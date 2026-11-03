@echo off
rem Stop the running training. The runtime is kept.
rem To use a non-default WSL distro, set MT_COLAB_WSL_DISTRO, for example to Ubuntu-24.04.
setlocal
chcp 65001 >nul
set "DISTRO_OPT="
if defined MT_COLAB_WSL_DISTRO set "DISTRO_OPT=-d %MT_COLAB_WSL_DISTRO%"
wsl.exe %DISTRO_OPT% --cd "%~dp0." --exec bash -l ./stop-training.sh %*
echo.
pause
