from __future__ import annotations

import argparse
import csv
import html as html_lib
import re
import time
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

PATTERNS = [
    re.compile(r'Disenchant ID:\s*(\d+)', re.I),
    re.compile(r'DisenchantId\s*[:=]?\s*(\d+)', re.I),
    re.compile(r'disenchantId\s*[:=]?\s*(\d+)', re.I),
    re.compile(r'"DisenchantId"\s*:\s*(\d+)', re.I),
    re.compile(r'"disenchantId"\s*:\s*(\d+)', re.I),
]
HEADERS = {
    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/154.0.0.0 Safari/537.36',
    'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
    'Accept-Language': 'en-US,en;q=0.9',
    'Cache-Control': 'no-cache',
}
VALID_SOURCES = {'OctoWow', 'CapyDB', 'SeedLegacy'}


def parse_de(body: str) -> int | None:
    plain = html_lib.unescape(re.sub(r'<[^>]+>', ' ', body))
    for pattern in PATTERNS:
        m = pattern.search(plain) or pattern.search(body)
        if m:
            return int(m.group(1))
    return None


def fetch_text(url: str, timeout: float) -> str:
    req = urllib.request.Request(url, headers=HEADERS)
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.read().decode('utf-8', errors='replace')


def resolve_one(item_id: int, timeout: float, retries: int) -> tuple[int, int | None, str, str]:
    sources = [
        ('OctoWow', f'https://octowow.st/db/?item={item_id}'),
        ('CapyDB', f'https://db.capycraft.org/item/{item_id}'),
    ]
    errors: list[str] = []
    for source, url in sources:
        for attempt in range(1, retries + 1):
            try:
                body = fetch_text(url, timeout)
                de = parse_de(body)
                if de is None:
                    raise RuntimeError('Disenchant ID field not found')
                return item_id, de, source, ''
            except Exception as exc:
                errors.append(f'{source} attempt={attempt}: {exc}')
                if attempt < retries:
                    time.sleep(0.15 * attempt)
    return item_id, None, '', ' | '.join(errors)


def read_seed(path: Path) -> dict[int, tuple[int, str]]:
    cache: dict[int, tuple[int, str]] = {}
    if not path.exists():
        return cache
    with path.open('r', encoding='utf-8-sig', newline='') as f:
        reader = csv.DictReader(f)
        names = set(reader.fieldnames or [])
        has_source = 'source' in names
        for row in reader:
            try:
                item_id = int(row['item_id'])
                deid = int(row['disenchant_id'])
            except Exception:
                continue
            source = (row.get('source') or '').strip() if has_source else ''
            if source not in VALID_SOURCES:
                source = 'SeedLegacy'
            old = cache.get(item_id)
            if old is not None and old[0] != deid:
                raise SystemExit(f'conflicting seed item_id={item_id}: {old[0]} vs {deid}')
            # Never silently upgrade provenance when values are identical.
            if old is None:
                cache[item_id] = (deid, source)
    return cache


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument('--seed-cache', required=True)
    ap.add_argument('--missing-ids', required=True)
    ap.add_argument('--output-cache', required=True)
    ap.add_argument('--unresolved', required=True)
    ap.add_argument('--workers', type=int, default=16)
    ap.add_argument('--timeout', type=float, default=15.0)
    ap.add_argument('--retries', type=int, default=2)
    args = ap.parse_args()

    cache = read_seed(Path(args.seed_cache))
    ids = sorted({int(x.strip()) for x in Path(args.missing_ids).read_text(encoding='utf-8').splitlines() if x.strip()})
    pending = [item_id for item_id in ids if item_id not in cache]
    print(f'[POC08-E-CACHE] START seed={len(cache)} requested_missing={len(ids)} pending={len(pending)} workers={args.workers}')

    unresolved: list[tuple[int, str]] = []
    source_counts = {'OctoWow': 0, 'CapyDB': 0}
    with ThreadPoolExecutor(max_workers=max(1, min(args.workers, 32))) as pool:
        futures = {pool.submit(resolve_one, item_id, args.timeout, args.retries): item_id for item_id in pending}
        for n, future in enumerate(as_completed(futures), 1):
            item_id, deid, source, error = future.result()
            if deid is None:
                unresolved.append((item_id, error))
                print(f'[POC08-E-CACHE] UNKNOWN item_id={item_id} fail_closed=YES reason={error}')
            else:
                cache[item_id] = (deid, source)
                source_counts[source] += 1
                print(f'[POC08-E-CACHE] RESOLVED item_id={item_id} disenchant_id={deid} source={source} progress={n}/{len(pending)}')

    out = Path(args.output_cache)
    out.parent.mkdir(parents=True, exist_ok=True)
    with out.open('w', encoding='utf-8', newline='') as f:
        w = csv.writer(f)
        w.writerow(['item_id', 'disenchant_id', 'source'])
        for item_id in sorted(cache):
            deid, source = cache[item_id]
            w.writerow([item_id, deid, source])

    unresolved_path = Path(args.unresolved)
    with unresolved_path.open('w', encoding='utf-8', newline='') as f:
        w = csv.writer(f)
        w.writerow(['item_id', 'reason'])
        for item_id, reason in sorted(unresolved):
            w.writerow([item_id, reason])

    for blocked in (20406, 20407, 20408):
        if cache.get(blocked, (-1, ''))[0] != 0:
            raise SystemExit(f'expected regression item {blocked} to have DisenchantID=0')
    if cache.get(41316, (0, ''))[0] <= 0:
        raise SystemExit('expected known-positive item 41316 to have DisenchantID>0')

    totals = {source: 0 for source in VALID_SOURCES}
    for _, source in cache.values():
        totals[source] = totals.get(source, 0) + 1
    print(
        '[POC08-E-CACHE] PASS '
        f'entries={len(cache)} octo={totals.get("OctoWow",0)} '
        f'capy={totals.get("CapyDB",0)} seed_legacy={totals.get("SeedLegacy",0)} '
        f'unresolved={len(unresolved)}'
    )
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
