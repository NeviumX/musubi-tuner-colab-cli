#!/usr/bin/env bash
# WSL の Ubuntu に必要なものを入れる。最初に 1 回だけ実行する。
set -euo pipefail

# shellcheck source=lib/messages.sh
source "$(dirname "$0")/lib/messages.sh"

msg sw_apt; echo
sudo apt-get update -qq
sudo apt-get install -y -qq openssh-client curl rsync tar python3

export PATH="$HOME/.local/bin:$PATH"

msg sw_uv; echo
if ! command -v uv >/dev/null 2>&1; then
    curl -LsSf https://astral.sh/uv/install.sh | sh
    export PATH="$HOME/.local/bin:$PATH"
fi
uv --version

msg sw_colab; echo
if command -v colab >/dev/null 2>&1; then
    uv tool upgrade google-colab-cli
else
    uv tool install google-colab-cli
fi

msg sw_key; echo
if [[ ! -f "$HOME/.ssh/id_ed25519" ]]; then
    mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
    ssh-keygen -t ed25519 -N "" -f "$HOME/.ssh/id_ed25519" -C "musubi-tuner-colab-cli"
else
    msg sw_key_exists; echo
fi

msg sw_done; echo
