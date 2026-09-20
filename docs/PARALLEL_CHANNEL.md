# Parallel development channel

- Branch: `parallel`, forked from `work` at `0018be29ecaff740567b659ac1686e2bee63a249` (the original `main`/`work` remain untouched).
- Target: WoW 1.12.1 build 5875, Windows x86. This is a candidate branch, not a new stable Vxx baseline.
- Delivery: `.github/workflows/build_work_candidate.yml` builds a verified candidate on `parallel` and publishes `WoW112-WORK-CANDIDATE-<sha>`; updater lookup must always filter to the `parallel` branch and require the latest completed successful workflow run.
- Bootstrap: `.github/workflows/build_updater.yml` builds `WoW112ParallelUpdater.exe` and `WoW112UpdaterBootstrap.exe` on `parallel`, publishes `WoW112ParallelUpdater-<sha>` with `updater_build.json` channel `parallel`.
- Separation: config and DPAPI token under `%APPDATA%/WoW112ParallelUpdater`; managed state/backups under `.wow112_parallel_updater`; never install into a game folder tracked by the original `.wow112_updater`.
- This initial commit changes only the delivery/update infrastructure. Gameplay DLL/EXE bytes and the canonical V69 stable baseline are unchanged by this split.
- Before game testing, require CI `verify_current.py`, updater x86 compile/UI smoke, candidate final package verification and successful artifacts. Do not promote experimental `parallel` into `main` by default.

## ESP-only runtime and independent GUI

- The `parallel` test candidate contains only the exact 5875 EXE and one rebuilt ESP DLL. Existing gameplay modules, ControlHub and optional companion modules are excluded on `parallel` only; `work` and `main` remain untouched.
- Press `Insert` while in-game to open the 750x475 native ESP panel (Segoe UI 22/29 px). Four independent live checkboxes: ESP display, Horde, Alliance, Hostile to me. Defaults: ESP ON, faction filters OFF, hostile filter ON. Faction/hostility filters combine by OR; toggling is immediate, without restarting or reloading the DLL.
- Horde and Alliance refer to the *character faction* by Vanilla race, never BG-assigned side. Hostile mode on mixed-faction BG uses current scoreboard team assignment and fails closed when the roster is unavailable. Outside BG a live target PvP flag is also required; some attackable unflagged players on PvP realms may be omitted.
- No settings for other DLLs are included; those can be integrated when rewritten for the parallel channel. This is a candidate, not a new stable Vxx release.

## Directory validation (updater 2.2-parallel.2)

- PARALLEL does not reject a directory solely because `.wow112_updater/installed.json` exists. This is compatible with selecting an existing/copy of an original-updater game directory.
- The original updater's state files stay untouched; PARALLEL uses its own `.wow112_parallel_updater/` state and backup namespace. When both channels install into the *same* folder, game EXE/DLL files with matching names can replace each other, so separate game folders remain useful for two simultaneous installations.
- Check directory existence, GitHub credentials, verified artifact SHA256, path normalization, running-game guard and backup/rollback mechanisms remain in force.

## ESP-only symbol provenance

The branch-specific `runtime/verified_symbols_5875.json` indexes only symbols with active PlayerESP translation-unit evidence. Symbols that were supported solely by removed SpeedFloor/AutoLootPP source were removed from this *derived parallel index*, not from the original work/main registry. The verifier remains unchanged and requires real current source evidence for every retained symbol.

## ESP filter rescans and target-by-click test

- Each of the four large ESP GUI checkboxes increments a revision counter and schedules a guarded live player-cache refresh on the next eligible render frame (~33 ms). A BG scoreboard refresh is requested separately on the game WndProc (next worker poll, ~100 ms); switching filters never executes native queries from the GUI callback and never skips the transition quarantine.
- Live, currently rendered ESP labels are clickable to target using two paths: direct opaque-pixel layered-label click sends a GUID message to the game window, while transparent pixels go through the original game-window hit-test path. Both resolve a live GUID again and require a current visible hit entry before invoking the build-5875 native target function. Stale/history labels are display-only, not clickable. Only a user click changes target.
- Test filters toggled quickly on mixed-faction BG, inspect that players reappear without waiting for the periodic cache and teammates remain excluded in Hostile-only mode. Click the rendered *opaque text/HP bar* for a nearby live player, verify the in-game target frame matches; clicking an obsolete/stale label must not switch target. Repeat after entering/leaving BG. Unknown or unloaded player objects cannot be materialized by refresh.

## Rogue PP/loot candidate (2026-09-20)

- Only on `parallel`: add the exact V69 PickPocketSelectiveRange, AutoLootPP and LongPickPocket runtime DLLs, in that order, after the rebuilt SpeedFloor and ESP. No original `work`/stable `main` runtime is modified.
- PickPocketSelectiveRange, AutoLootPP and LongPickPocket use their exact content-addressed runtime caches. Their source files under `src/` are maintained as *reconstructions*, not asserted byte-for-byte equivalent. In particular the AutoLootPP reconstruction omits the original corpse scanner/request path; it MUST NOT replace the exact binary in a runtime test.
- SpeedFloor uses its buildable reconstructed source and exports `W112_Control_GetModuleV1`. In the enlarged Insert ESP panel, its checkbox reads/sets setting 1 through the live ABI. Original default floor remains 7.1; the existing hostile-target guard remains active.
- The GUI reports whether AutoLootPP/LongPickPocket are loaded; the exact legacy binaries do not expose supported independent PP/loot toggle controls. No pretend toggle, hot-unload of hooked DLLs, second WndProc subclass, or additional legacy gameplay modules.
- Functional test: confirm ESP labels/target-by-click and BG filtering; toggle Stealth Floor live and verify speed change in stealth; in a suitable safe PvE test confirm automatic PP and corpse loot work while LongPP is loaded. Distinguish LOAD from successful server-side PP/loot. On a crash or missed corpse, report reproducible in-game outcome; do not promote to `main` without an accepted test.

## Parallel Rogue candidate CI repair

- `runtime/work_candidate.json` now explicitly permits the pre-existing candidate source-fingerprint drift for PickPocketSelectiveRange (current source size 27491 vs stable metadata size 9319) and AutoLootPP (24575 vs 24519). These are *not* source overrides and are not presented as stable source promotions.
- The candidate builder now treats PickPocketSelectiveRange, AutoLootPP and LongPickPocket as explicit exact-byte-only inputs: rejects edits to their source without an explicit migration, rejects invalid exact-only names and conflicts with source overrides, and never uses their reconstructed binaries as candidate DLLs.
- Existing fast/current, exact-runtime-artifact, symbol and final ZIP verifiers remain intact; exact-byte-only DLL artifacts must still match runtime SHA256/size and all final package invariants. Normal work candidates are unaffected because their `exact_byte_modules` list is absent.
- Only ESP and SpeedFloor are compiled for the parallel candidate. Do not consider the candidate runnable until the latest branch-specific GitHub Actions run reports final package PASS.
