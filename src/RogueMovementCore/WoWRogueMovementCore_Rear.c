/* Parallel Rogue movement: compile the canonical PvE/PvP rear source into the
   MovementCore DLL. Export its diagnostics, but not a second control API. */
#define PVE_REAR_EMBEDDED 1
#define DllMain RogueMovementCore_RearInit
#define _fltused rogue_rear_fltused
#define W112_Control_GetModuleV1 PVERear360_Control_GetModuleV1
#include "../PVERear360/WoWPVERear360_5875_v1.c"
