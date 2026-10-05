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

# Hard policy belongs in the binary too, not only in the launcher. This build
# must fail closed if somebody runs the EXE manually with relaxed env values.
policy_marker = '    let min_profit = i64::from(poc07_env_u32_default("WOW112_AUTOBUY_MIN_PROFIT", 1)?);'
policy_replacement = '''    let min_profit = i64::from(poc07_env_u32_default("WOW112_AUTOBUY_MIN_PROFIT", 1)?);\n\n    // CAPY/TURTLE VENDOR GUARD HARD POLICY. These are immutable ceilings/floors\n    // for this specialized build, independent of launcher configuration.\n    const CAPY_GUARD_MAX_BUYOUT_COPPER: u32 = 200_000; // 20g\n    const CAPY_GUARD_MIN_PROFIT_COPPER: i64 = 2;       // strictly > 1c\n    if !use_vendor || use_de {\n        return Err(format!(\n            "CAPY_GUARD_BLOCKED strategy must be vendor-only use_vendor={} use_de={}",\n            use_vendor, use_de\n        ));\n    }\n    if max_buyout > CAPY_GUARD_MAX_BUYOUT_COPPER {\n        return Err(format!(\n            "CAPY_GUARD_BLOCKED max buyout {} exceeds hard cap {} copper (20g)",\n            max_buyout, CAPY_GUARD_MAX_BUYOUT_COPPER\n        ));\n    }\n    if min_profit < CAPY_GUARD_MIN_PROFIT_COPPER {\n        return Err(format!(\n            "CAPY_GUARD_BLOCKED min profit {} below hard floor {} copper (>1c)",\n            min_profit, CAPY_GUARD_MIN_PROFIT_COPPER\n        ));\n    }\n    println!(\n        "[CAPY-GUARD] HARD POLICY PASS VENDOR_ONLY=YES MAX_BUYOUT=200000 MIN_PROFIT=2 HARD_MAX_PURCHASES=1"\n    );'''
if policy_marker not in s:
    raise SystemExit('hard policy insertion marker not found')
s = s.replace(policy_marker, policy_replacement, 1)

old = '''            let candidate = candidates\n                .first()\n                .copied()\n                .ok_or_else(|| "POC07_NO_QUALIFIED_CANDIDATE no purchase sent".to_string())?;'''
new = '''            // Capy/Turtle guard: BUY is impossible unless the launcher provides an\n            // exact externally-verified target from the immediately preceding scan.\n            let expected_auction_id = env::var("WOW112_BUY_EXPECT_AUCTION_ID")\n                .map_err(|_| "CAPY_GUARD_BLOCKED missing WOW112_BUY_EXPECT_AUCTION_ID".to_string())?\n                .trim().parse::<u32>()\n                .map_err(|e| format!("CAPY_GUARD_BLOCKED invalid expected auction id: {e}"))?;\n            let expected_item_id = env::var("WOW112_BUY_EXPECT_ITEM_ID")\n                .map_err(|_| "CAPY_GUARD_BLOCKED missing WOW112_BUY_EXPECT_ITEM_ID".to_string())?\n                .trim().parse::<u32>()\n                .map_err(|e| format!("CAPY_GUARD_BLOCKED invalid expected item id: {e}"))?;\n            let expected_buyout = env::var("WOW112_BUY_EXPECT_BUYOUT")\n                .map_err(|_| "CAPY_GUARD_BLOCKED missing WOW112_BUY_EXPECT_BUYOUT".to_string())?\n                .trim().parse::<u32>()\n                .map_err(|e| format!("CAPY_GUARD_BLOCKED invalid expected buyout: {e}"))?;\n            let expected_count = env::var("WOW112_BUY_EXPECT_COUNT")\n                .map_err(|_| "CAPY_GUARD_BLOCKED missing WOW112_BUY_EXPECT_COUNT".to_string())?\n                .trim().parse::<u32>()\n                .map_err(|e| format!("CAPY_GUARD_BLOCKED invalid expected count: {e}"))?;\n            let expected_vendor_unit = env::var("WOW112_BUY_EXPECT_VENDOR_UNIT")\n                .map_err(|_| "CAPY_GUARD_BLOCKED missing WOW112_BUY_EXPECT_VENDOR_UNIT".to_string())?\n                .trim().parse::<u32>()\n                .map_err(|e| format!("CAPY_GUARD_BLOCKED invalid expected vendor unit: {e}"))?;\n\n            if expected_buyout > CAPY_GUARD_MAX_BUYOUT_COPPER {\n                return Err(format!(\n                    "CAPY_GUARD_BLOCKED exact target buyout {} exceeds hard cap {}",\n                    expected_buyout, CAPY_GUARD_MAX_BUYOUT_COPPER\n                ));\n            }\n\n            let candidate = candidates\n                .iter()\n                .copied()\n                .find(|candidate| {\n                    candidate.record.auction_id == expected_auction_id\n                        && candidate.record.item_id == expected_item_id\n                        && candidate.record.buyout == expected_buyout\n                        && candidate.record.count == expected_count\n                        && candidate.unit_value == expected_vendor_unit\n                        && candidate.expected_profit >= CAPY_GUARD_MIN_PROFIT_COPPER\n                })\n                .ok_or_else(|| format!(\n                    "CAPY_GUARD_BLOCKED exact verified target not present/eligible auction_id={} item_id={} buyout={} count={} vendor_unit={}",\n                    expected_auction_id, expected_item_id, expected_buyout, expected_count, expected_vendor_unit\n                ))?;\n            println!(\n                "[CAPY-GUARD] EXACT TARGET PASS auction_id={} item_id={} buyout={} count={} vendor_unit={} expected_profit={}",\n                candidate.record.auction_id, candidate.record.item_id, candidate.record.buyout,\n                candidate.record.count, candidate.unit_value, candidate.expected_profit\n            );'''

if old not in s:
    raise SystemExit('buy-one selection marker not found')
s = s.replace(old, new, 1)

for marker in [
    'CAPY_GUARD_BLOCKED',
    '[CAPY-GUARD] HARD POLICY PASS',
    '[CAPY-GUARD] EXACT TARGET PASS',
    'CAPY_GUARD_MAX_BUYOUT_COPPER',
    'CAPY_GUARD_MIN_PROFIT_COPPER',
    'WOW112_BUY_EXPECT_AUCTION_ID',
    'WOW112_BUY_EXPECT_VENDOR_UNIT',
]:
    if marker not in s:
        raise SystemExit(f'marker missing after patch: {marker}')

p.write_text(s, encoding='utf-8')
print('[CAPY-GUARD-PATCH] PASS')
