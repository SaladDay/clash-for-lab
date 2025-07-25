#!/bin/bash

# Test script for port assignment logic
source script/common.sh
source script/clashctl.sh

echo "=== 端口分配逻辑测试 ==="
echo

# Create a test runtime config
test_config="/tmp/test_runtime_port.yaml"
cat > "$test_config" << EOF
mixed-port: 17890
external-controller: "0.0.0.0:19090"
dns:
  enable: true
  listen: "0.0.0.0:15353"
proxies:
  - name: test
    type: http
    server: 127.0.0.1
    port: 8080
EOF

echo "1. 测试配置文件:"
cat "$test_config"
echo

echo "2. 测试端口提取函数:"
MIHOMO_CONFIG_RUNTIME="$test_config"

echo "测试 _get_proxy_port..."
_get_proxy_port
echo "MIXED_PORT = $MIXED_PORT"

echo "测试 _get_ui_port..."
_get_ui_port  
echo "UI_PORT = $UI_PORT"

echo "测试 _get_dns_port..."
_get_dns_port
echo "DNS_PORT = $DNS_PORT"
echo

echo "3. 测试端口冲突检测:"
for port in $MIXED_PORT $UI_PORT $DNS_PORT; do
    if _is_already_in_use "$port" "mihomo"; then
        echo "端口 $port: 被其他进程占用"
    else
        echo "端口 $port: 可用"
    fi
done
echo

echo "4. 测试随机端口生成:"
echo "生成5个随机端口:"
for i in {1..5}; do
    random_port=$(_get_random_port)
    echo "随机端口 $i: $random_port"
done
echo

echo "5. 模拟端口更新:"
echo "模拟更新代理端口..."
new_port=$(_get_random_port)
"$BIN_YQ" -i ".mixed-port = $new_port" "$test_config"
echo "更新后的配置:"
"$BIN_YQ" '.mixed-port' "$test_config"
echo

# Clean up
rm -f "$test_config"

echo "=== 测试完成 ==="
echo
echo "修复说明:"
echo "1. 端口冲突检查现在在mihomo启动前进行"
echo "2. 所有端口冲突都会在配置文件中更新"
echo "3. 环境变量使用的端口与实际监听端口一致"
echo "4. 端口变更会显示详细信息"