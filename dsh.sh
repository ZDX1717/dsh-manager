#!/bin/bash
# DSH‑WEB 管理脚本｜Bash强制版
# 仅支持 bash，不兼容 dash/sh
# 功能：初始化systemd、启动、停止、重启、状态、获取token链接、修改服务名、更新dsh、卸载、日志查看、插件管理

# ========== 脚本自检：禁止 dash/sh 运行 ==========
# 判断"当前解释器是不是 bash"，而不是看 $SHELL。
# $SHELL 是登录 shell 环境变量（可能继承自 zsh/fish），
# 与"本脚本由哪个解释器执行"无关，用它判断会误杀
# 「登录 shell 是 zsh、但确实用 bash 运行本脚本」的用户。
if [ -z "${BASH_VERSION:-}" ]; then
    echo "❌ 本脚本必须使用 bash 运行，不要用 sh/dash"
    echo "执行方式：bash $0"
    exit 1
fi

# ========== 配置区 ==========
SVC="dsh-web"
DSH_BIN="$HOME/.local/bin/dsh"
DSH_PORT="3080"

# 本脚本自身版本与更新源（菜单 00 使用）
SCRIPT_VERSION="1.15.0"
TARGET_NAME="dsh-manager"
# 安装器写入的系统级快捷命令片段（卸载时会清理）
PROFILE_FILE="${DSH_PROFILE_FILE:-/etc/profile.d/dsh-manager.sh}"
SCRIPT_RAW_URL="${DSH_SCRIPT_URL:-https://raw.githubusercontent.com/ZDX1717/dsh-manager/main/dsh.sh}"
# GitHub API 基地址（解析 commit SHA 用）。
# 网络屏蔽 api.github.com 时可指向自建镜像：
#   DSH_GITHUB_API=https://your.mirror/proxy/api.github.com
# 伪造的 SHA 只会让 jsDelivr@<sha> 返回 404，属失败安全。
GITHUB_API="${DSH_GITHUB_API:-https://api.github.com}"
# 自建镜像（国内可直连），排在内置源末尾
MIRROR_RAW="https://github.zdx1717.ccwu.cc/raw/ZDX1717/dsh-manager/main"
# 下载超时：故意设得较短——有备用源兜底，宁可快速失败切换
SCRIPT_CONNECT_TIMEOUT="${DSH_CONNECT_TIMEOUT:-8}"
SCRIPT_MAX_TIME="${DSH_MAX_TIME:-30}"
# 追加自定义镜像（空格分隔），例如国内加速前缀
SCRIPT_EXTRA_MIRRORS="${DSH_EXTRA_MIRRORS:-}"
# 用 NodeSource 源装 Node.js 时的默认主版本（LTS）
NODE_MAJOR="${DSH_NODE_MAJOR:-24}"

# ========== 终端颜色 ==========
if [ -t 1 ]; then
    RST=$'\033[0m'
    RED=$'\033[31m'
    GRN=$'\033[32m'
    YEL=$'\033[33m'
    BLD=$'\033[1m'
    DIM=$'\033[2m'
else
    RST=""
    RED=""
    GRN=""
    YEL=""
    BLD=""
    DIM=""
fi

# ========== 输出函数 ==========
info()  { printf "${GRN}${BLD}[完成]${RST} %s\n" "$1"; }
warn()  { printf "${YEL}${BLD}[提示]${RST} %s\n" "$1"; }
err()   { printf "${RED}${BLD}[错误]${RST} %s\n" "$1"; }
title() { printf "\n${BLD}==== %s ====${RST}\n" "$1"; }

# ========== systemctl 封装 ==========
sysctl() {
    if [ "$(id -u)" -eq 0 ]; then
        systemctl "$@"
    else
        sudo systemctl "$@"
    fi
}

# ========== journalctl 调用前缀（非 root 走 sudo） ==========
# 用法：JC=$(journal_cmd); $JC -u "$SVC" -n 20   （故意不加引号，靠分词传参）
journal_cmd() {
    if [ "$(id -u)" -eq 0 ]; then
        printf 'journalctl'
    else
        printf 'sudo journalctl'
    fi
}

is_run() {
    sysctl is-active --quiet "$SVC"
    return $?
}

# ========== 获取systemd单元内真实ExecStart路径 ==========
get_systemd_dsh_path() {
    local EXEC
    EXEC=$(systemctl cat "$SVC" 2>/dev/null | grep '^ExecStart=' | sed 's/^ExecStart=//' | awk '{print $1}')
    echo "$EXEC"
}

# ========== 检查DSH是否安装 ==========
check_dsh_installed() {
    # 优先检查配置的路径
    if [ -x "$DSH_BIN" ]; then
        return 0
    fi
    
    # 检查 PATH 中是否有 dsh
    if command -v dsh >/dev/null 2>&1; then
        return 0
    fi
    
    # 检查 systemd 中的路径
    local SYS_BIN
    SYS_BIN=$(get_systemd_dsh_path)
    if [ -n "$SYS_BIN" ] && [ -x "$SYS_BIN" ]; then
        return 0
    fi
    
    return 1
}

# ========== 获取dsh版本 ==========
get_dsh_version() {
    # 优先检查配置的路径
    if [ -x "$DSH_BIN" ]; then
        "$DSH_BIN" --version 2>/dev/null | head -n1
        return
    fi
    
    # 然后检查 PATH
    if command -v dsh >/dev/null 2>&1; then
        dsh --version 2>/dev/null | head -n1
        return
    fi
    
    # 最后检查 systemd
    local SYS_BIN
    SYS_BIN=$(get_systemd_dsh_path)
    if [ -n "$SYS_BIN" ] && [ -x "$SYS_BIN" ]; then
        "$SYS_BIN" --version 2>/dev/null | head -n1
        return
    fi
    
    echo "未找到 DSH"
}

# ========== 安装引导 ==========
install_guide() {
    title "DSH 未安装"
    echo "DSH 程序本体尚未安装。最省事的做法："
    echo
    echo "  回主菜单按 1「快速开始」，会自动完成："
    echo "    Node.js/npm → DSH 本体 → systemd 服务 → 启动 → 给出访问链接"
    echo
    echo "  也可以手动执行：npm install -g @deepseek-ai/dsh"
}

# ========== 预检查 ==========
pre_check() {
    if ! check_dsh_installed; then
        install_guide
        return 1
    fi
    return 0
}

# ========== 以 root 权限执行命令 ==========
# 不看"是不是 root"，而是"当前能不能直接干"：非 root 一律走 sudo。
as_root() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    else
        sudo "$@"
    fi
}

# ========== 探测系统包管理器 ==========
detect_pkg_mgr() {
    local m
    for m in apt-get dnf yum zypper pacman apk; do
        if command -v "$m" >/dev/null 2>&1; then
            printf '%s\n' "$m"
            return 0
        fi
    done
    return 1
}

# ========== 下载到文件（curl 优先，wget 兜底） ==========
fetch_to_file() {
    local url="$1" out="$2"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --connect-timeout "$SCRIPT_CONNECT_TIMEOUT" \
            --max-time 60 "$url" -o "$out"
    elif command -v wget >/dev/null 2>&1; then
        wget -q -T 60 -O "$out" "$url"
    else
        return 127
    fi
}

# ========== 用发行版自带仓库安装 nodejs / npm ==========
install_node_via_distro() {
    local pkg="$1"
    echo
    case "$pkg" in
        apt-get)
            echo "正在更新软件包索引..."
            as_root apt-get update
            echo "正在安装 nodejs / npm..."
            # 少数发行版把 npm 拆成独立包且未必存在，失败则退化为只装 nodejs
            if as_root apt-get install -y nodejs npm; then
                return 0
            fi
            warn "nodejs npm 一并安装失败，尝试只安装 nodejs"
            as_root apt-get install -y nodejs
            ;;
        dnf)
            echo "正在安装 nodejs / npm..."
            as_root dnf install -y nodejs npm
            ;;
        yum)
            echo "正在安装 nodejs / npm..."
            as_root yum install -y nodejs npm
            ;;
        zypper)
            echo "正在安装 nodejs / npm..."
            as_root zypper --non-interactive install nodejs npm
            ;;
        pacman)
            echo "正在安装 nodejs / npm..."
            as_root pacman -Sy --noconfirm nodejs npm
            ;;
        apk)
            echo "正在安装 nodejs / npm..."
            as_root apk add --no-cache nodejs npm
            ;;
        *)
            err "不支持的包管理器：$pkg"
            return 1
            ;;
    esac
}

# ========== 用 NodeSource 官方源安装较新版 Node.js ==========
# 发行版仓库里的 Node 常年偏旧（DSH 对 Node 版本有要求），
# 所以默认推荐 NodeSource；只支持 Debian/Ubuntu 与 RHEL/Fedora 系，
# 其他发行版自动回退到自带仓库。
install_node_via_nodesource() {
    local pkg="$1"
    local major=""
    read -r -p "Node.js 主版本号 [默认 ${NODE_MAJOR}]： " major || major=""
    [ -z "$major" ] && major="$NODE_MAJOR"
    case "$major" in
        ''|*[!0-9]*)
            err "版本号必须是纯数字，例如 22 / 24"
            return 1
            ;;
    esac

    local base=""
    case "$pkg" in
        apt-get)
            base="https://deb.nodesource.com/setup_${major}.x"
            ;;
        dnf|yum)
            base="https://rpm.nodesource.com/setup_${major}.x"
            ;;
        *)
            warn "NodeSource 仅支持 Debian/Ubuntu 与 RHEL/Fedora 系，改用发行版仓库"
            install_node_via_distro "$pkg"
            return $?
            ;;
    esac

    # 先下载再执行，不用 curl | bash：这样下载失败/内容被替换时能自己判断
    local tmp="/tmp/nodesource_setup_${major}.x.sh"
    echo
    echo "正在下载 NodeSource 源配置脚本：$base"
    if ! fetch_to_file "$base" "$tmp"; then
        rm -f "$tmp" 2>/dev/null
        warn "下载失败（网络不通或被拦截），回退到发行版自带仓库"
        install_node_via_distro "$pkg"
        return $?
    fi
    if ! grep -q 'nodesource' "$tmp" 2>/dev/null; then
        rm -f "$tmp" 2>/dev/null
        err "下载内容不像 NodeSource 脚本（可能被劫持或返回了错误页），已放弃"
        echo "如需继续，可改用发行版仓库安装（主菜单 9 → 3，安装方式选 2）。"
        return 1
    fi

    echo "正在配置 NodeSource 源..."
    if ! as_root bash "$tmp"; then
        rm -f "$tmp" 2>/dev/null
        warn "NodeSource 源配置失败，回退到发行版自带仓库"
        install_node_via_distro "$pkg"
        return $?
    fi
    rm -f "$tmp" 2>/dev/null

    echo "正在安装 nodejs..."
    case "$pkg" in
        apt-get) as_root apt-get install -y nodejs ;;
        dnf)     as_root dnf install -y nodejs ;;
        yum)     as_root yum install -y nodejs ;;
    esac
}

# ========== 安装 Node.js 与 npm（菜单 9 → 3） ==========
install_nodejs_npm() {
    title "安装 Node.js 与 npm"

    # ---------- 权限 ----------
    if [ "$(id -u)" -ne 0 ] && ! command -v sudo >/dev/null 2>&1; then
        err "需要 root 权限，但系统未安装 sudo"
        echo "请用 root 登录后重新运行本脚本。"
        return 1
    fi

    # ---------- 包管理器 ----------
    local PKG=""
    PKG=$(detect_pkg_mgr) || {
        err "未识别到包管理器（apt-get/dnf/yum/zypper/pacman/apk）"
        echo "请参考 https://nodejs.org/zh-cn/download 手动安装 Node.js 后重试。"
        return 1
    }

    # ---------- 当前状态 ----------
    local cur_node="" cur_npm=""
    command -v node >/dev/null 2>&1 && cur_node=$(node --version 2>/dev/null)
    command -v npm  >/dev/null 2>&1 && cur_npm=$(npm --version 2>/dev/null)
    if [ -n "$cur_node" ] || [ -n "$cur_npm" ]; then
        echo "当前 Node.js：${cur_node:-未安装}    npm：${cur_npm:-未安装}"
    else
        echo "当前状态：未安装 Node.js / npm"
    fi
    echo "包管理器：$PKG"
    echo
    echo "选择安装方式："
    echo "  1. NodeSource 官方源（推荐，版本新）"
    echo "  2. 发行版自带仓库（快，可能旧）"
    echo "  0. 返回"
    echo
    local choice
    read -r -p "请选择： " choice || { echo; return 0; }

    case "$choice" in
        1) install_node_via_nodesource "$PKG" ;;
        2) install_node_via_distro "$PKG" ;;
        0) return 0 ;;
        *) warn "无效选项"; return 0 ;;
    esac

    # ---------- 统一以"node/npm 是否可用"作为最终判据 ----------
    # 各安装方式的失败信息参差不齐，只看结果最可靠。
    hash -r 2>/dev/null || true
    echo
    local new_node="" new_npm=""
    command -v node >/dev/null 2>&1 && new_node=$(node --version 2>/dev/null)
    command -v npm  >/dev/null 2>&1 && new_npm=$(npm --version 2>/dev/null)

    if [ -n "$new_node" ] && [ -n "$new_npm" ]; then
        info "Node.js 与 npm 安装完成"
        echo "Node.js：$new_node"
        echo "npm    ：$new_npm"
        echo
        echo "下一步：回主菜单按 1「快速开始」继续安装 DSH。"
        return 0
    fi

    err "安装流程已结束，但 Node.js / npm 仍不可用"
    echo "  node：${new_node:-未找到}"
    echo "  npm ：${new_npm:-未找到}"
    echo
    echo "可尝试手动安装："
    echo "  Debian/Ubuntu："
    echo "    curl -fsSL https://deb.nodesource.com/setup_${NODE_MAJOR}.x | sudo -E bash -"
    echo "    sudo apt-get install -y nodejs"
    echo "  Fedora/RHEL："
    echo "    curl -fsSL https://rpm.nodesource.com/setup_${NODE_MAJOR}.x | sudo bash -"
    echo "    sudo dnf install -y nodejs"
    echo "  Arch：sudo pacman -S nodejs npm"
    echo "若 node 已在别处安装，请确认其 bin 目录在 PATH 中。"
    return 1
}

# ========== 安装 / 更新 DSH 程序本体（npm） ==========
# npm install -g 同时覆盖"全新安装"和"升级到最新"两种情况，
# 因此安装与更新合并为同一个入口，无需两个菜单项。
#
# 参数：--yes 表示调用方（如「快速开始」）已经列出改动清单并取得用户同意，
# 此时不再二次确认。默认无论如何都要确认——绝不静默改动用户的系统。
install_or_update_dsh() {
    local ASSUME_YES=0
    [ "${1:-}" = "--yes" ] && ASSUME_YES=1

    title "安装 / 更新 DSH 程序本体"
    
    # ---------- 前置依赖：npm 与 node ----------
    if ! command -v npm >/dev/null 2>&1 || ! command -v node >/dev/null 2>&1; then
        err "未找到 Node.js / npm（DSH 通过 npm 全局安装）"
        echo "DSH 依赖 Node.js 运行环境，npm 随 Node.js 一起安装。"
        echo
        read -r -p "是否现在自动安装 Node.js 与 npm？(y/N): " CONFIRM || CONFIRM=""
        if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
            install_nodejs_npm
            hash -r 2>/dev/null || true
            echo
            if ! command -v npm >/dev/null 2>&1 || ! command -v node >/dev/null 2>&1; then
                err "Node.js 环境仍不可用，无法继续安装 DSH"
                return 1
            fi
        else
            echo "可手动安装后再回来："
            echo "  Debian/Ubuntu：sudo apt install -y nodejs npm"
            echo "  Fedora/RHEL  ：sudo dnf install -y nodejs npm"
            echo "  Arch         ：sudo pacman -S nodejs npm"
            echo
            echo "或用 主菜单 9 → 3「安装 Node.js 与 npm」走 NodeSource 源装较新版本。"
            return 1
        fi
    fi
    echo "Node.js：$(node --version 2>/dev/null)   npm：$(npm --version 2>/dev/null)"
    
    # ---------- 当前安装状态 ----------
    local installed=0
    local current_version=""
    if check_dsh_installed; then
        installed=1
        current_version=$(get_dsh_version)
        echo "当前已安装：$current_version"
    else
        echo "当前状态：未安装 DSH，将执行全新安装"
    fi
    
    # ---------- 查询最新版本 ----------
    echo "正在查询 npm 上的最新版本..."
    local latest_version=""
    latest_version=$(npm view @deepseek-ai/dsh version 2>/dev/null)
    if [ -n "$latest_version" ]; then
        echo "最新版本：$latest_version"
    else
        warn "无法获取版本信息（可能是网络或 npm 源问题）"
    fi
    
    # ---------- 确认 ----------
    # 这里是最容易出事的地方：以前"发现有新版"就直接 npm install，
    # 用户只是点了个入口就被升级了。现在一律先问。
    if [ $installed -eq 1 ] && [ -n "$latest_version" ] && [ "$current_version" = "$latest_version" ]; then
        # 已是最新
        if [ $ASSUME_YES -eq 1 ]; then
            echo
            info "已是最新版本（$current_version），无需改动"
            return 0
        fi
        echo
        warn "当前已是最新版本"
        local CONFIRM
        read -r -p "是否仍要重新安装？(y/N): " CONFIRM || CONFIRM=""
        if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
            warn "操作已取消"
            return 0
        fi
    elif [ $ASSUME_YES -eq 0 ]; then
        # 全新安装 / 升级
        local CONFIRM
        echo
        if [ $installed -eq 1 ] && [ -n "$latest_version" ]; then
            read -r -p "确认升级 DSH ${current_version} → ${latest_version}？(y/N): " CONFIRM || CONFIRM=""
        elif [ $installed -eq 0 ] && [ -n "$latest_version" ]; then
            read -r -p "确认安装 DSH ${latest_version}？(y/N): " CONFIRM || CONFIRM=""
        else
            read -r -p "确认执行 npm 安装 / 更新？(y/N): " CONFIRM || CONFIRM=""
        fi
        if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
            warn "操作已取消"
            return 0
        fi
    fi
    
    # ---------- 执行 ----------
    echo
    if [ $installed -eq 1 ]; then
        echo "正在更新 DSH 程序本体..."
    else
        echo "正在安装 DSH 程序本体..."
    fi
    echo
    
    local ret=0
    # 是否需要 sudo：不看是否为 root，而是看 npm 全局前缀是否可写。
    # 用 nvm/volta 装的 Node，全局前缀在用户家目录下，本来就不该 sudo
    # （sudo 后 PATH 里没有那个 npm，且会装到错误位置）。
    local npm_prefix=""
    local npm_need_sudo=0
    npm_prefix=$(npm prefix -g 2>/dev/null)
    if [ "$(id -u)" -ne 0 ]; then
        if [ -n "$npm_prefix" ] && [ -w "$npm_prefix" ]; then
            npm_need_sudo=0
        else
            npm_need_sudo=1
        fi
    fi
    
    if [ "$npm_need_sudo" -eq 1 ]; then
        echo "（npm 全局前缀 ${npm_prefix:-未知} 当前用户不可写，将使用 sudo）"
        echo
        sudo npm install -g @deepseek-ai/dsh 2>&1 || ret=$?
    else
        npm install -g @deepseek-ai/dsh 2>&1 || ret=$?
    fi
    
    if [ $ret -ne 0 ]; then
        err "npm 安装/更新失败"
        echo "可尝试手动执行："
        if [ "$npm_need_sudo" -eq 1 ]; then
            echo "  sudo npm install -g @deepseek-ai/dsh"
            echo "  依赖冲突时可加 --force："
            echo "  sudo npm install -g @deepseek-ai/dsh --force"
        else
            echo "  npm install -g @deepseek-ai/dsh"
            echo "  依赖冲突时可加 --force："
            echo "  npm install -g @deepseek-ai/dsh --force"
        fi
        return 1
    fi
    
    # npm 刚写入的 bin 可能还在 shell 的哈希缓存里，先清掉再探测
    hash -r 2>/dev/null || true
    
    # ---------- 校验安装结果 ----------
    if ! check_dsh_installed; then
        err "安装命令已返回成功，但仍找不到 dsh 可执行文件"
        if [ -n "$npm_prefix" ]; then
            echo "  npm 全局前缀：$npm_prefix"
            echo "  可执行文件通常在 $npm_prefix/bin，请确认它在 PATH 中："
            echo "    export PATH=\"$npm_prefix/bin:\$PATH\""
            echo "  需要的话写入 shell 配置后重新登录："
            echo "    echo 'export PATH=\"$npm_prefix/bin:\$PATH\"' >> ~/.bashrc"
        fi
        return 1
    fi
    
    local new_version
    new_version=$(get_dsh_version)
    echo
    if [ $installed -eq 1 ]; then
        info "更新完成"
        echo "旧版本：$current_version"
        echo "新版本：$new_version"
    else
        info "安装完成"
        echo "版本：$new_version"
    fi
    
    # ---------- 服务处理 ----------
    local UNIT="/etc/systemd/system/${SVC}.service"
    if [ -f "$UNIT" ]; then
        echo
        echo "正在重启服务..."
        sysctl restart "$SVC"
        sleep 2
        if is_run; then
            info "服务重启成功"
        else
            err "服务重启失败，请查看日志"
        fi
    else
        echo
        if [ $installed -eq 0 ]; then
            echo "提示：服务尚未初始化，可用菜单 1「快速开始」创建。"
        else
            echo "提示：服务尚未初始化，可用菜单 1 创建后再启动。"
        fi
    fi
}

# ========== 获取本脚本的真实路径 ==========
get_self_path() {
    local p="$0"
    if command -v realpath >/dev/null 2>&1; then
        realpath "$p" 2>/dev/null && return 0
    fi
    if command -v readlink >/dev/null 2>&1; then
        readlink -f "$p" 2>/dev/null && return 0
    fi
    printf '%s\n' "$p"
}

# ========== 更新源列表与下载（带超时与备用源） ==========
# raw.githubusercontent.com 在国内经常被干扰，卡住/超时是常见现象，
# 因此按顺序尝试多个源，任一成功即返回。
# jsDelivr 对 @分支 的缓存可能长达 12 小时（会静默返回旧版本），
# 所以优先用 commit SHA 寻址，保证拿到最新内容。
resolve_commit_sha() {
    local owner="$1" repo="$2" ref="$3"
    curl -fsSL \
        --connect-timeout "$SCRIPT_CONNECT_TIMEOUT" \
        --max-time "$SCRIPT_MAX_TIME" \
        "$GITHUB_API/repos/$owner/$repo/commits/$ref" 2>/dev/null \
        | sed -n 's/^[[:space:]]*"sha":[[:space:]]*"\([0-9a-f]\{40\}\)".*/\1/p' \
        | head -n 1
}

# 计算文件的 git blob 哈希：sha1("blob <字节数>\0" + 内容)
# 用于和 GitHub API 登记的哈希比对
git_blob_sha() {
    local f="$1" size
    command -v sha1sum >/dev/null 2>&1 || return 1
    size=$(stat -c%s "$f" 2>/dev/null) || return 1
    { printf 'blob %s\0' "$size"; cat -- "$f"; } | sha1sum | cut -d' ' -f1
}

# 校验下载内容与仓库登记是否一致。
# 本脚本无法内置自身哈希（自引用矛盾），故改用 API 这个独立通道比对，
# 可发现镜像篡改或 CDN 旧缓存。
# 返回 0=一致  1=不一致  2=无法校验（API 不可达，不阻断更新）
verify_via_api() {
    local file="$1" owner="$2" repo="$3" path="$4" ref="$5"
    local api_sha local_sha
    api_sha="$(curl -fsSL \
        --connect-timeout "$SCRIPT_CONNECT_TIMEOUT" \
        --max-time "$SCRIPT_MAX_TIME" \
        "https://api.github.com/repos/$owner/$repo/contents/$path?ref=$ref" 2>/dev/null \
        | sed -n 's/^[[:space:]]*"sha":[[:space:]]*"\([0-9a-f]\{40\}\)".*/\1/p' \
        | head -n 1)"
    [ -n "$api_sha" ] || return 2
    local_sha="$(git_blob_sha "$file")"
    [ -n "$local_sha" ] || return 2
    [ "$api_sha" = "$local_sha" ]
}

script_update_urls() {
    # 主源：raw（5 分钟缓存，最权威）
    printf '%s\n' "$SCRIPT_RAW_URL"
    
    # 由 raw 地址推导 jsDelivr 等价地址
    case "$SCRIPT_RAW_URL" in
        *raw.githubusercontent.com/*/*/*/*)
            local rest="${SCRIPT_RAW_URL#*raw.githubusercontent.com/}"
            local owner="${rest%%/*}"; rest="${rest#*/}"
            local repo="${rest%%/*}";  rest="${rest#*/}"
            local ref="${rest%%/*}";   local file="${rest#*/}"

            # GitHub Pages：另一个 CDN，与 raw 同时故障概率更低
            printf '%s\n' "https://$owner.github.io/$repo/$file"

            local sha
            sha="$(resolve_commit_sha "$owner" "$repo" "$ref" || true)"
            if [ -n "$sha" ]; then
                printf '%s\n' "https://cdn.jsdelivr.net/gh/$owner/$repo@$sha/$file"
            fi
            # 兜底：SHA 解析失败时用分支名（可能滞后）
            printf '%s\n' "https://cdn.jsdelivr.net/gh/$owner/$repo@$ref/$file"
            ;;
    esac
    
    # 自建镜像：排在所有内置源之后（前面全不通时才用到）
    case "$SCRIPT_RAW_URL" in
        *ZDX1717/dsh-manager*) printf '%s\n' "$MIRROR_RAW/$(basename "$SCRIPT_RAW_URL")" ;;
    esac

    local m
    for m in $SCRIPT_EXTRA_MIRRORS; do
        printf '%s\n' "${m%/}/$(basename "$SCRIPT_RAW_URL")"
    done
}

download_self_update() {
    local dest="$1" url
    while IFS= read -r url; do
        [ -n "$url" ] || continue
        echo "  尝试：$url"
        if curl -fsSL \
                --connect-timeout "$SCRIPT_CONNECT_TIMEOUT" \
                --max-time "$SCRIPT_MAX_TIME" \
                "$url" -o "$dest" 2>/dev/null && [ -s "$dest" ]; then
            return 0
        fi
        echo "    失败或超时，换下一个源"
    done < <(script_update_urls)
    return 1
}

# ========== 更新管理脚本自身（菜单 00） ==========
update_self() {
    title "更新管理脚本"
    
    local SELF
    SELF=$(get_self_path)
    
    # 通过 bash <(curl ...) 之类方式运行时，$0 不是真实文件，无法原地替换
    if [ ! -f "$SELF" ]; then
        err "无法定位脚本文件（当前以 $0 运行）"
        echo "请先安装后再使用本功能："
        echo "  bash <(curl -sSL https://raw.githubusercontent.com/ZDX1717/dsh-manager/main/install.sh)"
        return 1
    fi
    
    echo "脚本路径：$SELF"
    echo "当前版本：$SCRIPT_VERSION"
    
    # 权限检查：实现是先在本目录建 "$SELF.new.$$" 再 mv 覆盖，
    # 所以真正需要的是"目录可写"，只判断文件本身可写会误判
    # （文件可写但目录不可写时，会在最后一步才失败）。
    if [ ! -w "$(dirname "$SELF")" ]; then
        if [ -w "$SELF" ]; then
            warn "脚本所在目录不可写，将直接覆盖文件内容（非原子操作）"
        else
            err "没有写入权限：$SELF"
            echo "请以 root 身份运行后再更新"
            return 1
        fi
    fi
    
    echo "正在检查最新版本..."
    echo "（每个源最多等待 ${SCRIPT_MAX_TIME}s）"
    local TMP
    TMP=$(mktemp "${TMPDIR:-/tmp}/dsh-manager-update.XXXXXX") || {
        err "无法创建临时文件"
        return 1
    }
    
    if ! download_self_update "$TMP"; then
        err "所有下载源均失败"
        echo "可用 DSH_EXTRA_MIRRORS 指定镜像后重试，例如："
        echo "  DSH_EXTRA_MIRRORS=https://ghproxy.net/https://raw.githubusercontent.com/ZDX1717/dsh-manager/main dsh-manager"
        rm -f "$TMP"
        return 1
    fi
    
    # 校验下载内容，避免用坏文件覆盖掉可用脚本
    if [ ! -s "$TMP" ]; then
        err "下载内容为空，已中止"
        rm -f "$TMP"
        return 1
    fi
    if ! head -n1 "$TMP" | grep -q '^#!'; then
        err "下载内容不是有效的 Shell 脚本，已中止"
        rm -f "$TMP"
        return 1
    fi
    if ! bash -n "$TMP" 2>/dev/null; then
        err "下载脚本语法校验未通过，已中止"
        rm -f "$TMP"
        return 1
    fi
    
    # 与仓库登记内容比对：能发现镜像篡改或 CDN 返回旧缓存
    case "$SCRIPT_RAW_URL" in
        *raw.githubusercontent.com/*/*/*/*)
            local _rest="${SCRIPT_RAW_URL#*raw.githubusercontent.com/}"
            local _owner="${_rest%%/*}"; _rest="${_rest#*/}"
            local _repo="${_rest%%/*}";  _rest="${_rest#*/}"
            local _ref="${_rest%%/*}";   local _file="${_rest#*/}"
            local _vr=0
            verify_via_api "$TMP" "$_owner" "$_repo" "$_file" "$_ref" || _vr=$?
            case "$_vr" in
                0) info "内容校验通过（与仓库登记一致）" ;;
                1) err "下载内容与仓库登记不一致，可能是镜像篡改或旧缓存，已中止"
                   echo "  如确认无误，可稍后重试或手动更新"
                   rm -f "$TMP"
                   return 1 ;;
                2) warn "GitHub API 不可达，跳过内容比对（仅做了语法校验）" ;;
            esac
            ;;
    esac
    
    local NEW_VER
    NEW_VER=$(grep -m1 '^SCRIPT_VERSION=' "$TMP" 2>/dev/null | cut -d'"' -f2)
    [ -n "$NEW_VER" ] || NEW_VER="未知"
    echo "最新版本：$NEW_VER"
    
    # 用内容哈希判断是否需要更新（比版本号更可靠）
    local OLD_SUM NEW_SUM
    OLD_SUM=$(sha256sum "$SELF" 2>/dev/null | cut -d' ' -f1)
    NEW_SUM=$(sha256sum "$TMP" 2>/dev/null | cut -d' ' -f1)
    
    if [ -n "$OLD_SUM" ] && [ "$OLD_SUM" = "$NEW_SUM" ]; then
        info "已是最新版本，无需更新"
        rm -f "$TMP"
        return 0
    fi
    
    echo
    if [ "$SCRIPT_VERSION" = "$NEW_VER" ]; then
        warn "版本号相同但内容有变化，仍建议更新"
    fi
    read -r -p "确认更新？(y/N): " CONFIRM
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        warn "操作已取消"
        rm -f "$TMP"
        return 0
    fi
    
    # 备份当前版本
    local BAK="${SELF}.bak"
    if cp -p "$SELF" "$BAK" 2>/dev/null; then
        echo "已备份：$BAK"
    else
        warn "备份失败，继续更新"
    fi
    
    # 先落到同目录的临时文件，再 rename 覆盖，保证原子替换
    # （脚本正在运行，rename 不会打断当前进程）
    # 优先原子替换：先落同目录临时文件，再 rename 覆盖
    # （脚本正在运行，rename 不会打断当前进程）。
    # 目录不可写时回退为直接覆盖内容 —— 非原子，但那是唯一可行方式。
    local STAGED="${SELF}.new.$$"
    local replaced=0
    if install -m 0755 "$TMP" "$STAGED" 2>/dev/null && mv -f "$STAGED" "$SELF" 2>/dev/null; then
        replaced=1
    else
        rm -f "$STAGED" 2>/dev/null
        if cat -- "$TMP" > "$SELF" 2>/dev/null; then
            chmod 0755 "$SELF" 2>/dev/null || true
            replaced=1
        fi
    fi
    rm -f "$TMP"
    
    if [ $replaced -ne 1 ]; then
        err "替换失败，原脚本未受影响"
        return 1
    fi
    
    # 若存在 /usr/bin 下的软链，保持指向不变
    local LINK="/usr/bin/$(basename "$SELF")"
    if [ -L "$LINK" ]; then
        ln -sf "$SELF" "$LINK" 2>/dev/null
    fi
    
    echo
    info "更新完成"
    echo "旧版本：$SCRIPT_VERSION"
    echo "新版本：$NEW_VER"
    echo
    echo "提示：重新运行脚本即可使用新版本"
    echo "  备份文件：$BAK"
}

# ========== 永久把 SVC 写入本脚本文件 ==========
write_svc_to_script() {
    local NEW="$1"
    local SCRIPT_FILE="$0"
    
    # 检查文件是否存在
    if [ ! -f "$SCRIPT_FILE" ]; then
        err "脚本文件不存在: $SCRIPT_FILE"
        return 1
    fi
    
    # 检查是否有写入权限
    if [ ! -w "$SCRIPT_FILE" ]; then
        err "没有写入权限: $SCRIPT_FILE"
        echo "请手动修改脚本顶部的 SVC=\"$NEW\""
        return 1
    fi
    
    # 备份原文件
    local BACKUP_FILE="${SCRIPT_FILE}.backup"
    cp "$SCRIPT_FILE" "$BACKUP_FILE" 2>/dev/null
    
    # 更新配置
    sed -i "s/^SVC=\".*\"/SVC=\"$NEW\"/" "$SCRIPT_FILE"
    if [ $? -eq 0 ]; then
        info "已将新服务名永久写入脚本文件"
        # 删除备份文件
        rm -f "$BACKUP_FILE" 2>/dev/null
    else
        err "写入脚本失败"
        # 恢复备份
        if [ -f "$BACKUP_FILE" ]; then
            cp "$BACKUP_FILE" "$SCRIPT_FILE"
            rm -f "$BACKUP_FILE"
            echo "已恢复原文件"
        fi
        echo "请手动修改脚本顶部的 SVC=\"$NEW\""
        return 1
    fi
}

# ========== 初始化 systemd ==========
init_systemd() {
    title "初始化 Systemd 服务"
    UNIT="/etc/systemd/system/${SVC}.service"

    if [ -f "$UNIT" ]; then
        warn "服务文件已存在，无需重复初始化"
        return 0
    fi

    # 检查 DSH 是否安装
    if ! check_dsh_installed; then
        install_guide
        return 1
    fi
    
    # 确定使用的 DSH 路径
    local USE_DSH_BIN=""
    if [ -x "$DSH_BIN" ]; then
        USE_DSH_BIN="$DSH_BIN"
    elif command -v dsh >/dev/null 2>&1; then
        USE_DSH_BIN=$(command -v dsh)
    else
        err "未找到可执行dsh程序"
        return 1
    fi

    if [ "$(id -u)" -eq 0 ]; then
        cat > "$UNIT" << EOF
[Unit]
Description=DSH Web Service
After=network.target

[Service]
Type=simple
User=$USER
ExecStart=$USE_DSH_BIN web --host 127.0.0.1 --port $DSH_PORT
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    else
        sudo tee "$UNIT" >/dev/null << EOF
[Unit]
Description=DSH Web Service
After=network.target

[Service]
Type=simple
User=$USER
ExecStart=$USE_DSH_BIN web --host 127.0.0.1 --port $DSH_PORT
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    fi

    sysctl daemon-reload
    sysctl enable "$SVC" >/dev/null 2>&1
    info "初始化成功！可直接启动服务"
}

# ========== 启动 ==========
start_svc() {
    title "启动 ${SVC}"
    sysctl start "$SVC"
    sleep 1
    if is_run; then
        info "启动成功，服务运行中"
    else
        err "启动失败"
        sysctl status "$SVC"
    fi
}

# ========== 停止 ==========
stop_svc() {
    title "停止 ${SVC}"
    sysctl stop "$SVC"
    sleep 1
    if is_run; then
        err "停止失败，服务仍在运行"
    else
        info "服务已停止"
    fi
}

# ========== 重启 ==========
restart_svc() {
    title "重启 ${SVC}"
    sysctl restart "$SVC"
    sleep 1
    if is_run; then
        info "重启成功"
    else
        err "重启失败"
        sysctl status "$SVC"
    fi
}

# ========== 获取访问链接 ==========
get_url() {
    if ! is_run; then
        err "服务未运行，无法获取链接"
        return 1
    fi

    title "带 Token 访问链接"

    # 只认「本次运行的主进程」输出的那一行。
    # 否则服务刚重启、新 token 还没打印时，日志里最后一次匹配到的
    # 是上一次运行的旧 token，会拿着一个已失效的链接告诉用户可用。
    local PID=""
    PID=$(sysctl show -p MainPID --value "$SVC" 2>/dev/null | tr -d ' ')

    local JC
    if [ "$(id -u)" -eq 0 ]; then
        JC="journalctl"
    else
        JC="sudo journalctl"
    fi

    # 不硬编码 host:port —— 用户可能改过 systemd 单元里的监听地址
    local PATTERN='https?://[^[:space:]]*token=[0-9A-Za-z_-]+'

    echo "正在从服务日志读取 token（DSH 启动后约需 10~15 秒才打印）..."
    echo

    local LINK=""
    local i=0
    while [ $i -lt 60 ]; do
        if [ -n "$PID" ] && [ "$PID" != "0" ]; then
            LINK=$($JC -u "$SVC" --no-pager _PID="$PID" 2>/dev/null | grep -oE "$PATTERN" | tail -1)
        fi
        [ -n "$LINK" ] && break
        printf "."
        sleep 1
        i=$((i+1))
    done
    printf "\n"

    if [ -n "$LINK" ]; then
        printf "${GRN}${BLD}%s${RST}\n" "$LINK"
        echo
        echo "本次运行的主进程 PID：${PID:-未知}"
        echo "提示：token 每次重启都会变化，请以本条为准。"
        return 0
    fi

    warn "未能从日志中读到本次运行的 token"
    echo
    echo "已等待 ${i} 秒。可能原因："
    echo "  · 服务刚启动，token 尚未打印（再选一次本项即可）"
    echo "  · 当前主进程 PID 为 ${PID:-未知}，日志里没有它的启动输出"
    echo "    （例如服务启动很久、日志已轮转）"
    echo
    echo "可尝试："
    echo "  1) 重启服务后立即选本项：systemctl restart $SVC"
    echo "  2) 直接查看日志确认：journalctl -u $SVC -n 50 --no-pager"
    return 1
}

# ========== 修改服务名 ==========
rename_svc() {
    title "修改 systemd 服务名称"
    
    # 检查服务是否存在
    local OLD_UNIT="/etc/systemd/system/${SVC}.service"
    if [ ! -f "$OLD_UNIT" ]; then
        err "服务文件不存在: $OLD_UNIT"
        echo "请先初始化服务（选项7）"
        return 1
    fi
    
    printf "当前服务名称：${GRN}%s${RST}\n" "$SVC"
    echo "当前服务文件：$OLD_UNIT"
    echo
    echo "请输入新的服务名称："
    echo "提示：建议使用小写字母、数字和连字符，例如：dsh-web, my-dsh-service"
    read -r NEW_NAME

    if [ -z "$NEW_NAME" ]; then
        err "名称不能为空"
        return 1
    fi

    # 验证服务名称格式
    if [[ ! "$NEW_NAME" =~ ^[a-z0-9_-]+$ ]]; then
        err "服务名称格式不正确"
        echo "允许的字符：小写字母、数字、连字符(-)、下划线(_)"
        return 1
    fi

    if [ "$NEW_NAME" = "$SVC" ]; then
        warn "新旧名称一致，无需修改"
        return 0
    fi

    # 检查新名称是否已存在
    local NEW_UNIT="/etc/systemd/system/${NEW_NAME}.service"
    if [ -f "$NEW_UNIT" ]; then
        err "新服务名称已存在: $NEW_UNIT"
        echo "请使用其他名称"
        return 1
    fi

    echo
    echo "即将执行以下操作："
    echo "1. 停止当前服务: $SVC"
    echo "2. 禁用当前服务: $SVC"
    echo "3. 重命名服务文件: $SVC.service → $NEW_NAME.service"
    echo "4. 启用新服务: $NEW_NAME"
    echo "5. 更新脚本配置"
    echo
    read -r -p "确认修改？(y/N): " CONFIRM
    
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        warn "操作已取消"
        return 0
    fi

    echo
    echo "正在停止服务..."
    sysctl stop "$SVC" >/dev/null 2>&1
    echo "正在禁用服务..."
    sysctl disable "$SVC" >/dev/null 2>&1

    echo "正在重命名服务文件..."
    # 必须确认新 unit 写成功再删旧的，否则 cp 失败会同时失去新旧两份
    local _cp_ok=0
    if [ "$(id -u)" -eq 0 ]; then
        cp "$OLD_UNIT" "$NEW_UNIT" 2>/dev/null && _cp_ok=1
        [ $_cp_ok -eq 1 ] && rm -f "$OLD_UNIT" 2>/dev/null
    else
        sudo cp "$OLD_UNIT" "$NEW_UNIT" 2>/dev/null && _cp_ok=1
        [ $_cp_ok -eq 1 ] && sudo rm -f "$OLD_UNIT" 2>/dev/null
    fi
    if [ $_cp_ok -ne 1 ]; then
        err "重命名服务文件失败，原服务文件未改动"
        echo "  源：$OLD_UNIT"
        echo "  目标：$NEW_UNIT"
        return 1
    fi

    echo "正在重新加载 systemd 配置..."
    sysctl daemon-reload
    
    echo "正在启用新服务..."
    sysctl enable "$NEW_NAME" >/dev/null 2>&1

    SVC="$NEW_NAME"
    write_svc_to_script "$NEW_NAME"

    echo
    info "服务名称修改成功！"
    printf "新服务名称：${GRN}%s${RST}\n" "$SVC"
    echo "新服务文件：/etc/systemd/system/${SVC}.service"
    echo
    echo "提示：快捷命令 'd' 仍然有效，无需重新添加"
}

# ========== 卸载systemd服务 ==========
uninstall_svc() {
    title "卸载systemd服务"
    UNIT="/etc/systemd/system/${SVC}.service"
    if [ ! -f "$UNIT" ];then
        warn "服务单元不存在，无需卸载"
        return 0
    fi
    sysctl stop "$SVC" >/dev/null 2>&1
    sysctl disable "$SVC" >/dev/null 2>&1
    if [ "$(id -u)" -eq 0 ];then
        rm -f "$UNIT"
    else
        sudo rm -f "$UNIT"
    fi
    sysctl daemon-reload
    info "✅ systemd服务已卸载，dsh二进制文件保留"
}

# ========== 卸载：DSH 程序本体（npm） ==========
uninstall_dsh() {
    title "卸载 DSH 程序本体"
    
    if ! command -v npm >/dev/null 2>&1; then
        err "未找到 npm，无法通过 npm 卸载"
        echo "若当初是用其它方式装的（如手动放二进制），请自行删除："
        echo "  $DSH_BIN"
        return 1
    fi
    
    if ! check_dsh_installed; then
        warn "未检测到已安装的 DSH，无需卸载"
        return 0
    fi
    
    echo "当前版本：$(get_dsh_version)"
    echo "安装位置：$(command -v dsh 2>/dev/null || echo "$DSH_BIN")"
    echo
    info "说明：卸载程序本体不会删除你的数据"
    echo "  会话与配置仍在：$HOME/.dsh"
    echo "  如需保留，建议先用菜单 8「备份与恢复」导出"
    echo
    
    local CONFIRM
    read -r -p "确认卸载 DSH 程序本体？(y/N): " CONFIRM || CONFIRM=""
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        warn "操作已取消"
        return 0
    fi
    
    # 服务还在跑就先停掉，避免留下仍占用端口的僵尸进程
    if is_run; then
        echo
        echo "检测到服务正在运行，先停止..."
        sysctl stop "$SVC" >/dev/null 2>&1
        sleep 1
        if is_run; then
            warn "服务停止失败，请稍后手动检查：systemctl status $SVC"
        else
            echo "服务已停止"
        fi
    fi
    
    # 与安装一致：按 npm 全局前缀是否可写决定要不要 sudo
    local npm_prefix="" npm_need_sudo=0
    npm_prefix=$(npm prefix -g 2>/dev/null)
    if [ "$(id -u)" -ne 0 ]; then
        if [ -n "$npm_prefix" ] && [ -w "$npm_prefix" ]; then
            npm_need_sudo=0
        else
            npm_need_sudo=1
        fi
    fi
    
    echo
    echo "正在卸载 DSH 程序本体..."
    local ret=0
    if [ "$npm_need_sudo" -eq 1 ]; then
        sudo npm uninstall -g @deepseek-ai/dsh 2>&1 || ret=$?
    else
        npm uninstall -g @deepseek-ai/dsh 2>&1 || ret=$?
    fi
    
    if [ $ret -ne 0 ]; then
        err "npm 卸载失败"
        echo "可手动执行："
        if [ "$npm_need_sudo" -eq 1 ]; then
            echo "  sudo npm uninstall -g @deepseek-ai/dsh"
        else
            echo "  npm uninstall -g @deepseek-ai/dsh"
        fi
        return 1
    fi
    
    hash -r 2>/dev/null || true
    
    # 校验结果：可能还有别的副本（例如手动放的二进制）残留
    if check_dsh_installed; then
        warn "卸载命令已执行，但仍能检测到 dsh"
        echo "  位置：$(command -v dsh 2>/dev/null || echo "$DSH_BIN")"
        echo "  这通常是另一处副本（手动安装 / 别的 Node 环境），请自行确认后删除"
        return 1
    fi
    
    info "DSH 程序本体已卸载"
    echo "数据目录未改动：$HOME/.dsh"
}

# 从某个 rc 文件里摘掉本脚本写入的快捷别名
strip_alias_lines() {
    local rc="$1"
    [ -f "$rc" ] || return 0
    sed -i '/^# DSH 管理脚本快捷命令$/d' "$rc" 2>/dev/null
    sed -i '/^# DSH-Web 管理脚本快捷命令$/d' "$rc" 2>/dev/null
    sed -i "/^alias d='bash .*'$/d" "$rc" 2>/dev/null
    sed -i "/^alias d='$TARGET_NAME'$/d" "$rc" 2>/dev/null
    return 0
}

# ========== 卸载：本管理脚本自身 ==========
uninstall_self() {
    title "卸载本管理脚本"
    
    local SELF
    SELF=$(get_self_path)
    if [ ! -f "$SELF" ]; then
        err "无法定位本脚本文件（当前以 $0 运行）"
        return 1
    fi
    
    echo "将删除以下内容："
    echo "  · 管理脚本本体：$SELF"
    [ -L "/usr/bin/$TARGET_NAME" ] && echo "  · 软链接：/usr/bin/$TARGET_NAME"
    [ -f "$PROFILE_FILE" ] && echo "  · 快捷命令：$PROFILE_FILE"
    echo "  · ~/.bashrc 中的 alias d=..."
    echo
    info "不会删除：DSH 程序本体、$HOME/.dsh 数据"
    echo
    
    local CONFIRM
    read -r -p "确认卸载管理脚本？(y/N): " CONFIRM || CONFIRM=""
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        warn "操作已取消"
        return 0
    fi
    
    local rm_sh
    if [ "$(id -u)" -eq 0 ]; then
        rm_sh="rm -f"
    else
        rm_sh="sudo rm -f"
    fi
    
    # 软链与 profile 片段
    [ -L "/usr/bin/$TARGET_NAME" ] && { $rm_sh "/usr/bin/$TARGET_NAME" 2>/dev/null; echo "已删除 /usr/bin/$TARGET_NAME"; }
    [ -f "$PROFILE_FILE" ] && { $rm_sh "$PROFILE_FILE" 2>/dev/null; echo "已删除 $PROFILE_FILE"; }
    
    # ~/.bashrc 中的别名（含调用者用户，避免只清 root 的）
    local login_user="${SUDO_USER:-$(id -un)}"
    local home
    home="$(getent passwd "$login_user" 2>/dev/null | cut -d: -f6 || true)"
    if [ -n "$home" ] && [ -f "$home/.bashrc" ]; then
        strip_alias_lines "$home/.bashrc"
        echo "已清理 $home/.bashrc 中的快捷别名"
    fi
    [ -f "$HOME/.bashrc" ] && [ "$HOME/.bashrc" != "$home/.bashrc" ] && strip_alias_lines "$HOME/.bashrc"
    
    # 最后删自身。删掉后当前进程仍在内存中运行，属正常。
    if ! $rm_sh "$SELF" 2>/dev/null; then
        err "无法删除 $SELF，请手动执行："
        echo "  $rm_sh $SELF"
        return 1
    fi
    
    echo
    info "管理脚本已卸载"
    echo "当前会话仍在运行，退出后即彻底移除。"
    echo "如已开启 shell 缓存，请执行：hash -r  或重新登录"
    return 0
}

# ========== 卸载管理（子菜单） ==========
uninstall_management() {
    while true; do
        clear 2>/dev/null
        echo "=== 卸载 ==="
        echo
        echo "1. 卸载 systemd 服务（保留程序）"
        echo "2. 卸载 DSH 程序本体（保留数据）"
        echo "3. 完全卸载（服务+程序+脚本）"
        echo "0. 返回"
        echo
        read -r -p "请选择： " choice || { echo; return 0; }
        
        case "$choice" in
            1)
                uninstall_svc
                ;;
            2)
                uninstall_dsh
                ;;
            3)
                echo
                warn "完全卸载将依次执行："
                echo "  1) 停止并删除 systemd 服务"
                echo "  2) 卸载 DSH 程序本体"
                echo "  3) 删除管理脚本及其快捷命令"
                echo
                info "数据目录 $HOME/.dsh 会保留"
                echo
                local CONFIRM
                read -r -p "确认完全卸载？(y/N): " CONFIRM || CONFIRM=""
                if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
                    warn "操作已取消"
                else
                    echo
                    uninstall_svc
                    echo
                    uninstall_dsh
                    echo
                    # 只有删成功才结束进程；失败就留在菜单里，
                    # 否则用户看不到"无法删除"的提示与手动处理办法
                    if uninstall_self; then
                        exit 0
                    fi
                fi
                ;;
            0)
                return 0
                ;;
            *)
                err "无效的选择"
                ;;
        esac
        
        echo
        printf "按回车继续..."
        read -r null || { echo; return 0; }
    done
}

# ========== 实时日志 ==========
show_logs() {
    title "实时日志 (Ctrl+C退出)"
    if [ "$(id -u)" -eq 0 ]; then
        journalctl -u "$SVC" -f
    else
        sudo journalctl -u "$SVC" -f
    fi
}

# ========== 备份功能 ==========
# 备份目录
BACKUP_DIR="$HOME/.dsh/backups"

# 全局动画进程PID
ANIMATION_PID=""

# 清理函数：杀死所有动画子进程
cleanup_animation() {
    if [ -n "$ANIMATION_PID" ] && kill -0 "$ANIMATION_PID" 2>/dev/null; then
        kill "$ANIMATION_PID" 2>/dev/null
        wait "$ANIMATION_PID" 2>/dev/null
        ANIMATION_PID=""
    fi
}

# 初始化备份目录
init_backup_dir() {
    if [ ! -d "$BACKUP_DIR" ]; then
        mkdir -p "$BACKUP_DIR"
        if [ $? -ne 0 ]; then
            err "无法创建备份目录：$BACKUP_DIR"
            return 1
        fi
    fi
    return 0
}

# 验证备份文件完整性
verify_backup() {
    local backup_file="$1"
    if [ ! -f "$backup_file" ]; then
        err "备份文件不存在：$backup_file"
        return 1
    fi
    
    # 检查文件大小
    local file_size=$(stat -c %s "$backup_file" 2>/dev/null)
    if [ "$file_size" -lt 100 ]; then
        err "备份文件过小，可能损坏：$backup_file"
        return 1
    fi
    
    # 尝试列出备份内容
    if ! tar -tzf "$backup_file" >/dev/null 2>&1; then
        err "备份文件损坏，无法读取：$backup_file"
        return 1
    fi
    
    return 0
}

# 生成唯一的备份文件名
generate_backup_filename() {
    local prefix="$1"
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local counter=1
    local filename="${BACKUP_DIR}/${prefix}_${timestamp}.tar.gz"
    
    # 如果文件已存在，添加计数器
    while [ -f "$filename" ]; do
        filename="${BACKUP_DIR}/${prefix}_${timestamp}_${counter}.tar.gz"
        counter=$((counter + 1))
    done
    
    echo "$filename"
}

# ---------- 备份类型：前缀即类型，列表/清理都靠它区分 ----------
# dialogue = 仅对话记录；data = 对话+插件+配置；full = 完整
# sessions 是 1.5.3 以前的旧前缀（当时内容其实等于 data），保留兼容
BACKUP_PREFIXES="dsh_dialogue_backup|dsh_data_backup|dsh_sessions_backup|dsh_full_backup|dsh_plugins_backup"

# 由文件名判断备份类型，给用户看的短标签
backup_kind() {
    case "$(basename "$1")" in
        dsh_dialogue_backup*) echo "仅对话" ;;
        dsh_data_backup*|dsh_sessions_backup*) echo "对话+插件" ;;
        dsh_full_backup*)     echo "完整" ;;
        dsh_plugins_backup*)  echo "插件清单" ;;
        *)                    echo "未知" ;;
    esac
}

# 清单里补丁层的"实际内容"：只剩注释、空行和 [] 的就是 DSH 默认模板，视为空。
# 恢复时若拿模板去覆盖目标机，会把用户自己写的补丁层冲掉，所以必须区分。
manifest_patch_real() {
    sed -n '/^patch_begin$/,/^patch_end$/p' "$1" 2>/dev/null | sed '1d;$d' \
        | grep -v '^[[:space:]]*#' | grep -v '^[[:space:]]*$' | grep -v '^\[\]$'
}

# ---------- 工作区目录补齐 ----------
# DSH 把工作区按【绝对路径】记录在 storages/workspace.json 里。
# 换机器/重装后这些路径通常不存在：DSH 不会删记录，只会把工作区标成
# missing-dir（记录里的会话归属照旧，靠路径字符串比对）。
# 所以建出同名空目录就能让工作区重新可用 —— 对话正文本来就已恢复在 sessions/。
list_missing_workspaces() {
    local ws="$HOME/.dsh/storages/workspace.json"
    [ -f "$ws" ] || return 0
    command -v node >/dev/null 2>&1 || return 0
    node -e '
      const fs = require("fs");
      let d;
      try { d = JSON.parse(fs.readFileSync(process.argv[1], "utf8")); } catch (e) { process.exit(0); }
      const t = (d.tables || {}).workspaces || {};
      const seen = new Set();
      for (const w of Object.values(t)) {
        const p = w && w.path;
        if (!p || seen.has(p)) continue;
        seen.add(p);
        let ok = false;
        try { ok = fs.statSync(p).isDirectory(); } catch (e) { ok = false; }
        if (!ok) console.log(p + "\t" + (w.title || ""));
      }
    ' "$ws" 2>/dev/null
}

recreate_workspace_dirs() {
    local missing
    missing=$(list_missing_workspaces)
    if [ -z "$missing" ]; then
        info "工作区目录都在"
        return 0
    fi

    warn "以下工作区目录在当前机器上不存在："
    local p t
    while IFS=$'\t' read -r p t; do
        [ -n "$p" ] || continue
        printf '  %s\n' "$p"
    done <<< "$missing"
    echo
    echo "DSH 不会删这些工作区的记录，只是把它们标成不可用；"
    echo "对话已经恢复在 sessions/ 里，建出同名目录即可让工作区重新可用。"
    echo "（只是空目录，原来目录里的文件不在备份范围内）"
    echo
    read -r -p "现在创建这些目录？(y/N): " CONFIRM || CONFIRM=""
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        warn "已跳过"
        return 0
    fi

    local n=0
    while IFS=$'\t' read -r p t; do
        [ -n "$p" ] || continue
        if mkdir -p "$p" 2>/dev/null; then
            info "已创建 $p"
            n=$((n + 1))
        else
            err "创建失败（权限不足？）：$p"
        fi
    done <<< "$missing"
    info "共创建 $n 个目录"
}

# ---------- 备份分组 ----------
# 类型顺序：完整(最有价值) -> 仅对话 -> 旧版对话+插件 -> 插件清单
backup_group_name() {
    case "$(basename "$1")" in
        dsh_full_backup*)                      echo "完整备份" ;;
        dsh_dialogue_backup*)                  echo "仅对话记录" ;;
        dsh_data_backup*|dsh_sessions_backup*) echo "对话+插件（旧版）" ;;
        dsh_plugins_backup*)                   echo "插件清单" ;;
        *)                                     echo "其他" ;;
    esac
}

backup_group_order() {
    case "$(basename "$1")" in
        dsh_full_backup*)                      echo 1 ;;
        dsh_dialogue_backup*)                  echo 2 ;;
        dsh_data_backup*|dsh_sessions_backup*) echo 3 ;;
        dsh_plugins_backup*)                   echo 4 ;;
        *)                                     echo 9 ;;
    esac
}

# 先按类型分组、组内仍是时间倒序。
# 用稳定排序保住 list_backups 的时间序，避免"组内又乱掉"。
list_backups_grouped() {
    local f
    for f in $(list_backups); do
        printf '%s|%s\n' "$(backup_group_order "$f")" "$f"
    done | sort -s -t'|' -k1,1n | cut -d'|' -f2-
}

# 菜单 8（数据备份）与菜单 7（插件清单）各看各的：
# 插件清单是 1KB 级元数据，混在大归档里会被"保留最近N个"顺手删掉。
list_backups_data()         { list_backups | grep -v '\.list$'; }
list_backups_data_grouped() { list_backups_grouped | grep -v '\.list$'; }
list_backups_plugins()      { list_backups | grep '\.list$'; }

# 主次分明：类型做分组标题（一级），[序号] 日期 大小 为主信息（二级），
# 文件名缩进并用弱化色（三级）——它是给需要手动搬运的人看的，不该抢戏。
# 插件清单专用行：多显示"里面有几个插件"，选清单时才有依据
print_manifest_row() {
    local idx="$1" file="$2"
    local filename filesize filedate n
    filename=$(basename "$file")
    filesize=$(du -h "$file" 2>/dev/null | cut -f1)
    filedate=$(stat -c %y "$file" 2>/dev/null | cut -d' ' -f1,2 | cut -d: -f1,2)
    n=$(grep -c '^plugin=' "$file" 2>/dev/null)
    printf "${BLD}[%s]${RST} %s  %8s  %s 个插件\n" "$idx" "${filedate:-未知时间}" "${filesize:-?}" "${n:-0}"
    printf "    ${DIM}%s${RST}\n" "$filename"
}

print_backup_row() {
    local idx="$1" file="$2"
    local filename filesize filedate
    filename=$(basename "$file")
    filesize=$(du -h "$file" 2>/dev/null | cut -f1)
    filedate=$(stat -c %y "$file" 2>/dev/null | cut -d' ' -f1,2 | cut -d: -f1,2)
    printf "${BLD}[%s]${RST} %s  %8s\n" "$idx" "${filedate:-未知时间}" "${filesize:-?}"
    printf "    ${DIM}%s${RST}\n" "$filename"
}

# 按类型分组打印（传入数组；序号与数组下标一一对应，删除时不会错位）
print_backup_groups() {
    local files=("$@")
    [ ${#files[@]} -eq 0 ] && return 0

    local -a names=() counts=()
    local f g k found
    for f in "${files[@]}"; do
        g=$(backup_group_name "$f")
        found=-1
        for k in "${!names[@]}"; do
            [ "${names[$k]}" = "$g" ] && { found=$k; break; }
        done
        if [ "$found" -ge 0 ]; then
            counts[$found]=$(( ${counts[$found]} + 1 ))
        else
            names+=("$g"); counts+=("1")
        fi
    done

    local cur="" n
    for k in "${!files[@]}"; do
        g=$(backup_group_name "${files[$k]}")
        if [ "$g" != "$cur" ]; then
            [ -n "$cur" ] && echo
            n=0
            local j
            for j in "${!names[@]}"; do
                [ "${names[$j]}" = "$g" ] && n=${counts[$j]}
            done
            printf "${BLD}── %s（%s 个）──${RST}\n" "$g" "$n"
            cur="$g"
        fi
        print_backup_row "$((k+1))" "${files[$k]}"
    done
}

# 把 ~/.dsh 下指定的顶层条目打包成 tar.gz
# 用法：pack_dsh_backup <输出文件> <条目...>
#   条目可写目录名（sessions）或文件名（settings.yaml），不存在的自动跳过
pack_dsh_backup() {
    local out="$1"; shift
    local temp_dir
    temp_dir=$(mktemp -d) || { err "无法创建临时目录"; return 1; }
    mkdir -p "$temp_dir/.dsh" || { rm -rf "$temp_dir"; err "无法创建临时目录结构"; return 1; }

    local item src dst
    for item in "$@"; do
        src="$HOME/.dsh/$item"
        [ -e "$src" ] || continue
        dst="$temp_dir/.dsh/$item"
        mkdir -p "$(dirname "$dst")"
        if [ -d "$src" ]; then
            if command -v rsync >/dev/null 2>&1; then
                rsync -a --exclude='.cache' "$src/" "$dst/" 2>/dev/null
            else
                mkdir -p "$dst"
                tar -cf - -C "$src" --exclude='.cache' . 2>/dev/null \
                    | tar -xf - -C "$dst" 2>/dev/null
            fi
        else
            cp "$src" "$dst" 2>/dev/null
        fi
    done

    tar -czf "$out" -C "$temp_dir" .dsh 2>/dev/null
    local rc=$?
    rm -rf "$temp_dir"
    return $rc
}

# 备份时的点状进度动画（前台跑，结束由 cleanup_animation 收）
start_backup_animation() {
    echo -n "$1"
    (
        trap '' INT
        while true; do
            echo -n "."
            sleep 1
        done
    ) &
    ANIMATION_PID=$!
}

# ---------- 备份清单的枚举与识别 ----------
# 数据备份是 .tar.gz 目录归档，插件清单是 .list 文本；统一在这里按前缀过滤
# 按修改时间倒序（新的在前）。不能用 sort -r 排文件名：
# 不同前缀的第一个字母不同，排出来"最近一次"会是错的。
list_backups() {
    ls -1t "$BACKUP_DIR"/*.tar.gz "$BACKUP_DIR"/*.list 2>/dev/null \
        | grep -E "($BACKUP_PREFIXES)"
}

# 备份现状摘要，供菜单和备份类型屏复用
# 输出三行：数量体积 / 最近一次（时间 类型）
backup_status_lines() {
    local files=($(list_backups_data))
    if [ ${#files[@]} -eq 0 ]; then
        printf '还没有备份\n—\n'
        return 0
    fi
    local size
    size=$(du -ch "${files[@]}" 2>/dev/null | tail -n1 | cut -f1)
    printf '%s 个备份（共 %s）\n' "${#files[@]}" "${size:-?}"
    local newest="${files[0]}"
    local when
    when=$(stat -c %y "$newest" 2>/dev/null | cut -d' ' -f1,2 | cut -d: -f1,2)
    printf '%s  %s\n' "${when:-未知时间}" "$(backup_kind "$newest")"
}

is_plugin_manifest() {
    case "$1" in
        dsh_plugins_backup*|*.list) return 0 ;;
        *) return 1 ;;
    esac
}

# dsh 可执行文件：优先脚本配置的路径，其次 PATH
dsh_cmd() {
    if [ -x "$DSH_BIN" ]; then
        printf '%s\n' "$DSH_BIN"
    elif command -v dsh >/dev/null 2>&1; then
        command -v dsh
    else
        printf 'dsh\n'
    fi
}

# ---------- pnpm 前置检查 ----------
# `dsh plugin ...` 只是把参数转发给 pnpm。pnpm 不在 PATH 时，一批插件会
# 全部失败，而且 dsh 只回一句 "pnpm not found on PATH"，很容易被误读成
# "插件下架了"。所以动手前先查、先装。
ensure_pnpm() {
    if command -v pnpm >/dev/null 2>&1; then
        return 0
    fi

    err "没有找到 pnpm —— DSH 的 dsh plugin 靠它安装插件"
    echo "DSH 用 pnpm 管理 profile 插件；Node 自带的 npm 默认不含 pnpm。"
    echo

    if ! command -v npm >/dev/null 2>&1 && ! command -v corepack >/dev/null 2>&1; then
        echo "npm 和 corepack 都没有，请先安装 Node.js（见 主菜单 9 → 3）。"
        return 1
    fi

    read -r -p "现在安装 pnpm？(y/N): " CONFIRM || CONFIRM=""
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        echo
        echo "手动安装（任选其一）："
        echo "  corepack enable pnpm"
        echo "  npm install -g pnpm"
        return 1
    fi

    echo
    local ret=1
    if command -v corepack >/dev/null 2>&1; then
        echo "正在用 corepack 启用 pnpm..."
        if corepack enable pnpm 2>&1; then
            ret=0
        fi
    fi
    if [ $ret -ne 0 ] && command -v npm >/dev/null 2>&1; then
        echo "正在用 npm 安装 pnpm..."
        if npm install -g pnpm 2>&1; then
            ret=0
        fi
    fi

    hash -r 2>/dev/null || true
    if [ $ret -eq 0 ] && command -v pnpm >/dev/null 2>&1; then
        info "pnpm 已就绪：$(pnpm --version 2>/dev/null)"
        return 0
    fi
    err "pnpm 安装失败"
    echo "可手动执行：npm install -g pnpm"
    return 1
}

# ---------- 内存与进程诊断 ----------
# spawn ENOMEM 是内核拒绝创建进程，不是"装不下包"。
# 最常见成因：可用内存少 + 没有 swap，而服务进程虚拟大小又很大，
# fork pnpm 时复制页表失败。这里把那几个决定性的数字一次列出来。
kb2h() {
    awk -v k="${1:-0}" 'BEGIN{
        if (k >= 1048576) printf "%.1fG", k / 1048576;
        else if (k >= 1024) printf "%.0fM", k / 1024;
        else printf "%dK", k
    }'
}

mem_diag() {
    title "内存与进程诊断"
    echo "用于判断插件安装报 spawn ENOMEM 的原因"
    echo

    local mem_total mem_avail swap_total swap_free
    mem_total=$(awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null)
    mem_avail=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo 2>/dev/null)
    [ -z "$mem_avail" ] && mem_avail=$(awk '/^MemFree:/{print $2}' /proc/meminfo 2>/dev/null)
    swap_total=$(awk '/^SwapTotal:/{print $2}' /proc/meminfo 2>/dev/null)
    swap_free=$(awk '/^SwapFree:/{print $2}' /proc/meminfo 2>/dev/null)
    mem_total=${mem_total:-0}; mem_avail=${mem_avail:-0}
    swap_total=${swap_total:-0}; swap_free=${swap_free:-0}

    printf '内存     总 %s   可用 %s\n' "$(kb2h "$mem_total")" "$(kb2h "$mem_avail")"
    if [ "$swap_total" -eq 0 ]; then
        printf 'Swap     %s\n' "${RED}没有 swap${RST}"
    else
        printf 'Swap     总 %s   已用 %s\n' "$(kb2h "$swap_total")" "$(kb2h $((swap_total - swap_free)))"
    fi
    printf '映射上限 vm.max_map_count = %s\n' "$(cat /proc/sys/vm/max_map_count 2>/dev/null || echo 未知)"
    printf '内存策略 vm.overcommit_memory = %s\n' "$(cat /proc/sys/vm/overcommit_memory 2>/dev/null || echo 未知)"
    printf '进程上限 ulimit -u = %s\n' "$(ulimit -u 2>/dev/null || echo 未知)"
    echo

    local PID VSZ RSS
    PID=$(sysctl show -p MainPID --value "$SVC" 2>/dev/null | tr -d ' ')
    if [ -n "$PID" ] && [ "$PID" != "0" ] && [ -r "/proc/$PID/status" ]; then
        VSZ=$(awk '/^VmSize:/{print $2}' "/proc/$PID/status" 2>/dev/null)
        RSS=$(awk '/^VmRSS:/{print $2}' "/proc/$PID/status" 2>/dev/null)
        printf '服务进程 PID %s\n' "$PID"
        printf '         常驻内存 %s   虚拟 %s\n' "$(kb2h "${RSS:-0}")" "$(kb2h "${VSZ:-0}")"
    else
        printf '服务进程 未运行或读不到进程信息\n'
    fi

    local oom
    oom=$(dmesg 2>/dev/null | grep -ci 'out of memory\|oom-kill')
    oom=${oom:-0}
    [ "$oom" -gt 0 ] && printf '内核日志 发现 %s 条 OOM 记录\n' "$oom"
    echo

    if [ "$swap_total" -eq 0 ] && [ "$mem_avail" -lt 524288 ]; then
        warn "结论：可用内存偏低且完全没有 swap —— 服务进程内 fork pnpm 极易 ENOMEM"
        echo "      加 swap 后重试："
        echo "        fallocate -l 2G /swapfile && chmod 600 /swapfile"
        echo "        mkswap /swapfile && swapon /swapfile"
    elif [ "$swap_total" -eq 0 ]; then
        warn "结论：完全没有 swap，内存吃紧时没有任何缓冲"
        echo "      建议加 1~2GB swap 兜底："
        echo "        fallocate -l 2G /swapfile && chmod 600 /swapfile"
        echo "        mkswap /swapfile && swapon /swapfile"
    elif [ "$oom" -gt 0 ]; then
        warn "结论：近期出现过 OOM，内存确实不够用"
        echo "      可加 swap 或升配；也可改在终端里装插件（避开服务进程内 fork）"
    else
        info "结论：内存与 swap 看起来够用"
        echo "      若仍报 ENOMEM，多半卡在映射数或进程数上限："
        echo "        sysctl -w vm.max_map_count=262144"
    fi
    echo
    echo "绕开服务进程的办法（在终端里执行）："
    echo "  dsh plugin --profile $(get_current_profile) add <包名>@<版本>"
}

# 生成不覆盖已有文件的备份名：同一秒里连续改两次也不会互相盖掉
backup_file_unique() {
    local src="$1" dst="${1}.bak-$(date +%Y%m%d_%H%M%S)" n=1
    while [ -e "$dst" ]; do
        dst="${1}.bak-$(date +%Y%m%d_%H%M%S)_${n}"
        n=$((n + 1))
    done
    cp "$src" "$dst" 2>/dev/null && printf '%s\n' "$dst"
}

# ---------- profile 的 bundles（DSH 真正加载的包列表） ----------
# profile/package.json 里有两份东西：
#   dependencies  —— pnpm 装了什么（装完不等于会加载）
#   dsh.profile.bundles —— DSH 按这个顺序加载，缺一个包就启动失败
#     （cannot resolve profile bundle）。所以"启用/禁用"应当改 bundles，
#     而不是去重命名 node_modules 目录。
profile_manifest() {
    printf '%s\n' "$HOME/.dsh/profiles/$1/package.json"
}

profile_bundles_has() {
    local pj
    pj=$(profile_manifest "$1")
    [ -f "$pj" ] || return 1
    node -e '
      const fs = require("fs");
      try {
        const d = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
        const b = (((d.dsh || {}).profile || {}).bundles) || [];
        process.exit(b.includes(process.argv[2]) ? 0 : 1);
      } catch (e) { process.exit(1); }
    ' "$pj" "$2" 2>/dev/null
}

# 改 bundles：$1=profile $2=包名 $3=add|remove
profile_bundles_edit() {
    local pj
    pj=$(profile_manifest "$1")
    [ -f "$pj" ] || { err "找不到 $pj"; return 1; }
    backup_file_unique "$pj" >/dev/null
    node -e '
      const fs = require("fs");
      const [file, name, action] = process.argv.slice(1);
      const d = JSON.parse(fs.readFileSync(file, "utf8"));
      d.dsh = d.dsh || {};
      d.dsh.profile = d.dsh.profile || {};
      const b = (d.dsh.profile.bundles = d.dsh.profile.bundles || []);
      if (action === "add") {
        if (!b.includes(name)) b.push(name);
      } else {
        d.dsh.profile.bundles = b.filter((x) => x !== name);
      }
      fs.writeFileSync(file, JSON.stringify(d, null, 2) + "\n");
    ' "$pj" "$2" "$3" 2>/dev/null || { err "写入失败"; return 1; }
    return 0
}

# pnpm 11 留下的待放行条目（未编译的原生模块会让插件加载失败）
pending_build_approvals() {
    local f="$HOME/.dsh/profiles/$1/pnpm-workspace.yaml"
    [ -f "$f" ] || return 0
    grep 'set this to true or false' "$f" 2>/dev/null \
        | sed 's/: *set this to true or false.*//' \
        | sed "s/^[[:space:]]*//; s/^'//; s/'$//" \
        | grep -v '^$' | paste -sd' ' -
}

# ---------- 依赖构建脚本放行 ----------
# pnpm 11 起 strictDepBuilds 默认为真：没放行的依赖不许执行安装脚本，
# 带原生模块的（sharp / node-pty 等）会直接装不上，并把它们写成
#   allowBuilds:
#     sharp: set this to true or false
# 等用户放行。这种失败信息很隐晦，容易误判成"插件下架了"。
PLUGIN_BUILDS_DECISION="${PLUGIN_BUILDS_DECISION:-}"

approve_ignored_builds() {
    local profile="$1"
    local f="$HOME/.dsh/profiles/$profile/pnpm-workspace.yaml"
    if [ ! -f "$f" ]; then
        err "找不到 $f"
        return 1
    fi
    if ! grep -q 'set this to true or false' "$f"; then
        warn "文件里没有待放行的条目"
        echo "可手动执行：cd $(dirname "$f") && pnpm approve-builds"
        return 1
    fi
    backup_file_unique "$f" >/dev/null
    sed -i 's/: *set this to true or false *$/: true/' "$f"
    if grep -q 'set this to true or false' "$f"; then
        err "仍有未放行的条目，请手动执行 pnpm approve-builds"
        return 1
    fi
    info "已放行（原文件另存为 .bak-*）"
    return 0
}

# 装一个插件；若失败原因是构建脚本未放行，问一次是否放行并重试
plugin_add_with_builds() {
    local profile="$1" spec="$2"
    local dshbin out
    dshbin=$(dsh_cmd)

    if out=$("$dshbin" plugin --profile "$profile" add "$spec" 2>&1); then
        return 0
    fi

    local builds_err=0
    printf '%s\n' "$out" | grep -q 'should be allowed to run scripts\|Ignored build scripts' && builds_err=1

    if [ "$builds_err" -eq 0 ]; then
        # 与构建脚本无关的失败：原样展示 dsh 的报错
        printf '%s\n' "$out" | grep -v '^$' | tail -n4 | sed 's/^/      /'
        # 小内存机器上 fork/exec 会直接失败，报错只有一句 spawn ENOMEM，
        # 看上去像"插件坏了"，其实是机器内存不够
        if printf '%s\n' "$out" | grep -qi 'ENOMEM\|Cannot allocate memory'; then
            echo
            warn "进程创建失败（ENOMEM）—— 多半是内存不足，不是插件的问题"
            echo "      先看内存与 swap：free -h"
            echo "      小内存机器加 1~2GB swap 后重试即可，例如："
            echo "        fallocate -l 2G /swapfile && chmod 600 /swapfile"
            echo "        mkswap /swapfile && swapon /swapfile"
        fi
        return 1
    fi

    # 本轮已经问过并拒绝了，就别再刷同样的报错
    if [ "$PLUGIN_BUILDS_DECISION" = "no" ]; then
        return 1
    fi

    if [ "$PLUGIN_BUILDS_DECISION" != "yes" ]; then
        local pkgs
        pkgs=$(printf '%s\n' "$out" | sed -n 's/.*Ignored build scripts: *//p' | head -1 | sed 's/[[:space:]]*$//')
        echo
        warn "pnpm 拦下了构建脚本：${pkgs:-（见上面的输出）}"
        echo "      pnpm 11 默认 strictDepBuilds：没放行的依赖不许执行安装脚本，"
        echo "      带原生模块的（sharp / node-pty 等）就会装不上。"
        echo
        read -r -p "放行这些依赖的构建脚本并重试？(y/N): " CONFIRM || CONFIRM=""
        if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
            PLUGIN_BUILDS_DECISION="yes"
            if ! approve_ignored_builds "$profile"; then
                PLUGIN_BUILDS_DECISION="no"
                return 1
            fi
        else
            PLUGIN_BUILDS_DECISION="no"
            warn "已跳过放行"
            return 1
        fi
    fi

    echo "      重试 $spec ..."
    if out=$("$dshbin" plugin --profile "$profile" add "$spec" 2>&1); then
        return 0
    fi
    printf '%s\n' "$out" | grep -v '^$' | tail -n4 | sed 's/^/      /'
    return 1
}

# 读 profile 的插件与 bundle 清单，输出 "plugin=名字@版本" / "declared=..." / "bundle=..."
# 用 node 解析 JSON —— DSH 本身就依赖 node，等于零额外依赖，
# 比自己用 sed 抠 package.json 稳得多。
plugin_manifest_lines() {
    local pdir="$1"
    node -e '
      const fs = require("fs"), path = require("path");
      const dir = process.argv[1];
      let pkg;
      try { pkg = JSON.parse(fs.readFileSync(path.join(dir, "package.json"), "utf8")); }
      catch (e) { process.exit(2); }
      for (const n of Object.keys(pkg.dependencies || {})) {
        let ver = "?", declared = "";
        try {
          const m = JSON.parse(fs.readFileSync(path.join(dir, "node_modules", n, "package.json"), "utf8"));
          ver = m.version || "?";
          const c = (m.dsh || {}).compatibility;
          if (c && c.dsh) declared = c.dsh;
        } catch (e) { ver = "(未安装)"; }
        console.log("plugin=" + n + "@" + ver);
        if (declared) console.log("declared=" + n + " " + declared);
      }
      for (const b of (((pkg.dsh || {}).profile || {}).bundles || [])) console.log("bundle=" + b);
    ' "$pdir" 2>/dev/null
}

# ========== 插件清单导出（菜单 8 → 第 3 种备份） ==========
# 只记"装了什么、什么版本"，不搬插件代码。原因：
#   · 插件代码是 registry 上可重新下载的派生品，不是不可替代的数据；
#   · 跨 DSH 版本恢复旧插件代码，正是"插件忽然跑不起来"的成因
#     ——插件用 dsh.compatibility / peerDependencies 声明了兼容范围。
# 行式文本而非 JSON：读写都不依赖 jq / python3，人也能直接看、直接抄命令。
backup_plugin_manifest() {
    local out="$1"
    local profile
    profile=$(get_current_profile)
    local pdir="$HOME/.dsh/profiles/$profile"

    if [ ! -f "$pdir/package.json" ]; then
        err "找不到 $pdir/package.json，无法备份插件列表"
        return 1
    fi
    if ! command -v node >/dev/null 2>&1; then
        err "需要 node 才能读取插件列表"
        return 1
    fi

    local lines
    lines=$(plugin_manifest_lines "$pdir")
    if [ -z "$lines" ]; then
        err "没能读出任何插件信息（profile：$profile）"
        return 1
    fi

    {
        echo "# DSH 插件列表备份 —— 由 dsh-manager 生成（不含插件代码）"
        echo "# 恢复：主菜单 7 → 5 → 输入本份备份的编号 → 1"
        echo "# 手动：dsh plugin --profile $profile add <名称>@<版本>"
        echo "manifest=dsh-manager-plugin-manifest v1"
        echo "profile=$profile"
        echo "dsh_version=$(get_dsh_version 2>/dev/null)"
        echo "created=$(date '+%Y-%m-%d %H:%M:%S')"
        echo
        echo "# 已安装插件（名称@精确版本）"
        printf '%s\n' "$lines" | grep '^plugin='
        echo
        echo "# 各插件声明的 DSH 兼容范围（没声明的不列出）"
        printf '%s\n' "$lines" | grep '^declared=' || echo "# (无)"
        echo
        echo "# profile 装载的 bundle 顺序"
        printf '%s\n' "$lines" | grep '^bundle='
        echo
        echo "# 你自己的补丁层 cordis.patch.yml（非空时才需要恢复）"
        echo "patch_begin"
        [ -f "$pdir/cordis.patch.yml" ] && cat "$pdir/cordis.patch.yml"
        echo "patch_end"
    } > "$out" || { err "写入清单失败"; return 1; }

    [ -s "$out" ] || { err "清单为空"; return 1; }
    return 0
}

# ========== 插件清单恢复 ==========
restore_plugin_manifest() {
    local file="$1"

    # 解析：只认我们自己写的键值行，未知行忽略
    local profile
    profile=$(grep -m1 '^profile=' "$file" 2>/dev/null | cut -d= -f2)
    profile="${profile:-$(get_current_profile)}"
    local saved_dsh
    saved_dsh=$(grep -m1 '^dsh_version=' "$file" 2>/dev/null | cut -d= -f2)
    local cur_dsh
    cur_dsh=$(get_dsh_version 2>/dev/null)

    local -a names=() vers=()
    local line entry
    while IFS= read -r line; do
        case "$line" in
            plugin=*)
                entry="${line#plugin=}"
                names+=("${entry%@*}")
                vers+=("${entry##*@}")
                ;;
        esac
    done < "$file"

    if [ ${#names[@]} -eq 0 ]; then
        err "清单里没有插件记录"
        return 1
    fi

    title "按插件清单恢复"
    echo "清单文件：$(basename "$file")"
    echo "目标 profile：$profile"
    echo "清单生成时的 DSH：${saved_dsh:-未知}    当前 DSH：${cur_dsh:-未知}"
    if [ -n "$saved_dsh" ] && [ -n "$cur_dsh" ] && [ "$saved_dsh" != "$cur_dsh" ]; then
        warn "DSH 版本已经变了：按原版本装回的插件未必兼容当前版本"
        echo "      装失败、或装完 DSH 起不来都属正常，请谨慎。"
    fi
    echo
    echo "将要安装："
    local i
    for i in "${!names[@]}"; do
        printf "  %2d. %s@%s\n" "$((i+1))" "${names[$i]}" "${vers[$i]}"
    done
    echo
    echo "声明过兼容范围的插件（仅供参考，不影响安装）："
    grep '^declared=' "$file" 2>/dev/null | sed 's/^declared=/  /' || true
    echo
    echo "安装方式：dsh plugin --profile $profile add <名称>@<版本>"
    echo "需要联网（registry 见 ~/.npmrc）"
    echo

    # 先确认 pnpm 就位，否则下面会一路失败
    if ! ensure_pnpm; then
        warn "没有 pnpm，装不了插件，已中止"
        return 1
    fi
    read -r -p "确认开始安装？(y/N): " CONFIRM || CONFIRM=""
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        warn "操作已取消"
        return 0
    fi

    local okn=0 badn=0
    for i in "${!names[@]}"; do
        echo
        echo "--- [$((i+1))/${#names[@]}] ${names[$i]}@${vers[$i]}"
        if plugin_add_with_builds "$profile" "${names[$i]}@${vers[$i]}"; then
            okn=$((okn + 1))
        else
            badn=$((badn + 1))
            warn "安装失败：${names[$i]}@${vers[$i]}"
        fi
    done

    echo
    info "完成：成功 $okn 个，失败 $badn 个"

    # 恢复用户补丁层：只有"真内容"才问。
    # 全是注释和 [] 的是 DSH 默认模板，拿它覆盖会把目标机上的补丁冲掉。
    local pdir="$HOME/.dsh/profiles/$profile"
    if [ -n "$(manifest_patch_real "$file")" ]; then
        local patch
        patch=$(sed -n '/^patch_begin$/,/^patch_end$/p' "$file" 2>/dev/null | sed '1d;$d')
        echo
        echo "清单里带有你写的 cordis.patch.yml 补丁："
        printf '%s\n' "$patch" | sed 's/^/  /'
        echo
        echo "注意：会覆盖 $pdir/cordis.patch.yml 当前内容"
        read -r -p "写回补丁层？(y/N): " CONFIRM || CONFIRM=""
        if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
            printf '%s\n' "$patch" > "$pdir/cordis.patch.yml" \
                && info "已写回 cordis.patch.yml" \
                || err "写入失败"
        fi
    fi

    echo
    echo "提示：插件装完需要重启 DSH 服务生效（主菜单 4）。"
    [ "$badn" -gt 0 ] && return 1
    return 0
}

# 备份 DSH 数据
backup_sessions() {
    title "备份 DSH 数据"
    
    # 检查 DSH 是否安装
    if ! check_dsh_installed; then
        err "DSH 未安装，无法备份"
        return 1
    fi
    
    # 检查 DSH 目录是否存在
    local dsh_dir="$HOME/.dsh"
    if [ ! -d "$dsh_dir" ]; then
        err "DSH 目录不存在：$dsh_dir"
        return 1
    fi
    
    # 初始化备份目录
    if ! init_backup_dir; then
        return 1
    fi
    
    # 先给现状，帮用户决定这次备哪种
    local status
    status=$(backup_status_lines)
    printf '上次备份：%s\n' "$(printf '%s\n' "$status" | sed -n '2p')"
    echo
    echo "选择备份类型："
    echo "1. 仅对话记录"
    echo "2. 完整备份（不含插件）"
    echo "0. 取消"
    echo
    echo "插件清单由 主菜单 7 → 5 负责，不在这里。"
    read -r -p "请选择： " BACKUP_TYPE

    local backup_file=""
    case $BACKUP_TYPE in
        1)
            # ---------- 仅对话记录 ----------
            backup_file=$(generate_backup_filename "dsh_dialogue_backup")

            echo
            echo "正在执行备份（对话记录）..."
            echo "备份内容："
            echo "- 会话正文 (sessions/)"
            echo "- 工作区归属与归档状态 (storages/workspace.json)"
            echo "- 会话标题等 (storages/session_projcache/)"
            echo
            echo "后两项缺一不可：只备 sessions/ 的话，恢复后所有对话会掉进"
            echo "「未分类」、标题变成工作区名、已归档的也会重新冒出来。"
            echo
            echo "注意：本备份不含插件、设置和附件。"
            echo "换机器或重装后恢复，建议改用第 2 种完整备份。"
            echo

            start_backup_animation "正在创建备份"
            pack_dsh_backup "$backup_file" \
                sessions \
                storages/workspace.json \
                storages/session_projcache
            cleanup_animation
            ;;
        2)
            # ---------- 完整备份（数据） ----------
            # 一把打包 ~/.dsh 的"数据"，但排除 profiles/：
            # 插件代码是可重新下载的派生品，且跨 DSH 版本恢复旧插件
            # 正是"插件跑不起来"的成因（见插件清单那一档的说明）。
            backup_file=$(generate_backup_filename "dsh_full_backup")

            echo
            echo "正在执行完整备份（数据）..."
            echo "备份内容："
            echo "- 对话记录 (sessions/)"
            echo "- 工作区配置 (storages/)"
            echo "- 附件 (attachments/)"
            echo "- 设置、登录凭据、集成与模型配置"
            echo
            echo "不含插件（profiles/）；插件请用第 3 种「插件清单」备份"
            echo "排除：profiles/、backups/、cache/、telemetry/"
            echo

            start_backup_animation "正在创建完整备份"
            # 注意：GNU tar 的 --exclude 是位置相关选项，必须写在操作数
            # .dsh 之前，写在后面会被直接忽略。旧版就写在了后面，
            # 结果 backups/（历次备份自身）和 cache/ 一直被塞进包里。
            # .cache 不带斜杠写：GNU tar 默认非锚定匹配，能命中任意深度的
            # 同名目录（与 rsync --exclude='.cache' 一致）；写成
            # .dsh/profiles/*/.cache 反而只能匹配一层深，深层排除不掉。
            tar -czf "$backup_file" -C "$HOME" \
                --exclude='.dsh/profiles' \
                --exclude='.dsh/backups' \
                --exclude='.dsh/cache' \
                --exclude='.dsh/telemetry' \
                --exclude='.cache' \
                .dsh 2>/dev/null
            cleanup_animation
            ;;
        0)
            warn "操作已取消"
            return 0
            ;;
        *)
            err "无效的选择"
            return 1
            ;;
    esac
    
    if [ ! -f "$backup_file" ]; then
        err "备份失败"
        return 1
    fi

    # 验证数据归档完整性
    if ! verify_backup "$backup_file"; then
        err "备份文件验证失败"
        return 1
    fi

    info "备份成功"
    echo "类型：$(backup_kind "$backup_file")"
    echo "文件：$(basename "$backup_file")"
    echo "大小：$(du -h "$backup_file" | cut -f1)"
    echo "会话：$(find "$dsh_dir/sessions" -name '*.jsonl.zstd' 2>/dev/null | wc -l) 个"
}

# 恢复 DSH 数据
restore_sessions() {
    title "恢复 DSH 数据"
    
    # 检查备份目录是否存在
    if [ ! -d "$BACKUP_DIR" ]; then
        err "备份目录不存在：$BACKUP_DIR"
        return 1
    fi
    
    # 列出可用的备份文件
    echo "可恢复的备份："
    echo
    local backup_files=($(list_backups_data_grouped))

    if [ ${#backup_files[@]} -eq 0 ]; then
        warn "没有找到备份数据"
        return 1
    fi

    print_backup_groups "${backup_files[@]}"
    
    echo
    echo "请输入要恢复的备份编号（或 0 取消）："
    read -r choice
    
    if [ "$choice" = "0" ] || [ -z "$choice" ]; then
        warn "操作已取消"
        return 0
    fi
    
    # 验证输入
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt ${#backup_files[@]} ]; then
        err "无效的选择"
        return 1
    fi
    
    local selected_file="${backup_files[$((choice-1))]}"
    local filename=$(basename "$selected_file")

    # 验证备份文件完整性
    if ! verify_backup "$selected_file"; then
        err "备份文件验证失败，无法恢复"
        return 1
    fi
    
    echo
    echo "即将恢复备份：$filename"
    echo "这将覆盖当前的 DSH 数据！"
    echo
    echo "恢复内容："
    echo "- 会话数据 (sessions/) - 您的对话历史"
    echo "- 工作区配置 (storages/) - 工作区设置"
    echo "- 设置、附件、集成配置"
    echo "（不含插件；插件请用「插件清单」备份恢复）"
    echo
    echo "重要提示："
    echo "1. 建议在恢复前停止 DSH 服务：systemctl stop dsh-web"
    echo "2. 恢复后重启 DSH 服务：systemctl restart dsh-web"
    echo "3. 此操作会覆盖当前所有数据，请确保已备份重要信息"
    echo
    read -r -p "确认恢复？(y/N): " CONFIRM
    
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        warn "操作已取消"
        return 0
    fi
    
    # 检查 DSH 目录
    local dsh_dir="$HOME/.dsh"
    if [ ! -d "$dsh_dir" ]; then
        err "DSH 目录不存在：$dsh_dir"
        return 1
    fi
    
    echo
    echo "正在恢复 DSH 数据..."
    
    # 恢复备份（带循环点状动画）
    echo -n "正在恢复备份数据"
    (
        # 子shell中忽略INT信号，这样父shell可以杀死它
        trap '' INT
        while true; do
            echo -n "."
            sleep 1
        done
    ) &
    ANIMATION_PID=$!
    
    # 先恢复到临时目录，然后验证完整性
    local temp_restore_dir=$(mktemp -d)
    if [ ! -d "$temp_restore_dir" ]; then
        cleanup_animation
        err "无法创建临时恢复目录"
        return 1
    fi
    
    tar -xzf "$selected_file" -C "$temp_restore_dir" 2>/dev/null
    local extract_result=$?
    
    if [ $extract_result -ne 0 ]; then
        cleanup_animation
        rm -rf "$temp_restore_dir"
        err "解压备份文件失败"
        return 1
    fi
    
    # 快速检查会话文件（只检查文件是否存在和大小）
    echo
    echo "正在快速检查会话文件..."
    local sessions_dir="$temp_restore_dir/.dsh/sessions"
    if [ -d "$sessions_dir" ]; then
        local total_files=$(find "$sessions_dir" -name "*.jsonl.zstd" | wc -l)
        local empty_files=$(find "$sessions_dir" -name "*.jsonl.zstd" -empty | wc -l)
        
        echo "发现 $total_files 个会话文件"
        if [ $empty_files -gt 0 ]; then
            warn "发现 $empty_files 个空会话文件"
        else
            info "会话文件快速检查通过"
        fi
    fi
    
    # 停止动画
    cleanup_animation

    # 目标端已有的工作区注册表会被备份里的同名文件覆盖，
    # 先留一份，别让"恢复旧备份"顺手抹掉现在的工作区分组。
    local ws="$dsh_dir/storages/workspace.json"
    if [ -f "$ws" ] && [ -f "$temp_restore_dir/.dsh/storages/workspace.json" ]; then
        if cp "$ws" "$ws.bak-$(date +%Y%m%d_%H%M%S)" 2>/dev/null; then
            echo "已把当前工作区注册表另存为 workspace.json.bak-*"
        fi
    fi

    # 执行实际恢复
    echo -n "正在恢复数据到目标目录"
    (
        trap '' INT
        while true; do
            echo -n "."
            sleep 1
        done
    ) &
    ANIMATION_PID=$!
    
    # 使用 rsync 或 tar 来确保恢复的完整性
    local restore_result=0
    if command -v rsync >/dev/null 2>&1; then
        # 使用 rsync 恢复，但不使用 --delete 选项，避免删除用户其他数据
        if ! rsync -a "$temp_restore_dir/.dsh/" "$dsh_dir/" 2>/dev/null; then
            restore_result=1
        fi
    else
        # 没有 rsync：就地解包覆盖。
        # tar 解包本身就是"同名覆盖、其余原样保留"，等价于 rsync 不带 --delete；
        # 旧实现把整个 ~/.dsh 移开再解包、成功后删掉旧的，
        # 那等于"备份里没有的东西全部删除" —— 最小备份会把插件直接抹掉。
        if ! tar -cf - -C "$temp_restore_dir" .dsh 2>/dev/null | tar -xf - -C "$HOME" 2>/dev/null; then
            restore_result=1
        fi
    fi
    
    # 停止动画
    cleanup_animation
    
    # 清理临时目录
    rm -rf "$temp_restore_dir"
    
    if [ $restore_result -eq 0 ]; then
        printf " 完成\n"
        info "恢复成功"
        echo "已恢复备份：$filename"
        echo
        echo "建议操作："
        echo "1. 重启 DSH 服务：systemctl restart dsh-web"
        echo "2. 检查会话是否正常加载"
        echo "3. 如有问题，检查日志：journalctl -u dsh-web -f"
        echo
        # 换机器恢复时，工作区记的绝对路径多半不存在 —— 顺手补出来
        recreate_workspace_dirs
    else
        printf " 失败\n"
        err "恢复失败"
        return 1
    fi
}

# 查看备份列表
# 备份管理主菜单
backup_management() {
    title "管理备份文件"
    
    # 检查备份目录是否存在
    if [ ! -d "$BACKUP_DIR" ]; then
        warn "备份目录不存在"
        return 0
    fi
    
    # 列出所有备份文件
    local backup_files=($(list_backups_data_grouped))
    
    if [ ${#backup_files[@]} -eq 0 ]; then
        warn "没有找到备份文件"
        return 0
    fi
    
    # 按类型分组展示，组内时间倒序；序号即数组下标，删除不会错位
    local total_size
    total_size=$(du -ch "${backup_files[@]}" 2>/dev/null | tail -n1 | cut -f1)
    printf '共 %s 个，%s\n' "${#backup_files[@]}" "${total_size:-?}"
    echo
    print_backup_groups "${backup_files[@]}"
    echo
    
    # 显示管理选项
    echo "=== 管理选项 ==="
    echo "1. 批量清理（保留最近N个）"
    echo "2. 选择序号清理"
    echo "3. 删除所有备份"
    echo "0. 返回主菜单"
    echo
    
    read -r -p "请选择： " choice
    
    case $choice in
        1) clean_backups_batch $(list_backups) ;;   # 按时间序保留"最近N个"
        2) clean_backups_select "${backup_files[@]}" ;;
        3) clean_backups_all ;;
        0) return 0 ;;
        *) warn "无效选项" ;;
    esac
}

# 批量清理备份（保留最近N个）
clean_backups_batch() {
    local backup_files=("$@")
    local total_count=${#backup_files[@]}
    
    echo
    echo "=== 批量清理备份 ==="
    echo "当前有 $total_count 个备份文件"
    echo
    echo "清理选项："
    echo "1. 保留最近 5 个备份"
    echo "2. 保留最近 10 个备份"
    echo "3. 自定义保留数量"
    echo "0. 取消"
    echo
    
    read -r -p "请选择： " choice
    
    case $choice in
        1) local keep_count=5 ;;
        2) local keep_count=10 ;;
        3)
            echo "请输入要保留的备份数量："
            read -r keep_count
            if ! [[ "$keep_count" =~ ^[0-9]+$ ]] || [ "$keep_count" -lt 0 ]; then
                err "无效的数量"
                return 1
            fi
            ;;
        0) warn "操作已取消"; return 0 ;;
        *) err "无效的选择"; return 1 ;;
    esac
    
    local delete_count=$((total_count - keep_count))
    
    if [ $delete_count -le 0 ]; then
        info "当前备份数量（$total_count）不超过保留数量（$keep_count），无需清理"
        return 0
    fi
    
    echo
    echo "将删除 $delete_count 个旧备份，保留最近 $keep_count 个"
    echo "将要删除的备份："
    for ((i=keep_count; i<total_count; i++)); do
        local file="${backup_files[$i]}"
        local filename=$(basename "$file")
        local filesize=$(du -h "$file" | cut -f1)
        echo "- $filename ($filesize)"
    done
    
    echo
    read -r -p "确认删除？(y/N): " CONFIRM
    
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        warn "操作已取消"
        return 0
    fi
    
    # 删除旧备份
    local deleted_count=0
    for ((i=keep_count; i<total_count; i++)); do
        local file="${backup_files[$i]}"
        if rm -f "$file" 2>/dev/null; then
            deleted_count=$((deleted_count + 1))
        else
            warn "无法删除：$file"
        fi
    done
    
    if [ $deleted_count -gt 0 ]; then
        info "已清理 $deleted_count 个旧备份"
    else
        warn "没有成功删除任何备份"
    fi
}

# 选择序号清理备份
clean_backups_select() {
    local backup_files=("$@")
    local total_count=${#backup_files[@]}
    
    echo
    echo "=== 选择序号清理备份 ==="
    echo "输入要删除的备份序号（多个序号用空格分隔，例如：1 3 5）"
    echo "输入 'q' 取消操作"
    echo
    
    read -r -p "请输入序号： " input
    
    if [ "$input" = "q" ] || [ -z "$input" ]; then
        warn "操作已取消"
        return 0
    fi
    
    # 解析输入
    local selected_indices=()
    for num in $input; do
        if [[ "$num" =~ ^[0-9]+$ ]] && [ "$num" -ge 1 ] && [ "$num" -le "$total_count" ]; then
            selected_indices+=($((num-1)))
        else
            warn "忽略无效序号：$num"
        fi
    done
    
    if [ ${#selected_indices[@]} -eq 0 ]; then
        warn "没有有效的序号"
        return 1
    fi
    
    echo
    echo "将要删除的备份："
    for index in "${selected_indices[@]}"; do
        local file="${backup_files[$index]}"
        local filename=$(basename "$file")
        local filesize=$(du -h "$file" | cut -f1)
        echo "- $filename ($filesize)"
    done
    
    echo
    read -r -p "确认删除？(y/N): " CONFIRM
    
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        warn "操作已取消"
        return 0
    fi
    
    # 删除选中的备份
    local deleted_count=0
    for index in "${selected_indices[@]}"; do
        local file="${backup_files[$index]}"
        if rm -f "$file" 2>/dev/null; then
            deleted_count=$((deleted_count + 1))
        else
            warn "无法删除：$file"
        fi
    done
    
    if [ $deleted_count -gt 0 ]; then
        info "已删除 $deleted_count 个备份"
    else
        warn "没有成功删除任何备份"
    fi
}

# 删除所有备份
clean_backups_all() {
    echo
    echo "=== 删除所有数据备份 ==="
    read -r -p "确认删除所有备份？(y/N): " CONFIRM
    
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        warn "操作已取消"
        return 0
    fi
    
    rm -f "$BACKUP_DIR"/dsh_dialogue_backup_*.tar.gz
    rm -f "$BACKUP_DIR"/dsh_data_backup_*.tar.gz
    rm -f "$BACKUP_DIR"/dsh_sessions_backup_*.tar.gz
    rm -f "$BACKUP_DIR"/dsh_full_backup_*.tar.gz
    
    info "已删除所有备份"
}



# 测试备份恢复
test_backup_restore() {
    title "测试备份恢复"
    
    # 检查备份目录是否存在
    if [ ! -d "$BACKUP_DIR" ]; then
        err "备份目录不存在：$BACKUP_DIR"
        return 1
    fi
    
    # 列出可用的备份文件
    local backup_files=($(list_backups_data_grouped))

    if [ ${#backup_files[@]} -eq 0 ]; then
        warn "没有找到备份文件"
        return 1
    fi

    echo "可测试的数据归档："
    echo
    print_backup_groups "${backup_files[@]}"
    
    echo
    echo "请输入要测试的备份编号（或 0 取消）："
    read -r choice
    
    if [ "$choice" = "0" ] || [ -z "$choice" ]; then
        warn "操作已取消"
        return 0
    fi
    
    # 验证输入
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt ${#backup_files[@]} ]; then
        err "无效的选择"
        return 1
    fi
    
    local selected_file="${backup_files[$((choice-1))]}"
    local filename=$(basename "$selected_file")
    
    echo
    echo "即将测试备份：$filename"
    read -r -p "确认测试？(y/N): " CONFIRM
    
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        warn "操作已取消"
        return 0
    fi
    
    # 创建临时目录
    local temp_dir=$(mktemp -d)
    if [ ! -d "$temp_dir" ]; then
        err "无法创建临时目录"
        return 1
    fi
    
    echo "正在测试备份..."
    
    # 测试备份文件
    if tar -tzf "$selected_file" >/dev/null 2>&1; then
        echo "✅ 备份文件结构完整"
        
        # 尝试解压到临时目录
        tar -xzf "$selected_file" -C "$temp_dir" 2>/dev/null
        if [ $? -eq 0 ]; then
            echo "✅ 备份文件可以正常解压"
            
            # 检查解压后的内容
            echo "备份内容："
            find "$temp_dir" -type f | head -10 | while read file; do
                echo "- $(basename "$file")"
            done
            
            local file_count=$(find "$temp_dir" -type f | wc -l)
            echo "总共 $file_count 个文件"
        else
            echo "❌ 备份文件解压失败"
        fi
    else
        echo "❌ 备份文件结构损坏"
    fi
    
    # 清理临时目录
    rm -rf "$temp_dir"
    
    echo
    echo "测试完成"
}

# 备份与恢复（菜单 8：会话 + 插件 + 配置）
backup_restore_management() {
    # 标题交给循环内的 clear + echo，避免进入时打两遍标题
    while true; do
        clear 2>/dev/null
        echo "=== 备份与恢复 ==="
        echo
        # 状态区：进来先看见"我备过没有"
        local status
        status=$(backup_status_lines)
        echo "目录   $BACKUP_DIR"
        printf '已有   %s\n' "$(printf '%s\n' "$status" | sed -n '1p')"
        printf '上次   %s\n' "$(printf '%s\n' "$status" | sed -n '2p')"
        echo
        echo "1. 新建备份"
        echo "2. 恢复备份"
        echo "3. 管理备份文件"
        echo "4. 测试备份恢复"
        echo "0. 返回"
        echo
        read -r -p "请选择操作： " choice || { echo; return 0; }
        
        case $choice in
            1)
                # 备份 DSH 数据
                backup_sessions
                ;;
            2)
                # 恢复 DSH 数据
                restore_sessions
                ;;
            3)
                # 管理备份列表
                backup_management
                ;;
            4)
                # 测试备份恢复
                test_backup_restore
                ;;
            0)
                return 0
                ;;
            *)
                err "无效的选择"
                ;;
        esac
        
        echo
        printf "按回车继续..."
        read -r null || { echo; return 0; }
    done
}

# 清理旧备份
# ========== 插件管理 ==========
# DSH 插件管理基于 pnpm

# 获取当前 profile
get_current_profile() {
    # 优先 web（DSH 默认 profile），否则取第一个真实 profile 目录。
    # profiles/node_modules 是链接堆、不是 profile，要排掉。
    local p=""
    if [ -d "$HOME/.dsh/profiles/web" ]; then
        p="web"
    else
        p=$(ls -d "$HOME/.dsh/profiles"/*/ 2>/dev/null \
            | xargs -n1 basename 2>/dev/null \
            | grep -vx 'node_modules' | head -n1)
    fi
    printf '%s\n' "${p:-web}"
}

# ========== 插件名解析 ==========
# pnpm list 输出形如 name@version；scoped 包是 @scope/name@version。
# 不能用 cut -d'@' -f1（对 scoped 包会得到空串，导致状态误判、
# 启用/禁用操作对象为空）。这里只剥掉"以数字开头的版本段"，
# 从而兼容 @scope/name（无版本）这类输入。
plugin_name_of() {
    printf '%s\n' "$1" | sed 's/@[0-9][^@]*$//'
}

# ========== 从 bundles 移除包 ==========
# 删除插件必须同步修改 package.json 的 dsh.profile.bundles：
# dependencies 移除了而 bundles 还留着，DSH 启动就报 cannot resolve profile bundle。
remove_from_bundles() {
    # 从当前目录的 package.json 里移除 bundles 条目。
    # 用 node 解析 —— DSH 离不开 node，等于零额外依赖；
    # 原来依赖 jq/python3，最小服务器上两个都没有时会把 bundles 留着，
    # 于是 DSH 启动报 cannot resolve profile bundle。
    local pkg="$1"
    [ -f package.json ] || return 1
    backup_file_unique package.json >/dev/null
    node -e '
      const fs = require("fs");
      const [file, name] = process.argv.slice(1);
      const d = JSON.parse(fs.readFileSync(file, "utf8"));
      d.dsh = d.dsh || {};
      d.dsh.profile = d.dsh.profile || {};
      d.dsh.profile.bundles = (d.dsh.profile.bundles || []).filter((x) => x !== name);
      fs.writeFileSync(file, JSON.stringify(d, null, 2) + "\n");
    ' package.json "$pkg" 2>/dev/null
}

# 插件管理（整合所有插件功能）
# 包装层：内部需要 cd 到 profile 目录，若不恢复工作目录，
# 返回主菜单后所有依赖 $0 相对路径的功能（改名写回、加别名、
# 菜单 00 自更新）都会找不到脚本文件。
plugin_management() {
    local _saved_pwd="$PWD"
    plugin_menu_loop
    local _rc=$?
    cd "$_saved_pwd" 2>/dev/null || cd "$HOME" 2>/dev/null
    return $_rc
}

plugin_menu_loop() {
    title "插件管理"
    
    local profile=$(get_current_profile)
    local profile_dir="$HOME/.dsh/profiles/$profile"
    
    if [ ! -d "$profile_dir" ]; then
        err "Profile 目录不存在：$profile_dir"
        return 1
    fi
    
    # 主循环
    while true; do
        clear 2>/dev/null
        echo "=== 插件管理 ==="
        echo "Profile: $profile"
        echo
        
        # 获取插件列表
        cd "$profile_dir" 2>/dev/null
        if [ $? -ne 0 ]; then
            err "无法进入 Profile 目录"
            return 1
        fi
        
        # 获取插件列表
        local plugin_list=$(pnpm list --depth=0 2>/dev/null | grep -E "├──|└──" | sed 's/├── //g; s/└── //g')
        
        if [ -z "$plugin_list" ]; then
            echo "没有安装任何插件"
            echo
            echo "操作："
            echo "1. 安装插件"
            echo "5. 备份插件列表"
            echo "0. 返回"
            echo
            read -r -p "请选择操作： " choice || { echo; return 0; }
            
            case $choice in
                1)
                    # 安装插件
                    echo "请输入插件名称："
                    echo "示例：dsh-web-mobile-fix"
                    read -r PLUGIN_NAME
                    
                    if [ -z "$PLUGIN_NAME" ]; then
                        err "插件名称不能为空"
                        continue
                    fi
                    
                    echo
                    echo "即将安装：$PLUGIN_NAME"
                    read -r -p "确认？(y/N): " CONFIRM
                    
                    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
                        warn "已取消"
                        continue
                    fi
                    
                    echo "正在安装..."
                    if ! ensure_pnpm; then
                        warn "没有 pnpm，装不了插件"
                        continue
                    fi
                    if plugin_add_with_builds "$profile" "$PLUGIN_NAME"; then
                        info "安装成功：$PLUGIN_NAME"
                        echo "提示：可能需要重启 DSH 服务"
                    else
                        err "安装失败"
                    fi
                    ;;
                5)
                    plugin_manifest_menu
                    ;;
                0)
                    return 0
                    ;;
                *)
                    err "无效的选择"
                    ;;
            esac
        else
            echo "已安装的插件："
            echo
            
            # 待放行的构建脚本：包装上了，但原生模块没编译，插件可能加载失败
            local pending
            pending=$(pending_build_approvals "$profile")
            if [ -n "$pending" ]; then
                warn "有依赖的构建脚本未放行：$pending"
                echo "      它们的原生模块没编译，相关插件可能加载失败。"
                echo "      处理：本菜单选 1 重新安装（会问你是否放行），"
                echo "      或进入 profile 目录执行 pnpm approve-builds。"
                echo
            fi

            # 使用数组存储插件列表
            local plugins=()
            local index=1
            while IFS= read -r plugin; do
                if [ -n "$plugin" ]; then
                    plugins+=("$plugin")
                    # 状态要分两件事看：包装没装上（node_modules）、
                    # 以及 DSH 会不会加载它（dsh.profile.bundles）。
                    local plugin_name=$(plugin_name_of "$plugin")
                    local status
                    if [ ! -d "node_modules/$plugin_name" ]; then
                        status="❌ 未安装"
                    elif profile_bundles_has "$profile" "$plugin_name"; then
                        status="✅ 已启用"
                    else
                        status="⚠️  已安装未启用"
                    fi
                    echo "$index. $plugin - $status"
                    index=$((index + 1))
                fi
            done <<< "$plugin_list"
            
            echo
            echo "操作："
            echo "1. 安装插件"
            echo "2. 启用插件"
            echo "3. 禁用插件"
            echo "4. 删除插件（支持批量）"
            echo "5. 备份插件列表"
            echo "0. 返回"
            echo
            read -r -p "请选择操作： " choice || { echo; return 0; }
            
            case $choice in
                1)
                    # 安装插件
                    echo "请输入插件名称："
                    echo "示例：dsh-web-mobile-fix"
                    read -r PLUGIN_NAME
                    
                    if [ -z "$PLUGIN_NAME" ]; then
                        err "插件名称不能为空"
                        continue
                    fi
                    
                    echo
                    echo "即将安装：$PLUGIN_NAME"
                    read -r -p "确认？(y/N): " CONFIRM
                    
                    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
                        warn "已取消"
                        continue
                    fi
                    
                    echo "正在安装..."
                    if ! ensure_pnpm; then
                        warn "没有 pnpm，装不了插件"
                        continue
                    fi
                    if plugin_add_with_builds "$profile" "$PLUGIN_NAME"; then
                        info "安装成功：$PLUGIN_NAME"
                        echo "提示：可能需要重启 DSH 服务"
                    else
                        err "安装失败"
                    fi
                    ;;
                2)
                    # 启用插件
                    echo "请输入要启用的插件序号："
                    read -r plugin_num
                    if [[ "$plugin_num" =~ ^[0-9]+$ ]] && [ "$plugin_num" -ge 1 ] && [ "$plugin_num" -le ${#plugins[@]} ]; then
                        local plugin_name="${plugins[$((plugin_num-1))]}"
                        local plugin_short_name=$(plugin_name_of "$plugin_name")
                        echo "启用插件：$plugin_short_name"
                        
                        if [ ! -d "node_modules/$plugin_short_name" ] && \
                           [ -d "node_modules/${plugin_short_name}.disabled" ]; then
                            # 兼容早期用"重命名目录"禁用的插件
                            mv "node_modules/${plugin_short_name}.disabled" \
                               "node_modules/$plugin_short_name" 2>/dev/null
                        fi

                        if [ ! -d "node_modules/$plugin_short_name" ]; then
                            err "插件没装（node_modules 里没有它），请先用 1 安装"
                        elif profile_bundles_has "$profile" "$plugin_short_name"; then
                            warn "插件已经是启用状态"
                        elif profile_bundles_edit "$profile" "$plugin_short_name" add; then
                            info "插件已启用：$plugin_short_name"
                            echo "已加入 DSH 的加载列表（dsh.profile.bundles）"
                            echo "提示：需要重启 DSH 服务才会生效"
                        else
                            err "启用失败"
                        fi
                    else
                        err "无效的插件序号"
                    fi
                    ;;
                3)
                    # 禁用插件
                    echo "请输入要禁用的插件序号："
                    read -r plugin_num
                    if [[ "$plugin_num" =~ ^[0-9]+$ ]] && [ "$plugin_num" -ge 1 ] && [ "$plugin_num" -le ${#plugins[@]} ]; then
                        local plugin_name="${plugins[$((plugin_num-1))]}"
                        local plugin_short_name=$(plugin_name_of "$plugin_name")
                        echo "禁用插件：$plugin_short_name"
                        
                        if ! profile_bundles_has "$profile" "$plugin_short_name"; then
                            warn "插件已经是禁用状态"
                        elif profile_bundles_edit "$profile" "$plugin_short_name" remove; then
                            info "插件已禁用：$plugin_short_name"
                            echo "已从 DSH 的加载列表移除；包仍在 node_modules 里，随时可再启用"
                            echo "提示：需要重启 DSH 服务才会生效"
                        else
                            err "禁用失败"
                        fi
                    else
                        err "无效的插件序号"
                    fi
                    ;;
                4)
                    # 删除插件
                    echo "请输入要删除的插件序号（多个序号用空格分隔，例如：1 3 5）："
                    read -r plugin_nums
                    
                    if [ -z "$plugin_nums" ]; then
                        err "未输入插件序号"
                        continue
                    fi
                    
                    echo "要删除的插件："
                    local delete_list=()
                    for num in $plugin_nums; do
                        if [[ "$num" =~ ^[0-9]+$ ]] && [ "$num" -ge 1 ] && [ "$num" -le ${#plugins[@]} ]; then
                            local plugin_name="${plugins[$((num-1))]}"
                            local plugin_short_name=$(plugin_name_of "$plugin_name")
                            if [ -z "$plugin_short_name" ]; then
                                plugin_short_name="$plugin_name"
                            fi
                            delete_list+=("$plugin_short_name")
                            echo "- $plugin_short_name"
                        else
                            warn "忽略无效的序号：$num"
                        fi
                    done
                    
                    if [ ${#delete_list[@]} -eq 0 ]; then
                        err "没有有效的插件序号"
                        continue
                    fi
                    
                    echo
                    echo "确认删除以上 ${#delete_list[@]} 个插件？(y/N): "
                    read -r CONFIRM
                    
                    if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
                        # 删除会同时改 dependencies 和 bundles，必须两者都成功：
                        # bundles 改不掉、包却没了，DSH 下次启动就报
                        # cannot resolve profile bundle。现在用 node 解析，
                        # DSH 离不开 node，所以不再依赖 jq / python3。
                        if ! command -v node >/dev/null 2>&1; then
                            err "缺少 node，无法安全删除插件"
                            echo "  删除插件必须同步更新 package.json 的 bundles。"
                            continue
                        fi
                        
                        local success_count=0
                        local fail_count=0
                        
                        for plugin_short_name in "${delete_list[@]}"; do
                            echo "删除插件：$plugin_short_name"
                            if ! pnpm remove "$plugin_short_name" >/dev/null 2>&1; then
                                warn "删除失败：$plugin_short_name"
                                fail_count=$((fail_count + 1))
                                continue
                            fi
                            # 依赖已移除，务必确认 bundles 也摘掉了
                            if remove_from_bundles "$plugin_short_name"; then
                                success_count=$((success_count + 1))
                            else
                                warn "已从依赖移除，但未能更新 dsh.profile.bundles：$plugin_short_name"
                                echo "  这会导致 DSH 启动报 cannot resolve profile bundle，请手动处理："
                                echo "  编辑 package.json，把 bundles 里的 \"$plugin_short_name\" 删掉"
                                fail_count=$((fail_count + 1))
                            fi
                        done
                        
                        echo
                        echo "批量删除完成："
                        echo "  成功：$success_count 个"
                        echo "  失败：$fail_count 个"
                        
                        if [ $success_count -gt 0 ]; then
                            echo "提示：可能需要重启 DSH 服务"
                        fi
                    else
                        warn "操作已取消"
                    fi
                    ;;
                5)
                    plugin_manifest_menu
                    ;;
                0)
                    return 0
                    ;;
                *)
                    err "无效的选择"
                    ;;
            esac
        fi
        
        echo
        printf "按回车继续..."
        read -r null || { echo; return 0; }
    done
}

# ========== 会话修复功能 ==========
# 检查会话文件完整性
check_session_integrity() {
    local session_file="$1"
    local session_dir=$(dirname "$session_file")
    
    echo "检查会话文件：$(basename "$session_dir")"
    
    # 检查文件大小
    local file_size=$(stat -c %s "$session_file" 2>/dev/null)
    if [ "$file_size" -eq 0 ]; then
        err "会话文件为空"
        return 1
    fi
    
    # 检查文件是否可读
    if ! cat "$session_file" >/dev/null 2>&1; then
        err "会话文件无法读取"
        return 1
    fi
    
    # 尝试使用 zstd 解压测试（如果可用）
    if command -v zstd >/dev/null 2>&1; then
        if ! zstd -t "$session_file" >/dev/null 2>&1; then
            warn "会话文件可能损坏（zstd 测试失败）"
            return 1
        fi
    fi
    
    # 检查会话文件是否有对应的 lock 文件
    local lock_file="$session_dir/session.lock"
    if [ -f "$lock_file" ]; then
        # 检查 lock 文件是否为空
        if [ ! -s "$lock_file" ]; then
            warn "会话 lock 文件为空"
        fi
    fi
    
    info "会话文件检查通过"
    return 0
}

# 修复损坏的会话文件
# 注意：DSH 会话日志是压缩的追加式日志，损坏后无法在本脚本内安全重建。
# 原实现是"把损坏文件复制成 .backup，再从这个副本恢复回自身"，
# 副本内容与原文件完全相同，于是必然"校验通过"并报告修复成功 ——
# 实际一个字节都没修，还会在每个会话目录留下 .backup 垃圾。
# 改成如实报告并给出可行路径，不再谎报修复。
report_corrupted_session() {
    local session_dir="$1"
    local session_file="$session_dir/session.v3.jsonl.zstd"
    
    echo "  ❌ 会话损坏：$(basename "$session_dir")"
    echo "     文件：$session_file"
    if [ -s "$session_file" ]; then
        echo "     大小：$(stat -c%s "$session_file" 2>/dev/null) 字节"
    fi
    echo "     可选处理："
    echo "       1) 有正常时期的备份 → 菜单 8「恢复 DSH 数据」"
    echo "       2) 否则该会话无法恢复，可删除该会话目录后重新开始"
    return 1
}

# 扫描会话文件（检测完整性，损坏时如实报告）
scan_and_fix_sessions() {
    title "扫描会话文件"
    
    local sessions_dir="$HOME/.dsh/sessions"
    
    # 检查会话目录
    if [ ! -d "$sessions_dir" ]; then
        err "会话目录不存在：$sessions_dir"
        return 1
    fi
    
    echo "会话目录：$sessions_dir"
    echo
    
    # 统计会话文件
    local total_sessions=0
    local corrupted_sessions=0
    
    echo "正在扫描会话文件..."
    echo
    
    # 遍历所有工作区
    for workspace_dir in "$sessions_dir"/*/; do
        if [ -d "$workspace_dir" ]; then
            local workspace_name=$(basename "$workspace_dir")
            echo "工作区：$workspace_name"
            
            # 遍历工作区中的会话
            for session_dir in "$workspace_dir"*/; do
                if [ -d "$session_dir" ]; then
                    local session_file="$session_dir/session.v3.jsonl.zstd"
                    
                    if [ -f "$session_file" ]; then
                        total_sessions=$((total_sessions + 1))
                        
                        # 检查会话完整性
                        if ! check_session_integrity "$session_file"; then
                            corrupted_sessions=$((corrupted_sessions + 1))
                            
                            # 损坏时如实报告（不做假修复：这类压缩日志无法在脚本内安全重建）
                            report_corrupted_session "$session_dir"
                        fi
                    fi
                fi
            done
            echo
        fi
    done
    
    # 显示结果
    title "扫描结果"
    echo "总会话数：$total_sessions"
    echo "损坏会话数：$corrupted_sessions"
    echo
    
    if [ $corrupted_sessions -gt 0 ]; then
        warn "共发现 $corrupted_sessions 个损坏会话"
        echo "这类日志是压缩的追加式文件，损坏后无法在本脚本内安全重建。"
        echo "建议："
        echo "  1. 有正常时期的备份 → 菜单 8「恢复 DSH 数据」"
        echo "  2. 确认 DSH 已停止后再操作，避免写入中的文件被复制"
        echo "  3. 无法恢复的会话，可删除其会话目录后重新开始"
    else
        info "没有发现损坏的会话文件"
    fi
    
    echo
    echo "提示：本功能只检测、不修改任何会话文件。"
    echo "如需从备份恢复，请用菜单 8；操作前建议先停止服务："
    echo "  systemctl stop $SVC"
}

# ========== 添加快捷命令到 .bashrc ==========
add_alias_to_bashrc() {
    title "添加快捷命令到 .bashrc"
    
    local BASHRC="$HOME/.bashrc"
    local SELF_PATH
    SELF_PATH=$(get_self_path)
    local ALIAS_LINE="alias d='bash $SELF_PATH'"
    local ALIAS_COMMENT="# DSH 管理脚本快捷命令"
    
    # 检查 .bashrc 文件是否存在
    if [ ! -f "$BASHRC" ]; then
        warn ".bashrc 文件不存在，跳过添加"
        return 1
    fi
    
    # 判据用"将要写入的完整行"做字面匹配。
    # 原先用 grep "alias d='bash.*dsh.sh'" 判断，但安装后的路径是
    # /usr/local/bin/dsh-manager，永远匹配不到，于是每按一次就重复追加一组。
    if grep -qF "$ALIAS_LINE" "$BASHRC" 2>/dev/null; then
        warn "快捷命令已存在于 .bashrc 中（指向同一路径）"
        return 0
    fi
    
    # 已有 d 别名（无论指向何处）时不要静默重复追加，否则会互相覆盖
    if grep -qE "^alias[[:space:]]+d=" "$BASHRC" 2>/dev/null; then
        warn ".bashrc 中已存在 d 别名，未重复添加"
        echo "  现有定义：$(grep -E '^alias[[:space:]]+d=' "$BASHRC" | head -n 1)"
        echo "  如需改用本脚本，请先用 菜单 9 → 2 移除，或手动删除该行"
        return 0
    fi
    
    # 添加别名到 .bashrc
    {
        echo ""
        echo "$ALIAS_COMMENT"
        echo "$ALIAS_LINE"
    } >> "$BASHRC"
    
    if [ $? -eq 0 ]; then
        info "快捷命令已添加到 .bashrc"
        echo
        echo "现在可以使用以下命令快速启动管理面板："
        echo "  d"
        echo
        echo "提示：需要重新加载 .bashrc 才能生效："
        echo "  source ~/.bashrc"
        echo "  或重新登录终端"
    else
        err "添加快捷命令失败"
        return 1
    fi
}

# ========== 移除快捷命令从 .bashrc ==========
remove_alias_from_bashrc() {
    title "移除快捷命令从 .bashrc"
    
    local BASHRC="$HOME/.bashrc"
    local SELF_PATH
    SELF_PATH=$(get_self_path)
    
    # 检查 .bashrc 文件是否存在
    if [ ! -f "$BASHRC" ]; then
        warn ".bashrc 文件不存在，跳过移除"
        return 1
    fi
    
    # 匹配本脚本可能写入的两种形态：
    #   1) alias d='bash <本脚本绝对路径>'   （本菜单写入）
    #   2) alias d='dsh-manager'             （安装器写入）
    # 原先只匹配 dsh.sh 字样，安装成 dsh-manager 后永远删不掉。
    local found=0
    if grep -qF "alias d='bash $SELF_PATH'" "$BASHRC" 2>/dev/null; then
        found=1
    elif grep -qF "alias d='$TARGET_NAME'" "$BASHRC" 2>/dev/null; then
        found=1
    elif grep -qE "^alias[[:space:]]+d=" "$BASHRC" 2>/dev/null; then
        found=1
    fi
    
    if [ $found -eq 0 ]; then
        warn "未找到 DSH 快捷命令"
        return 0
    fi
    
    # 只删本脚本写入的那几行；不碰用户自己定义的其他 d 别名以外内容
    sed -i '/^# DSH 管理脚本快捷命令$/d' "$BASHRC"
    sed -i '/^# DSH-Web 管理脚本快捷命令$/d' "$BASHRC"
    sed -i "/^alias d='bash .*'$/d" "$BASHRC"
    sed -i "/^alias d='$TARGET_NAME'$/d" "$BASHRC"
    
    # 清掉可能残留的尾部空行
    sed -i -e :a -e '/^\n*$/{$d;N;ba' -e '}' "$BASHRC" 2>/dev/null
    
    info "快捷命令已从 .bashrc 移除"
    echo
    echo "提示：需要重新加载 .bashrc 才能生效："
    echo "  source ~/.bashrc"
    echo "  或重新登录终端"
}

# ========== 菜单 1：快速开始 ==========
# 新手只需要记住这一个入口，但"自动"不等于"不打招呼"：
#   阶段一 体检：只看不动，弄清每项现状
#   阶段二 列清单：把将要发生的改动全部摆出来（含版本号）
#   阶段三 一次确认：用户点头后才动手，取消则一个字节都不改
#   阶段四 执行：严格按清单走，失败即停
quick_start() {
    title "快速开始"
    echo "先体检、再列出将要做的改动，确认后才动手。"
    echo

    # ================= 阶段一：体检（只读） =================
    local node_ok=0 dsh_ok=0 unit_ok=0 run_ok=0
    local cur_ver="" latest_ver=""

    if command -v node >/dev/null 2>&1 && command -v npm >/dev/null 2>&1; then
        node_ok=1
    fi
    if check_dsh_installed; then
        dsh_ok=1
        cur_ver=$(get_dsh_version)
    fi
    [ -f "/etc/systemd/system/${SVC}.service" ] && unit_ok=1
    if [ $unit_ok -eq 1 ] && is_run; then
        run_ok=1
    fi
    # 只有 node 可用时才查得到 npm 上的版本
    if [ $node_ok -eq 1 ]; then
        latest_ver=$(npm view @deepseek-ai/dsh version 2>/dev/null)
    fi

    if [ $node_ok -eq 1 ]; then
        echo "Node.js    已就绪  node $(node --version 2>/dev/null)  npm $(npm --version 2>/dev/null)"
    else
        echo "Node.js    缺失"
    fi
    if [ $dsh_ok -eq 1 ]; then
        echo "DSH 本体   已安装  $cur_ver"
        [ -n "$latest_ver" ] && echo "            npm 最新  $latest_ver"
    else
        echo "DSH 本体   未安装"
        [ -n "$latest_ver" ] && echo "            npm 最新  $latest_ver"
    fi
    if [ $unit_ok -eq 1 ]; then
        echo "systemd    已存在  $SVC"
    else
        echo "systemd    未初始化"
    fi
    if [ $run_ok -eq 1 ]; then
        echo "服务       运行中"
    else
        echo "服务       未运行"
    fi
    echo

    # ================= 阶段二：列清单 =================
    local -a PLAN=()
    if [ $node_ok -eq 0 ]; then
        PLAN+=("安装 Node.js 与 npm")
    fi
    if [ $dsh_ok -eq 0 ]; then
        if [ -n "$latest_ver" ]; then
            PLAN+=("安装 DSH 本体 ${latest_ver}")
        else
            PLAN+=("安装 DSH 本体（npm 上的最新版）")
        fi
    elif [ -n "$latest_ver" ] && [ "$cur_ver" != "$latest_ver" ]; then
        PLAN+=("升级 DSH 本体 ${cur_ver} → ${latest_ver}")
    fi
    if [ $unit_ok -eq 0 ]; then
        PLAN+=("创建并启用 systemd 服务 ${SVC}")
    fi
    if [ $run_ok -eq 0 ]; then
        PLAN+=("启动服务")
    fi
    PLAN+=("输出带 token 的访问链接")

    # 拿不到 npm 版本时，绝不去猜"是否有新版"，也就不碰已装好的 DSH
    if [ $dsh_ok -eq 1 ] && [ -z "$latest_ver" ]; then
        warn "读不到 npm 上的最新版本，本次不动 DSH 本体（避免误升级）"
        echo
    fi

    echo "将要执行："
    local step
    for step in "${PLAN[@]}"; do
        echo "  · $step"
    done
    echo

    # ================= 阶段三：一次确认 =================
    read -r -p "确认执行以上改动？(y/N): " CONFIRM || CONFIRM=""
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        warn "已取消，未做任何改动"
        return 0
    fi
    echo

    # ================= 阶段四：执行 =================
    if [ $node_ok -eq 0 ]; then
        echo "[1/4] 安装 Node.js 与 npm"
        install_nodejs_npm
        hash -r 2>/dev/null || true
        if ! command -v node >/dev/null 2>&1 || ! command -v npm >/dev/null 2>&1; then
            err "Node.js 环境不可用，快速开始中止"
            echo "可稍后单独安装：主菜单 9 → 3"
            return 1
        fi
    else
        echo "[1/4] Node.js / npm 已就绪，跳过"
    fi
    echo

    if [ $dsh_ok -eq 0 ] || { [ -n "$latest_ver" ] && [ "$cur_ver" != "$latest_ver" ]; }; then
        echo "[2/4] 安装 / 更新 DSH 本体"
        # --yes：上面已经把改动列清楚并确认过了，这里不再二次询问
        if ! install_or_update_dsh --yes; then
            err "DSH 本体未就绪，快速开始中止"
            return 1
        fi
    else
        echo "[2/4] DSH 本体无需改动，跳过"
    fi
    echo

    if [ $unit_ok -eq 0 ]; then
        echo "[3/4] 初始化 systemd 服务"
        if ! init_systemd; then
            err "服务初始化失败，快速开始中止"
            return 1
        fi
    else
        echo "[3/4] systemd 服务已存在，跳过"
    fi
    echo

    echo "[4/4] 启动服务并获取访问链接"
    if is_run; then
        echo "      服务已在运行"
    else
        start_svc
        if ! is_run; then
            err "服务启动失败，快速开始中止"
            echo "可回主菜单按 6「状态与日志」查看原因。"
            return 1
        fi
    fi
    echo

    get_url
    echo
    info "快速开始全部完成"
}

# ========== 把秒数说成人话 ==========
human_duration() {
    local s="$1"
    local d=$((s / 86400))
    local h=$(((s % 86400) / 3600))
    local m=$(((s % 3600) / 60))
    if [ "$d" -gt 0 ]; then
        printf '%d 天 %d 小时' "$d" "$h"
    elif [ "$h" -gt 0 ]; then
        printf '%d 小时 %d 分' "$h" "$m"
    else
        printf '%d 分' "$m"
    fi
}

# ========== 菜单 6：状态与日志 ==========
# 设计目标：一屏回答"现在正常吗"，答不上再往下钻。
#   ① 问 systemd（服务层） ② 看端口（业务层） ③ 给结论 ④ 贴日志
# 全程只读，不改任何状态；日志放在最后，是"结论的展开"，不是独立功能。
status_and_logs() {
    local UNIT="/etc/systemd/system/${SVC}.service"
    local JC
    JC=$(journal_cmd)

    while true; do
        clear 2>/dev/null
        title "状态与日志"

        local HAS_UNIT=0
        [ -f "$UNIT" ] && HAS_UNIT=1

        # ---------- ① 服务层 ----------
        local ACTIVE="" MAINPID="" RESTARTS="" ENABLED=""
        if [ "$HAS_UNIT" -eq 1 ]; then
            ACTIVE=$(sysctl show -p ActiveState --value "$SVC" 2>/dev/null | tr -d ' ')
            MAINPID=$(sysctl show -p MainPID --value "$SVC" 2>/dev/null | tr -d ' ')
            RESTARTS=$(sysctl show -p NRestarts --value "$SVC" 2>/dev/null | tr -d ' ')
            ENABLED=$(sysctl is-enabled "$SVC" 2>/dev/null)
        fi

        local STATE_TXT="" STATE_COLOR="$GRN"
        if [ "$HAS_UNIT" -eq 0 ]; then
            STATE_TXT="未初始化"; STATE_COLOR="$YEL"
        elif [ "$ACTIVE" = "active" ]; then
            STATE_TXT="运行中"
        elif [ "$ACTIVE" = "failed" ]; then
            STATE_TXT="启动失败"; STATE_COLOR="$RED"
        else
            STATE_TXT="未运行"; STATE_COLOR="$RED"
        fi

        local UPTIME_TXT=""
        if [ "$ACTIVE" = "active" ]; then
            local TS EPOCH NOW
            TS=$(sysctl show -p ActiveEnterTimestamp --value "$SVC" 2>/dev/null)
            EPOCH=$(date -d "$TS" +%s 2>/dev/null)
            NOW=$(date +%s)
            # date -d 是 GNU 扩展，busybox 下会失败，此时不显示运行时长即可
            if [ -n "$EPOCH" ] && [ "$EPOCH" -gt 0 ] 2>/dev/null; then
                UPTIME_TXT=$(human_duration $((NOW - EPOCH)))
            fi
        fi

        # 一行一个字段：窄终端下横向拼接必然换行
        printf "服务    %s\n" "$SVC"
        printf "状态    ${STATE_COLOR}%s${RST}\n" "$STATE_TXT"
        case "$ENABLED" in
            enabled)  printf "自启    是\n" ;;
            disabled) printf "自启    否\n" ;;
        esac
        [ -n "$UPTIME_TXT" ] && printf "运行    %s\n" "$UPTIME_TXT"
        [ -n "$RESTARTS" ] && [ "$RESTARTS" != "0" ] && printf "重启    %s 次\n" "$RESTARTS"
        if [ -n "$MAINPID" ] && [ "$MAINPID" != "0" ]; then
            printf "主进程  PID %s\n" "$MAINPID"
        fi

        # ---------- ② 业务层：端口 ----------
        local PORTLINE="" LISTEN=0
        if command -v ss >/dev/null 2>&1; then
            PORTLINE=$(ss -ltn 2>/dev/null | grep -E "[:.]${DSH_PORT}[[:space:]]" | head -n1)
        elif command -v netstat >/dev/null 2>&1; then
            PORTLINE=$(netstat -ltn 2>/dev/null | grep -E "[:.]${DSH_PORT}[[:space:]]" | head -n1)
        fi
        if [ -n "$PORTLINE" ]; then
            LISTEN=1
            printf "监听    %s\n" "$(printf '%s' "$PORTLINE" | awk '{print $4}')"
        else
            printf "监听    端口 %s 未监听\n" "$DSH_PORT"
        fi

        # ---------- ③ 结论 ----------
        echo
        if [ "$HAS_UNIT" -eq 0 ]; then
            warn "结论：服务尚未初始化 —— 回主菜单按 1「快速开始」"
        elif [ "$ACTIVE" != "active" ]; then
            err "结论：服务未运行 —— 主菜单按 2 可启动"
        elif [ "$LISTEN" -eq 1 ]; then
            info "结论：运行正常"
        else
            warn "结论：进程在跑，但端口 $DSH_PORT 未监听（可能在启动中，或监听地址被改过）"
        fi

        # ---------- ④ 日志 ----------
        echo
        echo "最近日志（末尾 20 行）"
        local LOGS
        LOGS=$($JC -u "$SVC" -n 20 --no-pager 2>/dev/null)
        if [ -n "$LOGS" ]; then
            printf '%s\n' "$LOGS" | sed 's/^/  /'
        else
            echo "  （读不到日志：服务未初始化，或缺少 root 权限）"
        fi

        echo
        echo "1. 进入实时日志（Ctrl+C 退出）"
        echo "2. 只看错误级别日志"
        echo "3. 刷新"
        echo "0. 返回"
        echo
        local choice
        read -r -p "请选择： " choice || { echo; return 0; }

        case "$choice" in
            1)
                echo
                show_logs
                ;;
            2)
                echo
                echo "错误级别日志（末尾 50 行）"
                $JC -u "$SVC" -p err -n 50 --no-pager 2>/dev/null
                ;;
            3)
                continue
                ;;
            0)
                return 0
                ;;
            *)
                warn "无效选项"
                ;;
        esac

        echo
        printf "按回车继续..."
        read -r null || { echo; return 0; }
    done
}

# ========== 插件清单（菜单 7 → 5） ==========
# 从备份与恢复搬过来：插件的东西归插件菜单，
# 而且 1KB 的元数据混进大归档列表会被"保留最近N个"顺手删掉。
# ---------- 备份插件列表 ----------
# 设计：列表即入口。打开就看得到有几份备份，输入编号直接看内容，
# 不在"先选动作、再问是哪一份"上绕两遍。
#   b = 备份当前列表（b 是 backup，避免和编号撞车）
#   数字 = 查看该份备份

# 一行一份：编号、时间、里面几个插件
print_manifest_line() {
    local idx="$1" file="$2"
    local filedate n
    filedate=$(stat -c %y "$file" 2>/dev/null | cut -d' ' -f1,2 | cut -d: -f1,2)
    n=$(grep -c '^plugin=' "$file" 2>/dev/null)
    printf '  %2s. %s   %s 个插件\n' "$idx" "${filedate:-未知时间}" "${n:-0}"
}

plugin_manifest_export() {
    title "备份当前插件列表"
    if ! init_backup_dir; then
        return 1
    fi
    local out="${BACKUP_DIR}/dsh_plugins_backup_$(date +%Y%m%d_%H%M%S).list"
    if ! backup_plugin_manifest "$out"; then
        rm -f "$out"
        return 1
    fi
    info "已备份"
    echo "文件：$(basename "$out")"
    echo "插件：$(grep -c '^plugin=' "$out" 2>/dev/null) 个"
    echo "位置：$BACKUP_DIR"
}

# 单份备份的详情页：看内容 + 对这份备份做操作
plugin_manifest_detail() {
    local file="$1"
    while true; do
        clear 2>/dev/null
        title "备份详情"

        local created saved_dsh cur_dsh profile
        created=$(grep -m1 '^created=' "$file" 2>/dev/null | cut -d= -f2)
        saved_dsh=$(grep -m1 '^dsh_version=' "$file" 2>/dev/null | cut -d= -f2)
        profile=$(grep -m1 '^profile=' "$file" 2>/dev/null | cut -d= -f2)
        cur_dsh=$(get_dsh_version 2>/dev/null)

        local n
        n=$(grep -c '^plugin=' "$file" 2>/dev/null)
        printf '备份时间：%s\n' "${created:-未知}"
        printf '插件数量：%s 个\n' "${n:-0}"
        printf '备份时 DSH：%s\n' "${saved_dsh:-未知}"
        if [ -n "$saved_dsh" ] && [ -n "$cur_dsh" ] && [ "$saved_dsh" != "$cur_dsh" ]; then
            printf '当前 DSH：%s   ' "$cur_dsh"
            printf "${YEL}版本已变，下面这些插件未必兼容${RST}\n"
        else
            printf '当前 DSH：%s\n' "${cur_dsh:-未知}"
        fi
        echo

        # 主体就是插件列表：名称@版本，有兼容声明的跟在后面
        local entry name d
        while IFS= read -r entry; do
            [ -n "$entry" ] || continue
            name="${entry%@*}"
            printf '  %s\n' "$entry"
            d=$(grep -m1 "^declared=${name} " "$file" 2>/dev/null | sed 's/^declared=[^ ]* //')
            [ -n "$d" ] && printf '      声明兼容 %s\n' "$d"
        done < <(grep '^plugin=' "$file" 2>/dev/null | sed 's/^plugin=//')

        echo
        printf '文件：%s\n' "$(basename "$file")"
        if [ -n "$(manifest_patch_real "$file")" ]; then
            printf "补丁层：${YEL}有自定义 cordis.patch.yml${RST}\n"
        else
            printf '补丁层：无（原文另含装载顺序，供手动重建时查）\n'
        fi
        echo
        echo "1. 按这份备份重装插件"
        echo "2. 删除这份备份"
        echo "0. 返回"
        echo
        local choice
        read -r -p "请选择： " choice || { echo; return 0; }

        case $choice in
            1)
                restore_plugin_manifest "$file" || true
                ;;
            2)
                echo
                read -r -p "确认删除 $(basename "$file")？(y/N): " CONFIRM || CONFIRM=""
                if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
                    rm -f "$file" && info "已删除" || err "删除失败"
                    echo
                    printf "按回车继续..."
                    read -r null || { echo; return 0; }
                    return 0
                fi
                warn "操作已取消"
                ;;
            0)
                return 0
                ;;
            *)
                warn "无效选项"
                continue
                ;;
        esac

        echo
        printf "按回车继续..."
        read -r null || { echo; return 0; }
    done
}

plugin_manifest_menu() {
    while true; do
        clear 2>/dev/null
        title "备份插件列表"

        printf '当前 DSH：%s\n' "$(get_dsh_version 2>/dev/null)"
        echo

        local files=($(list_backups_plugins))
        if [ ${#files[@]} -eq 0 ]; then
            echo "还没有备份过插件列表。"
            echo "备份的是「当时装了哪些插件、什么版本」，约 1KB，不含插件代码。"
            echo "换机器或重装后照着它把插件装回来即可。"
            echo
            echo "b. 备份当前插件列表"
            echo "0. 返回"
            echo
            read -r -p "请选择： " choice || { echo; return 0; }
            case $choice in
                b|B) plugin_manifest_export ;;
                0) return 0 ;;
                *) warn "无效选项"; continue ;;
            esac
            echo
            printf "按回车继续..."
            read -r null || { echo; return 0; }
            continue
        fi

        printf '共 %s 份备份（输入编号查看）：\n\n' "${#files[@]}"
        local i
        for i in "${!files[@]}"; do
            print_manifest_line "$((i+1))" "${files[$i]}"
        done
        echo
        echo "b. 备份当前插件列表"
        echo "0. 返回"
        echo
        read -r -p "请选择： " choice || { echo; return 0; }

        case $choice in
            b|B)
                plugin_manifest_export
                echo
                printf "按回车继续..."
                read -r null || { echo; return 0; }
                ;;
            ''|*[!0-9]*)
                warn "无效选项"
                ;;
            0)
                return 0
                ;;
            *)
                if [ "$choice" -ge 1 ] && [ "$choice" -le ${#files[@]} ]; then
                    plugin_manifest_detail "${files[$((choice-1))]}"
                else
                    warn "无效编号"
                fi
                ;;
        esac
    done
}

# ========== 菜单 9：维护工具 ==========
maintenance_menu() {
    while true; do
        clear 2>/dev/null
        title "维护工具"
        echo "1. 修改 systemd 服务名称（当前：$SVC）"
        echo "2. 快捷命令 .bashrc（添加 / 移除）"
        echo "3. 安装 Node.js 与 npm"
        echo "4. 扫描修复会话文件"
        echo "5. 补齐工作区目录"
        echo "6. 内存与进程诊断"
        echo "0. 返回"
        echo
        local choice
        read -r -p "请选择： " choice || { echo; return 0; }

        case "$choice" in
            1) rename_svc ;;
            2) alias_menu ;;
            3) install_nodejs_npm ;;
            4) scan_and_fix_sessions ;;
            5) recreate_workspace_dirs ;;
            6) mem_diag ;;
            0) return 0 ;;
            *) warn "无效选项"; continue ;;
        esac

        echo
        printf "按回车继续..."
        read -r null || { echo; return 0; }
    done
}

# 快捷命令的加/删合成一项，不再各占一个主菜单位
alias_menu() {
    while true; do
        clear 2>/dev/null
        title "快捷命令 .bashrc"
        echo "1. 添加（alias d='$TARGET_NAME'）"
        echo "2. 移除"
        echo "0. 返回"
        echo
        local choice
        read -r -p "请选择： " choice || { echo; return 0; }

        case "$choice" in
            1) add_alias_to_bashrc ;;
            2) remove_alias_from_bashrc ;;
            0) return 0 ;;
            *) warn "无效选项"; continue ;;
        esac

        echo
        printf "按回车继续..."
        read -r null || { echo; return 0; }
    done
}

# ========== 菜单 ==========
# 排版约束：每一行都要能在 50 列的窄终端里不换行。
#   · 选项一律不带说明文字——窄终端下注释正是换行的元凶；
#     选项名本身够自解释，不确定就按进去看，子菜单 0 一律返回。
#   · 状态拆成几行短行，不用 ｜ 拼长行（全角分隔符本身就是宽字符）。
menu() {
    clear 2>/dev/null

    printf "${BLD}==== DSH-Web 管理面板 v%s ====${RST}\n" "$SCRIPT_VERSION"
    echo

    # ---- 状态区：每行都短 ----
    local DSH_TXT="" DSH_COLOR="$GRN"
    if check_dsh_installed; then
        DSH_TXT=$(get_dsh_version)
    else
        DSH_TXT="未安装"; DSH_COLOR="$RED"
    fi

    local UNIT="/etc/systemd/system/${SVC}.service"
    local STATE_TXT="" STATE_COLOR="$GRN" PID_TXT=""
    if [ ! -f "$UNIT" ]; then
        STATE_TXT="未初始化"; STATE_COLOR="$YEL"
    else
        local ACTIVE
        ACTIVE=$(sysctl show -p ActiveState --value "$SVC" 2>/dev/null | tr -d ' ')
        if [ "$ACTIVE" = "active" ]; then
            STATE_TXT="运行中"
            PID_TXT=$(sysctl show -p MainPID --value "$SVC" 2>/dev/null | tr -d ' ')
        elif [ "$ACTIVE" = "failed" ]; then
            STATE_TXT="启动失败"; STATE_COLOR="$RED"
        else
            STATE_TXT="未运行"; STATE_COLOR="$RED"
        fi
    fi

    printf "DSH   ${DSH_COLOR}%s${RST}\n" "$DSH_TXT"
    printf "服务  %s  ${STATE_COLOR}%s${RST}\n" "$SVC" "$STATE_TXT"
    if [ -n "$PID_TXT" ] && [ "$PID_TXT" != "0" ]; then
        printf "端口  %s   PID %s\n" "$DSH_PORT" "$PID_TXT"
    else
        printf "端口  %s\n" "$DSH_PORT"
    fi
    if ! check_dsh_installed; then
        printf "${YEL}DSH 未安装，输入 1 一键开始${RST}\n"
    fi
    echo

    # ---- 选项区：一项一行，不带注释 ----
    echo " 1. 快速开始"
    echo " 2. 启动"
    echo " 3. 停止"
    echo " 4. 重启"
    echo " 5. 获取 Token 链接"
    echo " 6. 状态与日志"
    echo " 7. 插件管理"
    echo " 8. 备份与恢复"
    echo " 9. 维护工具"
    echo "10. 卸载"
    echo
    echo "00. 更新管理脚本"
    echo " 0. 退出"
    echo
    printf "请输入选项："
}

# ========== 主循环 ==========
# 在主循环开始时设置全局信号陷阱
trap cleanup_animation EXIT INT TERM

while true; do
    menu
    # stdin 到 EOF（如 < /dev/null、管道结束）时必须退出，
    # 否则 read 立即返回空值会让菜单无限刷屏
    if ! read -r opt; then
        echo
        echo "已退出"
        exit 0
    fi
    case $opt in
        1) quick_start ;;
        2) start_svc ;;
        3) stop_svc ;;
        4) restart_svc ;;
        5) get_url ;;
        6) status_and_logs ;;
        7) plugin_management ;;
        8) backup_restore_management ;;
        9) maintenance_menu ;;
        10) uninstall_management ;;
        00) update_self ;;
        0) echo "已退出"; exit 0 ;;
        *) warn "无效选项" ;;
    esac

    echo
    printf "按回车继续..."
    read -r null || { echo; echo "已退出"; exit 0; }
done

