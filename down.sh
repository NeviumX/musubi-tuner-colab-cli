#!/usr/bin/env bash
# Colab のランタイムを削除する。
# PULL_OUTPUTS_ON_STOP=1 なら、削除の前に VM の学習結果を手元にコピーして中身を確かめる。
source "$(dirname "$0")/lib/common.sh"

require_cmds colab ssh rsync
teardown_runtime
