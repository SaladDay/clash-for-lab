# shellcheck disable=SC2148
# shellcheck disable=SC2034
# shellcheck disable=SC2155
[ -n "$BASH_VERSION" ] && set +o noglob
[ -n "$ZSH_VERSION" ] && setopt glob no_nomatch

SCRIPT_BASE_DIR='./script'

RESOURCES_BASE_DIR='./resources'
RESOURCES_BIN_DIR="${RESOURCES_BASE_DIR}/bin"
RESOURCES_CONFIG="${RESOURCES_BASE_DIR}/config.yaml"
RESOURCES_CONFIG_MIXIN="${RESOURCES_BASE_DIR}/mixin.yaml"

ZIP_BASE_DIR="${RESOURCES_BASE_DIR}/zip"
ZIP_YQ=$(echo ${ZIP_BASE_DIR}/yq*)
ZIP_SUBCONVERTER=$(echo ${ZIP_BASE_DIR}/subconverter*)
MIHOMO_BUNDLE_LOCK="${RESOURCES_BASE_DIR}/mihomo.lock.tsv"

ZIP_UI="${ZIP_BASE_DIR}/zashboard.zip"
ZIP_CLASHCTL=$(echo ${ZIP_BASE_DIR}/clashctl*)

MIHOMO_BASE_DIR="$HOME/tools/mihomo"
MIHOMO_SCRIPT_DIR="${MIHOMO_BASE_DIR}/$(basename $SCRIPT_BASE_DIR)"
MIHOMO_CONFIG_URL="${MIHOMO_BASE_DIR}/url"
MIHOMO_CONFIG_RAW="${MIHOMO_BASE_DIR}/$(basename $RESOURCES_CONFIG)"
MIHOMO_CONFIG_RAW_BAK="${MIHOMO_CONFIG_RAW}.bak"
MIHOMO_CONFIG_MIXIN="${MIHOMO_BASE_DIR}/$(basename $RESOURCES_CONFIG_MIXIN)"
MIHOMO_CONFIG_RUNTIME="${MIHOMO_BASE_DIR}/runtime.yaml"
MIHOMO_UPDATE_LOG="${MIHOMO_BASE_DIR}/mihomoctl.log"
MIHOMO_LOG_MAX_BYTES=8388608

# Legacy compatibility - keep CLASH_* variables pointing to new locations
CLASH_BASE_DIR="$MIHOMO_BASE_DIR"
CLASH_SCRIPT_DIR="$MIHOMO_SCRIPT_DIR"
CLASH_CONFIG_URL="$MIHOMO_CONFIG_URL"
CLASH_CONFIG_RAW="$MIHOMO_CONFIG_RAW"
CLASH_CONFIG_RAW_BAK="$MIHOMO_CONFIG_RAW_BAK"
CLASH_CONFIG_MIXIN="$MIHOMO_CONFIG_MIXIN"
CLASH_CONFIG_RUNTIME="$MIHOMO_CONFIG_RUNTIME"
CLASH_UPDATE_LOG="$MIHOMO_UPDATE_LOG"

_is_dir_writable() {
    local dir=$1
    [ -n "$dir" ] && [ -d "$dir" ] && [ -w "$dir" ] && [ -x "$dir" ]
}

_set_tmpdir_default() {
    # Respect user override if it is usable.
    if _is_dir_writable "$TMPDIR"; then
        export TMPDIR
        export TMP="$TMPDIR"
        export TEMP="$TMPDIR"
        return 0
    fi

    local uid
    uid=$(id -u 2>/dev/null || true)

    local candidate
    case "$uid" in
    '' | *[!0-9]*)
        ;;
    *)
        if _is_dir_writable "/run/user/$uid"; then
            candidate="/run/user/$uid/mihomo-tmp"
            mkdir -p "$candidate" 2>/dev/null || true
            if _is_dir_writable "$candidate"; then
                export TMPDIR="$candidate"
                export TMP="$TMPDIR"
                export TEMP="$TMPDIR"
                return 0
            fi
        fi
        ;;
    esac

    if _is_dir_writable "/dev/shm"; then
        candidate="/dev/shm/mihomo-tmp-${USER:-$uid}"
        mkdir -p "$candidate" 2>/dev/null || true
        if _is_dir_writable "$candidate"; then
            export TMPDIR="$candidate"
            export TMP="$TMPDIR"
            export TEMP="$TMPDIR"
            return 0
        fi
    fi

    if _is_dir_writable "$HOME"; then
        candidate="$HOME/.cache/mihomo/tmp"
        mkdir -p "$candidate" 2>/dev/null || true
        if _is_dir_writable "$candidate"; then
            export TMPDIR="$candidate"
            export TMP="$TMPDIR"
            export TEMP="$TMPDIR"
            return 0
        fi
    fi

    if [ -n "$MIHOMO_BASE_DIR" ]; then
        candidate="$MIHOMO_BASE_DIR/tmp"
        mkdir -p "$candidate" 2>/dev/null || true
        if _is_dir_writable "$candidate"; then
            export TMPDIR="$candidate"
            export TMP="$TMPDIR"
            export TEMP="$TMPDIR"
            return 0
        fi
    fi

    return 1
}

_set_var() {
    local user=$USER
    local home=$HOME

    [ -n "$BASH_VERSION" ] && {
        _SHELL=bash
    }
    [ -n "$ZSH_VERSION" ] && {
        _SHELL=zsh
    }
    [ -n "$fish_version" ] && {
        _SHELL=fish
    }

    # rc文件路径
    command -v bash >&/dev/null && {
        SHELL_RC_BASH="${home}/.bashrc"
    }
    command -v zsh >&/dev/null && {
        SHELL_RC_ZSH="${home}/.zshrc"
    }


    # Avoid using /tmp when / is full (bash heredoc, yq -i, mktemp, etc.).
    _set_tmpdir_default || true
}
_set_var

# shellcheck disable=SC2120
_set_bin() {
    local bin_base_dir="${MIHOMO_BASE_DIR}/bin"
    [ -n "$1" ] && bin_base_dir=$1
    BIN_CLASH="${bin_base_dir}/clash"
    BIN_MIHOMO="${bin_base_dir}/mihomo"
    BIN_YQ="${bin_base_dir}/yq"
    BIN_SUBCONVERTER_DIR="${bin_base_dir}/subconverter"
    BIN_SUBCONVERTER_CONFIG="$BIN_SUBCONVERTER_DIR/pref.yml"
    BIN_SUBCONVERTER_PORT="25500"
    BIN_SUBCONVERTER="${BIN_SUBCONVERTER_DIR}/subconverter"
    BIN_SUBCONVERTER_LOG="${BIN_SUBCONVERTER_DIR}/latest.log"

    [ -f "$BIN_CLASH" ] && {
        BIN_KERNEL=$BIN_CLASH
    }
    [ -f "$BIN_MIHOMO" ] && {
        BIN_KERNEL=$BIN_MIHOMO
    }
    BIN_KERNEL_NAME=$(basename "$BIN_KERNEL")
}
_set_bin

_rc_stat_id() {
    local file_path=$1 value
    value=$(LC_ALL=C stat -L -c '%d:%i' "$file_path" 2>/dev/null) ||
        value=$(LC_ALL=C stat -L -f '%d:%i' "$file_path" 2>/dev/null) || return 1
    printf '%s\n' "$value"
}

_rc_managed_line() {
    local escaped_script_dir
    escaped_script_dir=$(printf '%s' "$MIHOMO_SCRIPT_DIR" | sed "s/'/'\\\\''/g") || return 1
    printf ". '%s/managed.sh' && watch_proxy # clash-for-lab managed\n" "$escaped_script_dir"
}

_rc_filter_managed_lines() {
    local source=$1 canonical legacy line=''
    canonical=$(_rc_managed_line) || return 1
    legacy="source ${MIHOMO_SCRIPT_DIR}/common.sh && source ${MIHOMO_SCRIPT_DIR}/clashctl.sh && watch_proxy"

    while IFS= read -r line || [ -n "$line" ]; do
        [ "$line" = "$canonical" ] && continue
        [ "$line" = "$legacy" ] && continue
        printf '%s\n' "$line" || return 1
    done < "$source"
}

_set_rc() {
    local mode=${1:-set} rc candidate managed_line failed=false
    case "$mode" in
    set|unset) ;;
    *) return 1 ;;
    esac
    managed_line=$(_rc_managed_line) || return 1

    for rc in "$SHELL_RC_BASH" "$SHELL_RC_ZSH"; do
        [ -n "$rc" ] || continue
        if [ "$mode" = unset ] && [ ! -e "$rc" ] && [ ! -L "$rc" ]; then
            continue
        fi
        if [ ! -e "$rc" ] && [ ! -L "$rc" ]; then
            (umask 077; : > "$rc") || {
                failed=true
                continue
            }
        fi
        [ -f "$rc" ] || {
            failed=true
            continue
        }

        candidate=$(mktemp "${rc}.mihomo.XXXXXX") || {
            failed=true
            continue
        }
        if ! cp -p "$rc" "$candidate" ||
            ! _rc_filter_managed_lines "$rc" > "$candidate" ||
            { [ "$mode" = set ] && ! printf '%s\n' "$managed_line" >> "$candidate"; }; then
            rm -f "$candidate"
            failed=true
            continue
        fi

        if [ -L "$rc" ]; then
            # Keep dotfile-manager symlinks intact. Same-UID concurrent edits
            # are outside the supported operation model.
            cat "$candidate" > "$rc" || failed=true
            rm -f "$candidate"
        else
            mv -f "$candidate" "$rc" || {
                rm -f "$candidate"
                failed=true
            }
        fi
    done
    [ "$failed" = false ]
}

_get_random_port() {
    local randomPort
    # Try shuf first (Linux), then use alternative methods
    if command -v shuf >/dev/null 2>&1; then
        randomPort=$(shuf -i 1024-65535 -n 1)
    elif command -v jot >/dev/null 2>&1; then
        # macOS/BSD
        randomPort=$(jot -r 1 1024 65535)
    else
        # Fallback using RANDOM (bash/zsh)
        randomPort=$((RANDOM % 64512 + 1024))
    fi

    ! _is_bind "$randomPort" && { echo "$randomPort" && return; }
    _get_random_port
}

# 端口状态与偏好文件路径
MIHOMO_PORT_STATE="${MIHOMO_BASE_DIR}/config/ports.conf"
MIHOMO_PORT_PREF="${MIHOMO_BASE_DIR}/config/port.pref"

# 读取代理端口偏好设置
_load_port_preferences() {
    PORT_PREF_MODE=auto
    PORT_PREF_VALUE=""

    [ -f "$MIHOMO_PORT_PREF" ] || return 0

    while IFS='=' read -r key value; do
        case "$key" in
        PROXY_MODE)
            [ -n "$value" ] && PORT_PREF_MODE=$value
            ;;
        PROXY_PORT)
            PORT_PREF_VALUE=$value
            ;;
        esac
    done < "$MIHOMO_PORT_PREF"

    [ "$PORT_PREF_MODE" = "manual" ] || PORT_PREF_MODE=auto
}

# 保存代理端口偏好
_write_port_preferences_file() {
    local destination=$1 mode=$2 value=$3

    case "$mode" in
    auto)
        value=
        ;;
    manual)
        [[ $value =~ ^[0-9]+$ ]] && [ "$value" -ge 1024 ] && [ "$value" -le 65535 ] || return 1
        ;;
    *)
        return 1
        ;;
    esac

    printf 'PROXY_MODE=%s\nPROXY_PORT=%s\n' "$mode" "$value" > "$destination"
}

# 保存实际监听端口到状态文件
_save_port_state() {
    local proxy_port=$1
    local ui_port=$2
    local dns_port=$3
    local state_dir tmp

    state_dir=$(dirname "$MIHOMO_PORT_STATE")
    mkdir -p "$state_dir" || return 1
    tmp=$(mktemp "${MIHOMO_PORT_STATE}.tmp.XXXXXX") || return 1
    if ! cat > "$tmp" <<EOF
PROXY_PORT=$proxy_port
UI_PORT=$ui_port
DNS_PORT=$dns_port
TIMESTAMP=$(date +%s)
EOF
    then
        rm -f "$tmp"
        return 1
    fi
    if mv -f "$tmp" "$MIHOMO_PORT_STATE"; then
        return 0
    fi
    rm -f "$tmp"
    return 1
}

# 从状态文件读取实际监听端口
function _get_proxy_port() {
    if [ -f "$MIHOMO_PORT_STATE" ]; then
        MIXED_PORT=$(grep "^PROXY_PORT=" "$MIHOMO_PORT_STATE" 2>/dev/null | cut -d'=' -f2)
    fi
    # 如果状态文件不存在或读取失败，使用默认值
    MIXED_PORT=${MIXED_PORT:-7890}
}

function _get_ui_port() {
    if [ -f "$MIHOMO_PORT_STATE" ]; then
        UI_PORT=$(grep "^UI_PORT=" "$MIHOMO_PORT_STATE" 2>/dev/null | cut -d'=' -f2)
    fi
    # 如果状态文件不存在或读取失败，使用默认值
    UI_PORT=${UI_PORT:-9090}
}

function _get_dns_port() {
    if [ -f "$MIHOMO_PORT_STATE" ]; then
        DNS_PORT=$(grep "^DNS_PORT=" "$MIHOMO_PORT_STATE" 2>/dev/null | cut -d'=' -f2)
    fi
    # 如果状态文件不存在或读取失败，使用默认值
    DNS_PORT=${DNS_PORT:-15353}
}

_get_color() {
    local hex="${1#\#}"
    local r=$((16#${hex:0:2}))
    local g=$((16#${hex:2:2}))
    local b=$((16#${hex:4:2}))
    printf "\e[38;2;%d;%d;%dm" "$r" "$g" "$b"
}
_get_color_msg() {
    local color=$(_get_color "$1")
    local msg=$2
    local reset="\033[0m"
    printf "%b%s%b\n" "$color" "$msg" "$reset"
}

function _okcat() {
    local color=#c8d6e5
    local emoji=😼
    [ $# -gt 1 ] && emoji=$1 && shift
    local msg="${emoji} $1"
    _get_color_msg "$color" "$msg" && return 0
}

function _failcat() {
    local color=#fd79a8
    local emoji=😾
    [ $# -gt 1 ] && emoji=$1 && shift
    local msg="${emoji} $1"
    _get_color_msg "$color" "$msg" >&2 && return 1
}

_has_tty() {
    [ -t 0 ] && [ -t 1 ]
}

function _quit() {
    if [ -n "$_SHELL" ] && _has_tty; then
        exec "$_SHELL" -i
    fi
    return 0
}

function _error_quit() {
    [ $# -gt 0 ] && {
        local color=#f92f60
        local emoji=📢
        [ $# -gt 1 ] && emoji=$1 && shift
        local msg="${emoji} $1"
        _get_color_msg "$color" "$msg"
    }
    [ -z "$_SHELL" ] && _SHELL=bash

    # A high-level lifecycle command may hold the shared upgrade lock.
    # Release it before replacing or exiting the current shell.
    command -v _mihomo_operation_release >/dev/null 2>&1 &&
        _mihomo_operation_release >/dev/null 2>&1 || true

    if _has_tty; then
        exec "$_SHELL" -i
    fi

    exit 1
}

_is_bind() {
    local port=$1
    if command -v ss >/dev/null 2>&1; then
        ss -lnptu 2>/dev/null | grep ":${port}\b"
    elif command -v netstat >/dev/null 2>&1; then
        netstat -lnptu 2>/dev/null | grep ":${port}\b"
    elif [ -r /proc/net/tcp ]; then
        _is_bind_proc_net "$port"
    else
        return 1
    fi
}

# Fallback port-binding check via /proc/net/{tcp,tcp6,udp,udp6}.
# Used when neither ss nor netstat is available.  Outputs a line if the
# port is bound so callers that pipe _is_bind output (e.g.
# _is_already_in_use) continue to work.  The output does not contain
# process info, so _is_already_in_use conservatively treats any
# match as "in use by someone else" — which is safe.
_is_bind_proc_net() {
    local port=$1 hex_port
    hex_port=$(printf '%04X' "$port" 2>/dev/null) || return 1
    awk -v p="$hex_port" '
        FNR == 1 { next }
        FILENAME ~ /tcp/ && $2 ~ (":" p "$") && $4 == "0A" { found=1 }
        FILENAME ~ /udp/ && $2 ~ (":" p "$") { found=1 }
        END { if (found) print "proc-net:" p; else exit 1 }
    ' /proc/net/tcp /proc/net/tcp6 /proc/net/udp /proc/net/udp6 2>/dev/null
}

_is_already_in_use() {
    local port=$1
    local progress=$2
    _is_bind "$port" | grep -qs -v "$progress"
}

# 生成 clashctl-tui 配置文件内容（RON 格式）
# 参数：服务器名称、URL、密钥（可选）
_generate_clashctl_config() {
    local name=$1
    local url=$2
    local secret=$3

    # RON 格式要求：密钥为空时用 None，有值时用 Some("value")
    local secret_value="None,"
    if [ -n "$secret" ]; then
        secret_value="Some(\"$secret\"),"
    fi

    cat <<EOFRON
(
  servers: [
    (
      name: "$name",
      url: "$url",
      secret: $secret_value
    ),
  ],
  using: Some("$url"),
  tui: (
    log_file: None,
  ),
  sort: (
    connections: (
      by: time,
      order: descendant,
    ),
    rules: (
      by: payload,
      order: descendant,
    ),
    proxies: (
      by: delay,
      order: ascendant,
    ),
  ),
)
EOFRON
}

# Removed _is_root function - not needed in userspace

function _valid_env() {
    # 用户空间运行，不需要root权限检查
    if [ -z "$ZSH_VERSION" ] && [ -z "$BASH_VERSION" ]; then
        _failcat "仅支持：bash、zsh (例如: bash install.sh)"
        return 1
    fi
    return 0
}

function _valid_upgrade_env() {
    _valid_env || return 1
    case "$(uname -s 2>/dev/null):$(uname -m 2>/dev/null)" in
    Linux:x86_64|Linux:amd64)
        ;;
    *)
        _failcat "当前版本仅支持 Linux amd64"
        return 1
        ;;
    esac
    local required
    for required in curl gzip timeout; do
        command -v "$required" >/dev/null 2>&1 || {
            _failcat "缺少安装依赖：$required"
            return 1
        }
    done
    command -v sha256sum >/dev/null 2>&1 || command -v shasum >/dev/null 2>&1 || command -v openssl >/dev/null 2>&1 || {
        _failcat "缺少 SHA256 校验工具"
        return 1
    }
    return 0
}

function _valid_install_env() {
    _valid_upgrade_env || return 1
    local required
    for required in tar; do
        command -v "$required" >/dev/null 2>&1 || {
            _failcat "缺少安装依赖：$required"
            return 1
        }
    done
    return 0
}

# unzip is missing on many minimal servers and cannot be installed without
# root, so use whatever can read a zip archive.
_extract_zip() {
    local archive=$1 destination=$2 python
    if command -v unzip >/dev/null 2>&1; then
        unzip -q -o "$archive" -d "$destination" && return 0
    fi
    for python in python3 python; do
        command -v "$python" >/dev/null 2>&1 || continue
        "$python" -c 'import sys, zipfile
zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])' "$archive" "$destination" && return 0
    done
    if command -v bsdtar >/dev/null 2>&1; then
        bsdtar -xf "$archive" -C "$destination" && return 0
    fi
    if command -v busybox >/dev/null 2>&1; then
        busybox unzip -q -o "$archive" -d "$destination" && return 0
    fi
    return 1
}

_is_config_validation_data_name() {
    local normalized_name
    normalized_name=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]') || return 1
    case "$normalized_name" in
    country.mmdb|geoip.db|geoip.metadb|asn.mmdb|bundlemrs.7z|geoip.dat|geosite.dat)
        return 0
        ;;
    *)
        return 1
        ;;
    esac
}

_copy_validation_data() {
    local source=$1 destination=$2
    if cp --reflink=auto -pL "$source" "$destination" 2>/dev/null; then
        return 0
    fi
    rm -f "$destination"
    cp -pL "$source" "$destination"
}

_seed_config_validation_home() {
    local source_home=$1 validation_home=$2 source_data data_name
    [ -d "$source_home" ] && [ -d "$validation_home" ] || return 1

    # Mihomo may load or download these files while parsing GEO rules. Copy
    # only parse-time data into the private HomeDir: runtime databases, logs,
    # binaries and UI files are deliberately excluded.
    for source_data in "$source_home"/*; do
        [ -f "$source_data" ] || continue
        data_name=$(basename "$source_data") || return 1
        _is_config_validation_data_name "$data_name" || continue
        _copy_validation_data "$source_data" "$validation_home/$data_name" || return 1
    done
}

_initialize_config_validation_home() {
    local source_home=$1 validation_home=$2 marker
    marker="$validation_home/.clash-for-lab-validation-source"
    if [ -e "$validation_home" ] || [ -L "$validation_home" ]; then
        [ -d "$validation_home" ] && [ ! -L "$validation_home" ] || return 1
    else
        mkdir "$validation_home" || return 1
    fi
    chmod 0700 "$validation_home" || return 1
    if [ -f "$marker" ] && [ ! -L "$marker" ]; then
        [ "$(cat "$marker")" = "$source_home" ] || return 1
        return 0
    fi
    [ ! -e "$marker" ] && [ ! -L "$marker" ] || return 1
    _seed_config_validation_home "$source_home" "$validation_home" || return 1
    printf '%s\n' "$source_home" > "$marker" || return 1
    chmod 0600 "$marker"
}

_atomic_publish_new_validation_data() (
    local source=$1 destination=$2 destination_dir temporary
    _cleanup_validation_data_publish() {
        [ -z "${temporary:-}" ] || rm -f "$temporary"
    }
    trap '_cleanup_validation_data_publish' EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    [ -f "$source" ] && [ ! -L "$source" ] || return 1
    [ ! -e "$destination" ] && [ ! -L "$destination" ] || return 1
    destination_dir=$(dirname "$destination") || return 1
    temporary=$(mktemp "${destination_dir}/.mihomo-data.XXXXXX") || return 1
    if _copy_validation_data "$source" "$temporary" &&
        chmod 0644 "$temporary" &&
        ln "$temporary" "$destination"; then
        rm -f "$temporary" || return 1
        temporary=''
        trap - EXIT HUP INT TERM
        return 0
    fi
    return 1
)

_publish_new_config_validation_data() {
    local validation_home=$1 installed_home=$2 manifest=$3
    local staged_data data_name destination
    [ -d "$validation_home" ] && [ ! -L "$validation_home" ] ||
        return 1
    [ -d "$installed_home" ] && [ ! -L "$installed_home" ] ||
        return 1
    : > "$manifest" || return 1
    chmod 0600 "$manifest" || return 1
    for staged_data in "$validation_home"/*; do
        [ -f "$staged_data" ] && [ ! -L "$staged_data" ] || continue
        data_name=$(basename "$staged_data") || return 1
        _is_config_validation_data_name "$data_name" || continue
        destination="$installed_home/$data_name"
        if [ -e "$destination" ] || [ -L "$destination" ]; then
            continue
        fi
        # Record intent before publication so transaction cleanup also covers
        # an interruption immediately after the atomic link.
        printf '%s\n' "$data_name" >> "$manifest" || return 1
        _atomic_publish_new_validation_data "$staged_data" "$destination" ||
            return 1
    done
}

_rollback_new_config_validation_data() {
    local validation_home=$1 installed_home=$2 manifest=$3
    local data_name staged_data destination rollback_status=0
    [ -f "$manifest" ] && [ ! -L "$manifest" ] || return 0
    while IFS= read -r data_name || [ -n "$data_name" ]; do
        _is_config_validation_data_name "$data_name" || {
            rollback_status=1
            continue
        }
        staged_data="$validation_home/$data_name"
        destination="$installed_home/$data_name"
        if [ ! -e "$destination" ] && [ ! -L "$destination" ]; then
            continue
        fi
        if [ -f "$destination" ] && [ ! -L "$destination" ] &&
            [ -f "$staged_data" ] && [ ! -L "$staged_data" ] &&
            cmp -s "$staged_data" "$destination"; then
            rm -f "$destination" || rollback_status=1
        else
            rollback_status=1
        fi
    done < "$manifest"
    return "$rollback_status"
}

_config_validation_data_is_installed() {
    local validation_home=$1 installed_home=$2 staged_data data_name destination
    [ -d "$installed_home" ] || return 1
    [ -d "$validation_home" ] || return 0
    for staged_data in "$validation_home"/*; do
        [ -f "$staged_data" ] && [ ! -L "$staged_data" ] || continue
        data_name=$(basename "$staged_data") || return 1
        _is_config_validation_data_name "$data_name" || continue
        destination="$installed_home/$data_name"
        [ -f "$destination" ] && [ ! -L "$destination" ] || return 1
    done
}

function _valid_config() (
    local config=$1
    local source_home=${2:-} requested_validation_home=${3:-}
    local validation_home='' cleanup_validation_home=true validation_succeeded=false
    local validation_safe_paths msg
    [ -f "$config" ] && [ ! -L "$config" ] &&
        [ "$(wc -l <"$config")" -gt 1 ] || return 1
    [ -n "$source_home" ] || source_home=$(dirname "$config")
    [ -d "$source_home" ] || return 1

    umask 077
    if [ -n "$requested_validation_home" ]; then
        validation_home=$requested_validation_home
        cleanup_validation_home=false
    else
        validation_home=$(mktemp -d "$(dirname "$config")/.mihomo-config-test.XXXXXX") ||
            return 1
    fi
    _cleanup_validation_home() {
        [ "$cleanup_validation_home" != true ] &&
            [ "$validation_succeeded" = true ] ||
            [ -z "$validation_home" ] ||
            rm -rf "$validation_home"
    }
    trap '_cleanup_validation_home' EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    _initialize_config_validation_home "$source_home" "$validation_home" || return 1
    # The pinned stable Mihomo loads GEO data during `-t`, but providers stay
    # lazy. Keep GEO writes in validation_home while allowing existing config
    # references below source_home to pass Mihomo's path safety check.
    validation_safe_paths=$source_home
    [ -z "${SAFE_PATHS:-}" ] ||
        validation_safe_paths="${validation_safe_paths}:${SAFE_PATHS}"

    msg=$(SAFE_PATHS="$validation_safe_paths" timeout --kill-after=5 "${MIHOMO_CONFIG_TEST_TIMEOUT:-30}" \
        "$BIN_KERNEL" -d "$validation_home" -f "$config" -t 2>&1) || {
        case "$?:$msg" in
        124:*"start download"*)
            _failcat '🍂' '配置引用了本机没有的 GEO 数据，内核下载超时' || true
            ;;
        esac
        if echo "$msg" | grep -qs "unsupport proxy type"; then
            _failcat "不支持的代理协议，请使用 mihomo 内核" || true
        fi
        return 1
    }

    validation_succeeded=true
    return 0
)

_curl_config_line() {
    local option=$1 value=$2 escaped

    # Secrets must not be passed as command-line arguments: on Linux they are
    # normally visible to other local users through /proc/*/cmdline and ps.
    # curl's config parser accepts a quoted value on stdin. Escape the two
    # characters that are special inside that quoted form; subscription URLs
    # are validated separately and may not contain whitespace/newlines.
    escaped=$(printf '%s' "$value" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g') || return 1
    printf '%s = "%s"\n' "$option" "$escaped"
}

# Provide a human-readable hint based on curl's exit code.
# See https://everything.curl.dev/cmdline/exitcodes
_download_error_hint() {
    local rc=$1 url=$2
    case "$rc" in
    6)  _failcat '🍂' "DNS 解析失败：无法解析订阅地址域名" ;;
    7)  _failcat '🍂' "无法连接到订阅服务器" ;;
    28) _failcat '🍂' "下载超时：订阅服务器响应过慢或网络不通" ;;
    22) _failcat '🍂' "订阅服务器返回 HTTP 错误（如 404 或 403）：订阅地址可能已过期或失效" ;;
    35|51|53|54|55|58|60|64|66|77|80|82|83|90) _failcat '🍂' "TLS/SSL 错误：订阅服务器的证书有问题或不受信任" ;;
    *)  _failcat '🍂' "下载失败（curl 退出码 ${rc}）" ;;
    esac
}

_download_raw_config() (
    local dest=$1
    local url=$2
    local agent='clash-verge/v2.0.4'
    local tmp
    local sub_timeout=${MIHOMO_SUBSCRIBE_TIMEOUT:-60}
    local curl_rc
    umask 077
    tmp=$(mktemp 2>/dev/null) || tmp="${dest}.tmp.$$"

    _cleanup_tmp() { rm -f "$tmp"; }
    _curl_noproxy() {
        _curl_config_line url "$url" | curl \
            --disable --silent --show-error --fail --location \
            --max-redirs 5 --compressed --connect-timeout 10 \
            --max-time "$sub_timeout" --retry 2 --noproxy "*" \
            --user-agent "$agent" --output "$tmp" --config -
    }
    _curl_proxy() {
        _curl_config_line url "$url" | curl \
            --disable --silent --show-error --fail --location \
            --max-redirs 5 --compressed --connect-timeout 10 \
            --max-time "$sub_timeout" --retry 2 \
            --user-agent "$agent" --output "$tmp" --config -
    }

    # 优先直连（历史行为），失败后再尝试走当前环境代理（mihomo 开启后可用）。
    # 总超时可经 MIHOMO_SUBSCRIBE_TIMEOUT 环境变量调大，以适应弱网或大型订阅。
    curl_rc=0
    _curl_noproxy 2>/dev/null && { mv -f "$tmp" "$dest"; return 0; } || curl_rc=$?

    _curl_proxy 2>/dev/null && { mv -f "$tmp" "$dest"; return 0; } || curl_rc=$?

    if command -v wget >/dev/null 2>&1 && printf '%s\n' "$url" | wget \
        --no-verbose \
        --timeout "$sub_timeout" \
        --tries 2 \
        --user-agent "$agent" \
        --output-document "$tmp" \
        --input-file=- 2>/dev/null; then
        mv -f "$tmp" "$dest"
        return 0
    fi

    if command -v wget >/dev/null 2>&1 && printf '%s\n' "$url" | wget \
        --no-verbose \
        --timeout "$sub_timeout" \
        --tries 1 \
        --no-proxy \
        --user-agent "$agent" \
        --output-document "$tmp" \
        --input-file=- 2>/dev/null; then
        mv -f "$tmp" "$dest"
        return 0
    fi

    _cleanup_tmp
    _download_error_hint "$curl_rc" "$url"
    return 1
)

_tui_fail() {
    _failcat "$1" || true
    return 1
}

_tui_json() {
    local expression=$1 file=$2 tool
    tool=${BIN_YQ:-}
    [ -x "$tool" ] || tool=$(command -v yq 2>/dev/null || true)
    [ -x "$tool" ] || tool=$(command -v jq 2>/dev/null || true)
    [ -x "$tool" ] || {
        _tui_fail "缺少 JSON 解析器，无法校验 TUI 发布信息"
        return 1
    }

    case "$(basename "$tool")" in
    yq) "$tool" eval -r "$expression" "$file" ;;
    *) "$tool" -r "$expression" "$file" ;;
    esac
}

_tui_sha256() {
    local file=$1
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$file" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$file" | awk '{print $1}'
    elif command -v openssl >/dev/null 2>&1; then
        openssl dgst -sha256 "$file" | awk '{print $NF}'
    else
        _tui_fail "缺少 SHA256 校验工具"
        return 1
    fi
}

_tui_fetch() {
    local url=$1 output=$2 api_request=${3:-false}
    if [ "$api_request" = true ]; then
        curl --disable --silent --show-error --fail --location \
            --proto '=https' --proto-redir '=https' --tlsv1.2 \
            --connect-timeout 10 --max-time 60 --retry 2 \
            -H 'Accept: application/vnd.github+json' \
            -H 'X-GitHub-Api-Version: 2022-11-28' \
            --output "$output" "$url"
    else
        curl --disable --silent --show-error --fail --location \
            --proto '=https' --proto-redir '=https' --tlsv1.2 \
            --connect-timeout 10 --max-time 300 --retry 2 \
            --output "$output" "$url"
    fi
}

# 下载 clashctl-tui (懒加载)
_download_tui() (
    local dest="${MIHOMO_BASE_DIR}/bin/clashctl-tui"
    local dest_dir api_url expected_url
    local api_tmp='' asset_tmp=''
    local draft prerelease tag asset_count asset_size asset_digest asset_url
    local expected_sha actual_size actual_sha

    dest_dir=$(dirname "$dest")
    api_url='https://api.github.com/repos/saladday/clashctl/releases/latest'

    mkdir -p "$dest_dir" || {
        _tui_fail "无法创建 TUI 安装目录"
        return 1
    }
    [ ! -d "$dest" ] || {
        _tui_fail "TUI 安装路径是一个目录"
        return 1
    }

    api_tmp=$(mktemp "${dest_dir}/.clashctl-release.XXXXXX") || {
        _tui_fail "无法创建 TUI 发布信息临时文件"
        return 1
    }
    asset_tmp=$(mktemp "${dest_dir}/.clashctl-tui.XXXXXX") || {
        rm -f "$api_tmp"
        _tui_fail "无法创建 TUI 下载临时文件"
        return 1
    }
    trap 'exit 1' HUP INT TERM
    trap 'rm -f "$api_tmp" "$asset_tmp"' EXIT

    _okcat "首次使用 TUI，正在下载 clashctl-tui..."
    _tui_fetch "$api_url" "$api_tmp" true || {
        _tui_fail "无法读取 clashctl 最新稳定版信息"
        return 1
    }

    draft=$(_tui_json '.draft' "$api_tmp" 2>/dev/null) || {
        _tui_fail "clashctl 发布信息格式无效"
        return 1
    }
    prerelease=$(_tui_json '.prerelease' "$api_tmp" 2>/dev/null) || {
        _tui_fail "clashctl 发布信息格式无效"
        return 1
    }
    [ "$draft" = false ] && [ "$prerelease" = false ] || {
        _tui_fail "拒绝安装 clashctl 草稿或预发布版本"
        return 1
    }

    tag=$(_tui_json '.tag_name' "$api_tmp" 2>/dev/null) || {
        _tui_fail "clashctl 发布版本号无效"
        return 1
    }
    printf '%s' "$tag" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]*$' || {
        _tui_fail "clashctl 发布版本号无效"
        return 1
    }

    asset_count=$(_tui_json '[.assets[] | select(.name == "clashctl-Linux" and .state == "uploaded")] | length' "$api_tmp" 2>/dev/null) || {
        _tui_fail "clashctl 发布资源信息无效"
        return 1
    }
    [ "$asset_count" = 1 ] || {
        _tui_fail "clashctl 发布中没有唯一的 clashctl-Linux 资源"
        return 1
    }

    asset_size=$(_tui_json '.assets[] | select(.name == "clashctl-Linux" and .state == "uploaded") | .size' "$api_tmp" 2>/dev/null) || return 1
    asset_digest=$(_tui_json '.assets[] | select(.name == "clashctl-Linux" and .state == "uploaded") | .digest' "$api_tmp" 2>/dev/null) || return 1
    asset_url=$(_tui_json '.assets[] | select(.name == "clashctl-Linux" and .state == "uploaded") | .browser_download_url' "$api_tmp" 2>/dev/null) || return 1

    printf '%s' "$asset_size" | grep -Eq '^[1-9][0-9]*$' || {
        _tui_fail "clashctl-Linux 资源大小无效"
        return 1
    }
    printf '%s' "$asset_digest" | grep -Eq '^sha256:[0-9A-Fa-f]{64}$' || {
        _tui_fail "clashctl-Linux 资源缺少可信的 SHA256"
        return 1
    }
    expected_sha=$(printf '%s' "${asset_digest#sha256:}" | tr 'A-F' 'a-f')
    expected_url="https://github.com/SaladDay/clashctl/releases/download/${tag}/clashctl-Linux"
    [ "$asset_url" = "$expected_url" ] || {
        _tui_fail "clashctl-Linux 下载地址不是官方 GitHub 发布地址"
        return 1
    }

    _tui_fetch "$asset_url" "$asset_tmp" false || {
        _tui_fail "clashctl-Linux 下载失败"
        return 1
    }
    actual_size=$(LC_ALL=C wc -c < "$asset_tmp" | tr -d '[:space:]')
    [ "$actual_size" = "$asset_size" ] || {
        _tui_fail "clashctl-Linux 文件大小校验失败"
        return 1
    }
    actual_sha=$(_tui_sha256 "$asset_tmp") || return 1
    actual_sha=$(printf '%s' "$actual_sha" | tr 'A-F' 'a-f')
    [ "$actual_sha" = "$expected_sha" ] || {
        _tui_fail "clashctl-Linux SHA256 校验失败"
        return 1
    }

    chmod 0755 "$asset_tmp" || {
        _tui_fail "无法设置 clashctl-Linux 执行权限"
        return 1
    }
    mv -f "$asset_tmp" "$dest" || {
        _tui_fail "无法发布 clashctl-tui"
        return 1
    }
    asset_tmp=''
    _okcat "TUI 下载并校验完成"
)

_download_convert_config() {
    local dest=$1
    local source=$2
    _start_convert || return 1
    local base_url convert_tmp curl_config convert_status=0
    base_url="http://127.0.0.1:${BIN_SUBCONVERTER_PORT}/sub"
    umask 077
    convert_tmp=$(mktemp "${dest}.convert.XXXXXX" 2>/dev/null) || {
        _stop_convert || true
        return 1
    }
    curl_config=$(
        _curl_config_line data-urlencode 'target=clash' &&
            _curl_config_line data-urlencode "url=$source"
    ) || convert_status=$?
    if [ "$convert_status" -eq 0 ]; then
        printf '%s\n' "$curl_config" | curl \
            --disable \
            --get \
            --silent \
            --show-error \
            --fail \
            --connect-timeout 5 \
            --max-time "${MIHOMO_SUBSCRIBE_TIMEOUT:-120}" \
            --noproxy "*" \
            --output "$convert_tmp" \
            --url "$base_url" \
            --config - || convert_status=$?
    fi
    if [ "$convert_status" -eq 0 ]; then
        mv -f "$convert_tmp" "$dest" || convert_status=$?
    fi
    rm -f "$convert_tmp"
    _stop_convert || convert_status=1
    return "$convert_status"
}

_read_single_proxy_link() (
    local source=$1 link='' extra='' source_size first_status=0 second_status=0
    [ -f "$source" ] && [ ! -L "$source" ] || return 1
    source_size=$(wc -c < "$source" | tr -d '[:space:]') || return 1
    case "$source_size" in
    ''|*[!0-9]*) return 1 ;;
    esac
    [ "$source_size" -le 65536 ] || return 1
    exec 3< "$source" || return 1
    IFS= read -r link <&3 || first_status=$?
    IFS= read -r extra <&3 || second_status=$?
    exec 3<&-
    [ "$first_status" -eq 0 ] || [ -n "$link" ] || return 1
    [ "$second_status" -ne 0 ] && [ -z "$extra" ] || return 1
    link=${link%$'\r'}
    case "$link" in
    ss://*|ssr://*|vmess://*|vless://*|trojan://*|hysteria://*|hysteria2://*|hy2://*|anytls://*)
        printf '%s' "$link"
        ;;
    *)
        return 1
        ;;
    esac
)

_uri_percent_decode() {
    # Decode one URI component without adding a Python/Perl dependency.
    # Control bytes are not valid in the generated YAML scalars.
    LC_ALL=C awk '
        function hex_value(character, position) {
            position = index("0123456789ABCDEF", toupper(character))
            return position ? position - 1 : -1
        }
        {
            if (NR != 1)
                exit 2
            for (index_in_value = 1; index_in_value <= length($0); index_in_value++) {
                character = substr($0, index_in_value, 1)
                if (character == "%") {
                    if (index_in_value + 2 > length($0))
                        exit 2
                    high = hex_value(substr($0, index_in_value + 1, 1))
                    low = hex_value(substr($0, index_in_value + 2, 1))
                    if (high < 0 || low < 0)
                        exit 2
                    decoded = high * 16 + low
                    if (decoded < 32 || decoded == 127)
                        exit 2
                    printf "%c", decoded
                    index_in_value += 2
                } else {
                    if (character ~ /[[:cntrl:]]/)
                        exit 2
                    printf "%s", character
                }
            }
        }
        END {
            if (NR != 1)
                exit 2
        }
    '
}

_yaml_single_quote() {
    LC_ALL=C sed "s/'/''/g; 1s/^/'/; \$s/\$/'/"
}

_convert_anytls_proxy_link() (
    local dest=$1 link=$2 remainder authority password_encoded host_port
    local server_encoded server port query='' fragment='' item key value
    local sni='' insecure='' name group name_yaml server_yaml password_yaml sni_yaml
    local more_query port_number query_item_count=0 tmp=''

    case "$link" in
    anytls://?*) remainder=${link#anytls://} ;;
    *) return 1 ;;
    esac
    [ "${#link}" -le 8192 ] || return 1

    case "$remainder" in
    *'#'*)
        fragment=${remainder#*#}
        remainder=${remainder%%#*}
        ;;
    esac
    case "$remainder" in
    *'?'*)
        query=${remainder#*\?}
        remainder=${remainder%%\?*}
        ;;
    esac
    [ "${#query}" -le 4096 ] || return 1

    # The documented form uses "/?" but a link without the optional slash is
    # also unambiguous. Other paths are rejected instead of being folded into
    # the server name.
    case "$remainder" in
    */) authority=${remainder%/} ;;
    *) authority=$remainder ;;
    esac
    case "$authority" in
    *@*)
        password_encoded=${authority%%@*}
        host_port=${authority#*@}
        ;;
    *) return 1 ;;
    esac
    case "$host_port" in
    ''|*/*|*@*) return 1 ;;
    esac

    password=$(printf '%s\n' "$password_encoded" | _uri_percent_decode) || return 1
    [ -n "$password" ] || return 1

    case "$host_port" in
    \[*)
        case "$host_port" in
        *']'*) ;;
        *) return 1 ;;
        esac
        server_encoded=${host_port#\[}
        server_encoded=${server_encoded%%]*}
        value=${host_port#*]}
        case "$value" in
        '') port=443 ;;
        :*) port=${value#:} ;;
        *) return 1 ;;
        esac
        ;;
    *:*)
        server_encoded=${host_port%:*}
        port=${host_port##*:}
        case "$server_encoded" in
        *:*) return 1 ;;
        esac
        ;;
    *)
        server_encoded=$host_port
        port=443
        ;;
    esac

    server=$(printf '%s\n' "$server_encoded" | _uri_percent_decode) || return 1
    case "$server" in
    ''|*' '*|*/*|*@*|*'?'*|*'#'*|*\\*) return 1 ;;
    esac
    case "$port" in
    ''|*[!0-9]*) return 1 ;;
    esac
    [ "${#port}" -le 5 ] || return 1
    port_number=$((10#$port))
    [ "$port_number" -ge 1 ] && [ "$port_number" -le 65535 ] || return 1

    while [ -n "$query" ]; do
        query_item_count=$((query_item_count + 1))
        [ "$query_item_count" -le 16 ] || return 1
        case "$query" in
        *'&'*)
            item=${query%%&*}
            query=${query#*&}
            more_query=true
            ;;
        *)
            item=$query
            query=''
            more_query=false
            ;;
        esac
        case "$item" in
        *=*)
            key=${item%%=*}
            value=${item#*=}
            ;;
        *)
            key=$item
            value=''
            ;;
        esac
        case "$key" in
        sni)
            if [ -z "$sni" ]; then
                sni=$(printf '%s\n' "$value" | _uri_percent_decode) || return 1
            fi
            ;;
        insecure)
            if [ -z "$insecure" ]; then
                insecure=$(printf '%s\n' "$value" | _uri_percent_decode) || return 1
                case "$insecure" in
                0|1) ;;
                *) return 1 ;;
                esac
            fi
            ;;
        esac
        [ "$more_query" = true ] || break
    done

    case "$sni" in
    *' '*|*/*|*@*|*'?'*|*'#'*|*\\*) return 1 ;;
    esac
    name=$(printf '%s\n' "$fragment" | _uri_percent_decode) || return 1
    if [ -z "$name" ]; then
        case "$server" in
        *:*) name="[$server]:$port_number" ;;
        *) name="$server:$port_number" ;;
        esac
    fi
    case "$name" in
    DIRECT|REJECT|REJECT-DROP|COMPATIBLE|PASS|PASS-RULE)
        name="$name (AnyTLS)"
        ;;
    esac
    group=PROXY
    [ "$name" != "$group" ] || group=PROXY-GROUP

    name_yaml=$(printf '%s\n' "$name" | _yaml_single_quote) || return 1
    server_yaml=$(printf '%s\n' "$server" | _yaml_single_quote) || return 1
    password_yaml=$(printf '%s\n' "$password" | _yaml_single_quote) || return 1
    if [ -n "$sni" ]; then
        sni_yaml=$(printf '%s\n' "$sni" | _yaml_single_quote) || return 1
    fi

    umask 077
    tmp=$(mktemp "${dest}.anytls.XXXXXX" 2>/dev/null) || return 1
    _cleanup_anytls_tmp() { [ -z "$tmp" ] || rm -f "$tmp"; }
    trap '_cleanup_anytls_tmp' EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    (
        printf '%s\n' 'proxies:' || exit 1
        printf '  - name: %s\n' "$name_yaml" || exit 1
        printf '%s\n' '    type: anytls' || exit 1
        printf '    server: %s\n' "$server_yaml" || exit 1
        printf '    port: %s\n' "$port_number" || exit 1
        printf '    password: %s\n' "$password_yaml" || exit 1
        printf '%s\n' '    udp: true' || exit 1
        [ -z "$sni" ] || printf '    sni: %s\n' "$sni_yaml" || exit 1
        [ "$insecure" != 1 ] || printf '%s\n' '    skip-cert-verify: true' || exit 1
        printf '%s\n' 'proxy-groups:' || exit 1
        printf "  - name: '%s'\n" "$group" || exit 1
        printf '%s\n' '    type: select' '    proxies:' || exit 1
        printf '      - %s\n' "$name_yaml" || exit 1
        printf '%s\n' '      - DIRECT' 'rules:' || exit 1
        printf "  - 'MATCH,%s'\n" "$group" || exit 1
    ) > "$tmp" || return 1
    chmod 0600 "$tmp" || return 1
    mv -f "$tmp" "$dest" || return 1
    tmp=''
    trap - EXIT HUP INT TERM
)

function _download_config() {
    local dest=$1
    local url=$2
    local validation_home=${3:-} validation_sandbox=${4:-} proxy_link
    [ -n "$validation_home" ] || validation_home=$(dirname "$dest")
    if [ "${url:0:4}" = 'file' ]; then
        _valid_config "$dest" "$validation_home" "$validation_sandbox"
        return $?
    fi
    _download_raw_config "$dest" "$url" || return 1
    _okcat '🍃' '下载成功：内核验证配置...'
    _valid_config "$dest" "$validation_home" "$validation_sandbox" || {
        _failcat '🍂' "验证失败：尝试订阅转换..."
        # Prefer data already downloaded so conversion survives a provider or
        # network outage after the first successful request. The stable
        # converter needs a direct URI for one-line subscriptions and a local
        # file for encoded subscription bodies. The original URL remains the
        # final compatibility fallback.
        if proxy_link=$(_read_single_proxy_link "$dest"); then
            case "$proxy_link" in
            anytls://*)
                if _convert_anytls_proxy_link "$dest" "$proxy_link" &&
                    _valid_config "$dest" "$validation_home" "$validation_sandbox"; then
                    return 0
                fi
                ;;
            esac
            if _download_convert_config "$dest" "$proxy_link" 2>/dev/null &&
                _valid_config "$dest" "$validation_home" "$validation_sandbox"; then
                return 0
            fi
        else
            if _download_convert_config "$dest" "$dest" 2>/dev/null &&
                _valid_config "$dest" "$validation_home" "$validation_sandbox"; then
                return 0
            fi
        fi
        _download_convert_config "$dest" "$url" &&
            _valid_config "$dest" "$validation_home" "$validation_sandbox" ||
            _failcat '🍂' "转换失败：请检查订阅内容或网络"
    }
}

_process_is_current_user_live() {
    local pid=$1 current_uid owner_uid process_state
    [[ $pid =~ ^[0-9]+$ ]] || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    current_uid=$(id -u 2>/dev/null) || return 1

    if [ -r "/proc/$pid/status" ]; then
        owner_uid=$(awk '$1 == "Uid:" { print $2; exit }' "/proc/$pid/status" 2>/dev/null) || return 1
        process_state=$(awk '$1 == "State:" { print $2; exit }' "/proc/$pid/status" 2>/dev/null) || return 1
    else
        owner_uid=$(ps -p "$pid" -o uid= 2>/dev/null | tr -d '[:space:]') || return 1
        process_state=$(ps -p "$pid" -o stat= 2>/dev/null | tr -d '[:space:]') || return 1
    fi

    [ -n "$owner_uid" ] && [ "$owner_uid" = "$current_uid" ] || return 1
    case "$process_state" in
    '' | Z*) return 1 ;;
    esac
    return 0
}

_process_start_id() {
    local pid=$1 process_stat start_id
    _process_is_current_user_live "$pid" || return 1

    if [ -r "/proc/$pid/stat" ]; then
        process_stat=$(LC_ALL=C sed 's/^.*) //' "/proc/$pid/stat" 2>/dev/null) || return 1
        start_id=$(printf '%s\n' "$process_stat" | awk '{ print $20; exit }') || return 1
        case "$start_id" in
        '' | *[!0-9]*) return 1 ;;
        esac
        printf 'linux:%s\n' "$start_id"
        return 0
    fi

    # BSD/macOS does not expose /proc. lstart is stable for a process lifetime;
    # executable identity below makes the fallback conservative on PID reuse.
    start_id=$(LC_ALL=C ps -p "$pid" -o lstart= 2>/dev/null |
        sed 's/^[[:space:]]*//; s/[[:space:]]*$//') || return 1
    [ -n "$start_id" ] || return 1
    printf 'bsd:%s\n' "$start_id"
}

_capture_process_start_id() {
    local pid=$1 count=0 start_id
    while [ "$count" -lt 100 ]; do
        start_id=$(_process_start_id "$pid" 2>/dev/null) && {
            printf '%s\n' "$start_id"
            return 0
        }
        _process_is_current_user_live "$pid" || return 1
        sleep 0.01
        count=$((count + 1))
    done
    return 1
}

_process_executable_id() {
    local pid=$1 process_command executable_id
    _process_is_current_user_live "$pid" || return 1

    # /proc/<pid>/exe remains a usable magic link after the executable was
    # atomically replaced, but a generic `test -e` may report it as dangling.
    if [ -L "/proc/$pid/exe" ] || [ -e "/proc/$pid/exe" ]; then
        executable_id=$(_rc_stat_id "/proc/$pid/exe") || return 1
        printf 'inode:%s\n' "$executable_id"
        return 0
    fi

    process_command=$(ps -p "$pid" -o comm= 2>/dev/null |
        sed 's/^[[:space:]]*//; s/[[:space:]]*$//') || return 1
    [ -n "$process_command" ] || return 1
    case "$process_command" in
    /*)
        executable_id=$(_rc_stat_id "$process_command") || return 1
        printf 'inode:%s\n' "$executable_id"
        ;;
    *)
        # Some BSD ps implementations expose only the executable name. Keep it
        # as a conservative fingerprint and combine it with the start identity.
        printf 'name:%s\n' "$process_command"
        ;;
    esac
}

_process_command_references_path() {
    local pid=$1 expected_path=$2 process_args expected_id executable_id
    [ -n "$expected_path" ] || return 1

    expected_id=$(_rc_stat_id "$expected_path" 2>/dev/null || true)
    executable_id=$(_process_executable_id "$pid" 2>/dev/null || true)
    if [ -n "$expected_id" ] && [ "$executable_id" = "inode:$expected_id" ]; then
        return 0
    fi

    if [ -r "/proc/$pid/cmdline" ]; then
        LC_ALL=C tr '\000' '\n' < "/proc/$pid/cmdline" 2>/dev/null | awk \
            -v expected="$expected_path" '$0 == expected { found = 1 } END { exit !found }'
        return $?
    fi

    process_args=$(ps -p "$pid" -o args= 2>/dev/null || true)
    [ -n "$process_args" ] || return 1
    case "$process_args" in
    "$expected_path" | "$expected_path "* | *" $expected_path" | *" $expected_path "*) return 0 ;;
    esac
    return 1
}

_process_start_instance_is_current() {
    local pid=$1 expected_start_id=$2 current_start_id
    [ -n "$expected_start_id" ] || return 1
    current_start_id=$(_process_start_id "$pid" 2>/dev/null) || return 1
    [ "$current_start_id" = "$expected_start_id" ]
}

_process_instance_is_current() {
    local pid=$1 expected_start_id=$2 expected_executable_id=$3 current_executable_id
    _process_start_instance_is_current "$pid" "$expected_start_id" || return 1
    [ -n "$expected_executable_id" ] || return 1
    current_executable_id=$(_process_executable_id "$pid" 2>/dev/null) || return 1
    [ "$current_executable_id" = "$expected_executable_id" ]
}

_process_owned_instance_is_current() {
    local pid=$1 expected_start_id=$2 expected_executable_id=$3 expected_path=${4:-}
    _process_instance_is_current "$pid" "$expected_start_id" "$expected_executable_id" || return 1
    [ -z "$expected_path" ] || _process_command_references_path "$pid" "$expected_path"
}

_wait_for_process_exec_identity() {
    local pid=$1 expected_start_id=$2 expected_path=$3 count=0 executable_id
    while _process_start_instance_is_current "$pid" "$expected_start_id" && [ "$count" -lt 100 ]; do
        if _process_command_references_path "$pid" "$expected_path"; then
            executable_id=$(_process_executable_id "$pid" 2>/dev/null) || return 1
            [ -n "$executable_id" ] || return 1
            printf '%s\n' "$executable_id"
            return 0
        fi
        sleep 0.01
        count=$((count + 1))
    done
    return 1
}

_terminate_process_instance() {
    local pid=$1 expected_start_id=$2 expected_executable_id=${3:-}
    local expected_path=${4:-}
    local count=0

    [ -n "$expected_start_id" ] || return 1
    _process_start_instance_is_current "$pid" "$expected_start_id" || return 0
    if [ -n "$expected_executable_id" ]; then
        # A process that kept its start identity but changed executable is not
        # ours to signal. Report the ambiguity instead of treating it as exit.
        _process_owned_instance_is_current \
            "$pid" "$expected_start_id" "$expected_executable_id" "$expected_path" || return 1
    fi

    if ! kill "$pid" 2>/dev/null; then
        _process_start_instance_is_current "$pid" "$expected_start_id" || return 0
        if [ -n "$expected_executable_id" ]; then
            _process_owned_instance_is_current \
                "$pid" "$expected_start_id" "$expected_executable_id" "$expected_path" || return 1
        fi
        return 1
    fi

    while [ "$count" -lt 20 ]; do
        _process_start_instance_is_current "$pid" "$expected_start_id" || break
        if [ -n "$expected_executable_id" ]; then
            _process_owned_instance_is_current \
                "$pid" "$expected_start_id" "$expected_executable_id" "$expected_path" || return 1
        fi
        sleep 0.1
        count=$((count + 1))
    done

    _process_start_instance_is_current "$pid" "$expected_start_id" || return 0
    if [ -n "$expected_executable_id" ]; then
        _process_owned_instance_is_current \
            "$pid" "$expected_start_id" "$expected_executable_id" "$expected_path" || return 1
    fi
    kill -9 "$pid" 2>/dev/null || {
        _process_start_instance_is_current "$pid" "$expected_start_id" || return 0
        if [ -n "$expected_executable_id" ]; then
            _process_owned_instance_is_current \
                "$pid" "$expected_start_id" "$expected_executable_id" "$expected_path" || return 1
        fi
        return 1
    }
    count=0
    while _process_start_instance_is_current "$pid" "$expected_start_id" && [ "$count" -lt 20 ]; do
        sleep 0.1
        count=$((count + 1))
    done
    _process_start_instance_is_current "$pid" "$expected_start_id" && return 1
    return 0
}

_start_convert() {
    # Ensure config exists (YAML) so we can manage port reliably.
    [ ! -e "$BIN_SUBCONVERTER_CONFIG" ] && {
        cp -f "$BIN_SUBCONVERTER_DIR/pref.example.yml" "$BIN_SUBCONVERTER_CONFIG" 2>/dev/null || true
    }

    local config_port
    config_port=$("$BIN_YQ" '.server.port // ""' "$BIN_SUBCONVERTER_CONFIG" 2>/dev/null)
    [[ $config_port =~ ^[0-9]+$ ]] && BIN_SUBCONVERTER_PORT=$config_port

    _is_already_in_use $BIN_SUBCONVERTER_PORT 'subconverter' && {
        local newPort=$(_get_random_port)
        _failcat '🎯' "端口占用：$BIN_SUBCONVERTER_PORT 🎲 随机分配：$newPort"
        "$BIN_YQ" -i ".server.port = $newPort" "$BIN_SUBCONVERTER_CONFIG"
        BIN_SUBCONVERTER_PORT=$newPort
    }
    local start=$(date +%s)
    # Record both the process start identity and executable fingerprint. A PID
    # alone is not ownership: it can be reused before timeout cleanup runs.
    BIN_SUBCONVERTER_START_ID=''
    BIN_SUBCONVERTER_EXECUTABLE_ID=''
    if [ -L "$BIN_SUBCONVERTER_LOG" ] ||
        { [ -e "$BIN_SUBCONVERTER_LOG" ] && [ ! -f "$BIN_SUBCONVERTER_LOG" ]; }; then
        _failcat "订阅转换日志路径不是普通文件：$BIN_SUBCONVERTER_LOG"
        return 1
    fi
    (umask 077 && : > "$BIN_SUBCONVERTER_LOG") || return 1
    chmod 0600 "$BIN_SUBCONVERTER_LOG" || return 1
    # The converter may print the requested subscription URL. Keep its raw
    # output out of product logs so provider tokens are never persisted.
    (cd "$BIN_SUBCONVERTER_DIR" && exec "$BIN_SUBCONVERTER" 9>&- > /dev/null 2>&1) &
    BIN_SUBCONVERTER_PID=$!
    BIN_SUBCONVERTER_START_ID=$(_capture_process_start_id "$BIN_SUBCONVERTER_PID" 2>/dev/null) || {
        if ! _process_is_current_user_live "$BIN_SUBCONVERTER_PID"; then
            wait "$BIN_SUBCONVERTER_PID" 2>/dev/null || true
        fi
        BIN_SUBCONVERTER_PID=''
        _failcat "无法确认订阅转换进程身份"
        return 1
    }
    BIN_SUBCONVERTER_EXECUTABLE_ID=$(
        _wait_for_process_exec_identity "$BIN_SUBCONVERTER_PID" \
            "$BIN_SUBCONVERTER_START_ID" "$BIN_SUBCONVERTER"
    ) || {
        _terminate_process_instance "$BIN_SUBCONVERTER_PID" "$BIN_SUBCONVERTER_START_ID" || true
        wait "$BIN_SUBCONVERTER_PID" 2>/dev/null || true
        BIN_SUBCONVERTER_PID=''
        BIN_SUBCONVERTER_START_ID=''
        _failcat "无法确认订阅转换进程身份"
        return 1
    }
    while ! _is_bind "$BIN_SUBCONVERTER_PORT" >&/dev/null; do
        sleep 1s
        local now=$(date +%s)
        if [ $((now - start)) -gt 10 ]; then
            _stop_convert
            _failcat "订阅转换服务未启动"
            return 1
        fi
    done
}
_stop_convert() {
    local pid=${BIN_SUBCONVERTER_PID:-}
    local start_id=${BIN_SUBCONVERTER_START_ID:-}
    local executable_id=${BIN_SUBCONVERTER_EXECUTABLE_ID:-}
    [[ $pid =~ ^[0-9]+$ ]] || return 0
    local stop_result=0
    _terminate_process_instance "$pid" "$start_id" "$executable_id" "$BIN_SUBCONVERTER" || stop_result=1
    if [ "$stop_result" -eq 0 ] ||
        { [ -n "$start_id" ] && ! _process_start_instance_is_current "$pid" "$start_id"; } ||
        ! _process_is_current_user_live "$pid"; then
        wait "$pid" 2>/dev/null || true
    fi
    if [ "$stop_result" -eq 0 ]; then
        BIN_SUBCONVERTER_PID=''
        BIN_SUBCONVERTER_START_ID=''
        BIN_SUBCONVERTER_EXECUTABLE_ID=''
    fi
    return "$stop_result"
}

# User-space process management functions
_mihomo_pid_args_match() {
    local pid=$1 args

    if [ -r "/proc/$pid/cmdline" ]; then
        LC_ALL=C tr '\000' '\n' < "/proc/$pid/cmdline" 2>/dev/null | awk \
            -v kernel="$BIN_KERNEL" -v base="$MIHOMO_BASE_DIR" -v runtime="$MIHOMO_CONFIG_RUNTIME" '
                NR == 1 && $0 == kernel { has_kernel = 1 }
                previous == "-d" && $0 == base { has_base = 1 }
                previous == "-f" && $0 == runtime { has_runtime = 1 }
                { previous = $0 }
                END { exit !(has_kernel && has_base && has_runtime) }
            '
        return $?
    fi

    args=$(ps -p "$pid" -o args= 2>/dev/null || true)
    [ -n "$args" ] || return 1
    case "$args" in
    "$BIN_KERNEL" | "$BIN_KERNEL "*) ;;
    *) return 1 ;;
    esac
    case " $args " in
    *" -d $MIHOMO_BASE_DIR "*) ;;
    *) return 1 ;;
    esac
    case " $args " in
    *" -f $MIHOMO_CONFIG_RUNTIME "*) ;;
    *) return 1 ;;
    esac
}

_is_mihomo_pid() {
    local pid=$1 current_uid owner_uid process_state
    [[ $pid =~ ^[0-9]+$ ]] || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    current_uid=$(id -u 2>/dev/null) || return 1

    if [ -r "/proc/$pid/status" ] &&
        { [ -L "/proc/$pid/exe" ] || [ -e "/proc/$pid/exe" ]; }; then
        owner_uid=$(awk '$1 == "Uid:" { print $2; exit }' "/proc/$pid/status" 2>/dev/null) || return 1
        [ "$owner_uid" = "$current_uid" ] || return 1
        process_state=$(awk '$1 == "State:" { print $2; exit }' "/proc/$pid/status" 2>/dev/null) || return 1
        [ "$process_state" != Z ] || return 1
        # The on-disk kernel can be atomically replaced while this process is
        # running. Its executable inode then legitimately differs from the
        # current BIN_KERNEL inode. Exact argv, owner and start identity are
        # what bind lifecycle management to the old managed process; the
        # actual executable inode is captured immediately before signalling.
        _mihomo_pid_args_match "$pid"
        return $?
    fi

    owner_uid=$(ps -p "$pid" -o uid= 2>/dev/null | tr -d '[:space:]') || return 1
    [ "$owner_uid" = "$current_uid" ] || return 1
    process_state=$(ps -p "$pid" -o stat= 2>/dev/null | tr -d '[:space:]') || return 1
    case "$process_state" in
    Z*) return 1 ;;
    esac
    _mihomo_pid_args_match "$pid"
}

_find_managed_mihomo_pids() {
    local current_uid process_dir pid process_table line
    current_uid=$(id -u 2>/dev/null) || return 1

    if [ -d /proc/self ] && [ -r /proc/self/status ]; then
        for process_dir in /proc/[0-9]*; do
            [ -d "$process_dir" ] || continue
            pid=${process_dir##*/}
            _is_mihomo_pid "$pid" && printf '%s\n' "$pid"
        done
        return 0
    fi

    process_table=$(ps -U "$current_uid" -o pid=,args= 2>/dev/null) ||
        process_table=$(ps -u "$current_uid" -o pid=,args= 2>/dev/null) || return 1
    while IFS= read -r line; do
        line=${line#"${line%%[![:space:]]*}"}
        pid=${line%%[[:space:]]*}
        [[ $pid =~ ^[0-9]+$ ]] || continue
        case " $line " in
        *" -d $MIHOMO_BASE_DIR "*) ;;
        *) continue ;;
        esac
        case " $line " in
        *" -f $MIHOMO_CONFIG_RUNTIME "*) ;;
        *) continue ;;
        esac
        _is_mihomo_pid "$pid" && printf '%s\n' "$pid"
    done <<EOF
$process_table
EOF
    return 0
}

_is_same_managed_mihomo_instance() {
    local pid=$1 start_id=$2 executable_id=$3
    _process_instance_is_current "$pid" "$start_id" "$executable_id" || return 1
    _is_mihomo_pid "$pid"
}

_terminate_managed_mihomo_pid() {
    local pid=$1 count=0 start_id executable_id
    _is_mihomo_pid "$pid" || return 0
    start_id=$(_process_start_id "$pid" 2>/dev/null) || {
        _is_mihomo_pid "$pid" && return 1
        return 0
    }
    executable_id=$(_process_executable_id "$pid" 2>/dev/null) || {
        _process_start_instance_is_current "$pid" "$start_id" && return 1
        return 0
    }
    _is_same_managed_mihomo_instance "$pid" "$start_id" "$executable_id" || {
        _process_start_instance_is_current "$pid" "$start_id" && return 1
        return 0
    }

    if ! kill "$pid" 2>/dev/null; then
        _process_start_instance_is_current "$pid" "$start_id" || return 0
        _is_same_managed_mihomo_instance "$pid" "$start_id" "$executable_id" || return 1
        _failcat "无权停止 mihomo 进程 (PID: $pid)"
        return 1
    fi
    while _is_same_managed_mihomo_instance "$pid" "$start_id" "$executable_id" && [ "$count" -lt 50 ]; do
        sleep 0.1
        count=$((count + 1))
    done
    if _process_start_instance_is_current "$pid" "$start_id"; then
        _is_same_managed_mihomo_instance "$pid" "$start_id" "$executable_id" || {
            _failcat "mihomo 进程身份在停止期间发生变化，已拒绝强制终止 (PID: $pid)"
            return 1
        }
        kill -9 "$pid" 2>/dev/null || {
            _failcat "无法强制终止 mihomo 进程 (PID: $pid)"
            return 1
        }
        count=0
        while _process_start_instance_is_current "$pid" "$start_id" && [ "$count" -lt 20 ]; do
            sleep 0.1
            count=$((count + 1))
        done
    fi
    _process_start_instance_is_current "$pid" "$start_id" && {
        _failcat "mihomo 进程未能停止 (PID: $pid)"
        return 1
    }
    return 0
}

_mihomo_operation_acquire() {
    [ "${MIHOMO_OPERATION_LOCK_HELD:-false}" = true ] && return 0
    command -v _upgrade_acquire_lock >/dev/null 2>&1 || return 0
    _upgrade_acquire_lock || {
        _failcat "另一个 mihomo 操作正在运行"
        return 1
    }
    MIHOMO_OPERATION_LOCK_OWNED=true
}

_mihomo_operation_release() {
    [ "${MIHOMO_OPERATION_LOCK_OWNED:-false}" = true ] || return 0
    _upgrade_release_lock
    MIHOMO_OPERATION_LOCK_OWNED=false
}

_mihomo_run_locked() {
    local operation=$1
    shift
    if [ "${MIHOMO_OPERATION_LOCK_HELD:-false}" = true ]; then
        "$operation" "$@"
        return $?
    fi

    local MIHOMO_OPERATION_LOCK_OWNED=false
    local MIHOMO_OPERATION_LOCK_HELD=false
    local operation_result
    _mihomo_operation_acquire || return 1
    MIHOMO_OPERATION_LOCK_HELD=true
    "$operation" "$@"
    operation_result=$?
    _mihomo_operation_release
    return "$operation_result"
}

start_mihomo() {
    _mihomo_run_locked _start_mihomo_unlocked "$@"
}

_start_mihomo_unlocked() (
    local pid_file="$MIHOMO_BASE_DIR/config/mihomo.pid"
    local log_file="$MIHOMO_BASE_DIR/logs/mihomo.log"
    local pid='' pid_tmp='' pid_start_id='' pid_executable_id=''
    local managed_pids='' start_committed=false log_writer

    _start_mihomo_cleanup() {
        local cleanup_status=$?
        local child_stopped=false
        trap - EXIT HUP INT TERM
        rm -f "$pid_tmp" 2>/dev/null || true

        if [ "$start_committed" != true ] && [[ $pid =~ ^[0-9]+$ ]]; then
            # Verify the captured process instance before every signal. The
            # child may already have exited and its numeric PID may be reused.
            if _terminate_process_instance "$pid" "$pid_start_id" "$pid_executable_id" "$BIN_KERNEL" ||
                { [ -n "$pid_start_id" ] && ! _process_start_instance_is_current "$pid" "$pid_start_id"; } ||
                ! _process_is_current_user_live "$pid"; then
                wait "$pid" 2>/dev/null || true
                child_stopped=true
            fi
            if [ "$child_stopped" = true ] && [ "$(cat "$pid_file" 2>/dev/null || true)" = "$pid" ]; then
                rm -f "$pid_file" 2>/dev/null || true
            elif [ "$child_stopped" != true ]; then
                _failcat "无法确认启动失败的 mihomo 子进程已停止；已保留 PID 文件：$pid_file" || true
            fi
        fi
        return "$cleanup_status"
    }

    trap '_start_mihomo_cleanup' EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM

    # Create necessary directories
    mkdir -p "$(dirname "$pid_file")" "$(dirname "$log_file")" || return 1

    # Starting a second process is unsafe when discovery itself failed. Unlike
    # the read-only boolean helper, this mutation needs a definite scan result.
    managed_pids=$(_find_managed_mihomo_pids) || {
        _failcat "无法安全确认 mihomo 进程状态，已取消启动"
        return 1
    }
    if [ -n "$managed_pids" ]; then
        _okcat "mihomo 进程已在运行"
        return 0
    fi

    log_writer="${MIHOMO_SCRIPT_DIR}/log-writer.sh"
    [ -x "$log_writer" ] || log_writer="${SCRIPT_BASE_DIR}/log-writer.sh"
    [ -x "$log_writer" ] || {
        _failcat "缺少受管日志写入器：$log_writer"
        return 1
    }

    # Both processes ignore shell hangups. The process-substitution child
    # closes the lifecycle-lock descriptor and exits on EOF when Mihomo stops.
    # `exec` matters: a lingering wrapper shell would keep the caller's stdout
    # open and hang `clash on | tee` or `ssh host clash on` forever.
    # `$!` remains the Mihomo PID, so process identity checks are unchanged.
    nohup "$BIN_KERNEL" -d "$MIHOMO_BASE_DIR" -f "$MIHOMO_CONFIG_RUNTIME" \
        > >(exec nohup "$log_writer" "$log_file" "$MIHOMO_LOG_MAX_BYTES" \
            >/dev/null 2>&1 9>&-) 2>&1 9>&- &

    pid=$!
    pid_start_id=$(_capture_process_start_id "$pid" 2>/dev/null) || return 1
    pid_executable_id=$(
        _wait_for_process_exec_identity "$pid" "$pid_start_id" "$BIN_KERNEL"
    ) || return 1
    pid_tmp=$(mktemp "${pid_file}.tmp.XXXXXX") || return 1
    printf '%s\n' "$pid" > "$pid_tmp" || return 1
    mv -f "$pid_tmp" "$pid_file" || return 1
    pid_tmp=''

    # Wait a moment and verify the process started successfully
    sleep 1
    if _is_mihomo_pid "$pid"; then
        start_committed=true
        trap - EXIT HUP INT TERM
        _okcat "mihomo 进程启动成功 (PID: $pid)"
        return 0
    else
        rm -f "$pid_file"
        _failcat "mihomo 进程启动失败，请检查日志: $log_file"
        return 1
    fi
)

stop_mihomo() {
    _mihomo_run_locked _stop_mihomo_unlocked "$@"
}

_stop_mihomo_unlocked() {
    local pid_file="$MIHOMO_BASE_DIR/config/mihomo.pid"
    local managed_pids remaining pid stop_failed=false

    managed_pids=$(_find_managed_mihomo_pids) || {
        _failcat "无法安全确认 mihomo 进程状态；拒绝清理 PID 或安装文件"
        return 1
    }
    while IFS= read -r pid; do
        [ -n "$pid" ] || continue
        _terminate_managed_mihomo_pid "$pid" || stop_failed=true
    done <<EOF
$managed_pids
EOF
    [ "$stop_failed" = false ] || return 1

    remaining=$(_find_managed_mihomo_pids) || {
        _failcat "停止后无法再次确认 mihomo 进程状态"
        return 1
    }
    [ -z "$remaining" ] || {
        _failcat "仍检测到受管 mihomo 进程，拒绝继续清理：$remaining"
        return 1
    }

    rm -f "$pid_file" || return 1
    # 清理端口状态文件
    rm -f "$MIHOMO_PORT_STATE" || return 1
    if [ -n "$managed_pids" ]; then
        _okcat "mihomo 进程已停止"
    else
        _okcat "mihomo 进程未运行"
    fi
    return 0
}

is_mihomo_running() {
    local pid_file="$MIHOMO_BASE_DIR/config/mihomo.pid"
    local pid managed_pids

    pid=$(cat "$pid_file" 2>/dev/null || true)
    if [ -n "$pid" ] && _is_mihomo_pid "$pid"; then
        return 0
    fi

    managed_pids=$(_find_managed_mihomo_pids) || return 0
    [ -n "$managed_pids" ]
}

_resolve_port_conflicts() {
    local config_file=$1
    local show_message=${2:-true}
    local preference_mode=${3:-}
    local preference_value=${4:-}
    local port_changed=false

    if [ -n "$preference_mode" ]; then
        PORT_PREF_MODE=$preference_mode
        PORT_PREF_VALUE=$preference_value
    else
        _load_port_preferences
    fi

    # Check mixed-port (proxy port)
    local mixed_port
    mixed_port=$("$BIN_YQ" '.mixed-port // ""' "$config_file" 2>/dev/null) || return 1
    if [ "$PORT_PREF_MODE" = "manual" ]; then
        [[ $PORT_PREF_VALUE =~ ^[0-9]+$ ]] &&
            [ "$PORT_PREF_VALUE" -ge 1024 ] && [ "$PORT_PREF_VALUE" -le 65535 ] || {
            _failcat '固定代理端口偏好无效，请执行 clash port set <1024-65535>' || true
            return 1
        }
        MIXED_PORT=$PORT_PREF_VALUE
        "$BIN_YQ" -i ".mixed-port = $MIXED_PORT" "$config_file" || return 1
    else
        MIXED_PORT=${mixed_port:-7890}
    fi

    if _is_already_in_use "$MIXED_PORT" "$BIN_KERNEL_NAME"; then
        if [ "$PORT_PREF_MODE" = "manual" ]; then
            _failcat '🎯' "固定代理端口 ${MIXED_PORT} 已被占用；请执行 clash port set <端口> 或 clash port auto" || true
            return 1
        else
            [ "$show_message" = true ] && _failcat '🎯' "代理端口占用：${MIXED_PORT}"
            local newPort
            newPort=$(_get_random_port) || return 1
            [ "$show_message" = true ] && _failcat '🎯' "代理端口占用：${MIXED_PORT} 🎲 随机分配：$newPort"
            "$BIN_YQ" -i ".mixed-port = $newPort" "$config_file" || return 1
            MIXED_PORT=$newPort
            port_changed=true
        fi
    fi

    # Check external-controller (UI port)
    local ext_addr
    ext_addr=$("$BIN_YQ" '.external-controller // ""' "$config_file" 2>/dev/null) || return 1
    if [ -n "$ext_addr" ]; then
        local ext_port=${ext_addr##*:}
        UI_PORT=${ext_port:-9090}
        # Preserve the original bind address format
        local bind_addr=${ext_addr%:*}
        [ "$bind_addr" = "$ext_addr" ] && bind_addr="127.0.0.1"  # fallback if no colon found
    else
        UI_PORT=9090
        bind_addr="127.0.0.1"
    fi

    if _is_already_in_use "$UI_PORT" "$BIN_KERNEL_NAME"; then
        local newPort
        newPort=$(_get_random_port) || return 1
        [ "$show_message" = true ] && _failcat '🎯' "UI端口占用：${UI_PORT} 🎲 随机分配：$newPort"
        "$BIN_YQ" -i ".external-controller = \"${bind_addr}:$newPort\"" "$config_file" || return 1
        UI_PORT=$newPort
        port_changed=true
    fi

    # Check DNS listen port
    local dns_listen
    dns_listen=$("$BIN_YQ" '.dns.listen // ""' "$config_file" 2>/dev/null) || return 1
    if [ -n "$dns_listen" ]; then
        local dns_port=${dns_listen##*:}
        DNS_PORT=${dns_port:-15353}
        # Preserve the original bind address format
        local dns_bind_addr=${dns_listen%:*}
        [ "$dns_bind_addr" = "$dns_listen" ] && dns_bind_addr="127.0.0.1"  # fail closed if no host was present
    else
        DNS_PORT=15353
        dns_bind_addr="127.0.0.1"
    fi

    if _is_already_in_use "$DNS_PORT" "$BIN_KERNEL_NAME"; then
        local newPort
        newPort=$(_get_random_port) || return 1
        [ "$show_message" = true ] && _failcat '🎯' "DNS端口占用：${DNS_PORT} 🎲 随机分配：$newPort"
        "$BIN_YQ" -i ".dns.listen = \"${dns_bind_addr}:$newPort\"" "$config_file" || return 1
        DNS_PORT=$newPort
        port_changed=true
    fi

    if [ "$port_changed" = true ] && [ "$show_message" = true ]; then
        _okcat "端口分配完成 - 代理:$MIXED_PORT UI:$UI_PORT DNS:$DNS_PORT"
    fi

    return 0
}

# ─── Proxy Environment Health ──────────────────────────────────────
#
# Pure predicates for diagnosing whether the current shell's proxy
# environment variables are consistent with mihomo's live state.
# Used by watch_proxy (shell startup), clash status, and clash doctor.

# Return true if any proxy environment variable is set.
_proxy_env_is_set() {
    [ -n "${http_proxy:-}" ] || [ -n "${HTTP_PROXY:-}" ] ||
        [ -n "${https_proxy:-}" ] || [ -n "${HTTPS_PROXY:-}" ] ||
        [ -n "${all_proxy:-}" ] || [ -n "${ALL_PROXY:-}" ]
}

# Return true if the proxy URL in the environment points to a loopback
# address (127.0.0.1, ::1, or localhost).  mihomo always binds to
# loopback in userspace mode, so a loopback proxy that has no live
# listener is almost certainly a stale mihomo variable.
_proxy_env_is_loopback() {
    local url
    url=${http_proxy:-${HTTP_PROXY:-${all_proxy:-${ALL_PROXY:-}}}}
    case "$url" in
    *127.0.0.1*|*localhost*|*\[::1\]*) return 0 ;;
    *) return 1 ;;
    esac
}
