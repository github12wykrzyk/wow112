from pathlib import Path

path = Path("probes/Wow112HeadlessAndroid/src/bin/tele08_e_live_runtime.rs")
text = path.read_text(encoding="utf-8")
old = '    use crate::tele08_whisper_parser::{ParserConfig, WhisperObservation};\n'
new = (
    '    use wow112_headless_android_probe::tele08_e_live_logic::LiveResponseLogic;\n'
    '    use wow112_headless_android_probe::tele08_whisper_parser::{ParserConfig, WhisperObservation};\n'
)
count = text.count(old)
if count != 1:
    raise SystemExit(f"IMPORT FIX FAIL: expected 1 inner parser import, got {count}")
text = text.replace(old, new, 1)
path.write_text(text, encoding="utf-8")
print("IMPORT FIX COMPLETE")
