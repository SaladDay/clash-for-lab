#!/usr/bin/env bash

set -Eeuo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
repo_root=$(cd -- "$script_dir/.." && pwd -P)
test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' EXIT

fail() {
    printf 'test-integration: %s\n' "$*" >&2
    exit 1
}

file_mode() {
    if stat -c '%a' "$1" >/dev/null 2>&1; then
        stat -c '%a' "$1"
    else
        stat -f '%Lp' "$1"
    fi
}

# shellcheck source=../script/common.sh
set +u
. "$repo_root/script/common.sh"
# shellcheck source=../script/upgrade.sh
. "$repo_root/script/upgrade.sh"
# shellcheck source=../script/clashctl.sh
. "$repo_root/script/clashctl.sh"
set -u

mkdir -p "$test_root/dotfiles" "$test_root/path with space/it's/script"
printf '%s\n' 'export KEEP_ME=1' '. old-mihomo-line' > "$test_root/dotfiles/bashrc"
printf '%s\n' 'export KEEP_ME_TOO=1' > "$test_root/zshrc"
chmod 0640 "$test_root/dotfiles/bashrc"
chmod 0600 "$test_root/zshrc"
ln -s dotfiles/bashrc "$test_root/bashrc"

MIHOMO_SCRIPT_DIR="$test_root/path with space/it's/script"
SHELL_RC_BASH="$test_root/bashrc"
SHELL_RC_ZSH="$test_root/zshrc"
bash_mode_before=$(file_mode "$test_root/dotfiles/bashrc")
zsh_mode_before=$(file_mode "$test_root/zshrc")
bash_link_before=$(readlink "$test_root/bashrc")

_set_rc || fail 'failed to write shell RC files'
_set_rc || fail 'failed to rewrite shell RC files idempotently'
[ -L "$test_root/bashrc" ] || fail 'bash RC symlink was replaced'
[ "$(readlink "$test_root/bashrc")" = "$bash_link_before" ] || fail 'bash RC symlink target changed'
[ "$(file_mode "$test_root/dotfiles/bashrc")" = "$bash_mode_before" ] || fail 'bash RC mode changed'
[ "$(file_mode "$test_root/zshrc")" = "$zsh_mode_before" ] || fail 'zsh RC mode changed'
[ "$(grep -Fc '# clash-for-lab managed' "$test_root/dotfiles/bashrc")" = 1 ] || fail 'bash RC does not contain one canonical line'
[ "$(grep -Fc '# clash-for-lab managed' "$test_root/zshrc")" = 1 ] || fail 'zsh RC does not contain one canonical line'
bash -n "$test_root/dotfiles/bashrc" || fail 'generated bash RC is invalid'
zsh -n "$test_root/zshrc" || fail 'generated zsh RC is invalid'

_set_rc unset || fail 'failed to remove shell RC lines'
[ -L "$test_root/bashrc" ] || fail 'bash RC symlink was replaced during cleanup'
grep -Fq '# clash-for-lab managed' "$test_root/dotfiles/bashrc" && fail 'bash RC line was not removed'
grep -Fq '# clash-for-lab managed' "$test_root/zshrc" && fail 'zsh RC line was not removed'
[ "$(file_mode "$test_root/dotfiles/bashrc")" = "$bash_mode_before" ] || fail 'bash RC mode changed during cleanup'
[ "$(file_mode "$test_root/zshrc")" = "$zsh_mode_before" ] || fail 'zsh RC mode changed during cleanup'

unset_called=false
stop_mihomo() {
    return 1
}
_unset_system_proxy() {
    unset_called=true
}
_okcat() {
    return 0
}
if _clashoff_unlocked; then
    fail 'clash off swallowed a stop failure'
fi
[ "$unset_called" = false ] || fail 'clash off continued after a stop failure'

# `clash proxy on/off` owns the persisted preference transaction. Internal
# service helpers only refresh the current shell, so they cannot recursively
# acquire the lifecycle lock or race another mixin writer.
(
    proxy_root="$test_root/proxy-preference"
    proxy_yq="$proxy_root/fake-yq"
    expression_log="$proxy_root/yq-expressions"
    message_log="$proxy_root/messages"
    mixin_snapshot="$proxy_root/mixin.snapshot"
    fail_yq_marker="$proxy_root/fail-yq"
    mkdir -p "$proxy_root"
    printf '%s\n' \
        '#!/bin/sh' \
        'case "$1" in' \
        '-i)' \
        '    [ "${LOCK_ACTIVE:-false}" = true ] || exit 91' \
        '    printf "%s\n" "$2" >> "$YQ_EXPRESSION_LOG"' \
        '    [ ! -e "${YQ_FAIL_MARKER:-}" ] || exit 92' \
        '    case "$2" in' \
        '    ".system-proxy.enable = true") value=true ;;' \
        '    ".system-proxy.enable = false") value=false ;;' \
        '    *) exit 93 ;;' \
        '    esac' \
        '    /bin/sleep "${YQ_DELAY:-0}"' \
        '    sed "s/enable: .*/enable: $value/" "$3" > "$3.next" || exit 94' \
        '    /bin/mv -f "$3.next" "$3"' \
        '    ;;' \
        '*)' \
        '    case "$1" in' \
        '    ".system-proxy.enable") sed -n "s/^  enable: //p" "$2" ;;' \
        '    ".authentication[0] // \"\"") printf "%s\n" "user:pass" ;;' \
        '    *) exit 95 ;;' \
        '    esac' \
        '    ;;' \
        'esac' > "$proxy_yq"
    chmod 0755 "$proxy_yq"

    MIHOMO_BASE_DIR=$proxy_root
    MIHOMO_CONFIG_RUNTIME="$proxy_root/runtime.yaml"
    MIHOMO_CONFIG_MIXIN="$proxy_root/mixin.yaml"
    BIN_YQ=$proxy_yq
    YQ_EXPRESSION_LOG=$expression_log
    YQ_FAIL_MARKER=$fail_yq_marker
    YQ_DELAY=0
    LOCK_ACTIVE=false
    LOCK_CALLS=0
    export YQ_EXPRESSION_LOG YQ_FAIL_MARKER YQ_DELAY LOCK_ACTIVE
    printf '%s\n' runtime > "$MIHOMO_CONFIG_RUNTIME"
    printf '%s\n' 'keep: original' 'system-proxy:' '  enable: false' > "$MIHOMO_CONFIG_MIXIN"
    : > "$expression_log"
    : > "$message_log"

    _okcat() { printf 'ok:%s\n' "$*" >> "$message_log"; }
    _failcat() { printf 'fail:%s\n' "$*" >> "$message_log"; }
    _unset_system_proxy() {
        unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY
        unset all_proxy ALL_PROXY no_proxy NO_PROXY
    }
    is_mihomo_running() { return 0; }
    _get_proxy_port() { [ "$LOCK_ACTIVE" = true ] || fail 'proxy port was read outside the lifecycle lock'; MIXED_PORT=17890; }
    _get_ui_port() { [ "$LOCK_ACTIVE" = true ] || fail 'UI port was read outside the lifecycle lock'; UI_PORT=19090; }
    _get_dns_port() { [ "$LOCK_ACTIVE" = true ] || fail 'DNS port was read outside the lifecycle lock'; DNS_PORT=15353; }
    _mihomo_run_locked() {
        local operation=$1 operation_status=0
        shift
        [ "$LOCK_ACTIVE" = false ] || fail 'proxy command recursively acquired its lifecycle lock'
        LOCK_ACTIVE=true
        LOCK_CALLS=$((LOCK_CALLS + 1))
        "$operation" "$@" || operation_status=$?
        LOCK_ACTIVE=false
        return "$operation_status"
    }

    clashproxy on || fail 'proxy on failed'
    [ "$LOCK_CALLS" = 1 ] || fail 'proxy on used an unexpected lock boundary'
    grep -Fqx '  enable: true' "$MIHOMO_CONFIG_MIXIN" || fail 'proxy on did not persist its preference'
    [ "$http_proxy" = 'http://user:pass@127.0.0.1:17890' ] || fail 'proxy on exported the wrong HTTP proxy'
    [ "$all_proxy" = 'socks5h://user:pass@127.0.0.1:17890' ] || fail 'proxy on exported the wrong SOCKS proxy'
    [ "$(grep -Fc '已开启系统代理' "$message_log")" = 1 ] || fail 'proxy on did not report one success'

    # Internal refreshes must never rewrite the preference or take another lock.
    cp "$MIHOMO_CONFIG_MIXIN" "$mixin_snapshot"
    expression_count=$(wc -l < "$expression_log" | tr -d ' ')
    _set_system_proxy || fail 'environment-only proxy refresh failed'
    cmp -s "$mixin_snapshot" "$MIHOMO_CONFIG_MIXIN" || fail 'environment-only refresh rewrote the mixin'
    [ "$(wc -l < "$expression_log" | tr -d ' ')" = "$expression_count" ] ||
        fail 'environment-only refresh invoked the preference writer'
    [ "$LOCK_CALLS" = 1 ] || fail 'environment-only refresh recursively acquired the lock'
    [ "$http_proxy" = 'http://user:pass@127.0.0.1:17890' ] ||
        fail 'environment-only refresh ignored an enabled preference'

    clashproxy off || fail 'proxy off failed'
    [ "$LOCK_CALLS" = 2 ] || fail 'proxy off used an unexpected lock boundary'
    grep -Fqx '  enable: false' "$MIHOMO_CONFIG_MIXIN" || fail 'proxy off did not persist its preference'
    [ "${http_proxy+x}" != x ] || fail 'proxy off left HTTP proxy in the current shell'
    [ "${all_proxy+x}" != x ] || fail 'proxy off left SOCKS proxy in the current shell'
    http_proxy=must-be-cleared
    all_proxy=must-be-cleared
    _set_system_proxy || fail 'disabled environment-only refresh failed'
    [ "${http_proxy+x}" != x ] && [ "${all_proxy+x}" != x ] ||
        fail 'environment-only refresh ignored a disabled preference'

    # Directory, yq, and atomic-publish failures must preserve both the exact
    # mixin and the caller's current environment, without a success message.
    cp "$MIHOMO_CONFIG_MIXIN" "$mixin_snapshot"
    http_proxy=sentinel-http
    all_proxy=sentinel-socks
    : > "$message_log"
    mkdir() { return 1; }
    if clashproxy on >/dev/null 2>&1; then
        fail 'proxy on ignored a mixin-directory failure'
    fi
    unset -f mkdir
    cmp -s "$mixin_snapshot" "$MIHOMO_CONFIG_MIXIN" || fail 'directory failure changed the mixin'
    [ "$http_proxy" = sentinel-http ] && [ "$all_proxy" = sentinel-socks ] ||
        fail 'directory failure changed the proxy environment'
    grep -Fq '已开启系统代理' "$message_log" && fail 'directory failure printed proxy-on success'

    : > "$fail_yq_marker"
    : > "$message_log"
    if clashproxy on >/dev/null 2>&1; then
        fail 'proxy on ignored a yq failure'
    fi
    rm -f "$fail_yq_marker"
    cmp -s "$mixin_snapshot" "$MIHOMO_CONFIG_MIXIN" || fail 'yq failure changed the mixin'
    [ "$http_proxy" = sentinel-http ] && [ "$all_proxy" = sentinel-socks ] ||
        fail 'yq failure changed the proxy environment'
    grep -Fq '已开启系统代理' "$message_log" && fail 'yq failure printed proxy-on success'

    : > "$message_log"
    mv() { return 1; }
    if clashproxy off >/dev/null 2>&1; then
        fail 'proxy off ignored an atomic-publish failure'
    fi
    unset -f mv
    cmp -s "$mixin_snapshot" "$MIHOMO_CONFIG_MIXIN" || fail 'publish failure changed the mixin'
    [ "$http_proxy" = sentinel-http ] && [ "$all_proxy" = sentinel-socks ] ||
        fail 'publish failure cleared the proxy environment'
    grep -Fq '已关闭系统代理' "$message_log" && fail 'publish failure printed proxy-off success'

    # An external mixin edit after the candidate snapshot must win. The proxy
    # command aborts without changing the caller environment or the new line.
    external_proxy_edit() {
        printf '%s\n' 'external: keep-me' >> "$1"
    }
    _proxy_preference_before_commit() { external_proxy_edit "$@"; }
    cp "$MIHOMO_CONFIG_MIXIN" "$mixin_snapshot"
    http_proxy=external-edit-http
    all_proxy=external-edit-socks
    if clashproxy on >/dev/null 2>&1; then
        fail 'proxy on overwrote a concurrent external mixin edit'
    fi
    _proxy_preference_before_commit() { :; }
    grep -Fqx 'external: keep-me' "$MIHOMO_CONFIG_MIXIN" || fail 'proxy CAS dropped the external mixin edit'
    grep -Fqx '  enable: false' "$MIHOMO_CONFIG_MIXIN" || fail 'proxy CAS published its stale preference'
    [ "$http_proxy" = external-edit-http ] && [ "$all_proxy" = external-edit-socks ] ||
        fail 'proxy CAS failure changed the caller environment'

    # Two callers sharing the lifecycle lock may choose either final value,
    # but the published YAML must always be one complete candidate.
    lifecycle_dir="$proxy_root/lifecycle.lock"
    lifecycle_ready="$proxy_root/lifecycle.ready"
    [ ! -e "$lifecycle_dir" ] || fail 'concurrent proxy lock path unexpectedly exists before the test'
    _mihomo_run_locked() {
        local operation=$1 operation_status=0
        shift
        while [ -d "$lifecycle_dir" ]; do
            /bin/sleep 0.01
        done
        /bin/mkdir "$lifecycle_dir" || return 1
        [ "$operation" != _clashproxy_on_locked ] || : > "$lifecycle_ready"
        LOCK_ACTIVE=true
        "$operation" "$@" || operation_status=$?
        LOCK_ACTIVE=false
        /bin/rmdir "$lifecycle_dir" || operation_status=97
        return "$operation_status"
    }
    YQ_DELAY=0.1
    export YQ_DELAY
    : > "$expression_log"
    set +e
    clashproxy on > "$proxy_root/concurrent-on.out" 2>&1 &
    proxy_on_pid=$!
    wait_count=0
    while [ ! -f "$lifecycle_ready" ] && [ "$wait_count" -lt 100 ]; do
        /bin/sleep 0.01
        wait_count=$((wait_count + 1))
    done
    [ -f "$lifecycle_ready" ] || {
        sed 's/^/concurrent proxy on: /' "$proxy_root/concurrent-on.out" >&2
        fail 'concurrent proxy test never acquired the first lifecycle lock'
    }
    clashproxy off > "$proxy_root/concurrent-off.out" 2>&1 &
    proxy_off_pid=$!
    proxy_on_status=0
    wait "$proxy_on_pid" || proxy_on_status=$?
    proxy_off_status=0
    wait "$proxy_off_pid" || proxy_off_status=$?
    set -e
    [ "$proxy_on_status" -eq 0 ] || {
        sed 's/^/concurrent proxy on: /' "$proxy_root/concurrent-on.out" >&2
        fail "concurrent proxy on failed with status $proxy_on_status"
    }
    [ "$proxy_off_status" -eq 0 ] || {
        sed 's/^/concurrent proxy off: /' "$proxy_root/concurrent-off.out" >&2
        fail "concurrent proxy off failed with status $proxy_off_status"
    }
    [ "$(wc -l < "$expression_log" | tr -d ' ')" = 2 ] || fail 'concurrent proxy commands did not both persist'
    [ "$(grep -Ec '^  enable: (true|false)$' "$MIHOMO_CONFIG_MIXIN")" = 1 ] ||
        fail 'concurrent proxy commands published a torn mixin'
    grep -Fqx 'keep: original' "$MIHOMO_CONFIG_MIXIN" || fail 'concurrent proxy commands lost unrelated mixin data'
)

fake_yq="$test_root/fake-yq"
printf '%s\n' '#!/bin/sh' 'printf "%s\n" "runtime-new"' > "$fake_yq"
chmod 0755 "$fake_yq"

# A failed first start must restore the old runtime and leave the service stopped.
(
    BIN_YQ=$fake_yq
    MIHOMO_BASE_DIR="$test_root/clash-on-stopped"
    MIHOMO_CONFIG_MIXIN="$MIHOMO_BASE_DIR/mixin.yaml"
    MIHOMO_CONFIG_RAW="$MIHOMO_BASE_DIR/config.yaml"
    MIHOMO_CONFIG_RUNTIME="$MIHOMO_BASE_DIR/runtime.yaml"
    mkdir -p "$MIHOMO_BASE_DIR"
    printf '%s\n' mixin > "$MIHOMO_CONFIG_MIXIN"
    printf '%s\n' raw > "$MIHOMO_CONFIG_RAW"
    printf '%s\n' runtime-old > "$MIHOMO_CONFIG_RUNTIME"
    service_state="$MIHOMO_BASE_DIR/service.state"
    start_marker="$MIHOMO_BASE_DIR/start.called"
    stop_marker="$MIHOMO_BASE_DIR/stop.called"
    printf '%s\n' stopped > "$service_state"
    MIXED_PORT=7890
    UI_PORT=9090
    DNS_PORT=15353
    is_mihomo_running() { [ "$(cat "$service_state")" = running ]; }
    _resolve_port_conflicts() { return 0; }
    _valid_config() { return 0; }
    _start_mihomo_unlocked() { touch "$start_marker"; printf '%s\n' running > "$service_state"; }
    _stop_mihomo_unlocked() { touch "$stop_marker"; printf '%s\n' stopped > "$service_state"; }
    sleep() { return 0; }
    _verify_actual_ports() { return 0; }
    _save_port_state() { return 1; }
    _set_system_proxy() { return 0; }
    _unset_system_proxy() { return 0; }
    clashon_status=0
    _clashon_unlocked || clashon_status=$?
    [ "$clashon_status" -ne 0 ] || fail 'clash on swallowed a post-start state failure'
    [ -f "$start_marker" ] || fail 'clash on regression did not start the service'
    [ -f "$stop_marker" ] || fail 'clash on left its newly started service running after failure'
    [ "$(cat "$service_state")" = stopped ] || fail 'failed first start changed the original stopped state'
    [ "$(cat "$MIHOMO_CONFIG_RUNTIME")" = runtime-old ] || fail 'failed first start did not restore the old runtime'
)

# Restarting an already-running service must never leave a new runtime on disk
# while the old runtime is the one actually serving traffic.
(
    BIN_YQ=$fake_yq
    MIHOMO_BASE_DIR="$test_root/clash-on-running"
    MIHOMO_CONFIG_MIXIN="$MIHOMO_BASE_DIR/mixin.yaml"
    MIHOMO_CONFIG_RAW="$MIHOMO_BASE_DIR/config.yaml"
    MIHOMO_CONFIG_RUNTIME="$MIHOMO_BASE_DIR/runtime.yaml"
    actual_runtime="$MIHOMO_BASE_DIR/actual-runtime"
    mkdir -p "$MIHOMO_BASE_DIR"
    printf '%s\n' mixin > "$MIHOMO_CONFIG_MIXIN"
    printf '%s\n' raw > "$MIHOMO_CONFIG_RAW"
    printf '%s\n' runtime-old > "$MIHOMO_CONFIG_RUNTIME"
    printf '%s\n' runtime-old > "$actual_runtime"
    service_state="$MIHOMO_BASE_DIR/service.state"
    printf '%s\n' running > "$service_state"
    MIXED_PORT=7890
    UI_PORT=9090
    DNS_PORT=15353
    is_mihomo_running() { [ "$(cat "$service_state")" = running ]; }
    _resolve_port_conflicts() { return 0; }
    _valid_config() { return 0; }
    _start_mihomo_unlocked() {
        cp "$MIHOMO_CONFIG_RUNTIME" "$actual_runtime"
        printf '%s\n' running > "$service_state"
    }
    _stop_mihomo_unlocked() { printf '%s\n' stopped > "$service_state"; }
    sleep() { return 0; }
    _verify_actual_ports() { return 0; }
    _save_port_state() { [ "$(cat "$actual_runtime")" = runtime-old ]; }
    _set_system_proxy() { return 0; }
    _unset_system_proxy() { return 0; }
    if _clashon_unlocked >/dev/null 2>&1; then
        fail 'running-service apply failure was reported as successful'
    fi
    [ "$(cat "$service_state")" = running ] || fail 'running service was not restored after apply failure'
    [ "$(cat "$MIHOMO_CONFIG_RUNTIME")" = runtime-old ] || fail 'disk runtime was not restored after apply failure'
    [ "$(cat "$actual_runtime")" = runtime-old ] || fail 'actual service was restored with the wrong runtime'
)

# A merge command may truncate its output before it fails. That output must be
# isolated in a candidate file while a running service keeps its old runtime.
(
    failing_yq="$test_root/failing-yq"
    printf '%s\n' '#!/bin/sh' 'printf "%s\n" "partial"' 'exit 1' > "$failing_yq"
    chmod 0755 "$failing_yq"
    BIN_YQ=$failing_yq
    MIHOMO_BASE_DIR="$test_root/clash-on-merge-failure"
    MIHOMO_CONFIG_MIXIN="$MIHOMO_BASE_DIR/mixin.yaml"
    MIHOMO_CONFIG_RAW="$MIHOMO_BASE_DIR/config.yaml"
    MIHOMO_CONFIG_RUNTIME="$MIHOMO_BASE_DIR/runtime.yaml"
    mkdir -p "$MIHOMO_BASE_DIR"
    printf '%s\n' mixin > "$MIHOMO_CONFIG_MIXIN"
    printf '%s\n' raw > "$MIHOMO_CONFIG_RAW"
    printf '%s\n' runtime-old > "$MIHOMO_CONFIG_RUNTIME"
    is_mihomo_running() { return 0; }
    if _clashon_unlocked >/dev/null 2>&1; then
        fail 'merge failure was reported as a successful clash on'
    fi
    [ "$(cat "$MIHOMO_CONFIG_RUNTIME")" = runtime-old ] || fail 'merge failure truncated the published runtime'
    is_mihomo_running || fail 'merge failure stopped the existing service'
)

# Runtime replacement is a signal-safe transaction. Exercise TERM after the
# old service stops, after the runtime is published, and while the candidate
# service is starting. Both entry points must restore the exact old runtime and
# running state, ignore a second TERM during rollback, and preserve caller traps.
run_runtime_signal_case() (
    local operation=$1 window=$2
    local case_root="$test_root/runtime-signal-${operation#_}-$window"
    local ready="$case_root/ready" continue_file="$case_root/continue"
    local rollback_ready="$case_root/rollback-ready"
    local rollback_continue="$case_root/rollback-continue"
    local pause_child_file="$case_root/pause-child.pid"
    local injected="$case_root/injected" primary_sent="$case_root/primary-sent"
    local service_state="$case_root/service.state" actual_runtime="$case_root/actual-runtime"
    local transaction_pid transaction_body_pid pause_child_pid transaction_status=0 wait_count=0 trap_before

    BIN_YQ=$fake_yq
    MIHOMO_BASE_DIR=$case_root
    MIHOMO_CONFIG_MIXIN="$case_root/mixin.yaml"
    MIHOMO_CONFIG_RAW="$case_root/config.yaml"
    MIHOMO_CONFIG_RUNTIME="$case_root/runtime.yaml"
    MIXED_PORT=7890
    UI_PORT=9090
    DNS_PORT=15353
    mkdir -p "$case_root"
    printf '%s\n' mixin > "$MIHOMO_CONFIG_MIXIN"
    printf '%s\n' raw > "$MIHOMO_CONFIG_RAW"
    printf '%s\n' runtime-old > "$MIHOMO_CONFIG_RUNTIME"
    printf '%s\n' runtime-old > "$actual_runtime"
    printf '%s\n' running > "$service_state"

    _pause_until() {
        local marker=$1 release=$2
        (
            while [ ! -f "$release" ]; do
                /bin/sleep 0.02
            done
        ) &
        local pause_pid=$!
        printf '%s\n' "$pause_pid" > "$pause_child_file"
        : > "$marker"
        wait "$pause_pid"
    }
    is_mihomo_running() { [ "$(cat "$service_state")" = running ]; }
    _resolve_port_conflicts() { return 0; }
    _valid_config() { return 0; }
    _verify_actual_ports() { return 0; }
    _save_port_state() { return 0; }
    _set_system_proxy() { return 0; }
    _unset_system_proxy() { return 0; }
    sleep() { return 0; }
    _stop_mihomo_unlocked() {
        printf '%s\n' stopped > "$service_state"
        if [ "$window" = stop ] && [ ! -f "$injected" ]; then
            : > "$injected"
            _pause_until "$ready" "$continue_file"
        fi
    }
    _lifecycle_after_object_publish() {
        local object=$1 destination=$2
        if [ "$object" = runtime ] && [ "$destination" = "$MIHOMO_CONFIG_RUNTIME" ] &&
            [ "$(cat "$destination")" = runtime-new ] &&
            [ "$window" = publish ] && [ ! -f "$injected" ]; then
            : > "$injected"
            _pause_until "$ready" "$continue_file"
        fi
    }
    _start_mihomo_unlocked() {
        local runtime
        runtime=$(cat "$MIHOMO_CONFIG_RUNTIME")
        printf '%s\n' "$runtime" > "$actual_runtime"
        printf '%s\n' running > "$service_state"
        if [ "$runtime" = runtime-new ] && [ "$window" = start ] && [ ! -f "$injected" ]; then
            : > "$injected"
            _pause_until "$ready" "$continue_file"
        elif [ "$runtime" = runtime-old ] && [ -f "$primary_sent" ]; then
            _pause_until "$rollback_ready" "$rollback_continue"
        fi
    }

    trap ':' TERM
    trap_before=$(trap -p TERM)
    "$operation" &
    transaction_pid=$!
    while [ ! -f "$ready" ] && [ "$wait_count" -lt 200 ]; do
        /bin/sleep 0.02
        wait_count=$((wait_count + 1))
    done
    [ -f "$ready" ] || fail "$operation TERM/$window never reached the injected window"
    : > "$primary_sent"
    pause_child_pid=$(cat "$pause_child_file")
    transaction_body_pid=$(ps -o ppid= -p "$pause_child_pid" | tr -d ' ')
    [ -n "$transaction_body_pid" ] || fail "$operation TERM/$window body PID was not found"
    kill -TERM "$transaction_body_pid"
    kill -TERM "$pause_child_pid" 2>/dev/null || true

    wait_count=0
    while [ ! -f "$rollback_ready" ] && [ "$wait_count" -lt 200 ]; do
        /bin/sleep 0.02
        wait_count=$((wait_count + 1))
    done
    [ -f "$rollback_ready" ] || fail "$operation TERM/$window never entered rollback"
    pause_child_pid=$(cat "$pause_child_file")
    transaction_body_pid=$(ps -o ppid= -p "$pause_child_pid" | tr -d ' ')
    [ -n "$transaction_body_pid" ] || fail "$operation TERM/$window rollback body PID was not found"
    kill -TERM "$transaction_body_pid"
    : > "$rollback_continue"
    wait "$transaction_pid" 2>/dev/null || transaction_status=$?

    [ "$transaction_status" -eq 143 ] ||
        fail "$operation TERM/$window returned $transaction_status instead of 143"
    [ "$(cat "$MIHOMO_CONFIG_RUNTIME")" = runtime-old ] ||
        fail "$operation TERM/$window did not restore the old runtime"
    [ "$(cat "$actual_runtime")" = runtime-old ] ||
        fail "$operation TERM/$window restarted with the wrong runtime"
    [ "$(cat "$service_state")" = running ] ||
        fail "$operation TERM/$window did not restore the running service"
    [ "$(trap -p TERM)" = "$trap_before" ] ||
        fail "$operation TERM/$window polluted the caller TERM trap"
)

for runtime_operation in _clashon_unlocked _merge_config_restart_unlocked _clashrestart_unlocked; do
    for signal_window in stop publish start; do
        run_runtime_signal_case "$runtime_operation" "$signal_window" ||
            fail "$runtime_operation TERM/$signal_window transaction case failed"
    done
done

# Secret values are passed through yq's environment-value channel, never
# interpolated into its expression. Shell-looking input must remain plain data.
(
    safe_yq="$test_root/safe-secret-yq"
    expression_log="$test_root/safe-secret-expression"
    value_log="$test_root/safe-secret-value"
    candidate="$test_root/safe-secret-candidate"
    injection_marker="$test_root/secret-was-executed"
    malicious_secret='"; $(touch '"$injection_marker"'); #'
    printf '%s\n' \
        '#!/bin/sh' \
        'printf "%s" "$2" > "$YQ_EXPRESSION_LOG"' \
        'printf "%s" "$CLASH_FOR_LAB_MIXIN_VALUE" > "$YQ_VALUE_LOG"' \
        'printf "%s\n" candidate > "$3"' > "$safe_yq"
    chmod 0755 "$safe_yq"
    printf '%s\n' old-mixin > "$candidate"
    BIN_YQ=$safe_yq
    YQ_EXPRESSION_LOG=$expression_log
    YQ_VALUE_LOG=$value_log
    export YQ_EXPRESSION_LOG YQ_VALUE_LOG
    _write_mixin_candidate secret "$malicious_secret" "$candidate" ||
        fail 'safe secret writer rejected an opaque secret value'
    [ "$(cat "$expression_log")" = '.secret = strenv(CLASH_FOR_LAB_MIXIN_VALUE)' ] ||
        fail 'secret value was interpolated into the yq expression'
    [ "$(cat "$value_log")" = "$malicious_secret" ] || fail 'secret value was not passed losslessly'
    [ ! -e "$injection_marker" ] || fail 'shell-looking secret input was executed'
)

# Mixin changes publish the mixin and derived runtime in one rollback domain.
# A candidate startup failure must propagate through `clash secret` and restore
# both files plus the exact original running service.
(
    MIHOMO_BASE_DIR="$test_root/mixin-rollback"
    MIHOMO_CONFIG_MIXIN="$MIHOMO_BASE_DIR/mixin.yaml"
    MIHOMO_CONFIG_RAW="$MIHOMO_BASE_DIR/config.yaml"
    MIHOMO_CONFIG_RUNTIME="$MIHOMO_BASE_DIR/runtime.yaml"
    service_state="$MIHOMO_BASE_DIR/service.state"
    actual_runtime="$MIHOMO_BASE_DIR/actual-runtime"
    message_log="$MIHOMO_BASE_DIR/messages"
    lock_active=false
    MIXED_PORT=7890
    UI_PORT=9090
    DNS_PORT=15353
    mkdir -p "$MIHOMO_BASE_DIR"
    printf '%s\n' mixin-old > "$MIHOMO_CONFIG_MIXIN"
    printf '%s\n' raw > "$MIHOMO_CONFIG_RAW"
    printf '%s\n' runtime-old > "$MIHOMO_CONFIG_RUNTIME"
    printf '%s\n' runtime-old > "$actual_runtime"
    printf '%s\n' running > "$service_state"
    : > "$message_log"

    _mihomo_run_locked() {
        local operation=$1 operation_status=0
        shift
        [ "$lock_active" = false ] || fail 'mixin transaction recursively acquired its lock'
        lock_active=true
        "$operation" "$@" || operation_status=$?
        lock_active=false
        return "$operation_status"
    }
    _write_mixin_candidate() {
        local field=$1 value=$2 candidate=$3
        [ "$lock_active" = true ] || fail 'mixin candidate was changed outside the lifecycle lock'
        printf 'mixin-%s=%s\n' "$field" "$value" > "$candidate"
    }
    _build_runtime_candidate() {
        local raw_config=$1 destination=$2 show_ports=$3 mixin_candidate=$4
        [ "$lock_active" = true ] || fail 'runtime candidate was built outside the lifecycle lock'
        [ -s "$raw_config" ] && [ "$show_ports" = false ] || return 1
        printf 'runtime-%s\n' "$(cat "$mixin_candidate")" > "$destination"
    }
    is_mihomo_running() { [ "$(cat "$service_state")" = running ]; }
    _stop_mihomo_unlocked() { printf '%s\n' stopped > "$service_state"; }
    _activate_published_runtime_unlocked() {
        local runtime
        runtime=$(cat "$MIHOMO_CONFIG_RUNTIME")
        printf '%s\n' "$runtime" > "$actual_runtime"
        printf '%s\n' running > "$service_state"
        [ "$runtime" = runtime-old ]
    }
    _unset_system_proxy() { return 0; }
    _okcat() { printf 'ok:%s\n' "$*" >> "$message_log"; }
    _failcat() { printf 'fail:%s\n' "$*" >> "$message_log"; return 1; }

    if clashsecret 'candidate-secret' >/dev/null 2>&1; then
        fail 'failed mixin/service apply was reported as a successful secret change'
    fi
    [ "$(cat "$MIHOMO_CONFIG_MIXIN")" = mixin-old ] || fail 'mixin rollback did not restore the old mixin'
    [ "$(cat "$MIHOMO_CONFIG_RUNTIME")" = runtime-old ] || fail 'mixin rollback did not restore the old runtime'
    [ "$(cat "$actual_runtime")" = runtime-old ] || fail 'mixin rollback restarted with the wrong runtime'
    [ "$(cat "$service_state")" = running ] || fail 'mixin rollback did not restore the running service'
    if grep -Fq '密钥更新成功' "$message_log"; then
        fail 'secret command printed success after rollback'
    fi
    :
)

fake_kernel="$test_root/fake-mihomo"
printf '%s\n' \
    '#!/bin/sh' \
    'printf '\''%s\n'\'' "$$" > "$START_CHILD_MARKER"' \
    'while :; do' \
    '    sleep 1' \
    'done' > "$fake_kernel"
chmod 0755 "$fake_kernel"
mktemp_bin=$(command -v mktemp)

wait_for_file() {
    local path=$1 count=0
    while [ ! -s "$path" ] && [ "$count" -lt 100 ]; do
        /bin/sleep 0.02
        count=$((count + 1))
    done
    [ -s "$path" ]
}

wait_for_dead() {
    local pid=$1 count=0
    while kill -0 "$pid" 2>/dev/null && [ "$count" -lt 100 ]; do
        /bin/sleep 0.02
        count=$((count + 1))
    done
    ! kill -0 "$pid" 2>/dev/null
}

# Failure to stage the atomic PID file happens after fork; the known child must
# still be terminated directly.
(
    MIHOMO_BASE_DIR="$test_root/start-pid-write"
    MIHOMO_CONFIG_RUNTIME="$MIHOMO_BASE_DIR/runtime.yaml"
    MIHOMO_PORT_STATE="$MIHOMO_BASE_DIR/ports.conf"
    BIN_KERNEL=$fake_kernel
    START_CHILD_MARKER="$MIHOMO_BASE_DIR/child.pid"
    export START_CHILD_MARKER
    mkdir -p "$MIHOMO_BASE_DIR"
    printf '%s\n' runtime > "$MIHOMO_CONFIG_RUNTIME"
    _valid_config() { return 0; }
    _okcat() { return 0; }
    _failcat() { return 0; }
    mktemp() {
        case "$1" in
        *mihomo.pid.tmp.*)
            wait_for_file "$START_CHILD_MARKER" || return 1
            return 1
            ;;
        *) "$mktemp_bin" "$@" ;;
        esac
    }
    if _start_mihomo_unlocked; then
        fail 'PID staging failure was reported as a successful start'
    fi
    child_pid=$(cat "$START_CHILD_MARKER")
    wait_for_dead "$child_pid" || fail 'PID staging failure left the known child running'
)

# Failed startup verification happens after PID publication and must reap the
# exact child before clearing its PID file.
(
    MIHOMO_BASE_DIR="$test_root/start-verification"
    MIHOMO_CONFIG_RUNTIME="$MIHOMO_BASE_DIR/runtime.yaml"
    MIHOMO_PORT_STATE="$MIHOMO_BASE_DIR/ports.conf"
    BIN_KERNEL=$fake_kernel
    START_CHILD_MARKER="$MIHOMO_BASE_DIR/child.pid"
    export START_CHILD_MARKER
    mkdir -p "$MIHOMO_BASE_DIR"
    printf '%s\n' runtime > "$MIHOMO_CONFIG_RUNTIME"
    _valid_config() { return 0; }
    _okcat() { return 0; }
    _failcat() { return 0; }
    is_mihomo_running() { return 1; }
    if _start_mihomo_unlocked; then
        fail 'startup verification failure was reported as success'
    fi
    wait_for_file "$START_CHILD_MARKER" || fail 'verification fixture never spawned its child'
    child_pid=$(cat "$START_CHILD_MARKER")
    wait_for_dead "$child_pid" || fail 'startup verification failure left the known child running'
    [ ! -e "$MIHOMO_BASE_DIR/config/mihomo.pid" ] || fail 'startup verification failure left its PID file behind'
)

# A signal after PID publication must remove the PID file and reap the exact
# child instead of relying on later PID-file discovery.
(
    MIHOMO_BASE_DIR="$test_root/start-signal"
    MIHOMO_CONFIG_RUNTIME="$MIHOMO_BASE_DIR/runtime.yaml"
    MIHOMO_PORT_STATE="$MIHOMO_BASE_DIR/ports.conf"
    BIN_KERNEL=$fake_kernel
    START_CHILD_MARKER="$MIHOMO_BASE_DIR/child.pid"
    export START_CHILD_MARKER
    mkdir -p "$MIHOMO_BASE_DIR"
    printf '%s\n' runtime > "$MIHOMO_CONFIG_RUNTIME"
    _valid_config() { return 0; }
    _okcat() { return 0; }
    _failcat() { return 0; }
    _start_mihomo_unlocked &
    starter_pid=$!
    pid_file="$MIHOMO_BASE_DIR/config/mihomo.pid"
    wait_for_file "$pid_file" || fail 'signal fixture never published its PID file'
    child_pid=$(cat "$pid_file")
    start_body_pid=$(ps -o ppid= -p "$child_pid" | tr -d ' ')
    [ -n "$start_body_pid" ] || fail 'could not resolve the start transaction process'
    kill -TERM "$start_body_pid"
    wait "$starter_pid" 2>/dev/null && fail 'signalled start unexpectedly succeeded'
    wait_for_dead "$child_pid" || fail 'signalled start left the known child running'
    [ ! -e "$pid_file" ] || fail 'signalled start left its PID file behind'
)

if command -v flock >/dev/null 2>&1; then
    converter_root="$test_root/converter"
    mkdir -p "$converter_root"
    BIN_SUBCONVERTER_DIR=$converter_root
    BIN_SUBCONVERTER="$converter_root/subconverter-test-process"
    BIN_SUBCONVERTER_CONFIG="$converter_root/pref.yml"
    BIN_SUBCONVERTER_LOG="$converter_root/latest.log"
    BIN_SUBCONVERTER_PORT=25500
    printf '%s\n' '#!/bin/sh' 'sleep 30' > "$BIN_SUBCONVERTER"
    chmod 0755 "$BIN_SUBCONVERTER"
    MIHOMO_UPGRADE_LOCK_DIR="$test_root/converter-operation.lock"
    _is_already_in_use() { return 1; }
    _port_taken_by_others() { return 1; }
    _is_bind() { return 0; }
    _upgrade_acquire_lock || fail 'failed to acquire converter inheritance test lock'
    _start_convert || fail 'failed to start converter inheritance fixture'
    converter_log_mode=$(file_mode "$BIN_SUBCONVERTER_LOG")
    [ "$converter_log_mode" = 600 ] || fail 'converter log does not protect subscription details with mode 0600'
    _upgrade_release_lock
    if ! _upgrade_acquire_lock; then
        _stop_convert
        fail 'background converter inherited and retained the lifecycle lock'
    fi
    _upgrade_release_lock
    _stop_convert
fi

printf '%s\n' 'integration tests passed'
