# LazyScript/LazyRogue on isolated PARALLEL channel
These 38 addon files derive from the user-supplied LazyScript-for-twow-eh-main.zip, with original upstream project https://github.com/pfmiles/LazyScript-for-twow-eh commit e417ba44bbe4e8db5f9927eb2fb369b6ddd4c097. The work-branch Rogue hybrid and Lua-syntax fixes are copied as exact Git blobs; these files are not represented as pristine original upstream sources.
PARALLEL intentionally retains its independent ESP/SpeedFloor/PP/loot/PvERear360 runtime. This addon install introduces NO DLL and does not import work-branch AutoKick V3 or its native hooks. Without a native AutoKick bridge, the Rogue addon has a conservative 350 ms chat-based cast-detection fallback; in-game spell detection and SuperWoW compatibility remain unconfirmed. The upstream project explicitly noted SuperWoW incompatibility as of 2025-04-30.
The independent addons-only ZIP is published in the parallel candidate artifact with a matching-SHA256 addon_metadata.json and automatically installed by Parallel Updater >=2.3-parallel.3 into Interface/AddOns. Other addons, the EXE, active DLL list, dlls.txt and main/work branches are not changed by this source import.

## Parallel Rogue energy-tick criterion (experimental)

LazyRogue accepts `bs-ifEnergyTick<200ms` and custom integer values 0..2000 ms, with `<`, `>` and `=` comparisons. Clock sync is **automatic**: the load-on-demand addon registers for `UNIT_ENERGY` during OnLoad even if `PLAYER_LOGIN` has already passed; a natural +20 energy gain, or a partial gain that reaches full energy, establishes a 2-second tick-phase estimate from `GetTime()`. A nonstandard gain above 20 (e.g. Thistle Tea) invalidates synchronization. The phase remains usable for up to 8s, including at full energy, to avoid permanently false conditions when capped or when an event is missed; beyond 8s without another recognized tick it returns false until a fresh observation. This is **not** a direct server/DLL timer and may be inaccurate when energy procs overlap regeneration. `/lrtick` prints the observed synchronization state and remaining estimated milliseconds, with no manual synchronization action. Existing LastChance and interrupt behavior is preserved. The action still needs enough energy and to pass its other eligibility checks when the condition becomes true. No new DLL/EXE/GUI control or `dlls.txt` entry is required. In-game timing remains to be verified.

## Parallel Rogue first-pass rotation fixes (experimental)

- `ifLastChance` checks >=75 energy before >=55, uses the estimated upcoming tick if available, and falls back to a relative estimate if it is not synchronized.
- A timely, same-target `SPELL_FAILED_NOT_BEHIND` after BS/Ambush restores its previous `everyXs` timers and removes the newest failed history entry. Other attempts remain unconfirmed until tested in-game.
- LazyScript does not automatically invoke `TargetNearestEnemy()` for a Rogue in Stealth. Explicit targeting and existing targets remain unaffected; regular auto-target outside Stealth remains unchanged. The PP DLL remains responsible for scan targeting.
- This iteration does not modify DLLs, EXE, accepted baseline, or main/work branches.

## Parallel rear-action queue recovery candidate (experimental)

- `Actions.lua` temporarily suppresses repeated identical BS/Ambush attempts for 300 ms; other usable actions remain eligible.
- A matching Behind/Range rejection rolls back the pending rear action as before. If that action-bar slot is still current, no other cast/channel is active, and the rejection is timely, LazyScript invokes `SpellStopCasting()` and delays a retry for 120 ms. Unrelated spells are protected.
- `WoWOpenerUIRecovery_5875_v1.dll` is included in the Parallel candidate ZIP with conservative idle-only auto-clear enabled by default (250 ms unchanged state, stable world, no pending/active/queued cast). It does not automatically cancel an active or queued spell. Its manual control API remains optional.
- This does not guarantee recovery for every active queue lock: unconfirmed cases need diagnostics. V69/main/work are unchanged.
- In-game test: rejected BS/Ambush should not permanently block subsequent rotation; verify energy waits, casts/channels, poisons and BG transitions are not interrupted.

## Native cast/channel observer (parallel test candidate)
Only parallel adds src/CastObserver/WoWCastObserver_5875_v1.c compiled to
WoWCastObserver_5875_v1.dll as a root loader companion. The DLL observes the
selected target GUID plus current 5875 CGUnit native casting spell slot
(0xC8C) and UNIT_CHANNEL_SPELL descriptor index 0x90. It publishes a fresh
native snapshot every ~25ms via FrameScript_Execute to
lazyScript.interrupt.OnNativeCast(guid, spellID, remaining, kind, owned=0).
Here remaining=65535 means UNKNOWN; it is not a real remaining-cast clock.
A 0-kind snapshot invalidates a finished cast/channel. No native Kick,
CastSpellByName, movement, player cast, or game-state hooks are introduced.
The normal cast/channel spell slots and signature-guarded native read are
build-5875 lineage taken from the separate AutoKick V3 source. The observer
checks the exact signatures and becomes inert if they do not match.
LazyScript alone decides and dispatches Kick: chat messages may label
spells but never authorize a Kick without a fresh positive native snapshot.
If the DLL is absent/inert the automatic LS Kick intentionally does not fire.
AutoKick V3 is excluded from parallel; main/work remain untouched.
The addon-only ZIP and DLL candidate are separately SHA256 attested within
one successful branch-specific workflow artifact. Native slot liveness is
not proof of server-side interrupt acceptance: test normal casts, channels,
completed casts, target switching, relog, and BG transitions in game.

## Native local-player movement criteria (parallel test candidate)

LazyScript's player criteria now include `ifMoving` and `ifNotMoving` (examples:
`ss-ifMoving` and `bs-ifNotMoving`). The existing read-only parallel
CastObserver DLL also publishes fresh player-world-position movement snapshots
through `lazyScript.OnNativePlayerMovement(0/1)`; LazyScript alone evaluates
criteria and dispatches actions. It samples native verified 5875 world X/Y every
~25ms, requires about 50ms stable movement or 100ms stability before changing
state, and checks snapshot freshness (350ms). Rotation-only movement does not
count. Missing/inert DLL, login/map transitions or stale samples fail closed for
BOTH criteria: an unknown movement state must never be interpreted as standing.
The DLL never starts/stops movement; existing cast/channel observer and Kick
semantics are unchanged. Criteria are listed in LS help. Native coordinate
behavior in combat, BG transitions and synthetic-position scenarios requires
in-game validation before promotion to main.

## Parallel LazyScript / MovementCore trace bridge (experimental)

The existing embedded Rear360 game-window tick publishes read-only status and cumulative counters through the verified 5875 FrameScript_Execute ABI. LazyScript logs its BS/Ambush action dispatch, wait and bar checks, UI behind/range rejection, and native status/counter changes in a bounded in-memory buffer. Use `/ls reartrace`, `/ls reartrace 25`, `/ls reartrace clear`, `/ls reartrace on`, `/ls reartrace off`. LIVE means the native bridge is emitting; ABSENT/STALE is not proof of a server cast rejection. Native SPELL_GO is an observed game callback, not a separately confirmed server-side outcome. Counter deltas are asynchronous and cannot be attributed one-to-one to one LazyScript action. This diagnostic change adds no separate DLL, hooks, movement mutations, cast cancellation or retries; capture the last 25 events immediately after a failure in PvE or PvP.
