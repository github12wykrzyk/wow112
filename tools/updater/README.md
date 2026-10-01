# PARALLEL updater — independent experimental line

This copy is built only on branch `parallel` and installed as `WoW112ParallelUpdater.exe`. It retrieves **only** the newest successful `Build work candidate` run scoped to `parallel`, and its self-update retrieves **only** the `Build WoW112 updater` run scoped to `parallel`. It never offers `work` or `main` as a channel. The candidate build ZIP names remain unchanged but GitHub Actions run selection is branch-scoped.

Config and read-only GitHub credentials use `%APPDATA%/WoW112ParallelUpdater` (separate from the original updater). Managed state, backups, diagnostics and self-update stage use `.wow112_parallel_updater/` (separate from `.wow112_updater/`). PARALLEL also accepts a folder that has `.wow112_updater/installed.json`; that marker is no longer a blocker. Using one folder for both channels can replace overlapping game EXE/DLLs, while the two updaters retain independent installed-state and backup directories. Use separate folders only when you want both game builds installed simultaneously. Self-update verifies the `parallel` channel and updater binary name in `updater_build.json` before replacement. The original `main`/`work` updater is unchanged.

The sections below describe the shared engine; their older TEST/STABLE labels refer to the original updater and are not available in this branch-specific build.

## Konta WoW — poprawka zapisu i wpisywania (2.4-parallel.2)

- Wybrany profil pokazuje teraz status **Hasło zapisane i możliwe do odczytu (DPAPI)** zamiast pustego pola bez wyjaśnienia. Puste pole przy edycji oznacza „zachowaj dotychczasowe hasło”. Po kliknięciu **Zapisz profil** updater ponownie otwiera lokalny plik kont i odszyfrowuje hasło; nie zgłasza sukcesu, jeśli zapis lub odczyt się nie powiedzie. Dotychczasowe profile i szyfrowanie pozostają niezmienione.
- Po restarcie updatera **Wpisz dane do gry** potrafi odnaleźć uruchomione klienty w wybranym katalogu gry. Jeżeli działa kilka okien i nie ma zapamiętanego powiązania profilu z procesem, użytkownik wybiera okno po PID — dane nie są kierowane losowo do innego klienta.
- Do wprowadzania loginu i hasła używane są fizyczne skankody klawiszy Windows zamiast `KEYEVENTF_UNICODE`; cały tekst jest mapowany według układu klawiatury okna gry przed wpisywaniem, z kontrolą aktywnego PID przed wysłaniem każdego klawisza. Po zatwierdzeniu okna logowania podawany jest login, TAB, hasło, bez Enter. Jeśli WoW 5875 ignoruje symulowane skankody albo uprawnienia gry blokują wejście, potrzebny jest test w grze; nie potwierdzamy skuteczności tylko na podstawie testu offline.
- Zwykłe **Uruchom grę** nadal tylko uruchamia klienta — wpisanie danych jest oddzielną, świadomą akcją **Wpisz dane do gry** na ekranie logowania. Magazyn Parallel pozostaje niezależny od magazynu `work`.

## Konta WoW (2.4-parallel.1, PARALLEL)

- The **Konta WoW** button on the Parallel dashboard adds, edits, deletes and selects a default game account profile. It does not modify the original work/main updater.
- The credential vault is local to the Parallel updater: \`%APPDATA%\WoW112ParallelUpdater\wow_accounts.json\`. Passwords are encrypted with Windows DPAPI \`CurrentUser\`, never transmitted to GitHub or written to the game directory, diagnostic archives, or updater logs. The vault cannot be decrypted under a different Windows account; account vaults from work and parallel remain deliberately separate.
- **Uruchom grę z profilem** associates the profile with the newly launched Parallel game process. **Uruchom grę** and **Aktualizuj i uruchom** use the default selected profile. Multiple simultaneous clients can be associated with different profiles.
- **Wpisz dane do gry** requires the user to select a profile, manually focus its client login screen and cursor in the login field, and confirm. It checks the foreground process before each keystroke, sends login, TAB, password, and never Enter. This is an experimental Win32 keyboard-input feature for the WoW 1.12.1 (5875) login UI: fullscreen, keyboard layout and in-game behavior still require manual testing. Do not invoke this control while in chat or in the game world.
- The Windows CI UI smoke tests local DPAPI vault persistence and account UI registration. The updater self-update mechanism continues to retrieve only successful Parallel updater artifacts from branch \`parallel\`.

---

## Updater 2.9-parallel.8 — self-update workflow lookup fix

- Self-update no longer scans the shared `/actions/runs` feed for `Build WoW112 updater`. On active development days unrelated workflows can occupy the first 50 rows and make the updater falsely report that its workflow does not exist.
- The updater now queries `.github/workflows/build_updater.yml` directly for `parallel` runs, then keeps the existing exact-run status, artifact name, provenance, SHA256 and x86 validation gates.

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


## Parallel automatic LazyScript and LazyRogue update (2.3-parallel.3)

- The newest successful `parallel` candidate artifact includes `WoW112_LAZYROGUE_HYBRID_ADDONS.zip` plus `addon_metadata.json` alongside the unchanged root-only EXE/DLL runtime ZIP. The updater requires the addon archive and verifies commit SHA, SHA256, file count and path allowlist before any installation.
- `AKTUALIZUJ UPDATER` fetches version 2.3-parallel.3 from the branch-specific `WoW112ParallelUpdater-<sha>` workflow. `UPDATE + PLAY` then installs/updates `Interface/AddOns/LazyScript/` and `Interface/AddOns/LazyRogue/` with per-file hashes, backup, rollback and VERIFY/REPAIR; unrelated addons and `dlls.txt` are untouched.
- Parallel is **not** work/main: no AutoKick V3 DLL was added to the parallel runtime. LazyScript's native cast bridge operates only when its existing optional native AutoKick module is present; parallel runs the conservative chat-only fallback pending a dedicated parallel native interrupt module. The addon has not been validated for SuperWoW compatibility in a live 5875 client.

## GitHub activity monitor (2.5-parallel.5)

The **Monitor GH** button shows current branch HEAD and recent GitHub Actions status for `parallel`, `work` and `main`. It refreshes every 60 seconds while the parallel updater is open and supports manual refresh. A successful build on an older SHA is not treated as a build for the current HEAD. Monitoring is read-only, uses the existing token with Contents and Actions read permissions, does not change game files, and cannot determine whether ChatGPT is generating a reply without interacting with GitHub.

## Oczyść DLL (2.5-parallel.6)

Przycisk **Oczyść DLL** wyświetla DLL z głównego katalogu gry i poprzednio wyłączone pozycje. Zaznaczenie pliku oznacza usunięcie i zablokowanie ponownej instalacji; odznaczenie wcześniej wyłączonego modułu pozwala przywrócić go przy następnej aktualizacji. Czyszczenie wymaga zamkniętej gry i potwierdzenia. Pliki nieznane updaterowi są oznaczone i nie są wybierane automatycznie. Backup obejmuje usuwane DLL, `dlls.txt` i stan instalacji; rollback odtwarza te pliki, ale lista wyłączeń pozostaje w lokalnej konfiguracji do czasu świadomej zmiany. VERIFY/REPAIR respektuje wyłączenia. Przełączniki w oknie **DLL-e** nadal sterują wyłącznie aktualizowaniem istniejących plików.

## Updater 2.6-parallel.1 — routing visibility and self-update provenance

- Monitor GH shows live `feature/*` and `promote/*` refs and short HEAD alongside `parallel`, `work`, `main`. Experiment and promotion refs are **read-only**; this Parallel installer never picks their game artifacts automatically. The GitHub branch listing is limited to 100 entries and explicitly warns if truncated.
- Self-update requires an artifact named `WoW112ParallelUpdater-<workflow-head-sha>`; its `updater_build.json` must match that same exact workflow SHA, `parallel` channel, both binary names, SHA256, sizes, x86 machine and bootstrap protocol before staging. Gameplay-only commits can advance Parallel after the updater workflow: the updater binary is bound to its own workflow SHA, not to the newer gameplay HEAD.
- The existing game installer still requires an exact current `parallel` HEAD, candidate attestation, and `FINAL_PACKAGE: PASS`. Disabled DLL cleanup, backups and rollback are unchanged. No changes to game EXE, active DLLs or `main`/`work`.

## Główny panel statusów GitHub (Updater 2.6-parallel.5)

Statusy aktywnych kanałów work, parallel i main w górnym wierszu głównego okna bez osobnego dialogu. Zielony = SUCCESS, żółty = PENDING/RUNNING, czerwony = FAIL (również cancelled/timed_out), szary = UNKNOWN, brak tokenu lub błąd odczytu. Wyświetlany jest HEAD i czas ostatniego odczytu, a dymek zawiera workflow i run. Odświeżanie zaczyna się po otwarciu okna i ponawia co 10 sekund bez nakładania zapytań. Starszy udany run nie oznacza sukcesu nowszego HEAD. Status dotyczy CI i nie zastępuje weryfikacji paczki. Dialog Monitor GH nadal pokazuje dodatkowo gałęzie feature/* i promote/*, lecz są one wyłącznie podglądem, nie kanałami instalacji.


## Updater 2.9-parallel.9 — AuxVmangos report snapshot

GitHub diagnostic reports now include the newest AuxVmangos SavedVariables diagnostic snapshot from WTF/Account/*/SavedVariables/AuxVmangos.lua. AuxVmangos 0.11 keeps a bounded 80-event ring and compact vendor/query state for this purpose. The report does not expose the account-directory name; it labels only the addon file and modification time. SavedVariables are flushed by WoW on /reload, logout or client exit, so while the game is running the report may contain the latest flushed snapshot rather than the current in-memory state. The Aux snapshot is also part of the deterministic diagnostic signature.

## Updater 2.9-parallel.10 — dwie belki statusu GitHub

Nagłówek monitora GitHub mieści cały szybki status w dwóch belkach. Pierwsza pokazuje równolegle `PARALLEL`, `WORK` i `MAIN` z krótkim SHA; `SUCCESS` na development jest prezentowany jako `READY`, a `MAIN` zachowuje zielony `STABLE` z ostatniego autorytatywnego `Build stable candidate`, gdy późniejszy commit main nie uruchamia stable workflow. Druga belka pokazuje najważniejszy bieżący exact-HEAD gate `feature/*` lub `promote/*` (PREFLIGHT / PRE-PROMOTE), a `| +N` sygnalizuje dodatkowe aktualne gate'y. Historyczne branche bez exact-HEAD gate w 100 najnowszych runach nie zaśmiecają nagłówka; pełna lista dopasowanych gate'ów pozostaje w tooltipie i Monitor GH. Feature/promote pozostają wyłącznie podglądem i nigdy nie są instalowane jako Parallel.



## Updater 2.9-parallel.11 — AUX filters + AH Market Dump

- Original AUX Search Filter Builder is now an explicit upstream allow-list for AUX_ARB. The bridge forwards the active compiled Search filter label into AuxVmangos diagnostics, and AUX_ARB accepts named/exact Blizzard searches as well as post-filters. The original AUX validator still decides which rows reach the bot; guarded vendor/DE/flip economics and exact live revalidation remain authoritative. Old AUX Auto Buy/Auto Bid stay disabled while AUX_ARB is attached.
- AuxVmangos market history schema 2 keeps compact snapshots with min/p25/median/p75/max/average/weighted prices plus depth prices for 5/10/20 units, seller count, units at the current floor and net supply decrease. The old default retention of 24 snapshots migrates once to 96; the configurable ceiling is 336 snapshots/item.
- **Wyślij AH dump** uses the existing DPAPI-protected Issues token and uploads only the newest flushed AuxVmangos `marketMeta` plus the complete compact `marketDB` history. Large dumps are chunked across comments of one GitHub Issue and include a deterministic payload SHA256. Account-directory names, credentials and unrelated SavedVariables are not uploaded.
- WoW writes SavedVariables on `/reload`, logout or exit. If the client is still open, run `/reload` immediately before **Wyślij AH dump** to include the newest in-memory market history.
