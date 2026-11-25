#!/usr/bin/env bash
# One-line installer. Nothing here needs root:
#   curl -fsSL https://raw.githubusercontent.com/SaladDay/clash-for-lab/main/get.sh | bash -s -- '订阅地址'
# Everything lives in functions so a truncated download never runs half a script.

usage() {
    cat <<'EOF'
用法: get.sh ['订阅地址'] [--mirror https://镜像] [--dir 安装目录] [--ref 分支或标签]
已安装时会升级管理脚本并保留配置；带订阅地址则同时更换订阅。
EOF
}

fetch() {
    local source_url=$1 destination=$2
    shift 2
    curl -fL --retry 2 --connect-timeout 10 --speed-limit 1024 --speed-time 30 \
        --progress-bar -o "$destination" "$@" "$source_url"
}

main() {
    local repo=SaladDay/clash-for-lab ref=main mirror=${CLASH_MIRROR:-}
    local url='' dir='' tool archive source_url fallback_url
    while [ $# -gt 0 ]; do
        case "$1" in
        --mirror|--ref|--url|--dir)
            [ $# -ge 2 ] || { usage >&2; return 1; }
            case "$1" in
            --mirror) mirror=$2 ;;
            --ref) ref=$2 ;;
            --url) url=$2 ;;
            --dir) dir=$2 ;;
            esac
            shift 2
            ;;
        -h|--help) usage; return 0 ;;
        http://*|https://*) url=$1; shift ;;
        *) printf '未知参数：%s\n' "$1" >&2; usage >&2; return 1 ;;
        esac
    done

    case "$(uname -s):$(uname -m)" in
    Linux:x86_64|Linux:amd64) ;;
    *) printf '仅支持 Linux x86_64，当前：%s %s\n' "$(uname -s)" "$(uname -m)" >&2; return 1 ;;
    esac
    for tool in curl tar gzip; do
        command -v "$tool" >/dev/null 2>&1 || { printf '缺少命令：%s\n' "$tool" >&2; return 1; }
    done

    # Prefer $HOME: /tmp is often tiny, full or noexec on shared servers.
    mkdir -p "$HOME/.cache" || return 1
    WORK_DIR=$(mktemp -d "$HOME/.cache/clash-for-lab-install.XXXXXX") || return 1
    trap 'rm -rf -- "$WORK_DIR"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM HUP
    archive="$WORK_DIR/src.tar.gz"
    # codeload is reachable on networks where github.com itself is flaky.
    source_url="${CLASH_SOURCE_URL:-https://codeload.github.com/${repo}/tar.gz/${ref}}"
    fallback_url="https://github.com/${repo}/archive/${ref}.tar.gz"
    [ -z "$mirror" ] || source_url="${mirror%/}/${fallback_url}"

    printf '⏳ 正在下载 clash-for-lab（约 45 MB）...\n'
    # A proxy variable left behind by a dead proxy must not block the install.
    fetch "$source_url" "$archive" || fetch "$source_url" "$archive" --noproxy '*' ||
        { [ -z "$mirror" ] && fetch "$fallback_url" "$archive"; } || {
        printf '😾 下载失败：%s\n' "$source_url" >&2
        [ -n "$mirror" ] ||
            printf '   连不上 GitHub 时可指定你信任的镜像重试：--mirror https://镜像地址\n' >&2
        return 1
    }
    mkdir "$WORK_DIR/src" &&
        tar -xzf "$archive" --strip-components=1 -C "$WORK_DIR/src" || {
        printf '😾 安装包损坏，请重试\n' >&2
        return 1
    }
    rm -f "$archive"

    # With `curl | bash` stdin is this script; give the installer the terminal.
    set -- "$WORK_DIR/src/install.sh"
    [ -z "$url" ] || set -- "$@" --url "$url"
    [ -z "$dir" ] || set -- "$@" --dir "$dir"
    # The shell the installer may open at the end must not pin WORK_DIR, so
    # only let it read the prompt and print what to do next.
    if (exec </dev/tty) 2>/dev/null; then
        CLASH_INSTALL_NO_SHELL=1 bash "$@" </dev/tty
    else
        CLASH_INSTALL_NO_SHELL=1 bash "$@" </dev/null
    fi
}

main "$@"
