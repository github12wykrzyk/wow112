@echo off
setlocal EnableExtensions
cd /d "%~dp0"

set "BOOT=%TEMP%\wow112_ah_bootstrap_latest.ps1"
set "URL=https://raw.githubusercontent.com/github12wykrzyk/wow112/refs/heads/dev/windows-ah-de-liquidation-v3/packaging/ah_latest/bootstrap_latest.ps1"

echo ============================================================
echo WoW112 AH - LATEST
ECHO ============================================================
echo Pobieram aktualny bootstrap z GitHub...

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "Invoke-WebRequest -UseBasicParsing -Uri '%URL%' -OutFile '%BOOT%'"
if errorlevel 1 (
  echo.
  echo ERROR: nie udalo sie pobrac bootstrap_latest.ps1 z GitHub.
  pause
  exit /b 2
)

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%BOOT%" -InstallRoot "%~dp0"
set "RC=%ERRORLEVEL%"
del /q "%BOOT%" >nul 2>&1
exit /b %RC%
