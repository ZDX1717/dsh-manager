# dsh-manager

DSH-Web 服务管理脚本。

## 安装

```bash
bash <(curl -sSL https://ZDX1717.github.io/dsh-manager/install.sh)
```

不需要加 `sudo`，安装器会自动提权。

其他等价写法：

```bash
# 管道
curl -sSL https://ZDX1717.github.io/dsh-manager/install.sh | bash

# 先下载再执行
curl -sSL https://ZDX1717.github.io/dsh-manager/install.sh -o /tmp/i.sh && bash /tmp/i.sh

# 备用地址（GitHub Pages 不通时用）
bash <(curl -sSL https://raw.githubusercontent.com/ZDX1717/dsh-manager/main/install.sh)
bash <(curl -sSL https://cdn.jsdelivr.net/gh/ZDX1717/dsh-manager@main/install.sh)
```

安装器选项：

| 选项 | 说明 |
|------|------|
| `-y`, `--yes` | 跳过确认，直接安装 |
| `--from-file PATH` | 使用本地 `dsh.sh` 安装（离线安装） |
| `--skip-verify` | 跳过 `dsh.sh` 的 SHA-256 校验 |
| `-h`, `--help` | 显示帮助 |

下载的 `dsh.sh` 会做 **SHA-256 校验**：镜像被篡改、或 CDN 返回旧缓存时会被识别并拒绝，自动改用下一个源。本地文件（`--from-file`）不做校验。

下载时**会自动按顺序切换源**，每个源都有限时（连接 8s / 总计 30s），不会一直卡住：

```
raw.githubusercontent.com  →  <owner>.github.io  →  cdn.jsdelivr.net@<commit SHA>  →  cdn.jsdelivr.net@main  →  自定义镜像
```

CDN 源用 commit SHA 寻址，保证拿到的是最新内容（jsDelivr 对分支的缓存可能滞后 12 小时）。也可用环境变量指定自己的镜像：

```bash
DSH_EXTRA_MIRRORS=https://your-mirror/prefix bash <(curl -sSL .../install.sh)
```

> ⚠️ 不要写成 `sudo bash <(curl ...)`。
> `<( )` 传的是进程私有的 `/dev/fd/N`，而 sudo 会关闭 3 及以上的 fd，
> root 的 bash 打不开该路径，会报 `bash: /dev/fd/63: No such file or directory`
> 和 `curl: (23) Failure writing output to destination`。去掉 `sudo` 即可。

> 📌 推送后 `raw.githubusercontent.com` 有 5 分钟 CDN 缓存，刚更新完可能取到旧内容。

安装后重新登录（或 `source ~/.bashrc`），用快捷命令 `d` 打开管理面板。

## 功能菜单

```
=== 服务管理 ===
1. 启动
2. 停止
3. 重启
4. 查看状态

=== 访问与调试 ===
5. 获取 Token 访问链接
6. 查看实时日志

=== 安装与配置 ===
7. 初次初始化 Systemd 服务
8. 修改 systemd 服务名称
9. 卸载 systemd 服务
10. 添加快捷命令到 .bashrc
11. 移除快捷命令从 .bashrc
12. 更新 DSH 程序本体(npm)

=== 备份与恢复 ===
13. 备份与恢复管理

=== 插件管理 ===
14. 插件管理

=== 会话维护 ===
15. 扫描会话文件

00. 更新管理脚本

0. 退出脚本
```
