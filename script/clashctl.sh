# shellcheck disable=SC2148
# shellcheck disable=SC2155

_set_system_proxy() {
    # Ensure config files exist before reading
    [ ! -f "$MIHOMO_CONFIG_RUNTIME" ] && {
        _failcat "运行时配置文件不存在: $MIHOMO_CONFIG_RUNTIME"
        return 1
    }
    
    local auth=$("$BIN_YQ" '.authentication[0] // ""' "$MIHOMO_CONFIG_RUNTIME" 2>/dev/null)
    [ -n "$auth" ] && auth=$auth@

    local http_proxy_addr="http://${auth}127.0.0.1:${MIXED_PORT}"
    local socks_proxy_addr="socks5h://${auth}127.0.0.1:${MIXED_PORT}"
    local no_proxy_addr="localhost,127.0.0.1,::1"

    export http_proxy=$http_proxy_addr
    export https_proxy=$http_proxy
    export HTTP_PROXY=$http_proxy
    export HTTPS_PROXY=$http_proxy

    export all_proxy=$socks_proxy_addr
    export ALL_PROXY=$all_proxy

    export no_proxy=$no_proxy_addr
    export NO_PROXY=$no_proxy

    # Ensure mixin config directory exists and update using user permissions
    mkdir -p "$(dirname "$MIHOMO_CONFIG_MIXIN")"
    "$BIN_YQ" -i '.system-proxy.enable = true' "$MIHOMO_CONFIG_MIXIN" 2>/dev/null || {
        _failcat "无法更新系统代理配置"
        return 1
    }
}

_unset_system_proxy() {
    unset http_proxy
    unset https_proxy
    unset HTTP_PROXY
    unset HTTPS_PROXY
    unset all_proxy
    unset ALL_PROXY
    unset no_proxy
    unset NO_PROXY

    # Ensure mixin config exists and update using user permissions
    mkdir -p "$(dirname "$MIHOMO_CONFIG_MIXIN")"
    "$BIN_YQ" -i '.system-proxy.enable = false' "$MIHOMO_CONFIG_MIXIN" 2>/dev/null || {
        _failcat "无法更新系统代理配置"
    }
}

function clashon() {
    # Ensure config directory exists
    mkdir -p "$(dirname "$MIHOMO_CONFIG_RUNTIME")"
    
    # Merge configuration using user permissions
    "$BIN_YQ" eval-all '. as $item ireduce ({}; . *+ $item) | (.. | select(tag == "!!seq")) |= unique' \
        "$MIHOMO_CONFIG_MIXIN" "$MIHOMO_CONFIG_RAW" "$MIHOMO_CONFIG_MIXIN" > "$MIHOMO_CONFIG_RUNTIME"
    
    _get_proxy_port
    _get_ui_port
    _get_dns_port
    
    # Start mihomo process
    if start_mihomo; then
        _set_system_proxy
        _okcat '已开启代理环境'
    else
        _failcat '代理启动失败'
        return 1
    fi
}

watch_proxy() {
    # 新开交互式shell，且无代理变量时
    [ -z "$http_proxy" ] && [[ $- == *i* ]] && {
        # 检查 mihomo 进程是否运行，如果运行则设置代理环境变量
        if is_mihomo_running; then
            _get_proxy_port
            _set_system_proxy
        fi
    }
}

function clashoff() {
    # Stop mihomo process
    stop_mihomo
    _unset_system_proxy
    _okcat '已关闭代理环境'
}

function clashrestart() {
    _okcat "正在重启代理服务..."
    { clashoff && clashon; } >&/dev/null && _okcat "代理服务重启成功"
}

function clashproxy() {
    case "$1" in
    on)
        if is_mihomo_running; then
            _set_system_proxy
            _okcat '已开启系统代理'
        else
            _failcat '无法开启系统代理：mihomo 进程未运行'
            return 1
        fi
        ;;
    off)
        _unset_system_proxy
        _okcat '已关闭系统代理'
        ;;
    status)
        local system_proxy_status=$("$BIN_YQ" '.system-proxy.enable' "$MIHOMO_CONFIG_MIXIN" 2>/dev/null)
        if [ "$system_proxy_status" = "false" ]; then
            _failcat "系统代理：关闭"
            return 1
        fi
        
        if is_mihomo_running; then
            _okcat "系统代理：开启
http_proxy： $http_proxy
socks_proxy：$all_proxy"
        else
            _failcat "系统代理：配置为开启，但 mihomo 进程未运行"
            return 1
        fi
        ;;
    *)
        cat <<EOF
用法: clashproxy [on|off|status]
    on      开启系统代理
    off     关闭系统代理
    status  查看系统代理状态
EOF
        ;;
    esac
}

function clashstatus() {
    local pid_file="$MIHOMO_BASE_DIR/config/mihomo.pid"
    local log_file="$MIHOMO_BASE_DIR/logs/mihomo.log"
    
    # Show subscription URL
    local subscription_url=$(cat "$MIHOMO_CONFIG_URL" 2>/dev/null)
    if [ -n "$subscription_url" ]; then
        _okcat "订阅地址: $subscription_url"
    else
        _failcat "订阅地址: 未设置"
    fi
    
    if is_mihomo_running; then
        local pid=$(cat "$pid_file" 2>/dev/null)
        local uptime=$(ps -o etime= -p "$pid" 2>/dev/null | tr -d ' ')
        _okcat "mihomo 进程状态: 运行中"
        _okcat "进程 PID: $pid"
        _okcat "运行时间: ${uptime:-未知}"
        _okcat "配置文件: $MIHOMO_CONFIG_RUNTIME"
        _okcat "日志文件: $log_file"
        
        # Show proxy port status
        _get_proxy_port
        _get_ui_port
        _get_dns_port
        _okcat "代理端口: $MIXED_PORT"
        _okcat "管理端口: $UI_PORT"
        _okcat "DNS端口: $DNS_PORT"
        
        # Show system proxy status
        clashproxy status
    else
        _failcat "mihomo 进程状态: 未运行"
        [ -f "$pid_file" ] && {
            _failcat "发现残留 PID 文件，已清理"
            rm -f "$pid_file"
        }
        return 1
    fi
}

function clashui() {
    _get_ui_port
    # 公网ip
    # ifconfig.me
    local query_url='api64.ipify.org'
    local public_ip=$(curl -s --noproxy "*" --connect-timeout 2 $query_url)
    local public_address="http://${public_ip:-公网}:${UI_PORT}/ui"
    # 内网ip
    # ip route get 1.1.1.1 | grep -oP 'src \K\S+'
    local local_ip=$(hostname -I | awk '{print $1}')
    local local_address="http://${local_ip}:${UI_PORT}/ui"
    printf "\n"
    printf "╔═══════════════════════════════════════════════╗\n"
    printf "║                %s                  ║\n" "$(_okcat 'Web 控制台')"
    printf "║═══════════════════════════════════════════════║\n"
    printf "║                                               ║\n"
    printf "║     🔓 注意放行端口：%-5s                    ║\n" "$UI_PORT"
    printf "║     🏠 内网：%-31s  ║\n" "$local_address"
    printf "║     🌏 公网：%-31s  ║\n" "$public_address"
    printf "║     ☁️  公共：%-31s  ║\n" "$URL_CLASH_UI"
    printf "║                                               ║\n"
    printf "╚═══════════════════════════════════════════════╝\n"
    printf "\n"
}

_merge_config_restart() {
    # Use user-accessible temp directory instead of /tmp
    local backup="${MIHOMO_BASE_DIR}/config/runtime.backup"
    
    # Ensure config directory exists
    mkdir -p "$(dirname "$backup")"
    
    # Backup current runtime config
    cat "$MIHOMO_CONFIG_RUNTIME" 2>/dev/null > "$backup"
    
    # Merge configurations using user permissions
    "$BIN_YQ" eval-all '. as $item ireduce ({}; . *+ $item) | (.. | select(tag == "!!seq")) |= unique' \
        "$MIHOMO_CONFIG_MIXIN" "$MIHOMO_CONFIG_RAW" "$MIHOMO_CONFIG_MIXIN" > "$MIHOMO_CONFIG_RUNTIME"
    
    # Validate merged configuration
    _valid_config "$MIHOMO_CONFIG_RUNTIME" || {
        # Restore backup on validation failure
        cat "$backup" > "$MIHOMO_CONFIG_RUNTIME" 2>/dev/null
        _error_quit "验证失败：请检查 Mixin 配置"
    }
    
    # Clean up backup file
    rm -f "$backup"
    
    clashrestart
}

function clashsecret() {
    case "$#" in
    0)
        if [ -f "$MIHOMO_CONFIG_RUNTIME" ]; then
            _okcat "当前密钥：$("$BIN_YQ" '.secret // ""' "$MIHOMO_CONFIG_RUNTIME" 2>/dev/null)"
        else
            _failcat "运行时配置文件不存在"
        fi
        ;;
    1)
        # Ensure mixin config directory exists
        mkdir -p "$(dirname "$MIHOMO_CONFIG_MIXIN")"
        "$BIN_YQ" -i ".secret = \"$1\"" "$MIHOMO_CONFIG_MIXIN" 2>/dev/null || {
            _failcat "密钥更新失败，请重新输入"
            return 1
        }
        _merge_config_restart
        _okcat "密钥更新成功，已重启生效"
        ;;
    *)
        _failcat "密钥不要包含空格或使用引号包围"
        ;;
    esac
}

_tunstatus() {
    if [ -f "$MIHOMO_CONFIG_RUNTIME" ]; then
        local tun_status=$("$BIN_YQ" '.tun.enable' "${MIHOMO_CONFIG_RUNTIME}" 2>/dev/null)
        # shellcheck disable=SC2015
        [ "$tun_status" = 'true' ] && _okcat 'Tun 状态：启用' || _failcat 'Tun 状态：关闭'
    else
        _failcat 'Tun 状态：配置文件不存在'
        return 1
    fi
}

_tunoff() {
    _tunstatus >/dev/null || return 0
    # Ensure mixin config directory exists
    mkdir -p "$(dirname "$MIHOMO_CONFIG_MIXIN")"
    "$BIN_YQ" -i '.tun.enable = false' "$MIHOMO_CONFIG_MIXIN" 2>/dev/null || {
        _failcat "无法更新 Tun 配置"
        return 1
    }
    _merge_config_restart && _okcat "Tun 模式已关闭"
}

_tunon() {
    _tunstatus 2>/dev/null && return 0
    # Ensure mixin config directory exists
    mkdir -p "$(dirname "$MIHOMO_CONFIG_MIXIN")"
    "$BIN_YQ" -i '.tun.enable = true' "$MIHOMO_CONFIG_MIXIN" 2>/dev/null || {
        _failcat "无法更新 Tun 配置"
        return 1
    }
    _merge_config_restart
    sleep 0.5s
    
    # Check if mihomo is running and tun mode is working
    if is_mihomo_running; then
        local log_file="$MIHOMO_BASE_DIR/logs/mihomo.log"
        # Check recent log entries for tun mode status
        if [ -f "$log_file" ]; then
            # Look for tun-related messages in the last few lines
            tail -20 "$log_file" 2>/dev/null | grep -i "tun" >/dev/null 2>&1 && {
                _okcat "Tun 模式已开启"
            } || {
                _okcat "Tun 模式已开启 (请检查日志确认状态: $log_file)"
            }
        else
            _okcat "Tun 模式已开启"
        fi
    else
        _failcat "Tun 模式配置已更新，但 mihomo 进程未运行"
    fi
}

function clashtun() {
    case "$1" in
    on)
        _tunon
        ;;
    off)
        _tunoff
        ;;
    *)
        _tunstatus
        ;;
    esac
}

function clashsubscribe() {
    case "$#" in
    0)
        # Show current subscription URL
        local url=$(cat "$MIHOMO_CONFIG_URL" 2>/dev/null)
        if [ -n "$url" ]; then
            _okcat "当前订阅地址: $url"
        else
            _failcat "未设置订阅地址"
            return 1
        fi
        ;;
    1)
        # Set new subscription URL
        local new_url="$1"
        if [ "${new_url:0:4}" != "http" ]; then
            _failcat "无效的订阅地址，必须以 http 或 https 开头"
            return 1
        fi
        
        # Save URL
        mkdir -p "$(dirname "$MIHOMO_CONFIG_URL")"
        echo "$new_url" > "$MIHOMO_CONFIG_URL"
        _okcat "订阅地址已设置: $new_url"
        
        # Ask if user wants to update immediately
        printf "是否立即更新订阅配置? [y/N]: "
        read -r response
        case "$response" in
        [yY]|[yY][eE][sS])
            clashupdate "$new_url"
            ;;
        *)
            _okcat "订阅地址已保存，使用 'clash update' 命令更新配置"
            ;;
        esac
        ;;
    *)
        cat <<EOF
用法: clash subscribe [URL]
    无参数      显示当前订阅地址
    URL         设置新的订阅地址
EOF
        ;;
    esac
}

function clashupdate() {
    local url=$(cat "$MIHOMO_CONFIG_URL" 2>/dev/null)
    local is_auto

    case "$1" in
    auto)
        is_auto=true
        [ -n "$2" ] && url=$2
        ;;
    log)
        tail "${MIHOMO_UPDATE_LOG}" 2>/dev/null || _failcat "暂无更新日志"
        return 0
        ;;
    *)
        [ -n "$1" ] && url=$1
        ;;
    esac

    # 如果没有提供有效的订阅链接（url为空或者不是http开头），则使用默认配置文件
    [ "${url:0:4}" != "http" ] && {
        _failcat "没有提供有效的订阅链接：使用 ${MIHOMO_CONFIG_RAW} 进行更新..."
        url="file://$MIHOMO_CONFIG_RAW"
    }

    # 如果是自动更新模式，则设置用户级定时任务
    [ "$is_auto" = true ] && {
        # Check if crontab entry already exists
        crontab -l 2>/dev/null | grep -qs 'mihomoctl.*update.*auto' || {
            # Add user-level crontab entry (every 2 days at midnight)
            (crontab -l 2>/dev/null; echo "0 0 */2 * * $_SHELL -i -c 'mihomoctl update auto $url'") | crontab -
        }
        _okcat "已设置用户级定时更新订阅 (每2天执行一次)" && return 0
    }

    _okcat '👌' "正在下载：原配置已备份..."
    
    # Ensure directories exist and backup using user permissions
    mkdir -p "$(dirname "$MIHOMO_CONFIG_RAW_BAK")" "$(dirname "$MIHOMO_UPDATE_LOG")"
    cp "$MIHOMO_CONFIG_RAW" "$MIHOMO_CONFIG_RAW_BAK" 2>/dev/null

    _rollback() {
        _failcat '🍂' "$1"
        # Restore backup using user permissions
        cp "$MIHOMO_CONFIG_RAW_BAK" "$MIHOMO_CONFIG_RAW" 2>/dev/null
        echo "[$(date +"%Y-%m-%d %H:%M:%S")] 订阅更新失败：$url" >> "${MIHOMO_UPDATE_LOG}"
        _error_quit
    }

    _download_config "$MIHOMO_CONFIG_RAW" "$url" || _rollback "下载失败：已回滚配置"
    _valid_config "$MIHOMO_CONFIG_RAW" || _rollback "转换失败：已回滚配置，转换日志：$BIN_SUBCONVERTER_LOG"

    _merge_config_restart && _okcat '🍃' '订阅更新成功'
    
    # Save URL and log success using user permissions
    mkdir -p "$(dirname "$MIHOMO_CONFIG_URL")"
    echo "$url" > "$MIHOMO_CONFIG_URL"
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] 订阅更新成功：$url" >> "${MIHOMO_UPDATE_LOG}"
}

function clashmixin() {
    case "$1" in
    -e)
        vim "$MIHOMO_CONFIG_MIXIN" && {
            _merge_config_restart && _okcat "配置更新成功，已重启生效"
        }
        ;;
    -r)
        less -f "$MIHOMO_CONFIG_RUNTIME"
        ;;
    *)
        less -f "$MIHOMO_CONFIG_MIXIN"
        ;;
    esac
}

function clashctl() {
    case "$1" in
    on)
        clashon
        ;;
    off)
        clashoff
        ;;
    restart)
        clashrestart
        ;;
    ui)
        clashui
        ;;
    status)
        shift
        clashstatus "$@"
        ;;
    proxy)
        shift
        clashproxy "$@"
        ;;
    tun)
        shift
        clashtun "$@"
        ;;
    mixin)
        shift
        clashmixin "$@"
        ;;
    secret)
        shift
        clashsecret "$@"
        ;;
    subscribe)
        shift
        clashsubscribe "$@"
        ;;
    update)
        shift
        clashupdate "$@"
        ;;
    *)
        cat <<EOF

Usage:
    clash COMMAND  [OPTION]
    mihomo COMMAND [OPTION]
    mihomoctl COMMAND [OPTION]

Commands:
    on                      开启代理 (用户空间进程)
    off                     关闭代理 (停止用户进程)
    restart                 重启代理服务
    proxy    [on|off]       系统代理环境变量
    ui                      Web 控制台地址
    status                  进程运行状态 (包含订阅地址)
    tun      [on|off]       Tun 模式 (需要权限)
    mixin    [-e|-r]        Mixin 配置文件
    secret   [SECRET]       Web 控制台密钥
    subscribe [URL]         设置或查看订阅地址
    update   [auto|log]     更新订阅配置

说明:
    • 用户空间运行，无需 sudo 权限
    • 配置目录: ~/tools/mihomo/
    • 日志目录: ~/tools/mihomo/logs/
    • 进程管理: 基于 PID 文件和 nohup

EOF
        ;;
    esac
}

function mihomoctl() {
    clashctl "$@"
}

function clash() {
    clashctl "$@"
}

function mihomo() {
    clashctl "$@"
}
