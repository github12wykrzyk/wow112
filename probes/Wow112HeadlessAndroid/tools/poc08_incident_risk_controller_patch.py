from pathlib import Path
import sys

if len(sys.argv) != 2:
    raise SystemExit('usage: poc08_incident_risk_controller_patch.py GENERATED_F2_RS')

p = Path(sys.argv[1])
s = p.read_text(encoding='utf-8')

marker = 'pub fn login_poc08_economy_audit(\n'
idx = s.find(marker)
if idx < 0:
    raise SystemExit('incident risk controller login marker not found')

helpers = r'''
fn poc08_incident_now_unix() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

fn poc08_incident_state_dir() -> String {
    let base = env::var("WOW112_DE_RISK_STATE_PATH").unwrap_or_else(|_| "POC08_DE_RISK_STATE".to_string());
    format!("{base}.d")
}

fn poc08_incident_session_id() -> String {
    env::var("WOW112_DE_SESSION_ID").unwrap_or_else(|_| format!("pid-{}", std::process::id()))
}

fn poc08_incident_write_event(kind: &str, reservation_id: &str, row: &str) -> Result<(), String> {
    use std::io::Write as _;
    let dir = poc08_incident_state_dir();
    std::fs::create_dir_all(&dir).map_err(|e| format!("DE risk state mkdir failed dir={dir:?}: {e}"))?;
    let final_path = std::path::Path::new(&dir).join(format!("{}.{}.csv", reservation_id, kind));
    let tmp_path = std::path::Path::new(&dir).join(format!(".{}.{}.tmp", reservation_id, kind));
    let mut f = std::fs::OpenOptions::new().create_new(true).write(true).open(&tmp_path)
        .map_err(|e| format!("DE risk state temp open failed path={tmp_path:?}: {e}"))?;
    f.write_all(b"schema_version,reservation_id,unix_s,session_id,price_epoch,auction_id,item_id,deid,buyout,status,materials\n")
        .and_then(|_| f.write_all(row.as_bytes()))
        .and_then(|_| f.write_all(b"\n"))
        .map_err(|e| format!("DE risk state write failed path={tmp_path:?}: {e}"))?;
    f.sync_all().map_err(|e| format!("DE risk state fsync failed path={tmp_path:?}: {e}"))?;
    drop(f);
    std::fs::rename(&tmp_path, &final_path)
        .map_err(|e| format!("DE risk state atomic rename failed tmp={tmp_path:?} final={final_path:?}: {e}"))?;
    Ok(())
}

#[derive(Debug, Clone)]
struct Poc08IncidentExposure {
    reservation_id: String,
    unix_s: u64,
    session_id: String,
    price_epoch: u64,
    auction_id: u32,
    item_id: u32,
    deid: u32,
    buyout: u32,
    status: String,
    materials: Vec<u32>,
}

fn poc08_incident_load_exposure() -> Result<Vec<Poc08IncidentExposure>, String> {
    let dir = poc08_incident_state_dir();
    let Ok(entries) = std::fs::read_dir(&dir) else { return Ok(Vec::new()); };
    let mut states = std::collections::HashMap::<String, Poc08IncidentExposure>::new();
    for ent in entries.flatten() {
        let path = ent.path();
        if path.extension().and_then(|x| x.to_str()) != Some("csv") { continue; }
        let text = std::fs::read_to_string(&path)
            .map_err(|e| format!("DE risk state read failed path={path:?}: {e}"))?;
        let line = text.lines().nth(1).ok_or_else(|| format!("DE risk state partial file path={path:?}"))?;
        let c = line.split(',').collect::<Vec<_>>();
        if c.len() != 11 || c[0] != "1" { return Err(format!("DE risk state schema invalid path={path:?}")); }
        let materials = if c[10].trim().is_empty() { Vec::new() } else {
            c[10].split('|').map(|x| x.parse::<u32>().map_err(|e| format!("DE risk material parse: {e}"))).collect::<Result<Vec<_>,_>>()?
        };
        let e = Poc08IncidentExposure {
            reservation_id: c[1].to_string(),
            unix_s: c[2].parse().map_err(|e| format!("DE risk unix parse: {e}"))?,
            session_id: c[3].to_string(),
            price_epoch: c[4].parse().map_err(|e| format!("DE risk epoch parse: {e}"))?,
            auction_id: c[5].parse().map_err(|e| format!("DE risk auction parse: {e}"))?,
            item_id: c[6].parse().map_err(|e| format!("DE risk item parse: {e}"))?,
            deid: c[7].parse().map_err(|e| format!("DE risk deid parse: {e}"))?,
            buyout: c[8].parse().map_err(|e| format!("DE risk buyout parse: {e}"))?,
            status: c[9].to_string(),
            materials,
        };
        let replace = match states.get(&e.reservation_id) {
            None => true,
            Some(old) => old.status != "CONFIRMED" && e.status == "CONFIRMED",
        };
        if replace { states.insert(e.reservation_id.clone(), e); }
    }
    Ok(states.into_values().collect())
}

fn poc08_incident_reserve_de(auction_id: u32, item_id: u32, deid: u32, buyout: u32) -> Result<String, String> {
    if env::var("WOW112_DE_MUTATION_ENABLED").unwrap_or_default() != "YES" {
        return Err("POC08 DE mutation blocked: WOW112_DE_MUTATION_ENABLED must equal YES".to_string());
    }
    if deid == 0 || buyout == 0 { return Err("POC08 DE risk controller invalid target".to_string()); }
    let now = poc08_incident_now_unix();
    let epoch_s = u64::from(poc07_env_u32_default("WOW112_DE_PRICE_EPOCH_S", 900)?.max(60));
    let epoch = now / epoch_s;
    let session = poc08_incident_session_id().replace(',', "_");
    let rolling_s = u64::from(poc07_env_u32_default("WOW112_DE_EXPOSURE_WINDOW_S", 86_400)?.max(3600));
    let session_cap = u64::from(poc07_env_u32_default("WOW112_DE_SESSION_SPEND_CAP", 100_000)?);
    let rolling_cap = u64::from(poc07_env_u32_default("WOW112_DE_ROLLING_SPEND_CAP", 200_000)?);
    let deid_cap = u64::from(poc07_env_u32_default("WOW112_DE_PER_DEID_EXPOSURE_CAP", 50_000)?);
    let material_cap = u64::from(poc07_env_u32_default("WOW112_DE_PER_MATERIAL_EXPOSURE_CAP", 50_000)?);
    let max_epoch_buys = u64::from(poc07_env_u32_default("WOW112_DE_MAX_BUYS_PER_EPOCH", 3)?.max(1));

    let outcomes = poc08_discrete_de_outcomes(deid).ok_or_else(|| format!("POC08 DE risk controller missing discrete outcomes DEID={deid}"))?;
    let mut materials = outcomes.iter().map(|o| o.material_id).collect::<Vec<_>>();
    materials.sort_unstable();
    materials.dedup();

    let active = poc08_incident_load_exposure()?;
    let active = active.into_iter().filter(|e| now.saturating_sub(e.unix_s) <= rolling_s && (e.status == "UNKNOWN" || e.status == "CONFIRMED")).collect::<Vec<_>>();
    let session_spend: u64 = active.iter().filter(|e| e.session_id == session).map(|e| u64::from(e.buyout)).sum();
    let rolling_spend: u64 = active.iter().map(|e| u64::from(e.buyout)).sum();
    let deid_spend: u64 = active.iter().filter(|e| e.deid == deid).map(|e| u64::from(e.buyout)).sum();
    let epoch_buys = active.iter().filter(|e| e.price_epoch == epoch).count() as u64;

    if session_spend.saturating_add(u64::from(buyout)) > session_cap { return Err("POC08 DE risk block: SESSION_SPEND_CAP".to_string()); }
    if rolling_spend.saturating_add(u64::from(buyout)) > rolling_cap { return Err("POC08 DE risk block: ROLLING_SPEND_CAP".to_string()); }
    if deid_spend.saturating_add(u64::from(buyout)) > deid_cap { return Err(format!("POC08 DE risk block: DEID_EXPOSURE_CAP deid={deid}")); }
    if epoch_buys >= max_epoch_buys { return Err(format!("POC08 DE risk block: MAX_BUYS_PER_PRICE_EPOCH epoch={epoch}")); }
    for material in &materials {
        let exposed: u64 = active.iter().filter(|e| e.materials.contains(material)).map(|e| u64::from(e.buyout)).sum();
        if exposed.saturating_add(u64::from(buyout)) > material_cap {
            return Err(format!("POC08 DE risk block: MATERIAL_EXPOSURE_CAP material_id={material}"));
        }
    }

    let reservation_id = format!("{}-{}-{}-{}", now, std::process::id(), auction_id, item_id);
    let mats = materials.iter().map(|x| x.to_string()).collect::<Vec<_>>().join("|");
    let row = format!("1,{},{},{},{},{},{},{},{},UNKNOWN,{}", reservation_id, now, session, epoch, auction_id, item_id, deid, buyout, mats);
    poc08_incident_write_event("unknown", &reservation_id, &row)?;
    println!("[POC08-DE-RISK] RESERVE status=UNKNOWN reservation_id={} auction_id={} item_id={} deid={} buyout={} session_spend_before={} rolling_spend_before={} epoch_buys_before={} materials={}", reservation_id, auction_id, item_id, deid, buyout, session_spend, rolling_spend, epoch_buys, mats);
    Ok(reservation_id)
}

fn poc08_incident_confirm_de(reservation_id: &str, auction_id: u32, item_id: u32, deid: u32, buyout: u32) -> Result<(), String> {
    let now = poc08_incident_now_unix();
    let epoch_s = u64::from(poc07_env_u32_default("WOW112_DE_PRICE_EPOCH_S", 900)?.max(60));
    let epoch = now / epoch_s;
    let session = poc08_incident_session_id().replace(',', "_");
    let outcomes = poc08_discrete_de_outcomes(deid).ok_or_else(|| format!("missing DE outcomes DEID={deid}"))?;
    let mut materials = outcomes.iter().map(|o| o.material_id).collect::<Vec<_>>();
    materials.sort_unstable(); materials.dedup();
    let mats = materials.iter().map(|x| x.to_string()).collect::<Vec<_>>().join("|");
    let row = format!("1,{},{},{},{},{},{},{},{},CONFIRMED,{}", reservation_id, now, session, epoch, auction_id, item_id, deid, buyout, mats);
    poc08_incident_write_event("confirmed", reservation_id, &row)?;
    println!("[POC08-DE-RISK] CONFIRMED reservation_id={}", reservation_id);
    Ok(())
}
'''
s = s[:idx] + helpers + s[idx:]

needle = '''            let (expect_auction, expect_item, expect_buyout, expect_count) = poc08_f2_expected_de_target()?;\n'''
insert = '''            let (expect_auction, expect_item, expect_buyout, expect_count) = poc08_f2_expected_de_target()?;\n            let max_candidates = poc07_env_u32_default("WOW112_DE_MAX_ELIGIBLE_CANDIDATES", 20)? as usize;\n            let de_population = f0.iter().filter(|c| c.de_risk_pass && c.safe_de_ev > 0).count();\n            if de_population > max_candidates {\n                return Err(format!("POC08 DE risk block: CANDIDATE_EXPLOSION eligible={} max={}", de_population, max_candidates));\n            }\n'''
if s.count(needle) != 1:
    raise SystemExit(f'incident risk candidate marker mismatch count={s.count(needle)}')
s = s.replace(needle, insert, 1)

old_buy = r'''    let buy_candidate = poc08_f1_as_poc07(selected);
    println!("[POC08-F2] PRE-BUY guard=audited-exact-tuple+fresh-page+exact-auction-id+exact-item-id+exact-count+exact-buyout no_auto_retry_after_send=YES");
    poc07_buy_exact_one(
        stream,
        &mut crypto,
        auctioneer_guid,
        auction_house,
        mailbox_guid,
        buy_candidate,
        ah_mutation_committed,
    )?;
    println!("[POC08-F2] LIVE BUY-ONE PASS purchases=1 action={:?}", f1_action);
'''
new_buy = r'''    let buy_candidate = poc08_f1_as_poc07(selected);
    println!("[POC08-F2] PRE-BUY guard=audited-exact-tuple+fresh-page+exact-auction-id+exact-item-id+exact-count+exact-buyout+incident-risk-controller no_auto_retry_after_send=YES");
    let de_reservation = if matches!(f1_action, Poc08F1Action::DeWhitelist) {
        Some(poc08_incident_reserve_de(selected.record.auction_id, selected.record.item_id, selected.disenchant_id, selected.record.buyout)?)
    } else { None };
    poc07_buy_exact_one(
        stream,
        &mut crypto,
        auctioneer_guid,
        auction_house,
        mailbox_guid,
        buy_candidate,
        ah_mutation_committed,
    )?;
    if let Some(reservation_id) = de_reservation.as_deref() {
        poc08_incident_confirm_de(reservation_id, selected.record.auction_id, selected.record.item_id, selected.disenchant_id, selected.record.buyout)?;
    }
    println!("[POC08-F2] LIVE BUY-ONE PASS purchases=1 action={:?}", f1_action);
'''
if s.count(old_buy) != 1:
    raise SystemExit(f'incident risk prebuy marker mismatch count={s.count(old_buy)}')
s = s.replace(old_buy, new_buy, 1)

for m in [
    'WOW112_DE_MUTATION_ENABLED', 'SESSION_SPEND_CAP', 'ROLLING_SPEND_CAP',
    'MATERIAL_EXPOSURE_CAP', 'DEID_EXPOSURE_CAP', 'MAX_BUYS_PER_PRICE_EPOCH',
    'CANDIDATE_EXPLOSION', 'status=UNKNOWN', 'incident-risk-controller'
]:
    if m not in s:
        raise SystemExit('incident risk required marker missing: ' + m)

p.write_text(s, encoding='utf-8')
print('[POC08-INCIDENT-RISK] PASS persistent-exposure unknown-reservation epoch-cap candidate-breaker prebuy-check')
