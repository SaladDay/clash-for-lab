#!/usr/bin/env bash

set -eu
set -o pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
repo_root=$(CDPATH= cd -- "$script_dir/.." && pwd -P)
test_root=$(mktemp -d)

cleanup() {
    exit_status=$?
    trap - EXIT HUP INT TERM
    rm -rf -- "$test_root"
    exit "$exit_status"
}
trap cleanup EXIT HUP INT TERM

fail() {
    printf 'test-lifecycle-regressions: %s\n' "$*" >&2
    exit 1
}

export HOME="$test_root/home"
export MIHOMO_BASE_DIR="$HOME/tools/mihomo"
export MIHOMO_CONFIG_RAW="$MIHOMO_BASE_DIR/config.yaml"
export MIHOMO_CONFIG_RAW_BAK="$MIHOMO_CONFIG_RAW.bak"
export MIHOMO_CONFIG_RUNTIME="$MIHOMO_BASE_DIR/runtime.yaml"
export MIHOMO_CONFIG_URL="$MIHOMO_BASE_DIR/url"
export MIHOMO_CONFIG_MIXIN="$MIHOMO_BASE_DIR/mixin.yaml"
export MIHOMO_UPDATE_LOG="$MIHOMO_BASE_DIR/mihomoctl.log"
export MIHOMO_PORT_PREF="$MIHOMO_BASE_DIR/config/port.pref"
export MIHOMO_PORT_STATE="$MIHOMO_BASE_DIR/config/ports.conf"
export BIN_KERNEL_NAME=mihomo

fake_yq="$test_root/yq"
cat > "$fake_yq" <<'FAKE_YQ'
#!/bin/sh
set -eu
case "$1" in
eval-all)
    printf '%s\n' runtime-candidate
    cat "$3" "$4"
    ;;
-i)
    expression=$2
    destination=$3
    case "$expression" in
    *CLASH_FOR_LAB_MIXIN_VALUE*)
        printf 'secret=%s\n' "$CLASH_FOR_LAB_MIXIN_VALUE" >> "$destination"
        ;;
    *'.tun.enable = true'*) printf '%s\n' 'tun=true' >> "$destination" ;;
    *'.tun.enable = false'*) printf '%s\n' 'tun=false' >> "$destination" ;;
    *'.allow-lan = true'*) printf '%s\n' 'allow-lan=true' >> "$destination" ;;
    *'.allow-lan = false'*) printf '%s\n' 'allow-lan=false' >> "$destination" ;;
    *) exit 1 ;;
    esac
    ;;
*) exit 1 ;;
esac
FAKE_YQ
chmod 0755 "$fake_yq"
export BIN_YQ="$fake_yq"

set +u
# shellcheck source=../script/clashctl.sh
. "$repo_root/script/clashctl.sh"
set -u

trace="$test_root/trace"
service_state="$test_root/service.state"
actual_runtime="$test_root/actual-runtime"

_okcat() { return 0; }
_failcat() { return 1; }
_mihomo_run_locked() {
    printf 'lock:%s\n' "$1" >> "$trace"
    "$@"
}
_resolve_port_conflicts() {
    candidate=$1
    mode=${3:-}
    value=${4:-}
    [ -z "$mode" ] || printf 'port=%s:%s\n' "$mode" "$value" >> "$candidate"
}
_write_port_preferences_file() {
    destination=$1
    mode=$2
    value=${3:-}
    printf 'PROXY_MODE=%s\nPROXY_PORT=%s\n' "$mode" "$value" > "$destination"
}
_valid_config() {
    [ ! -f "$test_root/validation.fail" ] && [ -s "$1" ]
}
_initialize_config_validation_home() {
    [ "$1" = "$MIHOMO_BASE_DIR" ] || return 1
    mkdir -p "$2"
}
_publish_new_config_validation_data() {
    [ "$2" = "$MIHOMO_BASE_DIR" ] || return 1
    : > "$3"
}
_rollback_new_config_validation_data() { return 0; }
_is_already_in_use() { return 1; }
_port_taken_by_others() { return 1; }
_has_tty() { return 0; }
is_mihomo_running() {
    [ "$(cat "$service_state" 2>/dev/null || true)" = running ]
}
_stop_mihomo_unlocked() {
    printf '%s\n' stop >> "$trace"
    printf '%s\n' stopped > "$service_state"
}
_activate_published_runtime_unlocked() {
    printf '%s\n' start >> "$trace"
    cp "$MIHOMO_CONFIG_RUNTIME" "$actual_runtime"
    printf '%s\n' running > "$service_state"
    if [ -f "$test_root/start.fail-once" ]; then
        rm -f "$test_root/start.fail-once"
        return 1
    fi
}
_refresh_runtime_environment_unlocked() {
    printf '%s\n' refresh >> "$trace"
}
_unset_system_proxy() {
    printf '%s\n' proxy-off >> "$trace"
}
_download_config() {
    printf 'downloaded:%s\n' "$2" > "$1"
}

reset_fixture() {
    rm -rf -- "$MIHOMO_BASE_DIR"
    mkdir -p "$MIHOMO_BASE_DIR/config"
    printf '%s\n' raw-v1 > "$MIHOMO_CONFIG_RAW"
    printf '%s\n' backup-v0 > "$MIHOMO_CONFIG_RAW_BAK"
    printf '%s\n' runtime-v1 > "$MIHOMO_CONFIG_RUNTIME"
    printf '%s\n' 'https://saved.example/sub' > "$MIHOMO_CONFIG_URL"
    printf '%s\n' mixin-v1 > "$MIHOMO_CONFIG_MIXIN"
    printf '%s\n' 'PROXY_MODE=auto' 'PROXY_PORT=' > "$MIHOMO_PORT_PREF"
    printf '%s\n' stopped > "$service_state"
    printf '%s\n' runtime-v1 > "$actual_runtime"
    : > "$trace"
    rm -f "$test_root/validation.fail" "$test_root/start.fail-once"
}

snapshot_all() {
    prefix=$1
    cp "$MIHOMO_CONFIG_RAW" "$prefix.raw"
    cp "$MIHOMO_CONFIG_RAW_BAK" "$prefix.raw-bak"
    cp "$MIHOMO_CONFIG_RUNTIME" "$prefix.runtime"
    cp "$MIHOMO_CONFIG_URL" "$prefix.url"
    cp "$MIHOMO_CONFIG_MIXIN" "$prefix.mixin"
    cp "$MIHOMO_PORT_PREF" "$prefix.port"
    cp "$service_state" "$prefix.service"
}

assert_snapshot() {
    prefix=$1
    cmp -s "$prefix.raw" "$MIHOMO_CONFIG_RAW" || fail 'raw config changed after failure'
    cmp -s "$prefix.raw-bak" "$MIHOMO_CONFIG_RAW_BAK" || fail 'raw backup changed after failure'
    cmp -s "$prefix.runtime" "$MIHOMO_CONFIG_RUNTIME" || fail 'runtime changed after failure'
    cmp -s "$prefix.url" "$MIHOMO_CONFIG_URL" || fail 'URL changed after failure'
    cmp -s "$prefix.mixin" "$MIHOMO_CONFIG_MIXIN" || fail 'mixin changed after failure'
    cmp -s "$prefix.port" "$MIHOMO_PORT_PREF" || fail 'port preference changed after failure'
    cmp -s "$prefix.service" "$service_state" || fail 'service state changed after failure'
}

trace_count() {
    grep -c "^$1$" "$trace" 2>/dev/null || true
}

# clash on validates a private candidate, publishes it atomically, starts a
# stopped service, and enters through the command lock.
reset_fixture
clashon || fail 'clash on failed'
[ "$(cat "$service_state")" = running ] || fail 'clash on did not start the service'
grep -Fq raw-v1 "$MIHOMO_CONFIG_RUNTIME" || fail 'clash on published the wrong runtime'
[ "$(trace_count 'lock:_clashon_locked')" -eq 1 ] || fail 'clash on skipped the lock'
[ "$(trace_count start)" -eq 1 ] || fail 'clash on did not start exactly once'

# Candidate validation failure is pre-publication: a running service and its
# runtime remain untouched and are never stopped.
reset_fixture
printf '%s\n' running > "$service_state"
snapshot_all "$test_root/validation.before"
: > "$test_root/validation.fail"
if clashon >/dev/null 2>&1; then
    fail 'invalid runtime candidate was accepted'
fi
assert_snapshot "$test_root/validation.before"
[ "$(trace_count stop)" -eq 0 ] || fail 'validation failure stopped the service'
[ "$(trace_count start)" -eq 0 ] || fail 'validation failure started the service'

# Startup failure after publication restores the old runtime and original
# stopped state.
reset_fixture
snapshot_all "$test_root/on-start.before"
: > "$test_root/start.fail-once"
if clashon >/dev/null 2>&1; then
    fail 'clash on startup failure was reported as success'
fi
assert_snapshot "$test_root/on-start.before"
cmp -s "$MIHOMO_CONFIG_RUNTIME" "$actual_runtime" &&
    fail 'failed candidate remained the actual runtime'

# Restart keeps a running service running. A publication failure also restores
# the original runtime and service state.
reset_fixture
printf '%s\n' running > "$service_state"
clashrestart || fail 'restart failed'
[ "$(cat "$service_state")" = running ] || fail 'restart did not preserve running state'
[ "$(trace_count 'lock:_clashrestart_unlocked')" -eq 1 ] || fail 'restart skipped the lock'
[ "$(trace_count stop)" -eq 1 ] || fail 'restart did not stop once'
[ "$(trace_count start)" -eq 1 ] || fail 'restart did not start once'

reset_fixture
printf '%s\n' running > "$service_state"
snapshot_all "$test_root/publish.before"
if (
    _config_publish() { return 1; }
    clashrestart >/dev/null 2>&1
); then
    fail 'publication failure was reported as success'
fi
assert_snapshot "$test_root/publish.before"
cmp -s "$MIHOMO_CONFIG_RUNTIME" "$actual_runtime" ||
    fail 'publication rollback restarted the wrong runtime'

# Mixin changes use one lock and one candidate pair. Shell-looking secret input
# remains plain data, and a stopped service stays stopped.
reset_fixture
injection_marker="$test_root/secret-executed"
secret='"; $(touch '"$injection_marker"'); #'
_apply_mixin_change secret "$secret" || fail 'mixin secret update failed'
grep -Fqx "secret=$secret" "$MIHOMO_CONFIG_MIXIN" ||
    fail 'secret was not preserved as plain data'
grep -Fqx "secret=$secret" "$MIHOMO_CONFIG_RUNTIME" ||
    fail 'runtime did not include the mixin candidate'
[ ! -e "$injection_marker" ] || fail 'secret input executed as shell code'
[ "$(cat "$service_state")" = stopped ] || fail 'mixin change started a stopped service'
[ "$(trace_count 'lock:_apply_mixin_change_locked')" -eq 1 ] ||
    fail 'mixin change skipped the lock'

# A running mixin change that cannot start rolls back both files and restarts
# the old runtime.
reset_fixture
printf '%s\n' running > "$service_state"
snapshot_all "$test_root/mixin.before"
: > "$test_root/start.fail-once"
if _apply_mixin_change lan true >/dev/null 2>&1; then
    fail 'mixin startup failure was reported as success'
fi
assert_snapshot "$test_root/mixin.before"
cmp -s "$MIHOMO_CONFIG_RUNTIME" "$actual_runtime" ||
    fail 'mixin rollback restarted the wrong runtime'

# Port changes publish the preference and rebuilt runtime under one lock. A
# startup failure restores both and preserves the running state.
reset_fixture
printf '%s\n' running > "$service_state"
clashport set 23456 || fail 'manual port change failed'
grep -Fq 'PROXY_MODE=manual' "$MIHOMO_PORT_PREF" ||
    fail 'manual port preference was not published'
grep -Fq 'port=manual:23456' "$MIHOMO_CONFIG_RUNTIME" ||
    fail 'runtime did not use the manual port'
[ "$(cat "$service_state")" = running ] || fail 'port change stopped the service'
[ "$(trace_count 'lock:_clashport_apply_locked')" -eq 1 ] ||
    fail 'port change skipped the lock'

reset_fixture
printf '%s\n' running > "$service_state"
snapshot_all "$test_root/port.before"
: > "$test_root/start.fail-once"
if clashport auto >/dev/null 2>&1; then
    fail 'port startup failure was reported as success'
fi
assert_snapshot "$test_root/port.before"
cmp -s "$MIHOMO_CONFIG_RUNTIME" "$actual_runtime" ||
    fail 'port rollback restarted the wrong runtime'

# Subscription update shares the same lifecycle rules: successful running
# update restarts once, while startup failure restores all managed files.
reset_fixture
printf '%s\n' running > "$service_state"
clashupdate 'https://new.example/sub' || fail 'lifecycle update failed'
grep -Fq 'downloaded:https://new.example/sub' "$MIHOMO_CONFIG_RAW" ||
    fail 'update did not publish the downloaded raw file'
[ "$(cat "$MIHOMO_CONFIG_RAW_BAK")" = raw-v1 ] || fail 'update did not back up raw'
[ "$(cat "$service_state")" = running ] || fail 'update stopped the running service'
[ "$(trace_count 'lock:_clashupdate_locked')" -eq 1 ] || fail 'update skipped the lock'

reset_fixture
printf '%s\n' running > "$service_state"
snapshot_all "$test_root/update.before"
: > "$test_root/start.fail-once"
if clashupdate 'https://failed.example/sub' >/dev/null 2>&1; then
    fail 'update startup failure was reported as success'
fi
assert_snapshot "$test_root/update.before"
cmp -s "$MIHOMO_CONFIG_RUNTIME" "$actual_runtime" ||
    fail 'update rollback restarted the wrong runtime'

# Unsupported path types are rejected before config or service mutation.
reset_fixture
mv "$MIHOMO_CONFIG_RUNTIME" "$MIHOMO_CONFIG_RUNTIME.target"
ln -s "$MIHOMO_CONFIG_RUNTIME.target" "$MIHOMO_CONFIG_RUNTIME"
if clashon >/dev/null 2>&1; then
    fail 'clash on accepted a runtime symlink'
fi
[ -L "$MIHOMO_CONFIG_RUNTIME" ] || fail 'runtime symlink was replaced'
[ "$(trace_count stop)" -eq 0 ] || fail 'runtime symlink stopped the service'

reset_fixture
mv "$MIHOMO_CONFIG_MIXIN" "$MIHOMO_CONFIG_MIXIN.target"
ln -s "$MIHOMO_CONFIG_MIXIN.target" "$MIHOMO_CONFIG_MIXIN"
if _apply_mixin_change tun true >/dev/null 2>&1; then
    fail 'mixin change accepted a symlink'
fi
[ -L "$MIHOMO_CONFIG_MIXIN" ] || fail 'mixin symlink was replaced'
[ "$(trace_count stop)" -eq 0 ] || fail 'mixin symlink stopped the service'

reset_fixture
rm -f "$MIHOMO_PORT_PREF"
mkdir "$MIHOMO_PORT_PREF"
if clashport auto >/dev/null 2>&1; then
    fail 'port change accepted a special preference path'
fi
[ -d "$MIHOMO_PORT_PREF" ] || fail 'special port path was replaced'
[ "$(trace_count stop)" -eq 0 ] || fail 'special port path stopped the service'

reset_fixture
mv "$MIHOMO_CONFIG_RAW" "$MIHOMO_CONFIG_RAW.target"
ln -s "$MIHOMO_CONFIG_RAW.target" "$MIHOMO_CONFIG_RAW"
if clashupdate >/dev/null 2>&1; then
    fail 'update accepted a managed symlink'
fi
[ -L "$MIHOMO_CONFIG_RAW" ] || fail 'update replaced the managed symlink'
[ ! -s "$trace" ] || fail 'update path preflight acquired the lock or mutated service'

printf '%s\n' 'lifecycle regression tests passed'
