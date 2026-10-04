@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0RUN_PORTAL_CLICKER.ps1" %*
set ERR=%ERRORLEVEL%
endlocal & exit /b %ERR%
