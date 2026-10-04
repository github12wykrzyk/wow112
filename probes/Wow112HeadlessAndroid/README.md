# WoW112 Headless Android Probe

Isolated protocol probe for World of Warcraft 1.12.1 build 5875. It is intentionally independent from the current injected DLL/AUX runtime and is not part of `parallel_candidate.json`.

## Scope of POC-01

- Android x86_64 executable for a PC emulator.
- SRP6 login to auth server as WoW 1.12.1 build 5875 / Win32 x86.
- Realm list.
- World authentication and encrypted session.
- Character enumeration and character login.
- PASS only after `SMSG_LOGIN_VERIFY_WORLD` is received.
- No AH, Mail, movement, automation or UI yet.

## Runtime configuration

No credentials are stored in the repository.

Required environment variables:

- `WOW112_ACCOUNT`
- `WOW112_PASSWORD`

Optional:

- `WOW112_AUTH_ADDR` (default `10.0.2.2:3724`; Android Emulator host-loopback alias)
- `WOW112_REALM_INDEX` (default `0`)
- `WOW112_WORLD_ADDR` (override the realm-list address if the server advertises an address unreachable from the emulator)
- `WOW112_CHARACTER` (default: first character)

Example shape when run through ADB:

```text
adb push wow112-headless-android-probe /data/local/tmp/
adb shell chmod 755 /data/local/tmp/wow112-headless-android-probe
adb shell 'WOW112_AUTH_ADDR=host:3724 WOW112_ACCOUNT=... WOW112_PASSWORD=... WOW112_CHARACTER=... /data/local/tmp/wow112-headless-android-probe'
```

Do not put account credentials into workflow files, commits, issues or logs.

## Success criterion

The first real server test is successful only if the probe prints:

```text
[WOW112-ANDROID-PROBE] PASS: entered world session
```

Compilation alone is not gameplay/protocol proof.
