@echo off
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0RUN_POC08_C_PRICEBOOK_WINDOWS.ps1"
echo.
pause
