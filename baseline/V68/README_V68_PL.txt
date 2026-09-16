V68 - AUTOPP REAR-ONLY HARDLOS3D
World of Warcraft 1.12.1 build 5875 x86 - lokalne/prywatne srodowisko testowe

ZMIANA V68
- Naprawiony generator PP HARDLOS3D w MovementCore.
- V66/V67 wybieral punkty jako target XYZ + stale +/-X/+/-Y/+/-Z osi swiata.
  Nie uwzglednial orientacji moba, wiec retry mogl spoofowac rogue'a przed mobem.
- V68 czyta OFF_UNIT_O (0x09C4) celu i generuje wszystkie poziome kandydaty
  w tylnej polkuli wzgledem kierunku patrzenia celu.
- HARDLOS PP NIE ma fallbacku na exact target XYZ ani na punkt z przodu.
- Zachowany budzet 56 prob: 8 rear-only punktow poziomych x 7 wariantow Z.
- Maksymalny promien poziomy nowego sweepu: 3.05 yd.
- Mining HARDLOS nie zostal zmieniony.

AKTUALNY STACK V68
- WoWAutoLootPP v0.14 NOSKIP jest aktywny zamiast v0.13 ONESHOT.
  Dokladny runtime jest reprodukowalny 1:1 z zachowanego v0.13 przez
  artifacts/AutoLootPP/patch_v013_ONESHOT_to_v014_NOSKIP.py.
- WoWLongPickPocket v1.0 ALLRANGE_360FACING jest aktywny zamiast v0.9 FacingOnly.
  Dokladny runtime jest reprodukowalny 1:1 z zachowanego v0.9 przez
  artifacts/LongPickPocket/patch_v09_FacingOnly_to_v10_ALLRANGE_360FACING.py.
- Aktywny patched EXE jest przechowywany bezposrednio w root repo.

AKTYWNY MOVEMENTCORE
MovementCore_V68_MINING_HARDLOS_COMBAT_AUTOPP_F11_BLACKLIST_HARDLOS3D_REARONLY_RETRY.dll

POZOSTALE FUNKCJE ZACHOWANE
- F11 AutoPP ON/OFF.
- AutoPP player-target guard.
- Empty pockets blacklist GUID do zgonu celu.
- PP HARDLOS3D retry, teraz rear-only.
- Mining-first, Mining HARDLOS i Mining w combat.
- PlayerESP v1.2.
- Stealth CD hard 5 s w EXE + Guardian v2.
- PositionalSpoof / front-stab stack bez zmian.

TEST AUTOPP
1. Zamknij klienta.
2. Rozpakuj aktualny V68 do katalogu klienta.
3. Uruchom CLEAN_OLD_STACK_V68.bat, aby stare wersje DLL zostaly przeniesione do _V68_OLD.
4. Uruchom klienta przez WoW_5875_BASE_MELEE_300YD_PP_BYPASS_STEALTH5_HARD.exe.
5. F11 ma togglowac AutoPP.
6. Przy dalekich celach i LOS retry spoofowana pozycja ma pozostac za mobem.
7. W AutoGather_debug.log gotowosc MovementCore V68 ma zawierac:
   AUTOPP_V68_REARONLY_HARDLOS3D_RETRY_READY

SOURCE OF TRUTH
- CURRENT.json
- runtime/current.json
- baseline/V68/dlls.txt
- manifests/SHA256SUMS_V68.txt
- CURRENT_VERSION.md

ROLLBACK
Poprzednie runtime'y i ich odtwarzalne artefakty pozostaja w repo do porownania i rollbacku.
