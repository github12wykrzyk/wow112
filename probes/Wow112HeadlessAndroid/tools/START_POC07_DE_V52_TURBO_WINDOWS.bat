@echo off
setlocal
cd /d "%~dp0"
echo ============================================================
echo WoW112 WINDOWS HEADLESS - V5.2 TURBO OFFLINE
echo ============================================================
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0RUN_POC07_DE_V52_TURBO_WINDOWS.ps1"
set CODE=%ERRORLEVEL%
echo.
echo ============================================================
echo WINDOWS V5.2 TURBO zakonczony. Exit code: %CODE%
echo ============================================================
pause
exit /b %CODE%
