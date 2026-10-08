# Summon Service V1 — artifact contract

The packaging layer owns deployment only. It does **not** implement summon parsing, invites, portal use, payment logic, ledger semantics, AH actions, arbitrary Lua, or arbitrary packet sending.

## Required runtime binaries

- `bin/WoW112SummonService.exe`
- `bin/WoW112SummonOperatorConsole.exe`

They must be release/self-contained binaries: the operator machine must not need Rust or .NET SDKs.

`WoW112SummonService.exe` is launched with:

`--config <config/service.json> --data-dir <data> --log-dir <logs> --stop-file <state/service.stop> --health-file <state/health.json>`

Runtime contract:
1. continuously refresh `health-file` while ready;
2. stop cleanly when `stop-file` appears;
3. consume the WoW password only from the configured environment variable (default `WOW112_PASSWORD`), never from command-line arguments;
4. write service events/data only under `data/` and operational logs only under `logs/`;
5. operator control remains limited to `Pause`, `Resume`, and `ManualWhisper` in the console implementation.

The console is launched with `--root <package-root> --events <data/events.jsonl>`.

## Package layout

```text
SummonServiceV1/
  START_SUMMON_SERVICE.cmd
  STOP_SUMMON_SERVICE.cmd
  STATUS_SUMMON_SERVICE.cmd
  OPEN_CONSOLE.cmd
  BACKUP_DATA.cmd
  ROLLBACK.cmd
  UPGRADE_SUMMON_SERVICE.cmd
  VERSION
  manifest.json
  bin/
    WoW112SummonService.exe
    WoW112SummonOperatorConsole.exe
  config/
    service.json
    service.example.json
  data/
  logs/
  state/
  backups/
    data/
    releases/
  scripts/
  docs/
```

`config/service.json`, `data/`, `logs/`, `state/`, and `backups/` are mutable and intentionally excluded from the immutable file-hash list. Every shipped executable/script/launcher/document is SHA256-pinned by `manifest.json`.
