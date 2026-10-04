# WoW112 Android Headless - POC-05

Isolated headless protocol client for World of Warcraft 1.12.1 build 5875. It is independent from the injected Windows DLL/AUX runtime and is not part of `runtime/parallel_candidate.json`.

## POC-05 scope

- SRP6 auth, realm list, world authentication and encrypted world session.
- Character enumeration/login and reconnect with full state rebuild.
- Read-only Auction House query.
- Read-only mailbox listing.
- Player gold + owned item/container inventory snapshot.
- Guarded mailbox `take-money` / `take-item` actions.
- Fail-closed mutation handling: no automatic mutation retry after an uncertain post-send result.
- COD item collection is refused.

## Fast Windows test

Run `RUN_POC05.cmd` from this artifact. The launcher:

1. finds `adb.exe` from PATH, Android SDK environment variables, or common Android SDK locations;
2. waits for an emulator/device;
3. pushes the exact bundled Android binary to `/data/local/tmp/` and makes it executable;
4. asks for the WoW login/password only once per run;
5. asks which POC-05 mode to use;
6. runs the probe and keeps the window open so the final PASS/error remains visible.

Credentials are not written to the repository or to files in the bundle.

### Modes

- `Enter` / `0` - read-only mailbox mode; no mailbox mutation is sent.
- `1` - take money from one explicit `mail_id`.
- `2` - take one item from one explicit `mail_id`.

Mutation modes additionally require typing `YES`. The probe still validates the selected mail record, refuses COD item collection, and fails closed if the result becomes ambiguous after the mutation was sent.

## Optional launcher parameters

`RUN_POC05.ps1` accepts:

- `-AuthAddr` (default `10.0.2.2:3724`)
- `-WorldAddr`
- `-AhGuid`
- `-MailboxGuid`
- `-RealmIndex` (default `0`)
- `-SoakSeconds` (default `60`)
- `-ReconnectLimit` (default `60`)
- `-NoPause`

Example:

```powershell
.\RUN_POC05.ps1 -MailboxGuid 0xF11002A4A5002A0C -AhGuid 0xF130003D4100023A
```

Leaving GUID overrides empty keeps native object-update autodiscovery enabled.

## Exact-build evidence

Every workflow artifact contains:

- `BUILD_INFO.txt` - branch, exact Git SHA, workflow run ID, target and binary SHA256;
- `SHA256SUMS.txt` - checksums for all user-facing bundle files;
- `wow112-headless-android-probe` - Android x86_64 executable;
- `RUN_POC05.cmd` / `RUN_POC05.ps1` - Windows launcher.

Before testing, the workflow itself verifies `SHA256SUMS.txt` with `sha256sum -c`.

Compilation/CI proves artifact integrity only. Auction/mail behavior and server-side mutation semantics still require the explicit emulator/gameplay test on the exact SHA shown in `BUILD_INFO.txt`.
