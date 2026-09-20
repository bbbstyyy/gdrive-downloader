# gdrive-downloader

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
![Shell](https://img.shields.io/badge/shell-bash-89e051.svg)
![rclone](https://img.shields.io/badge/requires-rclone%20%E2%89%A5%201.63-blue.svg)

[English](README.md) | **简体中文**

支持断点续传、对限流友好的 Google Drive 下载工具 —— **任意 Drive 链接**都能下：整个文件夹、单个文件、在线文档，并可选择走网络代理。

大文件传输失败通常就两个原因：连接中断，以及 Google 对发起请求的身份做限流。这个脚本针对的就是这两点 —— 用续传代替重来，用预先限速代替撞上 403 再补救；至于下的是什么内容，它并不关心：文件夹链接、`/file/d/<ID>` 单文件链接、Docs/Sheets/Slides 链接，同一条命令都能处理。

## 特性

- **任意 Drive 链接** —— 文件夹、`/file/d/<ID>`、旧式 `open?id=`、Docs/Sheets/Slides/Drawings、以及裸 ID
- **断点续传** —— 随时中断，重跑同一条命令即可，已完成的文件自动跳过
- **限流友好** —— 主动限制 QPS，而不是撞上 403 之后再退避
- **完整性校验** —— 与远端比对 MD5，并为静默损坏的文件提供单独的修复路径
- **代理支持** —— `--proxy`（或 `PROXY` 环境变量）同时作用于 rclone 与 curl 两条路径
- **单文件无需凭证** —— 公开的单文件链接走直链下载；只有文件夹链接才必须用 rclone
- **自动发现凭证** —— 当前目录里放着 service account 密钥即可，不需要任何参数
- **按需下载** —— 用 `--include` 只取需要的路径
- **无头运行** —— 用 service account 认证，服务器上不需要浏览器
- **不侵入配置** —— 通过环境变量配置 rclone，绝不改动你的 `rclone.conf`

### 为什么不用 gdown

下 Google Drive 通常首选 `gdown`，但它扛不住大体量：大文件传输容易中断，而为恢复中断所做的多次重试，恰恰会触发 Google 的限流。`rclone` 原生支持续传，并且可以预先限制请求频率 —— 是绕开这个失败模式，而不是事后补救。当然，单个小文件没必要这么做，脚本会对它直接走直链。

## 各类链接的处理方式

| 链接 | 走的路径 | 行为 |
|---|---|---|
| `drive.google.com/drive/folders/<ID>` | rclone | 整棵树下载，可续传、MD5 校验、多线程 |
| `drive.google.com/file/d/<ID>/view` | `rclone backend copyid`，失败时回退 curl 直链 | 可续传；没有凭证或指定 `--strategy curl` 时走直链 |
| `drive.google.com/open?id=<ID>`、裸 ID | 先探测一次 | 先尝试当文件夹列出，否则按单个文件处理（可用 `--type` 强制） |
| `docs.google.com/{document,spreadsheets,presentation,drawings}/d/<ID>` | curl | 导出为 `.docx` / `.xlsx` / `.pptx` / `.png`（`--format` 可改；带 `#gid=…` 的表格默认导出 `.csv`） |
| 上述任意链接带 `?resourcekey=…` | 两者 | resource key 会同时带给 rclone 与直链 |

## 仓库结构

| 路径 | 说明 |
|---|---|
| `gdrive-download.sh` | 下载器本体。真正需要的只有这一个文件。 |
| `README.md` · `README.zh-CN.md` | 文档：英文 / 简体中文 |
| `LICENSE` | MIT |

## 环境要求

- Ubuntu 22.04（或任意 bash 3.2+ 的 Linux / macOS）
- `rclone` **≥ 1.63** —— 文件夹链接需要它；单文件的续传路径（`backend copyid`）也需要；更早的版本不支持多线程下载
- `curl` —— 单文件回退路径与在线文档导出需要
- 一个 Google 账号（任意账号均可，见[准备凭证](#准备凭证)）—— 只有文件夹链接与 rclone 单文件路径需要

## 安装 rclone

```bash
sudo -v ; curl https://rclone.org/install.sh | sudo bash
rclone version
```

Ubuntu apt 源里的 rclone 版本通常偏旧，建议用官方安装脚本。

## 准备凭证

文件夹链接（以及需要凭证的单文件路径）只要求「任意一个通过认证的 Google 身份」，不需要文件夹所有者额外授权 —— 只要链接的共享设置是「知道链接的任何人可查看」。服务器上没有浏览器，用 service account 最省事。

### 凭证从哪里加载

按下面的顺序查找：

1. **`--sa FILE` 或环境变量 `SA_FILE`** —— 按给定的路径使用，找不到就到此为止：文件夹链接直接报错，单文件则回退到直链。
2. **当前目录下的 `./service-account.json`** —— 默认位置。
3. **当前目录下其它 service account 密钥** —— 默认文件名不存在时，脚本会扫一遍当前目录的 `*.json`，凡是内容里同时有 `"type": "service_account"` 与 `"private_key"` 的即视为密钥；只有恰好命中一个时才自动采用。命中多个则不猜，直接列出候选并提示你用 `--sa` 指定。

所以把密钥丢进你执行脚本的目录就够了，不必非叫 `service-account.json`。自动发现不会覆盖显式的 `--sa` / `SA_FILE`；指定了 `--remote <名字>` 时更是完全不加载 service account，控制权始终在你手里。

### 方式 A：service account（推荐）

在任意一个你自己的 Google Cloud 项目里操作，全程只需一次：

1. 打开 https://console.cloud.google.com/ ，新建或选择一个项目
2. 启用 **Google Drive API**：https://console.cloud.google.com/apis/library/drive.googleapis.com
3. **IAM 和管理 → 服务账号 → 创建服务账号**，填个名字后一路点下去 —— **授予角色那一步留空**
4. 点进该服务账号 → **密钥 → 添加密钥 → 创建新密钥 → JSON** → 下载
5. 把密钥放到脚本会自动查找的位置 —— 最省事的就是你执行脚本的那个目录：

```bash
mv ~/Downloads/service-account.json ./service-account.json
chmod 600 ./service-account.json
```

如果更愿意放在项目外的固定位置，也可以放过去再用 `--sa` 指过去（或导出 `SA_FILE`）：

```bash
scp service-account.json user@server:/etc/gdrive/sa.json
ssh user@server 'chmod 600 /etc/gdrive/sa.json'
# 之后：./gdrive-download.sh download '<链接>' --sa /etc/gdrive/sa.json
```

角色留空是对的。IAM 角色管的是 Google Cloud 自家资源的访问权，而这里只是借这个身份通过认证，好去读一个公开共享的文件夹。它不消耗你的 Drive 配额。

> 如果你的组织策略禁止创建服务账号密钥（报错含 `iam.disableServiceAccountKeyCreation`），换个人 Google 账号即可 —— 这个项目纯粹用于认证，与数据归属无关。

### 方式 B：复用已有的 rclone remote

如果你已经配好了 Drive remote（比如叫 `gdrive`）：

```bash
./gdrive-download.sh download '<链接>' --remote gdrive
```

注意 rclone 内置的 OAuth client ID 是全球所有 rclone 用户共用的，更容易撞上全局限流；service account 有独立配额。

## 使用

```bash
chmod +x gdrive-download.sh

./gdrive-download.sh download '<链接>'          # 下载（默认命令）
./gdrive-download.sh check    '<链接>'          # 验证凭证，打印远端信息
./gdrive-download.sh list     '<链接>'          # 列出远端内容
./gdrive-download.sh verify   '<链接>'          # 校验本地与远端是否一致
./gdrive-download.sh info     '<链接>'          # 只解析链接，不下载、不需要凭证
```

所有参数都既可用命令行选项、也可用环境变量给出；`./gdrive-download.sh -h` 可查看完整列表。

```bash
# 文件夹链接，下到 /data/gdrive；当前目录里有密钥就自动用
DEST_DIR=/data/gdrive nohup ./gdrive-download.sh download \
  'https://drive.google.com/drive/folders/<FOLDER_ID>' > /dev/null 2>&1 &
tail -f logs/download_*.log

# 文件夹链接，密钥放在别处
SA_FILE=/etc/gdrive/sa.json ./gdrive-download.sh download '<文件夹链接>'

# 单个公开文件：完全不需要凭证
./gdrive-download.sh download 'https://drive.google.com/file/d/<FILE_ID>/view' -d ./data

# 在线文档，指定导出文件名
./gdrive-download.sh download 'https://docs.google.com/document/d/<DOC_ID>/edit' -n readme.docx
```

**中断了？重跑同一条命令即可。** 文件夹走 `rclone copy`，单文件走 HTTP Range 续传，所以已完成的数据会跳过，本地文件永远不会被删除（没有 `sync`，也没有 `--delete`）。

### 网络代理

```bash
./gdrive-download.sh download '<链接>' --proxy http://127.0.0.1:7890
./gdrive-download.sh download '<链接>' --proxy socks5h://127.0.0.1:1080   # 单文件 / 在线文档
PROXY=http://user:pass@10.0.0.1:3128 ./gdrive-download.sh download '<链接>'
./gdrive-download.sh download '<链接>' --no-proxy    # 忽略环境变量里的代理
```

两个引擎会同时生效：rclone 用 `--http-proxy`，curl 用 `--proxy`。参数里若不写 `http://` 前缀，会按「主机:端口」补成 `http://`。

两点说明：

- **文件夹链接需要 HTTP(S) 代理。** rclone 的全局 `--http-proxy` 是 HTTP 代理设置，文件夹下载请配 HTTP/HTTPS 代理。
- **socks5 只作用于 curl 路径** —— 单文件与在线文档导出可以用（`socks5://` 在本地解析域名，`socks5h://` 交给代理解析，通常用后者）。

另外，两个工具本身都认 `HTTP_PROXY` / `HTTPS_PROXY` 环境变量，所以机器级别的代理设置不加任何参数也能生效。

## 校验

```bash
./gdrive-download.sh verify '<链接>'
```

**文件夹**会与远端比对 MD5，差异写入 `logs/missing.txt` 和 `logs/differ.txt`，并打印对应的修复命令：

| 问题 | 修复方式 |
|---|---|
| 文件缺失 | `./gdrive-download.sh download '<链接>'` |
| 文件存在但内容不一致 | `CHECKSUM=1 ./gdrive-download.sh download '<链接>'` |

第二种情况值得说明：`rclone copy` 按 size + 修改时间判断是否需要重传。如果某个文件内容已损坏、但大小和修改时间仍与远端一致（例如磁盘静默错误），普通 `download` 会认为它已是最新而跳过，而 `verify` 则会一直报不一致。`CHECKSUM=1` 把比对方式切换为 MD5，这些文件才会真正被重新拉取。之所以不设为默认，是因为在体量较大的下载上重算本地校验和很慢。

**单个文件**或**在线文档导出**的校验则是对比本地大小与远端的 `Content-Length`，并打印本地 MD5 —— 单文件没有便宜的办法拿到远端 MD5（那需要一次 Drive API 调用），所以逐字节的可靠性依赖 `copyid` 路径上 rclone 自身的传输后哈希校验。怀疑某个单文件有问题时，用 `download --overwrite` 重下一次。

## 选项与环境变量

| 选项 | 变量 | 默认值 | 说明 |
|---|---|---|---|
| `<链接>` | `LINK` / `URL` / `GDRIVE_URL` | — | 要处理的 Drive 链接或裸 ID |
| `-d, --dest` | `DEST_DIR` | `./downloads` | 本地保存目录 |
| `-p, --proxy` | `PROXY` | 空 | 代理地址，如 `http://127.0.0.1:7890`、`socks5h://127.0.0.1:1080` |
| `--no-proxy` | — | 关 | 忽略环境变量里的 `HTTP_PROXY` / `HTTPS_PROXY` |
| `-n, --name` | `NAME` | 自动 | 输出文件名（单文件 / 在线文档导出） |
| `-f, --format` | `FORMAT` | 按文档类型 | 在线文档导出格式：`docx`、`xlsx`、`pptx`、`pdf`、`csv`、`png` |
| `--sa` | `SA_FILE` | `./service-account.json`，或自动发现的密钥 | service account 凭证路径；显式给出的值不会被自动发现覆盖 |
| `--remote` | `RCLONE_REMOTE` | 空 | 改用已有的 rclone remote，设置后忽略 `SA_FILE` |
| `--type` | `KIND_OVERRIDE` | 自动 | 链接有歧义时强制 `folder` 或 `file` |
| `--strategy` | `STRATEGY` | `auto` | 单文件下载路径：`auto` / `rclone` / `curl` |
| `--include` | `INCLUDE` | 空 | 只下载匹配的路径（仅文件夹链接） |
| `--threads` | `TRANSFERS` | `4` | 并发下载文件数 |
| `--tpslimit` | `TPSLIMIT` | `8` | API 请求频率上限（QPS） |
| `--bwlimit` | `BWLIMIT` | `off` | 带宽限速，如 `20M` |
| `--checksum` | `CHECKSUM` | `0` | 按 MD5 而非 size+修改时间比对（文件夹链接） |
| `--overwrite` | `OVERWRITE` | `0` | 本地已有同名同大小文件时也重新下载 |
| `--log-dir` | `LOG_DIR` | `./logs` | 日志与 cookie/探测临时文件目录 |

## 只下载部分内容（文件夹链接）

```bash
./gdrive-download.sh list '<文件夹链接>'                              # 先看有哪些文件
./gdrive-download.sh download '<文件夹链接>' --include 'photos/**'
```

⚠️ **按文件名过滤时务必带上分卷。** 如果远端把某个压缩包拆成 `name.z01`~`name.zNN` 加同名 `name.zip`（`.zip` 是**最后**一卷），那么 `--include '**/name.zip'` 只会匹配到最后一卷，下下来的 zip 根本解不开。正确写法是把整组匹配进来：

```bash
./gdrive-download.sh download '<文件夹链接>' --include '**/name.*'
```

这类分卷包用 `7z x name.zip`（来自 `p7zip-full`）可直接解；也可以先合并再解：`zip -s 0 name.zip --out combined.zip && unzip combined.zip`（合并会生成一份等大的文件，需预留约双倍磁盘空间）。

## 限流说明

Google Drive 对单个身份有 QPS 和每日流量上限。脚本默认做了几件事来压住风险：

- `--tpslimit 8` 预先限制请求频率，比撞上 403 后再恢复划算
- `--fast-list` 一次性列出整棵目录树，把列表类 API 调用降到最低
- `--retries 10 --low-level-retries 20`，叠加 rclone 内置的指数退避

如果仍然频繁遇到 `rateLimitExceeded`，把并发调小：`--threads 2 --tpslimit 4`。

另外还存在**按文件计**的下载配额，与你的账号无关 —— 热门公开文件被大量下载后会被临时锁定。这种情况下换 service account 没用，只能等 24 小时。由于支持续传，已下载的部分不会重传。单文件的 curl 路径能识别这种情况并明确报错，而不是把一张 HTML 错误页写进磁盘。

## 安全

service account 密钥是长期有效的凭证，拿到它的人可以调用你项目上已启用的 Google Cloud API。

- `.gitignore` 已整体排除 `*.json`，避免密钥被误提交 —— 包括自动发现到的那个
- 保持 `chmod 600`
- 用完后在 Cloud Console 中吊销

代理地址里可能带有账号密码，请用 `--proxy` 或 `PROXY` 传入，不要写进要提交的脚本里。

## 免责声明

本仓库**只提供下载工具**，不托管、不镜像、不再分发任何数据。

你让脚本去取的任何内容，版权与使用条款都由其发布方规定，与本项目无关。使用前请自行确认相关条款。

## 许可证

[MIT](LICENSE)
