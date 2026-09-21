/* Parallel Rogue movement: keep V21 as the canonical editable movement source.
   Compile it once into the consolidated DLL, with one shared DLL entry owner. */
#define W112_V21_ENTRY RogueMovementCore_MovementInit
#include "../MovementCore/WoWMovementCore_5875_v21_ALT_PRIORITY.c"
