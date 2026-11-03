#!/usr/bin/env bash
# 学習に使うモデルをランタイムにダウンロードする。ランタイムが無ければ作るところから行う。
#   ./model-download.sh                             URL、ファイル名、保存する場所を尋ねる
#   ./model-download.sh URL [URL ...] [--to-drive]  指定の URL をダウンロードする
# Hugging Face と Civitai はページの URL を貼り付けられる。ほかの https の URL も使える。
# 成功したら 0 で終わる。model-download.bat は、失敗したときだけウィンドウを残す。
source "$(dirname "$0")/lib/common.sh"

parse_drive_flags "$@"
set -- ${ARGS[@]+"${ARGS[@]}"}
urls=() to_drive=0
for a in "$@"; do
    case "$a" in
        --to-drive) to_drive=1 ;;
        *) urls+=("$a") ;;
    esac
done
[[ "$to_drive" == 1 ]] && USE_DRIVE=1

require_cmds colab ssh tar rsync python3
if session_exists && setup_done; then
    detect_drive
    upload_files
else
    ensure_instance
fi

filename=""
if (( ${#urls[@]} == 0 )); then
    while true; do
        ask "$(msg md_url)" || exit 1
        url="${REPLY//[[:space:]]/}"
        [[ -n "$url" ]] && break
    done
    urls=("$url")
    ask "$(msg md_filename)" || exit 1
    filename="$REPLY"
    if [[ "$DRIVE_READY" == 1 ]]; then
        msg md_where; echo
        ask "$(msg md_where_prompt)" || exit 1
        [[ "${REPLY:-2}" == 1 ]] || to_drive=1
    else
        log "$(msg md_no_drive)"
    fi
fi
[[ "$to_drive" == 1 && "$DRIVE_READY" != 1 ]] && die "$(msg pull_drive_needed)"

drive_args=""
[[ "$DRIVE_READY" == 1 ]] && drive_args="--drive-models $(quoted "$DRIVE_MODELS")"
[[ "$to_drive" == 1 ]] && drive_args+=" --to-drive"
for url in "${urls[@]}"; do
    log "$(msg md_starting "$url")"
    # トークンは標準入力で渡す。進み具合のバーは ssh 越しに 1 行で書き換わる
    tokens_json | rssh "MSG_LANG=$MSG_LANG $(quoted "$VM_PY") $(quoted "$STAGE_DIR/model_download.py") download \
        --models $(quoted "$VM_MODELS") --state $(quoted "$STAGE_DIR/state") --url $(quoted "$url") \
        --filename $(quoted "$filename") $drive_args --tokens-stdin" || die "$(msg md_failed)"
done
log "$(msg md_done)"
