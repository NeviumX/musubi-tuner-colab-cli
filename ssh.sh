#!/usr/bin/env bash
# config/ssh_config を使って Colab VM に入る。先頭の - で始まる引数は ssh のオプション、残りはリモートのコマンド。
#   ./ssh.sh                 シェルに入る
#   ./ssh.sh nvidia-smi      コマンドを実行する
#   ./ssh.sh -v true         接続の詳細を表示する。ssh_config を調整するときに使う
#   ./ssh.sh -t tmux attach -t sd-training   学習のコンソールを見る。抜けるのは Ctrl-b d
#   ./ssh.sh -O exit         共有 SSH 接続を閉じる
source "$(dirname "$0")/lib/common.sh"

# ProxyCommand はランタイムが無いと自動作成してしまうので、先に確かめる
session_exists || die "$(msg runtime_missing_start "$COLAB_SESSION")"

# -O exit や -O check は親接続への指示なので、新しく親を作らない
if [[ "${1:-}" != -O ]]; then
    ensure_master || die "$(msg ssh_failed_429)"
fi

opts=()
while [[ $# -gt 0 && "$1" == -* ]]; do opts+=("$1"); shift; done

exec ssh "${SSH_OPTS[@]}" ${opts[@]+"${opts[@]}"} "$SSH_HOST" "$@" <&3
