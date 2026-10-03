#!/usr/bin/env python3
"""Build the inert AuxEconomyShadow Lua bundle for an already watched hot host."""
from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SHADOW = ROOT / "src/AddOns/AuxEconomyShadow"
HOST_NAME = "SummonScout_PostPaymentOfferHot.lua"
BUNDLE_MARKER = b"W112_AH_SHADOW_HOT_BUNDLE_BEGIN:v1"
BUNDLE_END = b"W112_AH_SHADOW_HOT_BUNDLE_END:v1"
ATOMIC_BEGIN_MARKER = b"W112_AH_SHADOW_ATOMIC_BATCH_BEGIN:v1"
ATOMIC_END_MARKER = b"W112_AH_SHADOW_ATOMIC_BATCH_END:v1"
BUNDLE_PROTOCOL_REVISION = "v3-atomic-critical-hardening"
MAX_BUNDLE_BYTES = 196608
LUA51_LENGTH_OPERATOR = re.compile(rb"#\s*[A-Za-z_(]")

ORDER = (
    "AuxEconomyShadow_Anchor.lua",
    "AuxEconomyShadow_Contracts.lua",
    "AuxEconomyShadow_MarketBook.lua",
    "AuxEconomyShadow_Vendor.lua",
    "AuxEconomyShadow_Disenchant.lua",
    "AuxEconomyShadow_CandidatePipeline.lua",
    "AuxEconomyShadow_Coordinator.lua",
    "AuxEconomyShadow_AuxAdapter.lua",
    "AuxEconomyShadow_TransactionGuard.lua",
    "AuxEconomyShadow_AutoSell.lua",
    "AuxEconomyShadow_Ledger.lua",
    "AuxEconomyShadow_Parity.lua",
    "AuxEconomyShadow_HotPayload.lua",
)


def _assert_lua50_compatible(name: str, data: bytes) -> None:
    for number, raw in enumerate(data.splitlines(), 1):
        code = raw.split(b"--", 1)[0]
        if LUA51_LENGTH_OPERATOR.search(code):
            raise RuntimeError(
                "AH shadow hot bundle uses Lua 5.1 length operator in "
                + name + ":" + str(number)
            )


def _read(name: str) -> bytes:
    path = SHADOW / name
    if not path.is_file():
        raise RuntimeError("AH shadow hot bundle missing source: " + name)
    data = path.read_bytes().replace(b"\r\n", b"\n").replace(b"\r", b"\n")
    if not data.strip():
        raise RuntimeError("AH shadow hot bundle empty source: " + name)
    if b"\x00" in data:
        raise RuntimeError("AH shadow hot bundle NUL byte: " + name)
    _assert_lua50_compatible(name, data)
    return data.rstrip(b"\n")


def build_bundle() -> bytes:
    toc = SHADOW / "AuxEconomyShadow.toc"
    if not toc.is_file():
        raise RuntimeError("AH shadow hot bundle missing TOC")
    toc_text = toc.read_text(encoding="utf-8")
    pos = -1
    for name in ORDER:
        nxt = toc_text.find(name)
        if nxt <= pos:
            raise RuntimeError("AH shadow hot bundle TOC order mismatch at " + name)
        pos = nxt

    rows = [b"-- " + BUNDLE_MARKER]

    # The persistent anchor defines the replacement protocol. All replaceable
    # modules below it stage first and commit as one generation.
    anchor = ORDER[0]
    rows.append(("-- BEGIN " + anchor).encode("ascii"))
    rows.append(b"do")
    rows.append(_read(anchor))
    rows.append(b"end")
    rows.append(("-- END " + anchor).encode("ascii"))

    rows.append(b"-- " + ATOMIC_BEGIN_MARKER)
    rows.append(
        (
            'local __w112_ah_begin_ok, __w112_ah_begin_value = '
            'W112_AH_SHADOW.BeginHotPayload("' + BUNDLE_PROTOCOL_REVISION + '")'
        ).encode("ascii")
    )
    rows.append(b'if not __w112_ah_begin_ok then error(__w112_ah_begin_value or "AH atomic batch begin failed") end')
    rows.append(b"local __w112_ah_payload_ok, __w112_ah_payload_err = pcall(function()")

    for name in ORDER[1:]:
        rows.append(("-- BEGIN " + name).encode("ascii"))
        rows.append(b"do")
        rows.append(_read(name))
        rows.append(b"end")
        rows.append(("-- END " + name).encode("ascii"))

    rows.append(b"end)")
    rows.append(
        b"local __w112_ah_commit_ok, __w112_ah_commit_value = "
        b"W112_AH_SHADOW.EndHotPayload(__w112_ah_payload_ok, __w112_ah_payload_err)"
    )
    rows.append(
        b'if not __w112_ah_commit_ok then error(__w112_ah_commit_value or __w112_ah_payload_err or "AH atomic batch commit failed") end'
    )
    rows.append(b"-- " + ATOMIC_END_MARKER)
    rows.append(b"-- " + BUNDLE_END)

    bundle = b"\n".join(rows) + b"\n"
    if len(bundle) > MAX_BUNDLE_BYTES:
        raise RuntimeError("AH shadow hot bundle exceeds safety cap")
    if bundle.count(BUNDLE_MARKER) != 1 or bundle.count(BUNDLE_END) != 1:
        raise RuntimeError("AH shadow hot bundle marker mismatch")
    if bundle.count(ATOMIC_BEGIN_MARKER) != 1 or bundle.count(ATOMIC_END_MARKER) != 1:
        raise RuntimeError("AH shadow atomic batch marker mismatch")
    if bundle.find(ATOMIC_BEGIN_MARKER) >= bundle.find(ATOMIC_END_MARKER):
        raise RuntimeError("AH shadow atomic batch marker order mismatch")
    return bundle


def transform_summonscout_host(name: str, data: bytes) -> bytes:
    if name != HOST_NAME:
        return data
    if BUNDLE_MARKER in data or BUNDLE_END in data:
        raise RuntimeError("AH shadow hot bundle already present in watched host")
    bundle = build_bundle()
    return data.rstrip(b"\r\n") + b"\n\n-- Packaged AuxEconomyShadow hot bundle follows.\n" + bundle


if __name__ == "__main__":
    payload = build_bundle()
    print("AH_SHADOW_HOT_BUNDLE: PASS", "files", len(ORDER), "bytes", len(payload), "protocol", BUNDLE_PROTOCOL_REVISION)
