# WoW112Updater

Windows GUI updater/launcher for the private `github12wykrzyk/wow112` repository.

Target game runtime remains World of Warcraft 1.12.1 build 5875 x86. The updater itself is an external Windows utility and does not inject into the game.

## Current 2.1 safety + diagnostics behavior

- `TEST (work)` and `STABLE (main)` inspect the newest run of the expected GitHub Actions workflow on the selected branch.
- The updater installs only when that newest run is `completed` with `conclusion=success`. It never silently falls back to an older successful artifact when the newest run is queued, running, cancelled or failed.
- Downloads the corresponding candidate artifact through the GitHub API.
- Requires `candidate_metadata.json` and a valid 64-character `package_sha256`; missing/invalid metadata blocks install and VERIFY / REPAIR.
- Verifies the inner candidate ZIP against `package_sha256` before any game files are changed.
- Rejects nested ZIP paths and duplicate root filenames even when they differ only by letter case.
- Compares SHA256 of the canonical root WoW EXE **and** every DLL independently against the selected game directory; the dashboard explicitly reports EXE state (current / update / missing) even if all DLLs are unchanged.
- The **DLL-e** dialog has a persistent update toggle for every DLL. Checked means the updater may replace/add/remove that DLL; unchecked preserves the local DLL version and skips its update/removal.
- Updates the root canonical EXE from the verified candidate automatically (no DLL toggle applies to EXE), checks its SHA256 after installation and includes it in the rollback backup. The launcher uses that installed EXE. Generates `dlls.txt` from the verified candidate order while preserving locally held DLLs whose per-DLL update toggle is disabled.
- Tracks updater-managed files in `.wow112_updater/installed.json`; state and backup manifests are written transactionally through a temporary file with a previous-state recovery copy.
- File replacement first uses `File.Replace` and has a verified copy fallback for filesystems where replace semantics are unavailable.
- Shows the locally installed channel, GitHub Actions run, short commit SHA and installation time directly in the GUI.
- `UPDATE + PLAY` performs the update flow and then launches WoW in one action.
- Rollback history is selectable in the GUI; at most 10 newest backups are retained.
- `URUCHOM WOW` starts only a real WoW executable (`WoW.exe` or project `WoW_*.exe`) from the selected directory.
- `WoW112Updater.exe` may safely live directly in the WoW directory; it is excluded from the running-game guard.
- Realmlist selector reads and writes `<game>/realmlist.wtf` without touching unrelated lines. Presets: OctoWoW (`play.octowow.st`) and RavenCraft (`logon.ravencraft.io`).
- Updater version has one source of truth: `UpdaterBuildInfo.Version` in `tools/updater/UpdaterSafety.cs`; the GUI, diagnostics and `updater_build.json` use that value.

## Maintenance tools

### VERIFY / REPAIR

The updater retrieves the exact GitHub Actions artifact recorded in `.wow112_updater/installed.json`, requires and verifies the candidate ZIP SHA256, reconstructs the expected EXE/DLL/dlls.txt set and compares local SHA256 values.

If files are missing, modified or stale, the updater offers to repair them from the exact same installed build. Repair is blocked while WoW is running, creates a rollback-compatible backup first and verifies the files again after writing.

### DIAGNOSTYKA ZIP

Creates `.wow112_updater/diagnostics/WoW112_diagnostics_*.zip` containing sanitized installed-state metadata, `dlls.txt`, `realmlist.wtf` when present, updater/runtime information, SHA256/size status for managed files, backup index and the current updater session log.

The diagnostics ZIP intentionally never includes the GitHub token, updater `config.json` or DPAPI-protected token material.

### WYŚLIJ RAPORT DO GITHUB

Updater 2.1 can create a sanitized diagnostic GitHub Issue directly in `github12wykrzyk/wow112`.

The report includes:

- installed channel, Actions run, head SHA and artifact identity,
- current `dlls.txt`,
- newest local WoWDiagHub JSONL records from `<game>/.wow112_debug/`,
- up to two most recent native WoW `Errors/*.txt` crash reports from the last 72 hours (bounded head/tail excerpts),
- up to two matching Windows Application Error/Windows Error Reporting records from the last 72 hours, including faulting module/exception details when Windows recorded them,
- the tail of the updater session log,
- a deterministic diagnostic signature used to avoid duplicate open Issues.

The signature excludes volatile report-generation time and updater-session timestamps. It uses installed build identity, `dlls.txt`, WoWDiagHub data, the recent native crash reports and matching Windows exception records. A new native crash may create a new Issue even when the DLL set did not change.

Game-directory and user-profile paths are sanitized case-insensitively before upload. Native crash excerpts and Windows event messages can still contain character names or other in-game data; sending a report explicitly uploads these excerpts to the selected private repository. No raw memory dumps or arbitrary Windows events are uploaded. All file excerpts and event searches are bounded.

The normal updater token remains read-only and is **not** reused for issue creation.

Issue upload uses a separate fine-grained token scoped only to this repository with:

- Issues: Read and write

The report token is stored separately under `%APPDATA%/WoW112Updater/report_token.dpapi`, protected with Windows DPAPI (`CurrentUser`). It is not added to diagnostic ZIPs or report bodies.

`TOKEN RAPORTU` lets the user replace this token from the GUI. If GitHub rejects the stored report token with HTTP 401/403, the updater removes that rejected local token automatically so the next send attempt asks for a replacement instead of becoming permanently stuck on bad credentials.

### WoWDiagHub candidate module

The TEST(work) candidate may include `WoWDiagHub.dll`, an observer-only x86 diagnostics provider. V1 intentionally does not hook gameplay functions, install a global exception handler or perform network access.

It exposes `W112_DIAG_API_V1` so other DLLs can later report structured events without each module implementing its own logging transport. Local files are written under `<game>/.wow112_debug/` in JSONL form, with an in-process ring buffer used for snapshots.

Gameplay modules are not automatically instrumented merely because WoWDiagHub is present; instrumentation should be added point-by-point after the base diagnostics module is accepted in game.

### AKTUALIZUJ UPDATER

The updater can update itself. It inspects the newest `Build WoW112 updater` run for the selected channel branch and refuses to fall back to an older artifact if the newest run is not successful. For a successful newest run it validates `updater_build.json`, SHA256-verifies both `WoW112Updater.exe` and the x86 bootstrap, stages the new executable and starts `WoW112UpdaterBootstrap.exe`.

The bootstrap waits for the current updater process to exit, verifies the staged SHA256 again, replaces the updater executable, keeps `previous_updater.exe` under `.wow112_updater/selfupdate/` as recovery evidence and restarts the updater. No token is passed to the bootstrap.

`self_update_protocol: 1` is the compatibility contract for this replacement flow.

## Private repository authentication

The repository is private, so GitHub does not permit anonymous artifact downloads. The updater accepts a GitHub token with read-only access to this repository. Required fine-grained repository permissions are:

- Contents: Read
- Actions: Read

The token is stored only on the local PC, protected with Windows DPAPI (`CurrentUser`). It is never written to the repository, diagnostics ZIP or updater logs.

The optional issue-report token is separate and should have only the Issues permission described above.

## Channels

- `TEST (work)` consumes the newest aggregate work candidate only when its newest workflow run succeeded.
- `STABLE (main)` consumes the stable candidate/updater build from `main` after this infrastructure is accepted and promoted.

A failed/in-progress newest run is surfaced as an explicit error instead of silently serving an older package. This prevents accidental testing of stale code after a new push.

## Build

`.github/workflows/build_updater.yml` runs `python tools/verify_current.py`, compiles `WoW112Updater.exe` and `WoW112UpdaterBootstrap.exe` as Windows x86 .NET Framework 4.8 executables, verifies PE32/x86 for both and emits SHA256 metadata in `updater_build.json` using the same `UpdaterBuildInfo.Version` constant as the application.


## Single-screen dashboard (2.0, work candidate)

One Polish dashboard now contains configuration, installed/available build details,
update/launch actions, maintenance, backup selection and a live log. Token editing
and the enlarged log use small secondary dialogs. No navigation sidebar or full
window scrolling is required. The header uses a clean gold wordmark. The previous JPEG in the repository has a broken data stream and is no longer embedded or rendered.

`BuildUi` initializes core controls/events; feature controllers register explicit
control references through `IUpdaterHost`. `BuildDashboard` lays them out once before
WinForms starts. The old `UpdaterUiPolishFix.cs` is no longer compiled. No label-based
control lookup or post-show child-layout replacement is used.

All feature actions share the busy-state lock, including game-path/server controls.
The GitHub badge distinguishes an unverified saved token from a successful API call.
Changing the channel, directory or token invalidates remote build details. Installation
file replacement runs on a worker with UI-thread log delivery and a fresh running-game
check immediately before installation. Existing SHA, backup and workflow gates remain.

The default client area is 1040 x 680 logical pixels, compact target 960 x 620.
The window fits the monitor work area and declares PerMonitorV2 awareness. Extremely
small work areas are outside the supported layout target. Windows CI runs an offline
`--ui-smoke <directory>` probe: real WinForms screenshots, key states, button bounds,
text fit, busy restoration and explicit 125/150% layout simulations. These simulations
are not native monitor DPI switching tests; interactive Windows DPI validation remains
required. The probe uses a temporary configuration directory and no GitHub credentials.

## EXE refresh (2.2, TEST work)

The TEST candidate workflow now triggers on root `*.exe` changes in addition to runtime manifests, so EXE-only patches create a new downloadable artifact. The updater compares and displays EXE SHA256 separately from DLL changes; its offline UI smoke covers EXE missing/current/changed. A successful installation logs whether EXE was replaced.


## LazyScript + LazyRogue auto-install (Updater 2.3, TEST/work)

- The newest successful TEST candidate artifact carries the separate `WoW112_LAZYROGUE_HYBRID_ADDONS.zip` and `addon_metadata.json` in addition to the strict root-only game runtime ZIP.
- The updater validates the outer artifact's `git_sha`, SHA256, file count and exact addon path allowlist before touching game files; a missing or invalid addon archive blocks TEST installation instead of leaving incompatible DLL/addon versions.
- UPDATE / UPDATE + PLAY installs `Interface/AddOns/LazyScript/` and `Interface/AddOns/LazyRogue/` automatically, with per-file SHA256 comparison, transactional backup/rollback and VERIFY / REPAIR from the exact installed build. It does not change unrelated addons, does not include the addon files in `dlls.txt`, and does not change the stable `main` channel.
- Existing updater 2.2 cannot auto-install addons; use the built-in `AKTUALIZUJ UPDATER` on TEST once to acquire updater 2.3. The native hybrid data source is the existing experimental AutoKick V3 DLL, not an added LS-only DLL.


## WoW account profiles (Updater 2.4, TEST/work)

- Open **Konta WoW** in the updater dashboard. Add a profile name, login and password; select a default profile, edit an existing profile (leave the password empty to keep the saved one), or delete it.
- **Uruchom grę z profilem** launches the same verified installed game EXE and binds the chosen profile to that specific newly launched process. **Uruchom grę** and **Aktualizuj i uruchom** also use the currently selected default profile. Multiple running clients can use different profiles; credential entry targets the newest still-running updater-launched process for the selected profile.
- Passwords are encrypted with Windows DPAPI \`CurrentUser\`, with a separate account-vault entropy value. The vault is stored only in \`%APPDATA%\WoW112Updater\wow_accounts.json\`, independently of the game directory and GitHub token. The account login/label are locally visible metadata, but plaintext passwords are never written to disk, logs, GitHub, CLI arguments, clipboard, updater diagnostics or game configuration. This vault is not portable to another Windows user/computer. Back up access to the accounts separately.
- **Wpisz dane do gry** is an explicit, user-confirmed action after opening the game's *login screen* and putting the cursor in the login field. It activates only the previously updater-launched window belonging to the selected profile's process ID, checks the foreground process before sending each key, types login + TAB + password using Windows \`SendInput\` and does **not** press Enter. Do not invoke it from chat, the character-selection screen or while already in-game. Unicode keyboard input on the 5875 client and fullscreen focus behavior require an in-game test; if unsupported, type credentials manually.
- The updater has no automatic login on launch, cannot recover passwords for another Windows user, and does not modify WoW.exe, DLLs or realmlist for account profiles. The feature does not inject code, persist a plaintext password in Config.wtf or bypass the game's login UI.
- The Windows offline \`--ui-smoke\` now checks profile persistence, encryption/DPAPI roundtrip, deletion and the registered dashboard action, without using real accounts or sending keystrokes.

## GitHub activity monitor (Updater 2.5 / TEST work)

The **Monitor GH** button opens a read-only status window for `work`, `parallel`, and `main`.
While the updater is open, it polls GitHub once every 60 seconds and shows branch HEAD commit,
recent candidate workflow conclusion, running/queued workflows, and the last successful check time.
An older successful run is explicitly marked as older than branch HEAD. A manual refresh is available.
The monitor reuses the existing read-only GitHub token (Contents + Actions), stores no new credentials,
does not alter game files, and is disabled during the offline UI smoke test. GitHub inactivity
cannot establish whether an AI conversation is still generating text outside GitHub.

## GitHub status in main dashboard (Updater 2.6 / TEST work)

The main window shows three color-coded statuses for the active delivery branches work, parallel and main, without opening the optional Monitor GH dialog. Green = SUCCESS, yellow = PENDING/RUNNING, red = FAIL (including cancelled/timed_out), gray = UNKNOWN/offline. Each badge shows branch, current HEAD and time of last read; tooltip provides workflow/run details. An initial refresh starts when the dashboard appears and repeats every 10 seconds without overlapping requests. Runs on older SHAs never make the latest commit green. Status colors report CI observations only; installation still requires the existing successful candidate run, package hash check and FINAL_PACKAGE: PASS. Historical, promote and feature branches are not active delivery channels and are not included in this compact status strip.
