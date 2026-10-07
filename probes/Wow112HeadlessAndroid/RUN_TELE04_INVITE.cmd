@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0RUN_TELE04_INVITE.ps1"
set RC=%ERRORLEVEL%
endlocal & exit /b %RC%
