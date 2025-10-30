# shellcheck disable=SC2148
# shellcheck disable=SC1091
. script/common.sh >/dev/null 2>&1
. script/clashctl.sh >/dev/null 2>&1

# 用于检查环境是否有效
_valid_env

if [ -d "$MIHOMO_BASE_DIR" ]; then
    _error_quit "请先执行卸载脚本,以清除安装路径：$MIHOMO_BASE_DIR"
fi

_get_kernel

# 创建用户目录结构
mkdir -p "$MIHOMO_BASE_DIR"/{bin,config,logs}

# 解压并安装二进制文件到用户目录
if ! gzip -dc "$ZIP_KERNEL" > "${MIHOMO_BASE_DIR}/bin/$BIN_KERNEL_NAME"; then
    _error_quit "解压内核文件失败: $ZIP_KERNEL"
fi
chmod +x "${MIHOMO_BASE_DIR}/bin/$BIN_KERNEL_NAME"

if ! tar -xf "$ZIP_SUBCONVERTER" -C "${MIHOMO_BASE_DIR}/bin"; then
    _error_quit "解压 subconverter 失败: $ZIP_SUBCONVERTER"
fi

if ! tar -xf "$ZIP_YQ" -C "${MIHOMO_BASE_DIR}/bin"; then
    _error_quit "解压 yq 失败: $ZIP_YQ"
fi

if [ -f "${MIHOMO_BASE_DIR}/bin"/yq_* ]; then
    mv "${MIHOMO_BASE_DIR}/bin"/yq_* "${MIHOMO_BASE_DIR}/bin/yq"
fi
chmod +x "${MIHOMO_BASE_DIR}/bin/yq"

# 设置二进制文件路径
_set_bin

# 验证或获取配置文件
url=""
if ! _valid_config "$RESOURCES_CONFIG"; then
    echo -n "$(_okcat '✈️ ' '输入订阅：')"
    read -r url
    _okcat '⏳' '正在下载...'

    if ! _download_config "$RESOURCES_CONFIG" "$url"; then
        _error_quit "下载失败: 请将配置内容写入 $RESOURCES_CONFIG 后重新安装"
    fi

    if ! _valid_config "$RESOURCES_CONFIG"; then
        _error_quit "配置无效，请检查配置：$RESOURCES_CONFIG，转换日志：$BIN_SUBCONVERTER_LOG"
    fi
fi
_okcat '✅' '配置可用'

if [ -n "$url" ]; then
    echo "$url" > "$MIHOMO_CONFIG_URL"
fi

cp -rf "$SCRIPT_BASE_DIR" "$MIHOMO_BASE_DIR/"
cp "$RESOURCES_BASE_DIR"/*.yaml "$MIHOMO_BASE_DIR/" 2>/dev/null || true
cp "$RESOURCES_BASE_DIR"/*.mmdb "$MIHOMO_BASE_DIR/" 2>/dev/null || true

if ! tar -xf "$ZIP_UI" -C "$MIHOMO_BASE_DIR"; then
    _error_quit "解压 UI 文件失败: $ZIP_UI"
fi

# 设置 shell 配置
_set_rc

# 启动代理服务（会自动合并配置和检查端口冲突）
mihomoctl on

# 显示 Web UI 信息（启动后显示实际端口）
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

_quit
