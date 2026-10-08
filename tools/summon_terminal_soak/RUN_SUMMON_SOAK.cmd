@echo off
setlocal
if "%~1"=="" (
  python "%~dp0harness.py" --quality-only
  exit /b %ERRORLEVEL%
)
if /I "%~1"=="--quality-only" (
  python "%~dp0harness.py" %*
  exit /b %ERRORLEVEL%
)
python "%~dp0harness.py" --live %*
exit /b %ERRORLEVEL%
