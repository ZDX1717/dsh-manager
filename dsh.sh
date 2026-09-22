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
SCRIPT_VERSION="1.4.2"
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

# ========== 终端颜色 ==========
if [ -t 1 ]; then
    RST=$'\033[0m'
    RED=$'\033[31m'
    GRN=$'\033[32m'
    YEL=$'\033[33m'
    BLD=$'\033[1m'
else
    RST=""
    RED=""
    GRN=""
    YEL=""
    BLD=""
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
    echo "DSH 程序本体尚未安装。安装方式："
    echo
    echo "  方式一（推荐）：在本管理面板里直接安装"
    echo "    菜单 12「安装/更新 DSH 程序本体(npm)」"
    echo
    echo "  方式二：手动执行"
    echo "    npm install -g @deepseek-ai/dsh"
    echo
    echo "  方式三：下载二进制文件到 $DSH_BIN"
    echo
    echo "安装后回到菜单 7「初次初始化 Systemd 服务」，再启动服务。"
}

# ========== 预检查 ==========
pre_check() {
    if ! check_dsh_installed; then
        install_guide
        return 1
    fi
    return 0
}

# ========== 更新DSH函数（npm全局更新本体） ==========
# ========== 安装 / 更新 DSH 程序本体（npm） ==========
# npm install -g 同时覆盖"全新安装"和"升级到最新"两种情况，
# 因此安装与更新合并为同一个入口，无需两个菜单项。
install_or_update_dsh() {
    title "安装 / 更新 DSH 程序本体"
    
    # ---------- 前置依赖：npm 与 node ----------
    if ! command -v npm >/dev/null 2>&1; then
        err "未找到 npm（DSH 通过 npm 全局安装）"
        echo "请先安装 Node.js 与 npm，例如："
        echo "  Debian/Ubuntu：apt install -y nodejs npm"
        echo "  Fedora/RHEL  ：dnf install -y nodejs npm"
        echo "  Arch         ：pacman -S nodejs npm"
        echo
        echo "若发行版自带版本过旧，建议用 NodeSource 源安装较新版 Node.js。"
        return 1
    fi
    if ! command -v node >/dev/null 2>&1; then
        err "检测到 npm 但未找到 node，Node.js 环境不完整"
        echo "请重新安装 Node.js 后重试。"
        return 1
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
        warn "无法获取版本信息（可能是网络或 npm 源问题），仍可继续安装"
    fi
    
    # ---------- 已是最新时询问是否重装 ----------
    if [ $installed -eq 1 ] && [ -n "$latest_version" ] && [ "$current_version" = "$latest_version" ]; then
        echo
        warn "当前已是最新版本"
        local CONFIRM
        read -r -p "是否仍要重新安装？(y/N): " CONFIRM || CONFIRM=""
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
            echo "提示：服务尚未初始化，可用菜单 7「初次初始化 Systemd 服务」创建。"
        else
            echo "提示：服务尚未初始化，可用菜单 7 创建后再启动。"
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

# ========== 状态 ==========
status_svc() {
    title "${SVC} 服务状态"
    
    # 检查 DSH 安装状态
    if check_dsh_installed; then
        local VER
        VER=$(get_dsh_version)
        printf "DSH程序版本：%s\n" "$VER"
        printf "DSH安装路径：%s\n\n" "$(which dsh 2>/dev/null || echo "$DSH_BIN")"
    else
        err "DSH 未安装"
        echo
    fi

    # 检查服务状态
    local UNIT="/etc/systemd/system/${SVC}.service"
    if [ -f "$UNIT" ]; then
        if is_run; then
            info "服务状态：运行中"
        else
            err "服务状态：未运行"
        fi
        echo
        sysctl status "$SVC" --no-pager -l | grep -E "Loaded|Active|PID"
    else
        warn "服务未初始化"
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
    echo "  如需保留，建议先用菜单 13「备份与恢复管理」导出"
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
        echo "1. 卸载 systemd 服务（保留 DSH 程序与管理脚本）"
        echo "2. 卸载 DSH 程序本体（npm，保留数据）"
        echo "3. 完全卸载（服务 + DSH 程序 + 管理脚本，保留数据）"
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
    
    echo "选择备份类型："
    echo "1. 最小备份（推荐） - 只备份会话和配置"
    echo "2. 完整备份 - 备份所有数据"
    echo "0. 取消"
    read -r -p "请选择： " BACKUP_TYPE
    
    case $BACKUP_TYPE in
        1)
            # 最小备份
            local backup_file=$(generate_backup_filename "dsh_sessions_backup")
            
            echo
            echo "正在执行最小备份..."
            echo "备份内容（核心数据）："
            echo "- 会话数据 (sessions/) - 存储所有对话记录"
            echo "- 工作区配置 (storages/) - 存储工作区设置"
            echo "- 插件配置 (profiles/ 下的配置文件)"
            echo "- 设置文件 (settings.yaml)"
            echo
            echo "注意：此备份包含您的对话历史和工作区配置，"
            echo "重装 DSH 后恢复这些文件即可保留所有数据。"
            echo
            
            # 创建临时目录结构
            local temp_dir=$(mktemp -d)
            if [ ! -d "$temp_dir" ]; then
                err "无法创建临时目录"
                return 1
            fi
            
            mkdir -p "$temp_dir/.dsh"
            if [ $? -ne 0 ]; then
                err "无法创建临时目录结构"
                rm -rf "$temp_dir"
                return 1
            fi
            
            # 复制重要目录
            echo "正在复制会话数据..."
            if [ -d "$dsh_dir/sessions" ]; then
                # 使用 rsync 或 tar 来确保文件完整性
                if command -v rsync >/dev/null 2>&1; then
                    rsync -a "$dsh_dir/sessions/" "$temp_dir/.dsh/sessions/" 2>/dev/null
                else
                    # 如果没有 rsync，使用 tar 管道来确保完整性
                    tar -cf - -C "$dsh_dir" sessions | tar -xf - -C "$temp_dir/.dsh/" 2>/dev/null
                fi
                if [ $? -ne 0 ]; then
                    warn "复制会话数据时出现警告"
                fi
            fi
            
            echo "正在复制工作区配置..."
            if [ -d "$dsh_dir/storages" ]; then
                if command -v rsync >/dev/null 2>&1; then
                    rsync -a "$dsh_dir/storages/" "$temp_dir/.dsh/storages/" 2>/dev/null
                else
                    tar -cf - -C "$dsh_dir" storages | tar -xf - -C "$temp_dir/.dsh/" 2>/dev/null
                fi
                if [ $? -ne 0 ]; then
                    warn "复制工作区配置时出现警告"
                fi
            fi
            
            echo "正在复制插件配置..."
            if [ -d "$dsh_dir/profiles" ]; then
                # 备份插件配置和依赖
                mkdir -p "$temp_dir/.dsh/profiles"
                for profile_dir in "$dsh_dir/profiles"/*/; do
                    if [ -d "$profile_dir" ]; then
                        local profile_name=$(basename "$profile_dir")
                        mkdir -p "$temp_dir/.dsh/profiles/$profile_name"
                        
                        # 复制配置文件和 node_modules（插件本身）
                        if command -v rsync >/dev/null 2>&1; then
                            rsync -a --exclude='.cache' "$profile_dir/" "$temp_dir/.dsh/profiles/$profile_name/" 2>/dev/null
                        else
                            # 使用 tar 来复制配置和插件
                            cd "$profile_dir" 2>/dev/null && tar -cf - --exclude='.cache' . | tar -xf - -C "$temp_dir/.dsh/profiles/$profile_name/" 2>/dev/null
                            cd - >/dev/null 2>&1
                        fi
                    fi
                done
                
                # 复制根目录的配置文件
                if [ -f "$dsh_dir/profiles/package.json" ]; then
                    cp "$dsh_dir/profiles/package.json" "$temp_dir/.dsh/profiles/" 2>/dev/null
                fi
                if [ -f "$dsh_dir/profiles/pnpm-workspace.yaml" ]; then
                    cp "$dsh_dir/profiles/pnpm-workspace.yaml" "$temp_dir/.dsh/profiles/" 2>/dev/null
                fi
            fi
            
            echo "正在复制设置文件..."
            if [ -f "$dsh_dir/settings.yaml" ]; then
                cp "$dsh_dir/settings.yaml" "$temp_dir/.dsh/" 2>/dev/null
                if [ $? -ne 0 ]; then
                    warn "复制设置文件时出现警告"
                fi
            fi
            
            # 复制其他重要文件
            echo "正在复制其他配置文件..."
            for file in ".anonymous-user-id" ".credentials.yaml"; do
                if [ -f "$dsh_dir/$file" ]; then
                    cp "$dsh_dir/$file" "$temp_dir/.dsh/" 2>/dev/null
                fi
            done
            
            # 显示循环点状动画
            echo -n "正在创建备份"
            (
                # 子shell中忽略INT信号，这样父shell可以杀死它
                trap '' INT
                while true; do
                    echo -n "."
                    sleep 1
                done
            ) &
            ANIMATION_PID=$!
            
            # 执行备份
            tar -czf "$backup_file" -C "$temp_dir" .dsh 2>/dev/null
            local backup_result=$?
            
            # 停止动画
            cleanup_animation
            
            if [ $backup_result -eq 0 ]; then
                printf " 完成\n"
            else
                printf " 失败\n"
            fi
            
            # 清理临时目录
            rm -rf "$temp_dir"
            ;;
        2)
            # 完整备份
            local backup_file=$(generate_backup_filename "dsh_full_backup")
            
            echo
            echo "正在执行完整备份..."
            echo "备份内容："
            echo "- 会话数据 (sessions/)"
            echo "- 工作区配置 (storages/)"
            echo "- 插件配置和插件本身 (profiles/)"
            echo "- 设置文件 (settings.yaml)"
            echo "- 其他配置文件"
            echo
            
            # 显示循环点状动画
            echo -n "正在创建完整备份"
            (
                # 子shell中忽略INT信号，这样父shell可以杀死它
                trap '' INT
                while true; do
                    echo -n "."
                    sleep 1
                done
            ) &
            ANIMATION_PID=$!
            
            # 执行备份（排除缓存和临时文件，但保留插件）
            tar -czf "$backup_file" -C "$HOME" .dsh \
                --exclude='.dsh/backups' \
                --exclude='.dsh/profiles/*/.cache' \
                --exclude='.dsh/cache' \
                --exclude='.dsh/telemetry' \
                2>/dev/null
            local backup_result=$?
            
            # 停止动画
            cleanup_animation
            
            if [ $backup_result -eq 0 ]; then
                printf " 完成\n"
            else
                printf " 失败\n"
            fi
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
    
    if [ -f "$backup_file" ]; then
        # 验证备份文件完整性
        if ! verify_backup "$backup_file"; then
            err "备份文件验证失败"
            return 1
        fi
        
        local backup_size=$(du -h "$backup_file" | cut -f1)
        info "备份成功"
        echo "备份文件：$backup_file"
        echo "备份大小：$backup_size"
        echo
        echo "备份内容："
        echo "- 会话目录：$(ls -1 "$dsh_dir/sessions/" 2>/dev/null | wc -l) 个工作区"
        echo "- 会话文件：$(find "$dsh_dir/sessions/" -name "*.jsonl.zstd" 2>/dev/null | wc -l) 个会话"
        echo "- 工作区配置：$(cat "$dsh_dir/storages/workspace.json" 2>/dev/null | grep -c "workspaceIds" || echo 0) 个工作区"
        echo
        echo "备份文件内容："
        tar -tzf "$backup_file" 2>/dev/null | head -10
        echo "..."
    else
        err "备份失败"
        return 1
    fi
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
    echo "可用的备份文件："
    echo
    local backup_files=($(ls -1 "$BACKUP_DIR"/*.tar.gz 2>/dev/null | grep -E "(dsh_sessions_backup|dsh_full_backup)" | sort -r))
    
    if [ ${#backup_files[@]} -eq 0 ]; then
        warn "没有找到备份文件"
        return 1
    fi
    
    for i in "${!backup_files[@]}"; do
        local file="${backup_files[$i]}"
        local filename=$(basename "$file")
        local filesize=$(du -h "$file" | cut -f1)
        local filedate=$(stat -c %y "$file" 2>/dev/null | cut -d' ' -f1,2 | cut -d'.' -f1)
        echo "$((i+1)). $filename ($filesize) - $filedate"
    done
    
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
    echo "- 插件配置和设置文件"
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
        # 没有 rsync：改为"先移开、再落盘、成功才删"，
        # 绝不在未确认可回退的情况下 rm -rf 用户数据。
        local stash="${dsh_dir}.old.$$"
        local moved=0
        if [ -d "$dsh_dir" ]; then
            if ! mv "$dsh_dir" "$stash" 2>/dev/null; then
                cleanup_animation
                rm -rf "$temp_restore_dir"
                printf " 失败\n"
                err "无法暂存当前数据目录，已中止恢复（未做任何删除）"
                echo "  目标：$dsh_dir"
                return 1
            fi
            moved=1
        fi
        
        if ! tar -cf - -C "$temp_restore_dir" .dsh 2>/dev/null | tar -xf - -C "$HOME" 2>/dev/null; then
            restore_result=1
        fi
        
        # 解压出来的目录必须存在且非空，否则视为失败并回滚
        if [ $restore_result -eq 0 ] && [ ! -d "$dsh_dir" ]; then
            restore_result=1
        fi
        
        if [ $restore_result -ne 0 ]; then
            rm -rf "$dsh_dir" 2>/dev/null
            if [ $moved -eq 1 ]; then
                mv "$stash" "$dsh_dir" 2>/dev/null
                echo
                warn "恢复失败，已回滚到原数据"
            fi
        elif [ $moved -eq 1 ]; then
            rm -rf "$stash" 2>/dev/null
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
    else
        printf " 失败\n"
        err "恢复失败"
        return 1
    fi
}

# 查看备份列表
# 备份管理主菜单
backup_management() {
    title "管理备份列表"
    
    # 检查备份目录是否存在
    if [ ! -d "$BACKUP_DIR" ]; then
        warn "备份目录不存在"
        return 0
    fi
    
    # 列出所有备份文件
    local backup_files=($(ls -1 "$BACKUP_DIR"/*.tar.gz 2>/dev/null | grep -E "(dsh_sessions_backup|dsh_full_backup)" | sort -r))
    
    if [ ${#backup_files[@]} -eq 0 ]; then
        warn "没有找到备份文件"
        return 0
    fi
    
    # 显示备份列表
    echo "=== 备份文件列表 ==="
    printf "${BLD}%-5s %-40s %-10s %-20s${RST}\n" "序号" "文件名" "大小" "日期"
    echo "----------------------------------------------------------------------"
    
    for i in "${!backup_files[@]}"; do
        local file="${backup_files[$i]}"
        local filename=$(basename "$file")
        local filesize=$(du -h "$file" | cut -f1)
        local filedate=$(stat -c %y "$file" 2>/dev/null | cut -d' ' -f1,2 | cut -d'.' -f1)
        printf "%-5s %-40s %-10s %-20s\n" "$((i+1))" "$filename" "$filesize" "$filedate"
    done
    
    echo
    echo "总共 ${#backup_files[@]} 个备份文件"
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
        1) clean_backups_batch "${backup_files[@]}" ;;
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
    echo "=== 删除所有备份 ==="
    read -r -p "确认删除所有备份？(y/N): " CONFIRM
    
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        warn "操作已取消"
        return 0
    fi
    
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
    local backup_files=($(ls -1 "$BACKUP_DIR"/*.tar.gz 2>/dev/null | grep -E "(dsh_sessions_backup|dsh_full_backup)" | sort -r))
    
    if [ ${#backup_files[@]} -eq 0 ]; then
        warn "没有找到备份文件"
        return 1
    fi
    
    echo "可用的备份文件："
    echo
    for i in "${!backup_files[@]}"; do
        local file="${backup_files[$i]}"
        local filename=$(basename "$file")
        local filesize=$(du -h "$file" | cut -f1)
        echo "$((i+1)). $filename ($filesize)"
    done
    
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

# 备份与恢复管理（整合所有备份功能）
backup_restore_management() {
    title "备份与恢复管理"
    
    # 主循环
    while true; do
        clear 2>/dev/null
        echo "=== 备份与恢复管理 ==="
        echo
        echo "操作："
        echo "1. 备份对话记录"
        echo "2. 恢复对话记录"
        echo "3. 管理备份列表"
        echo "4. 测试备份恢复"
        echo "0. 返回"
        echo
        read -r -p "请选择操作： " choice || { echo; return 0; }
        
        case $choice in
            1)
                # 备份对话记录
                backup_sessions
                ;;
            2)
                # 恢复对话记录
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
    local profile="web"
    if [ -d "$HOME/.dsh/profiles" ]; then
        local profiles=$(ls -d "$HOME/.dsh/profiles"/*/ 2>/dev/null | xargs -n1 basename)
        if [ -n "$profiles" ]; then
            profile="web"
        fi
    fi
    echo "$profile"
}

# ========== 插件名解析 ==========
# pnpm list 输出形如 name@version；scoped 包是 @scope/name@version。
# 不能用 cut -d'@' -f1（对 scoped 包会得到空串，导致状态误判、
# 启用/禁用操作对象为空）。这里只剥掉"以数字开头的版本段"，
# 从而兼容 @scope/name（无版本）这类输入。
plugin_name_of() {
    printf '%s\n' "$1" | sed 's/@[0-9][^@]*$//'
}

# ========== JSON 编辑能力检测 ==========# 删除插件必须同步修改 package.json 的 dsh.profile.bundles，
# 否则 dependencies 已移除而 bundles 仍残留，DSH 启动会报
# cannot resolve profile bundle。优先 jq，退化到 python3。
json_tool() {
    if command -v jq >/dev/null 2>&1; then
        echo "jq"
        return 0
    fi
    if command -v python3 >/dev/null 2>&1; then
        echo "python3"
        return 0
    fi
    return 1
}

# 从 package.json 的 bundles 中移除指定包名
# 返回 0=成功  1=失败  2=无可用工具
remove_from_bundles() {
    local pkg="$1"
    local file="package.json"
    local tmp tool
    tmp=$(mktemp) || return 1
    tool=$(json_tool) || { rm -f "$tmp"; return 2; }
    
    if [ "$tool" = "jq" ]; then
        if jq --arg p "$pkg" '.dsh.profile.bundles |= map(select(. != $p))' "$file" > "$tmp" 2>/dev/null \
            && [ -s "$tmp" ] && mv "$tmp" "$file" 2>/dev/null; then
            return 0
        fi
        rm -f "$tmp"
        return 1
    fi
    
    # python3 兜底
    if python3 -c '
import json, sys
src, dst, pkg = sys.argv[1], sys.argv[2], sys.argv[3]
with open(src, encoding="utf-8") as f:
    data = json.load(f)
bundles = data.get("dsh", {}).get("profile", {}).get("bundles")
if isinstance(bundles, list):
    data["dsh"]["profile"]["bundles"] = [x for x in bundles if x != pkg]
with open(dst, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
    f.write("\n")
' "$file" "$tmp" "$pkg" 2>/dev/null && [ -s "$tmp" ] && mv "$tmp" "$file" 2>/dev/null; then
        return 0
    fi
    rm -f "$tmp"
    return 1
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
                    dsh plugin --profile "$profile" add "$PLUGIN_NAME"
                    if [ $? -eq 0 ]; then
                        info "安装成功：$PLUGIN_NAME"
                        echo "提示：可能需要重启 DSH 服务"
                    else
                        err "安装失败"
                    fi
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
            
            # 使用数组存储插件列表
            local plugins=()
            local index=1
            while IFS= read -r plugin; do
                if [ -n "$plugin" ]; then
                    plugins+=("$plugin")
                    # 检查插件状态（检查是否在 node_modules 中存在）
                    local plugin_name=$(plugin_name_of "$plugin")
                    local status="✅ 已启用"
                    if [ ! -d "node_modules/$plugin_name" ]; then
                        status="❌ 已禁用"
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
                    dsh plugin --profile "$profile" add "$PLUGIN_NAME"
                    if [ $? -eq 0 ]; then
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
                        
                        # 检查是否被禁用（重命名了）
                        if [ -d "node_modules/${plugin_short_name}.disabled" ]; then
                            mv "node_modules/${plugin_short_name}.disabled" "node_modules/$plugin_short_name" 2>/dev/null
                            if [ $? -eq 0 ]; then
                                info "插件已启用：$plugin_short_name"
                                echo "提示：可能需要重启 DSH 服务"
                            else
                                err "启用失败"
                            fi
                        elif [ -d "node_modules/$plugin_short_name" ]; then
                            warn "插件已经是启用状态"
                        else
                            err "插件不存在"
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
                        
                        # 检查是否已启用
                        if [ -d "node_modules/$plugin_short_name" ]; then
                            mv "node_modules/$plugin_short_name" "node_modules/${plugin_short_name}.disabled" 2>/dev/null
                            if [ $? -eq 0 ]; then
                                info "插件已禁用：$plugin_short_name"
                                echo "提示：可能需要重启 DSH 服务"
                            else
                                err "禁用失败"
                            fi
                        elif [ -d "node_modules/${plugin_short_name}.disabled" ]; then
                            warn "插件已经是禁用状态"
                        else
                            err "插件不存在"
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
                        # 先确认有 JSON 编辑工具。没有工具就绝不能动插件：
                        # pnpm remove 会清掉 dependencies，而 bundles 改不了，
                        # 结果是 DSH 启动时报 cannot resolve profile bundle。
                        if ! json_tool >/dev/null 2>&1; then
                            err "缺少 jq 或 python3，无法安全删除插件"
                            echo "  删除插件必须同步更新 package.json 的 bundles，"
                            echo "  否则 DSH 下次启动会报 cannot resolve profile bundle。"
                            echo "  请先安装其一后重试："
                            echo "    apt install -y jq        # Debian/Ubuntu"
                            echo "    dnf install -y jq        # Fedora/RHEL"
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
    echo "       1) 有正常时期的备份 → 菜单 13「恢复对话记录」"
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
        echo "  1. 有正常时期的备份 → 菜单 13「恢复对话记录」"
        echo "  2. 确认 DSH 已停止后再操作，避免写入中的文件被复制"
        echo "  3. 无法恢复的会话，可删除其会话目录后重新开始"
    else
        info "没有发现损坏的会话文件"
    fi
    
    echo
    echo "提示：本功能只检测、不修改任何会话文件。"
    echo "如需从备份恢复，请用菜单 13；操作前建议先停止服务："
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
        echo "  如需改用本脚本，请先用菜单 11 移除，或手动删除该行"
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

# ========== 菜单 ==========
menu() {
    clear 2>/dev/null
    
    # 标题部分 - 左对齐
    printf "${BLD}========== DSH‑WEB 管理面板 ==========${RST}\n"
    
    # 显示 DSH 安装状态
    if check_dsh_installed; then
        local VER
        VER=$(get_dsh_version)
        printf "DSH版本：${GRN}%s${RST}\n" "$VER"
    else
        printf "DSH状态：${RED}未安装${RST}\n"
    fi
    
    printf "当前服务：${GRN}%s${RST}\n" "$SVC"

    # 显示服务状态
    local UNIT="/etc/systemd/system/${SVC}.service"
    if [ -f "$UNIT" ]; then
        if is_run; then
            printf "运行状态：${GRN}运行中${RST}\n"
        else
            printf "运行状态：${RED}未运行${RST}\n"
        fi
    else
        printf "运行状态：${YEL}未初始化${RST}\n"
    fi

    echo
    echo "=== 服务管理 ==="
    echo "1. 启动"
    echo "2. 停止"
    echo "3. 重启"
    echo "4. 查看状态"
    echo
    echo "=== 访问与调试 ==="
    echo "5. 获取 Token 访问链接"
    echo "6. 查看实时日志"
    echo
    echo "=== 安装与配置 ==="
    echo "7. 初次初始化 Systemd 服务"
    echo "8. 修改 systemd 服务名称"
    echo "9. 卸载（服务/程序/管理脚本）"
    echo "10. 添加快捷命令到 .bashrc"
    echo "11. 移除快捷命令从 .bashrc"
    echo "12. 安装/更新 DSH 程序本体(npm)"
    echo
    echo "=== 备份与恢复 ==="
    echo "13. 备份与恢复管理"
    echo
    echo "=== 插件管理 ==="
    echo "14. 插件管理"
    echo
    echo "=== 会话维护 ==="
    echo "15. 扫描会话文件"
    echo
    echo "00. 更新管理脚本"
    echo
    echo "0. 退出脚本"
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
        1) start_svc ;;
        2) stop_svc ;;
        3) restart_svc ;;
        4) status_svc ;;
        5) get_url ;;
        6) show_logs ;;
        7) init_systemd ;;
        8) rename_svc ;;
        9) uninstall_management ;;
        10) add_alias_to_bashrc ;;
        11) remove_alias_from_bashrc ;;
        12) install_or_update_dsh ;;
        13) backup_restore_management ;;
        14) plugin_management ;;
        15) scan_and_fix_sessions ;;
        00) update_self ;;
        0) echo "已退出"; exit 0 ;;
        *) warn "无效选项" ;;
    esac

    echo
    printf "按回车继续..."
    read -r null || { echo; echo "已退出"; exit 0; }
done

