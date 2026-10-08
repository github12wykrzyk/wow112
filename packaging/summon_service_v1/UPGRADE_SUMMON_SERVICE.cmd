@echo off
setlocal
if "%~1"=="" (
  echo Usage: UPGRADE_SUMMON_SERVICE.cmd ^<package.zip^> [expected-source-sha]
  exit /b 2
)
set "EXPECTED=%~2"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\SummonService.ps1" -Action Upgrade -Root "%~dp0" -Package "%~1" -ExpectedSourceSha "%EXPECTED%"
exit /b %ERRORLEVEL%
