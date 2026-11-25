# shellcheck disable=SC2148
# Node selection through the local mihomo API: `clash node ...`.
# The API secret is only ever handed to curl on stdin, never on argv.

MIHOMO_NODE_TEST_URL="${MIHOMO_NODE_TEST_URL:-https://www.gstatic.com/generate_204}"
MIHOMO_NODE_TEST_TIMEOUT="${MIHOMO_NODE_TEST_TIMEOUT:-5000}"

_node_urlencode() {
    printf '%s' "$1" | LC_ALL=C od -An -v -tx1 | tr -d ' \n' | sed 's/../%&/g'
}

_node_api() {
    local method=$1 api_path=$2 body=${3:-} secret
    secret=$("$BIN_YQ" '.secret // ""' "$MIHOMO_CONFIG_RUNTIME" 2>/dev/null) || return 1
    {
        _curl_config_line url "http://127.0.0.1:${UI_PORT}${api_path}"
        _curl_config_line request "$method"
        [ -z "$secret" ] || _curl_config_line header "Authorization: Bearer $secret"
        [ -z "$body" ] || {
            _curl_config_line header 'Content-Type: application/json'
            _curl_config_line data-binary "$body"
        }
    } | curl --disable --silent --show-error --fail --noproxy '*' \
        --connect-timeout 3 --max-time 60 --config -
}

# The group users normally want to change: GLOBAL in global mode, otherwise
# the first `select` group of the running configuration.
_node_default_group() {
    local mode group
    mode=$(_node_api GET /configs 2>/dev/null | "$BIN_YQ" -p json '.mode // ""' 2>/dev/null)
    [ "$mode" = global ] && {
        printf 'GLOBAL\n'
        return 0
    }
    group=$("$BIN_YQ" '[.proxy-groups[] | select(.type == "select")][0].name // ""' \
        "$MIHOMO_CONFIG_RUNTIME" 2>/dev/null)
    printf '%s\n' "${group:-GLOBAL}"
}

# name<TAB>type<TAB>last delay (0 = unknown), in configuration order.
# yq fails on negative indexes into empty arrays, hence the leading [0].
_node_table() {
    local group=$1
    _node_api GET /proxies | NODE_GROUP=$group "$BIN_YQ" -p json -o tsv '
        .proxies as $p | [$p[strenv(NODE_GROUP)].all[] |
            . as $n | [$n, ($p[$n].type // ""), (([0] + [$p[$n].history[].delay]) | .[-1])]]'
}

_node_now() {
    _node_api GET "/proxies/$(_node_urlencode "$1")" | "$BIN_YQ" -p json '.now // ""'
}

_node_print() {
    local table=$1 now=$2
    printf '%s\n' "$table" | NODE_NOW=$now awk -F '\t' '
        { mark = ($1 == ENVIRON["NODE_NOW"]) ? "▶" : " "
          delay = ($3 + 0 > 0) ? $3 "ms" : "-"
          printf "%s %3d) %-8s %s\n", mark, NR, delay, $1 }'
}

# Resolve an exact name, a list number, or an unambiguous part of a name.
_node_resolve() {
    local table=$1 query=$2 names matches
    [ -n "$query" ] || return 1
    names=$(printf '%s\n' "$table" | cut -f1)
    if printf '%s\n' "$names" | grep -Fxq -- "$query"; then
        printf '%s\n' "$query"
        return 0
    fi
    case "$query" in
    0*|*[!0-9]*) ;;
    *)
        matches=$(printf '%s\n' "$names" | sed -n "${query}p" 2>/dev/null)
        if [ -n "$matches" ]; then
            printf '%s\n' "$matches"
            return 0
        fi
        ;;
    esac
    matches=$(printf '%s\n' "$names" | grep -iF -- "$query") || {
        _failcat "没有匹配的节点：$query" || true
        return 1
    }
    case "$(printf '%s\n' "$matches" | wc -l | tr -d ' ')" in
    1) printf '%s\n' "$matches" ;;
    *)
        _failcat "匹配到多个节点，请写更完整的名称或用序号：" || true
        printf '%s\n' "$matches" | sed 's/^/    /' >&2
        return 1
        ;;
    esac
}

_node_select() {
    local group=$1 node=$2 body
    body=$(NODE_NAME=$node "$BIN_YQ" -n -o json -I 0 '{"name": strenv(NODE_NAME)}') || return 1
    _node_api PUT "/proxies/$(_node_urlencode "$group")" "$body" >/dev/null 2>&1 || {
        _failcat "切换失败：策略组 $group 不支持手动选择" || true
        return 1
    }
    _okcat '🚀' "$group → $node"
}

# Drop outbounds that would "win" a speed test without proxying anything,
# nested groups, and the informational pseudo-nodes providers like to add.
_node_rank() {
    awk -F '\t' '
        $2 ~ /^(Selector|URLTest|Fallback|LoadBalance|Relay|Smart|Direct|Reject|RejectDrop|Pass|Compatible|Dns)$/ { next }
        $1 ~ /剩余|流量|到期|过期|套餐|官网|重置/ { next }
        $3 + 0 > 0 { print }' | sort -t "$(printf '\t')" -k3,3n
}

_node_test() {
    local group=$1 url
    url=$(_node_urlencode "$MIHOMO_NODE_TEST_URL")
    _okcat '⏳' "正在测速：$group ..."
    # The API fails as a whole when every node times out; the table shows that.
    _node_api GET "/group/$(_node_urlencode "$group")/delay?url=${url}&timeout=${MIHOMO_NODE_TEST_TIMEOUT}" \
        >/dev/null 2>&1 || true
}

_node_groups() {
    _node_api GET /proxies | "$BIN_YQ" -p json -o tsv '
        [.proxies[] | select(.all != null and .name != "GLOBAL") |
            [.name, .type, .now // ""]]' |
        awk -F '\t' '{ printf "  %s [%s] → %s\n", $1, $2, $3 }'
}

_node_usage() {
    cat <<'EOF'
用法: clash node [命令] [-g 策略组]
    (无参数)          列出节点，交互选择
    ls                列出节点和最近延迟
    use <序号|名称>   切换节点，名称可以只写一部分
    test              对所有节点测速
    best              测速并切换到延迟最低的节点
    groups            列出策略组及当前选择
默认操作第一个 select 策略组。
EOF
}

function clashnode() {
    local action='' group='' query='' table now best answer
    while [ $# -gt 0 ]; do
        case "$1" in
        -g|--group)
            [ $# -ge 2 ] || { _node_usage; return 1; }
            group=$2
            shift 2
            ;;
        -h|--help|help)
            _node_usage
            return 0
            ;;
        *)
            if [ -z "$action" ]; then action=$1; else query="${query:+$query }$1"; fi
            shift
            ;;
        esac
    done
    case "$action" in
    ''|ls|list|use|test|best|groups) ;;
    *) _node_usage; return 1 ;;
    esac
    is_mihomo_running || {
        _failcat "代理未运行，请先执行 clash on" || true
        return 1
    }
    _get_ui_port

    if [ "$action" = groups ]; then
        _node_groups
        return
    fi

    [ -n "$group" ] || group=$(_node_default_group)
    case "$action" in test|best) _node_test "$group" ;; esac
    table=$(_node_table "$group" 2>/dev/null)
    [ -n "$table" ] || {
        _failcat "读不到策略组 ${group}；用 clash node groups 查看可用策略组" || true
        return 1
    }

    case "$action" in
    use)
        [ -n "$query" ] || { _node_usage; return 1; }
        best=$(_node_resolve "$table" "$query") || return 1
        _node_select "$group" "$best"
        ;;
    best)
        best=$(printf '%s\n' "$table" | _node_rank | head -n 1)
        [ -n "$best" ] || {
            _failcat "没有可用节点：请检查订阅是否过期（clash update），或服务器网络是否受限" || true
            return 1
        }
        _node_select "$group" "$(printf '%s' "$best" | cut -f1)" || return 1
        _okcat '⚡' "延迟 $(printf '%s' "$best" | cut -f3)ms"
        ;;
    *)
        now=$(_node_now "$group")
        _okcat "策略组：$group"
        _node_print "$table" "$now"
        [ -z "$action" ] && _has_tty || return 0
        printf '输入序号或名称切换（回车取消）: '
        IFS= read -r answer || return 0
        [ -n "$answer" ] || return 0
        best=$(_node_resolve "$table" "$answer") || return 1
        _node_select "$group" "$best"
        ;;
    esac
}
