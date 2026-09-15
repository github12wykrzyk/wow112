@echo off
setlocal EnableExtensions EnableDelayedExpansion
set "LOG=V68_cleanup.log"
set "OLD=_V68_OLD"
echo [%date% %time%] V68 cleanup start>"%LOG%"
if not exist "%OLD%" mkdir "%OLD%" >>"%LOG%" 2>&1
if errorlevel 1 goto :err

for %%F in (MovementCore_*.dll) do if exist "%%F" (
  if /I not "%%~nxF"=="MovementCore_V68_MINING_HARDLOS_COMBAT_AUTOPP_F11_BLACKLIST_HARDLOS3D_REARONLY_RETRY.dll" call :moveone "%%F"
)
for %%F in (WoWLongPickPocket_*.dll) do if exist "%%F" (
  if /I not "%%~nxF"=="WoWLongPickPocket_v0_9_HARDLOS025_FacingOnly.dll" call :moveone "%%F"
)
for %%F in (WoWAutoLootPP_*.dll) do if exist "%%F" (
  if /I not "%%~nxF"=="WoWAutoLootPP_v0_13_PP300YD_HU_ATTACKABLE_LEVELGATE3_ONESHOT_SELECTORCHECK.dll" call :moveone "%%F"
)
for %%F in (WoWStealthCDGuardian_*.dll) do if exist "%%F" (
  if /I not "%%~nxF"=="WoWStealthCDGuardian_5875_v2_HARD5S_WATCHDOG.dll" call :moveone "%%F"
)
for %%F in (WoWPositionalSpoof_*.dll) do if exist "%%F" (
  if /I not "%%~nxF"=="WoWPositionalSpoof_v0_36_WotFRetry5_NoPP_SmartEnergy700_StealthCDSafe_NoFailHook_GateGCDFix.dll" call :moveone "%%F"
)
for %%F in (WoWPlayerESP_*.dll) do if exist "%%F" (
  if /I not "%%~nxF"=="WoWPlayerESP_v1_2_range_sweep.dll" call :moveone "%%F"
)
for %%F in (WoWNonPvPSpeedFloor_*.dll) do if exist "%%F" (
  if /I not "%%~nxF"=="WoWNonPvPSpeedFloor_v0_4_ALWAYS_FLOOR7_1_DIAG.dll" call :moveone "%%F"
)

echo [%date% %time%] OK>>"%LOG%"
echo Cleanup OK. Log: %LOG%
pause
exit /b 0

:moveone
echo Moving %~nx1>>"%LOG%"
move /Y "%~1" "%OLD%\%~nx1" >>"%LOG%" 2>&1
if errorlevel 1 goto :err
exit /b 0

:err
echo [%date% %time%] ERROR>>"%LOG%"
echo ERROR - sprawdz %LOG%
pause
exit /b 1
