@echo off
setlocal
title WoW112 Windows Headless POC07 DE V5
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0RUN_POC07_DE_V5_WINDOWS.ps1"
set CODE=%ERRORLEVEL%
echo.
echo Exit code: %CODE%
pause
exit /b %CODE%
