#!/usr/bin/env bash
# Qwen-Image の LoRA 学習を始める。TOML を省くと config/training/templates/qwen_image.toml に config/training/qwen_image.local.toml を重ねて使う。
#   ./start-training_QwenImage.sh [TOML] [--save-to local|drive] [--resume] [--drive|--no-drive]
exec bash "$(dirname "$0")/lib/train.sh" qwen_image "$@"
