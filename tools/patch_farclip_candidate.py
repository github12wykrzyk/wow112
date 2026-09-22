#!/usr/bin/env python3
"""Fail-closed 5875 x86 farclip TEST-only patch for the complete candidate ZIP.

Source: brndd/vanilla-tweaks src/main.rs, FARCLIP_OFFSET=0x40FED8.
Do not patch the canonical/stable EXE or apply vanilla-tweaks' unrelated edits.
"""
import argparse
import json
import struct
from pathlib import Path

from verify_candidate_package import deterministic_repack, read_zip, sha256_bytes, sha256_file

ROOT = Path(__file__).resolve().parents[1]
OFFSET = 0x40FED8
OLD = struct.pack('<f', 777.0)
NEW = struct.pack('<f', 1554.0)
SOURCE = 'https://github.com/brndd/vanilla-tweaks/blob/master/src/main.rs'


def patch_bytes(original, expected_hash):
    if sha256_bytes(original) != expected_hash:
        raise SystemExit('farclip: candidate EXE SHA256 differs from canonical runtime EXE')
    if len(original) <= OFFSET + len(OLD):
        raise SystemExit('farclip: candidate EXE is too small')
    if original[OFFSET:OFFSET + 4] != OLD:
        raise SystemExit('farclip: 5875 expected 777.0f at 0x40FED8; refusing unknown bytes')
    patched = original[:OFFSET] + NEW + original[OFFSET + 4:]
    if (len(patched) != len(original)
            or patched[:OFFSET] != original[:OFFSET]
            or patched[OFFSET + 4:] != original[OFFSET + 4:]
            or struct.unpack_from('<f', patched, OFFSET)[0] != 1554.0):
        raise SystemExit('farclip: exact four-byte patch verification failed')
    return patched


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--package', required=True)
    parser.add_argument('--metadata', required=True)
    parser.add_argument('--summary', required=True)
    parser.add_argument('--report', required=True)
    args = parser.parse_args()

    runtime = json.loads((ROOT / 'runtime/current.json').read_text(encoding='utf-8'))
    package, metadata_path, summary_path = [Path(v) for v in (args.package, args.metadata, args.summary)]
    meta = json.loads(metadata_path.read_text(encoding='utf-8'))
    summary = json.loads(summary_path.read_text(encoding='utf-8'))
    exe_name = runtime['exe']['name']
    stable_hash = runtime['exe']['sha256'].lower()
    if meta.get('exe', {}).get('name') != exe_name or meta['exe'].get('sha256') != stable_hash:
        raise SystemExit('farclip: candidate EXE metadata does not match canonical runtime')
    if meta.get('git_head') != summary.get('head'):
        raise SystemExit('farclip: candidate branch commit mismatch')
    rows = read_zip(package)
    if sum(name.lower().endswith('.exe') for name, _ in rows) != 1:
        raise SystemExit('farclip: expected exactly one root EXE')
    originals = dict(rows)
    if exe_name not in originals:
        raise SystemExit('farclip: canonical EXE name absent from candidate ZIP')
    new_exe = patch_bytes(originals[exe_name], stable_hash)
    new_rows = [(name, new_exe if name == exe_name else data) for name, data in rows]
    deterministic_repack(package, new_rows)
    actual = dict(read_zip(package))
    if actual != dict(new_rows):
        raise SystemExit('farclip: ZIP round-trip changed unrelated entries')
    patched_hash = sha256_bytes(actual[exe_name])
    patch = {
        'source': SOURCE,
        'source_build': 'WoW 1.12.1 build 5875, Windows x86',
        'offset_hex': hex(OFFSET),
        'original_float': 777.0,
        'patched_float': 1554.0,
        'original_hex': OLD.hex(),
        'patched_hex': NEW.hex(),
        'stable_exe_sha256': stable_hash,
        'candidate_exe_sha256': patched_hash,
        'changed_binary_bytes': sum(a != b for a, b in zip(OLD, NEW)),
        'game_runtime_tested': False,
    }
    # Only the test ZIP's EXE identity changes; stable manifest and on-disk EXE remain exact.
    meta['exe'].update(sha256=patched_hash, size=len(new_exe),
                       source_kind='candidate_farclip_patch', stable_current_sha256=stable_hash)
    meta['exe_farclip_patch'] = patch
    summary['exe_farclip_patch'] = patch
    for obj in (meta, summary):
        obj['package_sha256'] = sha256_file(package)
        obj['package_size'] = package.stat().st_size
    metadata_path.write_text(json.dumps(meta, indent=2) + '\n', encoding='utf-8')
    summary_path.write_text(json.dumps(summary, indent=2) + '\n', encoding='utf-8')
    report_path = Path(args.report)
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(json.dumps({'result': 'PASS', **patch}, indent=2) + '\n', encoding='utf-8')
    print('FARCLIP_CANDIDATE: PASS 777 -> 1554, SHA256=' + patched_hash)


if __name__ == '__main__':
    main()
