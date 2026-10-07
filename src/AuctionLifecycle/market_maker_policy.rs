//! Pure policy for AH repricing / shallow-depth clearing. No transport or login here.
//! Runtime must revalidate immediately before every BUY/CANCEL/POST and may execute
//! only one planned clear BUY before rescanning the market.

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Quote {
    pub auction_id: u32,
    pub buyout: u32,
    pub count: u32,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct PolicyConfig {
    pub floor_unit: u32,
    pub min_price_bps_of_own: u32,
    pub ah_cut_bps: u32,
    pub max_clear_spend: u32,
    pub max_clear_units: u32,
    pub clear_min_profit: u32,
    pub clear_min_roi_bps: u32,
    pub clear_min_jump_bps: u32,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Decision {
    Keep,
    BlockedFloor { observed_unit_ceiling: u32, floor_unit: u32 },
    Undercut { target_unit: u32, witness_auction_id: u32, floor_unit: u32 },
    ClearThenRelist {
        auction_ids: Vec<u32>,
        spend: u32,
        units: u32,
        target_unit: u32,
        expected_profit: i64,
        roi_bps: u32,
        jump_bps: u32,
        floor_unit: u32,
    },
}

fn ceil_div(n: u128, d: u128) -> u32 {
    if d == 0 { return u32::MAX; }
    ((n + d - 1) / d).min(u128::from(u32::MAX)) as u32
}

fn cmp_unit(a: &Quote, b: &Quote) -> std::cmp::Ordering {
    (u128::from(a.buyout) * u128::from(b.count))
        .cmp(&(u128::from(b.buyout) * u128::from(a.count)))
        .then(a.buyout.cmp(&b.buyout))
        .then(a.auction_id.cmp(&b.auction_id))
}

fn strictly_cheaper(a: &Quote, b: &Quote) -> bool {
    a.buyout > 0 && b.buyout > 0 && a.count > 0 && b.count > 0 &&
        u128::from(a.buyout) * u128::from(b.count) <
        u128::from(b.buyout) * u128::from(a.count)
}

/// Largest integer copper/unit price that is strictly below `q`'s rational unit price.
fn strict_unit_below(q: &Quote) -> u32 {
    if q.buyout == 0 || q.count == 0 { 0 } else { (q.buyout - 1) / q.count }
}

fn own_unit_ceil(q: &Quote) -> u32 {
    ceil_div(u128::from(q.buyout), u128::from(q.count.max(1)))
}

fn jump_bps(low: u32, high: u32) -> u32 {
    if low == 0 || high <= low { 0 } else {
        ((u128::from(high - low) * 10_000) / u128::from(low)).min(u128::from(u32::MAX)) as u32
    }
}

fn valid_config(c: PolicyConfig) -> bool {
    c.floor_unit > 0 && c.min_price_bps_of_own > 0 && c.min_price_bps_of_own <= 10_000 &&
        c.ah_cut_bps < 10_000 && c.max_clear_units > 0
}

pub fn decide(own: Quote, competitors: &[Quote], mut c: PolicyConfig, depth_complete_and_stable: bool) -> Decision {
    if own.buyout == 0 || own.count == 0 || !valid_config(c) { return Decision::Keep; }
    let own_unit = own_unit_ceil(&own);
    let own_guard = ceil_div(u128::from(own.buyout) * u128::from(c.min_price_bps_of_own), u128::from(own.count) * 10_000);
    c.floor_unit = c.floor_unit.max(own_guard);

    let mut rows: Vec<Quote> = competitors.iter().copied().filter(|q| q.buyout > 0 && q.count > 0).collect();
    rows.sort_by(cmp_unit);
    let Some(first) = rows.first().copied() else { return Decision::Keep; };
    if !strictly_cheaper(&first, &own) { return Decision::Keep; }

    let ordinary_target = strict_unit_below(&first);

    // Clearing is deliberately conservative: a prefix must fit hard spend/unit caps,
    // the acquired stock alone must be profitable after AH cut, and the recovered
    // price level must jump materially. We do NOT count hypothetical profit on the
    // user's existing stock, so a clear cannot be justified only by wishful repricing.
    if depth_complete_and_stable {
        let mut spend: u64 = 0;
        let mut units: u64 = 0;
        let mut ids = Vec::new();
        let mut best: Option<(Vec<u32>, u32, u32, u32, i64, u32, u32)> = None;
        for (idx, row) in rows.iter().enumerate() {
            spend = spend.saturating_add(u64::from(row.buyout));
            units = units.saturating_add(u64::from(row.count));
            ids.push(row.auction_id);
            if spend > u64::from(c.max_clear_spend) || units > u64::from(c.max_clear_units) { break; }

            // After clearing this prefix, either undercut the next competitor or,
            // if our existing listing would already be the floor, relist acquired
            // units at no more than our current unit price.
            let after_target = rows.get(idx + 1)
                .map(strict_unit_below)
                .unwrap_or(own_unit)
                .min(own_unit);
            if after_target < c.floor_unit || after_target == 0 { continue; }
            let jump = jump_bps(ordinary_target.max(1), after_target);
            if jump < c.clear_min_jump_bps { continue; }

            let gross = u128::from(after_target) * u128::from(units);
            let net = gross * u128::from(10_000 - c.ah_cut_bps) / 10_000;
            let profit_i128 = net as i128 - i128::from(spend);
            let profit = profit_i128.clamp(i128::from(i64::MIN), i128::from(i64::MAX)) as i64;
            if profit < i64::from(c.clear_min_profit) { continue; }
            let roi = if spend == 0 || profit <= 0 { 0 } else {
                ((u128::from(profit as u64) * 10_000) / u128::from(spend)).min(u128::from(u32::MAX)) as u32
            };
            if roi < c.clear_min_roi_bps { continue; }
            let candidate = (ids.clone(), spend as u32, units as u32, after_target, profit, roi, jump);
            if best.as_ref().map(|x| profit > x.4 || (profit == x.4 && spend < u64::from(x.1))).unwrap_or(true) {
                best = Some(candidate);
            }
        }
        if let Some((auction_ids, spend, units, target_unit, expected_profit, roi_bps, jump_bps)) = best {
            return Decision::ClearThenRelist { auction_ids, spend, units, target_unit, expected_profit, roi_bps, jump_bps, floor_unit: c.floor_unit };
        }
    }

    if ordinary_target >= c.floor_unit && ordinary_target > 0 {
        Decision::Undercut { target_unit: ordinary_target, witness_auction_id: first.auction_id, floor_unit: c.floor_unit }
    } else {
        Decision::BlockedFloor { observed_unit_ceiling: ordinary_target, floor_unit: c.floor_unit }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn cfg() -> PolicyConfig { PolicyConfig { floor_unit: 300, min_price_bps_of_own: 5000, ah_cut_bps: 500, max_clear_spend: 1000, max_clear_units: 3, clear_min_profit: 50, clear_min_roi_bps: 1000, clear_min_jump_bps: 1000 } }
    #[test] fn keep_when_already_lowest() {
        assert_eq!(decide(Quote{auction_id:1,buyout:400,count:1}, &[Quote{auction_id:2,buyout:450,count:1}], cfg(), true), Decision::Keep);
    }
    #[test] fn rational_undercut_is_strict_per_unit() {
        let mut c=cfg(); c.floor_unit=1; c.min_price_bps_of_own=1;
        let d=decide(Quote{auction_id:1,buyout:1000,count:2}, &[Quote{auction_id:2,buyout:999,count:2}], c, false);
        assert_eq!(d, Decision::Undercut{target_unit:499,witness_auction_id:2,floor_unit:1});
    }
    #[test] fn floor_blocks_price_war() {
        let d=decide(Quote{auction_id:1,buyout:800,count:2}, &[Quote{auction_id:2,buyout:500,count:2}], cfg(), false);
        assert!(matches!(d,Decision::BlockedFloor{..}));
    }
    #[test] fn clears_small_profitable_fake_floor() {
        let mut c=cfg(); c.floor_unit=200; c.min_price_bps_of_own=4000; c.max_clear_spend=700;
        let d=decide(Quote{auction_id:1,buyout:1000,count:2}, &[
            Quote{auction_id:10,buyout:300,count:1},
            Quote{auction_id:11,buyout:310,count:1},
            Quote{auction_id:12,buyout:1000,count:2},
        ], c, true);
        match d { Decision::ClearThenRelist{auction_ids,target_unit,..}=>{assert_eq!(auction_ids,vec![10,11]);assert_eq!(target_unit,499);}, _=>panic!("expected clear") }
    }
    #[test] fn never_clears_from_incomplete_depth() {
        let mut c=cfg(); c.floor_unit=200; c.min_price_bps_of_own=4000; c.max_clear_spend=700;
        let d=decide(Quote{auction_id:1,buyout:1000,count:2}, &[
            Quote{auction_id:10,buyout:300,count:1}, Quote{auction_id:11,buyout:1000,count:2}
        ], c, false);
        assert!(matches!(d,Decision::Undercut{..}));
    }
    #[test] fn clear_requires_acquired_stock_profit_after_cut() {
        let mut c=cfg(); c.floor_unit=1; c.min_price_bps_of_own=1; c.clear_min_profit=1; c.max_clear_spend=1000;
        let d=decide(Quote{auction_id:1,buyout:400,count:1}, &[
            Quote{auction_id:10,buyout:390,count:1}, Quote{auction_id:11,buyout:400,count:1}
        ], c, true);
        assert!(!matches!(d,Decision::ClearThenRelist{..}));
    }
}
