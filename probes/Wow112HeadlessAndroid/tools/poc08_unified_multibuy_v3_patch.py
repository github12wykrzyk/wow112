from pathlib import Path
import sys
if len(sys.argv)!=2: raise SystemExit('usage: UNIFIED_RS')
p=Path(sys.argv[1]); s=p.read_text(encoding='utf-8')
a=s.find('    let f1_action=poc08_f1_action()?;')
b=s.find('\n// BUY primitive contract: NO_AUTO_RETRY_FROM_THIS_POINT=YES (poc07_buy_exact_one)',a)
if a<0 or b<0: raise SystemExit('tail markers')
tail=r'''    let f1_action=poc08_f1_action()?;
    if matches!(f1_action,Poc08F1Action::Audit){println!("[POC08-UNIFIED] AUDIT PASS mutation=DISABLED full_ah=YES");return Ok(());}
    poc08_f1_live_confirm()?;
    let max_buy=poc07_env_u32_default("WOW112_F1_HARD_MAX_SINGLE_BUYOUT",150_000)?;
    let min_vendor=i64::from(poc07_env_u32_default("WOW112_F1_MIN_VENDOR_PROFIT",1)?);
    let max_disagree=poc07_env_u32_default("WOW112_F1_DE_MAX_MODEL_DISAGREEMENT_BPS",0)?;
    let de_limit=poc07_env_u32_default("WOW112_UNIFIED_DE_MAX_PURCHASES",5)?;
    let in_f0=|c:&Poc08EconomyCandidate|f0.iter().any(|x|x.record.auction_id==c.record.auction_id&&x.record.item_id==c.record.item_id&&x.record.count==c.record.count&&x.record.buyout==c.record.buyout);
    let vendor_ok=|c:&Poc08EconomyCandidate|c.record.buyout>0&&c.record.buyout<=max_buy&&c.vendor_unit>0&&c.vendor_profit>=min_vendor;
    let de_ok=|c:&Poc08EconomyCandidate|c.record.count==1&&c.record.buyout>0&&c.record.buyout<=max_buy&&c.disenchant_id>0&&c.de_risk_pass&&c.safe_de_ev>0&&in_f0(c)&&(poc08_de_source_confidence(c.record.item_id)>=2||(poc08_de_source(c.record.item_id)==Some("CapyDB")&&poc08_f0_model_agreement_bps(c.heuristic_de_ev,c.reference_de_ev)==0))&&poc08_f0_model_agreement_bps(c.heuristic_de_ev,c.reference_de_ev)<=max_disagree;
    if matches!(f1_action,Poc08F1Action::DeWhitelist){
        let wl=poc08_f1_item_whitelist()?; if wl.is_empty(){return Err("POC08-F2 DE exact blocked: whitelist empty".to_string());}
        let(ea,ei,eb,ec)=poc08_f2_expected_de_target()?; if !wl.contains(&ei){return Err(format!("POC08-F2 exact DE blocked: item_id={ei} outside whitelist"));}
        let c=match economy_candidates.iter().find(|c|c.record.auction_id==ea&&c.record.item_id==ei&&c.record.buyout==eb&&c.record.count==ec&&wl.contains(&c.record.item_id)&&de_ok(c)){Some(c)=>c,None=>return Err(format!("POC08_F2_EXACT_DE_TARGET_NOT_ELIGIBLE no purchase sent auction_id={ea} item_id={ei} buyout={eb} count={ec}"))};
        let buy=poc08_f1_as_poc07(c,Poc08Exit::Disenchant); poc07_buy_exact_one(stream,&mut crypto,auctioneer_guid,auction_house,mailbox_guid,buy,ah_mutation_committed)?;
        println!("[POC08-UNIFIED] LIVE BUY-ONE PASS purchases=1 action={:?} route=de",f1_action); return Ok(());
    }
    let mut queue=Vec::<(Poc08Exit,&Poc08EconomyCandidate,i64)>::new();
    for c in economy_candidates.iter(){
        let vok=!matches!(f1_action,Poc08F1Action::DeBest)&&vendor_ok(c); let dok=!matches!(f1_action,Poc08F1Action::VendorBest)&&de_ok(c);
        let chosen=match(vok,dok){(true,true)=>if c.vendor_profit>=c.de_profit{Some((Poc08Exit::Vendor,c.vendor_profit))}else{Some((Poc08Exit::Disenchant,c.de_profit))},(true,false)=>Some((Poc08Exit::Vendor,c.vendor_profit)),(false,true)=>Some((Poc08Exit::Disenchant,c.de_profit)),_=>None};
        if let Some((route,profit))=chosen{queue.push((route,c,profit));}
    }
    queue.sort_by(|a,b|{let at=if matches!(a.0,Poc08Exit::Vendor){0u8}else{1u8};let bt=if matches!(b.0,Poc08Exit::Vendor){0u8}else{1u8};b.2.cmp(&a.2).then_with(||at.cmp(&bt)).then_with(||a.1.record.buyout.cmp(&b.1.record.buyout)).then_with(||a.1.record.auction_id.cmp(&b.1.record.auction_id))});
    println!("[POC08-UNIFIED-MULTI] QUEUE action={:?} eligible={} vendor={} de={} de_limit={} vendor_limit=UNLIMITED order=PROFIT_DESC_VENDOR_TIE",f1_action,queue.len(),queue.iter().filter(|x|matches!(x.0,Poc08Exit::Vendor)).count(),queue.iter().filter(|x|matches!(x.0,Poc08Exit::Disenchant)).count(),de_limit);
    if queue.is_empty(){println!("[POC08-UNIFIED] NO_ELIGIBLE_LIVE_ROUTE action={:?} mutation=DISABLED status=NORMAL_NOOP",f1_action);return Ok(());}
    let(mut bought_total,mut bought_vendor,mut bought_de,mut stale_skipped,mut de_limit_skipped)=(0u32,0u32,0u32,0u32,0u32);
    for(rank,(route,c,profit))in queue.iter().enumerate(){
        if matches!(route,Poc08Exit::Disenchant)&&bought_de>=de_limit{de_limit_skipped+=1;continue;}
        println!("[POC08-UNIFIED-MULTI] TRY rank={} route={} auction_id={} item_id={} count={} buyout={} profit={}",rank,route.as_str(),c.record.auction_id,c.record.item_id,c.record.count,c.record.buyout,profit);
        let buy=poc08_f1_as_poc07(c,*route);
        match poc07_buy_exact_one(stream,&mut crypto,auctioneer_guid,auction_house,mailbox_guid,buy,ah_mutation_committed){
            Ok(())=>{bought_total+=1;if matches!(route,Poc08Exit::Vendor){bought_vendor+=1}else{bought_de+=1};*ah_mutation_committed=false;println!("[POC08-UNIFIED-MULTI] CONFIRMED auction_id={} purchases={} vendor={} de={} next_buy_armed=YES",c.record.auction_id,bought_total,bought_vendor,bought_de);},
            Err(error) if error.starts_with("POC07_BUY_TARGET_STALE")=>{*ah_mutation_committed=false;stale_skipped+=1;println!("[POC08-UNIFIED-MULTI] STALE SKIP auction_id={} no_purchase_sent=YES stale_skipped={}",c.record.auction_id,stale_skipped);},
            Err(error)=>return Err(error),
        }
    }
    println!("[POC08-UNIFIED-MULTI] LIVE PASS purchases={} vendor={} de={} stale_skipped={} de_limit_skipped={} vendor_limit=UNLIMITED de_limit={} snapshot_reused=YES",bought_total,bought_vendor,bought_de,stale_skipped,de_limit_skipped,de_limit); Ok(())
}
'''
s=s[:a]+tail+s[b:]
for m in ['POC08-UNIFIED-MULTI','vendor_limit=UNLIMITED','WOW112_UNIFIED_DE_MAX_PURCHASES','POC07_BUY_TARGET_STALE','next_buy_armed=YES','LIVE BUY-ONE PASS purchases=1']:
 if m not in s: raise SystemExit('missing '+m)
p.write_text(s,encoding='utf-8')
print('[POC08-UNIFIED-MULTIBUY-V3] PASS')
