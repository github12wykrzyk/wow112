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
