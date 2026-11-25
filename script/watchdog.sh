#!/usr/bin/env bash
# Watchdog: restart mihomo if it crashes unexpectedly.
#
# PID file presence = mihomo is expected to run.
# PID file absence  = user stopped it deliberately; do not restart.
#
# Arguments: $1 = MIHOMO_BASE_DIR, $2 = check interval (seconds)

set -e
set -o pipefail

base_dir=${1:?}
interval=${2:-30}
pid_file="${base_dir}/config/mihomo.pid"
watchdog_pid_file="${base_dir}/config/watchdog.pid"
script_dir="${base_dir}/script"

# Load management functions
. "${script_dir}/common.sh"
. "${script_dir}/upgrade.sh"
. "${script_dir}/clashctl.sh"

_self_alive() {
    local my_pid=$$ stored_pid
    [ -f "$watchdog_pid_file" ] || return 1
    stored_pid=$(cat "$watchdog_pid_file" 2>/dev/null || true)
    [ "$stored_pid" = "$my_pid" ]
}

while true; do
    sleep "$interval"

    # Stop if watchdog PID file was removed or changed (clash watchdog off)
    _self_alive || exit 0

    # If PID file doesn't exist, mihomo was stopped deliberately
    [ -f "$pid_file" ] || continue

    # If mihomo is running, nothing to do
    is_mihomo_running 2>/dev/null && continue

    # mihomo crashed (PID file exists but process is dead). The PID file is the
    # "should be running" marker, so it must survive a busy lock or a failed
    # start; otherwise the next round would treat the crash as a manual stop.
    if _mihomo_operation_acquire 2>/dev/null; then
        MIHOMO_OPERATION_LOCK_HELD=true
        if [ -f "$pid_file" ] && ! is_mihomo_running 2>/dev/null; then
            crashed_pid=$(cat "$pid_file" 2>/dev/null || true)
            if ! _start_mihomo_unlocked 2>/dev/null; then
                [ -f "$pid_file" ] || printf '%s\n' "$crashed_pid" > "$pid_file"
            fi
        fi
        _mihomo_operation_release 2>/dev/null || true
        MIHOMO_OPERATION_LOCK_HELD=false
    fi
done
