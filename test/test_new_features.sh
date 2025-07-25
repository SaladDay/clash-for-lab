#!/bin/bash

# Test script for new clash features
source script/common.sh
source script/clashctl.sh

echo "=== 测试新功能演示 ==="
echo

echo "1. 查看帮助信息 (显示新命令):"
clash
echo

echo "2. 查看当前订阅地址 (初始状态):"
clashsubscribe
echo

echo "3. 设置测试订阅地址:"
echo "模拟设置订阅地址: https://example.com/subscription"
mkdir -p ~/tools/mihomo
echo "https://example.com/subscription" > ~/tools/mihomo/url
echo "😼 订阅地址已设置: https://example.com/subscription"
echo

echo "4. 再次查看订阅地址:"
clashsubscribe
echo

echo "5. 查看状态 (包含订阅地址):"
clashstatus
echo

echo "6. 测试重启命令 (dry run):"
echo "clash restart - 重启代理服务"
echo "功能: 先关闭代理，再开启代理，实现服务重启"
echo

echo "=== 新功能说明 ==="
echo "✅ restart   - 重启代理服务"
echo "✅ status    - 显示订阅URI和运行状态"  
echo "✅ subscribe - 设置和查看订阅地址"
echo

echo "=== 使用示例 ==="
echo "clash restart                    # 重启代理服务"
echo "clash status                     # 查看状态(含订阅地址)"
echo "clash subscribe                  # 查看当前订阅地址"
echo "clash subscribe https://xxx.com  # 设置新的订阅地址"
echo

echo "=== 测试完成 ==="