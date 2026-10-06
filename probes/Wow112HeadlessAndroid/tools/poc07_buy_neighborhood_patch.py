from pathlib import Path
import sys

if len(sys.argv) != 2:
    raise SystemExit('usage: poc07_buy_neighborhood_patch.py WORLD_POC07_RS')

p = Path(sys.argv[1])
s = p.read_text(encoding='utf-8')

old = '''    let fresh_records = poc07_request_auction_page(
        stream,
        crypto,
        auctioneer_guid,
        auction_house,
        candidate.page,
        "poc07-fresh-precheck",
    )?;
    let action = Poc06AhAction::GuardedBuy {
        auction_id: candidate.record.auction_id,
        item_id: candidate.record.item_id,
        count: candidate.record.count,
        expected_buyout: candidate.record.buyout,
        max_price: candidate.record.buyout,
    };
    let target = poc06_validate_target(action, &fresh_records)?;
'''
new = '''    const POC07_REVALIDATE_RADIUS: u32 = 5;
    let action = Poc06AhAction::GuardedBuy {
        auction_id: candidate.record.auction_id,
        item_id: candidate.record.item_id,
        count: candidate.record.count,
        expected_buyout: candidate.record.buyout,
        max_price: candidate.record.buyout,
    };
    let mut pages = Vec::<u32>::with_capacity((POC07_REVALIDATE_RADIUS * 2 + 1) as usize);
    pages.push(candidate.page);
    for delta in 1..=POC07_REVALIDATE_RADIUS {
        if let Some(page) = candidate.page.checked_sub(delta) { pages.push(page); }
        if let Some(page) = candidate.page.checked_add(delta) { pages.push(page); }
    }
    let mut matched: Option<(u32, Poc06AuctionRecord)> = None;
    let mut last_error = String::from("exact tuple not found");
    for fresh_page in pages.iter().copied() {
        let fresh_records = poc07_request_auction_page(
            stream,
            crypto,
            auctioneer_guid,
            auction_house,
            fresh_page,
            "poc07-fresh-neighborhood-precheck",
        )?;
        match poc06_validate_target(action, &fresh_records) {
            Ok(target) => {
                println!(
                    "[POC07-BUY] REVALIDATE PASS auction_id={} original_page={} fresh_page={} radius={} exact_tuple=YES",
                    candidate.record.auction_id,
                    candidate.page,
                    fresh_page,
                    POC07_REVALIDATE_RADIUS,
                );
                matched = Some((fresh_page, target));
                break;
            }
            Err(error) => last_error = error,
        }
    }
    let (_revalidated_page, target) = matched.ok_or_else(|| format!(
        "POC07_BUY_TARGET_STALE no purchase sent auction_id={} item_id={} original_page={} radius={} pages_checked={} last_error={}",
        candidate.record.auction_id,
        candidate.record.item_id,
        candidate.page,
        POC07_REVALIDATE_RADIUS,
        pages.len(),
        last_error,
    ))?;
'''
if s.count(old) != 1:
    raise SystemExit(f'NEIGHBORHOOD precheck marker expected=1 actual={s.count(old)}')
s = s.replace(old, new, 1)

required = [
    'POC07_REVALIDATE_RADIUS: u32 = 5',
    'poc07-fresh-neighborhood-precheck',
    'exact_tuple=YES',
    'POC07_BUY_TARGET_STALE no purchase sent',
    'NO_AUTO_RETRY_FROM_THIS_POINT=YES',
]
for marker in required:
    if marker not in s:
        raise SystemExit('NEIGHBORHOOD missing marker: ' + marker)

p.write_text(s, encoding='utf-8')
print('[POC07-BUY-NEIGHBORHOOD] PASS radius=5 exact_tuple=YES send_guard=UNCHANGED')
