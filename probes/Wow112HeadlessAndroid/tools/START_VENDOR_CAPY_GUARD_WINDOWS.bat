@echo off
setlocal
title WoW112 Vendor Capy/Turtle Guard BUY20G
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0RUN_VENDOR_CAPY_GUARD_WINDOWS.ps1"
set EC=%ERRORLEVEL%
echo.
echo [LAUNCHER] exit=%EC%
pause
exit /b %EC%
