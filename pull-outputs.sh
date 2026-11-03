#!/usr/bin/env bash
# 学習結果を手元の OUTPUT_DIR にコピーする。ランタイムは止めない。
#   ./pull-outputs.sh          VM の outputs からコピーする
#   ./pull-outputs.sh --drive  Google ドライブの outputs からコピーする
source "$(dirname "$0")/lib/common.sh"

require_cmds colab ssh rsync
session_exists || die "$(msg runtime_missing_start "$COLAB_SESSION")"
if [[ "${1:-}" == --drive ]]; then
    drive_mounted || die "$(msg pull_drive_needed)"
    pull_all_outputs "$DRIVE_OUTPUTS"
else
    pull_all_outputs "$VM_OUTPUTS"
fi
