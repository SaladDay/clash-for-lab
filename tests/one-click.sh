#!/usr/bin/env bash

set -eu
set -o pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
repo_root=$(cd -- "$script_dir/.." && pwd -P)
test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' EXIT

fail() {
    printf 'test-one-click: %s\n' "$*" >&2
    exit 1
}

export HOME="$test_root/home"
mkdir -p "$HOME"
set +u
. "$repo_root/script/common.sh"
. "$repo_root/script/upgrade.sh"
. "$repo_root/script/clashctl.sh"
. "$repo_root/script/node.sh"
set -u

# ── dispatcher strips the command name ─────────────────────────────

(
    clashlog() { printf 'log:%s\n' "$*"; }
    clashwatchdog() { printf 'watchdog:%s\n' "$*"; }
    clashnode() { printf 'node:%s\n' "$*"; }
    [ "$(clashctl log 3)" = 'log:3' ] || fail 'clash log received its own name'
    [ "$(clashctl watchdog on)" = 'watchdog:on' ] || fail 'clash watchdog received its own name'
    [ "$(clashctl node use x)" = 'node:use x' ] || fail 'clash node arguments'
    clashctl help >/dev/null || fail 'help must succeed'
    ! clashctl bogus >/dev/null 2>&1 || fail 'unknown command must fail'
)

# ── an explicit false preference stays false (real yq) ─────────────

(
    tar -xzf "$repo_root"/resources/zip/yq_linux_amd64.tar.gz -C "$test_root"
    BIN_YQ=$(find "$test_root" -maxdepth 1 -name 'yq_*' -type f | head -n 1)
    MIHOMO_CONFIG_MIXIN="$test_root/mixin.yaml"
    printf 'system-proxy:\n  enable: false\n' > "$MIHOMO_CONFIG_MIXIN"
    [ "$(_system_proxy_preference)" = false ] || fail 'explicit false was read as true'
    printf 'system-proxy:\n  enable: true\n' > "$MIHOMO_CONFIG_MIXIN"
    [ "$(_system_proxy_preference)" = true ] || fail 'true was not preserved'
    printf 'mode: rule\n' > "$MIHOMO_CONFIG_MIXIN"
    [ "$(_system_proxy_preference)" = true ] || fail 'missing preference must default to true'

    # Node table: nodes without any history must not break the query.
    _node_api() {
        printf '%s' '{"proxies":{"G":{"all":["DIRECT","🇭🇰 A 1","B"]},"DIRECT":{"type":"Direct","history":[]},"🇭🇰 A 1":{"type":"Shadowsocks","history":[{"delay":9},{"delay":80}]},"B":{"type":"Trojan","history":[{"delay":40}]}}}'
    }
    table=$(_node_table G)
    [ "$(printf '%s\n' "$table" | wc -l | tr -d ' ')" = 3 ] || fail 'node table is incomplete'
    [ "$(printf '%s\n' "$table" | _node_rank | head -n 1 | cut -f1)" = B ] ||
        fail 'best node is not the fastest real proxy'
)

# ── node name resolution ───────────────────────────────────────────

(
    _failcat() { return 1; }
    table=$(printf '%s\t%s\t%s\n' DIRECT Direct 1 '香港 01' Trojan 50 '香港 02' Trojan 40 '日本 [x]' Trojan 0 '剩余流量：1G' Trojan 3)
    [ "$(_node_resolve "$table" 2)" = '香港 01' ] || fail 'resolve by number'
    [ "$(_node_resolve "$table" '香港 02')" = '香港 02' ] || fail 'resolve by exact name'
    [ "$(_node_resolve "$table" 日本)" = '日本 [x]' ] || fail 'resolve by part'
    [ "$(_node_resolve "$table" '[x]')" = '日本 [x]' ] || fail 'query must not be a pattern'
    ! _node_resolve "$table" 香港 >/dev/null 2>&1 || fail 'ambiguous name accepted'
    ! _node_resolve "$table" 99 >/dev/null 2>&1 || fail 'out-of-range number accepted'
    ! _node_resolve "$table" '' >/dev/null 2>&1 || fail 'empty query accepted'
    [ "$(printf '%s\n' "$table" | _node_rank | head -n 1 | cut -f1)" = '香港 02' ] ||
        fail 'DIRECT or an informational entry won the speed test'
    [ "$(_node_urlencode 'a/b 港')" = '%61%2f%62%20%e6%b8%af' ] || fail 'urlencode'
)

# ── API secret never reaches curl argv ─────────────────────────────

(
    BIN_YQ="$test_root/secret-yq"
    printf '%s\n' '#!/bin/sh' 'printf "%s\n" topsecret' > "$BIN_YQ"
    chmod 0755 "$BIN_YQ"
    UI_PORT=1
    curl() { printf '%s\n' "$*" > "$test_root/argv"; cat > "$test_root/stdin"; }
    _node_api GET /proxies
    ! grep -q topsecret "$test_root/argv" || fail 'secret leaked to argv'
    grep -q 'Bearer topsecret' "$test_root/stdin" || fail 'secret was not sent'
)

# ── status output hides the subscription token ─────────────────────

[ "$(_mask_subscription_url 'https://u:p@a.example:8443/sub?token=abc')" = 'https://a.example:8443/***' ] ||
    fail 'subscription URL was not masked'
[ "$(_mask_subscription_url 'https://a.example?token=abc')" = 'https://a.example/***' ] ||
    fail 'query-only subscription URL was not masked'

# ── the probe must really use the proxy ────────────────────────────

(
    curl() { cat >/dev/null; printf '%s\n' "$@" >> "$test_root/probe"; return 1; }
    _connectivity_check 1 2 '' 'u:p' </dev/null >/dev/null
    grep -A1 -x -- '--proxy' "$test_root/probe" | grep -qx 'http://127.0.0.1:2' || fail 'probe proxy'
    ! grep -q gstatic "$test_root/probe" || fail 'probe target is usually routed DIRECT'
    ! grep -q 'u:p' "$test_root/probe" || fail 'proxy credentials leaked to argv'
)

# ── zip extraction without unzip ───────────────────────────────────

if command -v python3 >/dev/null 2>&1; then
    (
        mkdir -p "$test_root/nozip" "$test_root/out"
        ln -s "$(command -v python3)" "$test_root/nozip/python3"
        python3 -c 'import sys,zipfile
zipfile.ZipFile(sys.argv[1],"w").writestr("dist/index.html","ok")' "$test_root/a.zip"
        PATH="$test_root/nozip" _extract_zip "$test_root/a.zip" "$test_root/out" ||
            fail 'zip fallback failed'
        [ "$(cat "$test_root/out/dist/index.html")" = ok ] || fail 'zip fallback content'
    )
fi

# ── launcher never replaces a user's own command ───────────────────

mkdir -p "$HOME/.local/bin"
printf 'mine\n' > "$HOME/.local/bin/clash"
_launcher_install
_launcher_remove
[ "$(cat "$HOME/.local/bin/clash")" = mine ] || fail 'a user command was touched'
rm "$HOME/.local/bin/clash"
_launcher_install
[ -L "$HOME/.local/bin/clash" ] || fail 'launcher was not created'
_launcher_remove
[ ! -L "$HOME/.local/bin/clash" ] || fail 'launcher was not removed'

# ── get.sh ─────────────────────────────────────────────────────────

# A truncated download must not execute anything.
size=$(wc -c < "$repo_root/get.sh")
head -c $((size - 12)) "$repo_root/get.sh" > "$test_root/truncated.sh"
[ -z "$(bash "$test_root/truncated.sh" https://example.invalid/sub 2>/dev/null </dev/null || true)" ] ||
    fail 'truncated get.sh executed code'
bash "$repo_root/get.sh" --help >/dev/null || fail 'get.sh --help'
! bash "$repo_root/get.sh" --nope >/dev/null 2>&1 || fail 'get.sh accepted an unknown option'

printf 'one-click tests passed\n'
