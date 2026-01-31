#!/usr/bin/env bash
# shellcheck disable=SC1091
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
. "${SCRIPT_DIR}/script/common.sh"
. "${SCRIPT_DIR}/script/clashctl.sh"

_valid_env || exit 1

# 停止 mihomo 进程
mihomoctl off >&/dev/null

# 移除用户级定时任务
crontab -l 2>/dev/null | grep -v 'mihomoctl_auto_update' | crontab - 2>/dev/null

# 删除用户目录安装
rm -rf "$MIHOMO_BASE_DIR"

# 清理临时资源目录（如果存在）
rm -rf "$RESOURCES_BIN_DIR"

# 清理 shell 配置
_set_rc unset

_okcat '✨' '已卸载 mihomo 用户空间代理，相关配置已清除'
_okcat '📝' '注意：请重新加载 shell 配置或重新登录以清除环境变量'
_quit
