@echo off
rem Download a model to the Colab runtime. The window stays open only when it fails.
rem To use a non-default WSL distro, set MT_COLAB_WSL_DISTRO, for example to Ubuntu-24.04.
setlocal
chcp 65001 >nul
set "DISTRO_OPT="
if defined MT_COLAB_WSL_DISTRO set "DISTRO_OPT=-d %MT_COLAB_WSL_DISTRO%"
title Model download
wsl.exe %DISTRO_OPT% --cd "%~dp0." --exec bash -l ./model-download.sh %*
if errorlevel 1 (
    echo.
    pause
)
