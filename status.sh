#!/usr/bin/env bash
# ランタイム・Musubi Tuner・Google ドライブ・学習の状態をまとめて表示する。
source "$(dirname "$0")/lib/common.sh"

require_cmds colab ssh

msg st_runtime "$COLAB_SESSION"; echo
if session_exists; then
    colab status -s "$COLAB_SESSION" | sed 's/^/    /'

    msg st_vm; echo
    rssh "nvidia-smi --query-gpu=name,memory.used,memory.total --format=csv,noheader; free -g | sed -n 2p; df -h $(quoted "$VM_ROOT") | tail -n 1" \
        2>/dev/null | sed 's/^/    /' || echo "    $(msg st_ssh_fail)"
    if setup_done; then echo "    $(msg st_setup_done)"; else echo "    $(msg st_setup_not)"; fi
    if drive_mounted; then echo "    $(msg st_drive_on)"; else echo "    $(msg st_drive_off)"; fi
    name="$(current_job)"
    if [[ -n "$name" ]]; then
        echo "    $(msg st_job "$name" "$(job_state "$name")")"
        rssh "tail -c 600 $(quoted "$(job_dir "$name")/run.log") 2>/dev/null | tr '\r' '\n' | grep -v '^[[:space:]]*\$' | tail -n 1" \
            2>/dev/null | sed 's/^/    /' || true
    fi
else
    echo "    $(msg st_none)"
fi

msg st_units; echo
colab usage | sed 's/^/    /'
