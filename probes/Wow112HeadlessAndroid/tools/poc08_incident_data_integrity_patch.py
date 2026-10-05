from pathlib import Path
import sys

if len(sys.argv) != 2:
    raise SystemExit('usage: poc08_incident_data_integrity_patch.py GENERATED_F2_RS')

p = Path(sys.argv[1])
s = p.read_text(encoding='utf-8')


def replace_between(start_marker: str, end_marker: str, replacement: str, label: str) -> None:
    global s
    a = s.find(start_marker)
    b = s.find(end_marker, a + len(start_marker)) if a >= 0 else -1
    if a < 0 or b < 0:
        raise SystemExit(f'incident data-integrity {label}: bounds not found')
    s = s[:a] + replacement.rstrip() + '\n\n' + s[b:]


history_v2 = r'''
fn poc08_history_v2_dir(path: &str) -> String {
    format!("{path}.v2.d")
}

fn poc08_history_now_unix() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

fn poc08_history_fnv1a64(bytes: &[u8]) -> u64 {
    let mut hash = 0xcbf29ce484222325u64;
    for b in bytes {
        hash ^= u64::from(*b);
        hash = hash.wrapping_mul(0x100000001b3);
    }
    hash
}

fn poc08_history_source_client() -> String {
    if let Ok(v) = env::var("WOW112_SOURCE_CLIENT") {
        let t = v.trim();
        if !t.is_empty() { return t.to_string(); }
    }
    let account = env::var("WOW112_ACCOUNT").unwrap_or_else(|_| "unknown-account".to_string());
    let character = env::var("WOW112_CHARACTER").unwrap_or_else(|_| "unknown-character".to_string());
    format!("{}:{}", account.trim(), character.trim())
}

fn poc08_history_file_health_fail(reason: &str) {
    println!("[POC08-DATA-HEALTH] status=FAIL_CLOSED scope=DE reason={reason}");
}

fn poc08_load_material_history(path: &str) -> std::collections::HashMap<u32, Vec<u32>> {
    let mut out = std::collections::HashMap::<u32, Vec<u32>>::new();
    let dir = poc08_history_v2_dir(path);
    let Ok(read_dir) = std::fs::read_dir(&dir) else {
        println!("[POC08-DATA-HEALTH] status=WARMUP scope=DE reason=NO_V2_HISTORY dir={:?}", dir);
        return out;
    };

    let now = poc08_history_now_unix();
    let max_age = poc07_env_u32_default("WOW112_DE_HISTORY_MAX_AGE_S", 21_600).unwrap_or(21_600) as u64;
    let epoch_s = poc07_env_u32_default("WOW112_DE_HISTORY_EPOCH_S", 900).unwrap_or(900).max(60) as u64;
    let mut seen_epoch = std::collections::HashSet::<(u32, u64)>::new();
    let mut malformed_recent = false;
    let mut accepted_rows = 0u32;

    for ent in read_dir.flatten() {
        let path_buf = ent.path();
        if path_buf.extension().and_then(|x| x.to_str()) != Some("csv") { continue; }
        let Ok(text) = std::fs::read_to_string(&path_buf) else {
            malformed_recent = true;
            continue;
        };
        let mut valid_snapshot = true;
        let mut staged = Vec::<(u32, u64, u32)>::new();
        for (line_no, line) in text.lines().enumerate() {
            if line_no == 0 { continue; }
            if line.trim().is_empty() { continue; }
            let cols = line.split(',').collect::<Vec<_>>();
            if cols.len() != 13 || cols[0] != "2" {
                valid_snapshot = false;
                break;
            }
            let unix_s = match cols[3].parse::<u64>() { Ok(v) => v, Err(_) => { valid_snapshot = false; break; } };
            let item_id = match cols[5].parse::<u32>() { Ok(v) if v > 0 => v, _ => { valid_snapshot = false; break; } };
            let raw_lowest = match cols[6].parse::<u32>() { Ok(v) => v, Err(_) => { valid_snapshot = false; break; } };
            let reference_price = match cols[7].parse::<u32>() { Ok(v) => v, Err(_) => { valid_snapshot = false; break; } };
            let safe_price = match cols[8].parse::<u32>() { Ok(v) => v, Err(_) => { valid_snapshot = false; break; } };
            let listing_count = match cols[9].parse::<u32>() { Ok(v) => v, Err(_) => { valid_snapshot = false; break; } };
            let unit_count = match cols[10].parse::<u32>() { Ok(v) => v, Err(_) => { valid_snapshot = false; break; } };
            let confidence = match cols[11].parse::<u8>() { Ok(v) => v, Err(_) => { valid_snapshot = false; break; } };
            let checksum = match u64::from_str_radix(cols[12], 16) { Ok(v) => v, Err(_) => { valid_snapshot = false; break; } };
            let payload = cols[..12].join(",");
            if poc08_history_fnv1a64(payload.as_bytes()) != checksum {
                valid_snapshot = false;
                break;
            }
            if unix_s > now.saturating_add(60) { valid_snapshot = false; break; }
            if now.saturating_sub(unix_s) > max_age { continue; }
            if raw_lowest == 0 || reference_price == 0 || safe_price == 0 || listing_count == 0 || unit_count == 0 || confidence < 2 {
                continue;
            }
            staged.push((item_id, unix_s, safe_price));
        }
        if !valid_snapshot {
            malformed_recent = true;
            println!("[POC08-DATA-HEALTH] malformed_snapshot={:?}", path_buf);
            continue;
        }
        for (item_id, unix_s, safe_price) in staged {
            let epoch = unix_s / epoch_s;
            if seen_epoch.insert((item_id, epoch)) {
                out.entry(item_id).or_default().push(safe_price);
                accepted_rows = accepted_rows.saturating_add(1);
            }
        }
    }

    if malformed_recent {
        poc08_history_file_health_fail("MALFORMED_OR_PARTIAL_V2_SNAPSHOT");
        return std::collections::HashMap::new();
    }
    println!("[POC08-DATA-HEALTH] status={} scope=DE accepted_history_rows={} epoch_s={} max_age_s={}",
        if accepted_rows > 0 { "OK" } else { "WARMUP" }, accepted_rows, epoch_s, max_age);
    out
}
'''
replace_between('fn poc08_load_material_history(', 'fn poc08_append_material_history(', history_v2, 'history loader')

append_v2 = r'''
fn poc08_append_material_history(
    path: &str,
    points: &[Poc08MaterialBookPoint],
) -> Result<(), String> {
    use std::io::Write as _;
    let dir = poc08_history_v2_dir(path);
    std::fs::create_dir_all(&dir)
        .map_err(|e| format!("POC08 V2 history mkdir failed dir={dir:?}: {e}"))?;
    let now = poc08_history_now_unix();
    let pid = std::process::id();
    let source = poc08_history_source_client().replace(',', "_");
    let source_hash = poc08_history_fnv1a64(source.as_bytes());
    let snapshot_id = format!("{}-{}-{:016x}", now, pid, source_hash);
    let scan_id = snapshot_id.clone();
    let final_path = std::path::Path::new(&dir).join(format!("{}.csv", snapshot_id));
    let tmp_path = std::path::Path::new(&dir).join(format!(".{}.tmp", snapshot_id));

    let mut body = String::from("schema_version,snapshot_id,scan_id,unix_s,source_client,item_id,raw_lowest,reference_price,safe_price,listing_count,unit_count,confidence,checksum\n");
    for point in points {
        let payload = format!(
            "2,{},{},{},{},{},{},{},{},{},{},{}",
            snapshot_id, scan_id, now, source, point.item_id, point.raw_lowest,
            point.raw_lowest, point.safe_price, point.listing_count, point.unit_count, point.confidence,
        );
        let checksum = poc08_history_fnv1a64(payload.as_bytes());
        body.push_str(&format!("{payload},{checksum:016x}\n"));
    }

    let mut file = std::fs::OpenOptions::new().create_new(true).write(true).open(&tmp_path)
        .map_err(|e| format!("POC08 V2 history temp open failed path={tmp_path:?}: {e}"))?;
    file.write_all(body.as_bytes())
        .map_err(|e| format!("POC08 V2 history temp write failed path={tmp_path:?}: {e}"))?;
    file.sync_all()
        .map_err(|e| format!("POC08 V2 history temp fsync failed path={tmp_path:?}: {e}"))?;
    drop(file);
    std::fs::rename(&tmp_path, &final_path)
        .map_err(|e| format!("POC08 V2 history atomic rename failed tmp={tmp_path:?} final={final_path:?}: {e}"))?;
    println!("[POC08-DATA-HEALTH] snapshot_commit=PASS schema=2 snapshot_id={} scan_id={} source_client={} rows={} path={:?}",
        snapshot_id, scan_id, source, points.len(), final_path);
    Ok(())
}
'''
replace_between('fn poc08_append_material_history(', 'fn poc08_collect_material_pricebook(', append_v2, 'history writer')

old_safe = r'''        let mut safe_price = if effective_conf >= 2 { raw_lowest } else { 0 };
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
'''
new_safe = r'''        let min_history = poc07_env_u32_default("WOW112_DE_MIN_HISTORY_EPOCHS", 3)?.max(3) as usize;
        let shock_bps = poc07_env_u32_default("WOW112_DE_UPWARD_SHOCK_BPS", 2000)?.clamp(500, 5000);
        let mut safe_price = 0u32;
        if effective_conf >= 2 && history_count >= min_history && history_median > 0 {
            let max_allowed = (u64::from(history_median)
                .saturating_mul(u64::from(10_000u32.saturating_add(shock_bps))) / 10_000)
                .min(u64::from(u32::MAX)) as u32;
            if raw_lowest <= max_allowed {
                safe_price = raw_lowest;
            } else {
                println!("[POC08-DATA-HEALTH] status=QUARANTINE item_id={} raw={} anchor={} history_n={} upward_shock_bps={} action=DE_BLOCK",
                    material_id, raw_lowest, history_median, history_count, shock_bps);
            }
        } else {
            println!("[POC08-DATA-HEALTH] status=WARMUP item_id={} raw={} history_n={} min_history={} confidence={} action=DE_BLOCK",
                material_id, raw_lowest, history_count, min_history, effective_conf);
        }
'''
if s.count(old_safe) != 1:
    raise SystemExit(f'incident data-integrity safe-price marker mismatch count={s.count(old_safe)}')
s = s.replace(old_safe, new_safe, 1)

old_unit = '            let unit = record.buyout / record.count;\n'
new_unit = '            let unit = record.buyout.saturating_add(record.count.saturating_sub(1)) / record.count;\n'
if s.count(old_unit) != 1:
    raise SystemExit(f'incident data-integrity unit-normalization marker mismatch count={s.count(old_unit)}')
s = s.replace(old_unit, new_unit, 1)

old_override = '            safe_prices.insert(material_id, value);\n'
new_override = '''            if env::var("WOW112_DE_ALLOW_MANUAL_OVERRIDE").unwrap_or_default() == "YES" {\n                safe_prices.insert(material_id, value);\n            } else {\n                println!("[POC08-DATA-HEALTH] status=FAIL_CLOSED item_id={} reason=MANUAL_OVERRIDE_NOT_ARMED action=DE_BLOCK", material_id);\n            }\n'''
if s.count(old_override) < 1:
    raise SystemExit('incident data-integrity manual override marker not found')
s = s.replace(old_override, new_override, 1)

required = [
    'schema_version,snapshot_id,scan_id,unix_s,source_client',
    'MALFORMED_OR_PARTIAL_V2_SNAPSHOT',
    'WOW112_DE_MIN_HISTORY_EPOCHS',
    'WOW112_DE_UPWARD_SHOCK_BPS',
    'status=QUARANTINE',
    'snapshot_commit=PASS schema=2',
    'saturating_add(record.count.saturating_sub(1)) / record.count',
]
for marker in required:
    if marker not in s:
        raise SystemExit('incident data-integrity required marker missing: ' + marker)

p.write_text(s, encoding='utf-8')
print('[POC08-INCIDENT-DATA-INTEGRITY] PASS schema=2 atomic-snapshots epoch-dedupe stale-check shock-quarantine fail-closed')
