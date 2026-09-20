# Parallel development channel

- Branch: `parallel`, forked from `work` at `0018be29ecaff740567b659ac1686e2bee63a249` (the original `main`/`work` remain untouched).
- Target: WoW 1.12.1 build 5875, Windows x86. This is a candidate branch, not a new stable Vxx baseline.
- Delivery: `.github/workflows/build_work_candidate.yml` builds a verified candidate on `parallel` and publishes `WoW112-WORK-CANDIDATE-<sha>`; updater lookup must always filter to the `parallel` branch and require the latest completed successful workflow run.
- Bootstrap: `.github/workflows/build_updater.yml` builds `WoW112ParallelUpdater.exe` and `WoW112UpdaterBootstrap.exe` on `parallel`, publishes `WoW112ParallelUpdater-<sha>` with `updater_build.json` channel `parallel`.
- Separation: config and DPAPI token under `%APPDATA%/WoW112ParallelUpdater`; managed state/backups under `.wow112_parallel_updater`; never install into a game folder tracked by the original `.wow112_updater`.
- This initial commit changes only the delivery/update infrastructure. Gameplay DLL/EXE bytes and the canonical V69 stable baseline are unchanged by this split.
- Before game testing, require CI `verify_current.py`, updater x86 compile/UI smoke, candidate final package verification and successful artifacts. Do not promote experimental `parallel` into `main` by default.
