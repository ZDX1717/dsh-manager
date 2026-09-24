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
ALIAS_NAME="d"
PROFILE_FILE="${DSH_PROFILE_FILE:-/etc/profile.d/dsh-manager.sh}"

# 下载超时：故意设得较短——有备用源兜底，宁可快速失败切换，
# 也不要在被干扰的源上长时间干等。
CURL_CONNECT_TIMEOUT="${DSH_CONNECT_TIMEOUT:-8}"
CURL_MAX_TIME="${DSH_MAX_TIME:-30}"

# dsh.sh 的 SHA-256。每次改动 dsh.sh 必须同步更新这里。
# 作用：下载源被第三方镜像篡改、或 CDN 返回了旧缓存时，
# 都能立刻发现并拒绝安装，而不是把来路不明的内容装进系统。
PAYLOAD_SHA256="46590e6f3388f9852a7bc319593038938810b54a7c3998eb5fb9ba99ab855987"

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
    curl -fsSL \
        --connect-timeout "$CURL_CONNECT_TIMEOUT" \
        --max-time "$CURL_MAX_TIME" \
        "$GITHUB_API/repos/$owner/$repo/commits/$ref" 2>/dev/null \
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
    [ -n "$PAYLOAD_SHA256" ] || return 0
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
        printf '  尝试 %s\n' "$url"
        if curl -fsSL \
                --connect-timeout "$CURL_CONNECT_TIMEOUT" \
                --max-time "$CURL_MAX_TIME" \
                "$url" -o "$dest" 2>/dev/null && [ -s "$dest" ]; then
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
            --from-file)     shift; FROM_FILE="${1:-}" ;;
            --skip-verify)   SKIP_VERIFY=1 ;;
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
        read -r -p "$prompt" answer < /dev/tty
    else
        warn "当前无可用终端，默认继续（如需中止请按 Ctrl+C）"
        answer="y"
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
    if ! tmp="$(mktemp "${TMPDIR:-/tmp}/dsh-installer.XXXXXX" 2>/dev/null)"; then
        err "无法创建临时文件（检查 TMPDIR 是否可写）：${TMPDIR:-/tmp}"
        exit 1
    fi
    # 立刻登记，保证后面任何分支提前退出时都会被 EXIT trap 清理
    ELEVATED_TMP="$tmp"

    # 以文件方式调用时直接复制自身，省一次下载；
    # 进程替换 / 管道调用时 $0 不是普通文件，改为重新下载。
    if [ -f "$0" ] && cp -- "$0" "$tmp" 2>/dev/null; then
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

    # jq / rsync / zstd 都是可选，缺了也能装，只提示不强制安装
    local missing=""
    local t
    for t in jq rsync zstd; do
        command -v "$t" >/dev/null 2>&1 || missing="$missing $t"
    done
    if [ -n "$missing" ]; then
        missing="${missing# }"
        warn "可选依赖未安装：$missing"
        echo "  缺失影响："
        echo "    jq       删除插件时必须（要同步修改 package.json 的 bundles）"
        echo "             没有 jq 时若有 python3 也能用，两者都缺则无法删插件"
        echo "    rsync    备份/恢复用更稳的复制方式"
        echo "    zstd     会话文件完整性校验"
        echo "  安装示例：apt install -y $missing"
    fi
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

    if ! install -m 0755 "$src" "$TARGET_BIN" 2>/dev/null; then
        err "无法写入 $TARGET_BIN"
        echo "  请检查权限（本脚本需以 root 运行）"
        return 1
    fi
    info "主脚本安装到 $TARGET_BIN"

    # /usr/local/bin 通常在 PATH 里；补一个 /usr/bin 软链兜底
    if [ -d /usr/bin ]; then
        ln -sf "$TARGET_BIN" "/usr/bin/$TARGET_NAME" 2>/dev/null || true
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

    if [ -w "$(dirname "$PROFILE_FILE")" ] || [ ! -e "$PROFILE_FILE" ]; then
        cat > "$PROFILE_FILE" <<EOF
# DSH 管理脚本快捷命令
alias $ALIAS_NAME='$TARGET_NAME'
EOF
        chmod 0644 "$PROFILE_FILE" 2>/dev/null || true
        info "已写入 $PROFILE_FILE（系统级，登录 shell 生效）"
    else
        warn "无法写入 $PROFILE_FILE，跳过"
    fi

    # 再写到调用者的 ~/.bashrc，覆盖"非登录交互 shell"的情况
    local login_user="${SUDO_USER:-$(id -un)}"
    [ "$login_user" = "root" ] && login_user="${SUDO_USER:-root}"

    local home
    # 末尾的 || true 必不可少：getent 对不存在的用户返回 2，
    # 而本函数是在非条件上下文中调用的，set -e 会因此静默终止整个安装
    home="$(getent passwd "$login_user" 2>/dev/null | cut -d: -f6 || true)"
    if [ -z "$home" ] || [ ! -f "$home/.bashrc" ]; then
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

    {
        echo ""
        echo "# DSH 管理脚本快捷命令"
        echo "alias $ALIAS_NAME='$TARGET_NAME'"
    } >> "$rc"
    info "已写入 $rc（用户：$login_user）"
}

# ---------- 结束信息 ----------
done_info() {
    title "安装完成"

    echo "运行方式："
    echo "  d                  （需先 source ~/.bashrc 或重新登录）"
    echo "  $TARGET_NAME"
    echo "  $TARGET_BIN"
    echo
    echo "首次使用建议先执行菜单里的「初次初始化 Systemd 服务」。"
    echo
    echo "更新："
    echo "  bash <(curl -sSL $SELF_URL) -y   # 重跑本安装器即可覆盖升级"
    echo
    echo "卸载："
    echo "  sudo rm -f $TARGET_BIN /usr/bin/$TARGET_NAME $PROFILE_FILE"
    echo "  sed -i \"/alias $ALIAS_NAME='$TARGET_NAME'/d\" ~/.bashrc"
}

# ---------- 主流程 ----------
main() {
    parse_args "$@"

    printf "${BLD}DSH 管理脚本安装器${RST}\n"
    echo "安装目录：$INSTALL_DIR"
    echo "快捷命令：$ALIAS_NAME"
    echo

    # 先提权，后续步骤全部以 root 身份执行
    ensure_root

    check_deps

    if ! confirm "确认安装？(y/N): "; then
        warn "安装已取消"
        exit 0
    fi

    if ! PAYLOAD_TMP="$(mktemp "${TMPDIR:-/tmp}/dsh-payload.XXXXXX" 2>/dev/null)"; then
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
