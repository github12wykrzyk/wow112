@echo off
setlocal
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0RUN_PORTAL_CLICKER_GUI.ps1"
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" (
  echo.
  echo Portal Clicker GUI zakonczyl sie kodem %RC%.
  pause
)
exit /b %RC%
