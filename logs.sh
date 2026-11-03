#!/usr/bin/env bash
# 学習のログを表示し直す。終わったら結果を回収する。Ctrl+C で表示をやめても学習は続く。
source "$(dirname "$0")/lib/common.sh"

require_cmds colab ssh rsync
session_exists || die "$(msg runtime_missing_start "$COLAB_SESSION")"
name="$(current_job)"
[[ -n "$name" ]] || die "$(msg no_job)"
follow_training "$name"
