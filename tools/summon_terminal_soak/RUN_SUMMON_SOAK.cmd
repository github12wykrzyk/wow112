@echo off
setlocal
python "%~dp0harness.py" %*
exit /b %ERRORLEVEL%
