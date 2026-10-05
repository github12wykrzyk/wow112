@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0RUN_TELE_SNIFFER.ps1" %*
set "ERR=%ERRORLEVEL%"
if not "%ERR%"=="0" (
  echo.
  echo TELE launcher failed with code %ERR%.
  pause
)
endlocal & exit /b %ERR%
