@echo off
setlocal EnableExtensions
cd /d "%~dp0"

if not exist "%~dp0_launcher\START_AH.ps1" (
  echo ERROR: _launcher\START_AH.ps1 not found.
  pause
  exit /b 2
)

:ENSURE_PROFILE
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0_launcher\START_AH.ps1" -Mode EnsureProfile
if errorlevel 1 (
  echo.
  echo Nie udalo sie zapisac profilu logowania.
  pause
  exit /b 2
)

:MENU
cls
echo ============================================================
echo WoW112 AH - HOTKEY LAUNCHER
echo ============================================================
echo Konto/postac/haslo: zapamietane lokalnie ^(haslo DPAPI Windows^)
echo.
echo [V] VENDOR STABLE - REAL BUY / loop do nastepnej 08:00
echo [D] DE LAB FAST - REAL BUY / max 3 / max 3g / max 2g each
echo [A] DE LAB FAST - AUDIT ONLY / zero BUY
echo [S] Zmien zapisany login/postac/haslo
echo [R] Otworz folder raportow DE
echo [Q] Wyjscie
echo.
echo UWAGA: V i D wykonuja realne zakupy. Sam hotkey jest uzbrojeniem trybu.
echo Nie uruchamiaj V i D rownoczesnie na tej samej postaci.
echo.
choice /C VDASRQ /N /M "Hotkey [V/D/A/S/R/Q]: "
if errorlevel 6 goto :EOF
if errorlevel 5 goto REPORTS
if errorlevel 4 goto SETUP
if errorlevel 3 goto AUDIT
if errorlevel 2 goto DEBUY
if errorlevel 1 goto VENDOR

:VENDOR
cls
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0_launcher\START_AH.ps1" -Mode Vendor
pause
goto MENU

:DEBUY
cls
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0_launcher\START_AH.ps1" -Mode DeLive3
pause
goto MENU

:AUDIT
cls
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0_launcher\START_AH.ps1" -Mode DeAudit
pause
goto MENU

:SETUP
cls
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0_launcher\START_AH.ps1" -Mode Setup
pause
goto MENU

:REPORTS
if not exist "%~dp0DE_LAB\REPORTS" mkdir "%~dp0DE_LAB\REPORTS" >nul 2>nul
start "" explorer.exe "%~dp0DE_LAB\REPORTS"
goto MENU
