# WoW112Updater

Windows GUI updater/launcher for the private `github12wykrzyk/wow112` repository.

Target game runtime remains World of Warcraft 1.12.1 build 5875 x86. The updater itself is an external Windows utility and does not inject into the game.

## Current V1.2 maintenance behavior

- `TEST (work)` reads the newest successful `Build work candidate` GitHub Actions run on branch `work`.
- Downloads the corresponding `WoW112-WORK-CANDIDATE-*` artifact through the GitHub API.
- Verifies the inner candidate ZIP against `candidate_metadata.json -> package_sha256` when metadata is present.
- Compares SHA256 of package files with the selected game directory and installs only changed files.
- Generates `dlls.txt` from DLL order in the verified candidate ZIP, including `WoWControlHub.dll` when present.
- Tracks updater-managed files in `.wow112_updater/installed.json` and safely removes stale managed files.
- Shows the locally installed channel, GitHub Actions run, short commit SHA and installation time directly in the GUI.
- `UPDATE + PLAY` performs the update flow and then launches WoW in one action.
- Rollback history is selectable in the GUI; at most 10 newest backups are retained.
- `URUCHOM WOW` starts only a real WoW executable (`WoW.exe` or project `WoW_*.exe`) from the selected directory.
- `WoW112Updater.exe` may safely live directly in the WoW directory; it is excluded from the running-game guard.
- Realmlist selector reads and writes `<game>/realmlist.wtf` without touching unrelated lines. Presets: OctoWoW (`play.octowow.st`) and RavenCraft (`logon.ravencraft.io`).

## Maintenance tools

### VERIFY / REPAIR

The updater retrieves the exact GitHub Actions artifact recorded in `.wow112_updater/installed.json`, verifies the candidate ZIP SHA256, reconstructs the expected EXE/DLL/dlls.txt set and compares local SHA256 values.

If files are missing, modified or stale, the updater offers to repair them from the exact same installed build. Repair is blocked while WoW is running, creates a rollback-compatible backup first and verifies the files again after writing.

### DIAGNOSTYKA ZIP

Creates `.wow112_updater/diagnostics/WoW112_diagnostics_*.zip` containing sanitized installed-state metadata, `dlls.txt`, `realmlist.wtf` when present, updater/runtime information, SHA256/size status for managed files, backup index and the current updater session log.

The diagnostics ZIP intentionally never includes the GitHub token, updater `config.json` or the DPAPI-protected token blob.

### AKTUALIZUJ UPDATER

The updater can now update itself. It reads the newest successful `Build WoW112 updater` artifact for the selected channel branch, validates `updater_build.json`, SHA256-verifies both `WoW112Updater.exe` and the x86 bootstrap, stages the new executable and starts `WoW112UpdaterBootstrap.exe`.

The bootstrap waits for the current updater process to exit, verifies the staged SHA256 again, replaces the updater executable, keeps `previous_updater.exe` under `.wow112_updater/selfupdate/` as recovery evidence and restarts the updater. No token is passed to the bootstrap.

`self_update_protocol: 1` is the compatibility contract for this replacement flow.

## Private repository authentication

The repository is private, so GitHub does not permit anonymous artifact downloads. The updater accepts a GitHub token with read-only access to this repository. Required fine-grained repository permissions are:

- Contents: Read
- Actions: Read

The token is stored only on the local PC, protected with Windows DPAPI (`CurrentUser`). It is never written to the repository, diagnostics ZIP or updater logs.

## Channels

- `TEST (work)` consumes the newest successful aggregate work candidate and the updater build from `work`.
- `STABLE (main)` consumes the stable candidate/updater build from `main` after this infrastructure is accepted and promoted.

`TEST (work)` intentionally follows the newest successful aggregate build. If several experiments are pushed to `work`, the updater follows the newest successful combined candidate rather than a package tied to one chat.

## Build

`.github/workflows/build_updater.yml` runs `python tools/verify_current.py`, compiles `WoW112Updater.exe` and `WoW112UpdaterBootstrap.exe` as Windows x86 .NET Framework 4.8 executables, verifies PE32/x86 for both and emits SHA256 metadata in `updater_build.json`.
