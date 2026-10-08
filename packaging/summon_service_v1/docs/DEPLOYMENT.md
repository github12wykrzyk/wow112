# Deployment and upgrade

## Fresh install

Extract the release ZIP to a writable local folder on Windows 11. Edit non-secret settings in `config/service.json`. Prefer supplying the credential through the configured secure credential source/environment; if absent and `prompt_if_missing=true`, `START_SUMMON_SERVICE.cmd` prompts with `Read-Host -AsSecureString`. The plaintext password is never written to disk, command-line arguments, package logs, or reports; the supervisor handoff uses a current-user DPAPI blob in `state/`.

## Start/stop and crash policy

`START_SUMMON_SERVICE.cmd` validates the exact manifest, checks the binary, prevents a second supervisor for the same folder, obtains the credential, and starts a hidden supervisor. The supervisor publishes PID files, rotates operational logs, and restarts an unexpectedly exited service with bounded backoff. `STOP_SUMMON_SERVICE.cmd` requests supervisor stop; the supervisor creates the service stop-file and waits for the configured graceful deadline before an explicit hard kill. A stuck supervisor is **not** implicitly killed by the outer stop command.

## Upgrade transaction

`UPGRADE_SUMMON_SERVICE.cmd NEW.zip EXPECTED_SOURCE_SHA` executes:

1. stage and SHA256-verify every immutable file and exact 40-hex source SHA;
2. backup `config/` + `data/`, then create a complete rollback snapshot;
3. graceful stop;
4. replace immutable release files while preserving live config/data;
5. run a checksum-pinned optional `scripts/migrate.ps1` if the new package contains one;
6. start and wait for health;
7. on any post-snapshot failure, restore the exact pre-upgrade snapshot and restart it.

A pre-verification failure does not stop or mutate the running service.

## Rollback

`ROLLBACK.cmd` restores the newest exact pre-upgrade release snapshot, verifies its embedded manifest before replacement, starts it, and requires health. Data-only backups are stored separately under `backups/data/`.
