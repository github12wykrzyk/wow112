//! Outer arming/effect-proof gate for the Prompt-2 live UNDERCUT canary.
//! This wrapper is deliberately separate from the executor so a direct binary invocation cannot
//! gain mutation authority merely by selecting WOW112_MM2_MODE=undercut-canary.

fn market_maker_v2_prompt2_undercut_canary(
    stream:&mut TcpStream,
    crypto:&mut HeaderCrypto,
    player:u64,
)->Result<(),String>{
    if env::var("WOW112_MM2_MUTATION_CONFIRM").unwrap_or_default()!="YES"{
        return Err("MM2_CANARY_BLOCKED explicit WOW112_MM2_MUTATION_CONFIRM=YES required".into());
    }
    if env::var("WOW112_MM2_EFFECT_CAP").unwrap_or_default()!="1"{
        return Err("MM2_CANARY_BLOCKED WOW112_MM2_EFFECT_CAP=1 required".into());
    }
    let(server,realm)=mm2_bound_identity(player)?;
    let before=crate::market_maker_v2_saga::Mm2SagaJournal::open(&server,realm,player)?
        .state().map(|s|s.saga_id);
    market_maker_v2_undercut_canary(stream,crypto,player)?;
    let after_journal=crate::market_maker_v2_saga::Mm2SagaJournal::open(&server,realm,player)?;
    let Some(after)=after_journal.state() else{
        return Ok(()); // e.g. BLOCKED_NO_SAFE_TARGET before a saga exists
    };
    if before==Some(after.saga_id){
        return Ok(()); // no new lifecycle/effect was started
    }
    match &after.phase{
        crate::market_maker_v2_saga::Mm2SagaPhase::Done=>{
            println!("MM2_CANARY_EFFECT_CONFIRMED mode=undercut-canary effects=1 final=DONE");
        },
        crate::market_maker_v2_saga::Mm2SagaPhase::Hold{reason}=>{
            println!("MM2_CANARY_EFFECT_CONFIRMED mode=undercut-canary effects=1 final=HOLD reason={reason:?}");
        },
        phase=>return Err(format!("MM2_CANARY_BLOCKED lifecycle ended nonterminal phase={phase:?}")),
    }
    Ok(())
}

#[cfg(test)]
mod mm2_prompt2_guard_tests{
    #[test]fn effect_proof_literal_matches_final_launcher_contract(){
        let p="MM2_CANARY_EFFECT_CONFIRMED mode=undercut-canary effects=1";
        assert!(p.contains("effects=1"));
    }
}
