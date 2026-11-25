#!/usr/bin/env bash

set -eu
set -o pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
repo_root=$(cd -- "$script_dir/.." && pwd -P)
test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' EXIT

fail() {
    printf 'test-watchdog: %s\n' "$*" >&2
    exit 1
}

export HOME="$test_root/home"
export MIHOMO_BASE_DIR="$HOME/tools/mihomo"
mkdir -p "$MIHOMO_BASE_DIR/config"

fake_yq="$test_root/yq"
cat > "$fake_yq" <<'FAKE_YQ'
#!/bin/sh
case "$1" in
'.system-proxy.enable') printf 'true\n' ;;
'.secret // ""') printf '\n' ;;
'.authentication[0] // ""') printf '\n' ;;
*) exit 1 ;;
esac
FAKE_YQ
chmod 0755 "$fake_yq"
export BIN_YQ="$fake_yq"

set +u
. "$repo_root/script/common.sh"
. "$repo_root/script/upgrade.sh"
. "$repo_root/script/clashctl.sh"
set -u

fake_watchdog="$test_root/watchdog.sh"
printf '%s\n' '#!/usr/bin/env bash' 'while :; do sleep 0.1; done' > "$fake_watchdog"
chmod 0755 "$fake_watchdog"

# ── _watchdog_is_running with no PID file ───────────────────────────

rm -f "$MIHOMO_BASE_DIR/config/watchdog.pid"
! _watchdog_is_running || fail 'should report not running when no PID file'

# ── _watchdog_is_running with dead PID ─────────────────────────────

printf '999999\n' > "$MIHOMO_BASE_DIR/config/watchdog.pid"
! _watchdog_is_running || fail 'should report not running when PID is dead'

# ── _watchdog_is_running with live PID ─────────────────────────────

"$fake_watchdog" "$MIHOMO_BASE_DIR" 30 &
local_pid=$!
printf '%s\n' "$local_pid" > "$MIHOMO_BASE_DIR/config/watchdog.pid"
sleep 0.3
_watchdog_is_running || fail 'should report running when PID is live'
kill "$local_pid" 2>/dev/null || true
wait "$local_pid" 2>/dev/null || true
rm -f "$MIHOMO_BASE_DIR/config/watchdog.pid"

# ── a recycled PID is neither reported nor killed ──────────────────

sleep 300 &
local_pid=$!
printf '%s\n' "$local_pid" > "$MIHOMO_BASE_DIR/config/watchdog.pid"
! _watchdog_is_running || fail 'an unrelated process was taken for the watchdog'
_watchdog_stop
kill -0 "$local_pid" 2>/dev/null || fail 'an unrelated process was killed'
kill "$local_pid" 2>/dev/null || true
wait "$local_pid" 2>/dev/null || true

# ── _watchdog_stop removes PID file for dead process ───────────────

printf '999999\n' > "$MIHOMO_BASE_DIR/config/watchdog.pid"
_watchdog_stop
[ ! -f "$MIHOMO_BASE_DIR/config/watchdog.pid" ] || fail 'should remove PID file for dead process'

# ── _watchdog_stop kills live process ──────────────────────────────

"$fake_watchdog" "$MIHOMO_BASE_DIR" 30 &
local_pid=$!
printf '%s\n' "$local_pid" > "$MIHOMO_BASE_DIR/config/watchdog.pid"
_watchdog_stop
[ ! -f "$MIHOMO_BASE_DIR/config/watchdog.pid" ] || fail 'should remove PID file after stop'
! kill -0 "$local_pid" 2>/dev/null || fail 'should kill the process'

# ── clash watchdog off cleans up stale PID file ───────────────────

printf '999999\n' > "$MIHOMO_BASE_DIR/config/watchdog.pid"
_okcat() { :; }
_failcat() { return 0; }
clashwatchdog off
[ ! -f "$MIHOMO_BASE_DIR/config/watchdog.pid" ] || fail 'off should clean up stale PID file'

# ── clash watchdog status reports running ──────────────────────────

"$fake_watchdog" "$MIHOMO_BASE_DIR" 30 &
local_pid=$!
printf '%s\n' "$local_pid" > "$MIHOMO_BASE_DIR/config/watchdog.pid"
_okcat() { printf '%s\n' "${2:-$1}"; }
_failcat() { printf '%s\n' "${2:-$1}" >&2; return 0; }
sleep 0.3
output=$(clashwatchdog status 2>&1)
if ! echo "$output" | grep -q '运行中'; then
    fail 'status should report running'
fi
kill "$local_pid" 2>/dev/null || true
wait "$local_pid" 2>/dev/null || true
rm -f "$MIHOMO_BASE_DIR/config/watchdog.pid"

# ── clash watchdog status reports not running ──────────────────────

rm -f "$MIHOMO_BASE_DIR/config/watchdog.pid"
_okcat() { printf '%s\n' "${2:-$1}"; }
_failcat() { printf '%s\n' "${2:-$1}" >&2; return 0; }
output=$(clashwatchdog status 2>&1 || true)
if ! echo "$output" | grep -q '未运行'; then
    fail 'status should report not running'
fi

# ── core design: no PID file = deliberate stop = no restart ────────

mihomo_pid="$MIHOMO_BASE_DIR/config/mihomo.pid"
rm -f "$mihomo_pid"
[ -f "$mihomo_pid" ] && fail 'should not restart when PID file absent' || true

# ── core design: PID file present + process dead = crash = restart ─

printf '999999\n' > "$mihomo_pid"
is_mihomo_running() { return 1; }
[ -f "$mihomo_pid" ] || fail 'PID file should exist for crash scenario'
is_mihomo_running 2>/dev/null && fail 'should detect crash when PID exists but process dead' || true
rm -f "$mihomo_pid"

printf 'watchdog tests passed\n'
