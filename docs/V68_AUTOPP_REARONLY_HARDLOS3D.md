# V68 AutoPP rear-only HARDLOS3D

Problem: `PPHardSelect()` w v19/V66 tworzyl 56 punktow przez dodawanie stalych przesuniec osi swiata do target XYZ. Orientacja celu nie byla uzywana, wiec czesc HARDLOS retry mogla umiescic spoofowana pozycje przed mobem.

Fix V68:
- source: `WoWMovementCore_5875_v20_AUTOPP_REARONLY_HARDLOS3D_RETRY.c`
- target orientation: `OFF_UNIT_O = 0x09C4`
- `forward = (cos(o), sin(o))`
- `right = (-sin(o), cos(o))`
- `candidate = target - forward*back + right*side`
- wszystkie poziome kandydaty maja `back > 0`, wiec sa w tylnej polkuli
- 7 grup Z zachowuje 56 wariantow retry
- max horizontal radius = 3.05 yd
- brak exact-target/front fallback
- Mining HARDLOS bez zmian

Build validation:
- PE32 / i386
- no import directory
- 80 export names zgodnych z poprzednim MovementCore
- DYNAMIC_BASE + NX_COMPAT + NO_SEH
