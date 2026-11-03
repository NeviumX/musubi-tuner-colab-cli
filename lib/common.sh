#!/usr/bin/env bash
# 各スクリプト共通の設定読み込みと関数。source して使う。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_DIR="$ROOT/.state"
CONFIG_DIR="$ROOT/config"
mkdir -p "$STATE_DIR"

# Windows のエディターで保存した CRLF の設定でも読めるよう、\r を取り除いてから読む
load_config() {
    # shellcheck disable=SC1090
    source <(tr -d '\r' < "$1")
}
load_config "$CONFIG_DIR/config.env"
[[ -f "$CONFIG_DIR/config.local.env" ]] && load_config "$CONFIG_DIR/config.local.env"
# shellcheck source=messages.sh
source "$ROOT/lib/messages.sh"

# ssh は標準入力を読んで VM へ送るので、入力した答えを横取りしないよう、手元の入力は記述子 3 に退避して
# ほかのコマンドの標準入力は空にしておく
exec 3<&0 </dev/null

# ssh_config が $COLAB_SESSION を参照する
export COLAB_SESSION
command -v colab >/dev/null 2>&1 || export PATH="$HOME/.local/bin:$PATH"

SSH_HOST="${SSH_HOST:-colab-musubi-tuner}"
SSH_OPTS=(-F "$CONFIG_DIR/ssh_config")
# 共有 SSH 接続のソケットの置き場所
mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"

# Colab VM 側の場所
STAGE_DIR="$VM_ROOT/.musubi-colab-cli"
MUSUBI_DIR="$VM_ROOT/musubi-tuner"
VENV="$VM_ROOT/musubi-venv"
VM_PY="$VENV/bin/python"
VM_MODELS="$VM_ROOT/models"
VM_OUTPUTS="$VM_ROOT/outputs"
TMUX_SESSION=musubi-training
DRIVE_MOUNT="${DRIVE_MOUNT:-$VM_ROOT/drive}"
DRIVE_ROOT="$DRIVE_MOUNT/MyDrive/$DRIVE_FOLDER"
DRIVE_MODELS="$DRIVE_ROOT/models"
DRIVE_OUTPUTS="$DRIVE_ROOT/outputs"
# モデルと W&B のトークン。config.local.env に書く
HF_TOKEN="${HF_TOKEN:-}"
CIVITAI_TOKEN="${CIVITAI_TOKEN:-}"
WANDB_API_KEY="${WANDB_API_KEY:-}"
DRIVE_CHOICE_FILE="$STATE_DIR/drive-choice"
KEEPALIVE_SEC=604800

log()  { printf '\033[36m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
warn() { printf '\033[33m[%s] %s\033[0m\n' "$(date +%H:%M:%S)" "$*" >&2; }
die()  { printf '\033[31m[%s] %s\033[0m\n' "$(date +%H:%M:%S)" "$*" >&2; exit 1; }

require_cmds() {
    local c
    for c in "$@"; do
        command -v "$c" >/dev/null 2>&1 || die "$(msg cmd_missing "$c")"
    done
}

quoted() { printf '%q' "$1"; }

# 手元の入力を読む。入力が無いときは 1 を返す
ask() { read -r -u 3 -p "$1" REPLY; }

# ランタイムがあるかを colab status の出力で判定する
session_exists() {
    local out
    out="$(colab status -s "$COLAB_SESSION" 2>&1)" || return 1
    ! grep -qi "not found" <<<"$out"
}

# ssh_config の ControlMaster で作った共有 SSH 接続への操作。新しい接続は作らない
ctl() { ssh "${SSH_OPTS[@]}" -O "$1" "${@:2}" "$SSH_HOST"; }

stop_master() { ctl exit >/dev/null 2>&1 || true; }

# 共有 SSH 接続を用意する。Colab のランタイムには同時に 1 本しか SSH をつなげないため、
# すべての ssh はこの 1 本に相乗りする。
ensure_master() {
    ctl check >/dev/null 2>&1 && return 0
    (
        flock 9
        ctl check >/dev/null 2>&1 && exit 0
        setsid -w ssh "${SSH_OPTS[@]}" -o ControlMaster=yes -N -f "$SSH_HOST"
    ) 9>"$HOME/.ssh/colab-cm-$COLAB_SESSION.lock"
}

# Colab VM 上でコマンドを実行する。
# colab ssh はランタイムが無いと新しく作るので、先に存在を確かめる。
rssh() {
    if ! session_exists; then
        warn "$(msg no_runtime_skip_ssh "$COLAB_SESSION")"
        return 255
    fi
    ensure_master || return 255
    ssh "${SSH_OPTS[@]}" "$SSH_HOST" "$@"
}

# 指定した変数を「NAME=値 ...」の形にして、リモートのコマンドの前に付けられるようにする
remote_env() {
    local v out=""
    for v in "$@"; do out+="$v=$(printf '%q' "${!v}") "; done
    printf '%s' "$out"
}

# SSH が通るまで待つ。VM の起動直後は少し時間がかかる
wait_ssh() {
    local i err
    for i in 1 2 3 4 5 6; do
        err="$(rssh true 2>&1 >/dev/null)" && return 0
        if grep -q "429" <<<"$err"; then
            warn "$(msg ssh_busy_429 "$i")"
        else
            warn "$(msg ssh_waiting "$i")"
        fi
        sleep 10
    done
    die "$(msg ssh_failed)"
}

check_gpu() {
    local gpu want="$EXPECT_GPU_REGEX"
    gpu="$(rssh "nvidia-smi --query-gpu=name,memory.total --format=csv,noheader" 2>/dev/null | head -n 1 || true)"
    log "$(msg gpu_line "${gpu:-$(msg gpu_unknown)}")"
    # 空なら GPU の種類名で判定する。G4 は表示名が分からないので確かめない
    if [[ -z "$want" ]]; then
        [[ "$GPU" == G4 ]] && return 0
        want="$GPU"
    fi
    [[ "$gpu" =~ $want ]] && return 0

    warn "$(msg gpu_mismatch "$want")"
    case "$ON_GPU_MISMATCH" in
        continue) return 0 ;;
        stop) REPLY=n ;;
        *) ask "$(msg gpu_continue_prompt)" || REPLY=n ;;
    esac
    [[ "$REPLY" =~ ^[yY] ]] && return 0

    log "$(msg stopping_to_save)"
    stop_master
    colab stop -s "$COLAB_SESSION" || true
    die "$(msg gpu_aborted)"
}

# ---- Google ドライブ ----
DRIVE_READY=0

# マウントすると MyDrive が現れ、flush_and_unmount で消える
drive_mounted() { rssh "test -d $(quoted "$DRIVE_MOUNT/MyDrive")" 2>/dev/null; }

# マウント済みかどうかだけを調べる。認可画面は出さない
detect_drive() {
    DRIVE_READY=0
    if [[ "$USE_DRIVE" != 0 ]] && drive_mounted; then DRIVE_READY=1; fi
    return 0
}

# --drive と --no-drive を受け取る。残りの引数は ARGS に入る
ARGS=()
parse_drive_flags() {
    local a
    for a in "$@"; do
        case "$a" in
            --drive) USE_DRIVE=1 ;;
            --no-drive) USE_DRIVE=0 ;;
            *) ARGS+=("$a") ;;
        esac
    done
}

# USE_DRIVE=ask なら、ランタイムを作る前に Google ドライブを使うか尋ねる。答えはランタイムを削除するまで覚えておく
decide_drive() {
    [[ "$USE_DRIVE" == ask ]] || { printf '%s' "$USE_DRIVE" > "$DRIVE_CHOICE_FILE"; return 0; }
    if [[ -f "$DRIVE_CHOICE_FILE" ]] && session_exists; then
        USE_DRIVE="$(cat "$DRIVE_CHOICE_FILE")"
        return 0
    fi
    ask "$(msg drive_ask)" || REPLY=n
    if [[ "$REPLY" =~ ^[nN] ]]; then USE_DRIVE=0; else USE_DRIVE=1; fi
    printf '%s' "$USE_DRIVE" > "$DRIVE_CHOICE_FILE"
}

# USE_DRIVE=1 なら Drive をマウントする。初回は Google の認可画面の URL が表示され、Enter を待つ。
ensure_drive() {
    DRIVE_READY=0
    [[ "$USE_DRIVE" == 1 ]] || return 0
    if drive_mounted; then
        log "$(msg drive_already)"
        DRIVE_READY=1
        return 0
    fi
    log "$(msg drive_mounting)"
    colab drivemount -s "$COLAB_SESSION" "$DRIVE_MOUNT" <&3 || true
    if drive_mounted; then
        DRIVE_READY=1
        log "$(msg drive_ready "MyDrive/$DRIVE_FOLDER")"
    else
        warn "$(msg drive_failed)"
    fi
}

# Drive への書き込みを終わらせてからアンマウントする。ランタイムの削除前に呼ぶ。
flush_drive() {
    drive_mounted || return 0
    log "$(msg drive_flushing)"
    local out
    if out="$(printf 'from google.colab import drive\ndrive.flush_and_unmount()\nprint("FLUSHED")\n' |
              colab exec -s "$COLAB_SESSION" --timeout 300 2>&1)" && grep -q FLUSHED <<<"$out"; then
        log "$(msg drive_flushed)"
    else
        printf '%s\n' "$out" | tail -n 5 | sed 's/^/    /' >&2
        warn "$(msg drive_flush_failed)"
    fi
}

# ---- Colab VM の準備 ----
# モデルのダウンロードと学習に使うトークンを JSON にする。値は英数字と記号の一部だけを受け付ける
tokens_json() {
    local name value out="" sep=""
    for name in HF_TOKEN CIVITAI_TOKEN WANDB_API_KEY; do
        value="${!name:-}"
        [[ -n "$value" ]] || continue
        if [[ ! "$value" =~ ^[A-Za-z0-9_.:-]+$ ]]; then
            warn "$(msg token_invalid "$name")"
            continue
        fi
        out+="$sep\"$name\":\"$value\""
        sep=","
    done
    printf '{%s}' "$out"
}

# VM で動かす Python のファイルとトークンを送る。トークンはコマンドの引数に載せず、標準入力で渡して root だけが読めるファイルに置く
upload_files() {
    local stage
    stage="$(quoted "$STAGE_DIR")"
    tar -C "$ROOT/lib" -cf - remote_train.py train_entry.py model_download.py |
        rssh "mkdir -p $stage/state $stage/jobs && tar -C $stage -xf -" || die "$(msg upload_failed)"
    tokens_json | rssh "umask 077 && cat > $stage/state/tokens.json" || warn "$(msg token_upload_failed)"
}

# Colab VM で Musubi Tuner の環境を作る。済んでいれば何もしない
remote_setup() {
    cat "$ROOT/lib/messages.sh" "$ROOT/lib/remote-setup.sh" |
        rssh "$(remote_env MUSUBI_REPO MUSUBI_REF MUSUBI_EXTRA_PACKAGES APT_PACKAGES VM_ROOT STAGE_DIR MSG_LANG) bash -s" ||
        die "$(msg setup_failed)"
}

# ランタイムを用意して、学習できる状態にする。up.sh の本体で、学習の開始でも呼ぶので、ランタイムが無くても学習を始められる。
# 途中で失敗しても、もう一度実行すれば済んだ手順は飛ばして続きから進む。
ensure_instance() {
    require_cmds colab ssh tar rsync python3
    decide_drive
    log "$(msg units_left)"
    colab usage 2>/dev/null | sed 's/^/    /' || true

    if session_exists; then
        log "$(msg runtime_exists "$COLAB_SESSION")"
    else
        local new_args=(-s "$COLAB_SESSION" --gpu "$GPU")
        [[ "$HIGH_MEM" == 1 ]] && new_args+=(--high-mem)
        # 前のランタイムへの共有 SSH 接続が残っていたら閉じる
        stop_master
        log "$(msg runtime_creating "colab new ${new_args[*]}")"
        colab new "${new_args[@]}"
    fi

    log "$(msg ssh_connecting)"
    wait_ssh
    check_gpu
    ensure_drive
    log "$(msg preparing)"
    upload_files
    remote_setup
}

setup_done() { rssh "test -f $(quoted "$STAGE_DIR/state/setup-done")" 2>/dev/null; }

# ---- 学習の状態 ----
job_dir() { printf '%s' "$STAGE_DIR/jobs/$1"; }

current_job() { rssh "cat $(quoted "$STAGE_DIR/current") 2>/dev/null" 2>/dev/null || true; }

# running / succeeded / failed / stopped / crashed を返す。VM に記録が無ければ空
job_state() {
    local q
    q="$(quoted "$(job_dir "$1")")"
    rssh "s=\$(sed -n 's/.*\"state\": \"\\([a-z]*\\)\".*/\\1/p' $q/status.json 2>/dev/null)
          if [ \"\$s\" = running ] && ! kill -0 \"\$(cat $q/pid 2>/dev/null)\" 2>/dev/null; then s=crashed; fi
          echo \"\$s\"" 2>/dev/null || true
}

# 学習が動いているなら、その名前を返す
running_job() {
    local name
    name="$(current_job)"
    [[ -n "$name" && "$(job_state "$name")" == running ]] && printf '%s' "$name"
    return 0
}

# ---- 学習中のランタイムの維持 ----
# Colab はカーネルが動いている間だけランタイムを生かす。SSH の接続は動きとして数えられないと考えて、
# 学習の間はカーネルでも待ち続けるコードを実行しておく。colab exec が切れてもカーネル側のコードは止まらない。
start_keepalive() {
    local file="$STATE_DIR/keepalive.py"
    cat > "$file" <<EOF
import json, os, time
path = $(python3 -c 'import json, sys; print(json.dumps(sys.argv[1]))' "$(job_dir "$1")/status.json")
end = time.time() + $KEEPALIVE_SEC
while time.time() < end:
    try:
        if json.load(open(path))["state"] != "running" or time.time() - os.path.getmtime(path) > 900:
            break
    except OSError:
        break
    except ValueError:
        pass
    time.sleep(30)
EOF
    setsid nohup colab exec -s "$COLAB_SESSION" -f "$file" --timeout "$KEEPALIVE_SEC" >/dev/null 2>&1 &
    disown
}

# ---- 学習結果の回収 ----
output_dir() {
    case "$OUTPUT_DIR" in
        /*) printf '%s' "$OUTPUT_DIR" ;;
        *)  printf '%s' "$ROOT/$OUTPUT_DIR" ;;
    esac
}

vm_rsync() { rsync -rlt --partial-dir=.rsync-partial -e "ssh ${SSH_OPTS[*]@Q}" "$@"; }

# VM のフォルダーを手元へコピーする。再開用の -state は別に扱い、VM から消えた古い -state は手元でも消す。
# 引数 3 が verify なら、中身を比べて全部一致したことを確かめる。
pull_dir() {
    local src="$1" dest="$2" mode="${3:-}" check=() differences
    ensure_master || return 1
    mkdir -p "$dest"
    [[ "$mode" == verify ]] && check=(--checksum)
    vm_rsync "${check[@]}" --exclude='*-state/' --exclude='.rsync-partial/' "$SSH_HOST:$src/" "$dest/" || return 1
    if [[ "$PULL_STATE" == 1 ]]; then
        vm_rsync "${check[@]}" --delete --include='/*-state/***' --exclude='*' "$SSH_HOST:$src/" "$dest/" || return 1
    fi
    [[ "$mode" == verify ]] || return 0
    local state_filter=(--exclude='*-state/')
    [[ "$PULL_STATE" == 1 ]] && state_filter=()
    differences="$(vm_rsync --checksum --dry-run --itemize-changes "${state_filter[@]}" --exclude='.rsync-partial/' "$SSH_HOST:$src/" "$dest/" |
                   grep -v '/$' || true)"
    [[ -z "$differences" ]]
}

# VM に残っている学習結果をすべて手元へコピーする
pull_all_outputs() {
    local src="$1" names name failed=0
    names="$(rssh "ls -1 $(quoted "$src") 2>/dev/null" 2>/dev/null || true)"
    if [[ -z "$names" ]]; then
        log "$(msg pull_none)"
        return 0
    fi
    while IFS= read -r name; do
        log "$(msg pull_start "$name" "$(output_dir)/$name")"
        if pull_dir "$src/$name" "$(output_dir)/$name" verify; then
            log "$(msg pull_verified "$name")"
        else
            warn "$(msg pull_failed "$name")"
            failed=1
        fi
    done <<<"$names"
    return "$failed"
}

# ---- 学習の表示 ----
PULLER_PID=""

# 学習の途中でも手元へコピーしておく。VM が途中で回収されても、そこまでの結果が残る
start_puller() {
    local src="$1" dest="$2"
    (( PULL_INTERVAL_SEC > 0 )) || return 0
    local parent=$$
    (
        trap - INT TERM HUP
        # ウィンドウを閉じて親が消えたら、一緒に終わる
        while sleep "$PULL_INTERVAL_SEC" && kill -0 "$parent" 2>/dev/null; do
            pull_dir "$src" "$dest" >/dev/null 2>&1 || true
        done
    ) &
    PULLER_PID=$!
}

stop_puller() {
    [[ -n "$PULLER_PID" ]] || return 0
    kill "$PULLER_PID" 2>/dev/null || true
    wait "$PULLER_PID" 2>/dev/null || true
    PULLER_PID=""
}

on_detach() {
    stop_puller
    echo
    warn "$(msg detached)"
    exit 0
}

# 学習のログを表示し続け、終わったら結果を回収する。Ctrl+C で表示だけをやめる
follow_training() {
    local name="$1" job q save_to output state lines=200
    job="$(job_dir "$name")"
    q="$(quoted "$job")"
    save_to="$(rssh "cat $q/save_to" 2>/dev/null || echo local)"
    output="$(rssh "cat $q/output_dir" 2>/dev/null || true)"
    trap on_detach INT TERM HUP
    log "$(msg follow_start "$name")"
    [[ "$save_to" == local && -n "$output" ]] && start_puller "$output" "$(output_dir)/$name"
    while true; do
        rssh "tail -n $lines -F $q/run.log --pid=\"\$(cat $q/pid)\" 2>/dev/null" || true
        state="$(job_state "$name")"
        [[ "$state" == running ]] || break
        # SSH が切れただけなら、つなぎ直して続きを表示する
        stop_puller
        session_exists || { state=gone; break; }
        warn "$(msg follow_reconnect)"
        sleep 10
        lines=20
        [[ "$save_to" == local && -n "$output" ]] && start_puller "$output" "$(output_dir)/$name"
    done
    stop_puller
    trap - INT TERM HUP
    finish_training "$name" "$state" "$save_to" "$output"
}

# 学習が終わった後の処理。成功して保存を確かめられたときだけ 0 を返す
finish_training() {
    local name="$1" state="$2" save_to="$3" output="$4" saved=1
    echo
    case "$state" in
        succeeded) log "$(msg train_succeeded "$name")" ;;
        stopped)   warn "$(msg train_stopped "$name")" ;;
        gone)      die "$(msg train_gone "$COLAB_SESSION")" ;;
        *)         warn "$(msg train_failed "$name" "$state")" ;;
    esac

    if [[ "$save_to" == drive ]]; then
        log "$(msg saved_on_drive "${output#"$DRIVE_MOUNT"/}")"
    elif [[ -n "$output" ]]; then
        log "$(msg pull_start "$name" "$(output_dir)/$name")"
        if pull_dir "$output" "$(output_dir)/$name" verify; then
            log "$(msg pull_verified "$name")"
        else
            saved=0
            warn "$(msg pull_failed "$name")"
        fi
    fi

    if [[ "$state" == succeeded && "$saved" == 1 && "$STOP_AFTER_TRAINING" == 1 ]]; then
        teardown_runtime auto
    else
        warn "$(msg runtime_still_billed)"
    fi
    [[ "$state" == succeeded && "$saved" == 1 ]]
}

# ---- ランタイムの削除 ----
# 学習結果の回収 → 学習の停止 → Drive の書き込み完了 → 接続を閉じる → colab stop の順。
# 回収できなかったときは、引数が auto なら削除せずに 1 を返し、それ以外なら削除するか尋ねる。
teardown_runtime() {
    local mode="${1:-ask}" name
    if session_exists; then
        name="$(running_job)"
        if [[ -n "$name" && "$mode" != auto ]]; then
            ask "$(msg training_running_delete "$name")" || REPLY=n
            [[ "$REPLY" =~ ^[yY] ]] || { warn "$(msg not_deleted)"; return 1; }
            stop_remote_training "$name" || true
        fi
        if [[ "$PULL_OUTPUTS_ON_STOP" == 1 ]] && ! pull_all_outputs "$VM_OUTPUTS"; then
            REPLY=n
            [[ "$mode" == auto ]] || { ask "$(msg delete_anyway)" || REPLY=n; }
            [[ "$REPLY" =~ ^[yY] ]] || { warn "$(msg not_deleted)"; return 1; }
        fi
        flush_drive
        stop_master
        log "$(msg stopping_runtime "$COLAB_SESSION")"
        colab stop -s "$COLAB_SESSION"
    else
        stop_master
        log "$(msg runtime_already_gone "$COLAB_SESSION")"
    fi
    rm -f "$DRIVE_CHOICE_FILE"
    log "$(msg usage_after_stop)"
    colab usage | sed 's/^/    /'
}

stop_remote_training() {
    rssh "$(quoted "$VM_PY") $(quoted "$STAGE_DIR/remote_train.py") stop $(quoted "$(job_dir "$1")")"
}
