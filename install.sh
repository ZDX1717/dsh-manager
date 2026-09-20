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

INSTALL_DIR="${DSH_INSTALL_DIR:-/usr/local/bin}"
TARGET_NAME="dsh-manager"
TARGET_BIN="$INSTALL_DIR/$TARGET_NAME"
ALIAS_NAME="d"
PROFILE_FILE="${DSH_PROFILE_FILE:-/etc/profile.d/dsh-manager.sh}"

ASSUME_YES=0
FROM_FILE=""
ELEVATED_TMP=""
PAYLOAD_TMP=""

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
  -h, --help             显示本帮助

环境变量：
  DSH_RAW_BASE           自定义下载源前缀
  DSH_INSTALL_DIR        安装目录（默认 /usr/local/bin）
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
            -y|--yes)     ASSUME_YES=1 ;;
            --from-file)  shift; FROM_FILE="${1:-}" ;;
            -h|--help)    usage; exit 0 ;;
            *)            warn "忽略未知参数：$1" ;;
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
    tmp="$(mktemp "${TMPDIR:-/tmp}/dsh-installer.XXXXXX")"
    # 立刻登记，保证后面任何分支提前退出时都会被 EXIT trap 清理
    ELEVATED_TMP="$tmp"

    # 以文件方式调用时直接复制自身，省一次下载；
    # 进程替换 / 管道调用时 $0 不是普通文件，改为重新下载。
    if [ -f "$0" ] && cp -- "$0" "$tmp" 2>/dev/null; then
        :
    elif ! curl -fsSL --retry 3 --retry-delay 1 "$SELF_URL" -o "$tmp"; then
        err "重新下载安装脚本失败：$SELF_URL"
        exit 1
    fi

    if [ ! -s "$tmp" ]; then
        err "取到的安装脚本为空"
        exit 1
    fi
    chmod +x "$tmp"

    local rc=0
    if [ "$ASSUME_YES" -eq 1 ]; then
        sudo bash "$tmp" --yes || rc=$?
    else
        sudo bash "$tmp" || rc=$?
    fi

    # 关键：无论提权成功与否都必须结束当前（非 root）进程，
    # 否则会以无权限身份继续执行后面的安装步骤。
    exit "$rc"
}

# ---------- 依赖 ----------
check_deps() {
    if ! command -v curl >/dev/null 2>&1; then
        warn "未找到 curl，尝试安装..."
        if command -v apt-get >/dev/null 2>&1; then
            apt-get update -qq && apt-get install -y curl
        elif command -v dnf >/dev/null 2>&1; then
            dnf install -y curl
        elif command -v yum >/dev/null 2>&1; then
            yum install -y curl
        elif command -v apk >/dev/null 2>&1; then
            apk add --no-cache curl
        else
            err "无法自动安装 curl，请手动安装后重试"
            exit 1
        fi
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
        echo "  jq=插件配置管理  rsync=更稳的备份/恢复  zstd=会话文件校验"
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
    else
        title "下载 DSH 管理脚本"
        echo "来源：$PAYLOAD_URL"
        if ! curl -fsSL --retry 3 --retry-delay 1 "$PAYLOAD_URL" -o "$dest"; then
            err "下载失败，请检查网络后重试"
            return 1
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
        install -d -m 0755 "$INSTALL_DIR"
    fi
    install -m 0755 "$src" "$TARGET_BIN"
    info "主脚本安装到 $TARGET_BIN"

    # /usr/local/bin 通常在 PATH 里；补一个 /usr/bin 软链兜底
    if [ -d /usr/bin ]; then
        ln -sf "$TARGET_BIN" "/usr/bin/$TARGET_NAME" 2>/dev/null || true
    fi
}

# ---------- 快捷命令 ----------
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
    home="$(getent passwd "$login_user" 2>/dev/null | cut -d: -f6)"
    if [ -z "$home" ] || [ ! -f "$home/.bashrc" ]; then
        return 0
    fi

    local rc="$home/.bashrc"
    if grep -q "^alias $ALIAS_NAME='$TARGET_NAME'" "$rc" 2>/dev/null; then
        info "$rc 中已存在快捷命令，跳过"
        return 0
    fi

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

    PAYLOAD_TMP="$(mktemp "${TMPDIR:-/tmp}/dsh-payload.XXXXXX")"

    if ! fetch_payload "$PAYLOAD_TMP"; then
        err "安装失败"
        exit 1
    fi

    install_payload "$PAYLOAD_TMP"
    setup_alias
    done_info
}

main "$@"
