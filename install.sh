#!/bin/bash
# ============================================================
# DSH 管理脚本 · 一键安装器
#
# 支持的运行方式（均已实测）：
#   1) bash <(curl -sSL <installer>)              # 非 root 会自动提权
#   2) curl -sSL <installer> | bash
#   3) curl -sSL <installer> -o /tmp/i.sh && bash /tmp/i.sh
#   4) sudo bash -c "$(curl -sSL <installer>)"
#
# ⚠️ 不要用 sudo bash <(curl ...)
#    sudo 会关闭 fd>=3，而 /dev/fd/N 是"进程私有"的句柄，
#    root 的 bash 打不开 /dev/fd/63 就直接退出，脚本一个字节都不会执行。
#    这属于调用方写法问题，脚本内部无法补救 —— 去掉 sudo 即可。
#
# 提权说明：非 root 运行时，本脚本会复制/重新下载自身并以 root 续跑，
#           所以上面第 1 种写法不需要手动加 sudo。
# ============================================================

# 与 dsh.sh 一致：明确拒绝 dash/sh，给出可执行的正确用法
if [ -z "${BASH_VERSION:-}" ]; then
    echo "❌ 本安装器必须使用 bash 运行，不要用 sh/dash" >&2
    echo "执行方式：bash $0" >&2
    exit 1
fi

set -euo pipefail

# ---------- 配置 ----------
RAW_BASE="${DSH_RAW_BASE:-https://raw.githubusercontent.com/ZDX1717/dsh-manager/main}"
SELF_NAME="install.sh"
PAYLOAD_NAME="dsh.sh"
SELF_URL="$RAW_BASE/$SELF_NAME"
PAYLOAD_URL="$RAW_BASE/$PAYLOAD_NAME"

# 自建镜像（国内可直连，实测与上游逐字节一致）。
# 放在内置源末尾：多数网络根本走不到它，只有 raw/Pages/jsDelivr 都不通时才会用到。
# 即便被篡改，也会被上面的 SHA-256 门禁拦下，不会装入未知内容。
MIRROR_RAW="https://github.zdx1717.ccwu.cc/raw/ZDX1717/dsh-manager/main"

# GitHub API 基地址。网络屏蔽 api.github.com 时可指向自己的镜像，
# 例如：DSH_GITHUB_API=https://your.mirror/proxy/api.github.com
# 只用于解析 commit SHA；伪造 SHA 会让 jsDelivr@<sha> 返回 404，属失败安全。
GITHUB_API="${DSH_GITHUB_API:-https://api.github.com}"

INSTALL_DIR="${DSH_INSTALL_DIR:-/usr/local/bin}"
TARGET_NAME="dsh-manager"
TARGET_BIN="$INSTALL_DIR/$TARGET_NAME"
# 兜底软链目录（通常 /usr/local/bin 已在 PATH，这里再补一个 /usr/bin）
LINK_DIR="${DSH_LINK_DIR:-/usr/bin}"
ALIAS_NAME="d"
PROFILE_FILE="${DSH_PROFILE_FILE:-/etc/profile.d/dsh-manager.sh}"

# 下载超时：故意设得较短——有备用源兜底，宁可快速失败切换，
# 也不要在被干扰的源上长时间干等。
CURL_CONNECT_TIMEOUT="${DSH_CONNECT_TIMEOUT:-8}"
CURL_MAX_TIME="${DSH_MAX_TIME:-30}"

# dsh.sh 的 SHA-256。每次改动 dsh.sh 必须同步更新这里。
# 作用：下载源被第三方镜像篡改、或 CDN 返回了旧缓存时，
# 都能立刻发现并拒绝安装，而不是把来路不明的内容装进系统。
PAYLOAD_SHA256="b3e9d6536f1da60e577a1aaa6f52a22d54ee75f1c567287f22280474b671299a"
# 写进 profile 片段的标记行：用于判断"这文件是不是本脚本写的"，
# 避免把 /etc/passwd 这类无关文件截断成两行 alias
PROFILE_MARK="# DSH 管理脚本快捷命令"

# 内置哈希必须是 64 位十六进制：空值会让校验静默放行（fail-open），
# 而界面上仍然打印"校验通过"，运维无从察觉
case "$PAYLOAD_SHA256" in
    *[!0-9a-f]*|"")
        echo "❌ 内置 PAYLOAD_SHA256 非法（必须是 64 位十六进制）" >&2
        exit 1
        ;;
esac
[ "${#PAYLOAD_SHA256}" -eq 64 ] || {
    echo "❌ 内置 PAYLOAD_SHA256 长度不对（应为 64）" >&2
    exit 1
}

ASSUME_YES=0
SKIP_VERIFY=0
FROM_FILE=""
ELEVATED_TMP=""
PAYLOAD_TMP=""

# 备用下载源。raw.githubusercontent.com 在国内经常被干扰，
# 卡住或超时是常见现象，因此依次尝试。
# jsDelivr 是公开 CDN，直接回源 GitHub 仓库内容；但它对 @分支 的缓存
# 可能长达 12 小时，会静默返回旧版本，所以这里优先用 commit SHA 寻址
# （SHA 对应的内容是immutable的，永远是最新且一致）。
# 可用 DSH_EXTRA_MIRRORS 追加自定义镜像（空格分隔的 URL 前缀）。
resolve_commit_sha() {
    local owner="$1" repo="$2" ref="$3"
    # GITHUB_API 来自环境变量：只接受 http(s)，否则以 "-" 开头的值会被 curl
    # 当成选项（例如 -K<文件> 可注入 url+output，以 root 往任意路径写）
    case "$GITHUB_API" in
        http://*|https://*) ;;
        *) return 0 ;;
    esac
    curl -fsSL \
        --connect-timeout "$CURL_CONNECT_TIMEOUT" \
        --max-time "$CURL_MAX_TIME" \
        -- "$GITHUB_API/repos/$owner/$repo/commits/$ref" 2>/dev/null \
        | sed -n 's/^[[:space:]]*"sha":[[:space:]]*"\([0-9a-f]\{40\}\)".*/\1/p' \
        | head -n 1
}

download_urls() {
    local rel="$1"
    # 主源：raw（5 分钟缓存，最权威）
    printf '%s\n' "$RAW_BASE/$rel"

    case "$RAW_BASE" in
        *raw.githubusercontent.com/*)
            local path="${RAW_BASE#*raw.githubusercontent.com/}"
            local owner="${path%%/*}"; path="${path#*/}"
            local repo="${path%%/*}"
            local ref="${path#*/}"

            # GitHub Pages：另一个 CDN（Fastly），与 raw 同时故障的概率更低
            printf '%s\n' "https://$owner.github.io/$repo/$rel"

            # jsDelivr：优先用 commit SHA 寻址（内容不可变，避免分支缓存滞后 12h）
            local sha
            sha="$(resolve_commit_sha "$owner" "$repo" "$ref" || true)"
            if [ -n "$sha" ]; then
                printf '%s\n' "https://cdn.jsdelivr.net/gh/$owner/$repo@$sha/$rel"
            fi
            # 兜底：SHA 解析失败时用分支名（可能滞后，但聊胜于无）
            printf '%s\n' "https://cdn.jsdelivr.net/gh/$owner/$repo@$ref/$rel"
            ;;
    esac

    local m
    # 自建镜像：排在所有内置源之后（多数网络走不到，只在前面全不通时启用）。
    # 仅当主源仍指向上游本仓库时才加 —— 镜像只镜像这一份，
    # 指向 fork 时加进来只会白白失败一次。
    if [ "$MIRROR_RAW" != "$RAW_BASE" ]; then
        case "$RAW_BASE" in
            *ZDX1717/dsh-manager*) printf '%s\n' "$MIRROR_RAW/$rel" ;;
        esac
    fi

    for m in ${DSH_EXTRA_MIRRORS:-}; do
        printf '%s\n' "${m%/}/$rel"
    done
}

# 校验下载到的 dsh.sh 是否与预期哈希一致
verify_payload() {
    local file="$1"
    [ "$SKIP_VERIFY" -eq 1 ] && return 0
    [ -n "$PAYLOAD_SHA256" ] || return 1
    local actual
    actual="$(sha256sum "$file" 2>/dev/null | cut -d' ' -f1)"
    [ -n "$actual" ] || return 1
    [ "$actual" = "$PAYLOAD_SHA256" ]
}

# 依次尝试各下载源；任一成功（且校验通过）即返回 0。
# 全程有超时，不会永久挂起。
# $3 = 1 时要求内容通过 SHA-256 校验，不通过则换下一个源。
download_file() {
    local rel="$1" dest="$2" need_verify="${3:-0}"
    local url
    while IFS= read -r url; do
        [ -n "$url" ] || continue
        # 源串来自 DSH_RAW_BASE / DSH_EXTRA_MIRRORS（环境变量），必须只当 URL 用：
        # 不加 -- 的话，"-K/tmp/cfg" 之类会被 curl 解析成选项，可注入
        # url + output，实现以 root 往任意路径写内容。
        case "$url" in
            http://*|https://*) ;;
            *) printf '    ⚠ 跳过非 http(s) 源：%s\n' "$url"; continue ;;
        esac
        printf '  尝试 %s\n' "$url"
        # 注意顺序：-o 必须在 -- 之前，-- 之后的一切都会被当作 URL
        if curl -fsSL \
                --connect-timeout "$CURL_CONNECT_TIMEOUT" \
                --max-time "$CURL_MAX_TIME" \
                -o "$dest" -- "$url" 2>/dev/null && [ -s "$dest" ]; then
            if [ "$need_verify" -eq 1 ] && ! verify_payload "$dest"; then
                printf '    ⚠ 内容与预期哈希不符，拒绝使用该源\n'
                continue
            fi
            return 0
        fi
        printf '    失败或超时，换下一个源\n'
    done < <(download_urls "$rel")
    return 1
}

# 计算 git blob 哈希：sha1("blob <字节数>\0" + 内容)
# 用于和 GitHub contents API 登记的 sha 比对
git_blob_sha() {
    local f="$1" size
    command -v sha1sum >/dev/null 2>&1 || return 1
    size=$(stat -c%s "$f" 2>/dev/null) || return 1
    { printf 'blob %s\0' "$size"; cat -- "$f"; } | sha1sum | cut -d' ' -f1
}

# 校验"提权时重新下载的那份安装器"与仓库登记是否一致。
# 为什么需要：payload（dsh.sh）有内置 SHA-256 门禁，但**安装器自身**没有；
# 而它马上要以 root 运行。第一次抓取（用户自己的 curl）与提权时的第二次抓取
# 是两个独立请求，中间人可以对后者投毒。
# 返回 0=一致  1=不一致（可能被投毒）  2=无法比对（API 不可达 / 缺工具）
verify_installer_self() {
    local file="$1"
    case "$RAW_BASE" in
        *raw.githubusercontent.com/*) ;;
        *) return 2 ;;
    esac
    case "$GITHUB_API" in
        http://*|https://*) ;;
        *) return 2 ;;
    esac

    local rest owner repo ref
    rest="${RAW_BASE#*raw.githubusercontent.com/}"
    owner="${rest%%/*}"; rest="${rest#*/}"
    repo="${rest%%/*}";  ref="${rest#*/}"

    local api_sha local_sha
    api_sha="$(curl -fsSL \
        --connect-timeout "$CURL_CONNECT_TIMEOUT" \
        --max-time "$CURL_MAX_TIME" \
        -- "$GITHUB_API/repos/$owner/$repo/contents/$SELF_NAME?ref=$ref" 2>/dev/null \
        | sed -n 's/^[[:space:]]*"sha":[[:space:]]*"\([0-9a-f]\{40\}\)".*/\1/p' \
        | head -n 1)"
    [ -n "$api_sha" ] || return 2
    local_sha="$(git_blob_sha "$file")" || return 2
    [ -n "$local_sha" ] || return 2
    [ "$api_sha" = "$local_sha" ]
}

# ---------- 颜色 ----------
if [ -t 1 ]; then
    RST=$'\033[0m'; RED=$'\033[31m'; GRN=$'\033[32m'
    YEL=$'\033[33m'; BLD=$'\033[1m'
else
    RST=""; RED=""; GRN=""; YEL=""; BLD=""
fi

info()  { printf "${GRN}${BLD}[完成]${RST} %s\n" "$1"; }
warn()  { printf "${YEL}${BLD}[提示]${RST} %s\n" "$1"; }
err()   { printf "${RED}${BLD}[错误]${RST} %s\n" "$1" >&2; }
title() { printf "\n${BLD}==== %s ====${RST}\n" "$1"; }

usage() {
    cat <<EOF
DSH 管理脚本安装器

用法：
  bash <(curl -sSL $SELF_URL)
  curl -sSL $SELF_URL | bash
  curl -sSL $SELF_URL -o /tmp/i.sh && bash /tmp/i.sh

选项：
  -y, --yes              跳过确认，直接安装
      --from-file PATH   使用本地 dsh.sh 安装（离线安装）
      --skip-verify      跳过 dsh.sh 的 SHA-256 校验
  -h, --help             显示本帮助

环境变量：
  DSH_RAW_BASE           自定义下载源前缀
  DSH_EXTRA_MIRRORS      追加自定义镜像（空格分隔）
  DSH_INSTALL_DIR        安装目录（默认 /usr/local/bin）
  DSH_LINK_DIR           兜底软链目录（默认 /usr/bin）
  DSH_GITHUB_API         GitHub API 基地址（解析 commit SHA 用）
  DSH_CONNECT_TIMEOUT    单源连接超时（秒，默认 8）
  DSH_MAX_TIME           单源总超时（秒，默认 30）
EOF
}

# ---------- 清理 ----------
cleanup() {
    [ -n "$ELEVATED_TMP" ] && rm -f -- "$ELEVATED_TMP" 2>/dev/null
    [ -n "$PAYLOAD_TMP" ]  && rm -f -- "$PAYLOAD_TMP"  2>/dev/null
    return 0
}
trap cleanup EXIT

# ---------- 参数 ----------
parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            -y|--yes)        ASSUME_YES=1 ;;
            --from-file)
                # 缺参数时必须报错：静默当成"没给"，会把用户明确要求的
                # 离线安装悄悄变成"从互联网下载并安装"
                if [ $# -lt 2 ] || [ -z "${2:-}" ]; then
                    err "--from-file 后面必须跟一个文件路径"
                    exit 2
                fi
                FROM_FILE="$2"
                shift
                ;;
            --skip-verify)   SKIP_VERIFY=1 ;;
            --)              shift; break ;;
            -h|--help)       usage; exit 0 ;;
            *)               warn "忽略未知参数：$1" ;;
        esac
        shift || true
    done
}

# ---------- 交互确认（管道安全）----------
# 管道方式下 stdin 就是脚本自身，直接 read 会把脚本文本吃掉，
# 所以改从 /dev/tty 读；注意不能只用 [ -r /dev/tty ] 判断，
# 该文件可能"存在但打不开"，这里用真实打开来探测。
confirm() {
    local prompt="$1" answer=""
    if [ "$ASSUME_YES" -eq 1 ]; then
        printf "%s已由 --yes 自动确认\n" "$prompt"
        return 0
    fi
    if [ -t 0 ]; then
        read -r -p "$prompt" answer || answer=""
    elif { true; } 2>/dev/null < /dev/tty; then
        # 这里同样要兜住 read 失败（EOF / Ctrl+D）：本行不在条件上下文里，
        # set -e 会让脚本在问句之后凭空退出、连"已取消"都不打印
        read -r -p "$prompt" answer < /dev/tty || answer=""
    else
        # 没有控制终端：默认值必须是"否"。
        # 无人值守（cron/CI/curl|bash < /dev/null）时默认继续，
        # 等于绕过确认还顺带提权，与 (y/N) 的语义相反。
        warn "当前无可用终端，已按默认拒绝（需要自动安装请显式加 -y）"
        return 1
    fi
    [[ "$answer" =~ ^[Yy]$ ]]
}

# ---------- 提权 ----------
ensure_root() {
    [ "$(id -u)" -eq 0 ] && return 0

    if ! command -v sudo >/dev/null 2>&1; then
        err "需要 root 权限，当前用户为 $(id -un)，且系统未安装 sudo"
        echo "请先切换到 root：su -"
        exit 1
    fi

    warn "当前用户 $(id -un) 非 root，提权后继续"
    local tmp
    if ! tmp="$(mktemp "$(tmp_template dsh-installer.XXXXXX)" 2>/dev/null)"; then
        err "无法创建临时文件（检查 TMPDIR 是否可写）：${TMPDIR:-/tmp}"
        exit 1
    fi
    # 立刻登记，保证后面任何分支提前退出时都会被 EXIT trap 清理
    ELEVATED_TMP="$tmp"

    # 以文件方式调用时直接复制自身，省一次下载；
    # 进程替换 / 管道调用时 $0 不是普通文件，改为重新下载。
    #
    # 只接受"带路径分隔符的 $0"：`curl | bash` 时 $0 是字面量 "bash"，
    # 仅凭当前目录里存在同名普通文件就当成"我自己"，
    # 会把那个文件 cp 过来、过一遍 bash -n，然后以 root 执行。
    local self_is_file=0
    case "$0" in
        */*) [ -f "$0" ] && self_is_file=1 ;;
    esac
    if [ "$self_is_file" -eq 1 ] && cp -- "$0" "$tmp" 2>/dev/null; then
        :
    else
        # 只有走"重新下载自身"这条路才依赖 curl，缺了要直接说清楚，
        # 否则会一路报成"下载失败"，误导排查方向
        if ! command -v curl >/dev/null 2>&1; then
            err "需要 curl 重新获取安装脚本，但系统未安装 curl"
            echo "请先安装 curl 后重试，例如："
            echo "  sudo apt install -y curl     # Debian/Ubuntu"
            echo "  sudo dnf install -y curl     # Fedora/RHEL"
            echo "或先把本脚本下载到本地，再以文件方式运行。"
            exit 1
        fi
        echo "正在重新获取安装脚本..."
        if ! download_file "$SELF_NAME" "$tmp"; then
            err "重新下载安装脚本失败"
            echo "可用 DSH_EXTRA_MIRRORS 指定自定义镜像后重试，例如："
            echo "  DSH_EXTRA_MIRRORS=https://ghproxy.net/https://raw.githubusercontent.com/ZDX1717/dsh-manager/main bash install.sh"
            exit 1
        fi
    fi

    if [ ! -s "$tmp" ]; then
        err "取到的安装脚本为空"
        exit 1
    fi
    # 执行前先做语法校验：这个文件马上要以 root 跑
    if ! bash -n "$tmp" 2>/dev/null; then
        err "取到的安装脚本语法校验未通过，已中止（可能下载不完整）"
        exit 1
    fi

    # 只有"重新下载"这条路才需要额外校验（本地副本来自用户自己给的文件，
    # 与首次运行的是同一份，不存在两次抓取之间被投毒的问题）
    if [ "$self_is_file" -ne 1 ]; then
        local vr=0
        verify_installer_self "$tmp" || vr=$?
        case "$vr" in
            0)
                echo "安装脚本校验通过（与仓库登记一致）"
                ;;
            1)
                err "重新下载的安装脚本与仓库登记不一致，已中止"
                echo "  这可能是中间人投毒或镜像被换过内容。"
                echo "  更稳妥的做法：先把安装器下载到本地，再执行"
                echo "    curl -sSL $SELF_URL -o /tmp/install.sh && bash /tmp/install.sh"
                rm -f -- "$tmp"
                exit 1
                ;;
            2)
                warn "无法比对重新下载的安装脚本（GitHub API 不可达或缺少 sha1sum）"
                echo "  这份脚本马上就要以 root 运行，却没有任何完整性依据。"
                echo "  建议取消，改为先下载到本地再执行："
                echo "    curl -sSL $SELF_URL -o /tmp/install.sh && bash /tmp/install.sh"
                if [ "${DSH_TRUST_UNVERIFIED:-0}" = "1" ]; then
                    warn "已按 DSH_TRUST_UNVERIFIED=1 继续"
                elif ! confirm "仍要继续？(y/N): "; then
                    warn "已取消"
                    rm -f -- "$tmp"
                    exit 1
                fi
                ;;
        esac
    fi
    chmod +x "$tmp"

    # 选项与环境变量都必须显式传给 root 子进程：
    # sudo 默认 env_reset 会丢掉所有 DSH_* 变量，
    # 且原先只转发了 --yes，导致 --from-file/--skip-verify 静默失效。
    local -a fwd=()
    [ "$ASSUME_YES" -eq 1 ] && fwd+=(--yes)
    [ "$SKIP_VERIFY" -eq 1 ] && fwd+=(--skip-verify)
    [ -n "$FROM_FILE" ] && fwd+=(--from-file "$FROM_FILE")

    local rc=0
    # 用 sudo env 显式带入变量（-E 在多数发行版被 sudoers 禁用，不可靠）
    sudo env \
        DSH_RAW_BASE="$RAW_BASE" \
        DSH_GITHUB_API="$GITHUB_API" \
        DSH_EXTRA_MIRRORS="${DSH_EXTRA_MIRRORS:-}" \
        DSH_INSTALL_DIR="$INSTALL_DIR" \
        DSH_PROFILE_FILE="$PROFILE_FILE" \
        DSH_CONNECT_TIMEOUT="$CURL_CONNECT_TIMEOUT" \
        DSH_MAX_TIME="$CURL_MAX_TIME" \
        bash "$tmp" ${fwd[@]+"${fwd[@]}"} || rc=$?

    # 关键：无论提权成功与否都必须结束当前（非 root）进程，
    # 否则会以无权限身份继续执行后面的安装步骤。
    exit "$rc"
}

# ---------- 依赖 ----------
check_deps() {
    PKG_INSTALL_CMD="$(detect_pkg_install_cmd)"
    # 离线安装只用 cp，根本不需要 curl —— 以前无条件强制 curl，
    # 把最需要离线安装的内网机器（无 curl、无外网）卡死在第一步
    [ -n "$FROM_FILE" ] && return 0

    if ! command -v sha256sum >/dev/null 2>&1; then
        err "缺少 sha256sum，无法校验下载内容（coreutils/busybox 通常自带）"
        echo "  装上它，或明确承担风险：bash $SELF_NAME --skip-verify"
        exit 1
    fi

    if ! command -v curl >/dev/null 2>&1; then
        warn "未找到 curl，尝试安装..."
        local installed=0
        # 统一用 if 包裹：裸命令在 set -e 下失败会静默终止脚本
        if command -v apt-get >/dev/null 2>&1; then
            if apt-get update -qq && apt-get install -y curl; then installed=1; fi
        elif command -v dnf >/dev/null 2>&1; then
            if dnf install -y curl; then installed=1; fi
        elif command -v yum >/dev/null 2>&1; then
            if yum install -y curl; then installed=1; fi
        elif command -v apk >/dev/null 2>&1; then
            if apk add --no-cache curl; then installed=1; fi
        elif command -v zypper >/dev/null 2>&1; then
            if zypper --non-interactive install curl; then installed=1; fi
        elif command -v pacman >/dev/null 2>&1; then
            if pacman -Sy --noconfirm curl; then installed=1; fi
        else
            err "未找到可用的包管理器，请手动安装 curl 后重试"
            exit 1
        fi

        if [ "$installed" -ne 1 ] || ! command -v curl >/dev/null 2>&1; then
            err "自动安装 curl 失败，请手动安装后重试"
            exit 1
        fi
        info "curl 安装完成"
    fi

    # rsync / zstd 是可选的，缺了也能装，只提示不强制安装。
    # 注意：管理脚本解析 package.json 用的是 node（DSH 的硬依赖），
    # 早已不依赖 jq / python3，这里不再提它们。
    local missing=""
    local t
    for t in rsync zstd; do
        command -v "$t" >/dev/null 2>&1 || missing="$missing $t"
    done
    if [ -n "$missing" ]; then
        missing="${missing# }"
        warn "可选依赖未安装：$missing"
        echo "  缺失影响："
        echo "    rsync    备份/恢复用更稳的复制方式（缺了会退回 tar 管道）"
        echo "    zstd     会话文件完整性校验（缺了会跳过深度校验）"
        echo "  安装示例：$PKG_INSTALL_CMD $missing"
    fi

    # 被装出来的 dsh.sh 硬依赖 systemd，在没有 systemd 的系统上
    # 会"装成功然后完全不可用"，这里提前说清楚
    if ! command -v systemctl >/dev/null 2>&1; then
        warn "本机没有 systemctl：管理脚本只支持 systemd，装好后大部分功能不可用"
    fi
}

# 按检测到的包管理器生成安装示例（以前固定写 apt，非 Debian 上照抄即失败）
detect_pkg_install_cmd() {
    if command -v apt-get >/dev/null 2>&1; then echo "apt-get install -y"
    elif command -v dnf >/dev/null 2>&1;  then echo "dnf install -y"
    elif command -v yum >/dev/null 2>&1;  then echo "yum install -y"
    elif command -v zypper >/dev/null 2>&1; then echo "zypper install -y"
    elif command -v pacman >/dev/null 2>&1; then echo "pacman -S --noconfirm"
    elif command -v apk >/dev/null 2>&1;  then echo "apk add --no-cache"
    else echo "（请用你的包管理器安装）"; fi
}

# ---------- 下载主脚本 ----------
fetch_payload() {
    local dest="$1"

    if [ -n "$FROM_FILE" ]; then
        if [ ! -f "$FROM_FILE" ]; then
            err "指定的本地文件不存在：$FROM_FILE"
            return 1
        fi
        cp -- "$FROM_FILE" "$dest"
        info "已从本地文件读取：$FROM_FILE"
        warn "本地文件不做哈希校验（内容由你自行确认）"
    else
        title "下载 DSH 管理脚本"
        echo "每个源最多等待 ${CURL_MAX_TIME}s（连接 ${CURL_CONNECT_TIMEOUT}s）"
        if [ "$SKIP_VERIFY" -eq 1 ]; then
            warn "已通过 --skip-verify 关闭哈希校验"
        else
            echo "下载后将校验 SHA-256：${PAYLOAD_SHA256:0:16}…"
        fi
        if ! download_file "$PAYLOAD_NAME" "$dest" 1; then
            err "所有下载源均失败，或内容未通过校验"
            echo
            echo "可能原因："
            echo "  · 网络不通，或所有源都被干扰"
            echo "  · 各源仍在 CDN 缓存期内、返回的是旧版本"
            echo "    （刚更新过脚本时常见，等几分钟再试）"
            echo "  · DSH_RAW_BASE 指向了 fork，内容与上游哈希不同"
            echo
            echo "期望哈希：$PAYLOAD_SHA256"
            echo "用自定义镜像重试："
            echo "  DSH_EXTRA_MIRRORS=<镜像前缀> bash install.sh"
            echo "离线安装："
            echo "  bash install.sh --from-file /path/to/dsh.sh"
            if [ "$SKIP_VERIFY" -eq 0 ]; then
                echo "确认内容可信、要跳过校验："
                echo "  bash install.sh --skip-verify"
            fi
            return 1
        fi
        if [ "$SKIP_VERIFY" -eq 0 ]; then
            info "SHA-256 校验通过"
        fi
    fi

    if [ ! -s "$dest" ]; then
        err "文件内容为空"
        return 1
    fi
    if ! head -n 1 "$dest" | grep -q '^#!'; then
        err "内容不是有效的 Shell 脚本（缺少 shebang）"
        return 1
    fi
    if ! bash -n "$dest" 2>/dev/null; then
        err "脚本语法校验未通过，已中止安装"
        return 1
    fi
    info "校验通过，大小 $(wc -c < "$dest" | tr -d ' ') 字节"
}

# 校验"root 要写入的目录"是否安全：绝对路径 + root 属主 + 组/其他不可写。
# 为什么：DSH_INSTALL_DIR / DSH_PROFILE_FILE 来自环境变量并被转发进 root 上下文，
# 不校验的话，把安装目录指到普通用户可写的地方，用户替换掉二进制后，
# 管理员下次 `sudo dsh-manager` 就等于执行了用户的代码。
safe_root_dir() {
    local d="$1" label="$2" mode g o
    case "$d" in
        /*) ;;
        *) err "$label 必须是绝对路径：$d"; return 1 ;;
    esac
    if [ ! -d "$d" ]; then
        err "$label 不存在：$d"
        return 1
    fi
    if [ "$(stat -c %u "$d" 2>/dev/null)" != "0" ]; then
        err "$label 不是 root 属主：$d"
        return 1
    fi
    mode="$(stat -c %a "$d" 2>/dev/null)"
    if [ -n "$mode" ]; then
        # 只看后两位（组 / 其他），忽略 setuid/sticky 前缀
        g="${mode: -2:1}"; o="${mode: -1}"
        case "$g$o" in
            *[2367]*)
                err "$label 允许组或其他用户写入：$d（root 往里写的东西会被替换）"
                return 1
                ;;
        esac
    fi
    return 0
}

# ---------- 临时目录 ----------
# mktemp 的模板直接拼 TMPDIR：相对路径会让临时文件落在当前目录，
# 指向不存在/不可写的目录则直接失败。这里统一收口并给出可读的错误。
tmp_template() {
    local name="$1" dir="${TMPDIR:-/tmp}"
    case "$dir" in
        /*) ;;
        *) warn "TMPDIR 不是绝对路径（$dir），临时文件改用 /tmp" ; dir="/tmp" ;;
    esac
    if [ ! -d "$dir" ] || [ ! -w "$dir" ]; then
        [ -n "${TMPDIR:-}" ] && warn "TMPDIR 不可写（$dir），临时文件改用 /tmp"
        dir="/tmp"
    fi
    printf '%s/%s' "$dir" "$name"
}

# ---------- 安装 ----------
install_payload() {
    local src="$1"
    title "安装"

    if [ ! -d "$INSTALL_DIR" ]; then
        if ! install -d -m 0755 "$INSTALL_DIR" 2>/dev/null; then
            err "无法创建安装目录：$INSTALL_DIR"
            echo "  请检查权限，或用 DSH_INSTALL_DIR 指定其它目录"
            return 1
        fi
    fi
    if ! safe_root_dir "$INSTALL_DIR" "安装目录（DSH_INSTALL_DIR）"; then
        return 1
    fi

    if ! install -m 0755 "$src" "$TARGET_BIN" 2>/dev/null; then
        err "无法写入 $TARGET_BIN"
        echo "  请检查权限（本脚本需以 root 运行）"
        return 1
    fi
    info "主脚本安装到 $TARGET_BIN"

    # /usr/local/bin 通常在 PATH 里；补一个软链兜底（默认 /usr/bin）。
    # 以前无条件 ln -sf：同名文件会被静默顶掉，别人的东西就没了。
    if [ -d "$LINK_DIR" ]; then
        local link="$LINK_DIR/$TARGET_NAME"
        if [ -e "$link" ] || [ -L "$link" ]; then
            if [ -L "$link" ] && [ "$(readlink -f "$link" 2>/dev/null)" = "$TARGET_BIN" ]; then
                : # 已经指向本脚本，无需处理
            else
                local stash="${link}.bak-$(date +%Y%m%d_%H%M%S)"
                if mv -f "$link" "$stash" 2>/dev/null; then
                    warn "已存在 $link（非本脚本软链），先改名为 $stash"
                else
                    warn "已存在 $link 且无法改名，跳过软链创建"
                fi
            fi
        fi
        if [ ! -e "$link" ] && [ ! -L "$link" ]; then
            if ! ln -sf "$TARGET_BIN" "$link" 2>/dev/null; then
                warn "无法创建软链 $link（不影响使用 $TARGET_BIN）"
            fi
        fi
    fi

    # 回读校验：以前收尾的失败被 || true 吞掉，会"看起来装成功"
    if [ ! -x "$TARGET_BIN" ]; then
        err "回读校验失败：$TARGET_BIN 不存在或不可执行"
        return 1
    fi
    if ! command -v "$TARGET_NAME" >/dev/null 2>&1; then
        warn "$TARGET_BIN 不在当前 PATH 中，请直接用完整路径调用"
    fi
}

# ---------- 快捷命令 ----------
# 检查某个 rc 文件里快捷别名是否可用
# 返回 0=未占用  1=已指向本脚本  2=已被别的命令占用（不要覆盖）
alias_state() {
    local rc="$1"
    if grep -qE "^alias[[:space:]]+$ALIAS_NAME=['\"]$TARGET_NAME['\"]" "$rc" 2>/dev/null; then
        return 1
    fi
    if grep -qE "^alias[[:space:]]+$ALIAS_NAME=" "$rc" 2>/dev/null; then
        return 2
    fi
    return 0
}

setup_alias() {
    title "配置快捷命令"

    local pdir
    pdir="$(dirname "$PROFILE_FILE")"

    if [ ! -d "$pdir" ]; then
        warn "目录不存在，跳过系统级快捷命令：$pdir"
    elif ! safe_root_dir "$pdir" "profile 片段目录（DSH_PROFILE_FILE 所在目录）"; then
        warn "该目录不安全，跳过系统级快捷命令"
    elif [ -e "$PROFILE_FILE" ] && ! head -n 1 "$PROFILE_FILE" 2>/dev/null | grep -qF "$PROFILE_MARK"; then
        # 不是本脚本写的文件一律不动：以前是无条件 cat > 覆盖，
        # 把 DSH_PROFILE_FILE 指向 /etc/passwd 这类文件就会被截断成两行 alias
        warn "$PROFILE_FILE 已存在且不是本脚本写的，已跳过（不覆盖）"
        echo "  如需改用本脚本，请先自行备份并删除该文件"
    else
        # 写失败不该让整个安装以失败告终（二进制此时已经装好了）
        if cat > "$PROFILE_FILE" <<EOF
$PROFILE_MARK
alias $ALIAS_NAME='$TARGET_NAME'
EOF
        then
            chmod 0644 "$PROFILE_FILE" 2>/dev/null || true
            info "已写入 $PROFILE_FILE（系统级，登录 shell 生效）"
        else
            warn "写入失败，跳过系统级快捷命令：$PROFILE_FILE"
        fi
    fi

    # 再写到调用者的 ~/.bashrc，覆盖"非登录交互 shell"的情况
    local login_user="${SUDO_USER:-$(id -un)}"

    local home=""
    # getent 不是 busybox applet：缺失时退回直接读 /etc/passwd，
    # 否则在纯 busybox 系统上会静默跳过用户级别名。
    # 末尾的 || true 必不可少：getent 对不存在的用户返回 2，
    # 而本函数是在非条件上下文中调用的，set -e 会因此静默终止整个安装
    if command -v getent >/dev/null 2>&1; then
        home="$(getent passwd "$login_user" 2>/dev/null | cut -d: -f6 || true)"
    fi
    if [ -z "$home" ] && [ -r /etc/passwd ]; then
        home="$(awk -F: -v u="$login_user" '$1==u{print $6; exit}' /etc/passwd 2>/dev/null || true)"
    fi
    if [ -z "$home" ]; then
        warn "无法确定用户 $login_user 的家目录，已跳过用户级快捷命令"
        return 0
    fi
    if [ ! -f "$home/.bashrc" ]; then
        return 0
    fi

    local rc="$home/.bashrc"
    local st=0
    alias_state "$rc" || st=$?

    case "$st" in
        1)
            info "$rc 中已存在快捷命令，跳过"
            return 0
            ;;
        2)
            # 不能默默追加：后定义的别名会盖掉用户原有的，属于静默破坏
            warn "$rc 中 $ALIAS_NAME 已被占用，为避免覆盖已跳过"
            echo "  现有定义：$(grep -E "^alias[[:space:]]+$ALIAS_NAME=" "$rc" | head -n 1)"
            echo "  如需改用本脚本，请先删除该行后重新运行安装器，"
            echo "  或直接用完整命令：$TARGET_NAME"
            return 0
            ;;
    esac

    if {
        echo ""
        echo "$PROFILE_MARK"
        echo "alias $ALIAS_NAME='$TARGET_NAME'"
    } >> "$rc" 2>/dev/null; then
        info "已写入 $rc（用户：$login_user）"
    else
        # 二进制已经装好了，这里失败不该让整个安装报错退出
        warn "写入失败，跳过用户级快捷命令：$rc"
    fi
}

# ---------- 结束信息 ----------
done_info() {
    title "安装完成"

    echo "运行方式："
    echo "  d                  （需先 source ~/.bashrc 或重新登录）"
    echo "  $TARGET_NAME"
    echo "  $TARGET_BIN"
    echo
    echo "首次使用：运行 $TARGET_NAME，然后按 1「快速开始」——"
    echo "它会自动初始化 systemd 服务、启动，并给出访问链接。"
    echo
    echo "更新："
    echo "  bash <(curl -sSL $SELF_URL) -y   # 重跑本安装器即可覆盖升级"
    echo
    echo "卸载（也可用管理面板的「卸载」菜单）："
    echo "  rm -f $TARGET_BIN $LINK_DIR/$TARGET_NAME $PROFILE_FILE"
    echo "  再手动删除 ~/.bashrc 里那行：alias $ALIAS_NAME='$TARGET_NAME'"
}

# ---------- PATH 收紧 ----------
# 提权后不再信任调用者的 PATH：若标准系统目录里能找到全部必需命令，
# 就只保留这些目录，避免用户可写目录里的假 curl/tar 被以 root 身份执行。
harden_path() {
    # 可选参数：要收紧到的目录列表（默认系统标准目录），便于测试
    local hardened="${1:-/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin}"
    local c ok=1
    for c in curl tar sha256sum mktemp install cp mv; do
        PATH="$hardened" command -v "$c" >/dev/null 2>&1 || { ok=0; break; }
    done
    if [ "$ok" -eq 1 ]; then
        PATH="$hardened"
        export PATH
    else
        warn "系统标准目录缺少必要命令，保留当前 PATH"
        warn "请确认其中没有被替换过的程序（可用 command -v curl 检查）"
    fi
}

# ---------- 主流程 ----------
main() {
    parse_args "$@"

    printf "${BLD}DSH 管理脚本安装器${RST}\n"
    echo "安装目录：$INSTALL_DIR"
    echo "快捷命令：$ALIAS_NAME"
    echo

    # 先提权，后续步骤全部以 root 身份执行
    if ! confirm "确认安装？(y/N): "; then
        warn "安装已取消"
        exit 0
    fi

    # 提权与依赖安装放在确认之后：以前 check_deps 会先以 root 装包，
    # 用户回答 n 时系统其实已经被改动过了
    ensure_root

    check_deps

    # 依赖都就位后再收紧 PATH（此时标准目录里一定有 curl/tar）
    harden_path

    if ! PAYLOAD_TMP="$(mktemp "$(tmp_template dsh-payload.XXXXXX)" 2>/dev/null)"; then
        err "无法创建临时文件（检查 TMPDIR 是否可写）：${TMPDIR:-/tmp}"
        exit 1
    fi

    if ! fetch_payload "$PAYLOAD_TMP"; then
        err "安装失败"
        exit 1
    fi

    install_payload "$PAYLOAD_TMP"
    setup_alias
    done_info
}

main "$@"
