#!/usr/bin/env bash
#
# v2x 数据集下载脚本 (Google Drive -> 本地)
#
# 环境: ubuntu22 server
# 方案: rclone + service account (选型理由与完整文档见 README.md)
#
# 用法:
#   ./download_v2x.sh check      # 验证凭证/连通性,统计文件数与总大小
#   ./download_v2x.sh list       # 列出远端文件树
#   ./download_v2x.sh download   # 下载(默认;可反复执行,已完成的文件自动跳过)
#   ./download_v2x.sh verify     # 用 MD5 比对本地与远端
#
# 常用环境变量:
#   DEST_DIR=/data/v2x  SA_FILE=/etc/v2x/sa.json  TRANSFERS=4  INCLUDE='DAIR-V2X (CVPR2022)/**'
#

set -euo pipefail

# ---------------------------------------------------------------- 配置
FOLDER_ID="${FOLDER_ID:-1gnrw5llXAIxuB9sEKKCm6xTaJ5HQAw2e}"
DEST_DIR="${DEST_DIR:-./v2x-data}"
SA_FILE="${SA_FILE:-./service-account.json}"
LOG_DIR="${LOG_DIR:-./logs}"

# 并发与限流: Drive 对单账号有 QPS 上限,调高 TRANSFERS 反而更容易触发 403 rateLimitExceeded
TRANSFERS="${TRANSFERS:-4}"
CHECKERS="${CHECKERS:-8}"
TPSLIMIT="${TPSLIMIT:-8}"
BWLIMIT="${BWLIMIT:-off}"

# 只下载部分子目录时设置,例如 INCLUDE='DAIR-V2X (CVPR2022)/**'
# 注意:数据集大量使用分卷压缩(.z01-.z04 与 .zip 同属一份),过滤时必须把同名分卷全部包含,否则解压不了
INCLUDE="${INCLUDE:-}"

# 1=按 MD5 比对而非 size+modtime。修复"大小相同但内容已损坏"的文件时必须开启,代价是要重算本地校验和
CHECKSUM="${CHECKSUM:-0}"

RCLONE_REMOTE="${RCLONE_REMOTE:-}"   # 不用 service account 时,指定已有的 rclone remote 名

# ---------------------------------------------------------------- 工具
log()  { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
die()  { printf '[%s] 错误: %s\n' "$(date '+%F %T')" "$*" >&2; exit 1; }

require_rclone() {
  command -v rclone >/dev/null 2>&1 && return
  cat >&2 <<'EOF'
错误: 未找到 rclone

安装 (ubuntu22):
    sudo -v ; curl https://rclone.org/install.sh | sudo bash
或:
    sudo apt update && sudo apt install -y rclone   # 版本较旧,可能不支持多线程下载
EOF
  exit 1
}

# 通过环境变量声明 remote,避免改动用户已有的 ~/.config/rclone/rclone.conf
setup_remote() {
  if [[ -n "$RCLONE_REMOTE" ]]; then
    REMOTE="${RCLONE_REMOTE%:}:"
    export RCLONE_DRIVE_ROOT_FOLDER_ID="$FOLDER_ID"
    log "使用已有 remote: $REMOTE (root_folder_id=$FOLDER_ID)"
    return
  fi

  [[ -f "$SA_FILE" ]] || die "未找到 service account 凭证: $SA_FILE
请参考 README.md 创建,或用 RCLONE_REMOTE=<remote名> 指定已配置好的 rclone remote。"

  REMOTE="v2x:"
  export RCLONE_CONFIG_V2X_TYPE="drive"
  export RCLONE_CONFIG_V2X_SCOPE="drive.readonly"
  export RCLONE_CONFIG_V2X_SERVICE_ACCOUNT_FILE="$(readlink -f "$SA_FILE")"
  export RCLONE_CONFIG_V2X_ROOT_FOLDER_ID="$FOLDER_ID"
  log "使用 service account: $SA_FILE"
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
  if [[ -n "$INCLUDE" ]]; then
    RC_FLAGS+=(--include "$INCLUDE")
    log "过滤规则: $INCLUDE"
  fi
}

# ---------------------------------------------------------------- 子命令
cmd_check() {
  log "远端连通性检查..."
  rclone lsd "$REMOTE" "${RC_FLAGS[@]}" || die "无法访问远端。常见原因:
  1. service account 的 Google Drive API 未启用
  2. 凭证 JSON 无效或已被撤销
  3. 文件夹 ID 有误或分享权限已变更"
  echo
  log "统计总量 (大目录可能需要几分钟)..."
  rclone size "$REMOTE" "${RC_FLAGS[@]}"
}

cmd_list() {
  rclone lsf --recursive --files-only --format "sp" --separator "  " "$REMOTE" "${RC_FLAGS[@]}"
}

cmd_download() {
  mkdir -p "$DEST_DIR" "$LOG_DIR"
  local logfile="$LOG_DIR/download_$(date '+%Y%m%d_%H%M%S').log"

  if [[ "$CHECKSUM" == "1" ]]; then
    RC_FLAGS+=(--checksum)
    log "已启用 MD5 比对模式 (会重算本地文件校验和,比默认慢)"
  fi

  log "远端: $REMOTE (folder=$FOLDER_ID)"
  log "本地: $(readlink -f "$DEST_DIR")"
  log "日志: $logfile"
  log "开始下载 (中断后重跑本命令即可续传)"
  echo

  # copy 而非 sync: 绝不删除本地已有文件
  # --multi-thread-*: 单个大文件拆多流下载,对数据集里的大压缩包提速明显
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
  log "建议执行 ./download_v2x.sh verify 校验完整性"
}

cmd_verify() {
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
    # Google Docs 原生格式文件(本数据集里是 ReadMe.docx)没有 MD5,rclone 只跳过不报错,
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
      log "补齐缺失文件:  ./download_v2x.sh download"
    fi
    # 内容损坏但 size/modtime 仍与远端一致时,普通 copy 会判定文件已是最新而跳过,必须按校验和比对才会重下
    if [[ "${n_differ:-0}" -gt 0 ]]; then
      log "修复损坏文件:  CHECKSUM=1 ./download_v2x.sh download"
    fi
    return 1
  }
}

# ---------------------------------------------------------------- 入口
main() {
  require_rclone
  setup_remote
  common_flags

  case "${1:-download}" in
    check)    cmd_check ;;
    list)     cmd_list ;;
    download) cmd_download ;;
    verify)   cmd_verify ;;
    *)        die "未知命令: $1  (可用: check | list | download | verify)" ;;
  esac
}

main "$@"
