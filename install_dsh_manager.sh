#!/bin/bash

# DSH 管理脚本一键安装器
#
# 推荐安装方式（先下载再执行，最稳）：
#   curl -sSL https://raw.githubusercontent.com/ZDX1717/dsh-manager/main/install_dsh_manager.sh -o /tmp/dsh_install.sh
#   sudo bash /tmp/dsh_install.sh
#
# 也支持管道方式（脚本会自动从 /dev/tty 读取确认）：
#   curl -sSL https://raw.githubusercontent.com/ZDX1717/dsh-manager/main/install_dsh_manager.sh | sudo bash
#
# 注意：不要用 `sudo bash <(curl ...)`，sudo 下 /dev/fd 不可用会报
#       "/dev/fd/63: No such file or directory"。

set -e

# 颜色定义
RST='\033[0m'
RED='\033[31m'
GRN='\033[32m'
YEL='\033[33m'
BLD='\033[1m'

# 输出函数
info()  { printf "${GRN}${BLD}[完成]${RST} %s\n" "$1"; }
warn()  { printf "${YEL}${BLD}[提示]${RST} %s\n" "$1"; }
err()   { printf "${RED}${BLD}[错误]${RST} %s\n" "$1"; }
title() { printf "\n${BLD}==== %s ====${RST}\n" "$1"; }

# 交互确认：管道执行时 stdin 是脚本内容，必须改从 /dev/tty 读，
# 否则会把脚本文本当成用户输入吃掉。
# 注意：不能只用 [ -r /dev/tty ] 判断——该文件可能存在但打不开
# （容器/无控制终端环境），这里用真实打开来探测。
confirm() {
    local prompt="$1" answer=""
    if [ -t 0 ]; then
        read -r -p "$prompt" answer || answer=""
    elif { true; } 2>/dev/null < /dev/tty; then
        read -r -p "$prompt" answer < /dev/tty
    else
        warn "非交互环境，默认继续安装（如需取消请用 Ctrl+C）"
        answer="y"
    fi
    [[ "$answer" =~ ^[Yy]$ ]]
}

# 配置
INSTALL_DIR="/usr/local/bin"
SCRIPT_NAME="dsh-manager"
GITHUB_REPO="ZDX1717/dsh-manager"
SCRIPT_URL="https://raw.githubusercontent.com/$GITHUB_REPO/main/dsh.sh"

# 检查 root 权限
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        err "请使用 root 权限运行此脚本"
        echo "使用方法：sudo bash $0"
        exit 1
    fi
}

# 检查依赖
check_dependencies() {
    echo "检查依赖..."
    
    # 检查 curl
    if ! command -v curl >/dev/null 2>&1; then
        warn "未找到 curl，正在安装..."
        if command -v apt >/dev/null 2>&1; then
            apt update -y && apt install -y curl
        elif command -v yum >/dev/null 2>&1; then
            yum install -y curl
        elif command -v dnf >/dev/null 2>&1; then
            dnf install -y curl
        else
            err "无法安装 curl，请手动安装"
            exit 1
        fi
    fi
    
    # 检查 jq
    if ! command -v jq >/dev/null 2>&1; then
        warn "未找到 jq，正在安装..."
        if command -v apt >/dev/null 2>&1; then
            apt update -y && apt install -y jq
        elif command -v yum >/dev/null 2>&1; then
            yum install -y jq
        elif command -v dnf >/dev/null 2>&1; then
            dnf install -y jq
        else
            err "无法安装 jq，请手动安装"
            exit 1
        fi
    fi
    
    info "依赖检查完成"
}

# 下载脚本
download_script() {
    title "下载 DSH 管理脚本"
    
    echo "正在从 GitHub 下载脚本..."
    echo "URL: $SCRIPT_URL"
    
    # 创建临时目录
    local temp_dir=$(mktemp -d)
    local temp_file="$temp_dir/dsh.sh"
    
    # 下载脚本
    if curl -sSL "$SCRIPT_URL" -o "$temp_file" 2>/dev/null; then
        # 验证下载的文件
        if [ -s "$temp_file" ] && head -n1 "$temp_file" | grep -q "#!/bin/bash"; then
            info "脚本下载成功"
            
            # 复制到安装目录
            cp "$temp_file" "$INSTALL_DIR/$SCRIPT_NAME"
            chmod +x "$INSTALL_DIR/$SCRIPT_NAME"
            
            # 清理临时文件
            rm -rf "$temp_dir"
            
            return 0
        else
            err "下载的文件无效"
            rm -rf "$temp_dir"
            return 1
        fi
    else
        err "下载失败"
        rm -rf "$temp_dir"
        return 1
    fi
}

# 创建符号链接
create_symlink() {
    title "创建符号链接"
    
    # 创建符号链接
    ln -sf "$INSTALL_DIR/$SCRIPT_NAME" "/usr/bin/$SCRIPT_NAME" 2>/dev/null
    
    # 添加到 PATH（如果需要）
    if ! echo "$PATH" | grep -q "$INSTALL_DIR"; then
        echo "export PATH=\"$INSTALL_DIR:\$PATH\"" >> /etc/profile.d/dsh-manager.sh
        info "已添加到 PATH"
    fi
    
    info "符号链接创建成功"
}

# 配置别名
setup_alias() {
    title "配置快捷命令"
    
    # 添加到 .bashrc
    local BASHRC="$HOME/.bashrc"
    local ALIAS_LINE="alias d='dsh-manager'"
    local ALIAS_COMMENT="# DSH 管理脚本快捷命令"
    
    if [ -f "$BASHRC" ]; then
        # 检查是否已存在别名
        if ! grep -q "alias d='dsh-manager'" "$BASHRC" 2>/dev/null; then
            echo "" >> "$BASHRC"
            echo "$ALIAS_COMMENT" >> "$BASHRC"
            echo "$ALIAS_LINE" >> "$BASHRC"
            info "已添加快捷命令到 .bashrc"
        else
            warn "快捷命令已存在"
        fi
    fi
    
    # 添加到 .profile
    local PROFILE="$HOME/.profile"
    if [ -f "$PROFILE" ]; then
        if ! grep -q "alias d='dsh-manager'" "$PROFILE" 2>/dev/null; then
            echo "" >> "$PROFILE"
            echo "$ALIAS_COMMENT" >> "$PROFILE"
            echo "$ALIAS_LINE" >> "$PROFILE"
            info "已添加快捷命令到 .profile"
        fi
    fi
}

# 显示安装信息
show_info() {
    title "安装完成"
    
    echo "DSH 管理脚本已成功安装！"
    echo
    echo "使用方法："
    echo "  1. 直接运行：$SCRIPT_NAME"
    echo "  2. 使用快捷命令：d"
    echo "  3. 使用完整命令：dsh-manager"
    echo
    echo "首次使用："
    echo "  请重新加载 shell 配置：source ~/.bashrc"
    echo "  或重新登录终端"
    echo
    echo "功能说明："
    echo "  - DSH 服务管理（启动、停止、重启）"
    echo "  - 插件管理（安装、启用、禁用、删除）"
    echo "  - 备份与恢复"
    echo "  - 会话维护"
    echo
    echo "更新方法："
    echo "  运行脚本后选择 '更新 DSH 程序本体(npm)'"
    echo
    echo "卸载方法："
    echo "  sudo rm -f $INSTALL_DIR/$SCRIPT_NAME /usr/bin/$SCRIPT_NAME"
    echo "  sudo rm -f /etc/profile.d/dsh-manager.sh"
    echo "  从 .bashrc 和 .profile 中删除别名行"
}

# 主函数
main() {
    title "DSH 管理脚本安装器"
    
    # 检查 root 权限
    check_root
    
    echo "此脚本将安装 DSH 管理脚本到您的系统"
    echo
    echo "安装位置：$INSTALL_DIR/$SCRIPT_NAME"
    echo "快捷命令：d"
    echo
    
    if ! confirm "确认安装？(y/N): "; then
        warn "安装已取消"
        exit 0
    fi
    
    # 检查依赖
    check_dependencies
    
    # 下载脚本
    if ! download_script; then
        err "安装失败"
        exit 1
    fi
    
    # 创建符号链接
    create_symlink
    
    # 配置别名
    setup_alias
    
    # 显示安装信息
    show_info
}

# 运行主函数
main