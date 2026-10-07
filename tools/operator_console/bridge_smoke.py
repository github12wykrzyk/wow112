#!/usr/bin/env python3
"""Windows-only synthetic IPC roundtrip for Operator Console V1.

This is intentionally NOT a gameplay test. It validates the exact named-mapping
wire contract used between the x64 console and the x86 WoW transport: map-first
PID discovery, incoming whisper projection, typed manual command dispatch,
backend ACK, and final WhisperSent event confirmation.
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
OFF_COMMAND_SEQ = 28
OFF_COMMAND_ACK = 32
OFF_COMMAND_STATUS = 36
OFF_COMMAND_KIND = 40
OFF_COMMAND_PLAYER = 44
OFF_COMMAND_TEXT = 108
OFF_COMMAND_CORR = 364
OFF_COMMAND_ERROR = 428

CMD_ACCEPTED = 2


def u32(mm, off):
    return struct.unpack_from('<I', mm, off)[0]


def put_u32(mm, off, value):
    struct.pack_into('<I', mm, off, int(value) & 0xFFFFFFFF)


def put_text(mm, off, cap, value):
    raw = (value or '').encode('utf-8')
    if len(raw) >= cap:
        raise ValueError(f'field too long for {cap}: {value!r}')
    mm[off:off+cap] = raw + b'\0' * (cap - len(raw))


def get_text(mm, off, cap):
    raw = bytes(mm[off:off+cap])
    return raw.split(b'\0', 1)[0].decode('utf-8', errors='strict')


def write_event(mm, seq, kind, character, player, text, result='', destination='', intent='', reason='', correlation='', flags=0, confidence=0):
    slot = HEADER + ((seq - 1) % RING) * SLOT
    put_u32(mm, slot + 0, 0)  # commit-last
    put_u32(mm, slot + 4, kind)
    put_u32(mm, slot + 8, confidence)
    put_u32(mm, slot + 12, flags)
    put_text(mm, slot + 16, 64, character)
    put_text(mm, slot + 80, 64, player)
    put_text(mm, slot + 144, 256, text)
    put_text(mm, slot + 400, 32, result)
    put_text(mm, slot + 432, 32, destination)
    put_text(mm, slot + 464, 32, intent)
    put_text(mm, slot + 496, 96, '')
    put_text(mm, slot + 592, 96, '')
    put_text(mm, slot + 688, 144, reason)
    put_text(mm, slot + 832, 64, correlation)
    put_u32(mm, slot + 0, seq)
    put_u32(mm, OFF_EVENT_SEQ, seq)
    mm.flush()


def wait_for(predicate, timeout=20.0, interval=0.05, label='condition'):
    deadline = time.time() + timeout
    last = None
    while time.time() < deadline:
        try:
            last = predicate()
            if last:
                return last
        except (FileNotFoundError, PermissionError, json.JSONDecodeError, UnicodeDecodeError):
            pass
        time.sleep(interval)
    raise RuntimeError(f'timeout waiting for {label}; last={last!r}')


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
                continue
    return rows


def has_event(path, event_type, message=None, correlation=None):
    for row in load_jsonl(path):
        if row.get('EventType') != event_type:
            continue
        if message is not None and row.get('Message') != message:
            continue
        if correlation is not None and row.get('CorrelationId') != correlation:
            continue
        return row
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--exe', required=True)
    ap.add_argument('--keep-temp', action='store_true')
    args = ap.parse_args()

    if os.name != 'nt':
        raise SystemExit('bridge_smoke.py requires Windows named mappings')

    exe = Path(args.exe).resolve()
    if not exe.is_file():
        raise SystemExit(f'console exe missing: {exe}')

    # Environment.GetFolderPath(LocalApplicationData) is a Windows known-folder
    # lookup, not an arbitrary LOCALAPPDATA override. Use the runner's real known
    # folder so the smoke observes the same files as the .NET console.
    local_appdata = Path(os.environ['LOCALAPPDATA']).resolve()
    operator_root = local_appdata / 'WoW112' / 'OperatorConsole'
    shutil.rmtree(operator_root, ignore_errors=True)
    bridge_dir = operator_root / 'bridge'
    bridge_dir.mkdir(parents=True, exist_ok=True)
    backend = bridge_dir / 'backend-events.jsonl'
    commands = bridge_dir / 'operator-commands.jsonl'

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

        # Seed a real wire-level incoming event before console discovery.
        write_event(
            mm, 1, 1, 'SmokeChar', 'SmokePeer', 'need hyjal',
            result='accepted', destination='hyjal', intent='summon_request',
            reason='synthetic-wire-smoke', flags=2, confidence=900,
        )

        proc = subprocess.Popen([str(exe)])

        incoming = wait_for(
            lambda: has_event(backend, 'WhisperReceived', message='need hyjal'),
            label='WhisperReceived from named mapping',
        )
        if incoming.get('SessionId') != f'wow-pid-{pid}':
            raise RuntimeError(f'wrong map-first session binding: {incoming}')
        parser = (incoming.get('Metadata') or {}).get('parser') or {}
        if parser.get('result') != 'accepted' or parser.get('destination') != 'hyjal':
            raise RuntimeError(f'parser diagnostic wire fields lost: {parser}')

        correlation = 'smoke-correlation-v1'
        command = {
            'SchemaVersion': '1',
            'CommandId': 'smoke-command-v1',
            'Account': '',
            'Profile': '',
            'Character': 'SmokeChar',
            'SessionId': f'wow-pid-{pid}',
            'Player': 'SmokePeer',
            'Text': 'manual smoke reply',
            'CorrelationId': correlation,
            'TimestampUtc': '/Date(0)/',
            'CommandType': 1,
        }
        with commands.open('a', encoding='utf-8', newline='') as fh:
            fh.write(json.dumps(command, separators=(',', ':')) + '\n')
            fh.flush()

        seq = wait_for(lambda: u32(mm, OFF_COMMAND_SEQ) or 0, label='native command_seq')
        if u32(mm, OFF_COMMAND_KIND) != 1:
            raise RuntimeError('console emitted non-whisper native opcode')
        if get_text(mm, OFF_COMMAND_PLAYER, 64) != 'SmokePeer':
            raise RuntimeError('native player routing mismatch')
        if get_text(mm, OFF_COMMAND_TEXT, 256) != 'manual smoke reply':
            raise RuntimeError('native whisper text mismatch')
        if get_text(mm, OFF_COMMAND_CORR, 64) != correlation:
            raise RuntimeError('native correlation mismatch')

        # Simulate the x86/Lua dispatch ACK. This is accepted, not yet sent.
        put_text(mm, OFF_COMMAND_ERROR, 128, '')
        put_u32(mm, OFF_COMMAND_STATUS, CMD_ACCEPTED)
        put_u32(mm, OFF_COMMAND_ACK, seq)
        mm.flush()
        wait_for(
            lambda: has_event(backend, 'OperatorCommandAccepted', correlation=correlation),
            label='OperatorCommandAccepted',
        )
        if has_event(backend, 'WhisperSent', correlation=correlation):
            raise RuntimeError('console falsely marked dispatch ACK as WhisperSent')

        # Only the CHAT_MSG_WHISPER_INFORM-equivalent event is allowed to mark sent.
        write_event(
            mm, 2, 2, 'SmokeChar', 'SmokePeer', 'manual smoke reply',
            result='sent', intent='manual', correlation=correlation,
        )
        sent = wait_for(
            lambda: has_event(backend, 'WhisperSent', message='manual smoke reply', correlation=correlation),
            label='WhisperSent final confirmation',
        )
        if sent.get('Direction') != 3:  # OperatorDirection.OutgoingManual
            raise RuntimeError(f'final manual direction mismatch: {sent}')

        print('OPERATOR BRIDGE IPC ROUNDTRIP PASS')
        print(f'fake_runtime_pid={pid}')
        print('map_first_discovery=PASS')
        print('incoming_whisper=PASS')
        print('manual_command_wire=PASS')
        print('dispatch_ack_not_sent=PASS')
        print('final_whisper_confirmation=PASS')
        return 0
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
        if args.keep_temp:
            print(f'operator_root={operator_root}')
        else:
            shutil.rmtree(operator_root, ignore_errors=True)


if __name__ == '__main__':
    raise SystemExit(main())
