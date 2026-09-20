#!/usr/bin/env bash
#
# gdrive-download.sh —— 从任意 Google Drive 链接获取 / 下载内容
#
# 四种链接形态都支持(均可带 ?resourcekey=...):
#   文件夹      https://drive.google.com/drive/folders/<ID>?usp=sharing
#   单个文件    https://drive.google.com/file/d/<ID>/view?usp=sharing
#   旧式/其它   https://drive.google.com/open?id=<ID>  ·  .../uc?id=<ID>  ·  裸 ID
#   在线文档    https://docs.google.com/{document,spreadsheets,presentation,drawings}/d/<ID>/edit
#
# 三条下载路径,按链接类型自动选择:
#   文件夹   -> rclone(断点续传 / 限流 / MD5 校验 / 多线程)     —— 复用原有能力
#   单文件   -> rclone backend copyid(可续传,传完比对 MD5),无凭证时回退 curl 直链
#   在线文档 -> curl 导出为 docx / xlsx / pptx / png / pdf
#
# 用法:
#   ./gdrive-download.sh [命令] [选项] <链接或 ID>
#   ./gdrive-download.sh -h          # 查看全部选项
#
# 详细说明见 README.md
#

set -euo pipefail

PROG="$(basename "$0")"

# ---------------------------------------------------------------- 默认配置
LINK_INPUT="${LINK:-${URL:-${GDRIVE_URL:-}}}"
[[ -z "$LINK_INPUT" && -n "${FOLDER_ID:-}" ]] && LINK_INPUT="${FOLDER_ID}"
DEFAULT_LINK="${DEFAULT_LINK:-}"     # 调用方可预置的默认链接(如自己的包装脚本),优先级低于命令行参数

DEST_DIR="${DEST_DIR:-./downloads}"

# 凭证查找顺序: --sa / 环境变量 SA_FILE(显式) > 当前目录下的 ./service-account.json
#               > 当前目录下唯一一个 service account 密钥(自动发现,见 resolve_sa_file)
SA_FILE_EXPLICIT=0
if [[ -n "${SA_FILE:-}" ]]; then SA_FILE_EXPLICIT=1; fi
SA_FILE="${SA_FILE:-./service-account.json}"

LOG_DIR="${LOG_DIR:-./logs}"

# 并发与限流: Drive 对单账号有 QPS 上限,调高 TRANSFERS 反而更容易触发 403 rateLimitExceeded
TRANSFERS="${TRANSFERS:-4}"
CHECKERS="${CHECKERS:-8}"
TPSLIMIT="${TPSLIMIT:-8}"
BWLIMIT="${BWLIMIT:-off}"

# 只下载部分子目录时设置,例如 INCLUDE='photos/**'
# 注意:若目标里的压缩包是分卷的(.z01~.zNN 与同名的 .zip 同属一份),过滤时必须把同名分卷全部包含,否则解压不了
INCLUDE="${INCLUDE:-}"

# 1=按 MD5 比对而非 size+modtime。修复"大小相同但内容已损坏"的文件时必须开启,代价是要重算本地校验和
CHECKSUM="${CHECKSUM:-0}"

RCLONE_REMOTE="${RCLONE_REMOTE:-}"   # 不用 service account 时,指定已有的 rclone remote 名

# 新增:通用部分
PROXY="${PROXY:-}"                   # 网络代理,如 http://127.0.0.1:7890 / socks5h://127.0.0.1:1080
NO_PROXY_MODE=0                      # 1=忽略环境变量中的代理设置
NAME="${NAME:-}"                     # 单文件/在线文档模式的输出文件名
FORMAT="${FORMAT:-}"                 # 在线文档导出格式,默认 docx/xlsx/pptx/png
STRATEGY="${STRATEGY:-auto}"         # auto | rclone | curl —— 单文件下载走哪条路径
KIND_OVERRIDE="${KIND_OVERRIDE:-}"   # 链接类型有歧义时手动指定: folder | file
OVERWRITE="${OVERWRITE:-0}"          # 1=即使本地已有同名同大小文件也重下
UA="${UA:-Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36}"

CMD="download"

# ---------------------------------------------------------------- 解析后状态
LINK_ID=""
LINK_KIND="auto"          # auto | folder | file | doc
DOC_TYPE=""               # document | spreadsheets | presentation | drawings
RESOURCE_KEY=""
SHEET_GID=""
REMOTE=""
RC_FLAGS=()

# ---------------------------------------------------------------- 工具
log()  { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
warn() { printf '[%s] 警告: %s\n' "$(date '+%F %T')" "$*" >&2; }
die()  { printf '[%s] 错误: %s\n' "$(date '+%F %T')" "$*" >&2; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }

# 兼容 macOS: 系统没有 readlink -f,BSD 的 md5 也和 md5sum 不一样
abspath() {
  local p="$1" d b
  if [[ -d "$p" ]]; then
    (cd "$p" && pwd)
  else
    d="$(dirname "$p")"; b="$(basename "$p")"
    if [[ -d "$d" ]]; then printf '%s/%s' "$(cd "$d" && pwd)" "$b"; else printf '%s' "$p"; fi
  fi
}

md5_of() {
  if have md5sum; then md5sum "$1" | cut -d' ' -f1
  elif have md5;    then md5 -q "$1"
  else printf 'n/a'; fi
}

url_decode() {
  case "$1" in
    *%*) printf '%b' "$(printf '%s' "$1" | sed 's/+/ /g; s/%/\\x/g')" ;;
    *)   printf '%s' "$1" ;;
  esac
}

human_size() {
  awk -v n="${1:-0}" 'BEGIN{s="B K M G T";split(s,u," ");i=1;while(n>=1024&&i<5){n/=1024;i++};printf (i==1?"%d %s":"%.2f %s"),n,u[i]}'
}

require_rclone() {
  command -v rclone >/dev/null 2>&1 && return 0
  cat >&2 <<'EOF'
错误: 未找到 rclone

安装 (ubuntu22):
    sudo -v ; curl https://rclone.org/install.sh | sudo bash
或:
    sudo apt update && sudo apt install -y rclone   # 版本较旧,可能不支持多线程下载

若只想下单个文件,可用 --strategy curl 走 curl 直链(不需要 rclone)。
EOF
  exit 1
}

# ---------------------------------------------------------------- 命令行
usage() {
  cat <<EOF
$PROG —— 从任意 Google Drive 链接下载内容

用法:
  $PROG [命令] [选项] <链接或 ID>

命令:
  download  下载(默认)。可反复执行,已完成的文件自动跳过
  check     验证凭证/连通性,打印远端信息
  list      列出远端内容(文件夹=文件树, 单文件=一条记录)
  verify    校验本地与远端是否一致
  info      只解析链接,打印类型/ID/直链,不下载(不需要凭证)

凭证:
  文件夹链接(以及 rclone 单文件路径)需要一个 service account 密钥(*.json)。
  查找顺序: --sa / SA_FILE 指定的路径  ->  当前目录下的 ./service-account.json
            ->  当前目录下唯一一个 service account 密钥(存在即自动加载,不必改文件名)
  公开的单文件链接完全不需要凭证,会直接走 curl 直链。

选项:
  -p, --proxy URL    网络代理,如 http://127.0.0.1:7890 / socks5h://127.0.0.1:1080
                     也可用环境变量 PROXY。文件夹模式走 rclone,仅支持 http/https 代理
      --no-proxy     忽略环境变量里的代理设置(直连)
  -d, --dest DIR     本地保存目录          (默认: $DEST_DIR)
  -n, --name NAME    单文件/在线文档的输出文件名
  -f, --format FMT   在线文档导出格式: docx|xlsx|pptx|pdf|csv|png (默认按文档类型)
      --sa FILE      service account 凭证路径
                     (默认: $SA_FILE,不存在时自动加载当前目录下唯一的密钥)
      --remote NAME  复用已有的 rclone remote,设置后忽略 --sa
      --include GLOB 只下载匹配的路径,如 'photos/**'
      --type T       链接类型有歧义时指定: folder | file
      --strategy S   单文件下载路径: auto | rclone | curl  (默认 auto)
      --threads N    并发文件数             (默认: $TRANSFERS)
      --tpslimit N   API 请求频率上限 QPS   (默认: $TPSLIMIT)
      --bwlimit X    带宽限速,如 20M        (默认: $BWLIMIT)
      --checksum    按 MD5 而非 size+修改时间比对(文件夹模式)
      --overwrite    本地已有同名文件也重新下载
      --log-dir DIR  日志目录               (默认: $LOG_DIR)
  -h, --help         显示本帮助

示例:
  $PROG download 'https://drive.google.com/drive/folders/<FOLDER_ID>'
  $PROG download 'https://drive.google.com/file/d/<FILE_ID>/view' -d ./data
  $PROG download 'https://docs.google.com/document/d/<DOC_ID>/edit' -n readme.docx
  PROXY=http://127.0.0.1:7890 $PROG download <链接>
  $PROG info <链接>          # 只想看解析结果
EOF
}

parse_args() {
  local POSITIONAL_SEEN=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help)     usage; exit 0 ;;
      -p|--proxy)    [[ $# -ge 2 ]] || die "--proxy 缺少参数"; PROXY="$2"; shift 2 ;;
      --proxy=*)     PROXY="${1#*=}"; shift ;;
      --no-proxy)    NO_PROXY_MODE=1; shift ;;
      -d|--dest)     [[ $# -ge 2 ]] || die "--dest 缺少参数"; DEST_DIR="$2"; shift 2 ;;
      --dest=*)      DEST_DIR="${1#*=}"; shift ;;
      -n|--name)     [[ $# -ge 2 ]] || die "--name 缺少参数"; NAME="$2"; shift 2 ;;
      --name=*)      NAME="${1#*=}"; shift ;;
      -f|--format)   [[ $# -ge 2 ]] || die "--format 缺少参数"; FORMAT="$2"; shift 2 ;;
      --format=*)    FORMAT="${1#*=}"; shift ;;
      --sa)          [[ $# -ge 2 ]] || die "--sa 缺少参数"; SA_FILE="$2"; SA_FILE_EXPLICIT=1; shift 2 ;;
      --sa=*)        SA_FILE="${1#*=}"; SA_FILE_EXPLICIT=1; shift ;;
      --remote)      [[ $# -ge 2 ]] || die "--remote 缺少参数"; RCLONE_REMOTE="$2"; shift 2 ;;
      --remote=*)    RCLONE_REMOTE="${1#*=}"; shift ;;
      --include)     [[ $# -ge 2 ]] || die "--include 缺少参数"; INCLUDE="$2"; shift 2 ;;
      --include=*)   INCLUDE="${1#*=}"; shift ;;
      --type)        [[ $# -ge 2 ]] || die "--type 缺少参数"; KIND_OVERRIDE="$2"; shift 2 ;;
      --type=*)      KIND_OVERRIDE="${1#*=}"; shift ;;
      --strategy)    [[ $# -ge 2 ]] || die "--strategy 缺少参数"; STRATEGY="$2"; shift 2 ;;
      --strategy=*)  STRATEGY="${1#*=}"; shift ;;
      --threads)     [[ $# -ge 2 ]] || die "--threads 缺少参数"; TRANSFERS="$2"; shift 2 ;;
      --threads=*)   TRANSFERS="${1#*=}"; shift ;;
      --tpslimit)    [[ $# -ge 2 ]] || die "--tpslimit 缺少参数"; TPSLIMIT="$2"; shift 2 ;;
      --tpslimit=*)  TPSLIMIT="${1#*=}"; shift ;;
      --bwlimit)     [[ $# -ge 2 ]] || die "--bwlimit 缺少参数"; BWLIMIT="$2"; shift 2 ;;
      --bwlimit=*)   BWLIMIT="${1#*=}"; shift ;;
      --checksum)    CHECKSUM=1; shift ;;
      --overwrite)   OVERWRITE=1; shift ;;
      --log-dir)     [[ $# -ge 2 ]] || die "--log-dir 缺少参数"; LOG_DIR="$2"; shift 2 ;;
      --log-dir=*)   LOG_DIR="${1#*=}"; shift ;;
      -*)            usage >&2; die "未知选项: $1" ;;
      *)
        case "$1" in
          check|list|download|verify|info) CMD="$1" ;;
          *)
            if [[ "$POSITIONAL_SEEN" == "0" ]]; then LINK_INPUT="$1"; POSITIONAL_SEEN=1
            else die "只能指定一个链接(多余参数: $1)"; fi
            ;;
        esac
        shift
        ;;
    esac
  done

  # 未显式给链接时,退回调用方预置的默认链接(环境变量 DEFAULT_LINK,见脚本头部配置)
  if [[ "$POSITIONAL_SEEN" == "0" && -z "$LINK_INPUT" && -n "${DEFAULT_LINK:-}" ]]; then
    LINK_INPUT="$DEFAULT_LINK"
  fi

  case "$STRATEGY" in auto|rclone|curl) ;; *) die "--strategy 只能是 auto | rclone | curl" ;; esac
  case "$KIND_OVERRIDE" in ""|auto|folder|file) ;; *) die "--type 只能是 folder | file" ;; esac

  if [[ "$NO_PROXY_MODE" == "1" ]]; then
    unset HTTP_PROXY HTTPS_PROXY http_proxy https_proxy ALL_PROXY all_proxy
    log "已按 --no-proxy 忽略环境变量中的代理设置"
  fi
  if [[ -n "$PROXY" ]]; then
    case "$PROXY" in
      *://*) ;;
      *) PROXY="http://$PROXY" ;;
    esac
  fi
}

# ---------------------------------------------------------------- 链接解析
# 支持: 文件夹 / 单文件 / 旧式 open?id= / 在线文档 / 裸 ID; 并抓出 resourcekey 与 sheet 的 gid
parse_link() {
  local raw="$1" url

  raw="$(printf '%s' "$raw" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
  raw="${raw#\"}"; raw="${raw%\"}"; raw="${raw#\'}"; raw="${raw%\'}"

  # 裸 ID
  if [[ "$raw" =~ ^[A-Za-z0-9_-]{10,}$ ]]; then
    LINK_ID="$raw"; LINK_KIND="auto"
    log "输入按 ID 处理: $LINK_ID"
    return 0
  fi

  case "$raw" in
    *://*) url="$raw" ;;
    *drive.google.com*|*docs.google.com*) url="https://$raw" ;;
    *) die "无法识别的链接: $raw" ;;
  esac

  RESOURCE_KEY="$(printf '%s' "$url" | sed -nE 's/.*[?&#]resourcekey=([A-Za-z0-9_-]+).*/\1/p')"
  SHEET_GID="$(printf '%s' "$url" | sed -nE 's/.*[?&#]gid=([0-9]+).*/\1/p')"

  case "$url" in
    *docs.google.com/*)
      DOC_TYPE="$(printf '%s' "$url" | sed -E 's#^[a-z]+://docs\.google\.com/([a-z]+)/.*#\1#')"
      LINK_ID="$(printf '%s' "$url" | sed -nE 's#.*/(u/[0-9]+/)?d/([A-Za-z0-9_-]{10,}).*#\2#p')"
      [[ -n "$LINK_ID" ]] || LINK_ID="$(printf '%s' "$url" | sed -nE 's/.*[?&]id=([A-Za-z0-9_-]{10,}).*/\1/p')"
      case "$DOC_TYPE" in
        document|spreadsheets|presentation|drawings|forms) ;;
        *) DOC_TYPE="" ;;
      esac
      LINK_KIND="doc"
      ;;
    *'/folders/'*)
      LINK_ID="$(printf '%s' "$url" | sed -nE 's#.*/folders/([A-Za-z0-9_-]{10,}).*#\1#p')"
      LINK_KIND="folder"
      ;;
    *'/file/d/'*)
      LINK_ID="$(printf '%s' "$url" | sed -nE 's#.*/file/d/([A-Za-z0-9_-]{10,}).*#\1#p')"
      LINK_KIND="file"
      ;;
    *)
      LINK_ID="$(printf '%s' "$url" | sed -nE 's/.*[?&]id=([A-Za-z0-9_-]{10,}).*/\1/p')"
      case "$url" in
        *thumbnail\?id=*|*'/uc?'*) LINK_KIND="file" ;;
        *)                         LINK_KIND="auto" ;;
      esac
      ;;
  esac

  [[ -n "$LINK_ID" ]] || die "无法从链接中解析出文件/文件夹 ID: $raw
支持的形态见 $PROG -h"
  return 0
}

# 旧式 open?id= / 裸 ID 无法从链接本身判断是文件夹还是文件,这里探一次
resolve_link_kind() {
  if [[ -n "$KIND_OVERRIDE" && "$KIND_OVERRIDE" != "auto" ]]; then
    LINK_KIND="$KIND_OVERRIDE"
    log "按 --type $KIND_OVERRIDE 处理"
    return 0
  fi
  if [[ "$LINK_KIND" != "auto" ]]; then
    return 0
  fi

  if have rclone && setup_remote "$LINK_ID" >/dev/null 2>&1; then
    if rclone lsf "$REMOTE" --max-depth 1 --files-only --quiet --drive-root-folder-id "$LINK_ID" >/dev/null 2>&1; then
      log "探测结果: 该 ID 是可列出的文件夹"
      LINK_KIND="folder"
      return 0
    fi
    log "探测结果: 该 ID 不是可列出的文件夹,按单个文件处理"
    LINK_KIND="file"
    return 0
  fi

  # 没有凭证就无从探测。这种链接多半是文件夹,走 folder 分支能给出更明确的报错;
  # 若实际是单个文件,提示用户用 --type file 走 curl 直链即可。
  log "没有可用凭证,无法探测链接类型;先按文件夹处理(单个文件请加 --type file)"
  LINK_KIND="folder"
  return 0
}

# ---------------------------------------------------------------- 凭证
# 看起来像 service account 密钥的 json(而不是普通的配置文件)
sa_looks_like_key() {
  [[ -f "$1" ]] || return 1
  grep -q '"type"[[:space:]]*:[[:space:]]*"service_account"' "$1" 2>/dev/null || return 1
  grep -q '"private_key"' "$1" 2>/dev/null || return 1
  return 0
}

# 解析出可用的凭证文件并写回 SA_FILE;没有可用凭证时返回 1
# 顺序: 显式指定(--sa / SA_FILE) > 当前目录的 ./service-account.json > 当前目录里唯一一个 sa 密钥
SA_RESOLVED=0
resolve_sa_file() {
  if [[ "$SA_RESOLVED" == "1" ]]; then
    if [[ -f "$SA_FILE" ]]; then return 0; else return 1; fi
  fi
  SA_RESOLVED=1

  if [[ -f "$SA_FILE" ]]; then
    [[ "$SA_FILE_EXPLICIT" == "0" ]] && log "凭证: 使用 $SA_FILE"
    return 0
  fi
  # 显式指定的路径不存在时不再猜,交给调用方报错
  [[ "$SA_FILE_EXPLICIT" == "1" ]] && return 1

  # 默认文件名不存在: 在当前目录下找 service account 密钥,唯一时才自动采用
  local -a cands=() named=()
  local f
  for f in *.json; do
    sa_looks_like_key "$f" && cands+=("$f")
  done
  [[ "${#cands[@]}" -eq 0 ]] && return 1

  if [[ "${#cands[@]}" -eq 1 ]]; then
    SA_FILE="${cands[0]}"
  else
    local g
    for g in "${cands[@]}"; do
      case "$g" in *service[-_]account*.json) named+=("$g") ;; esac
    done
    if [[ "${#named[@]}" -ne 1 ]]; then
      warn "当前目录下有多个 service account 密钥,无法自动选择:"
      printf '  %s\n' "${cands[@]}" >&2
      warn "请用 --sa <文件> 指定要用哪一个"
      return 1
    fi
    SA_FILE="${named[0]}"
  fi
  log "凭证: 自动加载当前目录下的 $SA_FILE"
  return 0
}

# ---------------------------------------------------------------- rclone 远端
# 通过环境变量声明 remote,避免改动用户已有的 ~/.config/rclone/rclone.conf
# 参数: $1 = 作为根的文件夹 ID(单文件模式留空)
# 返回: 0 = 已就绪; 1 = 没有可用凭证(调用方决定是否回退 curl)
setup_remote() {
  local root_id="${1:-}"

  if [[ -n "$RCLONE_REMOTE" ]]; then
    REMOTE="${RCLONE_REMOTE%:}:"
  else
    resolve_sa_file || return 1
    REMOTE="gdrivedl:"
    export RCLONE_CONFIG_GDRIVEDL_TYPE="drive"
    export RCLONE_CONFIG_GDRIVEDL_SCOPE="drive.readonly"
    export RCLONE_CONFIG_GDRIVEDL_SERVICE_ACCOUNT_FILE="$(abspath "$SA_FILE")"
  fi

  if [[ -n "$root_id" ]]; then
    export RCLONE_DRIVE_ROOT_FOLDER_ID="$root_id"
  else
    unset RCLONE_DRIVE_ROOT_FOLDER_ID || true
  fi
  [[ -n "$RESOURCE_KEY" ]] && export RCLONE_DRIVE_RESOURCE_KEY="$RESOURCE_KEY"

  return 0
}

setup_remote_or_die() {
  local root_id="${1:-}"
  setup_remote "$root_id" && return 0
  die "未找到可用的 service account 凭证(当前目录: $(pwd))
查找顺序: --sa / SA_FILE 指定的路径  ->  ./service-account.json  ->  当前目录下唯一的 service account 密钥
请参考 README.md 准备凭证,或用 --remote <rclone remote 名> 指定已配置好的 remote。
如果这个链接其实是单个文件,加 --type file 即可走 curl 直链(公开链接不需要凭证)。"
}

# 公共参数
#   --drive-acknowledge-abuse: 大文件会被 Drive 标记为"无法扫描病毒",不加则直接失败
#   --fast-list:               一次性列目录,大幅减少 API 调用,是规避限流的关键
#   --tpslimit:                主动压住 QPS,比事后重试划算
common_flags() {
  RC_FLAGS=(
    --drive-acknowledge-abuse
    --fast-list
    --transfers "$TRANSFERS"
    --checkers "$CHECKERS"
    --tpslimit "$TPSLIMIT"
    --tpslimit-burst "$TPSLIMIT"
    --bwlimit "$BWLIMIT"
    --retries 10
    --retries-sleep 20s
    --low-level-retries 20
    --timeout 5m
    --contimeout 60s
  )
  if [[ -n "$PROXY" ]]; then
    RC_FLAGS+=(--http-proxy "$PROXY")
    log "代理: $PROXY"
  fi
  if [[ -n "$INCLUDE" ]]; then
    RC_FLAGS+=(--include "$INCLUDE")
    log "过滤规则: $INCLUDE"
  fi
}

# ---------------------------------------------------------------- 文件夹模式 (复用原有能力)
cmd_folder_check() {
  log "远端连通性检查..."
  rclone lsd "$REMOTE" "${RC_FLAGS[@]}" || die "无法访问远端。常见原因:
  1. service account 的 Google Drive API 未启用
  2. 凭证 JSON 无效或已被撤销
  3. 文件夹 ID 有误、分享权限已变更,或该链接需要 resourcekey 才能访问"
  echo
  log "统计总量 (大目录可能需要几分钟)..."
  rclone size "$REMOTE" "${RC_FLAGS[@]}"
}

cmd_folder_list() {
  rclone lsf --recursive --files-only --format "sp" --separator "  " "$REMOTE" "${RC_FLAGS[@]}"
}

cmd_folder_download() {
  mkdir -p "$DEST_DIR" "$LOG_DIR"
  local logfile="$LOG_DIR/download_$(date '+%Y%m%d_%H%M%S').log"

  if [[ "$CHECKSUM" == "1" ]]; then
    RC_FLAGS+=(--checksum)
    log "已启用 MD5 比对模式 (会重算本地文件校验和,比默认慢)"
  fi

  log "远端: $REMOTE (folder=$LINK_ID)"
  log "本地: $(abspath "$DEST_DIR")"
  log "日志: $logfile"
  log "开始下载 (中断后重跑本命令即可续传)"
  echo

  # copy 而非 sync: 绝不删除本地已有文件
  # --multi-thread-*: 单个大文件拆多流下载,对别人分享的大压缩包提速明显
  rclone copy "$REMOTE" "$DEST_DIR" \
    "${RC_FLAGS[@]}" \
    --multi-thread-streams 4 \
    --multi-thread-cutoff 256M \
    --buffer-size 32M \
    --check-first \
    --progress \
    --stats 30s \
    --stats-one-line \
    --log-file "$logfile" \
    --log-level INFO

  echo
  log "下载完成"
  log "本地占用: $(du -sh "$DEST_DIR" | cut -f1)"
  log "建议执行 $PROG verify '$LINK_INPUT' 校验完整性"
}

cmd_folder_verify() {
  [[ -d "$DEST_DIR" ]] || die "本地目录不存在: $DEST_DIR"
  mkdir -p "$LOG_DIR"
  local logfile="$LOG_DIR/verify_$(date '+%Y%m%d_%H%M%S').log"

  log "比对 MD5 (差异清单写入 $logfile)"
  # Drive 为多数文件提供 MD5,可直接比对而无需重新下载
  rclone check "$REMOTE" "$DEST_DIR" \
    "${RC_FLAGS[@]}" \
    --one-way \
    --differ "$LOG_DIR/differ.txt" \
    --missing-on-dst "$LOG_DIR/missing.txt" \
    --log-file "$logfile" \
    --log-level INFO \
  && {
    log "校验通过,所有文件一致"
    # Google Docs 原生格式文件(如 ReadMe.docx)没有 MD5,rclone 只跳过不报错,
    # 这里显式提示,避免"校验通过"被误读成全量文件都比对过
    if grep -q 'could not be checked' "$logfile" 2>/dev/null; then
      log "注意: 有文件因无 MD5 而未参与比对(Google Docs 类文件),属正常现象"
    fi
    true
  } \
  || {
    local n_missing n_differ
    n_missing=$(wc -l < "$LOG_DIR/missing.txt" 2>/dev/null | tr -d ' ') || n_missing=0
    n_differ=$(wc -l < "$LOG_DIR/differ.txt" 2>/dev/null | tr -d ' ') || n_differ=0
    log "存在差异:"
    log "  缺失   ${n_missing:-0} 个 -> $LOG_DIR/missing.txt"
    log "  不一致 ${n_differ:-0} 个 -> $LOG_DIR/differ.txt"
    echo
    if [[ "${n_missing:-0}" -gt 0 ]]; then
      log "补齐缺失文件:  $PROG download '$LINK_INPUT'"
    fi
    # 内容损坏但 size/modtime 仍与远端一致时,普通 copy 会判定文件已是最新而跳过,必须按校验和比对才会重下
    if [[ "${n_differ:-0}" -gt 0 ]]; then
      log "修复损坏文件:  CHECKSUM=1 $PROG download '$LINK_INPUT'"
    fi
    return 1
  }
}

# ---------------------------------------------------------------- 单文件模式: curl 直链
# Drive 的直链下载口。confirm=t 能绕过"无法扫描病毒"的确认页,大文件也直接返回内容。
file_direct_url() {
  local u="https://drive.usercontent.google.com/download?id=$LINK_ID&export=download&confirm=t"
  [[ -n "$RESOURCE_KEY" ]] && u="$u&resourcekey=$RESOURCE_KEY"
  printf '%s' "$u"
}

header_get() { # <header文件> <头名>;取不到时返回空串并保持 0 退出码(set -e 下不能失败)
  grep -i "^$2:" "$1" 2>/dev/null | tail -1 | sed -E "s/^[^:]*:[[:space:]]*//" | tr -d '\r' || true
}

cd_filename() { # <header文件> -> 文件名(URL 解码后)
  local line n
  line="$(grep -i '^content-disposition:' "$1" 2>/dev/null | tail -1 | tr -d '\r')"
  [[ -n "$line" ]] || return 1
  if [[ "$line" =~ filename\*=UTF-8\'\'([^\;\"]+) ]]; then
    n="$(url_decode "${BASH_REMATCH[1]}")"
  elif [[ "$line" =~ filename=\"([^\"]+)\" ]]; then
    n="${BASH_REMATCH[1]}"
  elif [[ "$line" =~ filename=([^\;\"]+) ]]; then
    n="${BASH_REMATCH[1]}"
  else
    return 1
  fi
  [[ -n "$n" ]] || return 1
  printf '%s' "$n"
}

is_html_file() { # 判断下下来的是不是错误页而非真文件
  head -c 400 "$1" 2>/dev/null | tr -d '\0' | grep -qiE '<html|<!doctype|<form' 
}

# HEAD 一次拿名字/大小/类型;拿不到不算错误(部分环境不支持 HEAD)
HTTP_NAME=""; HTTP_SIZE=""; HTTP_TYPE=""; HTTP_CODE=""
http_probe() { # <url> <header输出文件>
  local url="$1" hdr="$2"
  HTTP_NAME=""; HTTP_SIZE=""; HTTP_TYPE=""; HTTP_CODE=""
  : > "$hdr"
  curl -sS -I -L -A "$UA" --connect-timeout 30 --max-time 120 -D "$hdr" -o /dev/null "$url" >/dev/null 2>&1 || true
  # 取不到任何头(离线/服务端不支持 HEAD)时保持空值,不能因此中断流程
  HTTP_CODE="$(grep -oE 'HTTP/[0-9.]+ [0-9]{3}' "$hdr" 2>/dev/null | tail -1 | awk '{print $2}' || true)"
  HTTP_NAME="$(cd_filename "$hdr" || true)"
  HTTP_SIZE="$(header_get "$hdr" content-length)"
  HTTP_TYPE="$(header_get "$hdr" content-type)"
  return 0
}

# 真正下载: 断点续传 + 确认页回退
# 参数: <url> <mode: drive|doc>
curl_fetch() {
  local url="$1" mode="$2"
  local hdr="$LOG_DIR/headers_$LINK_ID.txt"
  local jar="$LOG_DIR/.cookies_$LINK_ID.txt"
  local probe="$LOG_DIR/probe_$LINK_ID.txt"

  http_probe "$url" "$probe"

  local name="$NAME"
  [[ -z "$name" ]] && name="$HTTP_NAME"
  local final part
  if [[ -n "$name" ]]; then
    final="$DEST_DIR/$name"; part="$DEST_DIR/.$name.part"
  else
    final=""               # 名字待下载后从 Content-Disposition 里取
    part="$DEST_DIR/.$LINK_ID.part"
  fi

  # 已完成则跳过: 有远端大小时比大小,没有时只要最终文件在就认为已完成
  if [[ "$OVERWRITE" != "1" && -n "$final" && -f "$final" ]]; then
    local lsize; lsize="$(wc -c < "$final" | tr -d ' ' || true)"; lsize="${lsize:-0}"
    if [[ -z "$HTTP_SIZE" || "$lsize" == "$HTTP_SIZE" ]]; then
      log "已存在,跳过: $final ($(human_size "$lsize"))"
      return 0
    fi
    log "本地大小($lsize)与远端($HTTP_SIZE)不一致,重新下载"
  fi
  if [[ -f "$part" && -s "$part" ]]; then
    log "发现未完成的临时文件,继续续传: $part"
  fi

  local -a cflags=(-L --retry 5 --retry-delay 3 --retry-connrefused -A "$UA"
                   -b "$jar" -c "$jar" -D "$hdr" --connect-timeout 30)
  [[ -n "$PROXY" ]] && cflags+=(--proxy "$PROXY")
  [[ "$NO_PROXY_MODE" == "1" ]] && cflags+=(--noproxy '*')
  if [[ -t 1 ]]; then cflags+=(--progress-bar); else cflags+=(-sS); fi

  local -a pflags=(-sS -L -A "$UA" -b "$jar" -c "$jar")
  [[ -n "$PROXY" ]] && pflags+=(--proxy "$PROXY")
  [[ "$NO_PROXY_MODE" == "1" ]] && pflags+=(--noproxy '*')

  log "直链下载: $url"
  if [[ -n "$HTTP_NAME" ]]; then
    if [[ -n "$HTTP_SIZE" ]]; then
      log "远端: $HTTP_NAME ($(human_size "$HTTP_SIZE"))"
    else
      log "远端: $HTTP_NAME (大小未知)"
    fi
  fi

  resume_and_get() { # $1 = 1 表示允许续传
    local rc=0
    if [[ "$1" == "1" && -f "$part" && -s "$part" ]]; then
      curl "${cflags[@]}" -C - -o "$part" "$url" || rc=$?
      if [[ "$rc" != "0" ]]; then
        # 典型情况: 服务端不支持 Range,或重定向后确认页要求重新开始
        warn "续传失败(curl 退出码 $rc),改为从头下载"
        : > "$part"
        rc=0
      fi
    fi
    if [[ ! -s "$part" ]]; then
      curl "${cflags[@]}" -o "$part" "$url" || return $?
    fi
    return 0
  }

  resume_and_get 1 || die "下载失败: $url
可尝试 --strategy rclone 走 service account 路径,或检查 --proxy 设置"

  # 拿到的是 HTML -> 通常是被"无法扫描病毒"确认页挡住,或链接并非公开共享
  if is_html_file "$part"; then
    if [[ "$mode" == "doc" ]]; then
      die "导出在线文档失败: 返回的是 HTML 而非文件内容。
常见原因: 该文档未公开共享(需要登录),或 ID/类型有误。可改用 --sa 提供凭证。"
    fi
    log "返回的是确认页,提取 confirm 令牌后重试一次..."
    local page="$LOG_DIR/confirm_$LINK_ID.html"
    local confirm uuid direct
    curl "${pflags[@]}" -o "$page" \
      "https://drive.usercontent.google.com/download?id=$LINK_ID&export=download${RESOURCE_KEY:+&resourcekey=$RESOURCE_KEY}" || true
    confirm="$(sed -nE 's/.*name="confirm" value="([^"]+)".*/\1/p' "$page" 2>/dev/null | head -1 || true)"
    uuid="$(sed -nE 's/.*name="uuid" value="([^"]+)".*/\1/p' "$page" 2>/dev/null | head -1 || true)"
    if [[ -z "$confirm" ]]; then
      die "无法通过确认页下载。
  1) 确认链接是「知道链接的任何人可查看」;
  2) 若是热门大文件,可能触发了按文件计的下载配额,需等待 24 小时;
  3) 或改用 service account: --sa ./service-account.json
确认页已存到: $page"
    fi
    direct="https://drive.usercontent.google.com/download?id=$LINK_ID&export=download&confirm=$confirm"
    [[ -n "$uuid" ]] && direct="$direct&uuid=$uuid"
    [[ -n "$RESOURCE_KEY" ]] && direct="$direct&resourcekey=$RESOURCE_KEY"
    rm -f "$part"
    curl "${cflags[@]}" -o "$part" "$direct" || die "确认页重试仍失败: $direct"
    if is_html_file "$part"; then
      if grep -qiE 'quota|too many users|exceeded|配额' "$part"; then
        die "该文件触发了 Google 的下载配额限制(与账号无关,换账号也没用),请等待 24 小时后重试。
下载内容已保存到: $part"
      fi
      die "重试后仍是 HTML 页面,未能取到文件内容(见 $part)"
    fi
  fi

  # 名字兜底: 用下载响应头里的 Content-Disposition
  if [[ -z "$final" ]]; then
    name="$(cd_filename "$hdr" || true)"
    [[ -z "$name" ]] && name="$LINK_ID"
    final="$DEST_DIR/$name"
  fi

  mkdir -p "$(dirname "$final")"
  mv -f "$part" "$final"

  local size; size="$(wc -c < "$final" | tr -d ' ' || true)"; size="${size:-0}"
  if [[ -n "$HTTP_SIZE" && "$size" != "$HTTP_SIZE" ]]; then
    warn "下载字节数($size)与远端声明($HTTP_SIZE)不一致,建议重跑一次"
  fi
  log "完成: $final ($(human_size "$size"))"
  log "MD5: $(md5_of "$final")"
  return 0
}

# 单文件: 优先 rclone(可续传、带校验、有限流),没有凭证时回退 curl
cmd_file_download() {
  mkdir -p "$DEST_DIR" "$LOG_DIR"
  [[ -n "$INCLUDE" ]] && warn "单文件模式下 --include 无效,已忽略"

  if [[ "$STRATEGY" != "curl" ]]; then
    if setup_remote ""; then
      # 单文件模式此前没走过 common_flags,而 bash 3.2 下展开空数组会因 set -u 报错,这里补齐公共参数。
      # --include 对单文件没有意义(上面已警告忽略),临时屏蔽,免得 copyid 反而把目标文件过滤掉
      local _include="$INCLUDE"; INCLUDE=""
      common_flags
      INCLUDE="$_include"
      local dest="$DEST_DIR/"
      [[ -n "$NAME" ]] && dest="$DEST_DIR/$NAME"
      log "策略: rclone backend copyid (服务端 $REMOTE)"
      log "远端文件 ID: $LINK_ID"
      log "本地: $(abspath "$DEST_DIR")"
      echo
      if rclone backend copyid "$REMOTE" "$LINK_ID" "$dest" \
           "${RC_FLAGS[@]}" \
           --multi-thread-streams 4 \
           --multi-thread-cutoff 256M \
           --buffer-size 32M \
           --progress \
           --stats 30s \
           --stats-one-line; then
        echo
        log "完成"
        [[ -n "$NAME" ]] && log "输出: $(abspath "$DEST_DIR/$NAME")"
        return 0
      fi
      if [[ "$STRATEGY" == "rclone" ]]; then
        die "rclone 路径失败(--strategy rclone 不自动回退)"
      fi
      warn "rclone 路径失败,回退 curl 直链下载"
    else
      if [[ "$STRATEGY" == "rclone" ]]; then
        setup_remote_or_die ""
      fi
      log "没有 service account 凭证,改用 curl 直链下载(公开链接即可)"
    fi
  fi

  require_curl
  curl_fetch "$(file_direct_url)" drive
}

require_curl() {
  have curl || die "未找到 curl;或提供 --sa 走 rclone 路径"
  return 0
}

# ---------------------------------------------------------------- 单文件模式: 查询 / 校验
cmd_file_check() {
  log "远端文件 ID: $LINK_ID"
  log "直链: $(file_direct_url)"
  if have curl; then
    local probe="$LOG_DIR/probe_$LINK_ID.txt"
    mkdir -p "$LOG_DIR"
    http_probe "$(file_direct_url)" "$probe"
    echo
    log "HTTP: ${HTTP_CODE:-未知}"
    log "名称: ${HTTP_NAME:-未知}"
    log "大小: $( [[ -n "$HTTP_SIZE" ]] && human_size "$HTTP_SIZE" || echo 未知 )"
    log "类型: ${HTTP_TYPE:-未知}"
    if [[ -n "$HTTP_TYPE" && "$HTTP_TYPE" == text/html ]]; then
      warn "返回 text/html,通常表示需要登录或未公开共享;可用 --sa 提供凭证走 rclone 路径"
    fi
  fi
  if setup_remote ""; then
    log "凭证: 已就绪(可用 rclone 路径)"
  else
    log "凭证: 未提供(仅 curl 路径)"
  fi
  if [[ -n "$PROXY" ]]; then log "代理: $PROXY"; fi
}

cmd_file_list() {
  if have curl; then
    local probe="$LOG_DIR/probe_$LINK_ID.txt"
    mkdir -p "$LOG_DIR"
    http_probe "$(file_direct_url)" "$probe"
    printf '%s  %s\n' "${HTTP_SIZE:-?}" "${HTTP_NAME:-$LINK_ID}"
  else
    printf '%s\n' "$LINK_ID"
  fi
}

find_local_file() { # 尽力定位本地已下载的那份文件
  if [[ -n "$NAME" && -f "$DEST_DIR/$NAME" ]]; then printf '%s' "$DEST_DIR/$NAME"; return 0; fi
  if [[ -f "$DEST_DIR/$LINK_ID" ]]; then printf '%s' "$DEST_DIR/$LINK_ID"; return 0; fi
  local f
  for f in "$DEST_DIR/$LINK_ID".*; do
    [[ -e "$f" ]] && { printf '%s' "$f"; return 0; }
  done
  local p="$LOG_DIR/probe_$LINK_ID.txt"
  if [[ -f "$p" ]]; then
    local n; n="$(cd_filename "$p" || true)"
    [[ -n "$n" && -f "$DEST_DIR/$n" ]] && { printf '%s' "$DEST_DIR/$n"; return 0; }
  fi
  return 1
}

cmd_file_verify() {
  mkdir -p "$LOG_DIR"
  local local_file
  if ! local_file="$(find_local_file)"; then
    die "本地找不到对应文件(在 $DEST_DIR 下)。先执行 $PROG download '$LINK_INPUT'"
  fi
  log "本地文件: $local_file"
  log "本地 MD5: $(md5_of "$local_file")"
  log "本地大小: $(human_size "$(wc -c < "$local_file" | tr -d ' ' || true)")"

  if ! have curl; then
    warn "没有 curl,无法取远端大小;仅提示:单文件模式不做逐字节 MD5 校验"
    return 0
  fi

  local probe="$LOG_DIR/probe_$LINK_ID.txt"
  http_probe "$(file_direct_url)" "$probe"
  if [[ -z "$HTTP_SIZE" ]]; then
    warn "未能取得远端大小(HTTP ${HTTP_CODE:-未知}),跳过比对"
    return 0
  fi

  local lsize; lsize="$(wc -c < "$local_file" | tr -d ' ' || true)"; lsize="${lsize:-0}"
  if [[ "$lsize" == "$HTTP_SIZE" ]]; then
    log "校验通过: 与远端大小一致($(human_size "$HTTP_SIZE"))"
    [[ "$LINK_KIND" == "doc" ]] && log "注意: 在线文档导出内容的字节数不保证稳定,这里只比对大小"
    return 0
  fi
  log "大小不一致: 本地 $lsize vs 远端 $HTTP_SIZE"
  log "修复: $PROG download '$LINK_INPUT' --overwrite"
  return 1
}

# ---------------------------------------------------------------- 在线文档模式
# 默认导出格式: 按文档类型推断;带 gid 的表格默认导出 csv,否则整表导出 xlsx
doc_default_format() {
  if [[ -n "$FORMAT" ]]; then
    printf '%s' "$FORMAT"
    return 0
  fi
  case "$DOC_TYPE" in
    document)     printf 'docx' ;;
    spreadsheets) if [[ -n "$SHEET_GID" ]]; then printf 'csv'; else printf 'xlsx'; fi ;;
    presentation) printf 'pptx' ;;
    drawings)     printf 'png' ;;
    forms)        die "Google 表单不支持直接导出,请在浏览器里手动导出,或用 --format 指定其它格式" ;;
    *)            die "无法识别的在线文档类型: ${DOC_TYPE:-未知}。请用 --format 指定导出格式" ;;
  esac
}

doc_export_url() { # $1 = 导出格式
  local f="$1" base
  case "$DOC_TYPE" in
    document)     base="https://docs.google.com/document/d/$LINK_ID/export?format=$f" ;;
    spreadsheets) base="https://docs.google.com/spreadsheets/d/$LINK_ID/export?format=$f" ;;
    presentation) base="https://docs.google.com/presentation/d/$LINK_ID/export?format=$f" ;;
    drawings)     base="https://docs.google.com/drawings/d/$LINK_ID/export/$f" ;;
    *)            base="https://docs.google.com/uc?export=download&id=$LINK_ID" ;;
  esac
  if [[ -n "$SHEET_GID" ]]; then
    base="$base&gid=$SHEET_GID"
  fi
  printf '%s' "$base"
}

cmd_doc_download() {
  mkdir -p "$DEST_DIR" "$LOG_DIR"
  DOC_FORMAT_OUT="$(doc_default_format)"
  local url; url="$(doc_export_url "$DOC_FORMAT_OUT")"
  if [[ -z "$NAME" ]]; then
    NAME="$LINK_ID.$DOC_FORMAT_OUT"
    log "未指定 --name,先按 $NAME 命名(若响应头带真实标题则以响应头为准)"
  fi
  require_curl
  log "在线文档类型: $DOC_TYPE$( [[ -n "$SHEET_GID" ]] && printf ' (gid=%s)' "$SHEET_GID" )"
  log "导出格式: $DOC_FORMAT_OUT"
  curl_fetch "$url" doc
}

cmd_doc_check() {
  DOC_FORMAT_OUT="$(doc_default_format)"
  local url; url="$(doc_export_url "$DOC_FORMAT_OUT")"
  log "在线文档类型: $DOC_TYPE"
  log "导出格式: $DOC_FORMAT_OUT"
  log "导出链接: $url"
  if have curl; then
    local probe="$LOG_DIR/probe_$LINK_ID.txt"; mkdir -p "$LOG_DIR"
    http_probe "$url" "$probe"
    echo
    log "HTTP: ${HTTP_CODE:-未知}"
    log "名称: ${HTTP_NAME:-未知}"
    log "大小: $( [[ -n "$HTTP_SIZE" ]] && human_size "$HTTP_SIZE" || echo 未知 )"
    log "类型: ${HTTP_TYPE:-未知}"
    if [[ -n "$HTTP_TYPE" && "$HTTP_TYPE" == text/html ]]; then
      warn "返回 text/html,通常表示该文档未公开共享(需要登录)"
    fi
  fi
}

# ---------------------------------------------------------------- info
cmd_info() {
  local kind_name
  case "$LINK_KIND" in
    folder) kind_name="文件夹" ;;
    file)   kind_name="单个文件" ;;
    doc)    kind_name="在线文档 ($DOC_TYPE)" ;;
    auto)   kind_name="未确定(将先探测文件夹,不是则按单文件)" ;;
  esac
  log "输入: $LINK_INPUT"
  log "类型: $kind_name"
  log "ID:   $LINK_ID"
  [[ -n "$RESOURCE_KEY" ]] && log "resourcekey: $RESOURCE_KEY"
  [[ -n "$SHEET_GID" ]] && log "gid: $SHEET_GID"
  case "$LINK_KIND" in
    folder)
      log "下载方式: rclone(可续传/限流/MD5 校验)"
      log "等效命令: rclone lsf --drive-root-folder-id '$LINK_ID' <remote>:"
      ;;
    doc)
      local fmt
      fmt="$(doc_default_format 2>/dev/null)" || fmt=""
      [[ -z "$fmt" ]] && fmt="docx"
      log "下载方式: curl 导出(默认格式: $fmt)"
      log "导出链接: $(doc_export_url "$fmt")"
      ;;
    file)
      log "下载方式: rclone backend copyid(默认),失败或 --strategy curl 时用直链"
      log "直链: $(file_direct_url)"
      ;;
  esac
  [[ -n "$PROXY" ]] && log "代理: $PROXY"
  return 0
}

# ---------------------------------------------------------------- 入口
main() {
  parse_args "$@"

  if [[ -z "$LINK_INPUT" ]]; then
    usage >&2
    die "缺少链接或 ID。示例: $PROG download 'https://drive.google.com/drive/folders/<ID>'"
  fi

  parse_link "$LINK_INPUT"

  if [[ "$CMD" == "info" ]]; then
    cmd_info
    exit 0
  fi

  resolve_link_kind

  case "$LINK_KIND" in
    folder)
      require_rclone
      setup_remote_or_die "$LINK_ID"
      common_flags
      case "$CMD" in
        check)    cmd_folder_check ;;
        list)     cmd_folder_list ;;
        download) cmd_folder_download ;;
        verify)   cmd_folder_verify ;;
      esac
      ;;
    file)
      if [[ "$CMD" == "download" ]]; then
        cmd_file_download
      else
        # 查询类命令: 有凭证就用,没有也能跑(curl 直链探测)
        if setup_remote ""; then common_flags; fi
        case "$CMD" in
          check)  cmd_file_check ;;
          list)   cmd_file_list ;;
          verify) cmd_file_verify ;;
        esac
      fi
      ;;
    doc)
      case "$CMD" in
        check)    cmd_doc_check ;;
        download) cmd_doc_download ;;
        list)     cmd_doc_check ;;
        verify)
          # 导出内容按大小比对即可,复用单文件校验
          cmd_file_verify
          ;;
      esac
      ;;
    *)
      die "内部错误: 未知的链接类型 $LINK_KIND"
      ;;
  esac
}

main "$@"
