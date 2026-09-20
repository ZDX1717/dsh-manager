# dsh-manager

DSH-Web 服务管理脚本。基于 systemd 管理 DSH 服务，并提供插件管理、备份恢复、会话维护等功能。

## 一键安装

```bash
curl -sSL https://raw.githubusercontent.com/ZDX1717/dsh-manager/main/install_dsh_manager.sh -o /tmp/dsh_install.sh && sudo bash /tmp/dsh_install.sh
```

也支持管道方式（脚本会自动从 `/dev/tty` 读取确认）：

```bash
curl -sSL https://raw.githubusercontent.com/ZDX1717/dsh-manager/main/install_dsh_manager.sh | sudo bash
```

> ⚠️ 不要用 `sudo bash <(curl -sSL ...)`。
> `sudo` 下 `/dev/fd/63` 不可访问，会报
> `bash: /dev/fd/63: No such file or directory` 和 `curl: (23) Failure writing output to destination`。
> 这是进程替换与 sudo 的兼容问题，不是脚本本身的问题。

安装完成后可直接使用快捷命令 `d` 打开管理面板。

## 手动安装

```bash
# 下载脚本
sudo curl -sSL https://raw.githubusercontent.com/ZDX1717/dsh-manager/main/dsh.sh -o /usr/local/bin/dsh-manager

# 添加执行权限
sudo chmod +x /usr/local/bin/dsh-manager

# 运行
sudo dsh-manager
```

## 功能菜单

```
1. 启动                    服务管理
2. 停止
3. 重启
4. 查看状态
5. 获取 Token 访问链接      访问与调试
6. 查看实时日志
7. 初次初始化 Systemd 服务   安装与配置
8. 修改 systemd 服务名称
9. 卸载 systemd 服务
10. 添加快捷命令到 .bashrc
11. 移除快捷命令从 .bashrc
12. 更新 DSH 程序本体(npm)
13. 备份与恢复管理          备份与恢复
14. 插件管理               插件管理
15. 扫描并修复会话文件       会话维护
0. 退出脚本
```

## 功能说明

### 服务管理
通过 systemd 管理 `dsh-web` 服务，支持启动、停止、重启和状态查看。首次使用需先执行「初次初始化 Systemd 服务」创建服务单元。

### 访问与调试
- **获取 Token 访问链接**：从 journalctl 日志中抓取带 token 的本地访问链接
- **查看实时日志**：实时跟踪服务日志，Ctrl+C 退出

### 安装与配置
- **初始化 Systemd 服务**：自动生成 `/etc/systemd/system/dsh-web.service`
- **修改服务名称**：重命名服务单元，并同步更新脚本内配置
- **快捷命令**：一键添加或移除 `d` 命令别名

### 备份与恢复管理
提供四种操作：

| 操作 | 说明 |
|------|------|
| 备份对话记录 | 支持最小备份和完整备份 |
| 恢复对话记录 | 从备份文件恢复数据 |
| 管理备份列表 | 查看、批量清理、按序号删除备份 |
| 测试备份恢复 | 校验备份文件完整性和可解压性 |

**最小备份与完整备份的区别：**

| 项目 | 最小备份 | 完整备份 |
|------|----------|----------|
| 会话数据 sessions/ | 包含 | 包含 |
| 工作区配置 storages/ | 包含 | 包含 |
| 插件配置 | 包含 | 包含 |
| 插件包 node_modules | 包含 | 包含 |
| 缓存/日志 | 不包含 | 不包含 |

> 备份文件默认存放在 `~/.dsh/backups/`。

> **建议**：备份和恢复前先停止 DSH 服务，避免会话日志文件在写入过程中被复制导致损坏。
> ```bash
> systemctl stop dsh-web     # 备份/恢复前
> systemctl restart dsh-web  # 操作完成后
> ```

### 插件管理
基于 pnpm 的插件管理，支持：

- 查看插件列表及当前状态（✅ 已启用 / ❌ 已禁用）
- 安装插件
- 启用 / 禁用插件
- 删除插件（支持批量，输入序号空格分隔，如 `1 3 5`）

> 删除插件时会同步从 `package.json` 的 `dsh.profile.bundles` 中移除，避免 DSH 启动时报 `cannot resolve profile bundle` 错误。

### 会话维护
扫描所有会话日志文件，检查完整性和文件大小，标记可能损坏的会话。

## 环境要求

- Linux（使用 systemd）
- Bash 4.0+
- 可选依赖：`rsync`（更安全的文件复制）、`jq`（修改插件配置）、`zstd`（会话文件完整性校验）

## 卸载

```bash
# 卸载 systemd 服务（保留 DSH 程序本体）
sudo dsh-manager   # 选择 9. 卸载 systemd 服务

# 删除管理脚本
sudo rm -f /usr/local/bin/dsh-manager
sudo rm -f /etc/profile.d/dsh-manager.sh

# 清理快捷命令
sed -i '/# DSH 管理脚本快捷命令/d' ~/.bashrc
sed -i "/alias d='dsh-manager'/d" ~/.bashrc
```

## 更新管理脚本

```bash
sudo curl -sSL https://raw.githubusercontent.com/ZDX1717/dsh-manager/main/dsh.sh -o /usr/local/bin/dsh-manager
sudo chmod +x /usr/local/bin/dsh-manager
```

## 许可

MIT
