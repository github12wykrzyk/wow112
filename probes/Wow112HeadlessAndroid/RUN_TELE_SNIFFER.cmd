@echo off
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0RUN_TELE_SNIFFER.ps1" %*
set "RC=%ERRORLEVEL%"
endlocal & exit /b %RC%
