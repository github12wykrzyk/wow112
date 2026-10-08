//! Market Maker V2 pure depth/policy model. No transport or mutation here.

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Quote {
    pub auction_id: u32,
    pub owner_guid: u64,
    pub buyout: u32,
    pub count: u32,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DepthSource { Broad, Targeted }

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DepthView {
    pub source: DepthSource,
    pub complete: bool,
    pub coherent: bool,
    pub age_ms: u64,
    pub own_row_seen: bool,
    pub rows: Vec<Quote>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Floors {
    pub explicit_unit: u32,
    pub economic_unit: u32,
    pub history_unit: Option<u32>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Exposure {
    pub owned_units: u32,
    pub acquired_units: u32,
    pub acquired_spend: u32,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Limits {
    pub ah_cut_bps: u32,
    pub max_depth_age_ms: u64,
    pub max_step_drop_bps: u32,
    pub support_band_bps: u32,
    pub support_min_units: u32,
    pub cliff_min_bps: u32,
    pub max_clear_units: u32,
    pub max_clear_spend: u32,
    pub max_exposure_units: u32,
    pub clear_min_profit: u32,
    pub clear_min_roi_bps: u32,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum BlockReason {
    Invalid,
    NotTargeted,
    Incomplete,
    Stale,
    OwnRowMissing,
    Floor,
    StepDrop,
    ThinFloorUnclearable,
    PrefixTooLarge,
    NoSupportTier,
    Exposure,
    AcquiredLoss,
    Cap,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Decision {
    Keep,
    Block { reason: BlockReason },
    Undercut { target_unit: u32, witness_auction_id: u32, floor_unit: u32 },
    Clear {
        next_buy_auction_id: u32,
        plan_ids: Vec<u32>,
        spend: u32,
        units: u32,
        target_unit: u32,
        expected_acquired_profit: i64,
        roi_bps: u32,
        floor_unit: u32,
    },
}

fn cmp_unit(a:&Quote,b:&Quote)->std::cmp::Ordering {
    (u128::from(a.buyout)*u128::from(b.count)).cmp(&(u128::from(b.buyout)*u128::from(a.count)))
        .then(a.buyout.cmp(&b.buyout)).then(a.auction_id.cmp(&b.auction_id))
}
fn strict_below(q:&Quote)->u32 { if q.buyout==0||q.count==0 {0} else {(q.buyout-1)/q.count} }
fn unit_ceil(q:&Quote)->u32 { if q.count==0 {u32::MAX} else {((u128::from(q.buyout)+u128::from(q.count)-1)/u128::from(q.count)).min(u128::from(u32::MAX)) as u32} }
fn drop_bps(from:u32,to:u32)->u32 { if from==0||to>=from {0} else {((u128::from(from-to)*10000)/u128::from(from)).min(u128::from(u32::MAX)) as u32} }
fn jump_bps(low:u32,high:u32)->u32 { if low==0||high<=low {0} else {((u128::from(high-low)*10000)/u128::from(low)).min(u128::from(u32::MAX)) as u32} }
fn within_band(base:&Quote,q:&Quote,bps:u32)->bool {
    if base.buyout==0||base.count==0||q.buyout==0||q.count==0{return false;}
    let lhs=u128::from(q.buyout)*u128::from(base.count)*10000;
    let rhs=u128::from(base.buyout)*u128::from(q.count)*u128::from(10000u32.saturating_add(bps));
    lhs<=rhs
}
fn effective_floor(f:Floors)->u32 { f.explicit_unit.max(f.economic_unit).max(f.history_unit.unwrap_or(0)).max(1) }

/// Conservative live V2 decision. Portfolio/history uplift is intentionally not credited here;
/// history credit may be computed in shadow telemetry until calibrated.
pub fn decide(
    own:Quote,
    player_guid:u64,
    depth:&DepthView,
    floors:Floors,
    exposure:Exposure,
    limits:Limits,
)->Decision {
    if own.buyout==0||own.count==0||limits.ah_cut_bps>=10000||limits.support_min_units==0||limits.max_clear_units==0 {
        return Decision::Block{reason:BlockReason::Invalid};
    }
    if depth.source!=DepthSource::Targeted {return Decision::Block{reason:BlockReason::NotTargeted};}
    if !depth.complete||!depth.coherent {return Decision::Block{reason:BlockReason::Incomplete};}
    if depth.age_ms>limits.max_depth_age_ms {return Decision::Block{reason:BlockReason::Stale};}
    if !depth.own_row_seen {return Decision::Block{reason:BlockReason::OwnRowMissing};}
    if exposure.owned_units.saturating_add(exposure.acquired_units)>limits.max_exposure_units {return Decision::Block{reason:BlockReason::Exposure};}

    let floor=effective_floor(floors);
    let own_unit=unit_ceil(&own);
    let mut rows:Vec<Quote>=depth.rows.iter().copied().filter(|q|q.owner_guid!=player_guid&&q.buyout>0&&q.count>0).collect();
    rows.sort_by(cmp_unit);
    let Some(first)=rows.first().copied() else{return Decision::Keep;};
    if cmp_unit(&first,&own)!=std::cmp::Ordering::Less{return Decision::Keep;}
    let ordinary=strict_below(&first);
    if ordinary==0||ordinary<floor{return Decision::Block{reason:BlockReason::Floor};}

    // Find the first support tier whose local band contains enough units. This prevents
    // one isolated expensive quote from acting as the recovered market level.
    let mut support_idx=None;
    for i in 0..rows.len() {
        let base=rows[i];
        let mut units=0u32;
        for q in rows.iter().skip(i) {
            if !within_band(&base,q,limits.support_band_bps){break;}
            units=units.saturating_add(q.count);
            if units>=limits.support_min_units {support_idx=Some(i);break;}
        }
        if support_idx.is_some(){break;}
    }

    if let Some(si)=support_idx {
        if si>0 {
            let support=&rows[si];
            let support_target=strict_below(support).min(own_unit);
            let prefix=&rows[..si];
            let prefix_units=prefix.iter().fold(0u32,|a,q|a.saturating_add(q.count));
            let prefix_spend=prefix.iter().fold(0u64,|a,q|a.saturating_add(u64::from(q.buyout)));
            let prefix_max=unit_ceil(prefix.last().unwrap());
            let support_unit=unit_ceil(support);
            let cliff=jump_bps(prefix_max.max(1),support_unit);
            if cliff>=limits.cliff_min_bps {
                if prefix_units>limits.max_clear_units||prefix_spend>u64::from(limits.max_clear_spend){return Decision::Block{reason:BlockReason::PrefixTooLarge};}
                if exposure.owned_units.saturating_add(exposure.acquired_units).saturating_add(prefix_units)>limits.max_exposure_units{return Decision::Block{reason:BlockReason::Exposure};}
                if support_target<floor||support_target==0{return Decision::Block{reason:BlockReason::Floor};}
                let total_units=exposure.acquired_units.saturating_add(prefix_units);
                let total_spend=u64::from(exposure.acquired_spend).saturating_add(prefix_spend);
                let gross=u128::from(support_target)*u128::from(total_units);
                let net=gross*u128::from(10000-limits.ah_cut_bps)/10000;
                let pnl=(net as i128-i128::from(total_spend)).clamp(i128::from(i64::MIN),i128::from(i64::MAX)) as i64;
                if pnl<0{return Decision::Block{reason:BlockReason::AcquiredLoss};}
                if pnl<i64::from(limits.clear_min_profit){return Decision::Block{reason:BlockReason::Cap};}
                let roi=if total_spend==0 {0} else {((u128::from(pnl as u64)*10000)/u128::from(total_spend)).min(u128::from(u32::MAX)) as u32};
                if roi<limits.clear_min_roi_bps{return Decision::Block{reason:BlockReason::Cap};}
                let plan_ids=prefix.iter().map(|q|q.auction_id).collect::<Vec<_>>();
                return Decision::Clear{
                    next_buy_auction_id:plan_ids[0], plan_ids,
                    spend:prefix_spend.min(u64::from(u32::MAX)) as u32, units:prefix_units,
                    target_unit:support_target, expected_acquired_profit:pnl, roi_bps:roi, floor_unit:floor,
                };
            }
        }
    }

    // A thin floor which forms a material cliff but cannot be cleared is blocked instead
    // of followed down. Without a support tier, use the explicit step-drop guard.
    if drop_bps(own_unit,ordinary)>limits.max_step_drop_bps {
        return Decision::Block{reason:BlockReason::StepDrop};
    }
    Decision::Undercut{target_unit:ordinary,witness_auction_id:first.auction_id,floor_unit:floor}
}

#[cfg(test)]
mod tests {
    use super::*;
    fn lim()->Limits{Limits{ah_cut_bps:500,max_depth_age_ms:5000,max_step_drop_bps:3000,support_band_bps:500,support_min_units:5,cliff_min_bps:2500,max_clear_units:5,max_clear_spend:10000,max_exposure_units:30,clear_min_profit:1,clear_min_roi_bps:1}}
    fn view(rows:Vec<Quote>)->DepthView{DepthView{source:DepthSource::Targeted,complete:true,coherent:true,age_ms:0,own_row_seen:true,rows}}
    fn own()->Quote{Quote{auction_id:1,owner_guid:7,buyout:1000,count:1}}
    fn q(id:u32,p:u32,c:u32)->Quote{Quote{auction_id:id,owner_guid:99,buyout:p,count:c}}
    fn floors()->Floors{Floors{explicit_unit:1,economic_unit:1,history_unit:None}}
    #[test]fn stack_normalized_keep(){let d=decide(q(1,200,1),7,&view(vec![q(2,600,3)]),floors(),Exposure{owned_units:1,acquired_units:0,acquired_spend:0},lim());assert_eq!(d,Decision::Keep);}
    #[test]fn stale_blocks(){let mut v=view(vec![q(2,900,1)]);v.age_ms=5001;assert!(matches!(decide(own(),7,&v,floors(),Exposure{owned_units:1,acquired_units:0,acquired_spend:0},lim()),Decision::Block{reason:BlockReason::Stale}));}
    #[test]fn broad_cannot_authorize(){let mut v=view(vec![q(2,900,1)]);v.source=DepthSource::Broad;assert!(matches!(decide(own(),7,&v,floors(),Exposure{owned_units:1,acquired_units:0,acquired_spend:0},lim()),Decision::Block{reason:BlockReason::NotTargeted}));}
    #[test]fn thin_fake_floor_clearable(){let rows=vec![q(10,100,1),q(20,900,1),q(21,905,1),q(22,910,1),q(23,915,1),q(24,920,1)];let d=decide(own(),7,&view(rows),floors(),Exposure{owned_units:1,acquired_units:0,acquired_spend:0},lim());assert!(matches!(d,Decision::Clear{next_buy_auction_id:10,..}));}
    #[test]fn step_drop_blocks_unproven_floor(){let rows=vec![q(10,100,1)];assert!(matches!(decide(own(),7,&view(rows),floors(),Exposure{owned_units:1,acquired_units:0,acquired_spend:0},lim()),Decision::Block{reason:BlockReason::StepDrop}));}
    #[test]fn stack_normalized_undercut(){let mut l=lim();l.max_step_drop_bps=5000;let d=decide(q(1,1000,5),7,&view(vec![q(2,1900,10)]),floors(),Exposure{owned_units:5,acquired_units:0,acquired_spend:0},l);assert!(matches!(d,Decision::Undercut{target_unit:189,..}));}
}
