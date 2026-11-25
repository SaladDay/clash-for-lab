#!/usr/bin/env bash
# shellcheck disable=SC2148

# Management scripts are published as one immutable directory. The stable
# `script` entry is switched only after every file has been copied and parsed.
# clash-for-lab serializes this function with the normal operation lock; files
# owned by the same Unix account are not treated as an adversarial boundary.

_script_release_archive() {
    local source=$1 recovery
    [ -e "$source" ] || [ -L "$source" ] || return 0
    recovery=$(mktemp -d "${MIHOMO_BASE_DIR}/script.recovery.XXXXXX") || return 1
    chmod 0700 "$recovery" || return 1
    mv "$source" "$recovery/original" || return 1
    _failcat "旧管理脚本已保存在：$recovery" || true
}

_script_release_switch() {
    local source=$1 destination=$2
    mv -fT "$source" "$destination" 2>/dev/null ||
        mv -fh "$source" "$destination" 2>/dev/null
}

_script_release_owned_target() {
    local descriptor=$1
    case "$descriptor" in
    script.release.*)
        case "$descriptor" in */*) return 1 ;; esac
        printf '%s/%s\n' "$MIHOMO_BASE_DIR" "$descriptor"
        ;;
    *) return 1 ;;
    esac
}

_install_script_release() (
    local update_rc=${1:-true}
    local stage='' link_tmp='' old_target='' old_release='' legacy_recovery=''
    local committed=false module

    cleanup() {
        local result=$?
        trap - EXIT HUP INT TERM
        [ "$committed" = true ] || {
            [ -z "$link_tmp" ] || rm -f "$link_tmp" 2>/dev/null || true
            [ -z "$stage" ] || rm -rf "$stage" 2>/dev/null || true
            if [ -n "$legacy_recovery" ] &&
                [ ! -e "$MIHOMO_SCRIPT_DIR" ] && [ ! -L "$MIHOMO_SCRIPT_DIR" ]; then
                mv "$legacy_recovery/original" "$MIHOMO_SCRIPT_DIR" 2>/dev/null || true
                rmdir "$legacy_recovery" 2>/dev/null || true
            fi
        }
        exit "$result"
    }
    trap cleanup EXIT HUP INT TERM

    [ -d "$SCRIPT_BASE_DIR" ] && [ ! -L "$SCRIPT_BASE_DIR" ] || return 1
    mkdir -p "$MIHOMO_BASE_DIR" || return 1
    [ -d "$MIHOMO_BASE_DIR" ] && [ ! -L "$MIHOMO_BASE_DIR" ] || return 1

    stage=$(mktemp -d "${MIHOMO_BASE_DIR}/script.release.XXXXXX") || return 1
    cp -a "$SCRIPT_BASE_DIR/." "$stage/" || return 1
    {
        printf '%s\n' '# Managed clash-for-lab release.'
        cat "$stage/common.sh"
        printf '\n'
        cat "$stage/upgrade.sh"
        printf '\n'
        cat "$stage/clashctl.sh"
        for module in node.sh subs.sh; do
            [ -f "$stage/$module" ] || continue
            printf '\n'
            cat "$stage/$module"
        done
    } > "$stage/managed.sh" || return 1
    bash -n "$stage"/*.sh || return 1
    if command -v zsh >/dev/null 2>&1; then
        zsh -n "$stage"/*.sh || return 1
    fi

    link_tmp=$(mktemp "${MIHOMO_BASE_DIR}/.script-link.XXXXXX") || return 1
    rm -f "$link_tmp" || return 1
    ln -s "${stage##*/}" "$link_tmp" || return 1

    if [ -L "$MIHOMO_SCRIPT_DIR" ]; then
        old_target=$(readlink "$MIHOMO_SCRIPT_DIR") || return 1
        old_release=$(_script_release_owned_target "$old_target" 2>/dev/null || true)
        _script_release_switch "$link_tmp" "$MIHOMO_SCRIPT_DIR" || return 1
        link_tmp=''
    elif [ -d "$MIHOMO_SCRIPT_DIR" ]; then
        legacy_recovery=$(mktemp -d "${MIHOMO_BASE_DIR}/script.recovery.XXXXXX") || return 1
        chmod 0700 "$legacy_recovery" || return 1
        mv "$MIHOMO_SCRIPT_DIR" "$legacy_recovery/original" || return 1
        mv "$link_tmp" "$MIHOMO_SCRIPT_DIR" || return 1
        link_tmp=''
    elif [ ! -e "$MIHOMO_SCRIPT_DIR" ] && [ ! -L "$MIHOMO_SCRIPT_DIR" ]; then
        mv "$link_tmp" "$MIHOMO_SCRIPT_DIR" || return 1
        link_tmp=''
    else
        return 1
    fi

    committed=true
    [ -z "$old_release" ] || [ "$old_release" = "$stage" ] ||
        _script_release_archive "$old_release" || true
    [ -z "$legacy_recovery" ] ||
        _failcat "旧管理脚本已保存在：$legacy_recovery" || true

    if [ "$update_rc" = true ]; then
        _set_rc || return 1
    fi
)
