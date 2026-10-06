from pathlib import Path
import sys
if len(sys.argv)!=3: raise SystemExit('usage: INPUT OUTPUT')
s=Path(sys.argv[1]).read_text(encoding='utf-8')
def rep(a,b,label):
 n=s.count(a)
 if n!=1: raise SystemExit(f'{label}: expected1 got{n}')
 return s.replace(a,b,1)
s=rep('''enum Poc08F1Action {\n    Audit,\n    VendorSmoke,\n    DeWhitelist,\n}''','''enum Poc08F1Action {\n    Audit,\n    AutoBest,\n    VendorBest,\n    DeBest,\n    DeWhitelist,\n}''','enum')
s=rep('''    match raw.trim().to_ascii_lowercase().as_str() {\n        "" | "audit" | "scan" | "read-only" | "readonly" => Ok(Poc08F1Action::Audit),\n        "vendor" | "vendor-smoke" => Ok(Poc08F1Action::VendorSmoke),\n        "de" | "de-whitelist" => Ok(Poc08F1Action::DeWhitelist),\n        _ => Err(format!("unsupported WOW112_F1_ACTION={raw:?}")),\n    }''','''    match raw.trim().to_ascii_lowercase().as_str() {\n        "" | "audit" | "scan" | "read-only" | "readonly" => Ok(Poc08F1Action::Audit),\n        "auto" | "both" | "best" | "vendor+de" | "vendor-de" => Ok(Poc08F1Action::AutoBest),\n        "vendor" | "vendor-best" | "vendor-smoke" => Ok(Poc08F1Action::VendorBest),\n        "de" | "disenchant" | "de-best" => Ok(Poc08F1Action::DeBest),\n        "de-whitelist" | "de-exact" => Ok(Poc08F1Action::DeWhitelist),\n        _ => Err(format!("unsupported WOW112_F1_ACTION={raw:?}")),\n    }''','parser')
s=rep('''fn poc08_f1_as_poc07(c: &Poc08EconomyCandidate) -> Poc07Candidate {\n    let (strategy, unit_value, expected_profit) = match c.chosen_exit {''','''fn poc08_f1_as_poc07(c: &Poc08EconomyCandidate, route: Poc08Exit) -> Poc07Candidate {\n    let (strategy, unit_value, expected_profit) = match route {''','route')
s=rep('''    let mut csv = String::from("rank,auction_id,item_id,buyout,safe_de_ev,de_profit,de_roi_bps,de_ploss_bps,heuristic_ev,reference_ev,agreement_bps,source,vendor_profit,disenchant_id\\n");''','''    let mut csv = String::from("rank,auction_id,item_id,buyout,page,safe_de_ev,de_profit,de_roi_bps,de_ploss_bps,heuristic_ev,reference_ev,agreement_bps,source,vendor_profit,disenchant_id\\n");''','eligible csv header')
s=rep('''        csv.push_str(&format!("{},{},{},{},{},{},{},{},{},{},{},{},{},{}\\n", rank,c.record.auction_id,c.record.item_id,c.record.buyout,c.safe_de_ev,c.de_profit,c.de_roi_bps,c.de_ploss_bps,c.heuristic_de_ev,c.reference_de_ev,poc08_f0_model_agreement_bps(c.heuristic_de_ev,c.reference_de_ev),poc08_de_source(c.record.item_id).unwrap_or("UNKNOWN"),c.vendor_profit,c.disenchant_id));''','''        csv.push_str(&format!("{},{},{},{},{},{},{},{},{},{},{},{},{},{},{}\\n", rank,c.record.auction_id,c.record.item_id,c.record.buyout,c.page,c.safe_de_ev,c.de_profit,c.de_roi_bps,c.de_ploss_bps,c.heuristic_de_ev,c.reference_de_ev,poc08_f0_model_agreement_bps(c.heuristic_de_ev,c.reference_de_ev),poc08_de_source(c.record.item_id).unwrap_or("UNKNOWN"),c.vendor_profit,c.disenchant_id));''','eligible csv row')
a=s.find('    let f1_action = poc08_f1_action()?;\n')
b=s.find('\n// BUY primitive contract: NO_AUTO_RETRY_FROM_THIS_POINT=YES (poc07_buy_exact_one)',a)
if a<0 or b<0: raise SystemExit('tail markers')
tail=r'''    let f1_action=poc08_f1_action()?;
    if matches!(f1_action,Poc08F1Action::Audit){println!("[POC08-UNIFIED] AUDIT PASS mutation=DISABLED full_ah=YES");return Ok(());}
    poc08_f1_live_confirm()?;
    let max_buy=poc07_env_u32_default("WOW112_F1_HARD_MAX_SINGLE_BUYOUT",150_000)?;
    let min_vendor=i64::from(poc07_env_u32_default("WOW112_F1_MIN_VENDOR_PROFIT",1)?);
    let max_disagree=poc07_env_u32_default("WOW112_F1_DE_MAX_MODEL_DISAGREEMENT_BPS",0)?;
    let in_f0=|c:&Poc08EconomyCandidate|f0.iter().any(|x|x.record.auction_id==c.record.auction_id&&x.record.item_id==c.record.item_id&&x.record.count==c.record.count&&x.record.buyout==c.record.buyout);
    let vendor_ok=|c:&Poc08EconomyCandidate|c.record.buyout>0&&c.record.buyout<=max_buy&&c.vendor_unit>0&&c.vendor_profit>=min_vendor;
    let de_ok=|c:&Poc08EconomyCandidate|c.record.count==1&&c.record.buyout>0&&c.record.buyout<=max_buy&&c.disenchant_id>0&&c.de_risk_pass&&c.safe_de_ev>0&&in_f0(c)&&(poc08_de_source_confidence(c.record.item_id)>=2||(poc08_de_source(c.record.item_id)==Some("CapyDB")&&poc08_f0_model_agreement_bps(c.heuristic_de_ev,c.reference_de_ev)==0))&&poc08_f0_model_agreement_bps(c.heuristic_de_ev,c.reference_de_ev)<=max_disagree;
    let selection:Option<(Poc08Exit,&Poc08EconomyCandidate)>=match f1_action{
        Poc08F1Action::Audit=>unreachable!(),
        Poc08F1Action::AutoBest|Poc08F1Action::VendorBest|Poc08F1Action::DeBest=>{
            let mut r=Vec::<(Poc08Exit,&Poc08EconomyCandidate,i64)>::new();
            for c in economy_candidates.iter(){if !matches!(f1_action,Poc08F1Action::DeBest)&&vendor_ok(c){r.push((Poc08Exit::Vendor,c,c.vendor_profit));}if !matches!(f1_action,Poc08F1Action::VendorBest)&&de_ok(c){r.push((Poc08Exit::Disenchant,c,c.de_profit));}}
            r.sort_by(|a,b|{let at=if matches!(a.0,Poc08Exit::Vendor){0u8}else{1u8};let bt=if matches!(b.0,Poc08Exit::Vendor){0u8}else{1u8};b.2.cmp(&a.2).then_with(||at.cmp(&bt)).then_with(||a.1.record.buyout.cmp(&b.1.record.buyout)).then_with(||a.1.record.auction_id.cmp(&b.1.record.auction_id))});
            println!("[POC08-UNIFIED] LIVE ROUTES action={:?} eligible={} vendor={} de={} order=PROFIT_DESC_VENDOR_TIE",f1_action,r.len(),r.iter().filter(|x|matches!(x.0,Poc08Exit::Vendor)).count(),r.iter().filter(|x|matches!(x.0,Poc08Exit::Disenchant)).count());
            r.first().map(|(route,c,_)|(*route,*c))
        },
        Poc08F1Action::DeWhitelist=>{
            let wl=poc08_f1_item_whitelist()?;if wl.is_empty(){return Err("POC08-F2 DE exact blocked: whitelist empty".to_string());}
            let(ea,ei,eb,ec)=poc08_f2_expected_de_target()?;if !wl.contains(&ei){return Err(format!("POC08-F2 exact DE blocked: item_id={ei} outside whitelist"));}
            match economy_candidates.iter().find(|c|c.record.auction_id==ea&&c.record.item_id==ei&&c.record.buyout==eb&&c.record.count==ec&&wl.contains(&c.record.item_id)&&de_ok(c)){Some(c)=>Some((Poc08Exit::Disenchant,c)),None=>return Err(format!("POC08_F2_EXACT_DE_TARGET_NOT_ELIGIBLE no purchase sent auction_id={ea} item_id={ei} buyout={eb} count={ec}"))}
        }
    };
    let(route,c)=match selection{Some(v)=>v,None=>{println!("[POC08-UNIFIED] NO_ELIGIBLE_LIVE_ROUTE action={:?} mutation=DISABLED status=NORMAL_NOOP",f1_action);return Ok(());}};
    let profit=if matches!(route,Poc08Exit::Vendor){c.vendor_profit}else{c.de_profit};
    println!("[POC08-UNIFIED] SELECT action={:?} route={} auction_id={} item_id={} count={} buyout={} profit={} vendor_profit={} de_profit={} source={} agreement_bps={} hard_max_purchases=1",f1_action,route.as_str(),c.record.auction_id,c.record.item_id,c.record.count,c.record.buyout,profit,c.vendor_profit,c.de_profit,poc08_de_source(c.record.item_id).unwrap_or("N/A"),poc08_f0_model_agreement_bps(c.heuristic_de_ev,c.reference_de_ev));
    let buy=poc08_f1_as_poc07(c,route);
    println!("[POC08-UNIFIED] PRE-BUY guard=full-ah-audited-route+fresh-neighborhood-exact-tuple no_auto_retry_after_send=YES");
    poc07_buy_exact_one(stream,&mut crypto,auctioneer_guid,auction_house,mailbox_guid,buy,ah_mutation_committed)?;
    println!("[POC08-UNIFIED] LIVE BUY-ONE PASS purchases=1 action={:?} route={}",f1_action,route.as_str());
    Ok(())
}
'''
s=s[:a]+tail+s[b:]
for m in ['Poc08F1Action::AutoBest','Poc08F1Action::VendorBest','Poc08F1Action::DeBest','NO_ELIGIBLE_LIVE_ROUTE','PROFIT_DESC_VENDOR_TIE','CapyDB','LIVE BUY-ONE PASS purchases=1','rank,auction_id,item_id,buyout,page,safe_de_ev']:
 if m not in s: raise SystemExit('missing '+m)
vg=s[s.find('let vendor_ok='):s.find('let de_ok=')]
if 'count==1' in vg or 'count == 1' in vg: raise SystemExit('vendor stack gate regression')
dg=s[s.find('let de_ok='):s.find('let selection:')]
for m in ['count==1','de_risk_pass','in_f0(c)','==0']:
 if m not in dg: raise SystemExit('DE gate missing '+m)
Path(sys.argv[2]).write_text(s,encoding='utf-8')
print('[POC08-UNIFIED-ACTION] PASS')
