@echo off
setlocal
cd /d "%~dp0"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0RUN_POC05.ps1"
set "RC=%ERRORLEVEL%"
echo.
if not "%RC%"=="0" echo POC-05 launcher zakonczyl sie bledem. Kod: %RC%
echo Nacisnij dowolny klawisz, aby zamknac okno.
pause >nul
exit /b %RC%
