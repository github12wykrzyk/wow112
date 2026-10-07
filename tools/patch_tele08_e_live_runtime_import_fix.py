from pathlib import Path

path = Path("probes/Wow112HeadlessAndroid/src/bin/tele08_e_live_runtime.rs")
text = path.read_text(encoding="utf-8")

inner_old = '    use crate::tele08_whisper_parser::{ParserConfig, WhisperObservation};\n'
inner_new = (
    '    use wow112_headless_android_probe::tele08_e_live_logic::LiveResponseLogic;\n'
    '    use wow112_headless_android_probe::tele08_whisper_parser::{ParserConfig, WhisperObservation};\n'
)
count = text.count(inner_old)
if count != 1:
    raise SystemExit(f"IMPORT FIX FAIL: expected 1 inner parser import, got {count}")
text = text.replace(inner_old, inner_new, 1)

root_live_logic = 'use wow112_headless_android_probe::tele08_e_live_logic::LiveResponseLogic;\n'
count = text.count(root_live_logic)
if count != 1:
    raise SystemExit(f"IMPORT FIX FAIL: expected 1 root live logic import, got {count}")
text = text.replace(root_live_logic, '', 1)

old_call = 'tele08_whisper_parser::classify_whisper(&observation, &ParserConfig::default())'
new_call = (
    'wow112_headless_android_probe::tele08_whisper_parser::classify_whisper('
    '&observation, &ParserConfig::default())'
)
count = text.count(old_call)
if count != 1:
    raise SystemExit(f"IMPORT FIX FAIL: expected 1 root classify call, got {count}")
text = text.replace(old_call, new_call, 1)

path.write_text(text, encoding="utf-8")
print("IMPORT FIX COMPLETE")
