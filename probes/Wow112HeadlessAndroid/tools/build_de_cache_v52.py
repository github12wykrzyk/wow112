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
                    time.sleep(0.15 * attempt)
    return item_id, None, '', ' | '.join(errors)


def read_seed(path: Path) -> dict[int, tuple[int, str]]:
    cache: dict[int, tuple[int, str]] = {}
    if not path.exists():
        return cache
    with path.open('r', encoding='utf-8-sig', newline='') as f:
        for row in csv.DictReader(f):
            try:
                item_id = int(row['item_id'])
                disenchant_id = int(row['disenchant_id'])
                source = (row.get('source') or 'SeedLegacy').strip() or 'SeedLegacy'
                cache[item_id] = (disenchant_id, source)
            except Exception:
                pass
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

    seed = Path(args.seed_cache)
    missing_path = Path(args.missing_ids)
    out_path = Path(args.output_cache)
    unresolved_path = Path(args.unresolved)

    cache = read_seed(seed)
    ids = sorted({int(x.strip()) for x in missing_path.read_text(encoding='utf-8').splitlines() if x.strip()})
    pending = [item_id for item_id in ids if item_id not in cache]
    print(f'[V5.2-CACHE] START seed={len(cache)} requested_missing={len(ids)} pending={len(pending)} workers={args.workers}')

    unresolved: list[tuple[int, str]] = []
    resolved_now = 0
    source_counts: dict[str, int] = {}
    with ThreadPoolExecutor(max_workers=max(1, min(args.workers, 32))) as pool:
        futures = {pool.submit(resolve_one, item_id, args.timeout, args.retries): item_id for item_id in pending}
        for n, future in enumerate(as_completed(futures), 1):
            item_id, de, source, error = future.result()
            if de is None:
                unresolved.append((item_id, error))
                print(f'[V5.2-CACHE] UNKNOWN item_id={item_id} fail_closed=YES reason={error}')
            else:
                cache[item_id] = (de, source)
                resolved_now += 1
                source_counts[source] = source_counts.get(source, 0) + 1
                print(f'[V5.2-CACHE] RESOLVED item_id={item_id} disenchant_id={de} source={source} progress={n}/{len(pending)}')

    out_path.parent.mkdir(parents=True, exist_ok=True)
    with out_path.open('w', encoding='utf-8', newline='') as f:
        w = csv.writer(f)
        w.writerow(['item_id', 'disenchant_id', 'source'])
        for item_id in sorted(cache):
            disenchant_id, source = cache[item_id]
            w.writerow([item_id, disenchant_id, source])

    with unresolved_path.open('w', encoding='utf-8', newline='') as f:
        w = csv.writer(f)
        w.writerow(['item_id', 'reason'])
        for item_id, reason in sorted(unresolved):
            w.writerow([item_id, reason])

    print(
        f'[V5.2-CACHE] PASS cache_entries={len(cache)} resolved_now={resolved_now} unresolved={len(unresolved)} '
        f'sources={source_counts}'
    )
    if 20406 not in cache or cache[20406][0] != 0:
        raise SystemExit('expected seed 20406 DisenchantID=0')
    if 41316 not in cache or cache[41316][0] <= 0:
        raise SystemExit('expected seed 41316 DisenchantID>0')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
