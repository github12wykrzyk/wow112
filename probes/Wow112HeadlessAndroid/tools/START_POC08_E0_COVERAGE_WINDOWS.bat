@echo off
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0RUN_POC08_E0_COVERAGE_WINDOWS.ps1"
echo.
pause
