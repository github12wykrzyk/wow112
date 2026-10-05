from pathlib import Path
import sys

if len(sys.argv) != 2:
    raise SystemExit('usage: vendor_capy_guard_patch.py GENERATED_FULLSWEEP_RS')

p = Path(sys.argv[1])
s = p.read_text(encoding='utf-8')

# Print every qualified vendor candidate so the launcher can externally verify
# all potential targets, not only the first 20.
s = s.replace(
    'candidates.len().min(20)',
    'candidates.len()',
    1,
)
s = s.replace(
    'for (rank, candidate) in candidates.iter().take(20).enumerate() {',
    'for (rank, candidate) in candidates.iter().enumerate() {',
    1,
)

old = '''            let candidate = candidates\n                .first()\n                .copied()\n                .ok_or_else(|| "POC07_NO_QUALIFIED_CANDIDATE no purchase sent".to_string())?;'''
new = '''            // Capy/Turtle guard: BUY is impossible unless the launcher provides an\n            // exact externally-verified target from the immediately preceding scan.\n            let expected_auction_id = env::var("WOW112_BUY_EXPECT_AUCTION_ID")\n                .map_err(|_| "CAPY_GUARD_BLOCKED missing WOW112_BUY_EXPECT_AUCTION_ID".to_string())?\n                .trim().parse::<u32>()\n                .map_err(|e| format!("CAPY_GUARD_BLOCKED invalid expected auction id: {e}"))?;\n            let expected_item_id = env::var("WOW112_BUY_EXPECT_ITEM_ID")\n                .map_err(|_| "CAPY_GUARD_BLOCKED missing WOW112_BUY_EXPECT_ITEM_ID".to_string())?\n                .trim().parse::<u32>()\n                .map_err(|e| format!("CAPY_GUARD_BLOCKED invalid expected item id: {e}"))?;\n            let expected_buyout = env::var("WOW112_BUY_EXPECT_BUYOUT")\n                .map_err(|_| "CAPY_GUARD_BLOCKED missing WOW112_BUY_EXPECT_BUYOUT".to_string())?\n                .trim().parse::<u32>()\n                .map_err(|e| format!("CAPY_GUARD_BLOCKED invalid expected buyout: {e}"))?;\n            let expected_count = env::var("WOW112_BUY_EXPECT_COUNT")\n                .map_err(|_| "CAPY_GUARD_BLOCKED missing WOW112_BUY_EXPECT_COUNT".to_string())?\n                .trim().parse::<u32>()\n                .map_err(|e| format!("CAPY_GUARD_BLOCKED invalid expected count: {e}"))?;\n            let expected_vendor_unit = env::var("WOW112_BUY_EXPECT_VENDOR_UNIT")\n                .map_err(|_| "CAPY_GUARD_BLOCKED missing WOW112_BUY_EXPECT_VENDOR_UNIT".to_string())?\n                .trim().parse::<u32>()\n                .map_err(|e| format!("CAPY_GUARD_BLOCKED invalid expected vendor unit: {e}"))?;\n\n            let candidate = candidates\n                .iter()\n                .copied()\n                .find(|candidate| {\n                    candidate.record.auction_id == expected_auction_id\n                        && candidate.record.item_id == expected_item_id\n                        && candidate.record.buyout == expected_buyout\n                        && candidate.record.count == expected_count\n                        && candidate.unit_value == expected_vendor_unit\n                })\n                .ok_or_else(|| format!(\n                    "CAPY_GUARD_BLOCKED exact verified target not present auction_id={} item_id={} buyout={} count={} vendor_unit={}",\n                    expected_auction_id, expected_item_id, expected_buyout, expected_count, expected_vendor_unit\n                ))?;\n            println!(\n                "[CAPY-GUARD] EXACT TARGET PASS auction_id={} item_id={} buyout={} count={} vendor_unit={} expected_profit={}",\n                candidate.record.auction_id, candidate.record.item_id, candidate.record.buyout,\n                candidate.record.count, candidate.unit_value, candidate.expected_profit\n            );'''

if old not in s:
    raise SystemExit('buy-one selection marker not found')
s = s.replace(old, new, 1)

for marker in [
    'CAPY_GUARD_BLOCKED',
    '[CAPY-GUARD] EXACT TARGET PASS',
    'WOW112_BUY_EXPECT_AUCTION_ID',
    'WOW112_BUY_EXPECT_VENDOR_UNIT',
]:
    if marker not in s:
        raise SystemExit(f'marker missing after patch: {marker}')

p.write_text(s, encoding='utf-8')
print('[CAPY-GUARD-PATCH] PASS')
