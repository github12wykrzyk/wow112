#!/usr/bin/env python3
"""Guard WoW 1.12/Lua 5.0 callback upvalue budgets for SummonScout."""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "src/AddOns/SummonScout/SummonScout.lua"
LIMIT = 32
SAFE_MAX = 30


def strip_comments_and_strings(text: str) -> str:
    out = []
    i = 0
    n = len(text)
    while i < n:
        if text.startswith("--[[", i):
            end = text.find("]]", i + 4)
            if end < 0:
                out.append(" " * (n - i))
                break
            chunk = text[i:end + 2]
            out.append("".join("\n" if c == "\n" else " " for c in chunk))
            i = end + 2
            continue
        if text.startswith("--", i):
            end = text.find("\n", i + 2)
            if end < 0:
                out.append(" " * (n - i))
                break
            out.append(" " * (end - i))
            i = end
            continue
        ch = text[i]
        if ch in ("'", '"'):
            quote = ch
            start = i
            i += 1
            escaped = False
            while i < n:
                c = text[i]
                if escaped:
                    escaped = False
                elif c == "\\":
                    escaped = True
                elif c == quote:
                    i += 1
                    break
                i += 1
            chunk = text[start:i]
            out.append("".join("\n" if c == "\n" else " " for c in chunk))
            continue
        out.append(ch)
        i += 1
    return "".join(out)


def top_level_locals(prefix: str) -> set[str]:
    names = set()
    clean = strip_comments_and_strings(prefix)
    for line in clean.splitlines():
        m = re.match(r"^local\s+function\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(", line)
        if m:
            names.add(m.group(1))
            continue
        m = re.match(r"^local\s+([A-Za-z_][A-Za-z0-9_]*)\s*(?:=|$)", line)
        if m:
            names.add(m.group(1))
    return names


def callback_body(text: str, start_marker: str, end_marker: str) -> tuple[str, str]:
    start = text.find(start_marker)
    if start < 0:
        raise SystemExit(f"missing callback marker: {start_marker}")
    body_start = start + len(start_marker)
    end = text.find(end_marker, body_start)
    if end < 0:
        raise SystemExit(f"missing callback terminator marker after: {start_marker}")
    return text[:start], text[body_start:end]


def count_upvalue_candidates(prefix: str, body: str) -> list[str]:
    root = top_level_locals(prefix)
    clean = strip_comments_and_strings(body)
    shadowed = set()
    for line in clean.splitlines():
        m = re.search(r"\blocal\s+([A-Za-z_][A-Za-z0-9_]*)", line)
        if m:
            shadowed.add(m.group(1))
    refs = []
    for name in sorted(root):
        if name in shadowed:
            continue
        if re.search(rf"(?<![.:])\b{re.escape(name)}\b", clean):
            refs.append(name)
    return refs


def check(name: str, prefix: str, body: str) -> None:
    refs = count_upvalue_candidates(prefix, body)
    print(f"SUMMONSCOUT_UPVALUES: {name}={len(refs)} candidates: {', '.join(refs)}")
    if len(refs) > SAFE_MAX:
        raise SystemExit(
            f"SUMMONSCOUT_UPVALUES: FAIL {name} has {len(refs)} top-level local references; "
            f"WoW 1.12 Lua limit is {LIMIT}, safe project ceiling is {SAFE_MAX}"
        )


def main() -> int:
    if not SOURCE.exists():
        print("SUMMONSCOUT_UPVALUES: SKIP (SummonScout source absent)")
        return 0
    text = SOURCE.read_text(encoding="utf-8")
    p1, b1 = callback_body(text, 'frame:SetScript("OnEvent", function()', 'frame:SetScript("OnUpdate", function()')
    check("OnEvent", p1, b1)
    p2, b2 = callback_body(text, 'frame:SetScript("OnUpdate", function()', 'SLASH_SUMMONSCOUT1')
    check("OnUpdate", p2, b2)
    print("SUMMONSCOUT_UPVALUES: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
