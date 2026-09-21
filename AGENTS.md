# AGENTS.md — AI AUTOPILOT CONTRACT

This repository is operated primarily by AI agents. The human user should not be expected to browse, edit, merge, hash, package, or maintain repository files manually.

Target is permanently **World of Warcraft 1.12.1 build 5875, Windows x86** unless the user explicitly requests a comparison.

## 1. Mandatory startup sequence

Before editing anything, read in this order:

1. `AGENTS.md`
2. `AI_START_HERE.md`
3. `AI_INDEX.json`
4. `CURRENT.json`
5. `runtime/current.json`
6. only the source/evidence needed for the affected module.

Do not reconstruct current state from chat history, old ZIP names, archives, or historical baselines when current GitHub metadata exists.

## 2. Authority and routing

Authority order:

1. `CURRENT.json` — branch model, stable baseline, canonical pointers.
2. `runtime/current.json` — exact active EXE/DLL identities and source provenance.
3. `src/<Module>/...` — canonical editable source when referenced by runtime metadata.
4. candidate build metadata — exact source/binary built for a work candidate.
5. baseline/manifests — stable rollback identity.
6. `artifacts/` — exact-byte caches, recovery, binary audits, reproducers.
7. archives/history/legacy `source/` — recovery evidence only.

If prose conflicts with machine-readable routing, machine-readable routing wins and the prose must be repaired.

## 3. Branch model

- `main` = last accepted stable state only.
- `work` = active development candidate.
- `promote/**` = temporary curated stable-candidate branches used only for pre-promotion gates.
- Normal edits go to `work`.
- Before a new iteration, current `main` must be an ancestor of `work`.
- Preserve useful unique work state before any branch surgery.
- Never ask the user to merge/rebase/synchronize routine repository state manually.

A stable promotion is **not** `work -> main` wholesale. Curate only accepted changes onto a tree based on current `main`, because `work` may contain unrelated experiments.

## 4. Commit discipline

Prefer the smallest functional change. Preserve unrelated behavior.

When GitHub git-data tools are available, one logical multi-file iteration must be one tree/commit:
`create_blob -> create_tree -> create_commit -> update_ref`.

Avoid one Contents-API commit per file for multi-file changes because it creates duplicate CI runs and weak rollback points.

Do not consume a new Vxx number for every experiment. Stable baseline numbers are rollback points.

## 5. Source rules

`src/` is the only normal editable source root.

When `runtime/current.json` contains `source_path`, edit exactly that lineage. Do not pick source by filename similarity.

Keep provenance explicit:
- original/exact source,
- reconstructed source,
- functionally equivalent reconstruction,
- binary-patch lineage,
- exact archived/recoverable source.

Never relabel reconstruction as original source.

For source-only experiments on `work`, source promotion fingerprints may intentionally lag. Candidate build metadata records the exact source compiled. Before stable promotion they must be synchronized.

## 6. Normal TEST iteration

1. Verify `main` is an ancestor of `work`.
2. Route through `runtime/current.json`.
3. Make the smallest change.
4. Run `python tools/verify_current.py`.
5. Commit the complete logical iteration to `work`.
6. Let `.github/workflows/build_work_candidate.yml` build/package the candidate.
7. The workflow must finish with `tools/verify_candidate_package.py`.
8. Only a final package with `FINAL_PACKAGE: PASS` is eligible for user testing.
9. The user tests in game and reports the result.

A failed build or final package gate must not publish a runnable candidate.

## 7. Stable promotion protocol — mandatory

Because repository branch protection may be unavailable, stable promotion is guarded by an explicit pre-promotion workflow.

For every accepted stable promotion:

1. Start from the current `main` commit.
2. Curate only accepted source/runtime/baseline/infrastructure changes into a stable tree.
3. Set stable metadata consistently (`CURRENT.json`, `runtime/current.json`, baseline, manifests, provenance).
4. Run/synchronize source promotion fingerprints.
5. Create/update a temporary branch named `promote/<purpose>`.
6. Wait for `.github/workflows/pre_promote_stable.yml` on the **exact promotion SHA**.
7. Require that workflow to PASS:
   - source fingerprint check,
   - `verify_current.py`,
   - `verify_runtime_artifacts.py`,
   - verified-symbol registry check when present,
   - `verify_repo.py`,
   - exact-byte stable packaging,
   - final package verification.
8. Only after PASS may AI move `main` to that same verified SHA.
9. Confirm the `Build stable candidate` workflow on `main` also passes.
10. Re-integrate the new `main` into `work` without destroying unrelated work-only experiments.

**Never move `main` first and rely on post-push CI to discover whether the promotion was valid.**

## 8. Exact-byte STABLE rule

TEST candidates may be compiled from source.

STABLE packages must represent the **exact accepted runtime bytes**, not a fresh recompilation. Stable packaging uses:

```text
python tools/package_exact_current.py
python tools/verify_candidate_package.py --finalize ...
```

For every active stable DLL there must be an exact XZ artifact either:
- explicitly referenced by `binary_artifact`, or
- present in the content-addressed cache as
  `artifacts/runtime_cache/<runtime-sha256>.dll.xz`.

The packager must decompress and verify SHA256 + size against `runtime/current.json`. If any exact artifact is missing, promotion fails closed.

## 9. Verification levels

Routine iteration:

```text
python tools/verify_current.py
python tools/verify_runtime_artifacts.py
python tools/verify_verified_symbols.py
```

Promotion:

```text
python tools/sync_source_metadata.py --check
python tools/verify_current.py
python tools/verify_runtime_artifacts.py
python tools/verify_verified_symbols.py
python tools/verify_repo.py
```

Package gate:

```text
python tools/verify_candidate_package.py --finalize ...
```

Do not weaken verifiers to make CI green. Fix the underlying inconsistency.

## 10. Packaging

A runnable ZIP containing WoW must keep the active EXE in ZIP root beside all DLLs and `dlls.txt`.

`dlls.txt` must exactly match the final root DLL set and order.

The final package verifier is authoritative for:
- root-only layout,
- one EXE,
- DLL set,
- `dlls.txt`,
- PE32 x86 machine,
- nonzero entrypoints,
- package SHA256/size,
- candidate extra-module metadata.

Updater/other delivery tooling must consume only successful workflow artifacts and verify the inner package SHA before installation.

## 11. Repository hygiene

Do not commit generated `build/`, `dist/`, runtime debug logs/dumps, `.wow112_debug`, or updater local state.

Historical material stays out of the normal read path. Prefer deterministic scripts and machine-readable metadata over duplicated prose.

## 12. Communication

After a change report briefly:
- what changed,
- which module/infrastructure surface changed,
- verification/CI result,
- branch state (`work` only vs `main`),
- what the user needs to test, if anything.

The user should mainly describe desired behavior and perform in-game tests. AI owns GitHub housekeeping.

## 13. Definition of done

Experimental candidate:
- change committed atomically to `work`,
- `verify_current.py` passes,
- relevant x86 build passes,
- final package gate passes,
- runnable artifact exists when needed,
- rollback remains possible.

Stable release:
- user accepted the behavior or explicitly requested promotion,
- curated `promote/**` SHA is based on current `main`,
- strict source metadata and deep verification pass,
- exact-byte runtime recovery is complete,
- pre-promotion workflow passes on the exact SHA,
- `main` is moved only afterward,
- stable artifact workflow passes,
- `work` receives new `main` without losing unrelated experiments.

## 14. Resumable AI sessions and interrupted message streams

A ChatGPT message-stream failure is **not evidence** that a GitHub write, build, or package failed. Repository instructions cannot prevent client/network/service streaming failures; they must prevent ambiguous or duplicated repository operations after such failures.

### Branch routing

- Follow an explicitly requested existing development branch. User spelling `pararell` means the existing branch `parallel`; verify its exact name from GitHub before writing.
- `work` remains the default only when the user did not select another development branch. Do not silently redirect a `parallel` task to `work` because generic `CURRENT.json` or `AI_INDEX.json` metadata still says `work`.
- Stable `main` remains immutable during an unaccepted experiment. Preserve unrelated branch changes and the ancestry/verification requirements.

### Short, durable transaction boundaries

- Read the mandatory five entrypoint files in order, then fetch only the affected module and minimal relevant workflow data. Prefer bounded file slices and compact summaries of CI/API results; never dump an entire workflow-run collection or large source tree into the conversation without a specific need.
- Before each write, identify target branch, current branch HEAD, affected paths, and whether the intended change is already present. One logical change uses one commit, with a descriptive message and no unrelated file edits.
- After the GitHub write, confirm the resulting branch HEAD/commit before moving on. Then inspect the workflow for **that exact SHA** and verify the final candidate/artifact as required; distinguish `queued`, `running`, `failed`, `passed`, and `not checked`. Never declare success or offer a runnable build merely because a write was attempted.
- Report a compact durable checkpoint after a confirmed operation when useful: branch, short commit SHA, what changed, verification/build status, and artifact link only if verified. Do not paste large logs unless diagnosing a failure.

### Recovery after stream errors, timeouts or unknown tool results

1. Re-read the latest HEAD of the selected branch and the recent commits for the relevant paths; compare with the previously observed SHA and intended edit.
2. Query GitHub Actions for the exact resulting SHA, including run conclusion and uploaded artifacts if applicable. A passing run from an older SHA is not proof for the current HEAD.
3. If a commit exists, resume from its verified state; **do not replay** the same write or build solely because ChatGPT's response vanished.
4. If the write is absent, re-read the current file SHA/HEAD, reconcile intervening changes, then apply only the missing change. Never force-update a branch or overwrite a file using a stale SHA.
5. If the last operation is genuinely unknowable, state that explicitly, preserve evidence, and do not claim the task completed. Restart from the smallest independently verifiable step.

Keep ChatGPT transport troubleshooting separate from repository correctness. For repeated UI failures, use a new short conversation and compare browser/network conditions; these measures cannot guarantee a stream will never fail.
