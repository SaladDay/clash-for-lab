#!/bin/bash
# Quick verification script for mihomo userspace proxy installation
# This script performs basic checks to ensure the installation is working

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

MIHOMO_BASE_DIR="$HOME/tools/mihomo"

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[✓]${NC} $1"
}

log_error() {
    echo -e "${RED}[✗]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[!]${NC} $1"
}

# Check if mihomo is installed
check_installation() {
    log_info "检查 mihomo 安装状态..."
    
    if [ ! -d "$MIHOMO_BASE_DIR" ]; then
        log_error "mihomo 未安装，请先运行 install.sh"
        return 1
    fi
    
    local required_files=(
        "$MIHOMO_BASE_DIR/bin/mihomo"
        "$MIHOMO_BASE_DIR/bin/yq"
        "$MIHOMO_BASE_DIR/config.yaml"
        "$MIHOMO_BASE_DIR/mixin.yaml"
        "$MIHOMO_BASE_DIR/script/clashctl.sh"
    )
    
    for file in "${required_files[@]}"; do
        if [ ! -f "$file" ]; then
            log_error "缺少必要文件: $file"
            return 1
        fi
    done
    
    log_success "安装文件检查完成"
    return 0
}

# Check command availability
check_commands() {
    log_info "检查命令可用性..."
    
    # Source the scripts
    if ! source "$MIHOMO_BASE_DIR/script/common.sh" 2>/dev/null; then
        log_error "无法加载 common.sh"
        return 1
    fi
    
    if ! source "$MIHOMO_BASE_DIR/script/clashctl.sh" 2>/dev/null; then
        log_error "无法加载 clashctl.sh"
        return 1
    fi
    
    # Check if commands are available
    local commands=("mihomoctl" "clashctl" "clash" "mihomo")
    for cmd in "${commands[@]}"; do
        if command -v "$cmd" >/dev/null 2>&1; then
            log_success "命令可用: $cmd"
        else
            log_warning "命令不可用: $cmd (可能需要重新加载 shell)"
        fi
    done
    
    return 0
}

# Test basic functionality
test_basic_functionality() {
    log_info "测试基本功能..."
    
    # Source the scripts
    source "$MIHOMO_BASE_DIR/script/common.sh" 2>/dev/null || return 1
    source "$MIHOMO_BASE_DIR/script/clashctl.sh" 2>/dev/null || return 1
    
    # Test help command
    if mihomoctl >/dev/null 2>&1; then
        log_success "帮助命令正常"
    else
        log_error "帮助命令失败"
        return 1
    fi
    
    # Test status command
    if mihomoctl status >/dev/null 2>&1; then
        log_success "mihomo 当前正在运行"
    else
        log_info "mihomo 当前未运行（正常状态）"
    fi
    
    # Test configuration reading
    if [ -f "$MIHOMO_BASE_DIR/bin/yq" ]; then
        local port=$("$MIHOMO_BASE_DIR/bin/yq" '.mixed-port // 7890' "$MIHOMO_BASE_DIR/config.yaml" 2>/dev/null)
        if [ -n "$port" ]; then
            log_success "配置文件读取正常 (代理端口: $port)"
        else
            log_error "配置文件读取失败"
            return 1
        fi
    fi
    
    return 0
}

# Show installation info
show_installation_info() {
    log_info "安装信息："
    echo -e "  安装目录: ${GREEN}$MIHOMO_BASE_DIR${NC}"
    echo -e "  配置目录: ${GREEN}$MIHOMO_BASE_DIR/config/${NC}"
    echo -e "  日志目录: ${GREEN}$MIHOMO_BASE_DIR/logs/${NC}"
    echo
    
    log_info "常用命令："
    echo -e "  ${GREEN}mihomoctl on${NC}      - 启动代理"
    echo -e "  ${GREEN}mihomoctl off${NC}     - 停止代理"
    echo -e "  ${GREEN}mihomoctl status${NC}  - 查看状态"
    echo -e "  ${GREEN}mihomoctl ui${NC}      - 显示 Web 控制台地址"
    echo -e "  ${GREEN}mihomoctl update${NC}  - 更新订阅配置"
    echo
    
    log_info "测试命令："
    echo -e "  ${GREEN}./test/functional_test.sh${NC}   - 运行功能测试"
    echo -e "  ${GREEN}./test/integration_test.sh${NC} - 运行集成测试"
}

# Main function
main() {
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}  Mihomo 用户空间代理 - 安装验证${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo
    
    local verification_failed=0
    
    if ! check_installation; then
        verification_failed=1
    fi
    
    if ! check_commands; then
        verification_failed=1
    fi
    
    if ! test_basic_functionality; then
        verification_failed=1
    fi
    
    echo
    echo -e "${BLUE}========================================${NC}"
    
    if [ $verification_failed -eq 0 ]; then
        log_success "验证完成！mihomo 用户空间代理安装正常 ✅"
        echo
        show_installation_info
    else
        log_error "验证失败！请检查安装或查看错误信息 ❌"
        echo
        log_info "故障排除建议："
        echo "  1. 重新运行安装脚本: bash install.sh"
        echo "  2. 检查网络连接和订阅链接"
        echo "  3. 重新加载 shell 配置: source ~/.bashrc 或 source ~/.zshrc"
        echo "  4. 查看详细测试: ./test/functional_test.sh"
        exit 1
    fi
}

# Run main function
main "$@"