#!/usr/bin/env bash
# Z-Image の LoRA 学習を始める。TOML を省くと config/training/templates/zimage.toml に config/training/zimage.local.toml を重ねて使う。
#   ./start-training_ZImage.sh [TOML] [--save-to local|drive] [--resume] [--drive|--no-drive]
exec bash "$(dirname "$0")/lib/train.sh" zimage "$@"
