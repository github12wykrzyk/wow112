@echo off
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0RUN_POC08_E_PROVENANCE_WINDOWS.ps1"
echo.
pause
