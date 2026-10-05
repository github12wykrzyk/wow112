from pathlib import Path
import sys

if len(sys.argv) != 3:
    raise SystemExit('usage: poc08_f2_exact_de_patch.py INPUT_F1 OUTPUT_F2')

src = Path(sys.argv[1]).read_text(encoding='utf-8')


def rep(label: str, old: str, new: str) -> None:
    global src
    n = src.count(old)
    if n != 1:
        raise SystemExit(f'POC08-F2 {label} expected=1 actual={n}')
    src = src.replace(old, new, 1)


# F0 currently emits literal backslash-n in its eligible export. F2 PASS 1
# consumes that CSV with PowerShell Import-Csv, so convert exactly those two
# Rust string fragments to real newline escapes in the generated F2 source.
rep('F0 CSV header newline', 'disenchant_id\\\\n");', 'disenchant_id\\n");')
rep('F0 CSV row newline', '{},{}\\\\n", rank,c.record.auction_id', '{},{}\\n", rank,c.record.auction_id')

marker = 'pub fn login_poc08_economy_audit(\n'
idx = src.index(marker)
helpers = r'''
fn poc08_f2_required_u32(name: &str) -> Result<u32, String> {
    let raw = env::var(name).map_err(|_| format!("POC08-F2 exact DE blocked: missing {name}"))?;
    let value = raw.trim().parse::<u32>()
        .map_err(|e| format!("POC08-F2 exact DE blocked: invalid {name}={raw:?}: {e}"))?;
    if value == 0 {
        return Err(format!("POC08-F2 exact DE blocked: {name} must be >0"));
    }
    Ok(value)
}

fn poc08_f2_expected_de_target() -> Result<(u32, u32, u32, u32), String> {
    let auction_id = poc08_f2_required_u32("WOW112_F2_EXPECT_AUCTION_ID")?;
    let item_id = poc08_f2_required_u32("WOW112_F2_EXPECT_ITEM_ID")?;
    let buyout = poc08_f2_required_u32("WOW112_F2_EXPECT_BUYOUT")?;
    let count = poc08_f2_required_u32("WOW112_F2_EXPECT_COUNT")?;
    if count != 1 {
        return Err(format!("POC08-F2 exact DE blocked: count must equal 1, got {count}"));
    }
    Ok((auction_id, item_id, buyout, count))
}
'''
src = src[:idx] + helpers + src[idx:]

old = r'''        Poc08F1Action::DeWhitelist => {
            let whitelist = poc08_f1_item_whitelist()?;
            if whitelist.is_empty() {
                return Err("POC08-F1 DE live blocked: WOW112_F1_DE_WHITELIST is empty".to_string());
            }
            let mut d = f0.iter().copied().filter(|c| {
                whitelist.contains(&c.record.item_id)
                    && c.record.count == 1
                    && c.record.buyout > 0
                    && c.record.buyout <= f1_hard_max_buyout
                    && c.de_risk_pass
                    && c.safe_de_ev > 0
                    && poc08_f0_model_agreement_bps(c.heuristic_de_ev, c.reference_de_ev) <= f1_de_max_disagreement_bps
            }).collect::<Vec<_>>();
            d.sort_by(|a,b| b.de_profit.cmp(&a.de_profit)
                .then_with(|| a.record.buyout.cmp(&b.record.buyout))
                .then_with(|| a.record.auction_id.cmp(&b.record.auction_id)));
            let c = *d.first().ok_or_else(|| "POC08_F1_NO_WHITELISTED_DE_CANDIDATE no purchase sent".to_string())?;
            println!("[POC08-F1] SELECT action=DE_WHITELIST auction_id={} item_id={} count={} buyout={} safe_ev={} de_profit={} roi_bps={} ploss_bps={} agreement_bps={} source={} whitelist_size={} hard_max_buyout={} hard_max_purchases=1", c.record.auction_id,c.record.item_id,c.record.count,c.record.buyout,c.safe_de_ev,c.de_profit,c.de_roi_bps,c.de_ploss_bps,poc08_f0_model_agreement_bps(c.heuristic_de_ev,c.reference_de_ev),poc08_de_source(c.record.item_id).unwrap_or("UNKNOWN"),whitelist.len(),f1_hard_max_buyout);
            c
        }
'''
new = r'''        Poc08F1Action::DeWhitelist => {
            let whitelist = poc08_f1_item_whitelist()?;
            if whitelist.is_empty() {
                return Err("POC08-F2 DE live blocked: WOW112_F1_DE_WHITELIST is empty".to_string());
            }
            let (expect_auction, expect_item, expect_buyout, expect_count) = poc08_f2_expected_de_target()?;
            if !whitelist.contains(&expect_item) {
                return Err(format!("POC08-F2 exact DE blocked: expected item_id={} is outside whitelist", expect_item));
            }
            let mut d = f0.iter().copied().filter(|c| {
                c.record.auction_id == expect_auction
                    && c.record.item_id == expect_item
                    && c.record.buyout == expect_buyout
                    && c.record.count == expect_count
                    && whitelist.contains(&c.record.item_id)
                    && c.record.count == 1
                    && c.record.buyout > 0
                    && c.record.buyout <= f1_hard_max_buyout
                    && c.de_risk_pass
                    && c.safe_de_ev > 0
                    && poc08_f0_model_agreement_bps(c.heuristic_de_ev, c.reference_de_ev) <= f1_de_max_disagreement_bps
            }).collect::<Vec<_>>();
            d.sort_by(|a,b| b.de_profit.cmp(&a.de_profit)
                .then_with(|| a.record.buyout.cmp(&b.record.buyout))
                .then_with(|| a.record.auction_id.cmp(&b.record.auction_id)));
            let c = *d.first().ok_or_else(|| format!(
                "POC08_F2_EXACT_DE_TARGET_NOT_ELIGIBLE no purchase sent auction_id={} item_id={} buyout={} count={}",
                expect_auction, expect_item, expect_buyout, expect_count
            ))?;
            println!("[POC08-F2] EXACT AUDIT TARGET PASS auction_id={} item_id={} count={} buyout={} safe_ev={} de_profit={} roi_bps={} ploss_bps={} agreement_bps={} source={} hard_max_buyout={} hard_max_purchases=1", c.record.auction_id,c.record.item_id,c.record.count,c.record.buyout,c.safe_de_ev,c.de_profit,c.de_roi_bps,c.de_ploss_bps,poc08_f0_model_agreement_bps(c.heuristic_de_ev,c.reference_de_ev),poc08_de_source(c.record.item_id).unwrap_or("UNKNOWN"),f1_hard_max_buyout);
            c
        }
'''
rep('exact DE selector', old, new)

src = src.replace(
    '[POC08-F1] PRE-BUY guard=fresh-page+exact-auction-id+exact-item-id+exact-count+exact-buyout no_auto_retry_after_send=YES',
    '[POC08-F2] PRE-BUY guard=audited-exact-tuple+fresh-page+exact-auction-id+exact-item-id+exact-count+exact-buyout no_auto_retry_after_send=YES',
    1,
)
src = src.replace(
    '[POC08-F1] LIVE BUY-ONE PASS purchases=1 action={:?}',
    '[POC08-F2] LIVE BUY-ONE PASS purchases=1 action={:?}',
    1,
)

for required in [
    'WOW112_F2_EXPECT_AUCTION_ID',
    'WOW112_F2_EXPECT_ITEM_ID',
    'WOW112_F2_EXPECT_BUYOUT',
    'WOW112_F2_EXPECT_COUNT',
    '[POC08-F2] EXACT AUDIT TARGET PASS',
    'audited-exact-tuple+fresh-page',
]:
    if required not in src:
        raise SystemExit(f'POC08-F2 required marker missing: {required}')

Path(sys.argv[2]).write_text(src, encoding='utf-8')
print('[POC08-F2-PATCH] PASS exact audited DE target guard + CSV newline fix generated')
