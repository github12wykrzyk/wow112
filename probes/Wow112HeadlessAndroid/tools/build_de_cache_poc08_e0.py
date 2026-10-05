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
                    time.sleep(0.10 * attempt)
    return item_id, None, 'UNRESOLVED', ' | '.join(errors)


def read_seed(path: Path) -> dict[int, tuple[int, str]]:
    out: dict[int, tuple[int, str]] = {}
    if not path.exists():
        return out
    with path.open('r', encoding='utf-8-sig', newline='') as f:
        for row in csv.DictReader(f):
            try:
                item_id = int(row['item_id'])
                de = int(row['disenchant_id'])
                source = (row.get('source') or 'LEGACY_SEED').strip() or 'LEGACY_SEED'
            except Exception:
                continue
            out[item_id] = (de, source)
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument('--seed-cache', required=True)
    ap.add_argument('--item-ids', required=True)
    ap.add_argument('--output-cache', required=True)
    ap.add_argument('--unresolved', required=True)
    ap.add_argument('--workers', type=int, default=24)
    ap.add_argument('--timeout', type=float, default=10.0)
    ap.add_argument('--retries', type=int, default=1)
    ap.add_argument('--refresh-seed', action='store_true')
    args = ap.parse_args()

    seed = read_seed(Path(args.seed_cache))
    requested = sorted({int(x.strip()) for x in Path(args.item_ids).read_text(encoding='utf-8').splitlines() if x.strip()})
    if len(requested) < 1000:
        raise SystemExit(f'POC08-E0 coverage snapshot unexpectedly small: {len(requested)}')

    cache: dict[int, tuple[int, str]] = dict(seed)
    if args.refresh_seed:
        pending = requested
    else:
        pending = [item_id for item_id in requested if item_id not in cache]

    print(f'[POC08-E0-CACHE] START requested={len(requested)} seed={len(seed)} pending={len(pending)} refresh_seed={args.refresh_seed} workers={args.workers}')
    unresolved: list[tuple[int, str]] = []
    source_counts: dict[str, int] = {}

    with ThreadPoolExecutor(max_workers=max(1, min(args.workers, 32))) as pool:
        futures = {pool.submit(resolve_one, item_id, args.timeout, args.retries): item_id for item_id in pending}
        for n, future in enumerate(as_completed(futures), 1):
            item_id, de, source, error = future.result()
            if de is None:
                cache.pop(item_id, None)
                unresolved.append((item_id, error))
                if n <= 20 or n % 100 == 0:
                    print(f'[POC08-E0-CACHE] UNKNOWN item_id={item_id} progress={n}/{len(pending)}')
            else:
                cache[item_id] = (de, source)
                source_counts[source] = source_counts.get(source, 0) + 1
                if n <= 20 or n % 100 == 0:
                    print(f'[POC08-E0-CACHE] RESOLVED item_id={item_id} deid={de} source={source} progress={n}/{len(pending)}')

    out_path = Path(args.output_cache)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    with out_path.open('w', encoding='utf-8', newline='') as f:
        w = csv.writer(f)
        w.writerow(['item_id', 'disenchant_id', 'source'])
        for item_id in requested:
            row = cache.get(item_id)
            if row is not None:
                w.writerow([item_id, row[0], row[1]])

    unresolved_path = Path(args.unresolved)
    with unresolved_path.open('w', encoding='utf-8', newline='') as f:
        w = csv.writer(f)
        w.writerow(['item_id', 'reason'])
        for item_id, reason in sorted(unresolved):
            w.writerow([item_id, reason])

    requested_cache = {k: v for k, v in cache.items() if k in set(requested)}
    positive = sum(1 for de, _ in requested_cache.values() if de > 0)
    zero = sum(1 for de, _ in requested_cache.values() if de == 0)
    by_source: dict[str, int] = {}
    for _, source in requested_cache.values():
        by_source[source] = by_source.get(source, 0) + 1
    missing = len(requested) - len(requested_cache)
    print(f'[POC08-E0-CACHE] PASS requested={len(requested)} resolved={len(requested_cache)} positive={positive} zero={zero} unresolved={missing} sources={by_source}')

    # Permanent regression anchors.
    regressions = {20406: 0, 20407: 0, 20408: 0}
    for item_id, expected in regressions.items():
        row = requested_cache.get(item_id) or cache.get(item_id)
        if row is None or row[0] != expected:
            raise SystemExit(f'POC08-E0 regression failed item={item_id} expected={expected} got={row}')
    row = requested_cache.get(41316) or cache.get(41316)
    if row is None or row[0] <= 0:
        raise SystemExit(f'POC08-E0 known-positive regression failed item=41316 got={row}')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
