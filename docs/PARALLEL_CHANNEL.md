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

## Three-tab ESP / Rogue / Status GUI (parallel candidate)

- The Insert GUI is a 750x555 Win32 native window with **ESP**, **ROGUE**, and **STATUS** tabs. Each tab retains large 22 px readable controls while showing only its own page; switching tabs does not trigger a player rescan, reload or new WndProc subclass.
- ESP: four existing independent live filters and click-to-target continue unchanged. Actual checkbox changes alone increment the cache-refresh revision.
- Rogue: SpeedFloor live enabled (control ID 1), disable-on-hostile-target guard (ID 3), and minimum speed stepper (-/+ 0.1, 1.0..14.0, control ID 2); displayed speed and checkbox state are queried from the active DLL, not hardcoded.
- Status: ESP state and loaded/not-loaded indicators for PickPocketSelectiveRange, AutoLootPP and LongPickPocket; legacy PP/loot remain always-on with exact runtime DLLs and are *not* falsely represented as independently controllable.
- Close and reopen with Insert; return to game focus as before. Existing ESP render worker and its hook ownership, current world/BG quarantine, and target-by-click behavior remain unchanged.
- In-game checks: switch tabs repeatedly, toggle the four ESP filters and confirm immediate refresh and target clicks; change all three SpeedFloor settings and confirm live effect; reopen GUI and verify current runtime state; enter/leave BG, confirm ESP and GUI stability. Confirm Status 'LOADED' is not interpreted as proof of server-side PP/loot.

## Native GUI compilation regression guard

- CI preflights the documented Win32 `CreateFontA` 14-argument x86 `WINAPI` import and every GUI font allocation before candidate build. The prototype has five `int`, eight `DWORD`, and one `LPCSTR` parameters. The Windows x86 compiler remains authoritative.
- Do not announce a build as ready based on source/static tests alone: inspect the newest `parallel` workflow run on the exact SHA and require success and `FINAL_PACKAGE: PASS` before asking the user to update.

## LazyScript and LazyRogue updater integration (Parallel only)

Parallel updater 2.3-parallel.3 publishes a separately SHA256-attested addon-only ZIP in the existing candidate workflow artifact and auto-installs only `Interface/AddOns/LazyScript` and `Interface/AddOns/LazyRogue`. It backs up/reverts/repairs managed addon files without touching other installed addons or inserting them into `dlls.txt`. Parallel's existing ESP, GUI, PP, loot and PvE Rear360 DLL runtime is unchanged. AutoKick V3's native cast bridge was **not** copied from work; interrupt decisions use the short Lua chat fallback until a parallel native integration is separately built and verified.

## CURRENT work Rogue PP port (2026-09-20; supersedes earlier exact-only PickPocketSelectiveRange / no-MovementCore notes)

The parallel candidate now mirrors the *active work candidate*, not its historical V69 PP-only fallback. Source overrides compile the canonical current `work` sources `src/PickPocketSelectiveRange/PickPocketSelectiveRange_5875_v10_PP300_PICKLOCK300_9YD.c` (ordinary 8 yd, PP/Pick Lock 300 yd, stationary stealth-safe AutoJunkbox) and `src/MovementCore/WoWMovementCore_5875_v21_ALT_PRIORITY.c` (includes V20 AutoPP, per-life PP blacklist, rear-only HARDLOS3D retry, F11 and movement coordination). The corresponding stable identities in `runtime/current.json` remain exact V69 metadata; the candidate uses compiled overrides and does not claim source rebuilds are bitwise identical to those V69 DLLs.

AutoLootPP v0.14 and LongPickPocket v1.0 are the same SHA256-checked exact binary artifacts used by `work`, because the available AutoLootPP reconstruction does not contain the accepted corpse-loot scanner. The root loader order is ESP, SpeedFloor, PickPocketSelectiveRange, AutoLootPP, LongPickPocket, **MovementCore**, plus the separately appended parallel PvE Rear companion. MovementCore must come after LongPP to obtain the expected preexisting hook chain. Existing ESP/SpeedFloor code remains parallel-specific.

Insert -> ROGUE now reads and sets current work modules via their verified `W112_Control_GetModuleV1` ABIs: AutoPP (MovementCore setting 2; also F11) and AutoJunkbox (PickPocketSelectiveRange setting 1). There is intentionally no fictitious independent AutoLootPP toggle or hot-unload. STATUS distinguishes those modules and reflects work AutoPP state. The separate parallel PvE Rear companion yields its synthetic movement while MovementCore reports cast/PP/gather/SafeBreak ownership and fails closed if MovementCore/control export is unavailable. A loaded DLL and synthetic pulse count do not prove server-side PP, loot, or rear acceptance.

This is a parallel TEST candidate only, not an accepted stable Vxx. Require the exact parallel commit's GitHub Actions x86 build and FINAL_PACKAGE: PASS before installation; in-game verify actual PP and corpse loot, AutoJunkbox out of combat/stealth, F11 and GUI controls, 360 rear without PP interruption, and ESP/BG stability. Leave `work` and `main` untouched.

## Auto WotF standalone companion (parallel only, TEST)

- New source: `src/AutoWotF/WoWAutoWotF_5875_v1.c`; separate `WoWAutoWotF_5875_v1.dll` is appended by the parallel candidate workflow and included in the root `dlls.txt` after PvE Rear360; updater consumes only a verified complete candidate artifact.
- Ported from **work** PositionalSpoof's reconstructed WotFRetry5 detection/send path, not from the historical attached ZIP and not from its positional/movement hooks. Matches local Fear, Charm or Sleep aura mechanics, sends WotF (7744) on first detection and retries at 180 ms up to five times while CC persists; clears its transaction after CC disappears or player context changes.
- Always on; no fake independent GUI checkbox, no writes to movement, facing, target, client cast state or GCD. Uses a Win32 timer callback on the game's UI thread, no new WndProc subclass or spell/movement callsite hook.
- TEST: with an Undead character, verify WotF triggers during Fear, Charm and Sleep when off cooldown; check that nonmatching debuffs do not trigger and it does not spam indefinitely on cooldown. Repeat after BG transitions, relog and alongside AutoPP/PvE rear. Do not treat loader presence or local attempt counters as server-side acceptance.
