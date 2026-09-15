@echo off
setlocal EnableExtensions
cd /d "%~dp0"
set "LOG=%~dp0RESTORE_V68_BUNDLE.log"
echo [%date% %time%] Starting V68 restore>"%LOG%"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0RESTORE_V68_BUNDLE.ps1" >>"%LOG%" 2>&1
if errorlevel 1 (
  echo.
  echo [ERROR] Restore failed. See:
  echo %LOG%
  type "%LOG%"
  pause
  exit /b 1
)
echo.
type "%LOG%"
echo.
echo [OK] V68 bundle restored.
pause
exit /b 0
