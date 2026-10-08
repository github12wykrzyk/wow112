@echo off
setlocal EnableExtensions
cd /d "%~dp0"
set WOW112_AH_HELLO_TIMEOUT_SECS=120
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0START_AUTO_V2_BASELINE_FIX.ps1"
set RC=%ERRORLEVEL%
echo.
echo Exit code: %RC%
pause
exit /b %RC%
