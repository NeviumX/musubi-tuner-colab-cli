@echo off
rem Copy the training results on the VM to this PC. Pass --drive to copy from Google Drive.
rem To use a non-default WSL distro, set MT_COLAB_WSL_DISTRO, for example to Ubuntu-24.04.
setlocal
chcp 65001 >nul
set "DISTRO_OPT="
if defined MT_COLAB_WSL_DISTRO set "DISTRO_OPT=-d %MT_COLAB_WSL_DISTRO%"
wsl.exe %DISTRO_OPT% --cd "%~dp0." --exec bash -l ./pull-outputs.sh %*
echo.
pause
