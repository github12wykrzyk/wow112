# Development workflow

The authoritative repository contract is `AGENTS.md`. For branch routing, experiments, module dependencies, and stream recovery see `docs/AI_EXPERIMENTS.md`; for candidate and stable gates see `docs/AI_ITERATION_WORKFLOW.md`.

## Branches and experiments

`main` is accepted stable state; `work` is the existing development line; `parallel` is the independent alternative. The active runtime and canonical source of **each branch** come from that branch's `CURRENT.json` and `runtime/current.json`. Respect a user-selected branch. Otherwise inspect the active experiment ledger and live GitHub commits and follow the correct experiment; create a temporary `feature/<purpose>` from a verified relevant base for independent changes. Do not create branches per DLL, move unaccepted experiments between branches, or require existing parallel to be made an ancestor/descendant of work.

The ledger `runtime/ai_experiments.json` records declared experiments and exact-commit evidence; live GitHub HEAD and runtime metadata remain authoritative. Consult branch-specific hook/ABI/dependency registries and test shared hook ownership, DLL loader order and binary/source provenance before combining modules.

## Candidate verification

Before each write check the selected branch HEAD and target files; commit the smallest coherent iteration. Run `python tools/verify_current.py`, `python tools/verify_runtime_artifacts.py`, `python tools/verify_verified_symbols.py`, relevant module tests and the configured branch-specific x86 build workflow when binaries are affected. The `ai_experiments.yml` workflow validates metadata and routing only; it is not a replacement for native compilation or `verify_candidate_package.py --finalize`. Only a confirmed exact-SHA package with `FINAL_PACKAGE: PASS` may be offered as runnable. Game-test results must identify the tested commit and artifact.

## Curated stable promotion

Do not promote the whole work/parallel branch after one accepted feature. Curate only accepted changes and required dependencies on a fresh tree based on the current main, preserving the previous rollback baseline. Synchronize source fingerprints and stable metadata, run `verify_current.py`, `verify_runtime_artifacts.py`, `verify_verified_symbols.py`, `verify_repo.py` and exact-byte stable packaging, then require `Pre-promote stable` PASS on the exact promotion SHA. Only afterwards move main to the **same** verified SHA and require stable package verification. Synchronize resulting accepted changes into development branches selectively, without discarding their unique experiments. Infrastructure-only edits do not consume Vxx or change game runtime binaries.

## Interrupted sessions

Check live branch HEAD, affected files and Actions for the exact commit before attempting another write. A ChatGPT stream failure does not show whether the GitHub operation landed. Never force-push, reset unique changes, replay an uncertain commit blindly, or claim success from a different SHA.

## Source and binary identity

`src/` is the normal editable source root, and a declared `source_path` in branch runtime metadata is authoritative. Historical `source/`, `archives/` and `src/history/` are for recovery, not guessed replacements. Preserve provenance of original and reconstructed code. Stable packages must use exact accepted EXE/DLL bytes and retain manifest and SHA256 identity; rebuilding from source is a test-candidate operation, not a stable rollback substitute.
