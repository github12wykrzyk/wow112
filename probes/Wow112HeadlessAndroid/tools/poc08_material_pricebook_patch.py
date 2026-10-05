from pathlib import Path
import sys

if len(sys.argv) != 3:
    raise SystemExit('usage: poc08_material_pricebook_patch.py INPUT_POC08B OUTPUT_POC08C')

src = Path(sys.argv[1]).read_text(encoding='utf-8')
marker = 'fn poc08_reference_de_outcomes('
idx = src.index(marker)

helpers = r'''
#[derive(Debug, Clone, Copy)]
struct Poc08MaterialBookPoint {
    item_id: u32,
    raw_lowest: u32,
    safe_price: u32,
    listing_count: u32,
    unit_count: u64,
    history_count: usize,
    history_median: u32,
    confidence: u8, // 0=UNAVAILABLE, 1=LOW, 2=MEDIUM, 3=HIGH
}

fn poc08_material_confidence_name(value: u8) -> &'static str {
    match value {
        3 => "HIGH",
        2 => "MEDIUM",
        1 => "LOW",
        _ => "UNAVAILABLE",
    }
}

fn poc08_median_u32(values: &mut [u32]) -> u32 {
    if values.is_empty() { return 0; }
    values.sort_unstable();
    let mid = values.len() / 2;
    if values.len() % 2 == 1 {
        values[mid]
    } else {
        let a = u64::from(values[mid - 1]);
        let b = u64::from(values[mid]);
        ((a + b) / 2).min(u64::from(u32::MAX)) as u32
    }
}

fn poc08_load_material_history(path: &str) -> std::collections::HashMap<u32, Vec<u32>> {
    let mut out = std::collections::HashMap::<u32, Vec<u32>>::new();
    let Ok(text) = std::fs::read_to_string(path) else { return out; };
    for line in text.lines().skip(1) {
        let cols = line.split(',').collect::<Vec<_>>();
        if cols.len() < 3 { continue; }
        let Ok(item_id) = cols[1].trim().parse::<u32>() else { continue; };
        let Ok(price) = cols[2].trim().parse::<u32>() else { continue; };
        if item_id == 0 || price == 0 { continue; }
        let values = out.entry(item_id).or_default();
        values.push(price);
        if values.len() > 200 {
            let remove = values.len() - 200;
            values.drain(0..remove);
        }
    }
    out
}

fn poc08_append_material_history(
    path: &str,
    points: &[Poc08MaterialBookPoint],
) -> Result<(), String> {
    use std::io::Write as _;
    let exists_nonempty = std::fs::metadata(path).map(|m| m.len() > 0).unwrap_or(false);
    let mut file = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)
        .map_err(|e| format!("POC08 material history open failed path={path:?}: {e}"))?;
    if !exists_nonempty {
        writeln!(file, "unix_s,item_id,raw_lowest,listing_count,unit_count,safe_price,confidence")
            .map_err(|e| format!("POC08 material history header failed: {e}"))?;
    }
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    for p in points {
        writeln!(
            file,
            "{},{},{},{},{},{},{}",
            now,
            p.item_id,
            p.raw_lowest,
            p.listing_count,
            p.unit_count,
            p.safe_price,
            poc08_material_confidence_name(p.confidence),
        ).map_err(|e| format!("POC08 material history append failed: {e}"))?;
    }
    Ok(())
}

fn poc08_collect_material_pricebook(
    stream: &mut TcpStream,
    crypto: &mut HeaderCrypto,
    auctioneer_guid: u64,
    auction_house: u32,
    player_guid: u64,
) -> Result<(
    std::collections::HashMap<u32, u32>,
    std::collections::HashMap<u32, u32>,
    std::collections::HashMap<u32, u8>,
), String> {
    let history_path = env::var("WOW112_MATERIAL_HISTORY_PATH")
        .unwrap_or_else(|_| "POC08_MATERIAL_HISTORY.csv".to_string());
    let max_pages = poc07_env_u32_default("WOW112_MATERIAL_BOOK_MAX_PAGES", 8)?;
    if max_pages == 0 || max_pages > 64 {
        return Err(format!("WOW112_MATERIAL_BOOK_MAX_PAGES must be 1..64, got {max_pages}"));
    }
    let history = poc08_load_material_history(&history_path);
    let overrides = poc07_parse_value_map("WOW112_DE_MAT_VALUES")?;
    let mut raw_prices = std::collections::HashMap::<u32, u32>::new();
    let mut safe_prices = std::collections::HashMap::<u32, u32>::new();
    let mut confidence = std::collections::HashMap::<u32, u8>::new();
    let mut points = Vec::<Poc08MaterialBookPoint>::new();

    println!(
        "[POC08-C-PRICEBOOK] START materials={} history_path={:?} max_pages={} own_owner_guid=0x{:016X}",
        POC07_DE_MATERIALS_V4.len(), history_path, max_pages, player_guid
    );

    for (material_id, english_name) in POC07_DE_MATERIALS_V4.iter().copied() {
        if let Some(value) = overrides.get(&material_id).copied() {
            raw_prices.insert(material_id, value);
            safe_prices.insert(material_id, value);
            confidence.insert(material_id, 3);
            points.push(Poc08MaterialBookPoint {
                item_id: material_id, raw_lowest: value, safe_price: value,
                listing_count: 0, unit_count: 0, history_count: 0,
                history_median: 0, confidence: 3,
            });
            println!("[POC08-C-PRICEBOOK] OVERRIDE item_id={} value={} confidence=HIGH", material_id, value);
            continue;
        }

        let live_name = poc07_de_query_item_name_v4(stream, crypto, material_id)?
            .unwrap_or_else(|| english_name.to_string());
        let mut page = 0u32;
        let mut unit_prices = Vec::<u32>::new();
        let mut listing_count = 0u32;
        let mut unit_count = 0u64;
        let mut self_listings = 0u32;
        let mut total_seen = 0u32;

        loop {
            let (records, total) = poc07_de_request_named_page(
                stream, crypto, auctioneer_guid, auction_house,
                material_id, &live_name, page,
            )?;
            total_seen = total;
            for record in records.iter().copied() {
                if record.item_id != material_id || record.buyout == 0 || record.count == 0 {
                    continue;
                }
                if record.owner_guid == player_guid {
                    self_listings += 1;
                    continue;
                }
                let unit = u64::from(record.buyout) / u64::from(record.count);
                if unit == 0 { continue; }
                let unit = u32::try_from(unit)
                    .map_err(|_| "POC08 material unit price overflow".to_string())?;
                unit_prices.push(unit);
                listing_count = listing_count.saturating_add(1);
                unit_count = unit_count.saturating_add(u64::from(record.count));
            }

            let list_from = page.saturating_mul(50);
            let done = total == 0 || records.is_empty()
                || list_from.saturating_add(records.len() as u32) >= total;
            if done || page + 1 >= max_pages { break; }
            page = page.saturating_add(1);
        }

        unit_prices.sort_unstable();
        let raw_lowest = unit_prices.first().copied().unwrap_or(0);
        let mut hist = history.get(&material_id).cloned().unwrap_or_default();
        let history_count = hist.len();
        let history_median = poc08_median_u32(&mut hist);

        let depth_conf = if listing_count >= 5 && unit_count >= 10 {
            3u8
        } else if listing_count >= 2 && unit_count >= 3 {
            2u8
        } else if listing_count >= 1 {
            1u8
        } else {
            0u8
        };

        // History can rescue a sparse current book to MEDIUM, but never a
        // completely absent market. Current raw price is capped to 120% of
        // historical median once >=3 prior observations exist.
        let effective_conf = if raw_lowest == 0 {
            0u8
        } else if depth_conf >= 2 {
            depth_conf
        } else if history_count >= 3 && history_median > 0 {
            2u8
        } else {
            depth_conf
        };

        let mut safe_price = if effective_conf >= 2 { raw_lowest } else { 0 };
        if safe_price > 0 && history_count >= 3 && history_median > 0 {
            let history_cap = (u64::from(history_median).saturating_mul(120) / 100)
                .min(u64::from(u32::MAX)) as u32;
            safe_price = safe_price.min(history_cap);
        }
        // First-run MEDIUM book gets a 10% haircut. HIGH keeps current low.
        if safe_price > 0 && effective_conf == 2 && history_count < 3 {
            safe_price = (u64::from(safe_price).saturating_mul(9000) / 10_000)
                .min(u64::from(u32::MAX)) as u32;
        }

        if raw_lowest > 0 { raw_prices.insert(material_id, raw_lowest); }
        if safe_price > 0 { safe_prices.insert(material_id, safe_price); }
        confidence.insert(material_id, effective_conf);
        points.push(Poc08MaterialBookPoint {
            item_id: material_id,
            raw_lowest,
            safe_price,
            listing_count,
            unit_count,
            history_count,
            history_median,
            confidence: effective_conf,
        });

        println!(
            "[POC08-C-PRICEBOOK] item_id={} name={:?} raw={} safe={} listings={} units={} self_excluded={} total_name_matches={} pages={} history_n={} history_median={} confidence={}",
            material_id, live_name, raw_lowest, safe_price, listing_count, unit_count,
            self_listings, total_seen, page + 1, history_count, history_median,
            poc08_material_confidence_name(effective_conf)
        );
    }

    let export_path = env::var("WOW112_MATERIAL_BOOK_EXPORT")
        .unwrap_or_else(|_| "POC08_MATERIAL_BOOK.csv".to_string());
    let mut csv = String::from("item_id,raw_lowest,safe_price,listing_count,unit_count,history_count,history_median,confidence\n");
    for p in points.iter() {
        csv.push_str(&format!(
            "{},{},{},{},{},{},{},{}\n",
            p.item_id, p.raw_lowest, p.safe_price, p.listing_count, p.unit_count,
            p.history_count, p.history_median, poc08_material_confidence_name(p.confidence),
        ));
    }
    std::fs::write(&export_path, csv.as_bytes())
        .map_err(|e| format!("POC08 material book export failed path={export_path:?}: {e}"))?;
    poc08_append_material_history(&history_path, &points)?;

    println!(
        "[POC08-C-PRICEBOOK] PASS raw_coverage={}/{} safe_coverage={}/{} export={:?} history={:?}",
        raw_prices.len(), POC07_DE_MATERIALS_V4.len(),
        safe_prices.len(), POC07_DE_MATERIALS_V4.len(),
        export_path, history_path
    );
    Ok((raw_prices, safe_prices, confidence))
}

fn poc08_safe_ev_from_outcomes(
    outcomes: &[Poc07DeOutcome],
    safe_prices: &std::collections::HashMap<u32, u32>,
    net_bps: u32,
) -> u32 {
    let mut numerator: u128 = 0;
    for outcome in outcomes {
        // Missing/LOW-confidence material contributes ZERO. This is a lower
        // bound, not a reason to substitute a guessed market price.
        let price = safe_prices.get(&outcome.material_id).copied().unwrap_or(0);
        numerator = numerator.saturating_add(
            u128::from(price)
                .saturating_mul(u128::from(outcome.avg_qty_x100))
                .saturating_mul(u128::from(outcome.probability_bps)),
        );
    }
    let gross = numerator / 1_000_000u128;
    let net = gross.saturating_mul(u128::from(net_bps)) / 10_000u128;
    net.min(u128::from(u32::MAX)) as u32
}

'''
src = src[:idx] + helpers + src[idx:]

# Replace the old one-number material collector. RAW stays responsible for
# broad discovery/ceilings; SAFE is used only for conservative decisions.
old_collect = '    let mat_prices = poc07_collect_de_material_prices_v4(stream, &mut crypto, auctioneer_guid, auction_house)?;'
new_collect = '''    let (mat_prices, safe_mat_prices, _material_confidence) = poc08_collect_material_pricebook(\n        stream, &mut crypto, auctioneer_guid, auction_house, player_guid\n    )?;'''
if old_collect not in src:
    raise SystemExit('POC08-C material collector marker not found')
src = src.replace(old_collect, new_collect, 1)

# Candidate structure tracks RAW reference EV and SAFE lower-bound EV separately.
src = src.replace(
    '    reference_de_ev: u32,\n    de_profit: i64,\n',
    '    reference_de_ev: u32,\n    safe_de_ev: u32,\n    de_profit: i64,\n',
    1,
)

# Decision builder takes safe map and uses it for DE route.
src = src.replace(
    '    reference_de_values: &std::collections::HashMap<u32, u32>,\n    max_buyout: u32,',
    '    reference_de_values: &std::collections::HashMap<u32, u32>,\n    safe_de_values: &std::collections::HashMap<u32, u32>,\n    max_buyout: u32,',
    1,
)
old_decision_ev = '''        let reference_de_ev = if matches!(exact_de, Some(id) if id > 0) {\n            reference_de_values.get(&record.item_id).copied().unwrap_or(0)\n        } else { 0 };\n        let de_gross = u64::from(reference_de_ev).saturating_mul(u64::from(record.count));'''
new_decision_ev = '''        let reference_de_ev = if matches!(exact_de, Some(id) if id > 0) {\n            reference_de_values.get(&record.item_id).copied().unwrap_or(0)\n        } else { 0 };\n        let safe_de_ev = if matches!(exact_de, Some(id) if id > 0) {\n            safe_de_values.get(&record.item_id).copied().unwrap_or(0)\n        } else { 0 };\n        let de_gross = u64::from(safe_de_ev).saturating_mul(u64::from(record.count));'''
if old_decision_ev not in src:
    raise SystemExit('POC08-C decision EV marker not found')
src = src.replace(old_decision_ev, new_decision_ev, 1)
src = src.replace('        let de_ok = reference_de_ev > 0 && de_profit >= min_profit;', '        let de_ok = safe_de_ev > 0 && de_profit >= min_profit;', 1)
src = src.replace('                reference_de_ev,\n                de_profit,', '                reference_de_ev,\n                safe_de_ev,\n                de_profit,', 1)

# Build safe DE values after B builds raw reference values.
needle = '''    println!(\n        "[POC08-B-REFERENCE] PASS items={} deid_positive={} deid_zero={} deid_unknown={} ref_priced={} ref_model_missing={} ref_price_missing={} heuristic_reference_diff={} provenance=REFERENCE_CLASSIC_NOT_OCTO_VERIFIED",\n        item_ids.len(), ref_deid_positive, ref_deid_zero, ref_deid_unknown,\n        reference_de_values.len(), ref_model_missing, ref_price_missing,\n        heuristic_reference_diff\n    );\n'''
if needle not in src:
    raise SystemExit('POC08-C B-reference summary marker not found')
insert = needle + r'''
    let mut safe_de_values = std::collections::HashMap::<u32, u32>::new();
    let mut safe_model_covered = 0usize;
    for item_id in item_ids.iter().copied() {
        let Some(deid) = poc08_exact_disenchant_id(item_id) else { continue; };
        if deid == 0 { continue; }
        let Some(outcomes) = poc08_reference_de_outcomes(deid) else { continue; };
        safe_model_covered += 1;
        let safe_ev = poc08_safe_ev_from_outcomes(&outcomes, &safe_mat_prices, net_bps);
        if safe_ev > 0 { safe_de_values.insert(item_id, safe_ev); }
    }
    println!(
        "[POC08-C-SAFEEV] PASS model_covered={} positive_safe_ev={} raw_reference_ev={} rule=LOW_OR_MISSING_MATERIAL_CONTRIBUTES_ZERO",
        safe_model_covered, safe_de_values.len(), reference_de_values.len()
    );
'''
src = src.replace(needle, insert, 1)

# Pass safe values to unified decision function.
src = src.replace(
    '        &reference_de_values,\n        max_buyout,',
    '        &reference_de_values,\n        &safe_de_values,\n        max_buyout,',
    1,
)

# Candidate CSV and console expose SAFE separately.
src = src.replace(
    'disenchant_id,heuristic_de_ev,reference_de_ev,de_profit,chosen_exit',
    'disenchant_id,heuristic_de_ev,reference_de_ev,safe_de_ev,de_profit,chosen_exit',
    1,
)
src = src.replace(
    '            c.reference_de_ev,\n            c.de_profit,',
    '            c.reference_de_ev,\n            c.safe_de_ev,\n            c.de_profit,',
    1,
)
# One extra CSV value needs one extra formatter slot.
src = src.replace(
    '"{rank},{},{},{},{},{},{},{},{},{},{},{},{},{},{},{}\\n",',
    '"{rank},{},{},{},{},{},{},{},{},{},{},{},{},{},{},{},{}\\n",',
    1,
)
src = src.replace(
    'heuristic_ev={} reference_ev={} de_profit={}',
    'heuristic_ev={} reference_ev={} safe_ev={} de_profit={}',
    1,
)
src = src.replace(
    '            c.reference_de_ev,\n            c.de_profit,\n            c.chosen_profit,',
    '            c.reference_de_ev,\n            c.safe_de_ev,\n            c.de_profit,\n            c.chosen_profit,',
    1,
)

src = src.replace('[POC08-B] COMBINED AUDIT', '[POC08-C] COMBINED AUDIT', 1)
src = src.replace(
    '[POC08-B] MATERIAL PRICE MODEL source=live-lowest-positive unit_rounding=FLOOR depth_history=NOT_YET_AVAILABLE autobuy=DISABLED',
    '[POC08-C] MATERIAL PRICE MODEL source=DEPTH+HISTORY raw_for_discovery safe_for_decision own_listings_excluded=YES autobuy=DISABLED',
    1,
)
src = src.replace('[POC08-B] NO_CANDIDATE_PASS', '[POC08-C] NO_CANDIDATE_PASS', 1)
src = src.replace('[POC08-B] CANDIDATE AUDIT PASS', '[POC08-C] CANDIDATE AUDIT PASS', 1)
src = src.replace('[POC08-B] REAL COMBINED SCAN-ONLY PASS', '[POC08-C] REAL COMBINED SCAN-ONLY PASS', 1)
src = src.replace(
    '[POC08-B] ENGINE PASS mode=ReferenceCompare mutation=DISABLED zero_candidates_is_pass=YES',
    '[POC08-C] ENGINE PASS mode=RiskPricebookAudit mutation=DISABLED zero_candidates_is_pass=YES',
    1,
)

Path(sys.argv[2]).write_text(src, encoding='utf-8')
print('[POC08-C-PATCH] PASS depth/history material pricebook + SAFE EV generated')
