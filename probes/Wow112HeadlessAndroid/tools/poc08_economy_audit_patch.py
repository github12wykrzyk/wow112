from __future__ import annotations

from pathlib import Path
import sys

if len(sys.argv) != 3:
    raise SystemExit('usage: poc08_economy_audit_patch.py INPUT_V53 OUTPUT_POC08')

src = Path(sys.argv[1]).read_text(encoding='utf-8')

# Compile the exact DisenchantID cache directly into the runtime module.
include_marker = 'include!("world_poc07_delive.rs");\n'
if include_marker not in src:
    raise SystemExit('POC08 include marker not found')
src = src.replace(
    include_marker,
    include_marker + 'include!("poc08_de_cache_generated.rs");\n',
    1,
)

# Material pricing must never round a fractional unit price upward. POC08-A is
# still scan-only, but remove this optimistic bias before any future mutation.
old_rounding = '''                let unit = (u64::from(record.buyout) + u64::from(record.count) - 1) / u64::from(record.count);\n                let unit = u32::try_from(unit).map_err(|_| "DE material unit price overflow".to_string())?;'''
new_rounding = '''                let unit = u64::from(record.buyout) / u64::from(record.count);\n                if unit == 0 {\n                    continue;\n                }\n                let unit = u32::try_from(unit).map_err(|_| "DE material unit price overflow".to_string())?;'''
if old_rounding not in src:
    raise SystemExit('POC08 material rounding marker not found')
src = src.replace(old_rounding, new_rounding, 1)

login_marker = 'pub fn login_poc07_delive_v53('
idx = src.index(login_marker)

helpers = r'''
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Poc08Exit {
    Vendor,
    Disenchant,
}

impl Poc08Exit {
    fn as_str(self) -> &'static str {
        match self {
            Self::Vendor => "vendor",
            Self::Disenchant => "de",
        }
    }
}

#[derive(Debug, Clone, Copy)]
struct Poc08EconomyCandidate {
    page: u32,
    record: Poc06AuctionRecord,
    chosen_exit: Poc08Exit,
    chosen_profit: i64,
    vendor_unit: u32,
    vendor_profit: i64,
    disenchant_id: u32,
    de_ev: u32,
    de_profit: i64,
}

fn poc08_profit(gross: u64, buyout: u32) -> i64 {
    let value = i128::from(gross) - i128::from(buyout);
    value.clamp(i128::from(i64::MIN), i128::from(i64::MAX)) as i64
}

fn poc08_query_vendor_values_turbo(
    stream: &mut TcpStream,
    crypto: &mut HeaderCrypto,
    item_ids: &[u32],
    window: usize,
) -> Result<std::collections::HashMap<u32, u32>, String> {
    if window == 0 || window > 128 {
        return Err(format!("POC08 vendor query window must be 1..128, got {window}"));
    }
    let started = std::time::Instant::now();
    let mut values = std::collections::HashMap::<u32, u32>::new();
    let mut completed = HashSet::<u32>::new();
    let mut pending = HashSet::<u32>::new();
    let mut next = 0usize;
    let mut zero_vendor = 0usize;
    let mut missing_template = 0usize;
    let mut rx_packets = 0usize;

    while next < item_ids.len() && pending.len() < window {
        let item_id = item_ids[next];
        poc07_de_send_item_query_v52(stream, crypto, item_id)?;
        pending.insert(item_id);
        next += 1;
    }
    println!(
        "[POC08-VENDOR] ITEM-QUERY START total={} window={} initial_inflight={}",
        item_ids.len(), window, pending.len()
    );

    while !pending.is_empty() {
        let (opcode, payload) = read_encrypted_raw(stream, crypto.decrypter())?;
        rx_packets += 1;
        if opcode == POC07_SMSG_ITEM_QUERY_SINGLE_RESPONSE_OPCODE {
            if payload.len() < 4 {
                return Err(format!("POC08 vendor item response too short len={}", payload.len()));
            }
            let raw_entry = read_u32_at(&payload, 0)?;
            let item_id = raw_entry & 0x7fff_ffff;
            if pending.remove(&item_id) {
                match poc07_parse_item_sell_price(&payload, item_id)? {
                    Some(value) if value > 0 => {
                        values.insert(item_id, value);
                    }
                    Some(_) => zero_vendor += 1,
                    None => missing_template += 1,
                }
                completed.insert(item_id);

                while next < item_ids.len() && pending.len() < window {
                    let next_id = item_ids[next];
                    poc07_de_send_item_query_v52(stream, crypto, next_id)?;
                    pending.insert(next_id);
                    next += 1;
                }

                let done = completed.len();
                if done <= 16 || done % 250 == 0 || done == item_ids.len() {
                    let elapsed = started.elapsed().as_secs_f64().max(0.001);
                    println!(
                        "[POC08-VENDOR] progress={}/{} inflight={} qps={:.1}",
                        done, item_ids.len(), pending.len(), done as f64 / elapsed
                    );
                }
                continue;
            }
            continue;
        }
    }

    let elapsed = started.elapsed().as_secs_f64().max(0.001);
    println!(
        "[POC08-VENDOR] ITEM-QUERY PASS queried={} sellable={} zero_vendor={} missing_template={} elapsed_s={:.3} qps={:.1} window={} rx_packets={}",
        completed.len(), values.len(), zero_vendor, missing_template, elapsed,
        completed.len() as f64 / elapsed, window, rx_packets
    );
    Ok(values)
}

fn poc08_export_economy_audit(
    candidates: &[Poc08EconomyCandidate],
    rejected_rows: &[String],
) -> Result<(), String> {
    let candidate_path = env::var("WOW112_ECONOMY_CANDIDATE_EXPORT")
        .unwrap_or_else(|_| "POC08_ECONOMY_CANDIDATES.csv".to_string());
    let rejected_path = env::var("WOW112_ECONOMY_REJECTED_EXPORT")
        .unwrap_or_else(|_| "POC08_ECONOMY_REJECTED.csv".to_string());

    let mut csv = String::from(
        "rank,auction_id,item_id,count,buyout,page,owner_guid,vendor_unit,vendor_profit,disenchant_id,de_model_ev,de_profit,chosen_exit,chosen_profit,de_model_confidence\n"
    );
    for (rank, c) in candidates.iter().enumerate() {
        csv.push_str(&format!(
            "{rank},{},{},{},{},{},{},{},{},{},{},{},{},{},{}\n",
            c.record.auction_id,
            c.record.item_id,
            c.record.count,
            c.record.buyout,
            c.page,
            c.record.owner_guid,
            c.vendor_unit,
            c.vendor_profit,
            c.disenchant_id,
            c.de_ev,
            c.de_profit,
            c.chosen_exit.as_str(),
            c.chosen_profit,
            "HEURISTIC_DISTRIBUTION_EXACT_DEID",
        ));
    }
    std::fs::write(&candidate_path, csv.as_bytes())
        .map_err(|e| format!("POC08 candidate export failed path={candidate_path:?}: {e}"))?;

    let mut rejected = String::from(
        "auction_id,item_id,count,buyout,page,owner_guid,vendor_unit,vendor_profit,disenchant_id,de_model_ev,de_profit,reason\n"
    );
    for row in rejected_rows {
        rejected.push_str(row);
        rejected.push('\n');
    }
    std::fs::write(&rejected_path, rejected.as_bytes())
        .map_err(|e| format!("POC08 rejected export failed path={rejected_path:?}: {e}"))?;

    println!(
        "[POC08-EXPORT] PASS candidates={} rejected={} candidate_path={:?} rejected_path={:?}",
        candidates.len(), rejected_rows.len(), candidate_path, rejected_path
    );
    Ok(())
}

fn poc08_build_combined_decisions(
    scanned: &[(u32, Poc06AuctionRecord)],
    vendor_values: &std::collections::HashMap<u32, u32>,
    de_values: &std::collections::HashMap<u32, u32>,
    max_buyout: u32,
    min_profit: i64,
    blacklist: &HashSet<u32>,
) -> (Vec<Poc08EconomyCandidate>, Vec<String>) {
    let mut candidates = Vec::<Poc08EconomyCandidate>::new();
    let mut rejected = Vec::<String>::new();

    let mut exact_de_positive = 0usize;
    let mut exact_de_zero = 0usize;
    let mut exact_de_unknown = 0usize;
    let mut vendor_wins = 0usize;
    let mut de_wins = 0usize;

    for (page, record) in scanned.iter().copied() {
        if record.buyout == 0 || record.buyout > max_buyout || record.count == 0 || blacklist.contains(&record.item_id) {
            continue;
        }

        let vendor_unit = vendor_values.get(&record.item_id).copied().unwrap_or(0);
        let vendor_gross = u64::from(vendor_unit).saturating_mul(u64::from(record.count));
        let vendor_profit = poc08_profit(vendor_gross, record.buyout);

        let exact_de = poc08_exact_disenchant_id(record.item_id);
        let disenchant_id = exact_de.unwrap_or(0);
        match exact_de {
            Some(0) => exact_de_zero += 1,
            Some(_) => exact_de_positive += 1,
            None => exact_de_unknown += 1,
        }

        let de_ev = if matches!(exact_de, Some(id) if id > 0) {
            de_values.get(&record.item_id).copied().unwrap_or(0)
        } else {
            0
        };
        let de_gross = u64::from(de_ev).saturating_mul(u64::from(record.count));
        let de_profit = poc08_profit(de_gross, record.buyout);

        let vendor_ok = vendor_unit > 0 && vendor_profit >= min_profit;
        let de_ok = de_ev > 0 && de_profit >= min_profit;

        let chosen = match (vendor_ok, de_ok) {
            (true, true) if de_profit > vendor_profit => Some((Poc08Exit::Disenchant, de_profit)),
            (true, true) => Some((Poc08Exit::Vendor, vendor_profit)), // deterministic exit wins ties
            (true, false) => Some((Poc08Exit::Vendor, vendor_profit)),
            (false, true) => Some((Poc08Exit::Disenchant, de_profit)),
            (false, false) => None,
        };

        if let Some((chosen_exit, chosen_profit)) = chosen {
            match chosen_exit {
                Poc08Exit::Vendor => vendor_wins += 1,
                Poc08Exit::Disenchant => de_wins += 1,
            }
            candidates.push(Poc08EconomyCandidate {
                page,
                record,
                chosen_exit,
                chosen_profit,
                vendor_unit,
                vendor_profit,
                disenchant_id,
                de_ev,
                de_profit,
            });
        } else {
            let reason = if exact_de.is_none() && vendor_unit == 0 {
                "DE_ID_UNKNOWN_AND_NO_VENDOR"
            } else if exact_de == Some(0) && vendor_unit == 0 {
                "DE_ID_ZERO_AND_NO_VENDOR"
            } else if matches!(exact_de, Some(id) if id > 0) && de_ev == 0 && vendor_unit == 0 {
                "DE_MODEL_OR_MATERIAL_PRICE_UNAVAILABLE"
            } else {
                "NO_EXIT_MEETS_MIN_PROFIT"
            };
            rejected.push(format!(
                "{},{},{},{},{},{},{},{},{},{},{},{}",
                record.auction_id,
                record.item_id,
                record.count,
                record.buyout,
                page,
                record.owner_guid,
                vendor_unit,
                vendor_profit,
                disenchant_id,
                de_ev,
                de_profit,
                reason,
            ));
        }
    }

    candidates.sort_by(|a, b| {
        b.chosen_profit
            .cmp(&a.chosen_profit)
            .then_with(|| a.record.buyout.cmp(&b.record.buyout))
            .then_with(|| a.record.auction_id.cmp(&b.record.auction_id))
    });

    println!(
        "[POC08-DECISION] PASS scanned={} qualified={} rejected={} vendor_wins={} de_wins={} deid_positive_rows={} deid_zero_rows={} deid_unknown_rows={} cache_entries={}",
        scanned.len(), candidates.len(), rejected.len(), vendor_wins, de_wins,
        exact_de_positive, exact_de_zero, exact_de_unknown, POC08_DE_CACHE_ENTRIES
    );

    for (rank, c) in candidates.iter().take(50).enumerate() {
        println!(
            "[POC08-CANDIDATE] rank={} exit={} auction_id={} item_id={} count={} buyout={} vendor_unit={} vendor_profit={} deid={} de_ev={} de_profit={} chosen_profit={} page={}",
            rank,
            c.chosen_exit.as_str(),
            c.record.auction_id,
            c.record.item_id,
            c.record.count,
            c.record.buyout,
            c.vendor_unit,
            c.vendor_profit,
            c.disenchant_id,
            c.de_ev,
            c.de_profit,
            c.chosen_profit,
            c.page,
        );
    }

    (candidates, rejected)
}

'''

src = src[:idx] + helpers + src[idx:]
src = src.replace(login_marker, 'pub fn login_poc08_economy_audit(', 1)

# Replace the old DE-only candidate tail with a single combined decision ledger.
start_marker = '    let empty_vendor = std::collections::HashMap::<u32, u32>::new();\n'
start = src.find(start_marker)
if start < 0:
    raise SystemExit('POC08 candidate start marker not found')
end_marker = '    if soak_seconds > 0'
end = src.find(end_marker, start)
if end < 0:
    raise SystemExit('POC08 candidate end marker not found')

new_tail = r'''    println!("[POC08] COMBINED AUDIT valuation=DE+VENDOR exact_deid_gate=IN_RUNTIME de_distribution=HEURISTIC_V4 mutation=DISABLED");
    println!("[POC08] MATERIAL PRICE MODEL source=live-lowest-positive unit_rounding=FLOOR depth_history=NOT_YET_AVAILABLE autobuy=DISABLED");
    let vendor_values = poc08_query_vendor_values_turbo(
        stream,
        &mut crypto,
        &item_ids,
        item_query_window,
    )?;
    let (economy_candidates, rejected_rows) = poc08_build_combined_decisions(
        &scanned,
        &vendor_values,
        &de_values,
        max_buyout,
        min_profit,
        &blacklist,
    );
    poc08_export_economy_audit(&economy_candidates, &rejected_rows)?;
    if economy_candidates.is_empty() {
        println!("[POC08] NO_CANDIDATE_PASS qualified=0 mutation=DISABLED status=NORMAL_NOOP");
    } else {
        println!("[POC08] CANDIDATE AUDIT PASS qualified={} mutation=DISABLED", economy_candidates.len());
    }
    println!("[POC08] REAL COMBINED SCAN-ONLY PASS no_mutation=YES");
'''

src = src[:start] + new_tail + src[end:]

# Final engine marker: make it impossible to confuse this artifact with V5.3.
src = src.replace(
    'println!("[POC07-DE-V5.3] ENGINE PASS mode=ScanOnly mutation=DISABLED");',
    'println!("[POC08] ENGINE PASS mode=CombinedAudit mutation=DISABLED zero_candidates_is_pass=YES");',
    1,
)

Path(sys.argv[2]).write_text(src, encoding='utf-8')
print('[POC08-PATCH] PASS combined vendor+DE audit source generated')
