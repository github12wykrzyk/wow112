from pathlib import Path
import sys

if len(sys.argv) != 3:
    raise SystemExit('usage: poc07_de_v5_patch.py INPUT_V4 OUTPUT_V5')

src = Path(sys.argv[1]).read_text(encoding='utf-8')
marker = 'pub fn login_poc07_delive_v4('
idx = src.index(marker)
helpers = r'''
fn poc07_de_export_candidates_v5(candidates: &[Poc07Candidate]) -> Result<String, String> {
    let path = env::var("WOW112_DE_CANDIDATE_EXPORT")
        .unwrap_or_else(|_| "/data/local/tmp/poc07_de_v5_candidates.csv".to_string());
    let mut csv = String::from("rank,auction_id,item_id,count,buyout,unit_value,gross_value,expected_profit,page,owner_guid\n");
    let mut unique_ids = HashSet::<u32>::new();
    for (rank, candidate) in candidates.iter().enumerate() {
        unique_ids.insert(candidate.record.item_id);
        csv.push_str(&format!(
            "{rank},{},{},{},{},{},{},{},{},{}\n",
            candidate.record.auction_id,
            candidate.record.item_id,
            candidate.record.count,
            candidate.record.buyout,
            candidate.unit_value,
            candidate.gross_value,
            candidate.expected_profit,
            candidate.page,
            candidate.record.owner_guid,
        ));
    }
    std::fs::write(&path, csv.as_bytes())
        .map_err(|e| format!("V5 candidate export failed path={path:?}: {e}"))?;
    println!(
        "[POC07-DE-V5] CANDIDATE EXPORT PASS path={} rows={} unique_items={} format=csv",
        path,
        candidates.len(),
        unique_ids.len()
    );
    Ok(path)
}

'''
out = src[:idx] + helpers + src[idx:]
out = out.replace('pub fn login_poc07_delive_v4(', 'pub fn login_poc07_delive_v5(', 1)
out = out.replace('POC07-DE-LIVE-V4 is hard read-only; BUY is disabled in this build', 'POC07-DE-LIVE-V5 is hard read-only; BUY is disabled in this build', 1)
out = out.replace('[POC07-DE-V4]', '[POC07-DE-V5]')
old = '''    poc07_print_candidates(&candidates);\n    println!("[POC07-DE-V5] CANDIDATE SAFETY disenchant_id_gate=UNVERIFIED all_candidates=READ_ONLY_NO_BUY");\n    println!("[POC07-DE-V5] REAL DE SCAN-ONLY PASS no_mutation=YES");'''
new = '''    poc07_print_candidates(&candidates);\n    let export_path = poc07_de_export_candidates_v5(&candidates)?;\n    println!("[POC07-DE-V5] CANDIDATE SAFETY disenchant_id_gate=EXTERNAL_OCTO_DB_REQUIRED export_path={} all_candidates=READ_ONLY_NO_BUY", export_path);\n    println!("[POC07-DE-V5] REAL DE SCAN-ONLY PASS no_mutation=YES");'''
if old not in out:
    raise SystemExit('candidate tail marker not found')
out = out.replace(old, new, 1)
Path(sys.argv[2]).write_text(out, encoding='utf-8')
