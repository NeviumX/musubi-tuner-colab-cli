#!/usr/bin/env bash
# LoRA の学習を始める。start-training_*.sh から呼ばれる。ランタイムが無ければ作るところから行う。
#   lib/train.sh <qwen_image|zimage|krea2|minimax_h3> [TOML] [--save-to local|drive] [--resume] [--drive|--no-drive]
# 学習のログを表示し続け、終わったら結果を回収する。Ctrl+C で表示をやめても学習は続き、logs.bat で表示し直せる。
source "$(dirname "$0")/common.sh"

route="${1:?route}"
shift
case "$route" in
    qwen_image|zimage|krea2|minimax_h3) ;;
    *) die "$(msg unknown_route "$route")" ;;
esac

parse_drive_flags "$@"
set -- ${ARGS[@]+"${ARGS[@]}"}
training="" resume=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --resume) resume=1; shift ;;
        --save-to) SAVE_TO="${2:-}"; shift 2 ;;
        -*) die "$(msg unknown_option "$1")" ;;
        *) training="$1"; shift ;;
    esac
done
case "$SAVE_TO" in ask|local|drive) ;; *) die "$(msg bad_save_to "$SAVE_TO")" ;; esac

# .bat にファイルをドラッグすると Windows のパスで届く
if [[ "$training" =~ ^[A-Za-z]:[\\/] ]]; then
    training="$(wslpath -u "$training")"
fi
training="${training:-$CONFIG_DIR/training/templates/$route.toml}"

require_cmds colab ssh tar rsync python3

# 動いている学習があれば、新しく始めずに表示だけをつなぐ
if session_exists; then
    running="$(running_job)"
    if [[ -n "$running" ]]; then
        warn "$(msg already_training "$running")"
        follow_training "$running"
        exit $?
    fi
fi

# ---- 手元での検査。ここで止めれば課金は発生しない ----
out="$STATE_DIR/job"
name="$(python3 "$ROOT/lib/prepare_job.py" --training "$training" --route "$route" \
    --out "$out" --root "$ROOT" --vm-root "$VM_ROOT" --stage "$STAGE_DIR" --catalog "$CONFIG_DIR/models.txt" \
    --lang "$MSG_LANG")" || die "$(msg job_invalid)"

# ---- 保存先と Google ドライブ ----
[[ "$SAVE_TO" == drive ]] && USE_DRIVE=1
decide_drive
if [[ "$SAVE_TO" == ask ]]; then
    if [[ "$USE_DRIVE" == 1 ]]; then
        msg save_to_choices; echo
        ask "$(msg save_to_prompt)" || REPLY=1
        if [[ "${REPLY:-1}" == 2 ]]; then SAVE_TO=drive; else SAVE_TO=local; fi
    else
        SAVE_TO=local
    fi
fi
if [[ "$SAVE_TO" == drive ]]; then
    output="$DRIVE_OUTPUTS/$name"
else
    output="$VM_OUTPUTS/$name"
fi
printf 'output_dir = %s\n' "$(python3 -c 'import json, sys; print(json.dumps(sys.argv[1], ensure_ascii=False))' "$output")" >> "$out/training.toml"
printf '%s' "$SAVE_TO" > "$out/save_to"
printf '%s' "$output" > "$out/output_dir"
log "$(msg job_ready "$name" "$SAVE_TO")"

# ---- ランタイムと Musubi Tuner ----
ensure_instance
if [[ "$SAVE_TO" == drive && "$DRIVE_READY" != 1 ]]; then
    die "$(msg drive_required)"
fi

# ---- ジョブとデータセットを送る ----
job="$(job_dir "$name")"
q_job="$(quoted "$job")"
log "$(msg sending_job)"
tar -C "$out" -cf - . |
    rssh "mkdir -p $q_job && cd $q_job && mkdir -p previous && mv -f run.log status.json pid previous/ 2>/dev/null; tar -xf - && mkdir -p $(quoted "$output")" ||
    die "$(msg upload_failed)"

# 手元で消したファイルが VM に残らないよう --delete で同じにする。rsync は更新時刻を保つので、
# VM の remote_train.py はファイルの大きさと更新時刻からキャッシュを作り直すかを決められる
while IFS=$'\t' read -r local_dir remote_dir; do
    [[ -n "$local_dir" ]] || continue
    log "$(msg sending_dataset "$local_dir")"
    rssh "mkdir -p $(quoted "$remote_dir")"
    vm_rsync --delete --info=stats0 "$local_dir/" "$SSH_HOST:$remote_dir/" || die "$(msg upload_failed)"
done < <(python3 -c 'import json, sys
for item in json.load(open(sys.argv[1]))["sync"]:
    print(item["local"], item["remote"], sep="\t")' "$out/job.json")

# ---- モデル ----
log "$(msg checking_models)"
drive_args=""
[[ "$DRIVE_READY" == 1 ]] && drive_args="--drive-models $(quoted "$DRIVE_MODELS")"
downloader="$(quoted "$VM_PY") $(quoted "$STAGE_DIR/model_download.py")"
model_args="--models $(quoted "$VM_MODELS") --state $(quoted "$STAGE_DIR/state") --job $q_job/job.json $drive_args"

# VM にもドライブにもカタログにも無いモデルは URL を尋ねる。TOML に書いた名前で保存するので、そのまま学習に使われる
added=()
while IFS=$'\t' read -r key file; do
    [[ -n "$key" ]] || continue
    warn "$(msg model_not_found "$key" "$file")"
    ask "$(msg model_url_prompt)" || REPLY=""
    url="${REPLY//[[:space:]]/}"
    [[ -n "$url" ]] || die "$(msg model_url_none "$file")"
    python3 -c 'import json, sys
path, file, url = sys.argv[1:4]
job = json.load(open(path, encoding="utf-8"))
for item in job["models"]:
    if item["path"].rsplit("/", 1)[-1] == file:
        item["url"] = url
json.dump(job, open(path, "w", encoding="utf-8"), ensure_ascii=False, indent=1)' "$out/job.json" "$file" "$url"
    added+=("$url"$'\t'"$file")
done < <(rssh "$downloader missing $model_args" || true)
if (( ${#added[@]} > 0 )); then
    rssh "cat > $q_job/job.json" < "$out/job.json" || die "$(msg upload_failed)"
fi

[[ "$DRIVE_READY" == 1 && "$MODEL_CACHE_DRIVE" == 1 ]] && drive_args+=" --to-drive"
tokens_json | rssh "MSG_LANG=$MSG_LANG $(quoted "$VM_PY") $(quoted "$STAGE_DIR/model_download.py") ensure \
    --models $(quoted "$VM_MODELS") --state $(quoted "$STAGE_DIR/state") --job $q_job/job.json $drive_args --tokens-stdin" ||
    die "$(msg models_failed)"

# 取得できた URL は次のランタイムで尋ねないよう残す
for entry in ${added[@]+"${added[@]}"}; do
    printf '%s\n' "$entry" >> "$CONFIG_DIR/models.local.txt"
    log "$(msg model_url_saved "${entry#*$'\t'}")"
done

# ---- 再開 ----
# 新しい VM に状態が無ければ、手元に回収してある状態を送る
if [[ "$resume" == 1 && "$SAVE_TO" == local ]] && ! rssh "ls -d $(quoted "$output")/*-state >/dev/null 2>&1" &&
   compgen -G "$(output_dir)/$name/*-state" >/dev/null; then
    log "$(msg sending_state)"
    vm_rsync --include='/*-state/***' --exclude='*' "$(output_dir)/$name/" "$SSH_HOST:$output/" || die "$(msg upload_failed)"
fi

# ---- 実行前の検査 ----
check_args=""
[[ "$resume" == 1 ]] && check_args="--resume"
code=0
result="$(rssh "$(quoted "$VM_PY") $(quoted "$STAGE_DIR/remote_train.py") check $q_job --musubi $(quoted "$MUSUBI_DIR") $check_args")" || code=$?
case "$result" in
    UNKNOWN_KEYS*) die "$(msg unknown_keys "${result#UNKNOWN_KEYS }")" ;;
    MISSING*)      die "$(msg missing_files "${result#MISSING }")" ;;
    NO_STATE*)     die "$(msg no_state "${result#NO_STATE }")" ;;
    NOTHING_LEFT*) log "$(msg nothing_left)"; exit 0 ;;
    RESUME*)       log "$(msg resuming "${result#RESUME }")" ;;
esac
[[ "$code" == 0 ]] || die "$(msg check_failed "$result")"

# ---- 学習の開始 ----
# tmux の中で動かすので、SSH が切れても学習は止まらない
launch="$(quoted "$VM_PY") $(quoted "$STAGE_DIR/remote_train.py") run $q_job --musubi $(quoted "$MUSUBI_DIR") --venv $(quoted "$VENV")"
rssh "tmux kill-session -t $TMUX_SESSION 2>/dev/null; printf %s $(quoted "$name") > $(quoted "$STAGE_DIR/current"); tmux new-session -d -s $TMUX_SESSION $(quoted "$launch")" ||
    die "$(msg launch_failed)"
for _ in $(seq 1 30); do
    rssh "test -f $q_job/pid" 2>/dev/null && break
    sleep 1
done
start_keepalive "$name"
log "$(msg training_started "$name")"
follow_training "$name"
