#!/usr/bin/env bash
# 動いている学習を止める。ランタイムは残る。そこまでの結果は pull-outputs で回収でき、--resume で再開できる。
source "$(dirname "$0")/lib/common.sh"

require_cmds colab ssh
session_exists || die "$(msg runtime_missing_start "$COLAB_SESSION")"
name="$(running_job)"
[[ -n "$name" ]] || die "$(msg no_running_job)"
log "$(msg stopping_training "$name")"
stop_remote_training "$name" || die "$(msg stop_training_failed)"
log "$(msg train_stopped "$name")"
