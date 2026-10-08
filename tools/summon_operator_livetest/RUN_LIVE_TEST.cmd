@echo off
setlocal
cd /d "%~dp0"
echo ============================================================
echo WoW112 SUMMON OPERATOR - AUTONOMOUS HEADLESS LIVE TEST
echo CUSTOMER + 2 CLICKERS + SUMMONER + REAL PAYMENT + LEDGER
echo ============================================================
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Run-LiveTest.ps1" %*
set RC=%ERRORLEVEL%
echo.
if "%RC%"=="0" (
  echo FINAL: PASS
) else (
  echo FINAL: FAIL ^(exit %RC%^)
)
exit /b %RC%
