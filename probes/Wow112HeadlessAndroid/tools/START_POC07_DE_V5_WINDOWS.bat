@echo off
setlocal
title WoW112 Windows Headless POC07 DE V5
cd /d "%~dp0"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0RUN_POC07_DE_V5_WINDOWS.ps1"
set CODE=%ERRORLEVEL%
echo.
echo ============================================================
if not "%CODE%"=="0" (
  echo WINDOWS V5 zakonczyl sie bledem. Exit code: %CODE%
  echo Sprawdz: runtime\V5_WINDOWS_FATAL.log
  echo Sprawdz: runtime\V5_WINDOWS_SCAN.log
  echo Sprawdz: runtime\V5_GATE.log
) else (
  echo WINDOWS V5 zakonczony poprawnie. Exit code: 0
)
echo ============================================================
echo.
pause
exit /b %CODE%
