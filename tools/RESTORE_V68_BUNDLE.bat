@echo off
setlocal EnableExtensions
cd /d "%~dp0"
set "LOG=%~dp0RESTORE_V68_BUNDLE.log"
(
  echo [%date% %time%] RESTORE_V68_BUNDLE is deprecated.
  echo Canonical V68 is stored as a delta against V67.
  echo Runtime: artifacts\V68\runtime\
  echo Source : artifacts\V68\source\
  echo See README_RESTORE.md in both directories.
  echo Do NOT use archives\V68_FULL_NO_EXE_BUNDLE_B64 as source of truth.
)>"%LOG%"
type "%LOG%"
echo.
echo [STOP] Deprecated restore path intentionally disabled.
pause
exit /b 2
