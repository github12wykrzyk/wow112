@echo off
setlocal EnableExtensions
cd /d "%~dp0"

set "BOOT=%TEMP%\wow112_ah_bootstrap_latest.ps1"
set "BOOTSHA=%TEMP%\wow112_ah_bootstrap_latest.sha256"
set "BASE=https://github.com/github12wykrzyk/wow112/releases/download/ah-de-latest"
set "BOOTURL=%BASE%/WoW112_AH_BOOTSTRAP_LATEST.ps1"
set "SHAURL=%BASE%/WoW112_AH_BOOTSTRAP_LATEST.sha256"

echo ============================================================
echo WoW112 AH - LATEST / CORP-FRIENDLY V4
echo ============================================================
echo Release-only bootstrap. No raw.githubusercontent.com. No GitHub API.
echo.

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "$h=@{'User-Agent'='WoW112-AH-Latest-Starter/4.0'}; Invoke-WebRequest -UseBasicParsing -Uri '%BOOTURL%' -Headers $h -OutFile '%BOOT%'; Invoke-WebRequest -UseBasicParsing -Uri '%SHAURL%' -Headers $h -OutFile '%BOOTSHA%'; $actual=(Get-FileHash '%BOOT%' -Algorithm SHA256).Hash.ToLowerInvariant(); $expected=((Get-Content '%BOOTSHA%' -Raw).Trim().Split()[0]).ToLowerInvariant(); if($actual -ne $expected){ throw ('bootstrap SHA256 mismatch expected=' + $expected + ' actual=' + $actual) }"
if errorlevel 1 (
  echo.
  echo ============================================================
  echo UPDATE FAILED - release bootstrap download or hash verification failed.
  echo Uzywany jest tylko github.com / releases/download.
  echo ============================================================
  del /q "%BOOT%" "%BOOTSHA%" >nul 2>&1
  pause
  exit /b 2
)

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%BOOT%" -InstallRoot "%~dp0"
set "RC=%ERRORLEVEL%"
del /q "%BOOT%" "%BOOTSHA%" >nul 2>&1
if not "%RC%"=="0" (
  echo.
  echo ============================================================
  echo UPDATE FAILED - kod %RC%
  echo Runtime updater uses GitHub Release assets only.
  echo ============================================================
  pause
)
exit /b %RC%
