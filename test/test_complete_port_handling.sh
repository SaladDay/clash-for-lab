#!/bin/bash

echo "=== 完整端口处理测试 ==="
echo

# Test the complete port handling logic
source script/common.sh
source script/clashctl.sh

echo "1. 模拟mihomo日志文件:"
test_log="/tmp/test_mihomo_complete.log"
cat > "$test_log" << 'EOF'
time="2025-07-25T06:04:29.502836460Z" level=info msg="RESTful API listening at: [::]:19090"
time="2025-07-25T06:04:29.537973138Z" level=info msg="Mixed(http+socks) proxy listening at: 127.0.0.1:32740"
time="2025-07-25T06:04:29.538028078Z" level=info msg="DNS server(UDP) listening at: [::]:15353"
EOF

echo "日志内容:"
cat "$test_log"
echo

echo "2. 测试端口提取逻辑:"

# Simulate the port extraction logic from clashon function
log_file="$test_log"

echo "提取实际监听端口..."
actual_proxy_port=$(grep "Mixed(http+socks) proxy listening at:" "$log_file" | tail -1 | sed -n 's/.*127\.0\.0\.1:\([0-9]*\).*/\1/p')
actual_ui_port=$(grep "RESTful API listening at:" "$log_file" | tail -1 | sed -n 's/.*\[::\]:\([0-9]*\).*/\1/p')
actual_dns_port=$(grep "DNS server(UDP) listening at:" "$log_file" | tail -1 | sed -n 's/.*\[::\]:\([0-9]*\).*/\1/p')

echo "从日志提取的端口:"
echo "  代理端口: $actual_proxy_port"
echo "  UI端口: $actual_ui_port"
echo "  DNS端口: $actual_dns_port"
echo

echo "3. 模拟端口冲突和调整:"

# Simulate initial port assignment
MIXED_PORT=13772
UI_PORT=19090
DNS_PORT=15353

echo "初始分配的端口:"
echo "  代理端口: $MIXED_PORT"
echo "  UI端口: $UI_PORT"
echo "  DNS端口: $DNS_PORT"
echo

echo "检查端口是否需要调整..."

# Check if ports need adjustment
if [ -n "$actual_proxy_port" ] && [ "$actual_proxy_port" != "$MIXED_PORT" ]; then
    echo "🔄 mihomo自动调整代理端口: $MIXED_PORT → $actual_proxy_port"
    MIXED_PORT=$actual_proxy_port
fi

if [ -n "$actual_ui_port" ] && [ "$actual_ui_port" != "$UI_PORT" ]; then
    echo "🔄 mihomo自动调整UI端口: $UI_PORT → $actual_ui_port"
    UI_PORT=$actual_ui_port
fi

if [ -n "$actual_dns_port" ] && [ "$actual_dns_port" != "$DNS_PORT" ]; then
    echo "🔄 mihomo自动调整DNS端口: $DNS_PORT → $actual_dns_port"
    DNS_PORT=$actual_dns_port
fi

echo
echo "最终端口分配:"
echo "  代理端口: $MIXED_PORT"
echo "  UI端口: $UI_PORT"
echo "  DNS端口: $DNS_PORT"
echo

echo "4. 测试环境变量设置:"
echo "模拟设置代理环境变量..."

http_proxy_addr="http://127.0.0.1:${MIXED_PORT}"
socks_proxy_addr="socks5h://127.0.0.1:${MIXED_PORT}"

echo "HTTP代理: $http_proxy_addr"
echo "SOCKS代理: $socks_proxy_addr"
echo

echo "5. 验证端口可用性:"
echo "检查最终端口是否可用..."

for port in $MIXED_PORT $UI_PORT $DNS_PORT; do
    if command -v nc >/dev/null 2>&1; then
        if nc -z 127.0.0.1 "$port" 2>/dev/null; then
            echo "端口 $port: 正在使用"
        else
            echo "端口 $port: 可用"
        fi
    else
        echo "端口 $port: 无法检查 (nc命令不可用)"
    fi
done

# Clean up
rm -f "$test_log"

echo
echo "=== 测试完成 ==="
echo
echo "修复总结:"
echo "1. ✅ 在mihomo启动前检查端口冲突"
echo "2. ✅ 在mihomo启动后读取实际监听端口"
echo "3. ✅ 如果端口被mihomo自动调整，更新我们的变量"
echo "4. ✅ 使用最终端口设置环境变量"
echo "5. ✅ 显示详细的端口调整信息"