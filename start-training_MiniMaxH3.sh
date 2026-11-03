#!/usr/bin/env bash
# MiniMax H3 の LoRA 学習を始める。TOML を省くと config/training/templates/minimax_h3.toml に config/training/minimax_h3.local.toml を重ねて使う。
#   ./start-training_MiniMaxH3.sh [TOML] [--save-to local|drive] [--resume] [--drive|--no-drive]
exec bash "$(dirname "$0")/lib/train.sh" minimax_h3 "$@"
