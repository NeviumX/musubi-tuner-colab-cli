@echo off
rem Start MiniMax H3 LoRA training. Drop a training TOML on this file to use it instead of the default.
rem To use a non-default WSL distro, set MT_COLAB_WSL_DISTRO, for example to Ubuntu-24.04.
setlocal
chcp 65001 >nul
set "DISTRO_OPT="
if defined MT_COLAB_WSL_DISTRO set "DISTRO_OPT=-d %MT_COLAB_WSL_DISTRO%"
title MiniMax H3 training
wsl.exe %DISTRO_OPT% --cd "%~dp0." --exec bash -l ./start-training_MiniMaxH3.sh %*
echo.
pause
