@echo off
setlocal
cd /d "%~dp0"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0TELE06A_LIVE_4ACCOUNT.ps1"
echo.
echo Launcher finished. Press any key to close.
pause >nul
