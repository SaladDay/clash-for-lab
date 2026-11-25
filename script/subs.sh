# shellcheck disable=SC2148
# Named subscriptions (`clash sub`) and unattended refresh (`clash autoupdate`).

MIHOMO_SUBS_FILE="${MIHOMO_BASE_DIR}/subscriptions.tsv"
MIHOMO_AUTOUPDATE_FILE="${MIHOMO_BASE_DIR}/config/autoupdate"
MIHOMO_AUTOUPDATE_STAMP="${MIHOMO_BASE_DIR}/config/autoupdate.last"

_subs_url() {
    [ -f "$MIHOMO_SUBS_FILE" ] || return 1
    SUB_NAME=$1 awk -F '\t' '$1 == ENVIRON["SUB_NAME"] { print $2; found = 1; exit }
        END { exit !found }' "$MIHOMO_SUBS_FILE"
}

# Rewrite the list without NAME, optionally appending NAME with a new URL.
_subs_write() {
    local name=$1 url=${2:-} content=''
    _managed_file_supported "$MIHOMO_SUBS_FILE" || return 1
    [ ! -f "$MIHOMO_SUBS_FILE" ] ||
        content=$(SUB_NAME=$name awk -F '\t' '$1 != ENVIRON["SUB_NAME"]' "$MIHOMO_SUBS_FILE") || return 1
    [ -z "$url" ] || content="${content:+$content
}${name}	${url}"
    if [ -z "$content" ]; then
        rm -f "$MIHOMO_SUBS_FILE"
    else
        _config_atomic_write "$MIHOMO_SUBS_FILE" "$content"
    fi
}

_subs_list() {
    local current name url mark
    current=$(cat "$MIHOMO_CONFIG_URL" 2>/dev/null || true)
    [ -s "$MIHOMO_SUBS_FILE" ] || {
        _okcat "还没有保存的订阅，用 clash sub add <名称> '订阅地址' 添加"
        return 0
    }
    while IFS='	' read -r name url; do
        mark=' '
        [ "$url" = "$current" ] && mark='▶'
        printf '%s %s  %s\n' "$mark" "$name" "$(_mask_subscription_url "$url")"
    done < "$MIHOMO_SUBS_FILE"
}

function clashsub() {
    local action=${1:-ls} name=${2:-} url=${3:-}
    case "$name" in
    *[[:space:]]*)
        _failcat '订阅名称不能包含空白' || true
        return 1
        ;;
    esac
    case "$action:$#" in
    ls:*) _subs_list ;;
    add:3)
        [ -n "$name" ] && _is_valid_subscription_url "$url" || {
            _failcat '名称或订阅地址无效' || true
            return 1
        }
        _mihomo_run_locked _subs_write "$name" "$url" || return 1
        _okcat "已保存 ${name}，执行 clash sub use ${name} 启用"
        ;;
    use:2)
        url=$(_subs_url "$name") || {
            _failcat "没有名为 ${name} 的订阅，用 clash sub 查看" || true
            return 1
        }
        # Validated before anything is replaced; a bad one keeps the old config.
        clashupdate "$url"
        ;;
    rm:2)
        _subs_url "$name" >/dev/null || {
            _failcat "没有名为 ${name} 的订阅" || true
            return 1
        }
        _mihomo_run_locked _subs_write "$name" && _okcat "已删除 $name"
        ;;
    *)
        cat <<'EOF'
用法: clash sub [命令]
    ls                      列出保存的订阅
    add <名称> '订阅地址'   保存一个订阅
    use <名称>              下载并切换到该订阅
    rm <名称>               删除
EOF
        return 1
        ;;
    esac
}

function clashautoupdate() {
    local hours=${2:-24}
    case "${1:-status}" in
    on)
        case "$hours" in
        ''|0*|*[!0-9]*) _failcat '间隔必须是正整数小时' || true; return 1 ;;
        esac
        _config_atomic_write "$MIHOMO_AUTOUPDATE_FILE" "$hours" || return 1
        _watchdog_is_running || ( clashwatchdog on ) || return 1
        _okcat "每 ${hours} 小时自动更新订阅（更新时连接会短暂中断）"
        ;;
    off)
        rm -f "$MIHOMO_AUTOUPDATE_FILE" && _okcat '订阅自动更新：已关闭'
        ;;
    status)
        if [ ! -f "$MIHOMO_AUTOUPDATE_FILE" ]; then
            _okcat '订阅自动更新：已关闭'
        elif _watchdog_is_running; then
            _okcat "订阅自动更新：每 $(cat "$MIHOMO_AUTOUPDATE_FILE") 小时"
        else
            _failcat '订阅自动更新已开启，但看门狗未运行，执行 clash watchdog on' || true
        fi
        ;;
    *)
        _failcat '用法: clash autoupdate [on [小时]|off|status]' || true
        return 1
        ;;
    esac
}

# Called by the watchdog. Failures are retried at most once per hour.
_autoupdate_is_due() {
    local hours
    hours=$(cat "$MIHOMO_AUTOUPDATE_FILE" 2>/dev/null) || return 1
    case "$hours" in ''|0*|*[!0-9]*) return 1 ;; esac
    [ -z "$(find "$MIHOMO_CONFIG_RAW" -mmin "-$((hours * 60))" 2>/dev/null)" ] &&
        [ -z "$(find "$MIHOMO_AUTOUPDATE_STAMP" -mmin -60 2>/dev/null)" ]
}
