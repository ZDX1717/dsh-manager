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
raw.githubusercontent.com  →  <owner>.github.io  →  cdn.jsdelivr.net@<commit SHA>
  →  cdn.jsdelivr.net@main  →  自建镜像 github.zdx1717.ccwu.cc  →  自定义镜像
```

自建镜像排在内置源末尾：多数网络根本走不到它，只有前面全不通时才启用；
即使内容被篡改，也会被 SHA-256 门禁拦下，不会装入未知内容。

CDN 源用 commit SHA 寻址，保证拿到的是最新内容（jsDelivr 对分支的缓存可能滞后 12 小时）。也可用环境变量指定自己的镜像：

```bash
DSH_EXTRA_MIRRORS=https://your-mirror/prefix bash <(curl -sSL .../install.sh)
```

国内网络下可直接把自建镜像提为主源（最快）：

```bash
DSH_RAW_BASE=https://github.zdx1717.ccwu.cc/raw/ZDX1717/dsh-manager/main \
DSH_GITHUB_API=https://github.zdx1717.ccwu.cc/proxy/api.github.com \
  bash install.sh
```

`DSH_GITHUB_API` 只影响 commit SHA 的解析；若网络屏蔽 `api.github.com`，用它指向自建镜像即可恢复 jsDelivr@SHA 备用源。

> ⚠️ 不要写成 `sudo bash <(curl ...)`。
> `<( )` 传的是进程私有的 `/dev/fd/N`，而 sudo 会关闭 3 及以上的 fd，
> root 的 bash 打不开该路径，会报 `bash: /dev/fd/63: No such file or directory`
> 和 `curl: (23) Failure writing output to destination`。去掉 `sudo` 即可。

> 📌 推送后 `raw.githubusercontent.com` 有 5 分钟 CDN 缓存，刚更新完可能取到旧内容。

安装后重新登录（或 `source ~/.bashrc`），用快捷命令 `d` 打开管理面板。

## 功能菜单

```
=========== DSH-Web 管理面板 v1.5.1 ===========
DSH 0.1.5-rc.2 ｜ dsh-web [运行中] ｜ 端口 3080 ｜ PID 12345

 1. 快速开始              安装 / 初始化 / 启动，一步到位

 2. 启动      3. 停止      4. 重启
 5. 获取 Token 链接      6. 状态与日志

 7. 插件管理              启用 / 禁用 / 删除
 8. 备份与恢复            最小 / 完整备份、恢复、清理
 9. 维护工具              服务名 / 快捷命令 / Node 环境 / 会话修复
10. 卸载                  服务 / DSH 程序 / 本管理脚本

00. 更新管理脚本
 0. 退出
```

第一次用只需要按 `1`：先体检并列出将要做的改动（含版本号），**确认后**才装 Node.js/npm → 装 DSH → 建 systemd 服务 → 启动 → 输出带 token 的访问链接；答 `n` 则一个字节都不改。脚本不会在你没点头的情况下安装或升级 DSH。

`6. 状态与日志` 一屏给出结论（运行正常 / 未运行 / 端口未监听），下面直接跟最近日志，可选实时日志或只看错误级别日志。
