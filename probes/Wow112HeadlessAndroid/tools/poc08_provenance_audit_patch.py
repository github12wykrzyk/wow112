from pathlib import Path
import sys

if len(sys.argv) != 3:
    raise SystemExit('usage: poc08_provenance_audit_patch.py INPUT_POC08D OUTPUT_POC08E')

src = Path(sys.argv[1]).read_text(encoding='utf-8')

marker = '#[derive(Debug, Clone, Copy, PartialEq, Eq)]\nenum Poc08Exit {'
idx = src.index(marker)
helpers = r'''
fn poc08_export_de_provenance(item_ids: &[u32]) -> Result<(), String> {
    let path = env::var("WOW112_DE_PROVENANCE_EXPORT")
        .unwrap_or_else(|_| "POC08_E_DE_PROVENANCE.csv".to_string());
    let mut csv = String::from("item_id,disenchant_id,source,source_confidence,positive,authoritative\n");
    let mut deid_unknown = 0usize;
    let mut zero = 0usize;
    let mut positive = 0usize;
    let mut source_unknown = 0usize;
    let mut octo_web = 0usize;
    let mut capy = 0usize;
    let mut legacy = 0usize;
    let mut positive_octo_web = 0usize;
    let mut positive_external_reference = 0usize;
    let mut authoritative = 0usize;

    for item_id in item_ids.iter().copied() {
        let deid = poc08_exact_disenchant_id(item_id);
        let source = poc08_de_source(item_id).unwrap_or("UNKNOWN");
        let confidence = poc08_de_source_confidence(item_id);
        let is_authoritative = confidence >= 3;
        match source {
            "OctoWow" => octo_web += 1,
            "CapyDB" => capy += 1,
            "SeedLegacy" => legacy += 1,
            _ => source_unknown += 1,
        }
        match deid {
            None => deid_unknown += 1,
            Some(0) => zero += 1,
            Some(_) => {
                positive += 1;
                if source == "OctoWow" {
                    positive_octo_web += 1;
                } else {
                    positive_external_reference += 1;
                }
                if is_authoritative { authoritative += 1; }
            }
        }
        csv.push_str(&format!(
            "{},{},{},{},{},{}\n",
            item_id,
            deid.map(|v| v.to_string()).unwrap_or_else(|| "UNKNOWN".to_string()),
            source,
            confidence,
            matches!(deid, Some(id) if id > 0),
            is_authoritative,
        ));
    }
    std::fs::write(&path, csv.as_bytes())
        .map_err(|e| format!("POC08-E provenance export failed path={path:?}: {e}"))?;
    println!(
        "[POC08-E-PROVENANCE] ITEMS total={} positive={} zero={} deid_unknown={} source_unknown={} source_octo_web={} source_capy={} source_legacy={} positive_octo_web={} positive_external_reference={} positive_authoritative={} export={:?}",
        item_ids.len(), positive, zero, deid_unknown, source_unknown, octo_web,
        capy, legacy, positive_octo_web, positive_external_reference,
        authoritative, path
    );
    Ok(())
}

fn poc08_audit_candidate_provenance(candidates: &[Poc08EconomyCandidate]) {
    let mut vendor = 0usize;
    let mut de = 0usize;
    let mut de_octo_web = 0usize;
    let mut de_capy = 0usize;
    let mut de_legacy = 0usize;
    let mut de_unknown = 0usize;
    let mut de_risk_plus_authoritative_deid = 0usize;

    for c in candidates {
        match c.chosen_exit {
            Poc08Exit::Vendor => vendor += 1,
            Poc08Exit::Disenchant => {
                de += 1;
                let source = poc08_de_source(c.record.item_id).unwrap_or("UNKNOWN");
                match source {
                    "OctoWow" => de_octo_web += 1,
                    "CapyDB" => de_capy += 1,
                    "SeedLegacy" => de_legacy += 1,
                    _ => de_unknown += 1,
                }
                if c.de_risk_pass && poc08_de_source_confidence(c.record.item_id) >= 3 {
                    de_risk_plus_authoritative_deid += 1;
                }
            }
        }
    }
    println!(
        "[POC08-E-PROVENANCE] CANDIDATES total={} vendor={} de={} de_octo_web={} de_capy={} de_legacy={} de_unknown={} de_risk_plus_authoritative_deid={} distribution_octowow_verified=NO mutation_ready=0",
        candidates.len(), vendor, de, de_octo_web, de_capy, de_legacy, de_unknown,
        de_risk_plus_authoritative_deid
    );
}

'''
src = src[:idx] + helpers + src[idx:]

needle = '    let item_ids = item_ids.into_iter().collect::<Vec<_>>();\n'
if needle not in src:
    raise SystemExit('POC08-E item_ids marker not found')
src = src.replace(needle, needle + '    poc08_export_de_provenance(&item_ids)?;\n', 1)

# Diagnostic only: POC08-E does not modify D valuation/risk decisions.
# Future BUY requires both authoritative DEID evidence and an Octo-validated
# output distribution. Neither requirement is satisfied by this artifact.
engine = '    println!("[POC08-D] ENGINE PASS mode=DiscreteRiskGateAudit mutation=DISABLED zero_candidates_is_pass=YES");'
if engine not in src:
    raise SystemExit('POC08-E D engine marker not found')
src = src.replace(
    engine,
    '    poc08_audit_candidate_provenance(&economy_candidates);\n    println!("[POC08-E] ENGINE PASS mode=ProvenanceAudit mutation=DISABLED zero_candidates_is_pass=YES authoritative_deid_required_for_future_buy=YES distribution_octowow_verified=NO");',
    1,
)

src = src.replace('[POC08-D] COMBINED AUDIT', '[POC08-E] COMBINED AUDIT', 1)
src = src.replace('[POC08-D] NO_CANDIDATE_PASS', '[POC08-E] NO_CANDIDATE_PASS', 1)
src = src.replace('[POC08-D] CANDIDATE AUDIT PASS', '[POC08-E] CANDIDATE AUDIT PASS', 1)
src = src.replace('[POC08-D] REAL COMBINED RISK SCAN-ONLY PASS', '[POC08-E] REAL COMBINED PROVENANCE SCAN-ONLY PASS', 1)

Path(sys.argv[2]).write_text(src, encoding='utf-8')
print('[POC08-E-PATCH] PASS provenance audit generated; current web/legacy sources cannot authorize DE BUY')
