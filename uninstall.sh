#!/usr/bin/env bash
# shellcheck disable=SC1091

SCRIPT_SOURCE="${BASH_SOURCE[0]:-$0}"
SCRIPT_DIR="$(cd -- "$(dirname -- "$SCRIPT_SOURCE")" && pwd -P)"
cd "$SCRIPT_DIR" || exit 1
. "${SCRIPT_DIR}/script/common.sh"
. "${SCRIPT_DIR}/script/upgrade.sh"
. "${SCRIPT_DIR}/script/clashctl.sh"

_valid_env || exit 1

UNINSTALL_LOCK_HELD=false
MIHOMO_OPERATION_LOCK_HELD=false

_uninstall_cleanup() {
    local status=$?
    trap - EXIT HUP INT TERM
    if [ "$UNINSTALL_LOCK_HELD" = true ]; then
        _upgrade_release_lock
    fi
    exit "$status"
}

_uninstall_fail() {
    _failcat "$1" || true
    exit 1
}

trap _uninstall_cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

_upgrade_acquire_lock || _uninstall_fail "另一个 mihomo 操作正在运行，已取消卸载"
UNINSTALL_LOCK_HELD=true
MIHOMO_OPERATION_LOCK_HELD=true

case "$MIHOMO_BASE_DIR" in
"$HOME"/tools/mihomo) ;;
*) _uninstall_fail "拒绝卸载非标准路径：$MIHOMO_BASE_DIR" ;;
esac
[ -d "$MIHOMO_BASE_DIR" ] && [ ! -L "$MIHOMO_BASE_DIR" ] ||
    _uninstall_fail "安装目录不存在或类型异常：$MIHOMO_BASE_DIR"

_watchdog_stop 2>/dev/null || true
was_running=false
is_mihomo_running && was_running=true
stop_mihomo >/dev/null || _uninstall_fail "mihomo 未能停止，已取消卸载"

recovery_dir=$(mktemp -d "$(dirname "$MIHOMO_BASE_DIR")/.mihomo-uninstall.XXXXXX") ||
    _uninstall_fail "无法创建卸载临时目录"
quarantine="${recovery_dir}/mihomo"
if ! mv "$MIHOMO_BASE_DIR" "$quarantine"; then
    rmdir "$recovery_dir" 2>/dev/null || true
    [ "$was_running" = false ] || start_mihomo >/dev/null 2>&1 || true
    _uninstall_fail "无法移动安装目录，已取消卸载"
fi

if ! _set_rc unset; then
    if mv "$quarantine" "$MIHOMO_BASE_DIR"; then
        rmdir "$recovery_dir" 2>/dev/null || true
        _set_rc >/dev/null 2>&1 || true
        [ "$was_running" = false ] || start_mihomo >/dev/null 2>&1 || true
        _uninstall_fail "清理 shell 配置失败，安装目录已恢复"
    fi
    _uninstall_fail "清理 shell 配置失败，安装目录保存在：$quarantine"
fi

_upgrade_release_lock
UNINSTALL_LOCK_HELD=false
MIHOMO_OPERATION_LOCK_HELD=false

_launcher_remove || true
# The installed copy of this script runs from inside the removed directory.
cd "$HOME" || cd /
if ! rm -rf -- "$recovery_dir"; then
    _failcat "安装入口已移除，但部分文件需要手动清理：$recovery_dir" || true
fi

_okcat '✨' '已卸载 mihomo 用户空间代理'
_okcat '💡' '本程序不会改写用户 crontab；如旧版曾创建 mihomoctl_auto_update，请使用 crontab -e 手动删除该行'
_okcat '📝' '请重新加载 shell 配置或重新登录以清除环境变量'
_quit
