#!/usr/bin/env bash
# shellcheck disable=SC1091
SCRIPT_SOURCE="${BASH_SOURCE[0]:-$0}"
SCRIPT_DIR="$(cd -- "$(dirname -- "$SCRIPT_SOURCE")" && pwd -P)"
cd "$SCRIPT_DIR" || exit 1
. "${SCRIPT_DIR}/script/common.sh"
. "${SCRIPT_DIR}/script/upgrade.sh"
. "${SCRIPT_DIR}/script/clashctl.sh"
. "${SCRIPT_DIR}/script/install-lib.sh"

INSTALL_OWNS_BASE=false
INSTALL_LOCK_HELD=false
INSTALL_RC_TOUCHED=false
INSTALL_SERVICE_TOUCHED=false
MIHOMO_OPERATION_LOCK_HELD=false

_install_generate_api_secret() {
    local secret
    [ -r /dev/urandom ] || return 1
    secret=$(LC_ALL=C od -An -N 32 -tx1 /dev/urandom 2>/dev/null | tr -d '[:space:]') || return 1
    case "$secret" in
    ''|*[!0-9a-f]*) return 1 ;;
    esac
    [ "${#secret}" -eq 64 ] || return 1
    printf '%s\n' "$secret"
}

_install_secure_mixin() {
    local mixin=$1 secret candidate
    secret=$(_install_generate_api_secret) || return 1
    candidate=$(mktemp "${mixin}.secure.XXXXXX") || return 1
    if ! LC_ALL=C awk -v secret="$secret" '
        /^secret:[[:space:]]*$/ && !replaced {
            print "secret: \"" secret "\""
            replaced = 1
            next
        }
        { print }
        END { if (!replaced) exit 1 }
    ' "$mixin" > "$candidate"; then
        rm -f "$candidate"
        return 1
    fi
    chmod 0600 "$candidate" || {
        rm -f "$candidate"
        return 1
    }
    mv -f "$candidate" "$mixin"
}

_install_cleanup() {
    local exit_status=$1 cleanup_ok=true
    trap - EXIT HUP INT TERM
    if [ "$INSTALL_OWNS_BASE" = true ]; then
        _stop_convert >/dev/null 2>&1 || cleanup_ok=false
        if [ "$INSTALL_SERVICE_TOUCHED" = true ]; then
            stop_mihomo >/dev/null 2>&1 || cleanup_ok=false
        fi
        if [ "$INSTALL_RC_TOUCHED" = true ]; then
            _set_rc unset >/dev/null 2>&1 || cleanup_ok=false
        fi
        if [ "$cleanup_ok" = true ]; then
            case "$MIHOMO_BASE_DIR" in
            "$HOME"/tools/mihomo) rm -rf -- "$MIHOMO_BASE_DIR" ;;
            *) cleanup_ok=false ;;
            esac
        fi
        [ "$cleanup_ok" = true ] ||
            _failcat "安装失败，自动清理未完成，请检查：$MIHOMO_BASE_DIR" || true
    fi
    if [ "$INSTALL_LOCK_HELD" = true ]; then
        _upgrade_release_lock
    fi
    exit "$exit_status"
}

_error_quit() {
    [ $# -gt 0 ] && _failcat "$1" || true
    exit 1
}

trap '_install_cleanup $?' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# Data and helpers that both a fresh install and a refresh must provide.
# Existing GEO files are kept: users may have replaced them.
_install_support_files() {
    local data
    for data in "$RESOURCES_BASE_DIR"/*.mmdb "$RESOURCES_BASE_DIR"/*.dat; do
        [ -f "$data" ] || continue
        [ -e "$MIHOMO_BASE_DIR/${data##*/}" ] ||
            cp "$data" "$MIHOMO_BASE_DIR/" || return 1
    done
    if [ -f uninstall.sh ]; then
        cp uninstall.sh "$MIHOMO_BASE_DIR/uninstall.sh" || return 1
    fi
}

_install_launcher() {
    command -v _launcher_install >/dev/null 2>&1 || return 0
    _launcher_install || _failcat '未能创建 ~/.local/bin/clash，不影响使用' || true
}

_install_is_complete() {
    [ -x "${MIHOMO_BASE_DIR}/bin/mihomo" ] && [ -x "${MIHOMO_BASE_DIR}/bin/yq" ] &&
        [ -f "${MIHOMO_SCRIPT_DIR}/common.sh" ] && [ -f "$MIHOMO_CONFIG_RAW" ]
}

# Running the installer again is an update, never a dead end.
_install_update_existing() {
    _okcat '🔄' '检测到已安装，升级管理脚本并保留现有配置'
    _install_script_release || _error_quit "刷新管理脚本失败"
    _install_support_files || _error_quit "更新支持文件失败"
    _install_launcher
    if [ -n "$INSTALL_URL" ]; then
        clashupdate "$INSTALL_URL" || _error_quit "订阅更新失败，原配置未改动"
    fi
    if ! is_mihomo_running; then
        clashon || _error_quit "mihomo 启动失败，请用 clash log 查看原因"
    fi
}

_install_check_connectivity() {
    local auth secret
    _okcat '⏳' '正在检测能否通过代理访问外网...'
    _get_proxy_port
    _get_ui_port
    auth=$("$BIN_YQ" '.authentication[0] // ""' "$MIHOMO_CONFIG_RUNTIME" 2>/dev/null)
    secret=$("$BIN_YQ" '.secret // ""' "$MIHOMO_CONFIG_RUNTIME" 2>/dev/null)
    MIHOMO_PROBE_TIMEOUT=10
    case "$(_connectivity_check "$UI_PORT" "$MIXED_PORT" "$secret" "$auth")" in
    ok|api_fail) _okcat '✅' "代理可用：http://127.0.0.1:${MIXED_PORT}" ;;
    *) _failcat '⚠️' '代理已启动，但当前节点不通；执行 clash node best 自动选择可用节点' || true ;;
    esac
}

_install_finish() {
    command -v _connectivity_check >/dev/null 2>&1 && _install_check_connectivity
    _okcat '🎉' '安装完成，新开的终端会自动使用代理'
    cat <<'EOF'

  clash node         选择节点          clash status   查看状态
  clash node best    自动选最快节点    clash off/on   关闭/开启
  clash update       更新订阅          clash help     全部命令

EOF
    if [ -z "${CLASH_INSTALL_NO_SHELL:-}" ] && [ -t 0 ] && [ -t 1 ]; then
        cd "$HOME" || true
        _quit
    fi
    _okcat '💡' "当前终端立即生效：exec ${SHELL:-bash}"
}

# Give a mistyped URL another chance instead of throwing the install away.
_install_prompt_url() {
    local attempt=0
    while [ "$attempt" -lt 3 ]; do
        printf '%s' "$(_okcat '✈️ ' '输入订阅地址：')"
        IFS= read -r url || {
            printf '\n'
            _error_quit "没有可用终端输入订阅地址，请执行：bash install.sh '订阅地址'"
        }
        url=$(printf '%s' "$url" | tr -d '[:space:]')
        _is_valid_subscription_url "$url" && return 0
        _failcat '订阅地址必须以 http:// 或 https:// 开头' || true
        attempt=$((attempt + 1))
    done
    return 1
}

INSTALL_URL=""

while [ $# -gt 0 ]; do
    case "$1" in
    --refresh)
        _valid_upgrade_env || exit 1
        _upgrade_acquire_lock || _error_quit "另一个 mihomo 操作正在运行"
        INSTALL_LOCK_HELD=true
        MIHOMO_OPERATION_LOCK_HELD=true
        if [ ! -x "${MIHOMO_BASE_DIR}/bin/mihomo" ] || [ ! -f "${MIHOMO_SCRIPT_DIR}/common.sh" ]; then
            _error_quit "未检测到完整安装，无法刷新管理脚本：$MIHOMO_BASE_DIR"
        fi
        if [ ! -x "${MIHOMO_BASE_DIR}/bin/yq" ]; then
            _error_quit "已安装环境缺少 yq，无法启用内核升级：${MIHOMO_BASE_DIR}/bin/yq"
        fi
        _install_script_release || _error_quit "刷新管理脚本失败"
        _install_support_files || _error_quit "更新支持文件失败"
        _install_launcher
        _upgrade_release_lock
        INSTALL_LOCK_HELD=false
        MIHOMO_OPERATION_LOCK_HELD=false
        _okcat '✅' '管理脚本已刷新'
        _okcat '💡' '重新登录后可使用 clash upgrade'
        exit 0
        ;;
    --url)
        [ $# -ge 2 ] || _error_quit "--url 需要一个参数"
        INSTALL_URL=$2
        shift 2
        ;;
    http://*|https://*)
        INSTALL_URL=$1
        shift
        ;;
    --)
        shift
        break
        ;;
    *)
        _error_quit "未知参数：$1（用法：bash install.sh ['订阅地址']）"
        ;;
    esac
done

if [ -n "$INSTALL_URL" ]; then
    _is_valid_subscription_url "$INSTALL_URL" ||
        _error_quit "--url 订阅地址无效，必须是完整的小写 http:// 或 https:// URL"
fi

# 用于检查环境是否有效
_valid_install_env || exit 1
_upgrade_acquire_lock || _error_quit "另一个 mihomo 操作正在运行"
INSTALL_LOCK_HELD=true
MIHOMO_OPERATION_LOCK_HELD=true

if [ -d "$MIHOMO_BASE_DIR" ] && [ ! -L "$MIHOMO_BASE_DIR" ] && _install_is_complete; then
    _install_update_existing
    _upgrade_release_lock
    INSTALL_LOCK_HELD=false
    MIHOMO_OPERATION_LOCK_HELD=false
    _install_finish
    exit 0
fi

[ ! -e "$MIHOMO_BASE_DIR" ] && [ ! -L "$MIHOMO_BASE_DIR" ] ||
    _error_quit "安装目录已存在但不完整：$MIHOMO_BASE_DIR
   请先执行 bash uninstall.sh，或把该目录移走后重试"

# 创建用户目录结构
mkdir -p "$(dirname "$MIHOMO_BASE_DIR")" || _error_quit "创建安装父目录失败：$(dirname "$MIHOMO_BASE_DIR")"
mkdir "$MIHOMO_BASE_DIR" || _error_quit "无法原子创建安装目录：$MIHOMO_BASE_DIR"
INSTALL_OWNS_BASE=true
mkdir -p "$MIHOMO_BASE_DIR"/{bin,config,logs,state,tmp} || _error_quit "创建安装子目录失败：$MIHOMO_BASE_DIR"

# 先安装管理依赖，再安装经过 CI 校验的稳定版 mihomo。
if ! tar -xf "$ZIP_SUBCONVERTER" -C "${MIHOMO_BASE_DIR}/bin"; then
    _error_quit "解压 subconverter 失败: $ZIP_SUBCONVERTER"
fi

if ! tar -xf "$ZIP_YQ" -C "${MIHOMO_BASE_DIR}/bin"; then
    _error_quit "解压 yq 失败: $ZIP_YQ"
fi

# 重命名 yq 二进制文件（yq_linux_amd64 -> yq）
for yq_file in "${MIHOMO_BASE_DIR}/bin"/yq_*; do
    if [ -f "$yq_file" ]; then
        mv "$yq_file" "${MIHOMO_BASE_DIR}/bin/yq"
        break
    fi
done
chmod +x "${MIHOMO_BASE_DIR}/bin/yq" || _error_quit "设置 yq 权限失败"

if ! _install_bundled_mihomo "$MIHOMO_BUNDLE_LOCK" "$ZIP_BASE_DIR" "${MIHOMO_BASE_DIR}/bin/mihomo"; then
    _error_quit "安装 mihomo 稳定版失败，请检查 resources/mihomo.lock.tsv 和内核包"
fi

# 设置二进制文件路径
_set_bin

install_validation_home="${MIHOMO_BASE_DIR}/tmp/install-validation-home"
install_data_manifest="${MIHOMO_BASE_DIR}/tmp/install-validation-data.manifest"

# Mihomo resolves GEO databases and relative provider paths from its HomeDir.
# Install local data before validating a candidate stored under tmp/.
_install_support_files || _error_quit "安装配置数据失败"

# 仓库配置只作为只读输入；校验和下载在安装目录的临时文件中进行。
install_config_candidate=$(mktemp "${MIHOMO_BASE_DIR}/tmp/install-config.XXXXXX") ||
    _error_quit "创建配置暂存文件失败"
url=""
repo_config_usable=false
if [ -f "$RESOURCES_CONFIG" ] &&
    cp "$RESOURCES_CONFIG" "$install_config_candidate" &&
    _valid_config "$install_config_candidate" "$MIHOMO_BASE_DIR" \
        "$install_validation_home"; then
    repo_config_usable=true
fi

if [ "$repo_config_usable" != true ]; then
    rm -f "$install_config_candidate" || _error_quit "清理无效配置暂存文件失败"
    if [ -n "$INSTALL_URL" ]; then
        url=$INSTALL_URL
    else
        _install_prompt_url || true
    fi
    _is_valid_subscription_url "$url" ||
        _error_quit "订阅地址无效，必须是完整的小写 http:// 或 https:// URL"
    _okcat '⏳' '正在下载...'

    if ! TMPDIR="${MIHOMO_BASE_DIR}/tmp" \
        TMP="${MIHOMO_BASE_DIR}/tmp" \
        TEMP="${MIHOMO_BASE_DIR}/tmp" \
        _download_config "$install_config_candidate" "$url" "$MIHOMO_BASE_DIR" \
        "$install_validation_home"; then
        _error_quit "下载失败，请检查订阅地址后重试"
    fi
fi
_okcat '✅' '配置可用'

_publish_new_config_validation_data "$install_validation_home" "$MIHOMO_BASE_DIR" \
    "$install_data_manifest" ||
    _error_quit "发布配置所需的离线数据失败"
rm -rf "$install_validation_home" ||
    _error_quit "清理配置验证目录失败"
rm -f "$install_data_manifest" ||
    _error_quit "清理配置数据发布记录失败"

_config_atomic_copy "$install_config_candidate" "$MIHOMO_CONFIG_RAW" ||
    _error_quit "发布配置失败：$MIHOMO_CONFIG_RAW"
rm -f "$install_config_candidate" || _error_quit "清理配置暂存文件失败"

if [ -n "$url" ]; then
    _config_atomic_write "$MIHOMO_CONFIG_URL" "$url" || _error_quit "保存订阅地址失败"
fi

_install_script_release false || _error_quit "安装管理脚本失败"
for resource_yaml in "$RESOURCES_BASE_DIR"/*.yaml; do
    [ -f "$resource_yaml" ] || continue
    [ "$resource_yaml" = "$RESOURCES_CONFIG" ] && continue
    cp "$resource_yaml" "$MIHOMO_BASE_DIR/" || _error_quit "安装配置资源失败：$resource_yaml"
done
_install_secure_mixin "$MIHOMO_CONFIG_MIXIN" ||
    _error_quit "生成本机 Web 控制台密钥失败"

# 解压 zashboard UI。控制台是可选功能，没有解压工具也不能挡住代理本身。
if _extract_zip "$ZIP_UI" "$MIHOMO_BASE_DIR" && [ -d "${MIHOMO_BASE_DIR}/dist" ]; then
    mv "${MIHOMO_BASE_DIR}/dist" "${MIHOMO_BASE_DIR}/ui" || _error_quit "安装 UI 失败"
else
    rm -rf "${MIHOMO_BASE_DIR}/dist"
    _failcat '⚠️' '缺少 unzip 或 python，已跳过 Web 控制台；可用 clash node 管理节点' || true
fi

# 启动代理服务（会自动合并配置和检查端口冲突）
INSTALL_SERVICE_TOUCHED=true
mihomoctl on || _error_quit "mihomo 启动失败，安装已回滚"

# 最后才发布 shell 入口。此时所有大文件、配置和服务均已就绪，避免
# 后续安装失败时留下指向已删除目录的 RC 行。
INSTALL_RC_TOUCHED=true
_set_rc || _error_quit "写入 shell 配置失败"

_install_launcher

INSTALL_OWNS_BASE=false
_upgrade_release_lock
INSTALL_LOCK_HELD=false
MIHOMO_OPERATION_LOCK_HELD=false

_install_finish
