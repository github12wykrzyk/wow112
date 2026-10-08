@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0RUN_SUMMON_SOAK.ps1" %*
exit /b %ERRORLEVEL%
