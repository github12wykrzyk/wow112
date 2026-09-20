# PARALLEL Rogue / ESP test candidate

Build: World of Warcraft 1.12.1 (5875), Windows x86. Branch `parallel`, stable baseline V69 unchanged.

Runtime composition:
1. Rebuilt Player ESP: native enlarged Insert GUI, faction/hostility switches and click-to-target.
2. Rebuilt SpeedFloor: live GUI checkbox through `W112_Control_GetModuleV1`; minimum 7.1 and existing hostile-target guard.
3. Exact preserved PickPocketSelectiveRange v10: original PP/Pick Lock range and spell-specific dispatch path.
4. Exact preserved AutoLootPP v0.14: automatic Pick Pocket and loot logic from the accepted DLL, **not** the incomplete reconstructed source.
5. Exact preserved LongPickPocket v1.0: hook-based PP range/facing/loot transaction layer.

Auto PP and Auto Loot share a historical binary with no verified per-feature control ABI; the GUI only displays its load status. Do not interpret LOADED as proof that server-authorized PP/loot occurred. Do not hot-unload hooked DLLs.

In-game checks: Insert -> ESP labels and four live filters -> click a visible live label to target. Rogue section -> toggle Stealth Floor, verify it acts immediately and cannot be toggled when its control API is missing. Test PP on a valid humanoid/undead NPC and automatic loot of an eligible nearby corpse; report actual loot, any stuck loot window, range errors, crashes or interruption. Re-enter/leave BG and confirm no loss of ESP or GUI.

No test ZIP is considered ready until GitHub's `build_work_candidate.yml` on the exact commit concludes `FINAL_PACKAGE: PASS`. Leave `main` untouched.

## PvE Rear 360 V1 — isolated parallel experiment

`WoWPVERear360_5875_v1.dll` is a new companion DLL built from
`src/PVERear360/WoWPVERear360_5875_v1.c`; it does not reinstall the older
PositionalSpoof, cast/GCD hooks or MovementCore. It uses the verified build-5875
object-manager fields and native movement heartbeat wrapper, and synchronously
restores the local XYZ/O after emitting a double-heartbeat rear pose. The server
may reject the resulting synthetic movement: this feature is not guaranteed
to provide server-authoritative rear positioning.

Scope: current selected hostile NPC (type 3), actual horizontal distance <=8 yd
and vertical difference <=2.5 yd. Never active on player targets (PvP/BG).
A moving/turning NPC's live orientation is resampled at most every 100ms.
It pauses synthetic movement while the native cast/pending-cast fields are set.
V1 started a NULL-HWND timer from DllMain, which depended on the DLL-loading
thread having a Win32 message pump. A window timer cannot be installed from
another thread: Win32 requires its creating thread to own that window. The
patched candidate instead has a worker post a private message to the game's
existing ESP WndProc, which dispatches the native movement pulse on the game
window thread. No new movement hook or timer is installed. The ESP module is
a required companion for this parallel-only experiment. STATUS shows the
execution state and cumulative heartbeat pulses; pulses do not prove server
acceptance or an actual Backstab hit.
The absence of a visible native casting ID for a particular item/channel is
not yet independently verified: check mining, flag captures and poison crafts
before keeping this candidate. During LongPickPocket's active transaction,
LongPickPocket's existing movement hook may own the outgoing heartbeat; do not
interpret its presence as proof of server rear acceptance.

The module exports W112_CONTROL_API_V1 (`pve_rear360`, enable and interval
80..250ms) and status/pulse-count exports. It is default-on in this experimental
ZIP. The parallel ESP GUI does not expose enable/interval settings. Existing STATUS
shows timer state and pulse count, not confirmed server rear positioning.

Test: target one stationary hostile NPC from the front, use Backstab; then
approach from either side; repeat after the NPC turns/moves. Check the combat
log for actual Backstab/Ambush success and watch for rubber-banding, "not behind"
errors, unexpected movement and cast interruption. Verify a selected player
target on BG is unaffected, including while leaving/re-entering BG. Finally
confirm Auto PP and Auto Loot still work against an eligible humanoid/undead.
If any cast/channel/capture is interrupted, reject the candidate.
