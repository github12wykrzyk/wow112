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
