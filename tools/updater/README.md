# WoW112Updater

Windows GUI updater/launcher for the private `github12wykrzyk/wow112` repository.

Target game runtime remains World of Warcraft 1.12.1 build 5875 x86. The updater itself is an external Windows utility and does not inject into the game.

## V1 behavior

- TEST channel reads the newest successful `Build work candidate` GitHub Actions run on branch `work`.
- Downloads the corresponding `WoW112-WORK-CANDIDATE-*` artifact through the GitHub API.
- Verifies the inner candidate ZIP against `candidate_metadata.json -> package_sha256` when metadata is present.
- Compares SHA256 of package files with the selected game directory.
- Backs up every file that will be replaced or removed under `.wow112_updater/backups/`.
- Installs only changed EXE/DLL files.
- Generates `dlls.txt` from DLL order in the verified candidate ZIP, including `WoWControlHub.dll` when present.
- Tracks updater-managed files in `.wow112_updater/installed.json`; later updates can remove stale managed files safely.
- `ROLLBACK` restores the newest updater backup.
- `URUCHOM WOW` starts the installed WoW executable with the game directory as working directory.
- Updates are blocked while a process executable from the selected game directory is running.

## Private repository authentication

The repository is private, so GitHub does not permit anonymous artifact downloads. V1 accepts a GitHub token with read-only access to this repository. Required fine-grained repository permissions are:

- Contents: Read
- Actions: Read

The token is stored only on the local PC, protected with Windows DPAPI (`CurrentUser`). It is never written to the repository or updater logs.

## Channels

- `TEST (work)` is active now and consumes the existing work-candidate pipeline.
- `STABLE (main)` is already represented in the GUI but intentionally reports unavailable until a stable-package workflow is promoted to `main`. This prevents the updater from pretending an unverified stable package exists.

## Build

`.github/workflows/build_updater.yml` compiles `WoW112Updater.exe` as a Windows x86 .NET Framework 4.8 WinForms executable and performs a PE32/x86 smoke check before uploading the artifact.
