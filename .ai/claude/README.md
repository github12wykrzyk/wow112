# Claude Specialist Bridge

This repository exposes a budgeted, read-only Claude Code specialist for the primary ChatGPT/GPT engineering workflow.

## Durable invocation path for ChatGPT conversations

The workflow lives on canonical `main` at `.github/workflows/claude-specialist.yml`.

Because the ChatGPT GitHub connector may not expose GitHub Actions `workflow_dispatch`, autonomous chats invoke Claude by updating `.ai/claude/request.json` on the persistent branch `claude-requests`.

For each invocation:

1. Read the current request file on `claude-requests` to obtain its blob SHA.
2. Replace it with a new request using a unique `request_id`, set `enabled` to `true`, select `target_ref`, select `tier`, and provide one bounded `task`.
3. The push triggers `Claude Specialist` automatically.
4. Poll only the resulting top-level Claude Specialist run when needed; do not inspect successful logs unless the report itself is required.
5. Fetch the `claude-specialist-*` artifact and consume `claude-specialist-report.md` plus metadata.

Example request:

```json
{
  "enabled": true,
  "request_id": "ah-race-review-20261007-01",
  "target_ref": "feature/ah-auction-lifecycle-v1",
  "tier": "cheap",
  "task": "Review only the mutation coordinator for races between BUY, MAIL, CANCEL and POST. Return exact evidence and a minimal recommendation."
}
```

## Cost policy

- `cheap` (default): Haiku, max 2 turns, per-run cap $0.15, compact report.
- `normal`: Sonnet, max 3 turns, per-run cap $0.35.
- `deep`: Sonnet, max 5 turns, per-run cap $0.75.
- No Opus.
- No automatic cheap -> normal -> deep escalation.
- No Claude subagents.
- No automatic retry after a failed or uncertain Claude run.
- Use `normal` or `deep` only when the primary agent has a concrete reason that justifies the extra Claude budget.

## Safety

Claude is read-only. The workflow records repository state before Claude and fails closed if repository state changes afterward. The OAuth token is read only from the GitHub Actions secret `CLAUDE_CODE_OAUTH_TOKEN` and is never printed.

The disabled request template on `main` exists only so a new/recreated `claude-requests` branch can inherit a safe non-consuming starting state.
