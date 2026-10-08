@echo off
setlocal
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Invoke-SafeBackup.ps1" -Root "%~dp0"
exit /b %ERRORLEVEL%
