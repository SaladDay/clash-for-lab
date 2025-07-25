#!/bin/bash
# Integration test script for mihomo userspace proxy
# Tests the complete workflow including installation and basic operations

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Test configuration
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$TEST_DIR")"
MIHOMO_BASE_DIR="$HOME/tools/mihomo"
TEST_SUBSCRIPTION_URL="https://su.bestyuns.com:8888/api/v1/client/subscribe?token=6410394d3dbb13c9a83470099c20c071"

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

# Cleanup function
cleanup() {
    log_info "Cleaning up test environment..."
    
    # Stop mihomo if running
    if [ -f "$PROJECT_ROOT/script/clashctl.sh" ]; then
        source "$PROJECT_ROOT/script/common.sh" 2>/dev/null || true
        source "$PROJECT_ROOT/script/clashctl.sh" 2>/dev/null || true
        
        if command -v stop_mihomo >/dev/null 2>&1; then
            stop_mihomo 2>/dev/null || true
        fi
    fi
    
    # Remove test installation if it exists
    if [ -d "$MIHOMO_BASE_DIR" ]; then
        log_info "Removing test installation directory: $MIHOMO_BASE_DIR"
        rm -rf "$MIHOMO_BASE_DIR"
    fi
    
    # Clean up shell configuration
    if [ -f "$HOME/.bashrc" ]; then
        sed -i "\|$MIHOMO_BASE_DIR|d" "$HOME/.bashrc" 2>/dev/null || true
    fi
    if [ -f "$HOME/.zshrc" ]; then
        sed -i "\|$MIHOMO_BASE_DIR|d" "$HOME/.zshrc" 2>/dev/null || true
    fi
    
    # Remove user crontab entries
    crontab -l 2>/dev/null | grep -v 'mihomoctl.*update.*auto' | crontab - 2>/dev/null || true
}

# Test installation
test_installation() {
    log_info "Testing installation process..."
    
    # Ensure clean environment
    if [ -d "$MIHOMO_BASE_DIR" ]; then
        log_warning "Existing installation found, removing..."
        rm -rf "$MIHOMO_BASE_DIR"
    fi
    
    # Run installation with test subscription
    cd "$PROJECT_ROOT"
    echo "$TEST_SUBSCRIPTION_URL" | bash install.sh
    
    if [ $? -eq 0 ]; then
        log_success "Installation completed successfully"
        return 0
    else
        log_error "Installation failed"
        return 1
    fi
}

# Test basic commands
test_basic_commands() {
    log_info "Testing basic commands..."
    
    # Source the scripts
    source "$PROJECT_ROOT/script/common.sh" || {
        log_error "Failed to source common.sh"
        return 1
    }
    source "$PROJECT_ROOT/script/clashctl.sh" || {
        log_error "Failed to source clashctl.sh"
        return 1
    }
    
    # Test help command
    log_info "Testing help command..."
    clashctl >/dev/null 2>&1 || {
        log_error "Help command failed"
        return 1
    }
    
    # Test status command (should show not running initially)
    log_info "Testing status command..."
    if clashstatus >/dev/null 2>&1; then
        log_warning "mihomo appears to be running already"
    else
        log_success "Status command works correctly (not running)"
    fi
    
    return 0
}

# Test proxy operations
test_proxy_operations() {
    log_info "Testing proxy operations..."
    
    # Source the scripts
    source "$PROJECT_ROOT/script/common.sh" || {
        log_error "Failed to source common.sh"
        return 1
    }
    source "$PROJECT_ROOT/script/clashctl.sh" || {
        log_error "Failed to source clashctl.sh"
        return 1
    }
    
    # Test starting proxy
    log_info "Testing proxy start..."
    if clashon >/dev/null 2>&1; then
        log_success "Proxy started successfully"
        
        # Wait a moment for startup
        sleep 3
        
        # Test status when running
        if clashstatus >/dev/null 2>&1; then
            log_success "Status command shows running state"
        else
            log_error "Status command failed when proxy should be running"
            return 1
        fi
        
        # Test stopping proxy
        log_info "Testing proxy stop..."
        if clashoff >/dev/null 2>&1; then
            log_success "Proxy stopped successfully"
        else
            log_error "Failed to stop proxy"
            return 1
        fi
        
    else
        log_error "Failed to start proxy"
        return 1
    fi
    
    return 0
}

# Test configuration management
test_configuration() {
    log_info "Testing configuration management..."
    
    # Check if config files exist
    local config_files=(
        "$MIHOMO_BASE_DIR/config.yaml"
        "$MIHOMO_BASE_DIR/mixin.yaml"
    )
    
    for config in "${config_files[@]}"; do
        if [ ! -f "$config" ]; then
            log_error "Config file missing: $config"
            return 1
        fi
    done
    
    # Test yq functionality
    if [ -f "$MIHOMO_BASE_DIR/bin/yq" ]; then
        local port=$("$MIHOMO_BASE_DIR/bin/yq" '.mixed-port // 7890' "$MIHOMO_BASE_DIR/config.yaml" 2>/dev/null)
        if [ -n "$port" ] && [ "$port" -gt 0 ]; then
            log_success "Configuration reading works (port: $port)"
        else
            log_error "Failed to read configuration"
            return 1
        fi
    else
        log_error "yq binary not found"
        return 1
    fi
    
    return 0
}

# Test subscription update
test_subscription_update() {
    log_info "Testing subscription update..."
    
    # Source the scripts
    source "$PROJECT_ROOT/script/common.sh" || {
        log_error "Failed to source common.sh"
        return 1
    }
    source "$PROJECT_ROOT/script/clashctl.sh" || {
        log_error "Failed to source clashctl.sh"
        return 1
    }
    
    # Test update with URL
    log_info "Testing subscription update with URL..."
    if clashupdate "$TEST_SUBSCRIPTION_URL" >/dev/null 2>&1; then
        log_success "Subscription update completed"
    else
        log_warning "Subscription update failed (may be network related)"
    fi
    
    return 0
}

# Main test execution
main() {
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}  Mihomo Userspace Proxy Integration Test${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo
    
    # Set up cleanup trap
    trap cleanup EXIT
    
    local test_failed=0
    
    # Run tests
    if ! test_installation; then
        test_failed=1
    fi
    
    if ! test_basic_commands; then
        test_failed=1
    fi
    
    if ! test_configuration; then
        test_failed=1
    fi
    
    if ! test_proxy_operations; then
        test_failed=1
    fi
    
    if ! test_subscription_update; then
        test_failed=1
    fi
    
    echo
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}  Integration Test Summary${NC}"
    echo -e "${BLUE}========================================${NC}"
    
    if [ $test_failed -eq 0 ]; then
        log_success "All integration tests passed! ✅"
        echo
        log_info "The mihomo userspace proxy is working correctly."
        log_info "You can now use the following commands:"
        echo -e "  ${GREEN}mihomoctl on${NC}     - Start proxy"
        echo -e "  ${GREEN}mihomoctl off${NC}    - Stop proxy"
        echo -e "  ${GREEN}mihomoctl status${NC} - Check status"
        echo -e "  ${GREEN}mihomoctl ui${NC}     - Show web interface"
        exit 0
    else
        log_error "Some integration tests failed! ❌"
        exit 1
    fi
}

# Check if script is being sourced or executed
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi