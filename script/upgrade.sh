#!/usr/bin/env bash
# shellcheck disable=SC2148,SC2155

# GitHub Actions keeps the repository bundle on the latest stable Mihomo
# release. Clients resolve main to one immutable commit and fetch both the
# manifest and payload from that commit.

MIHOMO_UPGRADE_TIMEOUT="${MIHOMO_UPGRADE_TIMEOUT:-120}"
MIHOMO_UPGRADE_GRACE="${MIHOMO_UPGRADE_GRACE:-2}"
MIHOMO_UPGRADE_STATE_DIR="${MIHOMO_BASE_DIR}/state"
MIHOMO_UPGRADE_STATE_LOCK="${MIHOMO_UPGRADE_STATE_DIR}/mihomo.lock.tsv"
MIHOMO_UPGRADE_PREVIOUS_STATE="${MIHOMO_UPGRADE_STATE_DIR}/mihomo.previous.lock.tsv"
MIHOMO_UPGRADE_PREVIOUS="${MIHOMO_BASE_DIR}/bin/mihomo.previous"
MIHOMO_UPGRADE_LOCK_DIR="${HOME}/.cache/clash-for-lab/mihomo-operation.lock"
_UPGRADE_LOCK_METHOD=''
_UPGRADE_LOCK_HELD=''
_UPGRADE_LOCK_PATH=''

_upgrade_info() {
    if command -v _okcat >/dev/null 2>&1; then
        _okcat '🔄' "$1"
    else
        printf '%s\n' "$1"
    fi
}

_upgrade_fail() {
    if command -v _failcat >/dev/null 2>&1; then
        _failcat '⛔' "$1" || true
    else
        printf 'error: %s\n' "$1" >&2
    fi
    return 1
}

_upgrade_platform() {
    local os arch
    os=$(uname -s 2>/dev/null)
    arch=$(uname -m 2>/dev/null)
    case "$os:$arch" in
    Linux:x86_64|Linux:amd64)
        UPGRADE_OS=linux
        UPGRADE_ARCH=amd64
        UPGRADE_VARIANT=v1
        ;;
    *)
        _upgrade_fail "当前版本仅支持 Linux amd64，检测到：${os:-unknown} ${arch:-unknown}"
        return 1
        ;;
    esac
}

_upgrade_json() {
    local expression=$1 file=$2 tool
    tool=${BIN_YQ:-}
    [ -x "$tool" ] || tool=$(command -v yq 2>/dev/null || true)
    [ -x "$tool" ] || tool=$(command -v jq 2>/dev/null || true)
    [ -x "$tool" ] || {
        _upgrade_fail "缺少 JSON 解析器：请确认 yq 已正确安装"
        return 1
    }
    case "$(basename "$tool")" in
    yq) "$tool" eval -r "$expression" "$file" ;;
    *) "$tool" -r "$expression" "$file" ;;
    esac
}

_upgrade_fetch_url() {
    local url=$1 destination=$2 api_request=${3:-false} part="${destination}.part"
    rm -f "$part"
    if [ "$api_request" = true ]; then
        curl --disable --silent --show-error --fail --location \
            --proto '=https' --tlsv1.2 --connect-timeout 15 \
            --max-time "$MIHOMO_UPGRADE_TIMEOUT" --retry 2 \
            -H 'Accept: application/vnd.github+json' \
            -H 'X-GitHub-Api-Version: 2022-11-28' \
            --output "$part" "$url" || {
            rm -f "$part"
            return 1
        }
    else
        curl --disable --silent --show-error --fail --location \
            --proto '=https' --tlsv1.2 --connect-timeout 15 \
            --max-time "$MIHOMO_UPGRADE_TIMEOUT" --retry 2 \
            --output "$part" "$url" || {
            rm -f "$part"
            return 1
        }
    fi
    mv "$part" "$destination"
}

_upgrade_sha256() {
    local file=$1
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$file" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$file" | awk '{print $1}'
    elif command -v openssl >/dev/null 2>&1; then
        openssl dgst -sha256 "$file" | awk '{print $NF}'
    else
        _upgrade_fail "缺少 SHA256 校验工具"
        return 1
    fi
}

_upgrade_file_size() {
    LC_ALL=C wc -c < "$1" | tr -d '[:space:]'
}

_upgrade_version_from_output() {
    awk '
        {
            for (field = 1; field <= NF; field++) {
                if ($field ~ /^v[0-9]+\.[0-9]+\.[0-9]+/ &&
                    $field !~ /^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$/) {
                    invalid = 1
                }
                if ($field ~ /^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$/) {
                    count++
                    version = $field
                }
            }
        }
        END {
            if (invalid || count != 1) exit 1
            print version
        }
    '
}

_upgrade_binary_version() {
    local binary=$1 output
    [ -f "$binary" ] && [ ! -L "$binary" ] && [ -x "$binary" ] || return 1
    output=$(timeout --kill-after=5 "$MIHOMO_UPGRADE_TIMEOUT" "$binary" -v 2>&1) || return 1
    printf '%s\n' "$output" | _upgrade_version_from_output
}

_upgrade_parse_manifest() {
    local manifest=$1 row
    row=$(LC_ALL=C awk -F '\t' \
        -v os="$UPGRADE_OS" -v arch="$UPGRADE_ARCH" -v variant="$UPGRADE_VARIANT" '
        NR == 1 { if (NF != 2 || $1 != "schema" || $2 != "1") exit 1; next }
        NR == 2 {
            if (NF != 8 || $1 != "asset" || $2 != os || $3 != arch || $4 != variant) exit 1
            row = $0
            next
        }
        { exit 1 }
        END { if (NR != 2) exit 1; print row }
    ' "$manifest") || {
        _upgrade_fail "内核版本清单格式无效"
        return 1
    }
    IFS=$(printf '\t') read -r _ _ _ _ UPGRADE_REMOTE_VERSION UPGRADE_REMOTE_FILE \
        UPGRADE_REMOTE_SIZE UPGRADE_REMOTE_SHA256 <<EOF
$row
EOF
    UPGRADE_REMOTE_SHA256=$(printf '%s' "$UPGRADE_REMOTE_SHA256" | tr 'A-F' 'a-f')
    printf '%s' "$UPGRADE_REMOTE_VERSION" |
        grep -Eq '^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$' || {
        _upgrade_fail "版本清单中的版本号无效"
        return 1
    }
    [ "$UPGRADE_REMOTE_FILE" = 'mihomo-linux-amd64-v1.gz' ] || {
        _upgrade_fail "版本清单中的文件名不受信任"
        return 1
    }
    printf '%s' "$UPGRADE_REMOTE_SIZE" | grep -Eq '^[1-9][0-9]*$' || {
        _upgrade_fail "版本清单中的文件大小无效"
        return 1
    }
    printf '%s' "$UPGRADE_REMOTE_SHA256" | grep -Eq '^[0-9a-f]{64}$' || {
        _upgrade_fail "版本清单中的 SHA256 无效"
        return 1
    }
}

_upgrade_resolve_repository_snapshot() {
    local tmpdir=$1 repository='SaladDay/clash-for-lab' branch='main'
    local commit_json manifest commit_sha git_command
    commit_json="$tmpdir/commit.json"
    manifest="$tmpdir/mihomo.lock.tsv"
    commit_sha=
    if _upgrade_fetch_url \
        "https://api.github.com/repos/${repository}/commits/${branch}" \
        "$commit_json" true; then
        commit_sha=$(_upgrade_json '.sha' "$commit_json" 2>/dev/null || true)
    fi
    git_command=$(command -v git 2>/dev/null || true)
    if ! printf '%s' "$commit_sha" | grep -Eq '^([0-9a-f]{40}|[0-9a-f]{64})$' &&
        [ -n "$git_command" ]; then
        commit_sha=$(
            cd "$tmpdir" || exit 1
            timeout --kill-after=5 "$MIHOMO_UPGRADE_TIMEOUT" \
                env -i PATH=/usr/bin:/bin GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0 \
                "$git_command" -c credential.helper= ls-remote --exit-code \
                "https://github.com/${repository}.git" "refs/heads/${branch}" 2>/dev/null |
                awk -v ref="refs/heads/${branch}" '$2 == ref { print $1; exit }' || true
        )
    fi
    printf '%s' "$commit_sha" | grep -Eq '^([0-9a-f]{40}|[0-9a-f]{64})$' || {
        _upgrade_fail "无法解析 clash-for-lab 最新 commit（GitHub API 和 git 均不可用）"
        return 1
    }
    _upgrade_fetch_url \
        "https://raw.githubusercontent.com/${repository}/${commit_sha}/resources/mihomo.lock.tsv" \
        "$manifest" || {
        _upgrade_fail "无法下载内核版本清单"
        return 1
    }
    _upgrade_parse_manifest "$manifest" || return 1
    UPGRADE_REMOTE_COMMIT=$commit_sha
    UPGRADE_REMOTE_MANIFEST=$manifest
    UPGRADE_REMOTE_URL="https://raw.githubusercontent.com/${repository}/${commit_sha}/resources/zip/${UPGRADE_REMOTE_FILE}"
}

_upgrade_verify_archive() {
    local archive=$1 actual_size actual_sha
    actual_size=$(_upgrade_file_size "$archive") || return 1
    [ "$actual_size" = "$UPGRADE_REMOTE_SIZE" ] || {
        _upgrade_fail "内核文件大小不匹配：期望 $UPGRADE_REMOTE_SIZE，实际 $actual_size"
        return 1
    }
    actual_sha=$(_upgrade_sha256 "$archive") || return 1
    actual_sha=$(printf '%s' "$actual_sha" | tr 'A-F' 'a-f')
    [ "$actual_sha" = "$UPGRADE_REMOTE_SHA256" ] || {
        _upgrade_fail "内核 SHA256 校验失败"
        return 1
    }
    gzip -t "$archive" 2>/dev/null || {
        _upgrade_fail "内核压缩包已损坏"
        return 1
    }
}

_upgrade_binary_accepts_published_config() (
    local binary=$1 config validation_home validation_status=0
    validation_home="${binary}.validation-home"
    _cleanup_upgrade_validation_home() {
        rm -rf "$validation_home"
    }
    trap '_cleanup_upgrade_validation_home' EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    rm -rf "$validation_home" || return 1
    for config in "$MIHOMO_CONFIG_RUNTIME" "$MIHOMO_CONFIG_RAW"; do
        [ -f "$config" ] || continue
        BIN_KERNEL="$binary" MIHOMO_CONFIG_TEST_TIMEOUT="$MIHOMO_UPGRADE_TIMEOUT" \
            _valid_config "$config" "$MIHOMO_BASE_DIR" "$validation_home" ||
            validation_status=1
        [ "$validation_status" -eq 0 ] || break
    done
    if [ "$validation_status" -eq 0 ] &&
        ! _config_validation_data_is_installed "$validation_home" "$MIHOMO_BASE_DIR"; then
        validation_status=1
    fi
    return "$validation_status"
)

_upgrade_prepare_candidate() {
    local archive=$1 candidate=$2 version
    gzip -dc "$archive" > "$candidate" || {
        rm -f "$candidate"
        _upgrade_fail "解压 mihomo 内核失败"
        return 1
    }
    chmod 0755 "$candidate" || return 1
    version=$(_upgrade_binary_version "$candidate") || {
        _upgrade_fail "候选内核无法在当前机器运行"
        return 1
    }
    [ "$version" = "$UPGRADE_REMOTE_VERSION" ] || {
        _upgrade_fail "候选内核版本不匹配：期望 $UPGRADE_REMOTE_VERSION，实际 $version"
        return 1
    }
    _upgrade_binary_accepts_published_config "$candidate" || {
        _upgrade_fail "新内核无法通过当前配置检查"
        return 1
    }
}

_upgrade_parse_state() {
    local state=$1 row
    [ -f "$state" ] && [ ! -L "$state" ] || return 1
    row=$(LC_ALL=C awk -F '\t' \
        -v os="$UPGRADE_OS" -v arch="$UPGRADE_ARCH" -v variant="$UPGRADE_VARIANT" '
        NR == 1 { if (NF != 2 || $1 != "schema" || $2 != "2") bad = 1; next }
        NR == 2 {
            if (NF != 8 || $1 != "asset" || $2 != os || $3 != arch || $4 != variant) bad = 1
            else { av=$5; af=$6; as=$7; ah=$8 }
            next
        }
        NR == 3 {
            if (NF != 4 || $1 != "binary") bad = 1
            else { bv=$2; bs=$3; bh=$4 }
            next
        }
        { bad = 1 }
        END { if (NR != 3 || bad) exit 1; print av "\t" af "\t" as "\t" ah "\t" bv "\t" bs "\t" bh }
    ' "$state") || {
        _upgrade_fail "内核状态格式无效或缺少二进制身份"
        return 1
    }
    IFS=$(printf '\t') read -r UPGRADE_STATE_VERSION UPGRADE_STATE_FILE \
        UPGRADE_STATE_ARCHIVE_SIZE UPGRADE_STATE_ARCHIVE_SHA256 \
        UPGRADE_STATE_BINARY_VERSION UPGRADE_STATE_BINARY_SIZE \
        UPGRADE_STATE_BINARY_SHA256 <<EOF
$row
EOF
    printf '%s' "$UPGRADE_STATE_VERSION" |
        grep -Eq '^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$' || return 1
    [ "$UPGRADE_STATE_BINARY_VERSION" = "$UPGRADE_STATE_VERSION" ] || return 1
    [ "$UPGRADE_STATE_FILE" = 'mihomo-linux-amd64-v1.gz' ] || return 1
    printf '%s' "$UPGRADE_STATE_ARCHIVE_SIZE" | grep -Eq '^[1-9][0-9]*$' || return 1
    printf '%s' "$UPGRADE_STATE_ARCHIVE_SHA256" | grep -Eq '^[0-9a-f]{64}$' || return 1
    printf '%s' "$UPGRADE_STATE_BINARY_SIZE" | grep -Eq '^[1-9][0-9]*$' || return 1
    printf '%s' "$UPGRADE_STATE_BINARY_SHA256" | grep -Eq '^[0-9a-f]{64}$'
}

_upgrade_build_state_file() {
    local manifest=$1 binary=$2 destination=$3 binary_version binary_size binary_sha
    _upgrade_parse_manifest "$manifest" || return 1
    binary_version=$(_upgrade_binary_version "$binary") || return 1
    [ "$binary_version" = "$UPGRADE_REMOTE_VERSION" ] || return 1
    binary_size=$(_upgrade_file_size "$binary") || return 1
    binary_sha=$(_upgrade_sha256 "$binary") || return 1
    binary_sha=$(printf '%s' "$binary_sha" | tr 'A-F' 'a-f')
    {
        printf 'schema\t2\n'
        printf 'asset\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$UPGRADE_OS" "$UPGRADE_ARCH" "$UPGRADE_VARIANT" \
            "$UPGRADE_REMOTE_VERSION" "$UPGRADE_REMOTE_FILE" \
            "$UPGRADE_REMOTE_SIZE" "$UPGRADE_REMOTE_SHA256"
        printf 'binary\t%s\t%s\t%s\n' "$binary_version" "$binary_size" "$binary_sha"
    } > "$destination" || return 1
    chmod 0644 "$destination"
}

# Older installations have no state file. Record the current binary before
# replacing it so the first upgrade still has a usable rollback slot. The
# archive fields mirror the binary because the original package is unavailable;
# binary identity remains exact and is what rollback validates.
_upgrade_build_local_state_file() {
    local binary=$1 destination=$2 version size sha
    version=$(_upgrade_binary_version "$binary") || return 1
    printf '%s' "$version" |
        grep -Eq '^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$' || return 1
    size=$(_upgrade_file_size "$binary") || return 1
    sha=$(_upgrade_sha256 "$binary") || return 1
    sha=$(printf '%s' "$sha" | tr 'A-F' 'a-f')
    {
        printf 'schema\t2\n'
        printf 'asset\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$UPGRADE_OS" "$UPGRADE_ARCH" "$UPGRADE_VARIANT" \
            "$version" 'mihomo-linux-amd64-v1.gz' "$size" "$sha"
        printf 'binary\t%s\t%s\t%s\n' "$version" "$size" "$sha"
    } > "$destination" || return 1
    chmod 0644 "$destination"
}

_upgrade_binary_matches_state() {
    local binary=$1 state=$2 version size sha
    [ -f "$binary" ] && [ ! -L "$binary" ] && [ -x "$binary" ] || return 1
    _upgrade_parse_state "$state" || return 1
    size=$(_upgrade_file_size "$binary") || return 1
    [ "$size" = "$UPGRADE_STATE_BINARY_SIZE" ] || return 1
    sha=$(_upgrade_sha256 "$binary") || return 1
    sha=$(printf '%s' "$sha" | tr 'A-F' 'a-f')
    [ "$sha" = "$UPGRADE_STATE_BINARY_SHA256" ] || return 1
    version=$(_upgrade_binary_version "$binary") || return 1
    [ "$version" = "$UPGRADE_STATE_VERSION" ]
}

_upgrade_state_matches_manifest() {
    local state=$1 manifest=$2 version file size sha
    _upgrade_parse_manifest "$manifest" || return 1
    version=$UPGRADE_REMOTE_VERSION
    file=$UPGRADE_REMOTE_FILE
    size=$UPGRADE_REMOTE_SIZE
    sha=$UPGRADE_REMOTE_SHA256
    _upgrade_parse_state "$state" || return 1
    [ "$UPGRADE_STATE_VERSION" = "$version" ] &&
        [ "$UPGRADE_STATE_FILE" = "$file" ] &&
        [ "$UPGRADE_STATE_ARCHIVE_SIZE" = "$size" ] &&
        [ "$UPGRADE_STATE_ARCHIVE_SHA256" = "$sha" ]
}

_upgrade_atomic_copy() {
    local source=$1 destination=$2 staged
    mkdir -p "$(dirname "$destination")" || return 1
    staged=$(mktemp "${destination}.new.XXXXXX") || return 1
    if cp -p "$source" "$staged" && mv -f "$staged" "$destination"; then
        return 0
    fi
    rm -f "$staged"
    return 1
}

_upgrade_write_state_impl() {
    local source=$1 destination=${2:-$MIHOMO_UPGRADE_STATE_LOCK}
    _upgrade_atomic_copy "$source" "$destination" && chmod 0644 "$destination"
}

_upgrade_write_state() {
    _upgrade_write_state_impl "$@"
}

_upgrade_commit_transaction() {
    trap '' HUP INT TERM
    transaction_active=false
}

_upgrade_after_transaction_commit() { :; }
_upgrade_after_binary_publish() { :; }

_upgrade_make_tmp_dir() {
    local base="${MIHOMO_BASE_DIR}/tmp"
    mkdir -p "$base" || return 1
    mktemp -d "${base%/}/mihomo-upgrade.XXXXXX"
}

_upgrade_path_exists() {
    [ -e "$1" ] || [ -L "$1" ]
}

_upgrade_managed_file_ok() {
    local file_path=$1 required=${2:-false} executable=${3:-false}
    [ ! -L "$file_path" ] || return 1
    if [ -e "$file_path" ]; then
        [ -f "$file_path" ] || return 1
    elif [ "$required" = true ]; then
        return 1
    else
        return 0
    fi
    [ "$executable" != true ] || [ -x "$file_path" ]
}

_upgrade_acquire_lock() {
    local parent owner_file owner_tmp
    command -v flock >/dev/null 2>&1 && _UPGRADE_LOCK_METHOD=flock

    parent=$(dirname "$MIHOMO_UPGRADE_LOCK_DIR")
    mkdir -p "$parent" || return 1

    if [ "$_UPGRADE_LOCK_METHOD" = flock ]; then
        # If the lock path changed (e.g. a new test case), the old FD
        # and lock are stale.  Close FD 9 and reset state so the new
        # path can be acquired cleanly.
        if [ -n "$_UPGRADE_LOCK_HELD" ] && [ "$_UPGRADE_LOCK_PATH" != "$MIHOMO_UPGRADE_LOCK_DIR" ]; then
            flock -u 9 2>/dev/null || true
            exec 9>&- 2>/dev/null || true
            _UPGRADE_LOCK_HELD=''
            _UPGRADE_LOCK_METHOD=''
        fi
        # Refuse re-entrant acquisition within the same process.
        # Do NOT clear _UPGRADE_LOCK_METHOD: the lock is still held
        # and _upgrade_release_lock needs the method to release it.
        [ -z "${_UPGRADE_LOCK_HELD:-}" ] || return 1
        owner_file="${MIHOMO_UPGRADE_LOCK_DIR}.owner"
        _upgrade_managed_file_ok "$MIHOMO_UPGRADE_LOCK_DIR" false false || return 1
        _upgrade_managed_file_ok "$owner_file" false false || return 1
        if [ ! -e "$MIHOMO_UPGRADE_LOCK_DIR" ]; then
            (umask 077; : >> "$MIHOMO_UPGRADE_LOCK_DIR") || return 1
        fi
        exec 9>>"$MIHOMO_UPGRADE_LOCK_DIR" || return 1
        chmod 0600 "$MIHOMO_UPGRADE_LOCK_DIR" 2>/dev/null || true
        if ! flock -n 9; then
            exec 9>&-
            _UPGRADE_LOCK_METHOD=''
            return 1
        fi
        _UPGRADE_LOCK_HELD=1
        _UPGRADE_LOCK_PATH=$MIHOMO_UPGRADE_LOCK_DIR
    else
        # If the lock path changed, reset stale mkdir lock state.
        if [ -n "$_UPGRADE_LOCK_HELD" ] && [ "$_UPGRADE_LOCK_PATH" != "$MIHOMO_UPGRADE_LOCK_DIR" ]; then
            local old_lock_dir="${_UPGRADE_LOCK_PATH}.d"
            rm -f "${old_lock_dir}/owner" 2>/dev/null || true
            rmdir "$old_lock_dir" 2>/dev/null || true
            exec 9>&- 2>/dev/null || true
            _UPGRADE_LOCK_HELD=''
        fi
        # Refuse re-entrant acquisition within the same process.
        [ -z "${_UPGRADE_LOCK_HELD:-}" ] || return 1
        _UPGRADE_LOCK_METHOD=mkdir
        local lock_dir="${MIHOMO_UPGRADE_LOCK_DIR}.d"
        _upgrade_managed_file_ok "$lock_dir" false false || return 1
        if ! mkdir "$lock_dir" 2>/dev/null; then
            # Check for stale lock: if the owner PID is no longer alive,
            # remove the lock directory and retry.
            local stale_owner
            stale_owner=$(cat "${lock_dir}/owner" 2>/dev/null || true)
            if [ -n "$stale_owner" ] && ! kill -0 "$stale_owner" 2>/dev/null; then
                rm -f "${lock_dir}/owner" 2>/dev/null || true
                rmdir "$lock_dir" 2>/dev/null || true
                if ! mkdir "$lock_dir" 2>/dev/null; then
                    _UPGRADE_LOCK_METHOD=''
                    return 1
                fi
            else
                _UPGRADE_LOCK_METHOD=''
                return 1
            fi
        fi
        chmod 0700 "$lock_dir" 2>/dev/null || true
        exec 9>/dev/null || return 1
        owner_file="${lock_dir}/owner"
        _UPGRADE_LOCK_HELD=1
        _UPGRADE_LOCK_PATH=$MIHOMO_UPGRADE_LOCK_DIR
    fi

    owner=$(sh -c 'printf "%s\n" "$PPID"') || {
        _upgrade_release_lock
        return 1
    }
    owner_tmp=$(mktemp "${parent%/}/.mihomo-owner.XXXXXX") || {
        _upgrade_release_lock
        return 1
    }
    printf '%s\n' "$owner" > "$owner_tmp" && chmod 0600 "$owner_tmp" &&
        mv -f "$owner_tmp" "$owner_file" || {
        rm -f "$owner_tmp"
        _upgrade_release_lock
        return 1
    }
}

_upgrade_release_lock() {
    _UPGRADE_LOCK_HELD=''
    if [ "${_UPGRADE_LOCK_METHOD:-}" = mkdir ]; then
        local lock_dir="${MIHOMO_UPGRADE_LOCK_DIR}.d"
        local owner_file="${lock_dir}/owner"
        if [ -f "$owner_file" ] && [ ! -L "$owner_file" ]; then
            rm -f "$owner_file"
        fi
        rmdir "$lock_dir" 2>/dev/null || true
        exec 9>&-
        _UPGRADE_LOCK_METHOD=''
        return 0
    fi
    local owner_file="${MIHOMO_UPGRADE_LOCK_DIR}.owner"
    if [ -f "$owner_file" ] && [ ! -L "$owner_file" ]; then
        rm -f "$owner_file"
    fi
    flock -u 9 2>/dev/null || true
    exec 9>&-
    _UPGRADE_LOCK_METHOD=''
}

_upgrade_snapshot_file() {
    cp -p "$1" "$2"
}

_upgrade_restore_snapshot() {
    local snapshot=$1 destination=$2 existed=$3
    if [ "$existed" = true ]; then
        _upgrade_atomic_copy "$snapshot" "$destination"
    else
        rm -f "$destination"
    fi
}

_upgrade_restore_port_state() {
    if [ "${had_port_state:-false}" = true ]; then
        _upgrade_atomic_copy "$backup_port_state" "$port_state"
    else
        rm -f "$port_state"
    fi
}

_upgrade_transaction_cleanup() {
    local exit_status=$1 restore_failed=false
    trap '' HUP INT TERM
    trap - EXIT
    if [ "${transaction_active:-false}" = true ]; then
        if [ "${was_running:-false}" = true ]; then
            stop_mihomo >/dev/null 2>&1 || restore_failed=true
        fi
        _upgrade_restore_snapshot "$backup_current" "$target" "$had_current" || restore_failed=true
        _upgrade_restore_snapshot "$backup_previous" "$MIHOMO_UPGRADE_PREVIOUS" "$had_previous" || restore_failed=true
        _upgrade_restore_snapshot "$backup_current_state" "$MIHOMO_UPGRADE_STATE_LOCK" "$had_current_state" || restore_failed=true
        _upgrade_restore_snapshot "$backup_previous_state" "$MIHOMO_UPGRADE_PREVIOUS_STATE" "$had_previous_state" || restore_failed=true
        if [ "${was_running:-false}" = true ]; then
            _upgrade_restore_port_state || restore_failed=true
            start_mihomo >/dev/null 2>&1 || restore_failed=true
        fi
        if [ "$restore_failed" = true ]; then
            _upgrade_fail "事务恢复不完整，快照已保留：$tmpdir" || true
            tmpdir=
            exit_status=1
        fi
    fi
    _upgrade_release_lock
    [ -z "${tmpdir:-}" ] || rm -rf "$tmpdir" || true
    exit "$exit_status"
}

_upgrade_bundled_cleanup() {
    local exit_status=$1 restore_failed=false
    trap '' HUP INT TERM
    trap - EXIT
    if [ "${transaction_active:-false}" = true ]; then
        _upgrade_restore_snapshot "$backup_current" "$target" "$had_current" || restore_failed=true
        _upgrade_restore_snapshot "$backup_current_state" "$MIHOMO_UPGRADE_STATE_LOCK" "$had_current_state" || restore_failed=true
        if [ "$restore_failed" = true ]; then
            _upgrade_fail "安装事务恢复不完整，快照已保留：$tmpdir" || true
            tmpdir=
            exit_status=1
        fi
    fi
    [ -z "${tmpdir:-}" ] || rm -rf "$tmpdir" || true
    exit "$exit_status"
}

_install_bundled_mihomo() (
    local manifest=$1 archive_dir=$2 target=$3 archive candidate candidate_state
    local tmpdir backup_current backup_current_state
    local had_current=false had_current_state=false transaction_active=false
    tmpdir=
    trap '_upgrade_bundled_cleanup $?' EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    _upgrade_platform || exit 1
    _upgrade_parse_manifest "$manifest" || exit 1
    archive="${archive_dir%/}/${UPGRADE_REMOTE_FILE}"
    [ -f "$archive" ] && [ ! -L "$archive" ] || exit 1
    _upgrade_managed_file_ok "$target" false false || exit 1
    _upgrade_managed_file_ok "$MIHOMO_UPGRADE_STATE_LOCK" false false || exit 1
    tmpdir=$(_upgrade_make_tmp_dir) || exit 1
    candidate="$tmpdir/mihomo"
    candidate_state="$tmpdir/mihomo.state.tsv"
    backup_current="$tmpdir/current.before"
    backup_current_state="$tmpdir/current-state.before"
    _upgrade_verify_archive "$archive" &&
        _upgrade_prepare_candidate "$archive" "$candidate" &&
        _upgrade_build_state_file "$manifest" "$candidate" "$candidate_state" || exit 1
    if [ -f "$target" ]; then had_current=true; _upgrade_snapshot_file "$target" "$backup_current" || exit 1; fi
    if [ -f "$MIHOMO_UPGRADE_STATE_LOCK" ]; then
        had_current_state=true
        _upgrade_snapshot_file "$MIHOMO_UPGRADE_STATE_LOCK" "$backup_current_state" || exit 1
    fi
    transaction_active=true
    _upgrade_atomic_copy "$candidate" "$target" || exit 1
    _upgrade_write_state "$candidate_state" "$MIHOMO_UPGRADE_STATE_LOCK" || exit 1
    _upgrade_binary_matches_state "$target" "$MIHOMO_UPGRADE_STATE_LOCK" >/dev/null 2>&1 || exit 1
    _upgrade_commit_transaction
    _upgrade_info "已安装仓库稳定版 mihomo $UPGRADE_REMOTE_VERSION" || true
)

_upgrade_apply_transaction() (
    local target tmpdir archive candidate candidate_state current_version port_state rollback_state
    local backup_current backup_previous backup_current_state backup_previous_state backup_port_state
    local had_current=true had_previous=false had_current_state=false had_previous_state=false had_port_state=false
    local current_trusted=false was_running=false transaction_active=false
    local MIHOMO_OPERATION_LOCK_HELD=true
    _upgrade_acquire_lock || { _upgrade_fail "另一个内核升级任务正在运行"; exit 1; }
    tmpdir=
    trap '_upgrade_transaction_cleanup $?' EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    target=${BIN_MIHOMO:-"${MIHOMO_BASE_DIR}/bin/mihomo"}
    _upgrade_platform || exit 1
    _upgrade_managed_file_ok "$target" true true || { _upgrade_fail "当前内核不是可用的普通文件：$target"; exit 1; }
    _upgrade_managed_file_ok "$MIHOMO_UPGRADE_PREVIOUS" false false || exit 1
    _upgrade_managed_file_ok "$MIHOMO_UPGRADE_STATE_LOCK" false false || exit 1
    _upgrade_managed_file_ok "$MIHOMO_UPGRADE_PREVIOUS_STATE" false false || exit 1
    port_state=${MIHOMO_PORT_STATE:-"${MIHOMO_BASE_DIR}/config/ports${MIHOMO_HOST_SUFFIX:-}.conf"}
    _upgrade_managed_file_ok "$port_state" false false || exit 1
    tmpdir=$(_upgrade_make_tmp_dir) || exit 1
    _upgrade_info "正在检查仓库中的最新稳定版..."
    _upgrade_resolve_repository_snapshot "$tmpdir" || exit 1
    current_version=
    if [ -f "$MIHOMO_UPGRADE_STATE_LOCK" ] &&
        _upgrade_binary_matches_state "$target" "$MIHOMO_UPGRADE_STATE_LOCK" >/dev/null 2>&1; then
        current_trusted=true
        current_version=$UPGRADE_STATE_VERSION
    fi
    if [ "$current_trusted" = true ] &&
        _upgrade_state_matches_manifest "$MIHOMO_UPGRADE_STATE_LOCK" "$UPGRADE_REMOTE_MANIFEST" >/dev/null 2>&1; then
        _upgrade_info "当前已是最新稳定版 $current_version"
        exit 0
    fi
    rollback_state="$tmpdir/current-rollback.state.tsv"
    if [ "$current_trusted" = true ]; then
        cp -p "$MIHOMO_UPGRADE_STATE_LOCK" "$rollback_state" || exit 1
    else
        _upgrade_build_local_state_file "$target" "$rollback_state" || {
            _upgrade_fail "无法记录当前内核身份，已取消升级以保留回滚能力"
            exit 1
        }
    fi
    archive="$tmpdir/${UPGRADE_REMOTE_FILE}"
    candidate="$tmpdir/mihomo"
    candidate_state="$tmpdir/mihomo.state.tsv"
    _upgrade_fetch_url "$UPGRADE_REMOTE_URL" "$archive" || { _upgrade_fail "内核下载失败，当前版本未改动"; exit 1; }
    _upgrade_verify_archive "$archive" || exit 1
    _upgrade_prepare_candidate "$archive" "$candidate" || exit 1
    _upgrade_build_state_file "$UPGRADE_REMOTE_MANIFEST" "$candidate" "$candidate_state" || exit 1
    backup_current="$tmpdir/current.before"
    backup_previous="$tmpdir/previous.before"
    backup_current_state="$tmpdir/current-state.before"
    backup_previous_state="$tmpdir/previous-state.before"
    backup_port_state="$tmpdir/ports.before"
    _upgrade_snapshot_file "$target" "$backup_current" || exit 1
    if [ -f "$MIHOMO_UPGRADE_PREVIOUS" ]; then had_previous=true; _upgrade_snapshot_file "$MIHOMO_UPGRADE_PREVIOUS" "$backup_previous" || exit 1; fi
    if [ -f "$MIHOMO_UPGRADE_STATE_LOCK" ]; then had_current_state=true; _upgrade_snapshot_file "$MIHOMO_UPGRADE_STATE_LOCK" "$backup_current_state" || exit 1; fi
    if [ -f "$MIHOMO_UPGRADE_PREVIOUS_STATE" ]; then had_previous_state=true; _upgrade_snapshot_file "$MIHOMO_UPGRADE_PREVIOUS_STATE" "$backup_previous_state" || exit 1; fi
    is_mihomo_running && was_running=true
    if [ "$was_running" = true ]; then
        if [ -f "$port_state" ]; then had_port_state=true; _upgrade_snapshot_file "$port_state" "$backup_port_state" || exit 1; fi
    fi
    transaction_active=true
    if [ "$was_running" = true ]; then
        stop_mihomo >/dev/null || exit 1
        _upgrade_restore_port_state || exit 1
    fi
    _upgrade_atomic_copy "$candidate" "$target" || exit 1
    _upgrade_after_binary_publish upgrade || exit 1
    if [ "$was_running" = true ]; then
        start_mihomo >/dev/null 2>&1 || { _upgrade_fail "新内核启动失败，正在自动回滚"; exit 1; }
        sleep "$MIHOMO_UPGRADE_GRACE"
        is_mihomo_running || { _upgrade_fail "新内核运行检查失败，正在自动回滚"; exit 1; }
    fi
    _upgrade_atomic_copy "$backup_current" "$MIHOMO_UPGRADE_PREVIOUS" || exit 1
    _upgrade_write_state "$rollback_state" "$MIHOMO_UPGRADE_PREVIOUS_STATE" || exit 1
    _upgrade_write_state "$candidate_state" "$MIHOMO_UPGRADE_STATE_LOCK" || exit 1
    _upgrade_binary_matches_state "$target" "$MIHOMO_UPGRADE_STATE_LOCK" >/dev/null 2>&1 || exit 1
    _upgrade_binary_matches_state "$MIHOMO_UPGRADE_PREVIOUS" "$MIHOMO_UPGRADE_PREVIOUS_STATE" >/dev/null 2>&1 || exit 1
    _upgrade_commit_transaction
    _upgrade_after_transaction_commit
    _upgrade_info "mihomo 已升级到 $UPGRADE_REMOTE_VERSION" || true
)

_upgrade_rollback_transaction() (
    local target tmpdir restored_version port_state
    local backup_current backup_previous backup_current_state backup_previous_state backup_port_state
    local had_current=true had_previous=true had_current_state=true had_previous_state=true had_port_state=false
    local was_running=false transaction_active=false MIHOMO_OPERATION_LOCK_HELD=true
    _upgrade_acquire_lock || { _upgrade_fail "另一个内核升级任务正在运行"; exit 1; }
    tmpdir=
    trap '_upgrade_transaction_cleanup $?' EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    target=${BIN_MIHOMO:-"${MIHOMO_BASE_DIR}/bin/mihomo"}
    _upgrade_platform || exit 1
    _upgrade_managed_file_ok "$target" true true || exit 1
    _upgrade_managed_file_ok "$MIHOMO_UPGRADE_PREVIOUS" true true || { _upgrade_fail "没有可回滚的上一版内核"; exit 1; }
    _upgrade_managed_file_ok "$MIHOMO_UPGRADE_STATE_LOCK" true false || exit 1
    _upgrade_managed_file_ok "$MIHOMO_UPGRADE_PREVIOUS_STATE" true false || exit 1
    port_state=${MIHOMO_PORT_STATE:-"${MIHOMO_BASE_DIR}/config/ports${MIHOMO_HOST_SUFFIX:-}.conf"}
    _upgrade_managed_file_ok "$port_state" false false || exit 1
    _upgrade_binary_matches_state "$MIHOMO_UPGRADE_PREVIOUS" "$MIHOMO_UPGRADE_PREVIOUS_STATE" >/dev/null 2>&1 || { _upgrade_fail "上一版内核状态不匹配"; exit 1; }
    restored_version=$UPGRADE_STATE_VERSION
    _upgrade_binary_matches_state "$target" "$MIHOMO_UPGRADE_STATE_LOCK" >/dev/null 2>&1 || { _upgrade_fail "当前内核状态不匹配"; exit 1; }
    _upgrade_binary_accepts_published_config "$MIHOMO_UPGRADE_PREVIOUS" || { _upgrade_fail "上一版内核无法通过当前配置检查"; exit 1; }
    tmpdir=$(_upgrade_make_tmp_dir) || exit 1
    backup_current="$tmpdir/current.before"
    backup_previous="$tmpdir/previous.before"
    backup_current_state="$tmpdir/current-state.before"
    backup_previous_state="$tmpdir/previous-state.before"
    backup_port_state="$tmpdir/ports.before"
    _upgrade_snapshot_file "$target" "$backup_current" || exit 1
    _upgrade_snapshot_file "$MIHOMO_UPGRADE_PREVIOUS" "$backup_previous" || exit 1
    _upgrade_snapshot_file "$MIHOMO_UPGRADE_STATE_LOCK" "$backup_current_state" || exit 1
    _upgrade_snapshot_file "$MIHOMO_UPGRADE_PREVIOUS_STATE" "$backup_previous_state" || exit 1
    is_mihomo_running && was_running=true
    if [ "$was_running" = true ]; then
        if [ -f "$port_state" ]; then had_port_state=true; _upgrade_snapshot_file "$port_state" "$backup_port_state" || exit 1; fi
    fi
    transaction_active=true
    if [ "$was_running" = true ]; then stop_mihomo >/dev/null || exit 1; _upgrade_restore_port_state || exit 1; fi
    _upgrade_atomic_copy "$backup_previous" "$target" || exit 1
    _upgrade_after_binary_publish rollback || exit 1
    if [ "$was_running" = true ]; then
        start_mihomo >/dev/null 2>&1 || { _upgrade_fail "回滚版本无法启动，正在恢复原内核"; exit 1; }
        sleep "$MIHOMO_UPGRADE_GRACE"
        is_mihomo_running || exit 1
    fi
    _upgrade_atomic_copy "$backup_current" "$MIHOMO_UPGRADE_PREVIOUS" || exit 1
    _upgrade_write_state "$backup_previous_state" "$MIHOMO_UPGRADE_STATE_LOCK" || exit 1
    _upgrade_write_state "$backup_current_state" "$MIHOMO_UPGRADE_PREVIOUS_STATE" || exit 1
    _upgrade_binary_matches_state "$target" "$MIHOMO_UPGRADE_STATE_LOCK" >/dev/null 2>&1 || exit 1
    _upgrade_binary_matches_state "$MIHOMO_UPGRADE_PREVIOUS" "$MIHOMO_UPGRADE_PREVIOUS_STATE" >/dev/null 2>&1 || exit 1
    _upgrade_commit_transaction
    _upgrade_after_transaction_commit
    _upgrade_info "已回滚到 ${restored_version:-上一版本}" || true
)

_upgrade_status() (
    local target current previous
    _upgrade_acquire_lock || { _upgrade_fail "另一个 mihomo 操作正在运行，暂时无法读取版本状态"; return 1; }
    trap '_upgrade_release_lock' EXIT
    target=${BIN_MIHOMO:-"${MIHOMO_BASE_DIR}/bin/mihomo"}
    _upgrade_platform || exit 1
    _upgrade_managed_file_ok "$target" false false || exit 1
    _upgrade_managed_file_ok "$MIHOMO_UPGRADE_PREVIOUS" false false || exit 1
    _upgrade_managed_file_ok "$MIHOMO_UPGRADE_STATE_LOCK" false false || exit 1
    _upgrade_managed_file_ok "$MIHOMO_UPGRADE_PREVIOUS_STATE" false false || exit 1
    current=未安装
    if [ -x "$target" ]; then
        if [ -f "$MIHOMO_UPGRADE_STATE_LOCK" ] && _upgrade_binary_matches_state "$target" "$MIHOMO_UPGRADE_STATE_LOCK" >/dev/null 2>&1; then current=$UPGRADE_STATE_VERSION; else current=状态不可信; fi
    fi
    previous=
    if [ -x "$MIHOMO_UPGRADE_PREVIOUS" ]; then
        if [ -f "$MIHOMO_UPGRADE_PREVIOUS_STATE" ] && _upgrade_binary_matches_state "$MIHOMO_UPGRADE_PREVIOUS" "$MIHOMO_UPGRADE_PREVIOUS_STATE" >/dev/null 2>&1; then previous=$UPGRADE_STATE_VERSION; else previous=状态不可信; fi
    fi
    _upgrade_info "当前内核：$current"
    [ -n "$previous" ] && _upgrade_info "可回滚版本：$previous"
    _upgrade_info "更新来源：https://github.com/SaladDay/clash-for-lab"
    trap - EXIT
    _upgrade_release_lock
)

function clashupgrade() {
    case "${1:-apply}" in
    apply|update) _upgrade_apply_transaction ;;
    rollback) _upgrade_rollback_transaction ;;
    status|version) _upgrade_status ;;
    -h|--help|help)
        printf '%s\n' '用法: clash upgrade [rollback|status]' \
            '    无参数     从 clash-for-lab 仓库升级到最新稳定版 mihomo' \
            '    rollback   切换到升级前保留的上一版本' \
            '    status     查看当前版本和可回滚版本'
        ;;
    *) _upgrade_fail "未知参数：$1（使用 clash upgrade --help 查看用法）" ;;
    esac
}
