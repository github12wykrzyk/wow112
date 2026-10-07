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
echo WoW112 AH - HOTKEY LAUNCHER V4
echo ============================================================
echo Konto/postac/haslo: zapamietane lokalnie ^(haslo DPAPI Windows^)
echo.
echo [V] VENDOR STABLE - REAL BUY / osobny sprawdzony modul
echo [D] DE LAB FAST - REAL BUY / max 3 DE
echo [U] UNIFIED VENDOR+DE V4 - REAL BUY / jeden scan, wspolna kolejka
echo [A] DE LAB FAST - AUDIT ONLY / zero BUY
echo [T] UNIFIED VENDOR+DE V4 - AUDIT ONLY / zero BUY
echo [S] Zmien zapisany login/postac/haslo
echo [R] Otworz folder raportow
echo [Q] Wyjscie
echo.
echo U = jeden klient i jeden pelny snapshot AH; NIE uruchamia V i D jako dwoch procesow.
echo Live U: max 10 zakupow lacznie, max 3 DE, max 10g lacznie, max 3g DE.
echo V, D i U wykonuja realne zakupy. Sam hotkey jest uzbrojeniem trybu.
echo.
choice /C VDUATSRQ /N /M "Hotkey [V/D/U/A/T/S/R/Q]: "
if errorlevel 8 goto :EOF
if errorlevel 7 goto REPORTS
if errorlevel 6 goto SETUP
if errorlevel 5 goto UNIFIED_AUDIT
if errorlevel 4 goto AUDIT
if errorlevel 3 goto UNIFIED_LIVE
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

:UNIFIED_LIVE
cls
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0_launcher\START_AH.ps1" -Mode UnifiedLive
pause
goto MENU

:AUDIT
cls
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0_launcher\START_AH.ps1" -Mode DeAudit
pause
goto MENU

:UNIFIED_AUDIT
cls
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0_launcher\START_AH.ps1" -Mode UnifiedAudit
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
