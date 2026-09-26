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

环境变量：`DSH_RAW_BASE`、`DSH_EXTRA_MIRRORS`、`DSH_INSTALL_DIR`、`DSH_LINK_DIR`、`DSH_GITHUB_API`。

安装后重新登录（或 `source ~/.bashrc`）即可用 `d` 打开管理面板。

## 功能菜单

```
==== DSH-Web 管理面板 v1.18.3 ====
DSH   0.1.5-rc.3  [已安装]
服务  dsh-web  [运行中]
端口  3080  PID 12345
------------------------------
命令行输入 d 可快速启动脚本
------------------------------
 1. 快速开始
 2. 启动服务
 3. 停止服务
 4. 重启服务
 5. 获取 Token 链接
 6. 状态与日志
 7. 插件管理
 8. 备份与恢复
 9. 维护工具
10. 卸载
------------------------------
00. 更新管理脚本
------------------------------
 0. 退出脚本
------------------------------
请输入选项：
```
