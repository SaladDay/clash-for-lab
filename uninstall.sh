# shellcheck disable=SC2148
# shellcheck disable=SC1091
. script/common.sh >&/dev/null
. script/clashctl.sh >&/dev/null

_valid_env

# 停止 mihomo 进程
mihomoctl off >&/dev/null

# 移除用户级定时任务
crontab -l 2>/dev/null | grep -v 'mihomoctl.*update.*auto' | crontab - 2>/dev/null

# 删除用户目录安装
rm -rf "$MIHOMO_BASE_DIR"

# 清理临时资源目录（如果存在）
rm -rf "$RESOURCES_BIN_DIR"

# 清理 shell 配置
_set_rc unset

_okcat '✨' '已卸载 mihomo 用户空间代理，相关配置已清除'
_okcat '📝' '注意：请重新加载 shell 配置或重新登录以清除环境变量'
_quit
