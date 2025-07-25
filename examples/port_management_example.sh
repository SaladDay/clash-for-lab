#!/bin/bash
# 端口管理示例脚本 - 仅适用于 Linux

# 模拟端口冲突场景
echo "=== 端口管理示例 ==="

# 创建测试目录
mkdir -p /tmp/mihomo_example

# 创建示例配置文件
cat > /tmp/mihomo_example/config.yaml << EOF
mixed-port: 17890
external-controller: 0.0.0.0:19090
dns:
  listen: 0.0.0.0:15353
EOF

# 模拟端口占用
echo "1. 模拟端口 17890 被占用"
nc -l -p 17890 &
NC_PID=$!
sleep 1

# 解决端口冲突
echo "2. 运行端口冲突解决逻辑"
source ../script/common.sh
_set_bin "/tmp/mihomo_example"
MIHOMO_CONFIG_RUNTIME="/tmp/mihomo_example/config.yaml"

_resolve_port_conflicts "$MIHOMO_CONFIG_RUNTIME"

# 显示结果
echo "3. 端口冲突解决结果:"
echo "   代理端口: $MIXED_PORT"
echo "   UI 端口: $UI_PORT"
echo "   DNS 端口: $DNS_PORT"

# 清理
kill $NC_PID 2>/dev/null
rm -rf /tmp/mihomo_example

echo "=== 示例完成 ===" 