@echo off
setlocal
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\SummonService.ps1" -Action Status -Root "%~dp0" >nul 2>&1
if errorlevel 1 (
  echo ERROR: Summon Service is not healthy/running. Start or repair the service before opening the console.
  exit /b 3
)
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\SummonService.ps1" -Action Console -Root "%~dp0"
exit /b %ERRORLEVEL%
