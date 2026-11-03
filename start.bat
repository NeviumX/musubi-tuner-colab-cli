@echo off
rem Create a Colab runtime and prepare Musubi Tuner for training.
rem To use a non-default WSL distro, set MT_COLAB_WSL_DISTRO, for example to Ubuntu-24.04.
setlocal
chcp 65001 >nul
set "DISTRO_OPT="
if defined MT_COLAB_WSL_DISTRO set "DISTRO_OPT=-d %MT_COLAB_WSL_DISTRO%"
title Musubi Tuner on Colab
wsl.exe %DISTRO_OPT% --cd "%~dp0." --exec bash -l ./up.sh %*
echo.
pause
