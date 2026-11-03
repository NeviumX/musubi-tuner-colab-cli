#!/usr/bin/env bash
# Krea 2 の LoRA 学習を始める。TOML を省くと config/training/templates/krea2.toml に config/training/krea2.local.toml を重ねて使う。
#   ./start-training_Krea2.sh [TOML] [--save-to local|drive] [--resume] [--drive|--no-drive]
exec bash "$(dirname "$0")/lib/train.sh" krea2 "$@"
