from pathlib import Path
import re
import sys

if len(sys.argv) != 2:
    raise SystemExit('usage: UNIFIED_RS')

p = Path(sys.argv[1])
s = p.read_text(encoding='utf-8')

if 'fn poc08_load_shared_history_shadow_v1(' not in s:
    marker = 'fn poc08_reference_de_outcomes('
    if s.count(marker) != 1:
        raise SystemExit(f'history shadow helper marker expected 1 got {s.count(marker)}')
    helper = r'''
fn poc08_load_shared_history_shadow_v1() -> (std::collections::HashMap<u32,u32>, String) {
    let Some(path) = env::var("WOW112_SHARED_HISTORY_SHADOW_CSV").ok().filter(|v| !v.trim().is_empty()) else {
        println!("[POC08-HISTORY-SHADOW] disabled reason=WOW112_SHARED_HISTORY_SHADOW_CSV_NOT_SET decision_unchanged=YES");
        return (std::collections::HashMap::new(), "none".to_string());
    };
    let text = match std::fs::read_to_string(&path) {
        Ok(v) => v,
        Err(error) => {
            println!("[POC08-HISTORY-SHADOW] unavailable path={:?} error={:?} decision_unchanged=YES", path, error);
            return (std::collections::HashMap::new(), "unreadable".to_string());
        }
    };
    let mut prices = std::collections::HashMap::<u32,u32>::new();
    let mut view_id = String::from("unknown");
    for (index,line) in text.lines().enumerate() {
        if index == 0 { continue; }
        let cols = line.split(',').collect::<Vec<_>>();
        if cols.len() < 3 { continue; }
        let Ok(item_id) = cols[0].trim().parse::<u32>() else { continue; };
        let Ok(unit_copper) = cols[1].trim().parse::<u32>() else { continue; };
        if item_id == 0 || unit_copper == 0 { continue; }
        if view_id == "unknown" && !cols[2].trim().is_empty() { view_id = cols[2].trim().to_string(); }
        prices.insert(item_id, unit_copper);
    }
    println!("[POC08-HISTORY-SHADOW] LOAD PASS path={:?} materials={} view_id={} decision_unchanged=YES", path, prices.len(), view_id);
    (prices, view_id)
}

'''
    s = s.replace(marker, helper + marker, 1)

if 'stage=DE_EVALUATION_COMPARE' not in s:
    pattern = re.compile(
        r'(?ms)(\s*println!\(\n\s*"\[POC08-C-SAFEEV\] PASS.*?\n\s*\);)'
    )
    match = pattern.search(s)
    if not match:
        raise SystemExit('POC08-C-SAFEEV summary block missing')
    insert = match.group(1) + r'''
    let (history_shadow_mat_prices, history_shadow_view_id) = poc08_load_shared_history_shadow_v1();
    if !history_shadow_mat_prices.is_empty() {
        let mut shadow_compared = 0usize;
        let mut shadow_positive = 0usize;
        for item_id in item_ids.iter().copied() {
            let Some(deid) = poc08_exact_disenchant_id(item_id) else { continue; };
            if deid == 0 { continue; }
            let Some(outcomes) = poc08_reference_de_outcomes(deid) else { continue; };
            shadow_compared += 1;
            let current_safe_ev = safe_de_values.get(&item_id).copied().unwrap_or(0);
            let history_backed_ev = poc08_safe_ev_from_outcomes(&outcomes, &history_shadow_mat_prices, net_bps);
            if history_backed_ev > 0 { shadow_positive += 1; }
            let delta = i64::from(history_backed_ev) - i64::from(current_safe_ev);
            println!("[POC08-HISTORY-SHADOW] stage=DE_EVALUATION_COMPARE item_id={} deid={} current_safe_ev={} history_backed_ev={} delta={} provenance_view_id={} decision_unchanged=YES",
                item_id, deid, current_safe_ev, history_backed_ev, delta, history_shadow_view_id);
        }
        println!("[POC08-HISTORY-SHADOW] stage=SUMMARY compared={} positive_history_ev={} provenance_view_id={} decision_unchanged=YES",
            shadow_compared, shadow_positive, history_shadow_view_id);
    }
'''
    s = s[:match.start()] + insert + s[match.end():]

# A full scan that hits its hard max must close the history segment as truncated.
needle = '    Err(format!("POC08_UNIFIED_FULL_AH_TRUNCATED fail-closed max_pages={max_pages}"))'
if needle in s and 'max_pages_reached' not in s:
    s = s.replace(
        needle,
        '    crate::ah_history_observer::finish_full_best_effort("truncated", "max_pages_reached");\n' + needle,
        1,
    )

for marker in [
    'POC08-HISTORY-SHADOW',
    'WOW112_SHARED_HISTORY_SHADOW_CSV',
    'stage=DE_EVALUATION_COMPARE',
    'decision_unchanged=YES',
    'max_pages_reached',
]:
    if marker not in s:
        raise SystemExit('missing history shadow marker ' + marker)

p.write_text(s, encoding='utf-8')
print('[POC08-HISTORY-SHADOW-V1-PATCH] PASS decision_unchanged=YES full_scan_truncation_closed=YES')
