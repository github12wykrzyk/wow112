@echo off
setlocal
cd /d "%~dp0"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0TELE07_RUNNER.ps1" -Cycles 1
set RC=%ERRORLEVEL%
echo.
echo TELE07 exit code: %RC%
pause
exit /b %RC%
