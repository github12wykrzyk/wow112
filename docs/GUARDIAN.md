# WoW112 Guardian

The workflow runs at minute 17 of every UTC hour, subject to GitHub Actions scheduler delays. It must be installed on the default branch main to run hourly. It may also be run manually using workflow_dispatch.

The auditor checks the current main/work/parallel SHA, each branch's CURRENT.json and runtime/current.json, ordered active DLL manifest, exact-SHA workflow failures, duplicate DLLs, shared canonical source paths and work ancestry. It upserts a single tracking issue and uploads machine-readable JSON evidence. This bounded audit cannot establish actual in-game safety or detect every hook collision.

Without an OPENAI_API_KEY repository Actions secret, audit-only mode is active. When the key is set, at most one minimal model-proposed repair is attempted each run, only on a failing work/parallel HEAD whose last commit modified exactly one currently active C source file. Source and logs are treated as untrusted data. There are strict unique-replacement, size, line-count and hook/address guards; no model-generated workflow, verifier, runtime manifest or metadata edits are permitted.

The proposal is committed to a short-lived feature/guardian-<branch>-<sha> branch and opened as a draft pull request to its originating development branch. No automatic merge, main change, promotion or gameplay claim occurs. A separate explicitly dispatched exact-SHA Windows candidate gate runs repository verification, native build and final package verification. Only diagnostic metadata, never an unaccepted playable ZIP, is uploaded by that gate. An in-game test is still required before any promotion or merge.

The external OpenAI API key is separately billed and is not included in a ChatGPT subscription. Configure the Actions secret OPENAI_API_KEY to enable code proposals; remove it to revert to audit-only mode. GitHub repository Actions settings must allow GitHub Actions to create pull requests. If a create-PR permission is disallowed, audits continue and the repair status records the problem. Scheduled jobs may be delayed or omitted by GitHub. GITHUB_TOKEN-created ordinary push events do not trigger follow-on builds; the gate uses workflow_dispatch instead.

The Guardian report is evidence tied to a particular branch SHA, not an attestation that a source patch runs in WoW 1.12.1 build 5875 x86. Review draft PRs and candidate gate results before integration.
