#!/bin/bash

echo "=== 日志解析测试 ==="
echo

# Create a sample log file with the actual format
sample_log="/tmp/sample_mihomo.log"
cat > "$sample_log" << 'EOF'
time="2025-07-25T06:04:29.491642950Z" level=info msg="Start initial configuration in progress"
time="2025-07-25T06:04:29.494316367Z" level=info msg="Geodata Loader mode: memconservative"
time="2025-07-25T06:04:29.494380390Z" level=info msg="Geosite Matcher implementation: succinct"
time="2025-07-25T06:04:29.502220781Z" level=info msg="Initial configuration complete, total time: 10ms"
time="2025-07-25T06:04:29.502836460Z" level=info msg="RESTful API listening at: [::]:19090"
time="2025-07-25T06:04:29.537472967Z" level=info msg="Sniffer is closed"
time="2025-07-25T06:04:29.537853599Z" level=info msg="DNS server(TCP) listening at: [::]:15353"
time="2025-07-25T06:04:29.537973138Z" level=info msg="Mixed(http+socks) proxy listening at: 127.0.0.1:32740"
time="2025-07-25T06:04:29.538028078Z" level=info msg="DNS server(UDP) listening at: [::]:15353"
time="2025-07-25T06:04:29.542062618Z" level=info msg="Start initial Compatible provider 故障转移"
EOF

echo "1. 示例日志内容:"
cat "$sample_log"
echo

echo "2. 测试端口提取:"

echo "提取代理端口..."
actual_proxy_port=$(grep "Mixed(http+socks) proxy listening at:" "$sample_log" | tail -1 | sed -n 's/.*127\.0\.0\.1:\([0-9]*\).*/\1/p')
echo "代理端口: $actual_proxy_port"

echo "提取UI端口..."
actual_ui_port=$(grep "RESTful API listening at:" "$sample_log" | tail -1 | sed -n 's/.*:\([0-9]*\).*/\1/p')
echo "UI端口: $actual_ui_port"

echo "提取DNS端口..."
actual_dns_port=$(grep "DNS server(UDP) listening at:" "$sample_log" | tail -1 | sed -n 's/.*:\([0-9]*\).*/\1/p')
echo "DNS端口: $actual_dns_port"

echo

echo "3. 改进的正则表达式测试:"

echo "代理端口 (改进版):"
actual_proxy_port2=$(grep "Mixed(http+socks) proxy listening at:" "$sample_log" | tail -1 | grep -o '127\.0\.0\.1:[0-9]*' | cut -d: -f2)
echo "代理端口: $actual_proxy_port2"

echo "UI端口 (改进版):"
actual_ui_port2=$(grep "RESTful API listening at:" "$sample_log" | tail -1 | grep -o '\[::\]:[0-9]*' | cut -d: -f3)
echo "UI端口: $actual_ui_port2"

echo "DNS端口 (改进版):"
actual_dns_port2=$(grep "DNS server(UDP) listening at:" "$sample_log" | tail -1 | grep -o '\[::\]:[0-9]*' | cut -d: -f3)
echo "DNS端口: $actual_dns_port2"

echo

echo "4. 更通用的正则表达式:"

echo "代理端口 (通用版):"
actual_proxy_port3=$(grep "Mixed(http+socks) proxy listening at:" "$sample_log" | tail -1 | sed 's/.*listening at: [^:]*:\([0-9]*\).*/\1/')
echo "代理端口: $actual_proxy_port3"

echo "UI端口 (通用版):"
actual_ui_port3=$(grep "RESTful API listening at:" "$sample_log" | tail -1 | sed 's/.*listening at: [^:]*:\([0-9]*\).*/\1/')
echo "UI端口: $actual_ui_port3"

echo "DNS端口 (通用版):"
actual_dns_port3=$(grep "DNS server(UDP) listening at:" "$sample_log" | tail -1 | sed 's/.*listening at: [^:]*:\([0-9]*\).*/\1/')
echo "DNS端口: $actual_dns_port3"

# Clean up
rm -f "$sample_log"

echo
echo "=== 测试完成 ==="
echo "推荐使用通用版正则表达式，因为它能处理IPv4和IPv6地址格式"