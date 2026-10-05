from pathlib import Path
import sys

if len(sys.argv) != 3:
    raise SystemExit('usage: poc07_de_v53_class_ceiling_patch.py INPUT_V52 OUTPUT_V53')

src = Path(sys.argv[1]).read_text(encoding='utf-8')
marker = 'pub fn login_poc07_delive_v52('
idx = src.index(marker)

helpers = r'''
fn poc07_de_class_ceiling_v53(
    prices: &std::collections::HashMap<u32, u32>,
    net_bps: u32,
    max_buyout: u32,
    min_profit: i64,
    item_class: u32,
) -> Result<u32, String> {
    if item_class != 2 && item_class != 4 {
        return Err(format!("V5.3 unsupported class ceiling class={item_class}"));
    }
    let mut max_ev = 0u32;
    let mut priced_tiers = 0usize;
    let mut max_quality = 0u32;
    let mut max_item_level = 0u32;
    for quality in [2u32, 3u32] {
        for item_level in 1u32..=65u32 {
            let info = Poc07DeItemInfo {
                item_id: 0,
                item_class,
                quality,
                inventory_type: 0,
                item_level,
            };
            if poc07_de_outcomes_v4(info).is_none() {
                continue;
            }
            if let Some(ev) = poc07_de_expected_value_v4(info, prices, net_bps) {
                priced_tiers += 1;
                if ev > max_ev {
                    max_ev = ev;
                    max_quality = quality;
                    max_item_level = item_level;
                }
            }
        }
    }
    if priced_tiers == 0 || max_ev == 0 {
        return Err(format!("V5.3 class={item_class} has no fully-priced disenchant tier"));
    }
    let required_profit = u64::try_from(min_profit.max(0)).unwrap_or(0);
    let economic_ceiling = u64::from(max_ev).saturating_sub(required_profit);
    let ceiling = u64::from(max_buyout)
        .min(economic_ceiling)
        .min(u64::from(u32::MAX)) as u32;
    println!(
        "[POC07-DE-V53-TURBO] CLASS CEILING PASS class={} priced_tiers={} max_quality={} max_ilvl={} max_net_ev={} ({}) ceiling={} ({})",
        item_class,
        priced_tiers,
        max_quality,
        max_item_level,
        max_ev,
        poc06_format_money(max_ev),
        ceiling,
        poc06_format_money(ceiling)
    );
    Ok(ceiling)
}

'''

out = src[:idx] + helpers + src[idx:]
out = out.replace('pub fn login_poc07_delive_v52(', 'pub fn login_poc07_delive_v53(', 1)
out = out.replace('POC07-DE-LIVE-V5.2 is hard read-only; BUY is disabled in this build', 'POC07-DE-LIVE-V5.3 is hard read-only; BUY is disabled in this build', 1)
out = out.replace('[POC07-DE-V5.2]', '[POC07-DE-V5.3]')
out = out.replace('[POC07-DE-V52-TURBO]', '[POC07-DE-V53-TURBO]')
out = out.replace('[POC07-DE-ITEMINFO-V52]', '[POC07-DE-ITEMINFO-V53]')

old_ceiling = '''    let ceiling = poc07_de_global_ceiling_v4(&mat_prices, net_bps, max_buyout, min_profit)?;\n    if ceiling == 0 {'''
new_ceiling = '''    let ceiling = poc07_de_global_ceiling_v4(&mat_prices, net_bps, max_buyout, min_profit)?;\n    let weapon_ceiling = poc07_de_class_ceiling_v53(&mat_prices, net_bps, max_buyout, min_profit, 2)?;\n    let armor_ceiling = poc07_de_class_ceiling_v53(&mat_prices, net_bps, max_buyout, min_profit, 4)?;\n    if ceiling == 0 {'''
if old_ceiling not in out:
    raise SystemExit('V5.3 global ceiling marker not found')
out = out.replace(old_ceiling, new_ceiling, 1)

old_scan = '''    let ah_scan_started = std::time::Instant::now();\n    let mut scanned = Vec::<(u32, Poc06AuctionRecord)>::new();\n    let weapon_started = std::time::Instant::now();\n    let weapon_rows = poc07_de_scan_class_v4(stream, &mut crypto, auctioneer_guid, auction_house, 2, ceiling, filter_max_pages)?;\n    let weapon_elapsed = weapon_started.elapsed().as_secs_f64().max(0.001);\n    let weapon_pages = weapon_rows.iter().map(|(p, _)| p % 10_000).max().map(|p| p + 1).unwrap_or(0);\n    println!("[POC07-DE-V53-TURBO] AH-CLASS PASS class=2 pages~{} kept={} elapsed_s={:.3} pages_per_s={:.2}", weapon_pages, weapon_rows.len(), weapon_elapsed, weapon_pages as f64 / weapon_elapsed);\n    scanned.extend(weapon_rows);\n    let armor_started = std::time::Instant::now();\n    let armor_rows = poc07_de_scan_class_v4(stream, &mut crypto, auctioneer_guid, auction_house, 4, ceiling, filter_max_pages)?;\n    let armor_elapsed = armor_started.elapsed().as_secs_f64().max(0.001);\n    let armor_pages = armor_rows.iter().map(|(p, _)| p % 10_000).max().map(|p| p + 1).unwrap_or(0);\n    println!("[POC07-DE-V53-TURBO] AH-CLASS PASS class=4 pages~{} kept={} elapsed_s={:.3} pages_per_s={:.2}", armor_pages, armor_rows.len(), armor_elapsed, armor_pages as f64 / armor_elapsed);\n    scanned.extend(armor_rows);\n    let ah_elapsed = ah_scan_started.elapsed().as_secs_f64().max(0.001);\n    println!("[POC07-DE-V5.3] FILTERED ECONOMIC AH SCAN PASS records={} ceiling={} ({}) elapsed_s={:.3}", scanned.len(), ceiling, poc06_format_money(ceiling), ah_elapsed);'''
new_scan = '''    let ah_scan_started = std::time::Instant::now();\n    let mut scanned = Vec::<(u32, Poc06AuctionRecord)>::new();\n    let weapon_started = std::time::Instant::now();\n    let weapon_rows = if weapon_ceiling > 0 {\n        poc07_de_scan_class_v4(stream, &mut crypto, auctioneer_guid, auction_house, 2, weapon_ceiling, filter_max_pages)?\n    } else { Vec::new() };\n    let weapon_elapsed = weapon_started.elapsed().as_secs_f64().max(0.001);\n    let weapon_pages = weapon_rows.iter().map(|(p, _)| p % 10_000).max().map(|p| p + 1).unwrap_or(0);\n    println!("[POC07-DE-V53-TURBO] AH-CLASS PASS class=2 ceiling={} pages~{} kept={} elapsed_s={:.3} pages_per_s={:.2}", weapon_ceiling, weapon_pages, weapon_rows.len(), weapon_elapsed, weapon_pages as f64 / weapon_elapsed);\n    scanned.extend(weapon_rows);\n    let armor_started = std::time::Instant::now();\n    let armor_rows = if armor_ceiling > 0 {\n        poc07_de_scan_class_v4(stream, &mut crypto, auctioneer_guid, auction_house, 4, armor_ceiling, filter_max_pages)?\n    } else { Vec::new() };\n    let armor_elapsed = armor_started.elapsed().as_secs_f64().max(0.001);\n    let armor_pages = armor_rows.iter().map(|(p, _)| p % 10_000).max().map(|p| p + 1).unwrap_or(0);\n    println!("[POC07-DE-V53-TURBO] AH-CLASS PASS class=4 ceiling={} pages~{} kept={} elapsed_s={:.3} pages_per_s={:.2}", armor_ceiling, armor_pages, armor_rows.len(), armor_elapsed, armor_pages as f64 / armor_elapsed);\n    scanned.extend(armor_rows);\n    let ah_elapsed = ah_scan_started.elapsed().as_secs_f64().max(0.001);\n    println!("[POC07-DE-V5.3] FILTERED ECONOMIC AH SCAN PASS records={} global_ceiling={} weapon_ceiling={} armor_ceiling={} elapsed_s={:.3}", scanned.len(), ceiling, weapon_ceiling, armor_ceiling, ah_elapsed);'''
if old_scan not in out:
    raise SystemExit('V5.3 scan marker not found')
out = out.replace(old_scan, new_scan, 1)

Path(sys.argv[2]).write_text(out, encoding='utf-8')
