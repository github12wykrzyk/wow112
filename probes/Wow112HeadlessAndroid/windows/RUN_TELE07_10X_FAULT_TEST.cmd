@echo off
setlocal
cd /d "%~dp0"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0TELE07_RUNNER.ps1" -Cycles 10 -FaultRole SLAVE1 -FaultCycle 2
set RC=%ERRORLEVEL%
echo.
echo TELE07 10X FAULT TEST exit code: %RC%
pause
exit /b %RC%
