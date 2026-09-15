@echo off
setlocal EnableExtensions EnableDelayedExpansion
set "LOG=V67_cleanup_repo.log"
set "OLD=_V67_OLD"

echo [%date% %time%] V67 repo cleanup start>"%LOG%"
if not exist "%OLD%" mkdir "%OLD%" >>"%LOG%" 2>&1
if errorlevel 1 goto :err

rem Move only known project DLL families. Do not touch unrelated DLLs.
call :family "MovementCore_*.dll" "MovementCore_V66_MINING_HARDLOS_COMBAT_AUTOPP_F11_BLACKLIST_HARDLOS3D_RETRY.dll"
call :family "WoWMovementCore_*.dll" "__NONE__"
call :family "WoWLongPickPocket_*.dll" "WoWLongPickPocket_v0_9_HARDLOS025_FacingOnly.dll"
call :family "WoWAutoLootPP_*.dll" "WoWAutoLootPP_v0_13_PP300YD_HU_ATTACKABLE_LEVELGATE3_ONESHOT_SELECTORCHECK.dll"
call :family "WoWStealthCDGuardian_*.dll" "WoWStealthCDGuardian_5875_v2_HARD5S_WATCHDOG.dll"
call :family "WoWPositionalSpoof_*.dll" "WoWPositionalSpoof_v0_36_WotFRetry5_NoPP_SmartEnergy700_StealthCDSafe_NoFailHook_GateGCDFix.dll"
call :family "WoWPlayerESP_*.dll" "WoWPlayerESP_v1_2_range_sweep.dll"
call :family "PickPocketSelectiveRange_*.dll" "PickPocketSelectiveRange_5875_v10_PP300_PICKLOCK300_9YD.dll"
call :family "WoWNonPvPSpeedFloor_*.dll" "WoWNonPvPSpeedFloor_v0_4_ALWAYS_FLOOR7_1_DIAG.dll"

rem Legacy families known from V39/V43. None is active in V67.
call :family "WoWAutoStealth_*.dll" "__NONE__"
call :family "BackstabAutoRecast_*.dll" "__NONE__"
call :family "WoWCombatBreak_*.dll" "__NONE__"
call :family "WoWManualExtremeBreak_*.dll" "__NONE__"
call :family "WoWManualSafeBreak_*.dll" "__NONE__"
call :family "WoWNoFall_*.dll" "__NONE__"
call :family "WoWPPLevelGate_*.dll" "__NONE__"
call :family "WoWPPResistAuto_*.dll" "__NONE__"
call :family "WoWPPResistCombatBreak_*.dll" "__NONE__"
call :family "WoWPPResistUnreachable_*.dll" "__NONE__"
call :family "WoWPPResistZBreak_*.dll" "__NONE__"
call :family "WoWAutoKick_*.dll" "__NONE__"

if errorlevel 1 goto :err

echo [%date% %time%] OK>>"%LOG%"
echo Cleanup OK. Log: %LOG%
pause
exit /b 0

:family
for %%F in (%~1) do if exist "%%F" (
  if /I not "%%~nxF"=="%~2" call :moveone "%%F"
)
exit /b 0

:moveone
echo Moving %~nx1>>"%LOG%"
move /Y "%~1" "%OLD%\%~nx1" >>"%LOG%" 2>&1
if errorlevel 1 exit /b 1
exit /b 0

:err
echo [%date% %time%] ERROR>>"%LOG%"
echo ERROR - sprawdz %LOG%
pause
exit /b 1
