# shellcheck disable=SC2148
# shellcheck disable=SC1091
. script/common.sh >&/dev/null
. script/clashctl.sh >&/dev/null

# 用于检查环境是否有效
_valid_env

[ -d "$MIHOMO_BASE_DIR" ] && _error_quit "请先执行卸载脚本,以清除安装路径：$MIHOMO_BASE_DIR"

_get_kernel

# 创建用户目录结构
mkdir -p "$MIHOMO_BASE_DIR"/{bin,config,logs}

# 解压并安装二进制文件到用户目录
gzip -dc "$ZIP_KERNEL" > "${MIHOMO_BASE_DIR}/bin/$BIN_KERNEL_NAME"
chmod +x "${MIHOMO_BASE_DIR}/bin/$BIN_KERNEL_NAME"

tar -xf "$ZIP_SUBCONVERTER" -C "${MIHOMO_BASE_DIR}/bin"
tar -xf "$ZIP_YQ" -C "${MIHOMO_BASE_DIR}/bin"

# 重命名 yq 二进制文件
mv "${MIHOMO_BASE_DIR}/bin"/yq_* "${MIHOMO_BASE_DIR}/bin/yq" 2>/dev/null || true
chmod +x "${MIHOMO_BASE_DIR}/bin/yq"

# 设置二进制文件路径
_set_bin

# 验证或获取配置文件
_valid_config "$RESOURCES_CONFIG" || {
    echo -n "$(_okcat '✈️ ' '输入订阅：')"
    read -r url
    _okcat '⏳' '正在下载...'
    _download_config "$RESOURCES_CONFIG" "$url" || _error_quit "下载失败: 请将配置内容写入 $RESOURCES_CONFIG 后重新安装"
    _valid_config "$RESOURCES_CONFIG" || _error_quit "配置无效，请检查配置：$RESOURCES_CONFIG，转换日志：$BIN_SUBCONVERTER_LOG"
}
_okcat '✅' '配置可用'

[ -n "$url" ] && echo "$url" > "$MIHOMO_CONFIG_URL"

cp -rf "$SCRIPT_BASE_DIR" "$MIHOMO_BASE_DIR/"
find "$RESOURCES_BASE_DIR" -maxdepth 1 -type f \( -name "*.yaml" -o -name "*.mmdb" \) -exec cp {} "$MIHOMO_BASE_DIR/" \;

tar -xf "$ZIP_UI" -C "$MIHOMO_BASE_DIR"

# 设置 shell 配置
_set_rc

_set_bin

mkdir -p "$(dirname "$MIHOMO_CONFIG_RUNTIME")"
"$BIN_YQ" eval-all '. as $item ireduce ({}; . *+ $item) | (.. | select(tag == "!!seq")) |= unique' \
    "$MIHOMO_CONFIG_MIXIN" "$MIHOMO_CONFIG_RAW" "$MIHOMO_CONFIG_MIXIN" > "$MIHOMO_CONFIG_RUNTIME"

_okcat '🔧' '检查端口冲突...'
_resolve_port_conflicts "$MIHOMO_CONFIG_RUNTIME"

# 显示 Web UI 信息
clashui

_okcat '🎉' 'mihomo 用户空间代理已安装完成！'
_okcat '📝' '使用说明：'
_okcat '💡' '命令前缀: clash | mihomo | mihomoctl'
_okcat '  • 开启/关闭: clash on/off'
_okcat '  • 重启服务: clash restart'
_okcat '  • 查看状态: clash status'
_okcat '  • Web控制台: clash ui'
_okcat '  • 更新订阅: clash update [auto|log]'
_okcat '  • 设置订阅: clash subscribe [URL]'
_okcat '  • 系统代理: clash proxy [on|off]'
_okcat ''
_okcat '🏠' "安装目录: $MIHOMO_BASE_DIR"
_okcat '📁' "配置目录: $MIHOMO_BASE_DIR/config/"
_okcat '📋' "日志目录: $MIHOMO_BASE_DIR/logs/"

# 启动代理服务
mihomoctl on

_quit
