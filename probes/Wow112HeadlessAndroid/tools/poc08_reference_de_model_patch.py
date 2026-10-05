from pathlib import Path
import sys

if len(sys.argv) != 3:
    raise SystemExit('usage: poc08_reference_de_model_patch.py INPUT_POC08A OUTPUT_POC08B')

src = Path(sys.argv[1]).read_text(encoding='utf-8')
marker = '#[derive(Debug, Clone, Copy, PartialEq, Eq)]\nenum Poc08Exit {'
idx = src.index(marker)

helpers = r'''
fn poc08_reference_de_outcomes(disenchant_id: u32) -> Option<Vec<Poc07DeOutcome>> {
    // REFERENCE_CLASSIC model compiled from the public disenchant_loot_template
    // schema/data. This is NOT claimed to be Octo-exact until empirical/server
    // config validation. Zero-chance grouped rows are represented by the
    // leftover probability after explicit group chances.
    let o = |material_id: u32, probability_bps: u32, min_count: u32, max_count: u32| {
        Poc07DeOutcome {
            material_id,
            probability_bps,
            avg_qty_x100: (min_count + max_count).saturating_mul(50),
        }
    };
    Some(match disenchant_id {
        // Armor / non-weapon uncommon classic tiers.
        1 => vec![o(10938, 2000, 1, 2), o(10940, 8000, 1, 2)],
        2 => vec![o(10939, 2000, 1, 2), o(10940, 7500, 2, 3), o(10978, 500, 1, 1)],
        3 => vec![o(10940, 7500, 4, 6), o(10998, 1500, 1, 2), o(10978, 1000, 1, 1)],
        4 => vec![o(11082, 2000, 1, 2), o(11083, 7500, 1, 2), o(11084, 500, 1, 1)],
        5 => vec![o(11083, 7500, 2, 5), o(11134, 2000, 1, 2), o(11138, 500, 1, 1)],
        6 => vec![o(11135, 2000, 1, 2), o(11137, 7500, 1, 2), o(11139, 500, 1, 1)],
        7 => vec![o(11137, 7500, 2, 5), o(11174, 2000, 1, 2), o(11177, 500, 1, 1)],
        8 => vec![o(11175, 2000, 1, 2), o(11176, 7500, 1, 2), o(11178, 500, 1, 1)],
        9 => vec![o(11176, 7500, 2, 5), o(16202, 2000, 1, 2), o(14343, 500, 1, 1)],
        10 => vec![o(16203, 2000, 1, 2), o(16204, 7500, 1, 2), o(14344, 500, 1, 1)],
        11 => vec![o(16203, 2000, 2, 3), o(16204, 7500, 2, 5), o(14344, 500, 1, 1)],

        // Weapon uncommon classic tiers.
        21 => vec![o(10938, 8000, 1, 2), o(10940, 2000, 1, 2)],
        22 => vec![o(10939, 7500, 1, 2), o(10940, 2000, 2, 3), o(10978, 500, 1, 1)],
        23 => vec![o(10998, 7500, 1, 2), o(10940, 1500, 4, 6), o(10978, 1000, 1, 1)],
        24 => vec![o(11082, 7500, 1, 2), o(11083, 2000, 1, 2), o(11084, 500, 1, 1)],
        25 => vec![o(11134, 7500, 1, 2), o(11083, 2000, 2, 5), o(11138, 500, 1, 1)],
        26 => vec![o(11135, 7500, 1, 2), o(11137, 2000, 1, 2), o(11139, 500, 1, 1)],
        27 => vec![o(11174, 7500, 1, 2), o(11137, 2000, 2, 5), o(11177, 500, 1, 1)],
        28 => vec![o(11175, 7500, 1, 2), o(11176, 2000, 1, 2), o(11178, 500, 1, 1)],
        29 => vec![o(16202, 7500, 1, 2), o(11176, 2200, 2, 5), o(14343, 300, 1, 1)],
        30 => vec![o(16203, 7500, 1, 2), o(16204, 2200, 1, 2), o(14344, 300, 1, 1)],
        31 => vec![o(16203, 7500, 2, 3), o(16204, 2200, 2, 5), o(14344, 300, 1, 1)],

        // Rare / special classic tiers.
        41 => vec![o(10978, 10_000, 1, 1)],
        42 => vec![o(11084, 10_000, 1, 1)],
        43 => vec![o(11138, 10_000, 1, 1)],
        44 => vec![o(11139, 10_000, 1, 1)],
        45 => vec![o(11177, 10_000, 1, 1)],
        46 => vec![o(11178, 10_000, 1, 1)],
        47 => vec![o(14343, 10_000, 1, 1)],
        48 | 49 => vec![o(14344, 9950, 1, 1), o(20725, 50, 1, 1)],
        61 => vec![o(11177, 10_000, 2, 4)],
        62 => vec![o(11178, 10_000, 2, 4)],
        63 => vec![o(14343, 10_000, 2, 4)],
        64 => vec![o(20725, 10_000, 1, 1)],
        _ => return None,
    })
}

fn poc08_ev_from_outcomes(
    outcomes: &[Poc07DeOutcome],
    prices: &std::collections::HashMap<u32, u32>,
    net_bps: u32,
) -> Option<u32> {
    let mut numerator: u128 = 0;
    for outcome in outcomes {
        let price = prices.get(&outcome.material_id).copied()?;
        numerator = numerator.saturating_add(
            u128::from(price)
                .saturating_mul(u128::from(outcome.avg_qty_x100))
                .saturating_mul(u128::from(outcome.probability_bps)),
        );
    }
    let gross = numerator / 1_000_000u128;
    let net = gross.saturating_mul(u128::from(net_bps)) / 10_000u128;
    u32::try_from(net.min(u128::from(u32::MAX))).ok()
}

fn poc08_reference_de_value(
    disenchant_id: u32,
    prices: &std::collections::HashMap<u32, u32>,
    net_bps: u32,
) -> Option<u32> {
    let outcomes = poc08_reference_de_outcomes(disenchant_id)?;
    poc08_ev_from_outcomes(&outcomes, prices, net_bps)
}

'''
src = src[:idx] + helpers + src[idx:]

# Extend candidate structure so the audit preserves both valuations.
src = src.replace(
    '    de_ev: u32,\n    de_profit: i64,\n',
    '    heuristic_de_ev: u32,\n    reference_de_ev: u32,\n    de_profit: i64,\n',
    1,
)

# Combined builder now receives both maps; reference model controls the DE route.
src = src.replace(
    '    de_values: &std::collections::HashMap<u32, u32>,\n    max_buyout: u32,',
    '    heuristic_de_values: &std::collections::HashMap<u32, u32>,\n    reference_de_values: &std::collections::HashMap<u32, u32>,\n    max_buyout: u32,',
    1,
)

old_ev = '''        let de_ev = if matches!(exact_de, Some(id) if id > 0) {\n            de_values.get(&record.item_id).copied().unwrap_or(0)\n        } else {\n            0\n        };\n        let de_gross = u64::from(de_ev).saturating_mul(u64::from(record.count));\n        let de_profit = poc08_profit(de_gross, record.buyout);'''
new_ev = '''        let heuristic_de_ev = if matches!(exact_de, Some(id) if id > 0) {\n            heuristic_de_values.get(&record.item_id).copied().unwrap_or(0)\n        } else { 0 };\n        let reference_de_ev = if matches!(exact_de, Some(id) if id > 0) {\n            reference_de_values.get(&record.item_id).copied().unwrap_or(0)\n        } else { 0 };\n        let de_gross = u64::from(reference_de_ev).saturating_mul(u64::from(record.count));\n        let de_profit = poc08_profit(de_gross, record.buyout);'''
if old_ev not in src:
    raise SystemExit('POC08-B de EV marker not found')
src = src.replace(old_ev, new_ev, 1)
src = src.replace('        let de_ok = de_ev > 0 && de_profit >= min_profit;', '        let de_ok = reference_de_ev > 0 && de_profit >= min_profit;', 1)
src = src.replace('                de_ev,\n                de_profit,', '                heuristic_de_ev,\n                reference_de_ev,\n                de_profit,', 1)
src = src.replace(
    'matches!(exact_de, Some(id) if id > 0) && de_ev == 0 && vendor_unit == 0',
    'matches!(exact_de, Some(id) if id > 0) && reference_de_ev == 0 && vendor_unit == 0',
    1,
)
src = src.replace(
    '                de_ev,\n                de_profit,\n                reason,',
    '                reference_de_ev,\n                de_profit,\n                reason,',
    1,
)

# CSV schema and rows: preserve both values and provenance.
src = src.replace(
    '"rank,auction_id,item_id,count,buyout,page,owner_guid,vendor_unit,vendor_profit,disenchant_id,de_model_ev,de_profit,chosen_exit,chosen_profit,de_model_confidence\\n"',
    '"rank,auction_id,item_id,count,buyout,page,owner_guid,vendor_unit,vendor_profit,disenchant_id,heuristic_de_ev,reference_de_ev,de_profit,chosen_exit,chosen_profit,de_model_confidence\\n"',
    1,
)
src = src.replace(
    '            c.de_ev,\n            c.de_profit,',
    '            c.heuristic_de_ev,\n            c.reference_de_ev,\n            c.de_profit,',
    1,
)
src = src.replace('"HEURISTIC_DISTRIBUTION_EXACT_DEID",', '"REFERENCE_CLASSIC_NOT_OCTO_VERIFIED",', 1)
src = src.replace(
    '"auction_id,item_id,count,buyout,page,owner_guid,vendor_unit,vendor_profit,disenchant_id,de_model_ev,de_profit,reason\\n"',
    '"auction_id,item_id,count,buyout,page,owner_guid,vendor_unit,vendor_profit,disenchant_id,reference_de_ev,de_profit,reason\\n"',
    1,
)

# Console candidate output.
src = src.replace(
    'vendor_profit={} deid={} de_ev={} de_profit={} chosen_profit={} page={}",',
    'vendor_profit={} deid={} heuristic_ev={} reference_ev={} de_profit={} chosen_profit={} page={}",',
    1,
)
src = src.replace(
    '            c.disenchant_id,\n            c.de_ev,\n            c.de_profit,',
    '            c.disenchant_id,\n            c.heuristic_de_ev,\n            c.reference_de_ev,\n            c.de_profit,',
    1,
)

# Build reference values after heuristic template valuation. Only exact positive
# DisenchantIDs with a covered reference table entry and fully priced outputs qualify.
needle = '    println!("[POC07-DE-V5.3] TEMPLATE+VALUATION PASS queried={} model_supported={} fully_priced={} missing_templates={} material_coverage={}/{}", item_ids.len(), model_supported, priced_supported, missing_templates, mat_prices.len(), POC07_DE_MATERIALS_V4.len());\n'
if needle not in src:
    raise SystemExit('POC08-B template summary marker not found')
insert = needle + r'''
    let mut reference_de_values = std::collections::HashMap::<u32, u32>::new();
    let mut ref_deid_positive = 0usize;
    let mut ref_deid_zero = 0usize;
    let mut ref_deid_unknown = 0usize;
    let mut ref_model_missing = 0usize;
    let mut ref_price_missing = 0usize;
    let mut heuristic_reference_diff = 0usize;
    for item_id in item_ids.iter().copied() {
        match poc08_exact_disenchant_id(item_id) {
            None => { ref_deid_unknown += 1; }
            Some(0) => { ref_deid_zero += 1; }
            Some(deid) => {
                ref_deid_positive += 1;
                match poc08_reference_de_outcomes(deid) {
                    None => { ref_model_missing += 1; }
                    Some(outcomes) => match poc08_ev_from_outcomes(&outcomes, &mat_prices, net_bps) {
                        None => { ref_price_missing += 1; }
                        Some(ev) if ev > 0 => {
                            if de_values.get(&item_id).copied().unwrap_or(0) != ev {
                                heuristic_reference_diff += 1;
                            }
                            reference_de_values.insert(item_id, ev);
                        }
                        Some(_) => {}
                    },
                }
            }
        }
    }
    println!(
        "[POC08-B-REFERENCE] PASS items={} deid_positive={} deid_zero={} deid_unknown={} ref_priced={} ref_model_missing={} ref_price_missing={} heuristic_reference_diff={} provenance=REFERENCE_CLASSIC_NOT_OCTO_VERIFIED",
        item_ids.len(), ref_deid_positive, ref_deid_zero, ref_deid_unknown,
        reference_de_values.len(), ref_model_missing, ref_price_missing,
        heuristic_reference_diff
    );
'''
src = src.replace(needle, insert, 1)

# Pass the reference map into the unified decision engine.
src = src.replace(
    '        &de_values,\n        max_buyout,',
    '        &de_values,\n        &reference_de_values,\n        max_buyout,',
    1,
)

src = src.replace(
    '[POC08] COMBINED AUDIT valuation=DE+VENDOR exact_deid_gate=IN_RUNTIME de_distribution=HEURISTIC_V4 mutation=DISABLED',
    '[POC08-B] COMBINED AUDIT valuation=DE+VENDOR exact_deid_gate=IN_RUNTIME de_distribution=REFERENCE_CLASSIC_COMPARE mutation=DISABLED',
    1,
)
src = src.replace(
    '[POC08] MATERIAL PRICE MODEL source=live-lowest-positive unit_rounding=FLOOR depth_history=NOT_YET_AVAILABLE autobuy=DISABLED',
    '[POC08-B] MATERIAL PRICE MODEL source=live-lowest-positive unit_rounding=FLOOR depth_history=NOT_YET_AVAILABLE autobuy=DISABLED',
    1,
)
src = src.replace('[POC08] NO_CANDIDATE_PASS', '[POC08-B] NO_CANDIDATE_PASS', 1)
src = src.replace('[POC08] CANDIDATE AUDIT PASS', '[POC08-B] CANDIDATE AUDIT PASS', 1)
src = src.replace('[POC08] REAL COMBINED SCAN-ONLY PASS', '[POC08-B] REAL COMBINED SCAN-ONLY PASS', 1)
src = src.replace(
    '[POC08] ENGINE PASS mode=CombinedAudit mutation=DISABLED zero_candidates_is_pass=YES',
    '[POC08-B] ENGINE PASS mode=ReferenceCompare mutation=DISABLED zero_candidates_is_pass=YES',
    1,
)

Path(sys.argv[2]).write_text(src, encoding='utf-8')
print('[POC08-B-PATCH] PASS reference DisenchantID model comparison generated')
