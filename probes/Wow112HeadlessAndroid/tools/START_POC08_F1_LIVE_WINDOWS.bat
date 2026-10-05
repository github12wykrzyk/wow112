@echo off
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0RUN_POC08_F1_LIVE_WINDOWS.ps1"
pause
