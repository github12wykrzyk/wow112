#!/usr/bin/env python3
"""Windows synthetic smoke for summon/payment telemetry over Operator Bridge v1.

Not a gameplay test. It validates read-only decoding of canonical SummonScout
telemetry kinds 4..9, trusted-payment metadata, source timestamps and dedupe.
"""
import argparse
import json
import mmap
import os
from pathlib import Path
import shutil
import struct
import subprocess
import time

MAGIC = 0x4F323157
VERSION = 1
HEADER = 556
SLOT = 896
RING = 16
MAP_SIZE = HEADER + SLOT * RING
OFF_WORLD_READY = 16
OFF_EVENT_SEQ = 20
OFF_EVENT_DROPPED = 24


def put_u32(mm, off, value):
    struct.pack_into('<I', mm, off, int(value) & 0xFFFFFFFF)


def put_text(mm, off, cap, value):
    raw = (value or '').encode('utf-8')
    if len(raw) >= cap:
        raise ValueError(f'field too long for {cap}: {value!r}')
    mm[off:off + cap] = raw + b'\0' * (cap - len(raw))


def write_event(mm, seq, kind, player, text, result='', destination='', intent='', keywords='', source_unix='', reason='', correlation='', character='SmokeSummoner'):
    slot = HEADER + ((seq - 1) % RING) * SLOT
    put_u32(mm, slot + 0, 0)
    put_u32(mm, slot + 4, kind)
    put_u32(mm, slot + 8, 0)
    put_u32(mm, slot + 12, 0)
    put_text(mm, slot + 16, 64, character)
    put_text(mm, slot + 80, 64, player)
    put_text(mm, slot + 144, 256, text)
    put_text(mm, slot + 400, 32, result)
    put_text(mm, slot + 432, 32, destination)
    put_text(mm, slot + 464, 32, intent)
    put_text(mm, slot + 496, 96, keywords)
    put_text(mm, slot + 592, 96, source_unix)
    put_text(mm, slot + 688, 144, reason)
    put_text(mm, slot + 832, 64, correlation)
    put_u32(mm, slot + 0, seq)
    put_u32(mm, OFF_EVENT_SEQ, seq)
    mm.flush()


def load_jsonl(path):
    if not path.exists():
        return []
    rows = []
    with path.open('r', encoding='utf-8', errors='strict') as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                rows.append(json.loads(line))
            except json.JSONDecodeError:
                pass
    return rows


def matching(path, event_type, correlation=None):
    out = []
    for row in load_jsonl(path):
        if row.get('EventType') != event_type:
            continue
        if correlation is not None and row.get('CorrelationId') != correlation:
            continue
        out.append(row)
    return out


def wait_for(fn, label, timeout=20.0):
    deadline = time.time() + timeout
    last = None
    while time.time() < deadline:
        last = fn()
        if last:
            return last
        time.sleep(0.05)
    raise RuntimeError(f'timeout waiting for {label}; last={last!r}')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--exe', required=True)
    args = ap.parse_args()
    if os.name != 'nt':
        raise SystemExit('summon_telemetry_smoke.py requires Windows named mappings')

    exe = Path(args.exe).resolve()
    local_appdata = Path(os.environ['LOCALAPPDATA']).resolve()
    root = local_appdata / 'WoW112' / 'OperatorConsole'
    shutil.rmtree(root, ignore_errors=True)
    bridge = root / 'bridge'
    bridge.mkdir(parents=True, exist_ok=True)
    backend = bridge / 'backend-events.jsonl'

    pid = os.getpid()
    tag = f'Local\\WoW112_OperatorBridge_{pid}'
    mm = mmap.mmap(-1, MAP_SIZE, tagname=tag, access=mmap.ACCESS_WRITE)
    proc = None
    try:
        mm[:] = b'\0' * MAP_SIZE
        put_u32(mm, 0, MAGIC)
        put_u32(mm, 4, VERSION)
        put_u32(mm, 8, pid)
        put_u32(mm, 12, 1)
        put_u32(mm, OFF_WORLD_READY, 1)
        put_u32(mm, OFF_EVENT_DROPPED, 0)

        proc = subprocess.Popen([str(exe)])
        time.sleep(0.8)
        ts = int(time.time()) - 3600
        write_event(mm, 1, 4, 'ClientOne', 'Summon queued: ClientOne -> Mount Hyjal', 'queued', 'Mount Hyjal', 'summon', '41', str(ts), 'canonical summonPending', 'summon:101')
        write_event(mm, 2, 5, 'ClientOne', 'Summon started: ClientOne -> Mount Hyjal', 'started', 'Mount Hyjal', 'summon', '41', str(ts + 2), 'canonical summonActiveStarted', 'summon:102')
        write_event(mm, 3, 6, 'ClientOne', 'Summon completed: ClientOne -> Mount Hyjal', 'completed', 'Mount Hyjal', 'summon', '41', str(ts + 12), 'canonical active summon completed', 'summon:103')
        write_event(mm, 4, 8, 'ClientOne', 'Payment received: ClientOne -> 40000 copper', 'paid', 'Mount Hyjal', 'payment', '40000', str(ts + 20), 'trusted SummonScoutDB.paymentLog', 'payment:77')
        write_event(mm, 5, 7, 'ClientTwo', 'Summon failed: ClientTwo -> Winterspring', 'failed', 'Winterspring', 'summon', '42', str(ts + 25), 'left party/raid before cast', 'summon:104')
        write_event(mm, 6, 9, 'ClientThree', 'manual reply', 'uncertain', '', 'manual', '', str(ts + 30), 'no CHAT_MSG_WHISPER_INFORM within 30s; no automatic retry', 'manual:uncertain:1')

        queued = wait_for(lambda: matching(backend, 'SummonQueued', 'summon:101'), 'SummonQueued')[0]
        started = wait_for(lambda: matching(backend, 'SummonStarted', 'summon:102'), 'SummonStarted')[0]
        completed = wait_for(lambda: matching(backend, 'SummonCompleted', 'summon:103'), 'SummonCompleted')[0]
        expected = wait_for(lambda: matching(backend, 'PaymentExpected', 'summon:103:payment'), 'PaymentExpected')[0]
        paid = wait_for(lambda: matching(backend, 'PaymentReceived', 'payment:77'), 'PaymentReceived')[0]
        failed = wait_for(lambda: matching(backend, 'SummonFailed', 'summon:104'), 'SummonFailed')[0]
        uncertain = wait_for(lambda: matching(backend, 'WhisperSendUncertain', 'manual:uncertain:1'), 'WhisperSendUncertain')[0]

        if (queued.get('Metadata') or {}).get('destination') != 'Mount Hyjal':
            raise RuntimeError('queued destination lost')
        if (started.get('Metadata') or {}).get('request_seq') != '41':
            raise RuntimeError('summon request sequence lost')
        if (paid.get('Metadata') or {}).get('copper') != 40000:
            raise RuntimeError('payment copper lost')
        if (paid.get('Metadata') or {}).get('trusted_ledger') is not True:
            raise RuntimeError('payment is not marked trusted-ledger')
        if (paid.get('Metadata') or {}).get('source_unix') != ts + 20:
            raise RuntimeError('historical payment source timestamp lost')
        if failed.get('Severity') != 3:
            raise RuntimeError('SummonFailed must be WARN')
        if uncertain.get('Severity') != 3:
            raise RuntimeError('WhisperSendUncertain must be WARN')
        if expected.get('Metadata', {}).get('player') != 'ClientOne':
            raise RuntimeError('PaymentExpected player correlation lost')
        if completed.get('Metadata', {}).get('player') != 'ClientOne':
            raise RuntimeError('SummonCompleted player correlation lost')

        # Replay the same durable payment correlation at a new ring sequence.
        write_event(mm, 7, 8, 'ClientOne', 'Payment received replay', 'paid', 'Mount Hyjal', 'payment', '40000', str(ts + 20), 'trusted SummonScoutDB.paymentLog', 'payment:77')
        time.sleep(0.5)
        if len(matching(backend, 'PaymentReceived', 'payment:77')) != 1:
            raise RuntimeError('durable payment dedupe failed')

        print('SUMMON TELEMETRY IPC SMOKE PASS')
        print('summon_queued=PASS')
        print('summon_started=PASS')
        print('summon_completed=PASS')
        print('payment_expected=PASS')
        print('trusted_payment_history=PASS')
        print('summon_failed=PASS')
        print('whisper_uncertain_no_retry=PASS')
        print('durable_payment_dedupe=PASS')
        return 0
    except Exception:
        print('--- backend-events tail ---')
        for row in load_jsonl(backend)[-20:]:
            print(json.dumps(row, ensure_ascii=False, sort_keys=True))
        raise
    finally:
        if proc is not None:
            try:
                proc.terminate()
                proc.wait(timeout=5)
            except Exception:
                try:
                    proc.kill()
                except Exception:
                    pass
        mm.close()
        shutil.rmtree(root, ignore_errors=True)


if __name__ == '__main__':
    raise SystemExit(main())
