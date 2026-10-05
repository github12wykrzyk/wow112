@echo off
setlocal
powershell.exe -NoProfile -File "%~dp0RUN_TELE_SNIFFER.ps1" %*
set ERR=%ERRORLEVEL%
endlocal & exit /b %ERR%
