#!/usr/bin/env bash
#
# examples/download_v2x.sh —— 预置参数示例:固定指向 DAIR-V2X / V2X-Seq 数据集文件夹
#
# 下载逻辑全在仓库根目录的 gdrive-download.sh,这里只负责预置链接与默认目录。
# 用法与改名前的 download_v2x.sh 完全一致:
#
#   ./examples/download_v2x.sh check | list | download | verify
#   DEST_DIR=/data/v2x SA_FILE=/etc/v2x/sa.json ./examples/download_v2x.sh download
#
# 想给自己的 Drive 文件夹配一个同样的入口:复制本文件,改掉 V2X_FOLDER_ID 与默认 DEST_DIR 即可。

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

# 数据集文件夹: https://drive.google.com/drive/folders/1gnrw5llXAIxuB9sEKKCm6xTaJ5HQAw2e
# 保留 FOLDER_ID 环境变量,便于指向同一数据集的镜像目录
V2X_FOLDER_ID="${FOLDER_ID:-1gnrw5llXAIxuB9sEKKCm6xTaJ5HQAw2e}"
export DEFAULT_LINK="https://drive.google.com/drive/folders/${V2X_FOLDER_ID}"

# 原默认目录是 ./v2x-data,主脚本默认 ./downloads,这里保持原样
export DEST_DIR="${DEST_DIR:-./v2x-data}"

exec "$ROOT/gdrive-download.sh" "$@"
