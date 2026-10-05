from pathlib import Path
import sys

if len(sys.argv) != 3:
    raise SystemExit('usage: vendor_multibuy_v2_neighborhood_patch.py INPUT_MULTIBUY OUTPUT_V2')

src = Path(sys.argv[1]).read_text(encoding='utf-8')

old = r'''    // Baseline mailbox BEFORE final AH revalidation, so any post-send mail is provably new.
    let before_mail = poc05_request_mail_list(stream, crypto, mailbox_guid)?;
    let fresh_records = poc07_request_auction_page(
        stream,
        crypto,
        auctioneer_guid,
        auction_house,
        candidate.page,
        "poc07-multibuy-fresh-precheck",
    )?;
    let action = Poc06AhAction::GuardedBuy {
        auction_id: candidate.record.auction_id,
        item_id: candidate.record.item_id,
        count: candidate.record.count,
        expected_buyout: candidate.record.buyout,
        max_price: candidate.record.buyout,
    };
    let target = match poc06_validate_target(action, &fresh_records) {
        Ok(target) => target,
        Err(error) => {
            println!(
                "[POC07-MULTIBUY] SKIP_STALE index={} page={} auction_id={} item_id={} name={:?} reason={}",
                purchase_index,
                candidate.page,
                candidate.record.auction_id,
                candidate.record.item_id,
                item_name,
                error
            );
            return Ok(false);
        }
    };
'''

new = r'''    // Baseline mailbox BEFORE final AH revalidation, so any post-send mail is provably new.
    let before_mail = poc05_request_mail_list(stream, crypto, mailbox_guid)?;

    // AH pagination moves while the full scan is running. Revalidate the exact tuple in a
    // bounded page neighborhood rather than assuming the auction is still on its old page.
    // Exact auction_id + item_id + count + buyout is still mandatory before SEND.
    const REVALIDATE_RADIUS: u32 = 5;
    let mut pages = Vec::<u32>::with_capacity((REVALIDATE_RADIUS * 2 + 1) as usize);
    pages.push(candidate.page);
    for delta in 1..=REVALIDATE_RADIUS {
        if let Some(page) = candidate.page.checked_sub(delta) {
            pages.push(page);
        }
        if let Some(page) = candidate.page.checked_add(delta) {
            pages.push(page);
        }
    }

    let mut matched: Option<(u32, Poc06AuctionRecord)> = None;
    let mut last_error = String::from("auction not found in neighborhood");
    for fresh_page in pages.iter().copied() {
        let fresh_records = poc07_request_auction_page(
            stream,
            crypto,
            auctioneer_guid,
            auction_house,
            fresh_page,
            "poc07-multibuy-neighborhood-precheck",
        )?;
        let action = Poc06AhAction::GuardedBuy {
            auction_id: candidate.record.auction_id,
            item_id: candidate.record.item_id,
            count: candidate.record.count,
            expected_buyout: candidate.record.buyout,
            max_price: candidate.record.buyout,
        };
        match poc06_validate_target(action, &fresh_records) {
            Ok(target) => {
                println!(
                    "[POC07-MULTIBUY] REVALIDATE PASS index={} auction_id={} original_page={} fresh_page={} radius={}",
                    purchase_index,
                    candidate.record.auction_id,
                    candidate.page,
                    fresh_page,
                    REVALIDATE_RADIUS
                );
                matched = Some((fresh_page, target));
                break;
            }
            Err(error) => last_error = error,
        }
    }

    let (revalidated_page, target) = match matched {
        Some(value) => value,
        None => {
            println!(
                "[POC07-MULTIBUY] SKIP_STALE index={} page={} auction_id={} item_id={} name={:?} neighborhood_radius={} pages_checked={} reason={}",
                purchase_index,
                candidate.page,
                candidate.record.auction_id,
                candidate.record.item_id,
                item_name,
                REVALIDATE_RADIUS,
                pages.len(),
                last_error
            );
            return Ok(false);
        }
    };
'''

if old not in src:
    raise SystemExit('V2 fresh-revalidation marker not found')
src = src.replace(old, new, 1)

old_post = r'''    let after_auctions = poc07_request_auction_page(
        stream,
        crypto,
        auctioneer_guid,
        auction_house,
        candidate.page,
        "poc07-multibuy-post-reconcile",
    )'''
new_post = r'''    let after_auctions = poc07_request_auction_page(
        stream,
        crypto,
        auctioneer_guid,
        auction_house,
        revalidated_page,
        "poc07-multibuy-post-reconcile",
    )'''
if old_post not in src:
    raise SystemExit('V2 post-reconcile page marker not found')
src = src.replace(old_post, new_post, 1)

# Make the generated entrypoint/version unmistakable in logs and CI selection.
src = src.replace('pub fn login_poc07_vendorlive_multibuy(', 'pub fn login_poc07_vendorlive_multibuy_v2(', 1)
src = src.replace('[POC07-MULTIBUY] START', '[POC07-MULTIBUY-V2] START', 1)
src = src.replace('[POC07-MULTIBUY] PASS qualified=', '[POC07-MULTIBUY-V2] PASS qualified=', 1)

Path(sys.argv[2]).write_text(src, encoding='utf-8')
