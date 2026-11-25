# shellcheck disable=SC2148
# shellcheck disable=SC2155

_apply_system_proxy_environment() {
    local auth=$1
    local http_proxy_addr="http://${auth}127.0.0.1:${MIXED_PORT}"
    local socks_proxy_addr="socks5h://${auth}127.0.0.1:${MIXED_PORT}"
    local no_proxy_addr="localhost,127.0.0.1,::1"

    export http_proxy=$http_proxy_addr
    export https_proxy=$http_proxy_addr
    export HTTP_PROXY=$http_proxy_addr
    export HTTPS_PROXY=$http_proxy_addr

    export all_proxy=$socks_proxy_addr
    export ALL_PROXY=$socks_proxy_addr

    export no_proxy=$no_proxy_addr
    export NO_PROXY=$no_proxy_addr
}

# yq's `//` treats an explicit `false` like a missing value, so the default has
# to be applied here: only a literal `false` turns the preference off.
_system_proxy_preference() {
    local value
    value=$("$BIN_YQ" '.system-proxy.enable' "$MIHOMO_CONFIG_MIXIN" 2>/dev/null) || return 1
    [ "$value" = false ] || value=true
    printf '%s\n' "$value"
}

_set_system_proxy() {
    [ -f "$MIHOMO_CONFIG_RUNTIME" ] || {
        _failcat "运行时配置文件不存在: $MIHOMO_CONFIG_RUNTIME"
        return 1
    }

    local auth system_proxy_status
    system_proxy_status=$(_system_proxy_preference) || {
        _failcat "无法读取系统代理偏好"
        return 1
    }
    if [ "$system_proxy_status" != true ]; then
        _unset_system_proxy
        return 0
    fi

    auth=$("$BIN_YQ" '.authentication[0] // ""' "$MIHOMO_CONFIG_RUNTIME" 2>/dev/null) || {
        _failcat "无法读取代理认证配置"
        return 1
    }
    [ -n "$auth" ] && auth=$auth@
    _apply_system_proxy_environment "$auth"
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
}

_proxy_preference_before_commit() {
    :
}

_managed_file_supported() {
    [ ! -L "$1" ] && { [ ! -e "$1" ] || [ -f "$1" ]; }
}

_config_atomic_copy() {
    local source=$1 destination=$2 destination_dir temporary
    destination_dir=$(dirname "$destination") || return 1
    mkdir -p "$destination_dir" || return 1
    temporary=$(mktemp "${destination_dir}/.mihomo-config.XXXXXX") || return 1
    if cp "$source" "$temporary" && chmod 0600 "$temporary" &&
        mv -f "$temporary" "$destination"; then
        return 0
    fi
    rm -f "$temporary"
    return 1
}

_config_atomic_write() {
    local destination=$1 value=$2 destination_dir temporary
    destination_dir=$(dirname "$destination") || return 1
    mkdir -p "$destination_dir" || return 1
    temporary=$(mktemp "${destination_dir}/.mihomo-config.XXXXXX") || return 1
    if printf '%s\n' "$value" > "$temporary" && chmod 0600 "$temporary" &&
        mv -f "$temporary" "$destination"; then
        return 0
    fi
    rm -f "$temporary"
    return 1
}

_config_snapshot() {
    local file_path=$1 snapshot_dir=$2 name=$3
    _managed_file_supported "$file_path" || return 1
    if [ -f "$file_path" ]; then
        cp -p "$file_path" "$snapshot_dir/${name}.previous" || return 1
        chmod 0600 "$snapshot_dir/${name}.previous" || return 1
        printf '%s\n' present > "$snapshot_dir/${name}.state"
    else
        printf '%s\n' absent > "$snapshot_dir/${name}.state"
    fi
    chmod 0600 "$snapshot_dir/${name}.state"
}

_config_snapshot_present() {
    [ "$(cat "$1/$2.state" 2>/dev/null)" = present ]
}

_lifecycle_before_object_publish() {
    :
}

_lifecycle_after_object_publish() {
    :
}

_lifecycle_before_object_restore() {
    :
}

_config_publish() {
    local name=$1 source=$2 destination=$3
    _lifecycle_before_object_publish "$name" "$destination" || return 1
    _config_atomic_copy "$source" "$destination" || return 1
    _lifecycle_after_object_publish "$name" "$destination"
}

_config_restore() {
    local file_path=$1 snapshot_dir=$2 name=$3 state
    _lifecycle_before_object_restore "$name" "$file_path" || return 1
    state=$(cat "$snapshot_dir/${name}.state" 2>/dev/null) || return 1
    case "$state" in
    present) _config_atomic_copy "$snapshot_dir/${name}.previous" "$file_path" ;;
    absent) rm -f -- "$file_path" ;;
    *) return 1 ;;
    esac
}

_config_path_matches_snapshot() {
    local file_path=$1 snapshot=$2 had_path=$3
    if [ "$had_path" = true ]; then
        _managed_file_supported "$file_path" && [ -f "$file_path" ] &&
            cmp -s "$file_path" "$snapshot"
    else
        [ ! -e "$file_path" ] && [ ! -L "$file_path" ]
    fi
}

_persist_system_proxy_preference() (
    local enabled=$1 config_dir tmpdir candidate snapshot had_mixin=false status=0
    _managed_file_supported "$MIHOMO_CONFIG_MIXIN" || return 1
    config_dir=$(dirname "$MIHOMO_CONFIG_MIXIN") || return 1
    mkdir -p "$config_dir" || return 1
    tmpdir=$(mktemp -d "${config_dir}/.proxy-preference.XXXXXX") || return 1
    chmod 0700 "$tmpdir" || {
        rm -rf "$tmpdir"
        return 1
    }
    candidate="$tmpdir/candidate"
    snapshot="$tmpdir/snapshot"
    trap 'status=$?; trap - EXIT HUP INT TERM; rm -rf "$tmpdir"; exit "$status"' EXIT HUP INT TERM

    if [ -f "$MIHOMO_CONFIG_MIXIN" ]; then
        cp -p "$MIHOMO_CONFIG_MIXIN" "$snapshot" || return 1
        cp -p "$snapshot" "$candidate" || return 1
        had_mixin=true
    else
        printf '{}\n' > "$candidate" || return 1
    fi
    case "$enabled" in
    true) "$BIN_YQ" -i '.system-proxy.enable = true' "$candidate" 2>/dev/null || return 1 ;;
    false) "$BIN_YQ" -i '.system-proxy.enable = false' "$candidate" 2>/dev/null || return 1 ;;
    *) return 1 ;;
    esac

    _proxy_preference_before_commit "$MIHOMO_CONFIG_MIXIN" || return 1
    _config_path_matches_snapshot "$MIHOMO_CONFIG_MIXIN" "$snapshot" "$had_mixin" || {
        _failcat 'Mixin 在代理设置期间已被其他命令修改，本次操作已取消' || true
        return 1
    }
    _config_atomic_copy "$candidate" "$MIHOMO_CONFIG_MIXIN" || return 1
    trap - EXIT HUP INT TERM
    rm -rf "$tmpdir"
)

function clashon() {
    _mihomo_run_locked _clashon_locked "$@"
}

_build_runtime_candidate() {
    local raw_config=$1 candidate=$2 show_ports=${3:-false}
    local mixin_config=${4:-$MIHOMO_CONFIG_MIXIN}
    local port_preference_mode=${5:-}
    local port_preference_value=${6:-}
    local validation_sandbox=${7:-}
    "$BIN_YQ" eval-all '. as $item ireduce ({}; . *+ $item) | (.. | select(tag == "!!seq")) |= unique' \
        "$mixin_config" "$raw_config" "$mixin_config" > "$candidate" || {
        _failcat '合并配置失败'
        return 1
    }
    _resolve_port_conflicts "$candidate" "$show_ports" \
        "$port_preference_mode" "$port_preference_value" || return 1
    _valid_config "$candidate" "$MIHOMO_BASE_DIR" "$validation_sandbox" || {
        _failcat '验证失败：请检查 Mixin 配置'
        return 1
    }
}

_activate_published_runtime_unlocked() {
    _start_mihomo_unlocked || return 1
    sleep 2
    _verify_actual_ports || return 1
    _save_port_state "$MIXED_PORT" "$UI_PORT" "$DNS_PORT" || return 1
    _set_system_proxy || return 1
}

_refresh_runtime_environment_unlocked() {
    if is_mihomo_running &&
        command -v _get_proxy_port >/dev/null 2>&1 &&
        command -v _get_ui_port >/dev/null 2>&1 &&
        command -v _get_dns_port >/dev/null 2>&1; then
        _get_proxy_port
        _get_ui_port
        _get_dns_port
        # The transaction already persisted the proxy setting. This second
        # call makes its exported variables visible in the interactive shell.
        _set_system_proxy >/dev/null 2>&1 || true
    fi
}

_clashon_locked() {
    local transaction_status=0
    _clashon_unlocked "$@" || transaction_status=$?
    [ "$transaction_status" -eq 0 ] || return "$transaction_status"
    _refresh_runtime_environment_unlocked
    _okcat '已开启代理环境'
}

_runtime_rebuild_and_start_unlocked() (
    local show_ports=$1 tmpdir candidate validation_home validation_data_manifest
    local was_running=false
    local transaction_started=false transaction_committed=false service_transitioned=false

    _runtime_transaction_cleanup() {
        local transaction_status=$?
        trap '' HUP INT TERM
        trap - EXIT
        if [ "$transaction_committed" != true ] && [ "$transaction_started" = true ]; then
            if [ "$service_transitioned" = true ] && is_mihomo_running; then
                _stop_mihomo_unlocked >/dev/null 2>&1 || true
            fi
            _rollback_new_config_validation_data "$validation_home" "$MIHOMO_BASE_DIR" \
                "$validation_data_manifest" >/dev/null 2>&1 || true
            _config_restore "$MIHOMO_CONFIG_RUNTIME" "$tmpdir" runtime >/dev/null 2>&1 || true
            if [ "$service_transitioned" = true ]; then
                if [ "$was_running" = true ]; then
                    _activate_published_runtime_unlocked >/dev/null 2>&1 || true
                else
                    _unset_system_proxy >/dev/null 2>&1 || true
                fi
            fi
        fi
        rm -rf "$tmpdir" 2>/dev/null || true
        exit "$transaction_status"
    }

    _managed_file_supported "$MIHOMO_CONFIG_RAW" && [ -f "$MIHOMO_CONFIG_RAW" ] || return 1
    _managed_file_supported "$MIHOMO_CONFIG_MIXIN" && [ -f "$MIHOMO_CONFIG_MIXIN" ] || return 1
    _managed_file_supported "$MIHOMO_CONFIG_RUNTIME" || return 1
    mkdir -p "${MIHOMO_BASE_DIR}/tmp" || return 1
    tmpdir=$(mktemp -d "${MIHOMO_BASE_DIR}/tmp/runtime-change.XXXXXX") || return 1
    chmod 0700 "$tmpdir" || {
        rm -rf "$tmpdir"
        return 1
    }
    candidate="$tmpdir/runtime.candidate"
    validation_home="$tmpdir/validation-home"
    validation_data_manifest="$tmpdir/validation-data.manifest"
    _initialize_config_validation_home "$MIHOMO_BASE_DIR" "$validation_home" || {
        rm -rf "$tmpdir"
        return 1
    }
    _config_snapshot "$MIHOMO_CONFIG_RUNTIME" "$tmpdir" runtime || {
        rm -rf "$tmpdir"
        return 1
    }
    _build_runtime_candidate "$MIHOMO_CONFIG_RAW" "$candidate" "$show_ports" \
        "$MIHOMO_CONFIG_MIXIN" "" "" "$validation_home" || {
        rm -rf "$tmpdir"
        return 1
    }
    chmod 0600 "$candidate" || {
        rm -rf "$tmpdir"
        return 1
    }
    is_mihomo_running && was_running=true

    trap '_runtime_transaction_cleanup' EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    transaction_started=true
    if [ "$was_running" = true ]; then
        service_transitioned=true
        _stop_mihomo_unlocked || return 1
    fi
    _publish_new_config_validation_data "$validation_home" "$MIHOMO_BASE_DIR" \
        "$validation_data_manifest" || return 1
    _config_publish runtime "$candidate" "$MIHOMO_CONFIG_RUNTIME" || return 1
    service_transitioned=true
    _activate_published_runtime_unlocked || return 1

    transaction_committed=true
    trap - EXIT HUP INT TERM
    rm -rf "$tmpdir"
)

_clashon_unlocked() {
    _runtime_rebuild_and_start_unlocked true
}

# 验证实际监听端口与配置是否一致
_verify_actual_ports() {
    local log_file="$MIHOMO_BASE_DIR/logs/mihomo.log"
    [ ! -f "$log_file" ] && return 0

    # Extract actual listening ports from log
    # Try both old format (Mixed) and new format (HTTP proxy)
    local actual_proxy_port=$(grep "Mixed(http+socks) proxy listening at:" "$log_file" | tail -1 | sed -n 's/.*127\.0\.0\.1:\([0-9]*\).*/\1/p')
    [ -z "$actual_proxy_port" ] && actual_proxy_port=$(grep "HTTP proxy listening at:" "$log_file" | tail -1 | sed -n 's/.*127\.0\.0\.1:\([0-9]*\).*/\1/p')

    local actual_ui_port=$(grep "RESTful API listening at:" "$log_file" | tail -1 | sed -n 's/.*:\([0-9]\+\)[^0-9]*$/\1/p')
    local actual_dns_port=$(grep "DNS server(UDP) listening at:" "$log_file" | tail -1 | sed -n 's/.*\[::\]:\([0-9]*\).*/\1/p')

    # 从配置文件获取期望端口进行比较
    local config_proxy_port=$("$BIN_YQ" '.mixed-port // 7890' "$MIHOMO_CONFIG_RUNTIME" 2>/dev/null)
    local config_ui_addr=$("$BIN_YQ" '.external-controller // "127.0.0.1:9090"' "$MIHOMO_CONFIG_RUNTIME" 2>/dev/null)
    local config_ui_port=${config_ui_addr##*:}
    local config_dns_addr=$("$BIN_YQ" '.dns.listen // "127.0.0.1:15353"' "$MIHOMO_CONFIG_RUNTIME" 2>/dev/null)
    local config_dns_port=${config_dns_addr##*:}

    local port_changed=false

    # 设置实际监听端口到变量
    if [ -n "$actual_proxy_port" ]; then
        MIXED_PORT=$actual_proxy_port
        [ "$actual_proxy_port" != "$config_proxy_port" ] && {
            _failcat "🔄" "mihomo自动调整代理端口: $config_proxy_port → $actual_proxy_port"
            port_changed=true
        }
    else
        MIXED_PORT=$config_proxy_port
    fi

    if [ -n "$actual_ui_port" ]; then
        UI_PORT=$actual_ui_port
        [ "$actual_ui_port" != "$config_ui_port" ] && {
            _failcat "🔄" "mihomo自动调整UI端口: $config_ui_port → $actual_ui_port"
            port_changed=true
        }
    else
        UI_PORT=$config_ui_port
    fi

    if [ -n "$actual_dns_port" ]; then
        DNS_PORT=$actual_dns_port
        [ "$actual_dns_port" != "$config_dns_port" ] && {
            _failcat "🔄" "mihomo自动调整DNS端口: $config_dns_port → $actual_dns_port"
            port_changed=true
        }
    else
        DNS_PORT=$config_dns_port
    fi

    # 只有当端口有变化时才显示最终端口分配并重新设置系统代理
    if [ "$port_changed" = true ]; then
        _okcat "最终端口分配 - 代理:$MIXED_PORT UI:$UI_PORT DNS:$DNS_PORT"
        # 保存实际监听端口到状态文件
        _save_port_state "$MIXED_PORT" "$UI_PORT" "$DNS_PORT" || return 1
        # 端口变化时重新设置系统代理环境变量
        _set_system_proxy || return 1
    fi
}

# ─── Proxy Environment Health ──────────────────────────────────────
#
# Diagnose whether the current shell's proxy environment variables
# are consistent with mihomo's live state.  Returns one of:
#   inactive  – no proxy env vars set
#   external  – proxy points to a non-loopback address (user's own)
#   poisoned  – proxy points to loopback but mihomo is not running
#   stale     – mihomo is running but the env var port doesn't match
#   healthy   – everything is consistent

_proxy_env_diagnose() {
    if ! _proxy_env_is_set; then
        printf 'inactive\n'
        return 0
    fi
    if ! _proxy_env_is_loopback; then
        printf 'external\n'
        return 0
    fi
    if ! is_mihomo_running; then
        printf 'poisoned\n'
        return 0
    fi
    # mihomo is running; verify the port in the env var matches the
    # actual mihomo mixed-port recorded in the port state file.
    _get_proxy_port 2>/dev/null || MIXED_PORT=
    local url port
    url=${http_proxy:-${HTTP_PROXY:-}}
    port=${url##*:}
    port=${port%%[/?]*}
    case "$port" in
    ''|*[!0-9]*) printf 'healthy\n'; return 0 ;;
    esac
    if [ -n "$MIXED_PORT" ] && [ "$port" != "$MIXED_PORT" ]; then
        printf 'stale\n'
        return 0
    fi
    printf 'healthy\n'
}

# Clear inherited loopback proxy variables when mihomo is no longer
# running.  Called by watch_proxy on every new interactive shell to
# prevent stale variables from causing silent connection failures.
_watch_proxy_cleanup() {
    if _proxy_env_is_loopback && ! is_mihomo_running; then
        _unset_system_proxy
    fi
}

watch_proxy() {
    [[ $- == *i* ]] || return 0

    local system_proxy_status
    system_proxy_status=$(_system_proxy_preference)

    if [ -z "${http_proxy:-}" ]; then
        # New interactive shell without inherited proxy variables.
        # Set them when the user has enabled system proxy and mihomo is live.
        if [ "$system_proxy_status" = "true" ] && is_mihomo_running; then
            _get_proxy_port
            _get_ui_port
            _get_dns_port
            _set_system_proxy
        fi
    elif [ "$system_proxy_status" = "true" ]; then
        # Proxy was inherited from a parent shell.  If system proxy is
        # enabled, clear stale loopback variables to prevent silent
        # connection failures.  If the user disabled system proxy,
        # leave their environment untouched.
        _watch_proxy_cleanup
    fi
}

function clashoff() {
    _mihomo_run_locked _clashoff_unlocked "$@"
}

_clashoff_unlocked() {
    # Stop mihomo process
    stop_mihomo || return 1
    _unset_system_proxy || return 1
    _okcat '已关闭代理环境'
}

function clashrestart() {
    _mihomo_run_locked _clashrestart_unlocked "$@"
}

_clashrestart_unlocked() {
    local restart_status=0
    _okcat "正在重启代理服务..."
    _merge_config_restart_unlocked || restart_status=$?
    if [ "$restart_status" -ne 0 ]; then
        _failcat "代理服务重启失败，已保留原配置和运行状态" || true
        return "$restart_status"
    fi
    _refresh_runtime_environment_unlocked
    _okcat "代理服务重启成功"
}

function clashproxy() {
    case "${1:-}" in
    on)
        _mihomo_run_locked _clashproxy_on_locked
        ;;
    off)
        _mihomo_run_locked _clashproxy_off_locked
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

_clashproxy_on_locked() {
    local auth

    is_mihomo_running || {
        _failcat '无法开启系统代理：mihomo 进程未运行'
        return 1
    }
    _get_proxy_port || return 1
    _get_ui_port || return 1
    _get_dns_port || return 1
    [ -f "$MIHOMO_CONFIG_RUNTIME" ] || {
        _failcat "运行时配置文件不存在: $MIHOMO_CONFIG_RUNTIME"
        return 1
    }
    auth=$("$BIN_YQ" '.authentication[0] // ""' "$MIHOMO_CONFIG_RUNTIME" 2>/dev/null) || {
        _failcat "无法读取代理认证配置"
        return 1
    }
    [ -n "$auth" ] && auth=$auth@

    _persist_system_proxy_preference true || {
        _failcat "无法更新系统代理配置"
        return 1
    }
    _apply_system_proxy_environment "$auth"
    _okcat '已开启系统代理'
}

_clashproxy_off_locked() {
    _persist_system_proxy_preference false || {
        _failcat "无法更新系统代理配置"
        return 1
    }
    _unset_system_proxy
    _okcat '已关闭系统代理'
}

_clashport_apply_unlocked() (
    local mode=$1 value=${2:-}
    local tmpdir preference_candidate runtime_candidate was_running=false
    local service_transitioned=false transaction_started=false transaction_committed=false

    _port_transaction_cleanup() {
        local transaction_status=$?
        trap '' HUP INT TERM
        trap - EXIT
        if [ "$transaction_committed" != true ] && [ "$transaction_started" = true ]; then
            if [ "$service_transitioned" = true ] && is_mihomo_running; then
                _stop_mihomo_unlocked >/dev/null 2>&1 || true
            fi
            _config_restore "$MIHOMO_PORT_PREF" "$tmpdir" preference >/dev/null 2>&1 || true
            _config_restore "$MIHOMO_CONFIG_RUNTIME" "$tmpdir" runtime >/dev/null 2>&1 || true
            if [ "$service_transitioned" = true ]; then
                if [ "$was_running" = true ]; then
                    _activate_published_runtime_unlocked >/dev/null 2>&1 || true
                else
                    _unset_system_proxy >/dev/null 2>&1 || true
                fi
            fi
        fi
        rm -rf "$tmpdir" 2>/dev/null || true
        exit "$transaction_status"
    }

    [ -d "$MIHOMO_BASE_DIR" ] || {
        _failcat "安装目录不存在：$MIHOMO_BASE_DIR" || true
        return 1
    }
    _managed_file_supported "$MIHOMO_PORT_PREF" || return 1
    _managed_file_supported "$MIHOMO_CONFIG_RUNTIME" || return 1
    mkdir -p "${MIHOMO_BASE_DIR}/tmp" "$(dirname "$MIHOMO_PORT_PREF")" || return 1
    tmpdir=$(mktemp -d "${MIHOMO_BASE_DIR}/tmp/port-change.XXXXXX") || return 1
    chmod 0700 "$tmpdir" || {
        rm -rf "$tmpdir"
        return 1
    }
    preference_candidate="$tmpdir/port.candidate"
    runtime_candidate="$tmpdir/runtime.candidate.yaml"
    _config_snapshot "$MIHOMO_PORT_PREF" "$tmpdir" preference || {
        rm -rf "$tmpdir"
        return 1
    }
    _config_snapshot "$MIHOMO_CONFIG_RUNTIME" "$tmpdir" runtime || {
        rm -rf "$tmpdir"
        return 1
    }
    _write_port_preferences_file "$preference_candidate" "$mode" "$value" || {
        rm -rf "$tmpdir"
        return 1
    }
    chmod 0600 "$preference_candidate" || return 1
    is_mihomo_running && was_running=true

    if [ "$was_running" = true ]; then
        _build_runtime_candidate "$MIHOMO_CONFIG_RAW" "$runtime_candidate" false \
            "$MIHOMO_CONFIG_MIXIN" "$mode" "$value" || {
            rm -rf "$tmpdir"
            return 1
        }
        chmod 0600 "$runtime_candidate" || return 1
    fi

    trap '_port_transaction_cleanup' EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    transaction_started=true
    if [ "$was_running" = true ]; then
        service_transitioned=true
        _stop_mihomo_unlocked || return 1
    fi
    _config_publish preference "$preference_candidate" "$MIHOMO_PORT_PREF" || return 1
    if [ "$was_running" = true ]; then
        _config_publish runtime "$runtime_candidate" "$MIHOMO_CONFIG_RUNTIME" || return 1
        _activate_published_runtime_unlocked || return 1
    fi

    transaction_committed=true
    trap - EXIT HUP INT TERM
    rm -rf "$tmpdir" 2>/dev/null || true
)

_clashport_apply_locked() {
    local mode=$1 value=${2:-}
    _clashport_apply_unlocked "$mode" "$value" || return 1
    _refresh_runtime_environment_unlocked
    if [ "$mode" = manual ]; then
        _okcat "已固定代理端口：$value"
    else
        _okcat "已切换为自动分配代理端口"
    fi
}

function clashport() {
    local action=${1:-}
    shift || true

    case "$action" in
    ""|status)
        _load_port_preferences
        _get_proxy_port
        local mode_msg
        if [ "$PORT_PREF_MODE" = "manual" ] && [ -n "$PORT_PREF_VALUE" ]; then
            mode_msg="固定(${PORT_PREF_VALUE})"
        else
            mode_msg="自动"
        fi
        _okcat "端口模式：$mode_msg"
        _okcat "当前代理端口：$MIXED_PORT"
        ;;
    auto)
        _mihomo_run_locked _clashport_apply_locked auto ""
        ;;
    set|manual)
        local manual_port=${1:-}
        local prefer_auto=false

        while true; do
            if [ -z "$manual_port" ]; then
                printf "请输入想要固定的代理端口 [1024-65535]: "
                if ! read -r manual_port; then
                    _failcat "未读取到端口，已取消设置" || true
                    return 1
                fi
            fi

            if [ -z "$manual_port" ]; then
                _failcat "未输入端口"
                _has_tty || return 1
                continue
            fi

            if ! [[ $manual_port =~ ^[0-9]+$ ]] || [ "$manual_port" -lt 1024 ] || [ "$manual_port" -gt 65535 ]; then
                _failcat "端口号无效，请输入 1024-65535 之间的数字"
                manual_port=""
                _has_tty || return 1
                continue
            fi

            if _is_already_in_use "$manual_port" "$BIN_KERNEL_NAME"; then
                _failcat '🎯' "端口 $manual_port 已被占用"
                _has_tty || {
                    _failcat "非交互环境无法选择新端口；请改用 clash port auto 或指定其他端口" || true
                    return 1
                }
                printf "选择操作 [r]重新输入/[a]自动分配: "
                if ! read -r choice; then
                    _failcat "未读取到选择，已取消设置" || true
                    return 1
                fi
                case "$choice" in
                [aA])
                    prefer_auto=true
                    break
                    ;;
                [rR])
                    manual_port=""
                    continue
                    ;;
                *)
                    manual_port=""
                    continue
                    ;;
                esac
            fi

            break
        done

        if [ "$prefer_auto" = true ]; then
            _mihomo_run_locked _clashport_apply_locked auto ""
        else
            _mihomo_run_locked _clashport_apply_locked manual "$manual_port"
        fi
        ;;
    *)
        cat <<EOF
用法: clashport [status|auto|set <port>]
    status          查看当前代理端口模式与端口
    auto            切换为自动分配代理端口
    set <port>      固定代理端口，端口冲突时可选择重新输入或自动分配
EOF
        ;;
    esac
}

# Probe mihomo's management API and proxy port to verify end-to-end
# connectivity.  Returns one of:
#   ok          – both API and proxy are responding
#   proxy_fail  – API responds but proxy cannot reach the internet
#   api_fail    – proxy works but API is not responding
#   down        – neither is responding
#
# Timeouts are short (2–5 s) so that clash status stays interactive.
_connectivity_check() {
    local ui_port=$1 proxy_port=$2 secret=${3:-} auth=${4:-}
    local api_ok=false proxy_ok=false
    local api_args

    api_args=(
        --disable --silent --show-error --fail
        --connect-timeout 2 --max-time 3
        --noproxy '*'
        --output /dev/null
    )
    [ -n "$secret" ] && api_args+=(-H "Authorization: Bearer $secret")

    curl "${api_args[@]}" "http://127.0.0.1:${ui_port}/version" 2>/dev/null &&
        api_ok=true

    # gstatic.com resolves to mainland addresses and is usually routed DIRECT, so
    # it answers even when every node is dead; google.com must use a node.
    # --noproxy '' matches nothing. '*' would bypass --proxy and report the
    # server's own direct connectivity instead.
    { [ -z "$auth" ] || _curl_config_line proxy-user "$auth"; } |
        curl --disable --silent --show-error --fail \
            --connect-timeout 3 --max-time "${MIHOMO_PROBE_TIMEOUT:-5}" \
            --proxy "http://127.0.0.1:${proxy_port}" \
            --noproxy '' \
            --output /dev/null \
            --config - \
            'http://www.google.com/generate_204' 2>/dev/null &&
        proxy_ok=true

    if [ "$api_ok" = true ] && [ "$proxy_ok" = true ]; then
        printf 'ok\n'
    elif [ "$api_ok" = true ]; then
        printf 'proxy_fail\n'
    elif [ "$proxy_ok" = true ]; then
        printf 'api_fail\n'
    else
        printf 'down\n'
    fi
}

_mask_subscription_url() {
    local scheme=${1%%://*} rest=${1#*://}
    rest=${rest%%[/?#]*}
    printf '%s://%s/***\n' "$scheme" "${rest##*@}"
}

function clashstatus() {
    local pid_file="$MIHOMO_BASE_DIR/config/mihomo.pid"
    local log_file="$MIHOMO_BASE_DIR/logs/mihomo.log"
    local pid='' managed_pids='' uptime=''
    local probe=true

    [ "${1:-}" = "--no-probe" ] && probe=false

    # Show subscription URL
    local subscription_url=$(cat "$MIHOMO_CONFIG_URL" 2>/dev/null)
    if [ -n "$subscription_url" ]; then
        # The path and query carry the token; status output gets pasted into issues.
        _okcat "订阅地址: $(_mask_subscription_url "$subscription_url")（完整地址: clash subscribe）"
    else
        _failcat "订阅地址: 未设置"
    fi

    if is_mihomo_running; then
        pid=$(cat "$pid_file" 2>/dev/null || true)
        if ! _is_mihomo_pid "$pid"; then
            managed_pids=$(_find_managed_mihomo_pids) || {
                _failcat "mihomo 进程状态: 无法安全确认"
                return 1
            }
            pid=$(printf '%s\n' "$managed_pids" | sed -n '1p')
        fi
        if [ -z "$pid" ]; then
            _failcat "mihomo 进程状态: 查询期间已停止"
            return 1
        fi
        uptime=$(ps -o etime= -p "$pid" 2>/dev/null | tr -d ' ')
        _okcat "mihomo 进程状态: 运行中"
        _okcat "进程 PID: $pid"
        _okcat "运行时间: ${uptime:-未知}"
        _okcat "配置文件: $MIHOMO_CONFIG_RUNTIME"
        _okcat "日志文件: $log_file"

        # Show proxy port status
        if [ -f "$MIHOMO_CONFIG_RUNTIME" ]; then
            _get_proxy_port
            _get_ui_port
            _get_dns_port
            _okcat "代理端口: $MIXED_PORT"
            _okcat "管理端口: $UI_PORT"
            _okcat "DNS端口: $DNS_PORT"

            # Connectivity probe
            if [ "$probe" = true ]; then
                local secret connectivity auth
                secret=$("$BIN_YQ" '.secret // ""' "$MIHOMO_CONFIG_RUNTIME" 2>/dev/null)
                auth=$("$BIN_YQ" '.authentication[0] // ""' "$MIHOMO_CONFIG_RUNTIME" 2>/dev/null)
                connectivity=$(_connectivity_check "$UI_PORT" "$MIXED_PORT" "$secret" "$auth")
                case "$connectivity" in
                ok)         _okcat '✅' '连通性: 正常' ;;
                proxy_fail) _failcat '⚠️' '连通性: 当前节点无法出网，试试 clash node best' || true ;;
                api_fail)   _failcat '⚠️' '连通性: 代理正常但管理 API 不可达' || true ;;
                down)       _failcat '❌' '连通性: 代理端口和管理 API 均不可达' || true ;;
                esac
            fi
        else
            _failcat "配置文件不存在，无法获取端口信息"
        fi

        # Show system proxy status
        clashproxy status
    else
        _failcat "mihomo 进程状态: 未运行"
        [ ! -f "$pid_file" ] || _failcat "检测到 PID 文件；状态查询不会自动清理" || true
        if _proxy_env_is_set && _proxy_env_is_loopback; then
            _failcat "⚠️ 当前终端代理变量指向已停止的 mihomo，执行 clash doctor 修复" || true
        fi
        return 1
    fi
}

function clashui() {
    _get_ui_port || return 1
    local host
    host=$(hostname -f 2>/dev/null || hostname 2>/dev/null)
    _okcat "第 1 步，在自己的电脑上执行（主机名和 SSH 端口按你平时的登录方式调整）："
    printf '  ssh -L %s:127.0.0.1:%s -N %s@%s\n' "$UI_PORT" "$UI_PORT" \
        "$(id -un 2>/dev/null || printf user)" "${host:-server}"
    _okcat "第 2 步，在自己电脑的浏览器打开：http://127.0.0.1:${UI_PORT}/ui"
    _okcat "首次登录：主机 127.0.0.1，端口 ${UI_PORT}，密钥用 clash secret 查看"
}

function clashtui() {
    local clashctl_bin="${MIHOMO_BASE_DIR}/bin/clashctl-tui"

    # 懒加载: 首次使用时下载 TUI 工具
    if [ ! -x "$clashctl_bin" ]; then
        _download_tui || return 1
    fi

    # 确保 mihomo 运行
    if ! is_mihomo_running; then
        _okcat "正在启动 mihomo..."
        clashon || return 1
    fi

    # 获取实际端口
    _verify_actual_ports
    _get_ui_port

    # 检查端口可用性
    if ! _is_bind "$UI_PORT" 2>/dev/null; then
        _failcat "API 端口 ${UI_PORT} 未监听，请执行 clash status 检查"
        return 1
    fi

    # 生成配置并启动 TUI
    local endpoint="http://127.0.0.1:${UI_PORT}"
    local api_secret
    local config_file="${MIHOMO_BASE_DIR}/config/clashctl.ron"
    local config_tmp=''

    api_secret=$("$BIN_YQ" '.secret // ""' "$MIHOMO_CONFIG_RUNTIME" 2>/dev/null) || {
        _failcat "无法读取 Web 控制台密钥"
        return 1
    }

    mkdir -p "$(dirname "$config_file")" || return 1
    config_tmp=$(mktemp "${config_file}.tmp.XXXXXX") || {
        _failcat "无法安全暂存 TUI 配置"
        return 1
    }
    if ! _generate_clashctl_config "mihomo-local" "$endpoint" "$api_secret" > "$config_tmp" ||
        ! chmod 0600 "$config_tmp" ||
        ! mv -f "$config_tmp" "$config_file"; then
        rm -f "$config_tmp"
        _failcat "生成配置失败"
        return 1
    fi
    config_tmp=''

    _okcat "正在连接 $endpoint ..."
    "$clashctl_bin" --config-path "$config_file" tui
}

_merge_config_restart() {
    _mihomo_run_locked _merge_config_restart_locked "$@"
}

_merge_config_restart_locked() {
    local transaction_status=0
    _merge_config_restart_unlocked "$@" || transaction_status=$?
    [ "$transaction_status" -eq 0 ] || return "$transaction_status"
    _refresh_runtime_environment_unlocked
}

_merge_config_restart_unlocked() {
    _runtime_rebuild_and_start_unlocked false
}

_write_mixin_candidate() {
    local field=$1 value=$2 candidate=$3

    case "$field" in
    secret)
        CLASH_FOR_LAB_MIXIN_VALUE=$value \
            "$BIN_YQ" -i '.secret = strenv(CLASH_FOR_LAB_MIXIN_VALUE)' "$candidate"
        ;;
    tun)
        case "$value" in
        true) "$BIN_YQ" -i '.tun.enable = true' "$candidate" ;;
        false) "$BIN_YQ" -i '.tun.enable = false' "$candidate" ;;
        *) return 1 ;;
        esac
        ;;
    lan)
        case "$value" in
        true) "$BIN_YQ" -i '.allow-lan = true' "$candidate" ;;
        false) "$BIN_YQ" -i '.allow-lan = false' "$candidate" ;;
        *) return 1 ;;
        esac
        ;;
    *)
        return 1
        ;;
    esac
}

_apply_mixin_change() {
    _mihomo_run_locked _apply_mixin_change_locked "$@"
}

_apply_mixin_change_locked() {
    local transaction_status=0
    _apply_mixin_change_unlocked "$@" || transaction_status=$?
    [ "$transaction_status" -eq 0 ] || return "$transaction_status"
    _refresh_runtime_environment_unlocked
}

_apply_mixin_change_unlocked() (
    local field=$1 value=$2
    local tmpdir mixin_candidate runtime_candidate validation_home validation_data_manifest
    local was_running=false
    local service_transitioned=false transaction_started=false transaction_committed=false

    _mixin_transaction_cleanup() {
        local transaction_status=$?
        trap '' HUP INT TERM
        trap - EXIT
        if [ "$transaction_committed" != true ] && [ "$transaction_started" = true ]; then
            if [ "$service_transitioned" = true ] && is_mihomo_running; then
                _stop_mihomo_unlocked >/dev/null 2>&1 || true
            fi
            _rollback_new_config_validation_data "$validation_home" "$MIHOMO_BASE_DIR" \
                "$validation_data_manifest" >/dev/null 2>&1 || true
            _config_restore "$MIHOMO_CONFIG_MIXIN" "$tmpdir" mixin >/dev/null 2>&1 || true
            _config_restore "$MIHOMO_CONFIG_RUNTIME" "$tmpdir" runtime >/dev/null 2>&1 || true
            if [ "$service_transitioned" = true ]; then
                if [ "$was_running" = true ]; then
                    _activate_published_runtime_unlocked >/dev/null 2>&1 || true
                else
                    _unset_system_proxy >/dev/null 2>&1 || true
                fi
            fi
        fi
        rm -rf "$tmpdir" 2>/dev/null || true
        exit "$transaction_status"
    }

    _managed_file_supported "$MIHOMO_CONFIG_MIXIN" || return 1
    _managed_file_supported "$MIHOMO_CONFIG_RUNTIME" || return 1
    _managed_file_supported "$MIHOMO_CONFIG_RAW" && [ -f "$MIHOMO_CONFIG_RAW" ] || return 1
    mkdir -p "${MIHOMO_BASE_DIR}/tmp" "$(dirname "$MIHOMO_CONFIG_MIXIN")" || return 1
    tmpdir=$(mktemp -d "${MIHOMO_BASE_DIR}/tmp/mixin-change.XXXXXX") || return 1
    chmod 0700 "$tmpdir" || {
        rm -rf "$tmpdir"
        return 1
    }
    mixin_candidate="$tmpdir/mixin.candidate.yaml"
    runtime_candidate="$tmpdir/runtime.candidate.yaml"
    validation_home="$tmpdir/validation-home"
    validation_data_manifest="$tmpdir/validation-data.manifest"
    _initialize_config_validation_home "$MIHOMO_BASE_DIR" "$validation_home" || {
        rm -rf "$tmpdir"
        return 1
    }
    _config_snapshot "$MIHOMO_CONFIG_MIXIN" "$tmpdir" mixin || {
        rm -rf "$tmpdir"
        return 1
    }
    _config_snapshot "$MIHOMO_CONFIG_RUNTIME" "$tmpdir" runtime || {
        rm -rf "$tmpdir"
        return 1
    }
    if _config_snapshot_present "$tmpdir" mixin; then
        cp -p "$tmpdir/mixin.previous" "$mixin_candidate" || {
            rm -rf "$tmpdir"
            return 1
        }
    else
        printf '{}\n' > "$mixin_candidate" || {
            rm -rf "$tmpdir"
            return 1
        }
    fi
    _write_mixin_candidate "$field" "$value" "$mixin_candidate" || {
        rm -rf "$tmpdir"
        return 1
    }
    _build_runtime_candidate "$MIHOMO_CONFIG_RAW" "$runtime_candidate" false \
        "$mixin_candidate" "" "" "$validation_home" || {
        rm -rf "$tmpdir"
        return 1
    }
    chmod 0600 "$mixin_candidate" "$runtime_candidate" || return 1
    is_mihomo_running && was_running=true

    trap '_mixin_transaction_cleanup' EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    transaction_started=true
    if [ "$was_running" = true ]; then
        service_transitioned=true
        _stop_mihomo_unlocked || return 1
    fi
    _publish_new_config_validation_data "$validation_home" "$MIHOMO_BASE_DIR" \
        "$validation_data_manifest" || return 1
    _config_publish mixin "$mixin_candidate" "$MIHOMO_CONFIG_MIXIN" || return 1
    _config_publish runtime "$runtime_candidate" "$MIHOMO_CONFIG_RUNTIME" || return 1
    if [ "$was_running" = true ]; then
        _activate_published_runtime_unlocked || return 1
    fi

    transaction_committed=true
    trap - EXIT HUP INT TERM
    rm -rf "$tmpdir"
)

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
        _apply_mixin_change secret "$1" || {
            _failcat "密钥更新失败，请重新输入"
            return 1
        }
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
    _apply_mixin_change tun false || {
        _failcat "无法更新 Tun 配置"
        return 1
    }
    _okcat "Tun 模式已关闭"
}

_tunon() {
    _tunstatus 2>/dev/null && return 0
    _apply_mixin_change tun true || {
        _failcat "无法更新 Tun 配置"
        return 1
    }
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

_lanstatus() {
    if [ -f "$MIHOMO_CONFIG_RUNTIME" ]; then
        local lan_status=$("$BIN_YQ" '.allow-lan // false' "${MIHOMO_CONFIG_RUNTIME}" 2>/dev/null)
        if [ "$lan_status" = 'true' ]; then
            _okcat '局域网访问：已开启'
        else
            _failcat '局域网访问：已关闭'
        fi
    else
        _failcat '局域网访问：配置文件不存在'
        return 1
    fi
}

_lanoff() {
    _lanstatus >/dev/null 2>&1 && {
        local current_status=$("$BIN_YQ" '.allow-lan // false' "${MIHOMO_CONFIG_RUNTIME}" 2>/dev/null)
        [ "$current_status" = 'false' ] && return 0
    }

    _apply_mixin_change lan false || {
        _failcat "无法更新局域网访问配置"
        return 1
    }
    _okcat "局域网访问已关闭"
}

_lanon() {
    local current_status=$("$BIN_YQ" '.allow-lan // false' "${MIHOMO_CONFIG_RUNTIME}" 2>/dev/null)
    [ "$current_status" = 'true' ] && return 0

    _apply_mixin_change lan true || {
        _failcat "无法更新局域网访问配置"
        return 1
    }
    _okcat "局域网访问已开启"
}

function clashlan() {
    case "$1" in
    on)
        _lanon
        ;;
    off)
        _lanoff
        ;;
    status)
        _lanstatus
        ;;
    *)
        _lanstatus
        ;;
    esac
}

_subscription_path_is_supported() {
    _managed_file_supported "$1"
}

_subscription_update_paths_are_supported() {
    local managed_path
    for managed_path in \
        "$MIHOMO_CONFIG_RAW" "$MIHOMO_CONFIG_RAW_BAK" \
        "$MIHOMO_CONFIG_RUNTIME" "$MIHOMO_CONFIG_URL" \
        "$MIHOMO_CONFIG_MIXIN" "$MIHOMO_PORT_PREF" \
        "$MIHOMO_PORT_STATE" "$MIHOMO_UPDATE_LOG"; do
        _subscription_path_is_supported "$managed_path" || return 1
    done
}

_clashsubscribe_set_locked() {
    local new_url=$1
    _subscription_path_is_supported "$MIHOMO_CONFIG_URL" || {
        _failcat '订阅地址文件是符号链接或特殊文件，已拒绝修改' || true
        return 1
    }
    _config_atomic_write "$MIHOMO_CONFIG_URL" "$new_url"
}

function clashsubscribe() {
    local new_url response url
    case "$#" in
    0)
        if _subscription_path_is_supported "$MIHOMO_CONFIG_URL" &&
            url=$(_read_subscription_url_snapshot "$MIHOMO_CONFIG_URL"); then
            _okcat "当前订阅地址: $url"
        else
            _failcat "未设置有效的订阅地址"
            return 1
        fi
        ;;
    1)
        new_url=$1
        _is_valid_subscription_url "$new_url" || {
            _failcat "无效的订阅地址，必须是完整的小写 http:// 或 https:// URL"
            return 1
        }
        _subscription_path_is_supported "$MIHOMO_CONFIG_URL" || {
            _failcat '订阅地址文件是符号链接或特殊文件，已拒绝修改'
            return 1
        }
        _mihomo_run_locked _clashsubscribe_set_locked "$new_url" || return 1
        _okcat "订阅地址已保存"

        # Enter means yes, but a closed stdin (scripts) never triggers an update.
        printf "是否立即更新订阅配置? [Y/n]: "
        if ! IFS= read -r response; then
            response=n
        fi
        case "$response" in
        ''|[yY]|[yY][eE][sS])
            # Read the URL again under the update lock. If another clash command
            # changed it while this prompt was open, the current value wins.
            clashupdate
            ;;
        *)
            _okcat "使用 'clash update' 命令可随时更新配置"
            ;;
        esac
        ;;
    *)
        cat <<EOF
用法: clash subscribe [URL]
    无参数      显示当前订阅地址
    URL         设置新的订阅地址，请用单引号包住完整地址
示例: clash subscribe 'https://example.com/sub?token=...&client=mihomo'
EOF
        return 1
        ;;
    esac
}

_append_subscription_update_log() {
    local log_dir
    log_dir=$(dirname "$MIHOMO_UPDATE_LOG") || return 1
    if [ -L "$MIHOMO_UPDATE_LOG" ] ||
        { [ -e "$MIHOMO_UPDATE_LOG" ] && [ ! -f "$MIHOMO_UPDATE_LOG" ]; }; then
        return 1
    fi
    mkdir -p "$log_dir" || return 1
    if [ ! -e "$MIHOMO_UPDATE_LOG" ]; then
        (umask 077 && : > "$MIHOMO_UPDATE_LOG") || return 1
    fi
    chmod 0600 "$MIHOMO_UPDATE_LOG" || return 1
    printf '[%s] 订阅更新成功\n' "$(date '+%Y-%m-%d %H:%M:%S')" >> "$MIHOMO_UPDATE_LOG"
}

_is_valid_subscription_url() {
    local url=$1 remainder authority hostport host port

    case "$url" in
    http://*) remainder=${url#http://} ;;
    https://*) remainder=${url#https://} ;;
    *) return 1 ;;
    esac
    case "$url" in
    *[[:space:]]*) return 1 ;;
    esac

    authority=${remainder%%[/?#]*}
    [ -n "$authority" ] || return 1
    hostport=${authority##*@}
    [ -n "$hostport" ] || return 1

    case "$hostport" in
    \[*\]*)
        host=${hostport#\[}
        host=${host%%\]*}
        [ -n "$host" ] || return 1
        port=${hostport#*\]}
        case "$port" in
        '') ;;
        :*)
            port=${port#:}
            [ -n "$port" ] || return 1
            case "$port" in
            *[!0-9]*) return 1 ;;
            esac
            [ "${#port}" -le 5 ] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || return 1
            ;;
        *) return 1 ;;
        esac
        ;;
    *)
        case "$hostport" in
        *'['*|*']'*) return 1 ;;
        esac
        host=${hostport%%:*}
        [ -n "$host" ] || return 1
        if [ "$hostport" != "$host" ]; then
            port=${hostport#*:}
            [ -n "$port" ] || return 1
            case "$port" in
            *[!0-9]*) return 1 ;;
            esac
            [ "${#port}" -le 5 ] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || return 1
        fi
        ;;
    esac
}

_read_subscription_url_snapshot() (
    local snapshot=$1 url='' extra='' first_status=0 second_status=0
    [ -f "$snapshot" ] && [ ! -L "$snapshot" ] || return 1
    exec 3< "$snapshot" || return 1
    IFS= read -r url <&3 || first_status=$?
    IFS= read -r extra <&3 || second_status=$?
    exec 3<&-
    [ "$first_status" -eq 0 ] || [ -n "$url" ] || return 1
    [ "$second_status" -ne 0 ] && [ -z "$extra" ] || return 1
    _is_valid_subscription_url "$url" || return 1
    printf '%s' "$url"
)

_clashupdate_apply_locked() (
    local explicit_url=$1 url=${2:-}
    local tmpdir snapshot_dir raw_candidate runtime_candidate url_candidate
    local validation_home validation_data_manifest
    local was_running=false service_transitioned=false
    local transaction_started=false transaction_committed=false

    _clashupdate_cleanup() {
        local transaction_status=$? restore_failed=false
        trap '' HUP INT TERM
        trap - EXIT
        if [ "$transaction_committed" != true ] && [ "$transaction_started" = true ]; then
            if [ "$service_transitioned" = true ] && is_mihomo_running; then
                _stop_mihomo_unlocked >/dev/null 2>&1 || true
            fi
            _rollback_new_config_validation_data "$validation_home" "$MIHOMO_BASE_DIR" \
                "$validation_data_manifest" >/dev/null 2>&1 ||
                restore_failed=true
            _config_restore "$MIHOMO_CONFIG_RAW" "$snapshot_dir" raw >/dev/null 2>&1 ||
                restore_failed=true
            _config_restore "$MIHOMO_CONFIG_RAW_BAK" "$snapshot_dir" raw-bak >/dev/null 2>&1 ||
                restore_failed=true
            _config_restore "$MIHOMO_CONFIG_RUNTIME" "$snapshot_dir" runtime >/dev/null 2>&1 ||
                restore_failed=true
            _config_restore "$MIHOMO_CONFIG_URL" "$snapshot_dir" url >/dev/null 2>&1 ||
                restore_failed=true
            if [ "$service_transitioned" = true ]; then
                if [ "$was_running" = true ]; then
                    _activate_published_runtime_unlocked >/dev/null 2>&1 ||
                        restore_failed=true
                else
                    _unset_system_proxy >/dev/null 2>&1 || true
                fi
            fi
            [ "$restore_failed" = false ] ||
                _failcat '订阅更新失败，配置或服务状态未能完整恢复，请立即检查' || true
        fi
        rm -rf "$tmpdir" 2>/dev/null || true
        exit "$transaction_status"
    }

    _subscription_update_paths_are_supported || {
        _failcat '订阅受管配置包含符号链接或特殊文件，已拒绝更新且未改动任何配置' || true
        return 1
    }
    if [ "$explicit_url" != true ]; then
        url=$(_read_subscription_url_snapshot "$MIHOMO_CONFIG_URL") || {
            _failcat "已保存的订阅地址无效，请重新执行 clash subscribe '完整订阅地址'" || true
            return 1
        }
    fi

    umask 077
    mkdir -p "${MIHOMO_BASE_DIR}/tmp" || return 1
    tmpdir=$(mktemp -d "${MIHOMO_BASE_DIR}/tmp/subscription-update.XXXXXX") || return 1
    chmod 0700 "$tmpdir" || {
        rm -rf "$tmpdir"
        return 1
    }
    snapshot_dir="$tmpdir/snapshot"
    mkdir "$snapshot_dir" || {
        rm -rf "$tmpdir"
        return 1
    }
    chmod 0700 "$snapshot_dir" || {
        rm -rf "$tmpdir"
        return 1
    }
    raw_candidate="$tmpdir/raw.candidate"
    runtime_candidate="$tmpdir/runtime.candidate"
    url_candidate="$tmpdir/url.candidate"
    validation_home="$tmpdir/validation-home"
    validation_data_manifest="$tmpdir/validation-data.manifest"
    _initialize_config_validation_home "$MIHOMO_BASE_DIR" "$validation_home" || {
        rm -rf "$tmpdir"
        return 1
    }

    _okcat '👌' '正在下载并验证新订阅配置...'
    _download_config "$raw_candidate" "$url" "$MIHOMO_BASE_DIR" \
        "$validation_home" || {
        rm -rf "$tmpdir"
        _failcat '🍂' '下载或转换失败，当前配置未改动' || true
        return 1
    }
    chmod 0600 "$raw_candidate" || {
        rm -rf "$tmpdir"
        return 1
    }

    _config_snapshot "$MIHOMO_CONFIG_RAW" "$snapshot_dir" raw &&
        _config_snapshot "$MIHOMO_CONFIG_RAW_BAK" "$snapshot_dir" raw-bak &&
        _config_snapshot "$MIHOMO_CONFIG_RUNTIME" "$snapshot_dir" runtime &&
        _config_snapshot "$MIHOMO_CONFIG_URL" "$snapshot_dir" url || {
        rm -rf "$tmpdir"
        return 1
    }
    _build_runtime_candidate "$raw_candidate" "$runtime_candidate" false \
        "$MIHOMO_CONFIG_MIXIN" "" "" "$validation_home" || {
        rm -rf "$tmpdir"
        return 1
    }
    printf '%s\n' "$url" > "$url_candidate" || {
        rm -rf "$tmpdir"
        return 1
    }
    chmod 0600 "$runtime_candidate" "$url_candidate" || {
        rm -rf "$tmpdir"
        return 1
    }

    is_mihomo_running && was_running=true
    trap '_clashupdate_cleanup' EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    transaction_started=true

    if [ "$was_running" = true ]; then
        service_transitioned=true
        _stop_mihomo_unlocked || return 1
    fi
    _publish_new_config_validation_data "$validation_home" "$MIHOMO_BASE_DIR" \
        "$validation_data_manifest" || return 1
    _config_publish raw "$raw_candidate" "$MIHOMO_CONFIG_RAW" || return 1
    if _config_snapshot_present "$snapshot_dir" raw; then
        _config_publish raw-bak "$snapshot_dir/raw.previous" "$MIHOMO_CONFIG_RAW_BAK" || return 1
    fi
    _config_publish runtime "$runtime_candidate" "$MIHOMO_CONFIG_RUNTIME" || return 1
    _config_publish url "$url_candidate" "$MIHOMO_CONFIG_URL" || return 1

    if [ "$was_running" = true ]; then
        _activate_published_runtime_unlocked || return 1
    fi

    transaction_committed=true
    trap - EXIT HUP INT TERM
    _append_subscription_update_log 2>/dev/null ||
        _failcat '🍂' '订阅已更新，但无法安全写入更新日志' || true
    rm -rf "$tmpdir"
)

_clashupdate_locked() {
    _clashupdate_apply_locked "$@" || return 1
    _refresh_runtime_environment_unlocked
    _okcat '🍃' '订阅更新成功'
}

function clashupdate() {
    local explicit_url=false url=

    if [ "${1:-}" = auto ]; then
        _failcat '为避免覆盖用户的并发 crontab 修改，本版本不再自动写入定时任务；请手动执行 clash update'
        return 1
    fi

    case "$#" in
    0) ;;
    1)
        case "$1" in
        log)
            if [ -f "$MIHOMO_UPDATE_LOG" ] && [ ! -L "$MIHOMO_UPDATE_LOG" ]; then
                tail "$MIHOMO_UPDATE_LOG"
            else
                _failcat "暂无更新日志"
            fi
            return $?
            ;;
        *)
            _is_valid_subscription_url "$1" || {
                _failcat '订阅地址必须是不含空白的完整小写 http:// 或 https:// URL'
                return 1
            }
            explicit_url=true
            url=$1
            ;;
        esac
        ;;
    *)
        _failcat '用法: clash update [URL|log]'
        return 1
        ;;
    esac

    # This check intentionally precedes lock acquisition, temp creation and
    # downloading. Unsupported managed paths therefore cause zero side effects.
    _subscription_update_paths_are_supported || {
        _failcat '订阅受管配置包含符号链接或特殊文件，已拒绝更新且未改动任何配置'
        return 1
    }
    if [ "$explicit_url" = false ] &&
        [ ! -f "$MIHOMO_CONFIG_URL" ]; then
        _failcat "未设置有效的订阅地址，请先执行 clash subscribe '完整订阅地址'"
        return 1
    fi

    _mihomo_run_locked _clashupdate_locked "$explicit_url" "$url"
}
function clashmixin() {
    case "$1" in
    -e)
        local editor
        editor=${EDITOR:-}
        [ -n "$editor" ] && command -v "$editor" >/dev/null 2>&1 ||
            editor=vim
        command -v "$editor" >/dev/null 2>&1 ||
            editor=vi
        command -v "$editor" >/dev/null 2>&1 ||
            editor=nano
        command -v "$editor" >/dev/null 2>&1 || {
            _failcat "未找到可用的编辑器（尝试了 EDITOR、vim、vi、nano）"
            return 1
        }
        "$editor" "$MIHOMO_CONFIG_MIXIN" && {
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

function clashdoctor() {
    local diagnosis issues=0 fixed=0

    _okcat '🔍' '代理环境诊断'

    # 1. Process status
    if is_mihomo_running; then
        local pid
        pid=$(cat "$MIHOMO_BASE_DIR/config/mihomo.pid" 2>/dev/null || true)
        _okcat '✅' "mihomo 进程: 运行中 (PID: ${pid:-未知})"
    else
        _failcat '❌' 'mihomo 进程: 未运行' || true
        issues=$((issues + 1))
    fi

    # 2. Proxy environment diagnosis
    diagnosis=$(_proxy_env_diagnose)
    case "$diagnosis" in
    healthy)
        _okcat '✅' '代理环境变量: 正常'
        ;;
    inactive)
        if is_mihomo_running; then
            _failcat '⚠️' '代理环境变量: 未设置 (mihomo 运行中，建议 clash proxy on)' || true
            issues=$((issues + 1))
        else
            _okcat '✅' '代理环境变量: 未设置'
        fi
        ;;
    poisoned)
        _failcat '❌' '代理环境变量: 指向已停止的 mihomo (中毒)' || true
        issues=$((issues + 1))
        ;;
    stale)
        _failcat '⚠️' '代理环境变量: 端口与当前 mihomo 不一致' || true
        issues=$((issues + 1))
        ;;
    external)
        _okcat 'ℹ️' '代理环境变量: 指向非本机代理 (不干预)'
        ;;
    esac

    # 3. Port bindings (only if mihomo is running)
    if is_mihomo_running; then
        _get_proxy_port 2>/dev/null || true
        _get_ui_port 2>/dev/null || true
        _get_dns_port 2>/dev/null || true

        if _is_bind "$MIXED_PORT" >/dev/null 2>&1; then
            _okcat '✅' "代理端口 ${MIXED_PORT}: 监听中"
        else
            _failcat '❌' "代理端口 ${MIXED_PORT}: 未监听" || true
            issues=$((issues + 1))
        fi

        if _is_bind "$UI_PORT" >/dev/null 2>&1; then
            _okcat '✅' "管理端口 ${UI_PORT}: 监听中"
        else
            _failcat '❌' "管理端口 ${UI_PORT}: 未监听" || true
            issues=$((issues + 1))
        fi
    fi

    # 4. Auto-fix
    if [ "$issues" -gt 0 ]; then
        _okcat '🔧' "发现 $issues 个问题，正在修复..."

        case "$diagnosis" in
        poisoned)
            _unset_system_proxy
            _okcat '✅' '已清除当前终端的过期代理环境变量'
            fixed=$((fixed + 1))
            ;;
        stale)
            if is_mihomo_running; then
                _get_proxy_port 2>/dev/null || true
                _get_ui_port 2>/dev/null || true
                _get_dns_port 2>/dev/null || true
                if _set_system_proxy 2>/dev/null; then
                    _okcat '✅' '已刷新当前终端的代理环境变量'
                    fixed=$((fixed + 1))
                else
                    _failcat '❌' '无法刷新代理环境变量' || true
                fi
            fi
            ;;
        esac

        if ! is_mihomo_running; then
            _okcat '💡' '执行 clash on 启动代理服务'
        fi

        local remaining=$((issues - fixed))
        [ "$remaining" -le 0 ] ||
            _okcat 'ℹ️' "还有 $remaining 个问题需要手动处理"
    else
        _okcat '✅' '一切正常'
    fi
}

function clashlog() {
    local log_file="$MIHOMO_BASE_DIR/logs/mihomo.log"
    local lines=50

    [ -f "$log_file" ] && [ ! -L "$log_file" ] || {
        _failcat "日志文件不存在：$log_file"
        return 1
    }

    case "${1:-}" in
    ''|[0-9]*)
        [ -z "${1:-}" ] || lines=$1
        [[ $lines =~ ^[0-9]+$ ]] && [ "$lines" -ge 1 ] || {
            _failcat "行数必须为正整数"
            return 1
        }
        tail -n "$lines" "$log_file"
        ;;
    -f|--follow)
        tail -f "$log_file"
        ;;
    *)
        _failcat "用法: clash log [N|-f]（N 为行数，默认 50；-f 跟踪日志）"
        return 1
        ;;
    esac
}

MIHOMO_WATCHDOG_PID_FILE="${MIHOMO_BASE_DIR}/config/watchdog.pid"
MIHOMO_WATCHDOG_INTERVAL=30

# A recycled PID must not be mistaken for (or killed as) our watchdog.
_watchdog_pid_matches() {
    local pid=$1 command_line
    _process_is_current_user_live "$pid" 2>/dev/null || return 1
    command_line=$(ps -ww -p "$pid" -o args= 2>/dev/null) || return 1
    case "$command_line " in
    *"/watchdog.sh $MIHOMO_BASE_DIR "*) return 0 ;;
    *) return 1 ;;
    esac
}

_watchdog_is_running() {
    local pid
    pid=$(cat "$MIHOMO_WATCHDOG_PID_FILE" 2>/dev/null || true)
    [ -n "$pid" ] && _watchdog_pid_matches "$pid"
}

_watchdog_stop() {
    local pid
    pid=$(cat "$MIHOMO_WATCHDOG_PID_FILE" 2>/dev/null || true)
    [ -n "$pid" ] || return 0
    _watchdog_pid_matches "$pid" || {
        rm -f "$MIHOMO_WATCHDOG_PID_FILE"
        return 0
    }
    kill "$pid" 2>/dev/null || true
    local count=0
    while _watchdog_pid_matches "$pid" && [ "$count" -lt 50 ]; do
        sleep 0.1
        count=$((count + 1))
    done
    _watchdog_pid_matches "$pid" && kill -9 "$pid" 2>/dev/null || true
    rm -f "$MIHOMO_WATCHDOG_PID_FILE"
}

function clashwatchdog() {
    case "${1:-status}" in
    on)
        if _watchdog_is_running; then
            _okcat '✅' '看门狗已在运行'
            return 0
        fi
        local watchdog_script
        watchdog_script="${MIHOMO_SCRIPT_DIR}/watchdog.sh"
        [ -x "$watchdog_script" ] || watchdog_script="${SCRIPT_BASE_DIR}/watchdog.sh"
        [ -x "$watchdog_script" ] || {
            _failcat '缺少看门狗脚本'
            return 1
        }
        nohup "$watchdog_script" "$MIHOMO_BASE_DIR" "$MIHOMO_WATCHDOG_INTERVAL" \
            >/dev/null 2>&1 &
        local wpid=$!
        sleep 1
        if _process_is_current_user_live "$wpid" 2>/dev/null; then
            printf '%s\n' "$wpid" > "$MIHOMO_WATCHDOG_PID_FILE"
            _okcat '✅' "看门狗已启动 (PID: $wpid)，每 ${MIHOMO_WATCHDOG_INTERVAL}s 检查一次"
        else
            _failcat '看门狗启动失败'
            return 1
        fi
        ;;
    off)
        if _watchdog_is_running; then
            _watchdog_stop
            _okcat '✅' '看门狗已停止'
        else
            rm -f "$MIHOMO_WATCHDOG_PID_FILE" 2>/dev/null || true
            _okcat '✅' '看门狗未运行'
        fi
        ;;
    status)
        if _watchdog_is_running; then
            local pid
            pid=$(cat "$MIHOMO_WATCHDOG_PID_FILE" 2>/dev/null || true)
            _okcat '✅' "看门狗: 运行中 (PID: ${pid:-未知})"
        else
            _failcat '看门狗: 未运行'
        fi
        ;;
    *)
        _failcat '用法: clash watchdog [on|off|status]'
        return 1
        ;;
    esac
}

# Run one command through the proxy without changing the current shell.
function clashrun() {
    [ $# -gt 0 ] || {
        _failcat "用法: clash run <命令> [参数...]" || true
        return 1
    }
    is_mihomo_running || {
        _failcat "代理未运行，请先执行 clash on" || true
        return 1
    }
    (
        _get_proxy_port
        auth=$("$BIN_YQ" '.authentication[0] // ""' "$MIHOMO_CONFIG_RUNTIME" 2>/dev/null)
        _apply_system_proxy_environment "${auth:+$auth@}"
        "$@"
    )
}

# Print assignments for `eval`, for sbatch scripts and other plain shells.
function clashenv() {
    is_mihomo_running || {
        _failcat "代理未运行，请先执行 clash on" || true
        return 1
    }
    (
        _get_proxy_port
        auth=$("$BIN_YQ" '.authentication[0] // ""' "$MIHOMO_CONFIG_RUNTIME" 2>/dev/null)
        _apply_system_proxy_environment "${auth:+$auth@}"
        printf 'export http_proxy=%q https_proxy=%q HTTP_PROXY=%q HTTPS_PROXY=%q\n' \
            "$http_proxy" "$https_proxy" "$HTTP_PROXY" "$HTTPS_PROXY"
        printf 'export all_proxy=%q ALL_PROXY=%q no_proxy=%q NO_PROXY=%q\n' \
            "$all_proxy" "$ALL_PROXY" "$no_proxy" "$NO_PROXY"
    )
}

function clashuninstall() {
    local answer uninstaller="${MIHOMO_BASE_DIR}/uninstall.sh"
    [ -f "$uninstaller" ] || {
        _failcat "缺少 ${uninstaller}，请在仓库目录执行 bash uninstall.sh" || true
        return 1
    }
    if [ "${1:-}" != -y ]; then
        printf '将停止代理并删除 %s（含订阅配置），继续? [y/N]: ' "$MIHOMO_BASE_DIR"
        IFS= read -r answer || answer=
        case "$answer" in
        [yY]|[yY][eE][sS]) ;;
        *) return 1 ;;
        esac
    fi
    bash "$uninstaller" </dev/null || return 1
    if _proxy_env_is_loopback; then
        _unset_system_proxy
    fi
}

MIHOMO_LAUNCHER="${HOME}/.local/bin/clash"

# Never replace a `clash` the user already has; only ever remove our own link.
_launcher_install() {
    [ ! -e "$MIHOMO_LAUNCHER" ] && [ ! -L "$MIHOMO_LAUNCHER" ] || return 0
    mkdir -p "$(dirname "$MIHOMO_LAUNCHER")" &&
        ln -s "${MIHOMO_SCRIPT_DIR}/clash-cli" "$MIHOMO_LAUNCHER"
}

_launcher_remove() {
    [ "$(readlink "$MIHOMO_LAUNCHER" 2>/dev/null)" = "${MIHOMO_SCRIPT_DIR}/clash-cli" ] || return 0
    rm -f "$MIHOMO_LAUNCHER"
}

function clashctl() {
    local help_status=0
    case "${1:-}" in
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
    port)
        shift
        clashport "$@"
        ;;
    tun)
        shift
        clashtun "$@"
        ;;
    lan)
        shift
        clashlan "$@"
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
    upgrade)
        shift
        clashupgrade "$@"
        ;;
    tui)
        clashtui
        ;;
    doctor)
        clashdoctor
        ;;
    log)
        shift
        clashlog "$@"
        ;;
    watchdog)
        shift
        clashwatchdog "$@"
        ;;
    node)
        shift
        clashnode "$@"
        ;;
    run)
        shift
        clashrun "$@"
        ;;
    env)
        clashenv
        ;;
    uninstall)
        shift
        clashuninstall "$@"
        ;;
    *)
        case "${1:-}" in
        ''|help|-h|--help) ;;
        *)
            _failcat "未知命令：$1" || true
            help_status=1
            ;;
        esac
        cat <<EOF

Usage:
    clash COMMAND  [OPTION]
    mihomo COMMAND [OPTION]
    mihomoctl COMMAND [OPTION]

Commands:
    on                      开启代理
    off                     关闭代理
    node     [ls|use|test|best]    查看、切换、测速节点
    run      COMMAND...     仅让这一条命令走代理
    env                     输出代理变量，用于 eval "\$(clash env)"
    restart                 重启代理服务
    status  [--no-probe]    进程运行状态与连通性检测
    doctor                  诊断并修复代理环境
    tui                     交互式终端界面（TUI）
    ui                      Web 控制台地址
    proxy    [on|off|status]       系统代理环境变量
    port     [status|auto|set]     代理端口模式设置
    tun      [on|off|status]       Tun 模式 (需要权限)
    lan      [on|off|status]       局域网访问控制
    mixin    [-e|-r]        Mixin 配置文件
    secret   [SECRET]       Web 控制台密钥
    subscribe [URL]         设置或查看订阅地址
    update   [URL|log]      手动更新订阅配置
    upgrade  [rollback|status]     升级或回滚 mihomo 稳定版内核
    log      [N]            查看最近 N 行运行日志（默认 50）
    watchdog [on|off|status]    进程崩溃自恢复
    uninstall [-y]          停止并卸载

说明:
    • 用户空间运行，无需 sudo 权限
    • 配置目录: ~/tools/mihomo/
    • 日志目录: ~/tools/mihomo/logs/
    • 进程管理: 基于 PID 文件和 nohup

EOF
        return "$help_status"
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
