#!/bin/bash
# Functional test script for mihomo userspace proxy
# Tests basic functionality without requiring sudo privileges

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

# Source the common functions
source "$PROJECT_ROOT/script/common.sh" 2>/dev/null || {
    echo -e "${RED}Error: Cannot source common.sh${NC}"
    exit 1
}

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Logging
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[PASS]${NC} $1"
    ((TESTS_PASSED++))
}

log_error() {
    echo -e "${RED}[FAIL]${NC} $1"
    ((TESTS_FAILED++))
}

log_warning() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

run_test() {
    local test_name="$1"
    local test_function="$2"
    
    ((TESTS_RUN++))
    log_info "Running test: $test_name"
    
    if $test_function; then
        log_success "$test_name"
    else
        log_error "$test_name"
    fi
    echo
}

# Test functions
test_directory_structure() {
    local required_dirs=(
        "$MIHOMO_BASE_DIR"
        "$MIHOMO_BASE_DIR/bin"
        "$MIHOMO_BASE_DIR/config"
        "$MIHOMO_BASE_DIR/logs"
        "$MIHOMO_BASE_DIR/script"
    )
    
    for dir in "${required_dirs[@]}"; do
        if [ ! -d "$dir" ]; then
            log_error "Required directory missing: $dir"
            return 1
        fi
    done
    
    return 0
}

test_binary_files() {
    local required_binaries=(
        "$MIHOMO_BASE_DIR/bin/mihomo"
        "$MIHOMO_BASE_DIR/bin/yq"
        "$MIHOMO_BASE_DIR/bin/subconverter/subconverter"
    )
    
    for binary in "${required_binaries[@]}"; do
        if [ ! -f "$binary" ]; then
            log_error "Required binary missing: $binary"
            return 1
        fi
        
        if [ ! -x "$binary" ]; then
            log_error "Binary not executable: $binary"
            return 1
        fi
    done
    
    return 0
}

test_config_files() {
    local required_configs=(
        "$MIHOMO_BASE_DIR/config.yaml"
        "$MIHOMO_BASE_DIR/mixin.yaml"
    )
    
    for config in "${required_configs[@]}"; do
        if [ ! -f "$config" ]; then
            log_error "Required config file missing: $config"
            return 1
        fi
    done
    
    return 0
}

test_script_functions() {
    # Source the clashctl script
    source "$PROJECT_ROOT/script/clashctl.sh" 2>/dev/null || {
        log_error "Cannot source clashctl.sh"
        return 1
    }
    
    # Test if key functions are defined
    local required_functions=(
        "clashctl"
        "mihomoctl"
        "clashon"
        "clashoff"
        "clashstatus"
        "start_mihomo"
        "stop_mihomo"
        "is_mihomo_running"
    )
    
    for func in "${required_functions[@]}"; do
        if ! declare -f "$func" >/dev/null; then
            log_error "Required function not defined: $func"
            return 1
        fi
    done
    
    return 0
}

test_process_management() {
    # Source the clashctl script
    source "$PROJECT_ROOT/script/clashctl.sh" 2>/dev/null || {
        log_error "Cannot source clashctl.sh"
        return 1
    }
    
    # Test process status check when not running
    if is_mihomo_running; then
        log_warning "mihomo is already running, stopping for test"
        stop_mihomo
        sleep 2
    fi
    
    # Should return false when not running
    if is_mihomo_running; then
        log_error "is_mihomo_running should return false when process is not running"
        return 1
    fi
    
    return 0
}

test_config_validation() {
    # Test yq binary functionality
    if [ -f "$MIHOMO_BASE_DIR/config.yaml" ]; then
        local test_value=$("$MIHOMO_BASE_DIR/bin/yq" '.mixed-port // 7890' "$MIHOMO_BASE_DIR/config.yaml" 2>/dev/null)
        if [ -z "$test_value" ]; then
            log_error "yq binary cannot read config file"
            return 1
        fi
    fi
    
    return 0
}

test_user_permissions() {
    # Test if we can write to mihomo directory
    local test_file="$MIHOMO_BASE_DIR/test_write_permission"
    
    if ! touch "$test_file" 2>/dev/null; then
        log_error "Cannot write to mihomo directory: $MIHOMO_BASE_DIR"
        return 1
    fi
    
    rm -f "$test_file"
    
    # Test if we can create subdirectories
    local test_dir="$MIHOMO_BASE_DIR/test_dir"
    if ! mkdir -p "$test_dir" 2>/dev/null; then
        log_error "Cannot create subdirectories in mihomo directory"
        return 1
    fi
    
    rmdir "$test_dir"
    
    return 0
}

test_command_help() {
    # Source the clashctl script
    source "$PROJECT_ROOT/script/clashctl.sh" 2>/dev/null || {
        log_error "Cannot source clashctl.sh"
        return 1
    }
    
    # Test help output
    local help_output=$(clashctl 2>&1)
    
    if [[ ! "$help_output" =~ "用户空间运行" ]]; then
        log_error "Help output doesn't mention userspace operation"
        return 1
    fi
    
    if [[ ! "$help_output" =~ "mihomoctl" ]]; then
        log_error "Help output doesn't mention mihomoctl command"
        return 1
    fi
    
    return 0
}

test_environment_variables() {
    # Test if required environment variables are set
    if [ -z "$MIHOMO_BASE_DIR" ]; then
        log_error "MIHOMO_BASE_DIR not set"
        return 1
    fi
    
    if [ -z "$BIN_MIHOMO" ]; then
        log_error "BIN_MIHOMO not set"
        return 1
    fi
    
    return 0
}

# Cleanup function
cleanup() {
    log_info "Cleaning up test environment..."
    # Stop mihomo if it was started during tests
    if is_mihomo_running 2>/dev/null; then
        stop_mihomo 2>/dev/null || true
    fi
}

# Main test execution
main() {
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}  Mihomo Userspace Proxy Functional Test${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo
    
    # Set up cleanup trap
    trap cleanup EXIT
    
    # Run tests
    run_test "Directory Structure" test_directory_structure
    run_test "Binary Files" test_binary_files
    run_test "Config Files" test_config_files
    run_test "Script Functions" test_script_functions
    run_test "Process Management" test_process_management
    run_test "Config Validation" test_config_validation
    run_test "User Permissions" test_user_permissions
    run_test "Command Help" test_command_help
    run_test "Environment Variables" test_environment_variables
    
    # Print summary
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}  Test Summary${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo -e "Tests Run:    ${TESTS_RUN}"
    echo -e "Tests Passed: ${GREEN}${TESTS_PASSED}${NC}"
    echo -e "Tests Failed: ${RED}${TESTS_FAILED}${NC}"
    echo
    
    if [ $TESTS_FAILED -eq 0 ]; then
        echo -e "${GREEN}All tests passed! ✅${NC}"
        exit 0
    else
        echo -e "${RED}Some tests failed! ❌${NC}"
        exit 1
    fi
}

# Check if script is being sourced or executed
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi