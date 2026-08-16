# v2x-downloader

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
![Shell](https://img.shields.io/badge/shell-bash-89e051.svg)
![rclone](https://img.shields.io/badge/requires-rclone%20%E2%89%A5%201.63-blue.svg)

[English](README.md) | **简体中文**

用于下载托管在 Google Drive 上的 V2X 自动驾驶公开数据集（DAIR-V2X 与 V2X-Seq），支持断点续传，并针对限流做了调优。

从 Google Drive 拉 141 GiB 数据，主要在跟两件事作斗争：传输中断和限流。这个脚本把 `rclone` 按这个场景配好 —— 中断后从断点继续，在 Google 限流之前先自我限流，下完再逐个文件做 MD5 校验。

## 为什么不用 gdown

下 Google Drive 通常首选 `gdown`，但它扛不住这个体量：大文件传输容易中断，而为恢复中断所做的多次重试，恰恰会触发 Google 的限流。`rclone` 原生支持续传，并且可以预先限制请求频率 —— 是绕开这个失败模式，而不是事后补救。

## 特性

- **断点续传** —— 随时中断，重跑同一条命令即可，已完成的文件自动跳过
- **限流友好** —— 主动限制 QPS，而不是撞上 403 之后再退避
- **完整性校验** —— 与远端比对 MD5，并为静默损坏的文件提供单独的修复路径
- **按需下载** —— 可只取某一个子数据集，不必下满 141 GiB
- **无头运行** —— 用 service account 认证，服务器上不需要浏览器
- **不侵入配置** —— 通过环境变量配置 rclone，绝不改动你的 `rclone.conf`

## 数据集构成

共 44 个文件，**141.3 GiB**，两个顶层目录：

| 目录 | 内容 |
|---|---|
| `DAIR-V2X (CVPR2022)` | DAIR-V2X-C / DAIR-V2X-I / DAIR-V2X-V，各含 Example 与 Full Dataset |
| `V2X-Seq (CVPR2023)` | Sequential-Perception-Dataset（含 test 集）、Trajectory-Forecasting-Dataset |

单文件最大 8.59 GiB。**大部分数据是分卷压缩包** —— `.z01`~`.z04` 与同名 `.zip` 属于同一份，缺任何一卷都解压不了，详见[解压分卷压缩包](#解压分卷压缩包)。

另有一个 `ReadMe.docx` 是 Google Docs 原生格式，在 `list` 里显示大小为 `-1`，属正常现象，下载时会自动导出为标准 `.docx`。

## 环境要求

- Ubuntu 22.04（或任意带 bash 的 Linux）；已在 Ubuntu 22 server 与 macOS 上测试
- `rclone` **≥ 1.63** —— 更早的版本不支持多线程下载
- 一个 Google 账号（任意账号均可，见[准备凭证](#准备凭证)）

## 安装 rclone

```bash
sudo -v ; curl https://rclone.org/install.sh | sudo bash
rclone version
```

Ubuntu apt 源里的 rclone 版本通常偏旧，建议用官方安装脚本。

## 准备凭证

目标文件夹的共享设置是「知道链接的任何人可查看」，因此**任意**通过认证的 Google 身份都能读取，不需要文件夹所有者给你额外授权。服务器上没有浏览器，用 service account 最省事。

### 方式 A：service account（推荐）

在任意一个你自己的 Google Cloud 项目里操作，全程只需一次：

1. 打开 https://console.cloud.google.com/ ，新建或选择一个项目
2. 启用 **Google Drive API**：https://console.cloud.google.com/apis/library/drive.googleapis.com
3. **IAM 和管理 → 服务账号 → 创建服务账号**，填个名字后一路点下去 —— **授予角色那一步留空**
4. 点进该服务账号 → **密钥 → 添加密钥 → 创建新密钥 → JSON** → 下载
5. 传到服务器：

```bash
scp service-account.json user@server:/etc/v2x/sa.json
ssh user@server 'chmod 600 /etc/v2x/sa.json'
```

角色留空是对的。IAM 角色管的是 Google Cloud 自家资源的访问权，而这里只是借这个身份通过认证，好去读一个公开共享的文件夹。它不消耗你的 Drive 配额。

> 如果你的组织策略禁止创建服务账号密钥（报错含 `iam.disableServiceAccountKeyCreation`），换个人 Google 账号即可 —— 这个项目纯粹用于认证，与数据归属无关。

### 方式 B：复用已有的 rclone remote

如果你已经配好了 Drive remote（比如叫 `gdrive`）：

```bash
RCLONE_REMOTE=gdrive ./download_v2x.sh download
```

注意 rclone 内置的 OAuth client ID 是全球所有 rclone 用户共用的，更容易撞上全局限流；service account 有独立配额。

## 使用

```bash
chmod +x download_v2x.sh

./download_v2x.sh check      # 验证凭证，统计文件数与总大小
./download_v2x.sh list       # 列出远端全部文件
./download_v2x.sh download   # 下载（默认命令）
./download_v2x.sh verify     # 与远端比对 MD5
```

跑全量时建议挂后台：

```bash
DEST_DIR=/data/v2x SA_FILE=/etc/v2x/sa.json \
  nohup ./download_v2x.sh download > /dev/null 2>&1 &

tail -f logs/download_*.log
```

**中断了？重跑同一条命令即可。** 脚本用的是 `rclone copy`，已完成的文件会跳过，本地文件永远不会被删除。

## 校验

```bash
./download_v2x.sh verify
```

与远端比对 MD5，差异写入 `logs/missing.txt` 和 `logs/differ.txt`，并打印对应的修复命令：

| 问题 | 修复方式 |
|---|---|
| 文件缺失 | `./download_v2x.sh download` |
| 文件存在但内容不一致 | `CHECKSUM=1 ./download_v2x.sh download` |

第二种情况值得说明：`rclone copy` 按 size + 修改时间判断是否需要重传。如果某个文件内容已损坏、但大小和修改时间仍与远端一致（例如磁盘静默错误），普通 `download` 会认为它已是最新而跳过，而 `verify` 则会一直报不一致。`CHECKSUM=1` 把比对方式切换为 MD5，这些文件才会真正被重新拉取。之所以不设为默认，是因为在这个体量的数据集上重算本地校验和很慢。

`ReadMe.docx` 没有 MD5（Google Docs 导出的字节不稳定），会被跳过而非校验，脚本在这种情况下会显式提示。

## 环境变量

| 变量 | 默认值 | 说明 |
|---|---|---|
| `DEST_DIR` | `./v2x-data` | 本地保存目录 |
| `SA_FILE` | `./service-account.json` | service account 凭证路径 |
| `RCLONE_REMOTE` | 空 | 改用已有的 rclone remote，设置后忽略 `SA_FILE` |
| `TRANSFERS` | `4` | 并发下载文件数 |
| `TPSLIMIT` | `8` | API 请求频率上限（QPS） |
| `BWLIMIT` | `off` | 带宽限速，如 `20M` |
| `INCLUDE` | 空 | 只下载匹配的路径，如 `'DAIR-V2X (CVPR2022)/**'` |
| `CHECKSUM` | `0` | 设为 `1` 时按 MD5 而非 size+修改时间比对 |
| `LOG_DIR` | `./logs` | 日志目录 |
| `FOLDER_ID` | 数据集文件夹 ID | 换成其他 Drive 文件夹时改这个 |

### 只下载部分内容

```bash
./download_v2x.sh list                                      # 先看有哪些文件
INCLUDE='DAIR-V2X (CVPR2022)/**' ./download_v2x.sh download
```

⚠️ **按文件名过滤时务必带上分卷。** `INCLUDE='**/single-vehicle-side-velodyne.zip'` 只会匹配到最后一卷，漏掉 `.z01`~`.z04`，下下来的 zip 根本解不开。正确写法是把整组匹配进来：

```bash
INCLUDE='**/single-vehicle-side-velodyne.*' ./download_v2x.sh download
```

## 解压分卷压缩包

`.z01`~`.z04` 加同名 `.zip`（`.zip` 是**最后**一卷）共同构成一份 WinZip 分卷压缩包。先装工具：

```bash
sudo apt update && sudo apt install -y zip p7zip-full
```

**方式一 —— 用 7z 直接处理分卷（推荐）：**

```bash
7z x single-vehicle-side-velodyne.zip
```

**方式二 —— 先合并再解压**（所有分卷需在同一目录）：

```bash
cd "DAIR-V2X (CVPR2022)/DAIR-V2X-V/Full Dataset (train&val)"
zip -s 0 single-vehicle-side-velodyne.zip --out combined.zip
unzip combined.zip
rm combined.zip
```

方式二的 `zip -s 0` 会生成一个与原始数据等大的合并文件，磁盘需预留约双倍空间；方式一没有这个问题。

## 限流说明

Google Drive 对单个身份有 QPS 和每日流量上限。脚本默认做了几件事来压住风险：

- `--tpslimit 8` 预先限制请求频率，比撞上 403 后再恢复划算
- `--fast-list` 一次性列出整棵目录树，把列表类 API 调用降到最低
- `--retries 10 --low-level-retries 20`，叠加 rclone 内置的指数退避

如果仍然频繁遇到 `rateLimitExceeded`，把并发调小：`TRANSFERS=2 TPSLIMIT=4 ./download_v2x.sh download`。

另外还存在**按文件计**的下载配额，与你的账号无关 —— 热门公开文件被大量下载后会被临时锁定。这种情况下换 service account 没用，只能等 24 小时。由于支持续传，已下载的部分不会重传。

## 安全

service account 密钥是长期有效的凭证，拿到它的人可以调用你项目上已启用的 Google Cloud API。

- `.gitignore` 已整体排除 `*.json`，避免密钥被误提交
- 保持 `chmod 600`
- 用完后在 Cloud Console 中吊销

## 免责声明

本仓库**只提供下载工具**，不托管、不镜像、不再分发任何数据。

数据集是其原作者的成果 —— DAIR-V2X（CVPR 2022）与 V2X-Seq（CVPR 2023）。其许可条款、允许的用途和引用要求由原作者规定，与本项目无关。使用数据前请查阅 Drive 文件夹内的 `ReadMe.docx` 及相应论文，并在成果中按要求引用。

## 许可证

[MIT](LICENSE)
