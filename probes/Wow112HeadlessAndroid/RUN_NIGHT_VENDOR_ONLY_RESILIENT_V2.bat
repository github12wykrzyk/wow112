@echo off
setlocal
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\RUN_NIGHT_VENDOR_ONLY_RESILIENT_V2.ps1"
set RC=%ERRORLEVEL%
echo.
echo Exit code: %RC%
pause
exit /b %RC%
