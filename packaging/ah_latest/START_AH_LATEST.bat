@echo off
setlocal EnableExtensions
cd /d "%~dp0"

set "BOOT=%TEMP%\wow112_ah_bootstrap_latest.ps1"
set "BOOTSHA=%TEMP%\wow112_ah_bootstrap_latest.sha256"
set "BASE=https://github.com/github12wykrzyk/wow112/releases/download/ah-de-latest"
set "BOOTURL=%BASE%/WoW112_AH_BOOTSTRAP_LATEST.ps1"
set "SHAURL=%BASE%/WoW112_AH_BOOTSTRAP_LATEST.sha256"

echo ============================================================
echo WoW112 AH - LATEST / CORP-FRIENDLY V5 PROXYSAFE
echo ============================================================
echo Release-only bootstrap. No raw.githubusercontent.com. No GitHub API.
echo.

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "$h=@{'User-Agent'='WoW112-AH-Latest-Starter/5.0'}; Invoke-WebRequest -UseBasicParsing -Uri '%BOOTURL%' -Headers $h -OutFile '%BOOT%'; Invoke-WebRequest -UseBasicParsing -Uri '%SHAURL%' -Headers $h -OutFile '%BOOTSHA%'; $actual=(Get-FileHash '%BOOT%' -Algorithm SHA256).Hash.ToLowerInvariant(); $expected=((Get-Content '%BOOTSHA%' -Raw).Trim().Split()[0]).ToLowerInvariant(); if($actual -ne $expected){ throw ('bootstrap SHA256 mismatch expected=' + $expected + ' actual=' + $actual) }"
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

REM Corporate proxy fix: verified bootstrap is patched only in TEMP so manifest is
REM downloaded to a real file and parsed with Get-Content -Raw instead of IWR .Content.
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "$p='%BOOT%'; $t=Get-Content -LiteralPath $p -Raw; $old='$remoteManifest = (Invoke-WebRequest -UseBasicParsing -Uri $ManifestUrl -Headers $Headers).Content'; $new=[string]::Join([Environment]::NewLine,@('$manifestTmp = Join-Path $env:TEMP (''wow112_ah_manifest_'' + [guid]::NewGuid().ToString(''N'') + ''.txt'')','try {','    $manifestFetchUrl = $ManifestUrl + ''?cb='' + [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()','    Invoke-WebRequest -UseBasicParsing -Uri $manifestFetchUrl -Headers $Headers -OutFile $manifestTmp','    $remoteManifest = Get-Content -LiteralPath $manifestTmp -Raw','}','finally {','    Remove-Item -LiteralPath $manifestTmp -Force -ErrorAction SilentlyContinue','}')); if(-not $t.Contains($old)){ if(-not $t.Contains('Get-Content -LiteralPath $manifestTmp -Raw')){ throw 'Proxy-fix anchor not found in downloaded bootstrap.' } } else { $t=$t.Replace($old,$new); Set-Content -LiteralPath $p -Value $t -Encoding UTF8 }"
if errorlevel 1 (
  echo.
  echo UPDATE FAILED - proxy-safe manifest patch failed.
  del /q "%BOOT%" "%BOOTSHA%" >nul 2>&1
  pause
  exit /b 3
)

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%BOOT%" -InstallRoot "%CD%"
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
