#!/usr/bin/env bash
# Colab にランタイムを作り、Musubi Tuner を学習できる状態にする。
#   ./up.sh [--drive|--no-drive]
# 途中で失敗しても、もう一度実行すれば済んだ手順は飛ばして続きから進む。
source "$(dirname "$0")/lib/common.sh"

parse_drive_flags "$@"
ensure_instance
log "$(msg instance_ready)"
warn "$(msg usage_hint)"
