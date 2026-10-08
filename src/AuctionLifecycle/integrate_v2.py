#!/usr/bin/env python3
"""Integrate Market Maker V2 after the existing Lifecycle/V1 source integration.

This is intentionally a second pass. It never edits canonical login or BUY bodies and
fails closed if the expected V1 integration markers drift.
"""
from pathlib import Path
import sys


def once(text: str, old: str, new: str) -> str:
    n = text.count(old)
    if n != 1:
        raise ValueError(f"MM2 integration marker mismatch count={n}: {old[:100]!r}")
    return text.replace(old, new, 1)


def integrate(root: Path) -> None:
    src = root / "probes/Wow112HeadlessAndroid/src"
    main = src / "main.rs"
    world7 = src / "world_poc07.rs"
    if not main.exists() or not world7.exists():
        raise FileNotFoundError("generated canonical source missing")

    m = main.read_text(encoding="utf-8-sig")
    anchor = '#[path = "../../../src/AuctionLifecycle/market_maker_policy.rs"]\nmod market_maker_policy;'
    insert = anchor + '\n' + '\n'.join([
        '#[path = "../../../src/AuctionLifecycle/market_maker_v2_policy.rs"]',
        'mod market_maker_v2_policy;',
        '#[path = "../../../src/AuctionLifecycle/market_maker_v2_recovery.rs"]',
        'mod market_maker_v2_recovery;',
        '#[path = "../../../src/AuctionLifecycle/market_maker_v2_saga.rs"]',
        'mod market_maker_v2_saga;',
    ])
    m = once(m, anchor, insert)

    w = world7.read_text(encoding="utf-8-sig")
    v1_tail = '\ninclude!("../../../src/AuctionLifecycle/market_maker.rs");\n'
    v2_tail = v1_tail + ''.join([
        'include!("../../../src/AuctionLifecycle/market_maker_v2_inventory.rs");\n',
        'include!("../../../src/AuctionLifecycle/market_maker_v2_io.rs");\n',
        'include!("../../../src/AuctionLifecycle/market_maker_v2_targets.rs");\n',
        'include!("../../../src/AuctionLifecycle/market_maker_v2_depth.rs");\n',
    ])
    w = once(w, v1_tail, v2_tail)

    main.write_text(m, encoding="utf-8")
    world7.write_text(w, encoding="utf-8")
    print("MARKET MAKER V2 INTEGRATION PASS; canonical login/BUY bodies untouched")


if __name__ == "__main__":
    integrate(Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve())
