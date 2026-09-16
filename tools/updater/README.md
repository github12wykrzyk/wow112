# WoW112Updater

Windows GUI updater/launcher for the private `github12wykrzyk/wow112` repository.

Target game runtime remains World of Warcraft 1.12.1 build 5875 x86. The updater itself is an external Windows utility and does not inject into the game.

## V1.1 QoL behavior

- `TEST (work)` reads the newest successful `Build work candidate` GitHub Actions run on branch `work`.
- Downloads the corresponding `WoW112-WORK-CANDIDATE-*` artifact through the GitHub API.
- Verifies the inner candidate ZIP against `candidate_metadata.json -> package_sha256` when metadata is present.
- Compares SHA256 of package files with the selected game directory and installs only changed files.
- Generates `dlls.txt` from DLL order in the verified candidate ZIP, including `WoWControlHub.dll` when present.
- Tracks updater-managed files in `.wow112_updater/installed.json` and safely removes stale managed files.
- Shows the locally installed channel, GitHub Actions run, short commit SHA and installation time directly in the GUI.
- `UPDATE + PLAY` performs the update flow and then launches WoW in one action.
- Rollback history is selectable in the GUI instead of being limited to the newest backup.
- The updater keeps at most the 10 newest backups under `.wow112_updater/backups/`.
- `URUCHOM WOW` starts the installed WoW executable with the game directory as working directory.
- Updates are blocked only while an actual WoW game executable (`WoW.exe` or the project `WoW_*.exe`) from the selected directory is running.
- `WoW112Updater.exe` may safely be stored and launched directly from the WoW directory; it is excluded from the running-game guard and from the launch fallback.

## Private repository authentication

The repository is private, so GitHub does not permit anonymous artifact downloads. The updater accepts a GitHub token with read-only access to this repository. Required fine-grained repository permissions are:

- Contents: Read
- Actions: Read

The token is stored only on the local PC, protected with Windows DPAPI (`CurrentUser`). It is never written to the repository or updater logs.

## Channels

- `TEST (work)` consumes the newest successful aggregate work candidate.
- `STABLE (main)` is wired to the `Build stable candidate` workflow. It becomes usable after this updater/stable-pipeline infrastructure is accepted and promoted to `main`.

`TEST (work)` intentionally follows the newest successful aggregate build. If several experiments are pushed to `work`, the updater follows the newest successful combined candidate rather than a package tied to one chat.

## Build and self-update foundation

`.github/workflows/build_updater.yml` first runs `python tools/verify_current.py`, then compiles `WoW112Updater.exe` as a Windows x86 .NET Framework 4.8 WinForms executable and performs a PE32/x86 smoke check.

`updater_build.json` records `updater_version: 1.1`, SHA256, source commit and `self_update_protocol: 1`. This metadata is the contract for the next self-update step. Automatic replacement of the running updater executable is not implemented yet; it requires a small bootstrap/helper so the old process can exit before its EXE is atomically replaced.
