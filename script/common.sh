# shellcheck disable=SC2148
# shellcheck disable=SC2034
# shellcheck disable=SC2155
[ -n "$BASH_VERSION" ] && set +o noglob
[ -n "$ZSH_VERSION" ] && setopt glob no_nomatch

URL_GH_PROXY='https://ghfast.top'
URL_CLASH_UI="http://board.zash.run.place"

SCRIPT_BASE_DIR='./script'
SCRIPT_FISH="${SCRIPT_BASE_DIR}/clashctl.fish"

RESOURCES_BASE_DIR='./resources'
RESOURCES_BIN_DIR="${RESOURCES_BASE_DIR}/bin"
RESOURCES_CONFIG="${RESOURCES_BASE_DIR}/config.yaml"
RESOURCES_CONFIG_MIXIN="${RESOURCES_BASE_DIR}/mixin.yaml"

ZIP_BASE_DIR="${RESOURCES_BASE_DIR}/zip"
ZIP_CLASH=$(echo ${ZIP_BASE_DIR}/clash*)
ZIP_MIHOMO=$(echo ${ZIP_BASE_DIR}/mihomo*)
ZIP_YQ=$(echo ${ZIP_BASE_DIR}/yq*)
ZIP_SUBCONVERTER=$(echo ${ZIP_BASE_DIR}/subconverter*)
ZIP_UI="${ZIP_BASE_DIR}/yacd.tar.xz"

MIHOMO_BASE_DIR="$HOME/tools/mihomo"
MIHOMO_SCRIPT_DIR="${MIHOMO_BASE_DIR}/$(basename $SCRIPT_BASE_DIR)"
MIHOMO_CONFIG_URL="${MIHOMO_BASE_DIR}/url"
MIHOMO_CONFIG_RAW="${MIHOMO_BASE_DIR}/$(basename $RESOURCES_CONFIG)"
MIHOMO_CONFIG_RAW_BAK="${MIHOMO_CONFIG_RAW}.bak"
MIHOMO_CONFIG_MIXIN="${MIHOMO_BASE_DIR}/$(basename $RESOURCES_CONFIG_MIXIN)"
MIHOMO_CONFIG_RUNTIME="${MIHOMO_BASE_DIR}/runtime.yaml"
MIHOMO_UPDATE_LOG="${MIHOMO_BASE_DIR}/mihomoctl.log"

# Legacy compatibility - keep CLASH_* variables pointing to new locations
CLASH_BASE_DIR="$MIHOMO_BASE_DIR"
CLASH_SCRIPT_DIR="$MIHOMO_SCRIPT_DIR"
CLASH_CONFIG_URL="$MIHOMO_CONFIG_URL"
CLASH_CONFIG_RAW="$MIHOMO_CONFIG_RAW"
CLASH_CONFIG_RAW_BAK="$MIHOMO_CONFIG_RAW_BAK"
CLASH_CONFIG_MIXIN="$MIHOMO_CONFIG_MIXIN"
CLASH_CONFIG_RUNTIME="$MIHOMO_CONFIG_RUNTIME"
CLASH_UPDATE_LOG="$MIHOMO_UPDATE_LOG"

_set_var() {
    local user=$USER
    local home=$HOME

    [ -n "$BASH_VERSION" ] && {
        _SHELL=bash
    }
    [ -n "$ZSH_VERSION" ] && {
        _SHELL=zsh
    }
    [ -n "$fish_version" ] && {
        _SHELL=fish
    }

    # rc文件路径
    command -v bash >&/dev/null && {
        SHELL_RC_BASH="${home}/.bashrc"
    }
    command -v zsh >&/dev/null && {
        SHELL_RC_ZSH="${home}/.zshrc"
    }
    command -v fish >&/dev/null && {
        SHELL_RC_FISH="${home}/.config/fish/conf.d/clashctl.fish"
    }

    # 用户级定时任务路径 - 使用用户crontab而不是系统crontab
    MIHOMO_CRON_TAB="user"  # 标记使用用户级crontab
    
    # Legacy compatibility
    CLASH_CRON_TAB="$MIHOMO_CRON_TAB"
}
_set_var

# shellcheck disable=SC2120
_set_bin() {
    local bin_base_dir="${MIHOMO_BASE_DIR}/bin"
    [ -n "$1" ] && bin_base_dir=$1
    BIN_CLASH="${bin_base_dir}/clash"
    BIN_MIHOMO="${bin_base_dir}/mihomo"
    BIN_YQ="${bin_base_dir}/yq"
    BIN_SUBCONVERTER_DIR="${bin_base_dir}/subconverter"
    BIN_SUBCONVERTER_CONFIG="$BIN_SUBCONVERTER_DIR/pref.yml"
    BIN_SUBCONVERTER_PORT="25500"
    BIN_SUBCONVERTER="${BIN_SUBCONVERTER_DIR}/subconverter"
    BIN_SUBCONVERTER_LOG="${BIN_SUBCONVERTER_DIR}/latest.log"

    [ -f "$BIN_CLASH" ] && {
        BIN_KERNEL=$BIN_CLASH
    }
    [ -f "$BIN_MIHOMO" ] && {
        BIN_KERNEL=$BIN_MIHOMO
    }
    BIN_KERNEL_NAME=$(basename "$BIN_KERNEL")
}
_set_bin

_set_rc() {
    [ "$1" = "unset" ] && {
        sed -i "\|$MIHOMO_SCRIPT_DIR|d" "$SHELL_RC_BASH" "$SHELL_RC_ZSH" 2>/dev/null
        rm -f "$SHELL_RC_FISH" 2>/dev/null
        return
    }

    echo "source $MIHOMO_SCRIPT_DIR/common.sh && source $MIHOMO_SCRIPT_DIR/clashctl.sh && watch_proxy" |
        tee -a "$SHELL_RC_BASH" "$SHELL_RC_ZSH" >&/dev/null
    [ -n "$SHELL_RC_FISH" ] && install $SCRIPT_FISH "$SHELL_RC_FISH"
}

# 默认集成、安装mihomo内核
# 移除/删除mihomo：下载安装clash内核
function _get_kernel() {
    [ -f "$ZIP_CLASH" ] && {
        ZIP_KERNEL=$ZIP_CLASH
        BIN_KERNEL=$BIN_CLASH
    }

    [ -f "$ZIP_MIHOMO" ] && {
        ZIP_KERNEL=$ZIP_MIHOMO
        BIN_KERNEL=$BIN_MIHOMO
    }

    [ ! -f "$ZIP_MIHOMO" ] && [ ! -f "$ZIP_CLASH" ] && {
        local arch=$(uname -m)
        _failcat "${ZIP_BASE_DIR}：未检测到可用的内核压缩包"
        _download_clash "$arch"
        ZIP_KERNEL=$ZIP_CLASH
        BIN_KERNEL=$BIN_CLASH
    }

    BIN_KERNEL_NAME=$(basename "$BIN_KERNEL")
    _okcat "安装内核：$BIN_KERNEL_NAME"
}

_get_random_port() {
    local randomPort=$(shuf -i 1024-65535 -n 1)
    ! _is_bind "$randomPort" && { echo "$randomPort" && return; }
    _get_random_port
}

function _get_proxy_port() {
    local mixed_port=$("$BIN_YQ" '.mixed-port // ""' $MIHOMO_CONFIG_RUNTIME)
    MIXED_PORT=${mixed_port:-17890}

    _is_already_in_use "$MIXED_PORT" "$BIN_KERNEL_NAME" && {
        local newPort=$(_get_random_port)
        local msg="端口占用：${MIXED_PORT} 🎲 随机分配：$newPort"
        "$BIN_YQ" -i ".mixed-port = $newPort" $MIHOMO_CONFIG_RUNTIME
        MIXED_PORT=$newPort
        _failcat '🎯' "$msg"
    }
}

function _get_ui_port() {
    local ext_addr=$("$BIN_YQ" '.external-controller // ""' $MIHOMO_CONFIG_RUNTIME)
    local ext_port=${ext_addr##*:}
    UI_PORT=${ext_port:-19090}

    _is_already_in_use "$UI_PORT" "$BIN_KERNEL_NAME" && {
        local newPort=$(_get_random_port)
        local msg="端口占用：${UI_PORT} 🎲 随机分配：$newPort"
        "$BIN_YQ" -i ".external-controller = \"0.0.0.0:$newPort\"" $MIHOMO_CONFIG_RUNTIME
        UI_PORT=$newPort
        _failcat '🎯' "$msg"
    }
}

function _get_dns_port() {
    local dns_listen=$("$BIN_YQ" '.dns.listen // ""' $MIHOMO_CONFIG_RUNTIME)
    local dns_port=${dns_listen##*:}
    DNS_PORT=${dns_port:-15353}

    _is_already_in_use "$DNS_PORT" "$BIN_KERNEL_NAME" && {
        local newPort=$(_get_random_port)
        local msg="DNS端口占用：${DNS_PORT} 🎲 随机分配：$newPort"
        "$BIN_YQ" -i ".dns.listen = \"0.0.0.0:$newPort\"" $MIHOMO_CONFIG_RUNTIME
        DNS_PORT=$newPort
        _failcat '🎯' "$msg"
    }
}

_get_color() {
    local hex="${1#\#}"
    local r=$((16#${hex:0:2}))
    local g=$((16#${hex:2:2}))
    local b=$((16#${hex:4:2}))
    printf "\e[38;2;%d;%d;%dm" "$r" "$g" "$b"
}
_get_color_msg() {
    local color=$(_get_color "$1")
    local msg=$2
    local reset="\033[0m"
    printf "%b%s%b\n" "$color" "$msg" "$reset"
}

function _okcat() {
    local color=#c8d6e5
    local emoji=😼
    [ $# -gt 1 ] && emoji=$1 && shift
    local msg="${emoji} $1"
    _get_color_msg "$color" "$msg" && return 0
}

function _failcat() {
    local color=#fd79a8
    local emoji=😾
    [ $# -gt 1 ] && emoji=$1 && shift
    local msg="${emoji} $1"
    _get_color_msg "$color" "$msg" >&2 && return 1
}

function _quit() {
    exec "$_SHELL" -i
}

function _error_quit() {
    [ $# -gt 0 ] && {
        local color=#f92f60
        local emoji=📢
        [ $# -gt 1 ] && emoji=$1 && shift
        local msg="${emoji} $1"
        _get_color_msg "$color" "$msg"
    }
    exec $_SHELL -i
}

_is_bind() {
    local port=$1
    { ss -lnptu || netstat -lnptu; } 2>/dev/null | grep ":${port}\b"
}

_is_already_in_use() {
    local port=$1
    local progress=$2
    _is_bind "$port" | grep -qs -v "$progress"
}

# Removed _is_root function - not needed in userspace

function _valid_env() {
    # 用户空间运行，不需要root权限检查
    [ -n "$ZSH_VERSION" ] && [ -n "$BASH_VERSION" ] && _error_quit "仅支持：bash、zsh"
    # 用户空间不依赖systemd，移除相关检查
}

function _valid_config() {
    [ -e "$1" ] && [ "$(wc -l <"$1")" -gt 1 ] && {
        local cmd msg
        cmd="$BIN_KERNEL -d $(dirname "$1") -f $1 -t"
        msg=$(eval "$cmd") || {
            eval "$cmd"
            echo "$msg" | grep -qs "unsupport proxy type" && _error_quit "不支持的代理协议，请安装 mihomo 内核"
        }
    }
}

_download_clash() {
    local arch=$1
    local url sha256sum
    case "$arch" in
    x86_64)
        url=https://downloads.clash.wiki/ClashPremium/clash-linux-amd64-2023.08.17.gz
        sha256sum='92380f053f083e3794c1681583be013a57b160292d1d9e1056e7fa1c2d948747'
        ;;
    *86*)
        url=https://downloads.clash.wiki/ClashPremium/clash-linux-386-2023.08.17.gz
        sha256sum='254125efa731ade3c1bf7cfd83ae09a824e1361592ccd7c0cccd2a266dcb92b5'
        ;;
    armv*)
        url=https://downloads.clash.wiki/ClashPremium/clash-linux-armv5-2023.08.17.gz
        sha256sum='622f5e774847782b6d54066f0716114a088f143f9bdd37edf3394ae8253062e8'
        ;;
    aarch64)
        url=https://downloads.clash.wiki/ClashPremium/clash-linux-arm64-2023.08.17.gz
        sha256sum='c45b39bb241e270ae5f4498e2af75cecc0f03c9db3c0db5e55c8c4919f01afdd'
        ;;
    *)
        _error_quit "未知的架构版本：$arch，请自行下载对应版本至 ${ZIP_BASE_DIR} 目录下：https://downloads.clash.wiki/ClashPremium/"
        ;;
    esac

    _okcat '⏳' "正在下载：clash：${arch} 架构..."
    local clash_zip="${ZIP_BASE_DIR}/$(basename $url)"
    curl \
        --progress-bar \
        --show-error \
        --fail \
        --insecure \
        --connect-timeout 15 \
        --retry 1 \
        --output "$clash_zip" \
        "$url"
    echo $sha256sum "$clash_zip" | sha256sum -c ||
        _error_quit "下载失败：请自行下载对应版本至 ${ZIP_BASE_DIR} 目录下：https://downloads.clash.wiki/ClashPremium/"
}

_download_raw_config() {
    local dest=$1
    local url=$2
    local agent='clash-verge/v2.0.4'
    curl \
        --silent \
        --show-error \
        --insecure \
        --connect-timeout 4 \
        --retry 1 \
        --user-agent "$agent" \
        --output "$dest" \
        "$url" ||
        wget \
            --no-verbose \
            --no-check-certificate \
            --timeout 3 \
            --tries 1 \
            --user-agent "$agent" \
            --output-document "$dest" \
            "$url"
}
_download_convert_config() {
    local dest=$1
    local url=$2
    _start_convert
    local convert_url=$(
        target='clash'
        base_url="http://127.0.0.1:${BIN_SUBCONVERTER_PORT}/sub"
        curl \
            --get \
            --silent \
            --output /dev/null \
            --data-urlencode "target=$target" \
            --data-urlencode "url=$url" \
            --write-out '%{url_effective}' \
            "$base_url"
    )
    _download_raw_config "$dest" "$convert_url"
    _stop_convert
}
function _download_config() {
    local dest=$1
    local url=$2
    [ "${url:0:4}" = 'file' ] && return 0
    _download_raw_config "$dest" "$url" || return 1
    _okcat '🍃' '下载成功：内核验证配置...'
    _valid_config "$dest" || {
        _failcat '🍂' "验证失败：尝试订阅转换..."
        _download_convert_config "$dest" "$url" || _failcat '🍂' "转换失败：请检查日志：$BIN_SUBCONVERTER_LOG"
    }
}

_start_convert() {
    _is_already_in_use $BIN_SUBCONVERTER_PORT 'subconverter' && {
        local newPort=$(_get_random_port)
        _failcat '🎯' "端口占用：$BIN_SUBCONVERTER_PORT 🎲 随机分配：$newPort"
        [ ! -e "$BIN_SUBCONVERTER_CONFIG" ] && {
            cp -f "$BIN_SUBCONVERTER_DIR/pref.example.yml" "$BIN_SUBCONVERTER_CONFIG"
        }
        "$BIN_YQ" -i ".server.port = $newPort" "$BIN_SUBCONVERTER_CONFIG"
        BIN_SUBCONVERTER_PORT=$newPort
    }
    local start=$(date +%s)
    # 子shell运行，屏蔽kill时的输出
    ("$BIN_SUBCONVERTER" 2>&1 | tee "$BIN_SUBCONVERTER_LOG" >/dev/null &)
    while ! _is_bind "$BIN_SUBCONVERTER_PORT" >&/dev/null; do
        sleep 1s
        local now=$(date +%s)
        [ $((now - start)) -gt 1 ] && _error_quit "订阅转换服务未启动，请检查日志：$BIN_SUBCONVERTER_LOG"
    done
}
_stop_convert() {
    pkill -9 -f "$BIN_SUBCONVERTER" >&/dev/null
}

# User-space process management functions
start_mihomo() {
    local pid_file="$MIHOMO_BASE_DIR/config/mihomo.pid"
    local log_file="$MIHOMO_BASE_DIR/logs/mihomo.log"
    
    # Create necessary directories
    mkdir -p "$(dirname "$pid_file")" "$(dirname "$log_file")"
    
    # Check if mihomo is already running
    if is_mihomo_running; then
        _okcat "mihomo 进程已在运行"
        return 0
    fi
    
    # Validate configuration before starting
    _valid_config "$MIHOMO_CONFIG_RUNTIME" || {
        _failcat "配置文件验证失败，无法启动 mihomo"
        return 1
    }
    
    # Start mihomo process in background using nohup
    nohup "$BIN_KERNEL" -d "$MIHOMO_BASE_DIR" -f "$MIHOMO_CONFIG_RUNTIME" \
        > "$log_file" 2>&1 &
    
    local pid=$!
    echo "$pid" > "$pid_file"
    
    # Wait a moment and verify the process started successfully
    sleep 1
    if is_mihomo_running; then
        _okcat "mihomo 进程启动成功 (PID: $pid)"
        return 0
    else
        rm -f "$pid_file"
        _failcat "mihomo 进程启动失败，请检查日志: $log_file"
        return 1
    fi
}

stop_mihomo() {
    local pid_file="$MIHOMO_BASE_DIR/config/mihomo.pid"
    
    if [ ! -f "$pid_file" ]; then
        _okcat "mihomo 进程未运行"
        return 0
    fi
    
    local pid=$(cat "$pid_file" 2>/dev/null)
    if [ -z "$pid" ]; then
        rm -f "$pid_file"
        _okcat "PID 文件为空，已清理"
        return 0
    fi
    
    # Try graceful shutdown first
    if kill "$pid" 2>/dev/null; then
        # Wait for graceful shutdown
        local count=0
        while kill -0 "$pid" 2>/dev/null && [ $count -lt 10 ]; do
            sleep 1
            count=$((count + 1))
        done
        
        # Force kill if still running
        if kill -0 "$pid" 2>/dev/null; then
            kill -9 "$pid" 2>/dev/null
            _okcat "强制终止 mihomo 进程 (PID: $pid)"
        else
            _okcat "mihomo 进程已优雅停止 (PID: $pid)"
        fi
    else
        _okcat "mihomo 进程已停止"
    fi
    
    rm -f "$pid_file"
    return 0
}

is_mihomo_running() {
    local pid_file="$MIHOMO_BASE_DIR/config/mihomo.pid"
    
    [ ! -f "$pid_file" ] && return 1
    
    local pid=$(cat "$pid_file" 2>/dev/null)
    [ -z "$pid" ] && return 1
    
    # Check if process is actually running
    kill -0 "$pid" 2>/dev/null
}
