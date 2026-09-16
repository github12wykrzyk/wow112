# `src/` — canonical editable source root

For AI-assisted development, start here **only after** reading `runtime/current.json`.

Rules:

- An active module's `source_path` in `runtime/current.json` is authoritative.
- A module directory may also contain reconstructed source, recovery notes or historical evidence; similar filenames do not make those files canonical.
- Original source and reconstructed source must remain clearly distinguished.
- New canonical editable sources should be placed under `src/<Module>/`.
- Historical ancestors belong under `src/history/` or recovery artifacts, not beside an active canonical file unless they are explicitly labeled.
- Do not infer active runtime behavior from source alone; match the runtime DLL entry and provenance metadata.

For a compact active-module map, run:

```text
python tools/ai_status.py
```
