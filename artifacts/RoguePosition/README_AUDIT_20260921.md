# Rogue positional-gate audit — 5875 x86 — NO EXE PATCH
Branch: parallel; inspected HEAD: d00cda982825f147903de4367b2b762ad2c49387
Exact input: WoW_5875_BASE_MELEE_300YD_PP_BYPASS_STEALTH5_HARD.exe
Size: 4907008 bytes; SHA256: 9a735271283a49d16ca670d6a6fc8bb12937deca07221087c608b27c2ffd42a2.
The uploaded EXE matched CURRENT.json, runtime/current.json, and the GitHub Actions candidate's EXE entry for the inspected HEAD.

## Verified reference sites (PE32 .text file offset = VA - 0x400000)
- File 0x2E2528, VA 0x006E2528: B8 6C 05 87 00 C3 = mov eax,0x0087056C; ret. The target is the SPELL_FAILED_NOT_BEHIND string, NOT a position-check predicate.
- File 0x2E253A, VA 0x006E253A: B8 1C 05 87 00 C3 = mov eax,0x0087051C; ret. The target is the SPELL_FAILED_NOT_INFRONT string, NOT a position-check predicate.
- File 0x183720, VA 0x00583720: B8 30 9E 85 00 C3 = mov eax,0x00859E30; ret. The target is the DBFilesClient\Spell.dbc path, NOT a field check.
The exact-byte read-only verifier in this directory confirms these facts and the one direct .text pointer reference per listed string/path; indirect references and unrelated check sites are not excluded.

## What is NOT established
No confirmed exact-build client cast initiation -> positional predicate -> outgoing CMSG_CAST_SPELL call chain. The actual build-5875 Spell.dbc contents were not recovered; its exact per-rank flags cannot be asserted. A displayed SPELL_FAILED_NOT_BEHIND/NOT_INFRONT does not distinguish server response from local rejection. No evidence that the real game server enforces only, or that disabling a client check would override independent server checks. Gouge target-facing is semantically distinct from Backstab/Ambush caster-behind; do not conflate them.

External context, NOT proof of client offsets or of the actual user's server implementation:
- https://github.com/cmangos/mangos-classic/blob/master/src/game/Spells/Spell.cpp
- https://github.com/cmangos/mangos-classic/blob/master/src/game/Spells/SpellDefines.h
- https://trinitycore.info/files/DBC/335/spell (later build; do not transplant structure)

## Safe next discriminating evidence
For a spell attempt, correlate the exact spell ID and caster/target orientation with outgoing CMSG_CAST_SPELL and matching incoming SMSG_CAST_FAILED (or absence of outgoing packet); follow the exact binary call chain of any pre-send rejection. Verify every byte and affected class/rank before any minimal reversible patch. Do not NOP these three string/path getter functions or remove only visible error messages.

Disposition: this is a diagnostic documentation commit. No EXE, DLL, CURRENT.json, runtime/current.json or manifest bytes were modified; no Rogue positional patch or verified patched package was produced. Existing candidate build is unchanged gameplay behavior. No new Vxx or stable promotion.
