from pathlib import Path
import sys

if len(sys.argv) != 2:
    raise SystemExit('usage: UNIFIED_RS')

p = Path(sys.argv[1])
s = p.read_text(encoding='utf-8')

def rep(label: str, old: str, new: str) -> None:
    global s
    n = s.count(old)
    if n != 1:
        raise SystemExit(f'{label}: expected 1 got {n}')
    s = s.replace(old, new, 1)

old_ids = '''    let (mat_prices, safe_mat_prices, material_confidence) = poc08_collect_material_pricebook(&scanned, player_guid)?;
    let mut item_ids=scanned.iter().filter_map(|(_,r)|if r.buyout==0||r.buyout>max_buyout||r.count==0||blacklist.contains(&r.item_id){None}else{Some(r.item_id)}).collect::<Vec<_>>();
    item_ids.sort_unstable();item_ids.dedup();
    println!("[POC08-UNIFIED] item template valuation start unique_affordable_items={} vendor_scope=ALL de_scope=MODEL_SUPPORTED",item_ids.len());

    let item_query_started = std::time::Instant::now();
'''
new_ids = '''    let (mat_prices, safe_mat_prices, material_confidence) = poc08_collect_material_pricebook(&scanned, player_guid)?;

    // V3.2 FAST: keep the complete AH snapshot for material/depth/history pricing, but do not
    // spend server item-template queries on auctions that cannot enter the DE route anyway.
    // Exact positive DEID is a local O(1) gate. count==1 and buyout/blacklist are already hard
    // live/F0 requirements. Weapon/armor + quality sanity is verified after the reduced template query.
    let de_fast_prefilter = env::var("WOW112_DE_FAST_PREFILTER")
        .map(|v| matches!(v.trim().to_ascii_lowercase().as_str(), "1"|"true"|"yes"|"on"))
        .unwrap_or(false);
    let mut affordable_item_ids=scanned.iter().filter_map(|(_,r)|if r.buyout==0||r.buyout>max_buyout||r.count==0||blacklist.contains(&r.item_id){None}else{Some(r.item_id)}).collect::<Vec<_>>();
    affordable_item_ids.sort_unstable();affordable_item_ids.dedup();
    let affordable_unique=affordable_item_ids.len();
    let mut item_ids = if de_fast_prefilter {
        scanned.iter().filter_map(|(_,r)| {
            if r.buyout==0 || r.buyout>max_buyout || r.count!=1 || blacklist.contains(&r.item_id) { return None; }
            match poc08_exact_disenchant_id(r.item_id) { Some(deid) if deid>0 => Some(r.item_id), _ => None }
        }).collect::<Vec<_>>()
    } else { affordable_item_ids.clone() };
    item_ids.sort_unstable();item_ids.dedup();
    println!("[POC08-DE-FAST-PREFILTER] stage=LOCAL_DEID enabled={} full_snapshot_records={} affordable_unique={} template_query_unique={} skipped_unique={} rule=count1+buyout_cap+positive_exact_deid full_snapshot_preserved=YES",
        de_fast_prefilter, scanned.len(), affordable_unique, item_ids.len(), affordable_unique.saturating_sub(item_ids.len()));
    println!("[POC08-UNIFIED] item template valuation start unique_affordable_items={} vendor_scope={} de_scope=POSITIVE_DEID_THEN_WEAPON_ARMOR_UNCOMMON_PLUS",
        item_ids.len(), if de_fast_prefilter{"DE_SCOPED"}else{"ALL"});

    let item_query_started = std::time::Instant::now();
'''
rep('local DEID prefilter', old_ids, new_ids)

old_loop_tail = '''    let item_query_elapsed = item_query_started.elapsed().as_secs_f64().max(0.001);
    println!("[POC07-DE-V53-TURBO] TEMPLATE STAGE PASS queried={} elapsed_s={:.3} qps={:.1} window={}", item_ids.len(), item_query_elapsed, item_ids.len() as f64 / item_query_elapsed, item_query_window);
    println!("[POC07-DE-V5.3] TEMPLATE+VALUATION PASS queried={} model_supported={} fully_priced={} missing_templates={} material_coverage={}/{}", item_ids.len(), model_supported, priced_supported, missing_templates, mat_prices.len(), POC07_DE_MATERIALS_V4.len());

    let mut reference_de_values = std::collections::HashMap::<u32, u32>::new();
'''
new_loop_tail = '''    let item_query_elapsed = item_query_started.elapsed().as_secs_f64().max(0.001);
    let queried_before_sanity=item_ids.len();
    if de_fast_prefilter {
        item_ids.retain(|item_id| match turbo_infos.get(item_id).copied().flatten() {
            Some(info) => (info.item_class==2 || info.item_class==4) && (2..=4).contains(&info.quality) && poc07_de_outcomes_v4(info).is_some(),
            None => false,
        });
    }
    println!("[POC08-DE-FAST-PREFILTER] stage=TEMPLATE_SANITY enabled={} queried={} retained={} rejected={} rule=weapon_or_armor+quality_2_to_4+model_supported",
        de_fast_prefilter, queried_before_sanity, item_ids.len(), queried_before_sanity.saturating_sub(item_ids.len()));
    println!("[POC07-DE-V53-TURBO] TEMPLATE STAGE PASS queried={} retained={} elapsed_s={:.3} qps={:.1} window={}", queried_before_sanity, item_ids.len(), item_query_elapsed, queried_before_sanity as f64 / item_query_elapsed, item_query_window);
    println!("[POC07-DE-V5.3] TEMPLATE+VALUATION PASS queried={} retained={} model_supported={} fully_priced={} missing_templates={} material_coverage={}/{}", queried_before_sanity, item_ids.len(), model_supported, priced_supported, missing_templates, mat_prices.len(), POC07_DE_MATERIALS_V4.len());

    let mut reference_de_values = std::collections::HashMap::<u32, u32>::new();
'''
rep('template sanity', old_loop_tail, new_loop_tail)

old_vendor_build = '''    poc08_export_de_provenance(&item_ids)?;
    let vendor_values = poc08_query_vendor_values_turbo(
        stream,
        &mut crypto,
        &item_ids,
        item_query_window,
    )?;
    let (economy_candidates, rejected_rows) = poc08_build_combined_decisions(
        &scanned,
        &vendor_values,
'''
new_vendor_build = '''    poc08_export_de_provenance(&item_ids)?;
    let vendor_values = poc08_query_vendor_values_turbo(
        stream,
        &mut crypto,
        &item_ids,
        item_query_window,
    )?;
    let fast_item_set=item_ids.iter().copied().collect::<HashSet<u32>>();
    let fast_scanned = if de_fast_prefilter {
        scanned.iter().copied().filter(|(_,r)| r.count==1 && r.buyout>0 && r.buyout<=max_buyout && fast_item_set.contains(&r.item_id) && !blacklist.contains(&r.item_id)).collect::<Vec<_>>()
    } else { Vec::new() };
    let decision_scanned: &[(u32,Poc06AuctionRecord)] = if de_fast_prefilter { fast_scanned.as_slice() } else { scanned.as_slice() };
    println!("[POC08-DE-FAST-PREFILTER] stage=DECISION_ROWS enabled={} full_snapshot_records={} decision_records={} skipped_records={} material_book_source=FULL_SNAPSHOT",
        de_fast_prefilter, scanned.len(), decision_scanned.len(), scanned.len().saturating_sub(decision_scanned.len()));
    let (economy_candidates, rejected_rows) = poc08_build_combined_decisions(
        decision_scanned,
        &vendor_values,
'''
rep('decision scoped rows', old_vendor_build, new_vendor_build)

old_as = '''fn poc08_f1_as_poc07(c: &Poc08EconomyCandidate, route: Poc08Exit) -> Poc07Candidate {
    let (strategy, unit_value, expected_profit) = match route {
        Poc08Exit::Vendor => (Poc07Strategy::Vendor, c.vendor_unit, c.vendor_profit),
        Poc08Exit::Disenchant => (Poc07Strategy::Disenchant, c.safe_de_ev, c.de_profit),
    };
'''
new_as = '''fn poc08_f1_as_poc07(c: &Poc08EconomyCandidate, route: Poc08Exit) -> Poc07Candidate {
    let (strategy, unit_value, expected_profit) = match route {
        Poc08Exit::Vendor => (Poc07Strategy::Vendor, c.vendor_unit, c.vendor_profit),
        Poc08Exit::Disenchant => {
            let (decision_ev, decision_profit, _decision_roi_bps, _factor_bps)=poc08_f0_liquidation_decision(c);
            (Poc07Strategy::Disenchant, decision_ev, decision_profit)
        },
    };
'''
rep('live logger final liquidation profit', old_as, new_as)

for marker in [
    'POC08-DE-FAST-PREFILTER',
    'WOW112_DE_FAST_PREFILTER',
    'full_snapshot_preserved=YES',
    'rule=weapon_or_armor+quality_2_to_4+model_supported',
    'material_book_source=FULL_SNAPSHOT',
    'poc08_f0_liquidation_decision(c)',
]:
    if marker not in s:
        raise SystemExit('missing marker '+marker)

p.write_text(s, encoding='utf-8')
print('[POC08-DE-FAST-PREFILTER-V32-PATCH] PASS')
