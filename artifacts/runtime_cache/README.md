# Runtime binary cache

This directory is the normal exact-byte recovery path for DLLs listed in `runtime/current.json`.

Each active DLL has a `binary_artifact` entry pointing to a content-addressed XZ file:

`artifacts/runtime_cache/<runtime-sha256>.dll.xz`

Rules:

- the decompressed bytes MUST match the DLL `sha256` in `runtime/current.json`;
- `binary_artifact.size` is the decompressed DLL size;
- these files are runtime recovery artifacts, not source code and not evidence of source originality;
- source provenance remains defined by `source_state`, `source_origin`, `source_path`, recovery docs and binary audits;
- `tools/verify_runtime_artifacts.py` verifies every cached DLL byte-for-byte;
- `tools/package_current.py` uses this cache for unchanged DLLs and validates every restored hash;
- a freshly built candidate may be supplied to `package_current.py` with `--override NAME=PATH`;
- before a candidate becomes a stable baseline, its exact accepted DLL should have a matching cache artifact.

The current cache was populated from the hash-verified GitHub Actions smoke-test package and each decompressed DLL was rechecked against `runtime/current.json`.

Legacy V67/V68 recovery chunks and binary reproducers remain valuable provenance/rollback evidence, but normal packaging should not need to scan them or fetch Git history.
