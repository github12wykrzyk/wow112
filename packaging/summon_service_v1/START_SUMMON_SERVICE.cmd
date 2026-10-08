@echo off
setlocal
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\SummonService.ps1" -Action Start -Root "%~dp0."
exit /b %ERRORLEVEL%
