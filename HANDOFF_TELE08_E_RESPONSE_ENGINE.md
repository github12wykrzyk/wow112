# HANDOFF — TELE08 E Response Engine + Unknown Whisper Dump

## Identity

- Track: TELE08 E — Response Engine + Unknown Whisper Dump
- Branch: `feature/tele08-e-response-engine-v1`
- Authoritative base: `04e8337fec7ba0d76c8267e03c1324f7039f2487`
- Tested code/CI SHA: `96e8b22e41987710b2d87061da1821dbe35d19d9`
- Coordination/preflight SHA before this handoff: `6e6044980b2a8e7888295c3f0ed39b4e24bf9b4e`
- Scope: response policy + unknown-whisper reporting only. No WoW whisper packet transmission is implemented by Track E.

## Deliverables

Track E adds:

- `probes/Wow112HeadlessAndroid/src/tele_response_engine.rs`
- `probes/Wow112HeadlessAndroid/src/lib.rs` module export
- `.github/workflows/tele08_e_response_engine_ci.yml`
- `runtime/parallel_tasks/tele08-e-response-engine-v1.json`

It does not modify TELE06 ritual/portal/click/movement behavior or TELE07 supervisor runtime behavior.

## Public API / contract

Primary response API:

```rust
ResponseEngine::new(config: ResponseEngineConfig)
ResponseEngine::handle_context(context: ResponseContext, now: u64) -> Vec<ResponseDecision>
```

Each decision exposes:

```rust
ResponseDecision {
    should_send,
    recipient,
    response_kind,
    text,
    cooldown_key,
    reason,
}
```

Unknown-whisper reporting API:

```rust
UnknownWhisperDumper::new(config: UnknownWhisperDumpConfig)
UnknownWhisperDumper::record_unknown(&UnknownWhisperRecord) -> io::Result<()>
```

Track E only decides and reports. A later integration layer must consume `should_send=true` decisions and perform any actual whisper transmission.

## Response contexts covered

`ResponseContext` supports:

- request accepted
- request queued, optionally with queue position and queue length
- already grouped
- in combat
- unsupported destination
- destination unavailable: low shards, manual off/maintenance, unhealthy team, temporary
- summon started
- summon completed / thank-you
- request expired
- safe job failure
- competition message
- unknown message

Unknown defaults to `should_send=false` with reason `UnknownNoReply`.

Unsupported-destination responses use only the alternatives supplied by the caller. Track E never invents or hardcodes the current destination pool.

Completion-time alternative destinations are opt-in through `completion_mentions_alternatives`; the default is a simple thank-you.

## Cooldown / rate policy

The decision core never reads wall-clock time. The caller supplies explicit `now: u64`.

Configurable controls:

- optional global minimum interval
- per-recipient cooldown
- per-recipient + response-kind cooldown
- competition-specific cooldown
- duplicate-text suppression per recipient

Rate state is updated only after an allowed decision. A cooldown blocks while `now.saturating_sub(last) < duration`; therefore the exact boundary is allowed.

Recipient keys are normalized with trim + ASCII lowercase. Cooldown state is intentionally in memory only and does not persist across process restarts.

## Templates and safety

Default response templates are centralized in `TemplateConfig` and can be replaced through `ResponseEngineConfig`.

Supported caller-provided variables include destination, alternatives, queue position/length, timeout and retry values when those values are explicitly supplied by the caller.

Template substitution is single-pass. Substituted string values are control-character sanitized and are not reparsed as template syntax, preventing placeholder-style format injection through user text.

Failure responses are deliberately generic and do not expose internal runtime details.

## Unknown whisper JSONL dump

Schema version: `1`.

Default path:

`tele08_unknown_whispers.jsonl`

Default bounded size: 8 MiB with a single rotated backup at `.1`.

`UnknownWhisperRecord` supports:

- `schema_version`
- `timestamp`
- `sender`
- `raw_text`
- optional `normalized_text`
- optional `source_role`
- optional `source_destination`
- `parser_signals`
- optional `parser_reason`
- optional `current_destination_context`
- category: `unknown`, `low-confidence`, or `competition`

JSON escaping handles quotes, backslashes, CR/LF/tab, other control characters and Unicode. Each append writes one complete JSON line and flushes it. Previous valid lines are not rewritten.

The dumper does not obtain a timestamp itself; the integration caller supplies it. This preserves deterministic policy behavior and keeps time ownership outside Track E.

The response engine does not automatically invoke the dumper for `Unknown`; parser/integration code should explicitly create and record an `UnknownWhisperRecord` when appropriate.

## Tests and evidence

Dedicated Track E CI workflow: `.github/workflows/tele08_e_response_engine_ci.yml`.

Final non-mutating CI run on tested code SHA `96e8b22e41987710b2d87061da1821dbe35d19d9`:

- Track E `rustfmt --check`: PASS
- full crate `cargo check`: PASS
- full crate `cargo test`: PASS
- Track E unit tests: 16 passed, 0 failed
- all crate test suites in that run: 91 passed, 0 failed
- GitHub Actions run: `37575658098`

Track E tests cover all required contexts, unsupported destinations with and without alternatives, grouped/combat text, queue-position variants, cooldown blocking and exact-boundary release, recipient independence, competition cooldown, duplicate-text suppression, deterministic explicit time, single-pass template substitution, JSONL escaping, append behavior and bounded rotation.

Full-crate `cargo fmt --check` is intentionally not used as the Track E formatting gate because frozen pre-existing TELE04/05/06/07 baseline files are not rustfmt-clean under the current toolchain. Only Track E source files are formatting-checked; the full crate is still compiled and tested.

Repo-wide feature preflight after adding the required Track E task record also passed:

- coordination SHA: `6e6044980b2a8e7888295c3f0ed39b4e24bf9b4e`
- preflight run: `37575768197`
- auto-integration: intentionally skipped (`auto_integrate=false`)

Existing warnings in frozen TELE06/TELE07/world code remain untouched.

No live WoW whisper test is claimed because Track E deliberately contains no whisper transmission path.

## Integration points for TELE08 master

1. Parser / queue / registry / executor layers should map observed state into typed `ResponseContext` values.
2. The owning scheduler should provide the explicit logical/monotonic `now` value to `handle_context`.
3. The destination registry remains authoritative for currently available alternatives and passes them into Track E. Track E must not synthesize destination availability.
4. A separate sender layer may consume only decisions where `should_send=true` and perform `SendWhisper`/packet I/O. Keep packet transmission outside `tele_response_engine.rs`.
5. Unknown, low-confidence and optionally competition observations should be converted to `UnknownWhisperRecord` and passed to `record_unknown` by the integration layer.
6. Retry/timeout values should be supplied only when the executor has a safe externally meaningful value; otherwise use the generic failure/expiry variants.

## Known limitations

- Not yet wired to the future TELE08 parser/queue/registry/executor integration.
- No actual whisper transmission.
- Cooldown state is process-local and resets on restart.
- Dump write failures are returned to the caller; there is no internal retry queue.
- Rotation keeps one backup generation only.
- There is no multi-process file lock. If multiple processes can dump concurrently, integration should serialize writes or use separate dump paths.
- There is no generic secret scrubber. The schema is intentionally limited to whisper/parser context; callers must not put credentials, tokens or other secrets into optional fields.

## Frozen / non-goals

Track E must remain independent from:

- TELE06 ritual execution
- portal click behavior
- movement logic
- TELE07 supervisor behavior
- WoW packet formatting/transmission

Any future sender integration should be a separate, explicit integration step rather than adding packet I/O to this policy module.
