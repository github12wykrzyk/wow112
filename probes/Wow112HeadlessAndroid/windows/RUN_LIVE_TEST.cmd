@echo off
setlocal
set "ROOT=%~dp0"

if not exist "%ROOT%LIVE_TEST_RUNNER.ps1" (
  echo.
  echo ERROR: LIVE_TEST_RUNNER.ps1 is missing.
  echo This usually means the CMD was launched directly from inside the ZIP archive.
  echo Right-click the ZIP ^> Extract All, then run RUN_LIVE_TEST.cmd from the extracted folder.
  echo.
  pause
  exit /b 2
)

if not exist "%ROOT%tele06a_acceptor_runtime.exe" (
  echo ERROR: tele06a_acceptor_runtime.exe is missing. Extract the complete ZIP first.
  pause
  exit /b 2
)

if not exist "%ROOT%tele06a_ritual_runtime.exe" (
  echo ERROR: tele06a_ritual_runtime.exe is missing. Extract the complete ZIP first.
  pause
  exit /b 2
)

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%ROOT%LIVE_TEST_RUNNER.ps1"
set "RC=%ERRORLEVEL%"
echo.
echo Runner exit code: %RC%
if exist "%ROOT%LATEST_RESULT.zip" echo Result ready: %ROOT%LATEST_RESULT.zip
echo.
pause
exit /b %RC%
