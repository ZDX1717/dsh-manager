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
==== DSH-Web 管理面板 v1.12.0 ====

DSH   0.1.5-rc.2
服务  dsh-web  运行中
端口  3080   PID 12345

 1. 快速开始
 2. 启动
 3. 停止
 4. 重启
 5. 获取 Token 链接
 6. 状态与日志
 7. 插件管理
 8. 备份与恢复
 9. 维护工具
10. 卸载

00. 更新管理脚本
 0. 退出
```

菜单刻意不做说明文字、不加横向分割线：最宽一行 33 列，50 列的窄终端也不会换行；选项名本身够自解释，拿不准就按进去看，子菜单 `0` 一律返回。

第一次用只需要按 `1`：先体检并列出将要做的改动（含版本号），**确认后**才装 Node.js/npm → 装 DSH → 建 systemd 服务 → 启动 → 输出带 token 的访问链接；答 `n` 则一个字节都不改。脚本不会在你没点头的情况下安装或升级 DSH。

`6. 状态与日志` 一屏给出结论（运行正常 / 未运行 / 端口未监听），下面直接跟最近日志，可选实时日志或只看错误级别日志。

`8. 备份与恢复` 只负责**数据**，两档：

| 类型 | 内容 | 本机实测 |
|---|---|---|
| 1. 对话记录 | `sessions/` + `storages/workspace.json` + `storages/session_projcache/` | 约 16 MB |
| 2. 完整备份（不含插件） | `storages/`、`settings.yaml`、登录凭据、`attachments/`、`im/ integrations/ llm-*` | 约 60 MB |

**为什么"对话记录"不只备 `sessions/`**：会话正文里既没有标题，也没有工作区归属和归档状态：

| 你看到的东西 | 实际存在哪 |
|---|---|
| 对话内容 | `sessions/<工作区路径编码>/<会话 id>/session.v3.jsonl.zstd` |
| 属于哪个工作区 | `storages/workspace.json` → `tables.workspaces.<id>.sessionIds` |
| 是否已归档 | `storages/workspace.json` → `global.archivedSessionIds` |
| 对话标题 | `storages/session_projcache/sessions/<id>.json` → `rows.title` |

只备 `sessions/` 的话，恢复到别的机器后会出现三个症状：所有对话掉进「未分类」、
标题变成工作区名、已归档的对话重新冒出来。后两个文件加起来才 1.1 MB，所以第 1 档一并带上。

**跨机器恢复后工作区打不开怎么办**：工作区按**绝对路径**记录（如 `/root/DSH/文档`），
换服务器后这些目录通常不存在。DSH 不会删记录，只会把工作区标成不可用（`missing-dir`），
对话的归属照旧——所以能看到工作区、却打不开它。

`主菜单 9 → 5 补齐工作区目录` 会读 `storages/workspace.json`，列出当前机器上不存在的路径，
问你要不要建出来。建出来的是**空目录**（原目录里的文件本来就不在备份范围内），
但工作区能重新打开、里面的对话也照常显示。恢复流程跑完时会自动问一次。

恢复只覆盖同名文件、**不删除**目标端已有数据（有无 `rsync` 都是如此）。
若目标机已有工作区，覆盖前会把 `storages/workspace.json` 另存为 `.bak-<时间>`。

**为什么不备份插件代码**：插件是 registry 上随时可重新下载的派生品，不是不可替代的数据；
而且每个插件都用 `dsh.compatibility` / `peerDependencies` 声明了它支持的 DSH 版本范围，
把旧插件代码整包恢复到新 DSH 上，正是"插件忽然跑不起来"的主因
（典型表现是启动时报 `cannot resolve profile bundle`）。

## 备份插件列表（主菜单 7 → 5）

插件的备份放在**插件管理**里，备份的是「当时装了哪些插件、什么版本」，
约 1 KB 纯文本，**不含插件代码**。

打开就是列表，**输入编号直接看内容**，不用先选动作再选是哪一份：

```
==== 备份插件列表 ====
当前 DSH：0.1.5-rc.3

共 2 份备份（输入编号查看）：

   1. 2026-09-26 11:37   7 个插件
   2. 2026-09-26 01:23   7 个插件

b. 备份当前插件列表
0. 返回
```

进去看到的就是插件本体（`名称@版本`），有兼容声明的跟在后面：

```
==== 备份详情 ====
备份时间：2026-09-26 11:37:31
插件数量：7 个
备份时 DSH：0.1.5-rc.3
当前 DSH：0.1.5-rc.3

  @xmanrui/dsh-im@4.28.1
      声明兼容 0.1.7-alpha.1
  dsh-cost-meter@1.7.37
      声明兼容 >=0.1.0-rc.5
  ...

1. 按这份备份重装插件
2. 删除这份备份
0. 返回
```

- **主要用途是查看**：换机器或重装后照着这份列表装。DSH 版本不同时插件未必兼容，
  所以恢复是详情页里的一次显式选择（`1`），不是默认动作；版本不一致时页面会直接告警。
- 重装按**精确版本**（`dsh plugin --profile web add 名称@版本`），需要联网
  （registry 见 `~/.npmrc`）。**需要 pnpm**：`dsh plugin` 只是把参数转发给 pnpm，
  Node 自带的 npm 不含它。脚本会在动手前检查，缺了就问你要不要装
  （先试 `corepack enable pnpm`，不行再 `npm install -g pnpm`），
  不会让你对着七个"安装失败"发懵。
- 备份文件里另含装载顺序与 `cordis.patch.yml` 原文，供手动重建时查。

放在插件菜单而不是备份菜单的原因：这份列表只有 1 KB，
和大归档混在同一份列表里，会被「保留最近 N 个」这类保留策略顺手删掉；
而查看/重装插件本质就是插件的事，和「安装插件」在同一处。
