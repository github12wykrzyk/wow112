@echo off
setlocal EnableExtensions EnableDelayedExpansion
set "LOG=VERIFY_V68.log"
echo [%date% %time%] VERIFY V68>"%LOG%"
set FAIL=0
if not exist "SHA256SUMS_V68.txt" (
  echo MISSING SHA256SUMS_V68.txt>>"%LOG%"
  goto :err
)
where certutil >nul 2>&1
if errorlevel 1 (
  echo ERROR certutil not found>>"%LOG%"
  goto :err
)
for /f "tokens=1,*" %%A in (SHA256SUMS_V68.txt) do (
  set "EXPECTED=%%A"
  set "FILE=%%B"
  set "GOT="
  if not exist "!FILE!" (
    echo MISSING !FILE!>>"%LOG%"
    set FAIL=1
  ) else (
    for /f "skip=1 tokens=*" %%H in ('certutil -hashfile "!FILE!" SHA256 2^>nul') do if not defined GOT set "GOT=%%H"
    set "GOT=!GOT: =!"
    if /I not "!GOT!"=="!EXPECTED!" (
      echo FAIL !FILE! expected=!EXPECTED! got=!GOT!>>"%LOG%"
      set FAIL=1
    ) else echo OK !FILE!>>"%LOG%"
  )
)
if "!FAIL!"=="1" goto :err
echo ALL OK>>"%LOG%"
echo V68 verify OK
pause
exit /b 0
:err
echo VERIFY FAILED - sprawdz %LOG%
pause
exit /b 1
