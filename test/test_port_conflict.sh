#!/bin/bash

# Test script for port conflict handling
source script/common.sh
source script/clashctl.sh

echo "=== 端口冲突处理测试 ==="
echo

echo "1. 检查当前端口占用情况:"
echo "检查常用端口占用..."

# Check common ports
for port in 1053 7890 9090; do
    if _is_bind "$port" >/dev/null 2>&1; then
        echo "端口 $port: 已占用"
        # Show what's using the port
        ss -lnptu 2>/dev/null | grep ":${port}\b" || netstat -lnptu 2>/dev/null | grep ":${port}\b"
    else
        echo "端口 $port: 可用"
    fi
done
echo

echo "2. 测试端口冲突检测函数:"
echo "测试 _is_already_in_use 函数..."

# Test the port conflict detection
test_port="1053"
if _is_already_in_use "$test_port" "mihomo"; then
    echo "✅ 检测到端口 $test_port 被其他进程占用"
else
    echo "ℹ️  端口 $test_port 未被其他进程占用或被mihomo占用"
fi
echo

echo "3. 模拟配置文件端口检查:"
echo "创建临时配置文件进行测试..."

# Create a temporary config for testing
temp_config="/tmp/test_runtime.yaml"
cat > "$temp_config" << EOF
mixed-port: 7890
external-controller: "0.0.0.0:9090"
dns:
  enable: true
  listen: "0.0.0.0:1053"
EOF

echo "临时配置文件内容:"
cat "$temp_config"
echo

# Test port extraction
MIHOMO_CONFIG_RUNTIME="$temp_config"
echo "4. 测试端口提取和冲突处理:"

echo "提取代理端口..."
mixed_port=$("$BIN_YQ" '.mixed-port // ""' "$temp_config" 2>/dev/null || echo "7890")
echo "代理端口: ${mixed_port:-7890}"

echo "提取UI端口..."
ext_addr=$("$BIN_YQ" '.external-controller // ""' "$temp_config" 2>/dev/null || echo "0.0.0.0:9090")
ext_port=${ext_addr##*:}
echo "UI端口: ${ext_port:-9090}"

echo "提取DNS端口..."
dns_listen=$("$BIN_YQ" '.dns.listen // ""' "$temp_config" 2>/dev/null || echo "0.0.0.0:1053")
dns_port=${dns_listen##*:}
echo "DNS端口: ${dns_port:-1053}"

# Clean up
rm -f "$temp_config"
echo

echo "5. 建议解决方案:"
echo "如果遇到端口冲突，脚本会自动:"
echo "- 检测端口占用情况"
echo "- 随机分配新的可用端口"
echo "- 更新配置文件中的端口设置"
echo "- 显示端口变更信息"
echo

echo "6. 手动解决端口冲突:"
echo "如果需要手动指定端口，可以编辑 mixin.yaml:"
echo "vim ~/tools/mihomo/mixin.yaml"
echo
echo "修改以下配置项:"
echo "external-controller: \"0.0.0.0:新端口\"  # Web控制台端口"
echo "mixed-port: 新端口                      # 代理端口"
echo "dns:"
echo "  listen: \"0.0.0.0:新端口\"              # DNS端口"
echo

echo "=== 测试完成 ==="
echo "如果仍有端口冲突，请运行 'clash on' 查看自动端口分配结果"