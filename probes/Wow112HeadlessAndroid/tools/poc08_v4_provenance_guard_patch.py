from pathlib import Path
import sys

if len(sys.argv) != 2:
    raise SystemExit('usage: UNIFIED_RS')

p = Path(sys.argv[1])
s = p.read_text(encoding='utf-8')

old_f0 = '''        if poc08_de_source_confidence(c.record.item_id) == 0 { return false; }
'''
new_f0 = '''        let source_confidence = poc08_de_source_confidence(c.record.item_id);
        let source_is_live_eligible = source_confidence >= 2
            || (poc08_de_source(c.record.item_id) == Some("CapyDB")
                && poc08_f0_model_agreement_bps(c.heuristic_de_ev, c.reference_de_ev) == 0);
        if !source_is_live_eligible { return false; }
'''
if s.count(old_f0) != 1:
    raise SystemExit(f'F0 provenance anchor expected 1 got {s.count(old_f0)}')
s = s.replace(old_f0, new_f0, 1)

old_de = '''    let de_ok=|c:&Poc08EconomyCandidate|c.record.count==1&&c.record.buyout>0&&c.record.buyout<=max_buy&&c.disenchant_id>0&&c.de_risk_pass&&c.safe_de_ev>0&&in_f0(c)&&poc08_de_source_confidence(c.record.item_id)>0&&poc08_f0_liquidation_decision(c).1>=min_live_de_liquidation_profit;
'''
new_de = '''    let de_ok=|c:&Poc08EconomyCandidate|c.record.count==1&&c.record.buyout>0&&c.record.buyout<=max_buy&&c.disenchant_id>0&&c.de_risk_pass&&c.safe_de_ev>0&&in_f0(c)&&(poc08_de_source_confidence(c.record.item_id)>=2||(poc08_de_source(c.record.item_id)==Some("CapyDB")&&poc08_f0_model_agreement_bps(c.heuristic_de_ev,c.reference_de_ev)==0))&&poc08_f0_liquidation_decision(c).1>=min_live_de_liquidation_profit;
'''
if s.count(old_de) != 1:
    raise SystemExit(f'live DE provenance anchor expected 1 got {s.count(old_de)}')
s = s.replace(old_de, new_de, 1)

for marker in [
    'Some("CapyDB")',
    'poc08_de_source_confidence(c.record.item_id)>=2',
    'poc08_f0_model_agreement_bps(c.heuristic_de_ev,c.reference_de_ev)==0',
    'POC08-UNIFIED-V4',
    'WOW112_UNIFIED_VENDOR_MAX_PURCHASES',
    'NO_AUTO_RETRY_FROM_THIS_POINT=YES',
]:
    if marker not in s:
        raise SystemExit('missing V4 provenance marker '+marker)

p.write_text(s, encoding='utf-8')
print('[POC08-V4-PROVENANCE-GUARD] PASS rule=OCTO_CONF_GE2_OR_CAPY_AGREEMENT0 legacy=BLOCKED')
