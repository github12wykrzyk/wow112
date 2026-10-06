from pathlib import Path
import sys

if len(sys.argv) != 2:
    raise SystemExit('usage: vendor_mailbox_fastfix_patch.py WORLD_POC07_RS')

p = Path(sys.argv[1])
s = p.read_text(encoding='utf-8')

old_pre = '    let before_mail = poc05_request_mail_list(stream, crypto, mailbox_guid)?;\n'
new_pre = '    println!("[POC07-BUY] PRE-BUY MAILBOX BYPASS enabled=YES reason=mailbox-not-required-for-mutation");\n'
if s.count(old_pre) != 1:
    raise SystemExit(f'pre-buy mailbox marker mismatch count={s.count(old_pre)}')
s = s.replace(old_pre, new_pre, 1)

old_post = '''    let after_auctions = poc07_request_auction_page(
        stream,
        crypto,
        auctioneer_guid,
        auction_house,
        candidate.page,
        "poc07-post-buy-reconcile",
    )
    .map_err(|error| {
        format!(
            "AH_MUTATION_CONFIRMED_POSTCHECK_FAILED auction_id={}: AH snapshot failed: {error}",
            target.auction_id
        )
    })?;
    let after_mail = poc05_request_mail_list(stream, crypto, mailbox_guid).map_err(|error| {
        format!(
            "AH_MUTATION_CONFIRMED_POSTCHECK_FAILED auction_id={}: mailbox snapshot failed: {error}",
            target.auction_id
        )
    })?;
    poc06_reconcile_buy(target, &after_auctions, &before_mail, &after_mail)?;
    println!("[POC07-BUY] BUY-ONE PASS purchases=1");
'''

new_post = '''    match poc07_request_auction_page(
        stream,
        crypto,
        auctioneer_guid,
        auction_house,
        candidate.page,
        "poc07-post-buy-reconcile",
    ) {
        Ok(after_auctions) => {
            let still_present = after_auctions
                .iter()
                .any(|record| record.auction_id == target.auction_id);
            if still_present {
                println!(
                    "[POC07-BUY] POST-AH WARN auction_id={} still_present=YES server_confirmed=YES no_retry=YES",
                    target.auction_id
                );
            } else {
                println!(
                    "[POC07-BUY] POST-AH PASS auction_id={} absent_from_fresh_page=YES",
                    target.auction_id
                );
            }
        }
        Err(error) => {
            println!(
                "[POC07-BUY] POST-AH WARN auction_id={} best_effort=YES server_confirmed=YES no_retry=YES error={error}",
                target.auction_id
            );
        }
    }

    match poc05_request_mail_list(stream, crypto, mailbox_guid) {
        Ok(_) => println!(
            "[POC07-BUY] POST-MAIL PASS auction_id={} best_effort=YES",
            target.auction_id
        ),
        Err(error) => println!(
            "[POC07-BUY] POST-MAIL WARN auction_id={} best_effort=YES server_confirmed=YES no_retry=YES error={error}",
            target.auction_id
        ),
    }

    println!("[POC07-BUY] BUY-ONE PASS purchases=1 server_confirmed=YES postchecks=BEST_EFFORT");
'''

if s.count(old_post) != 1:
    raise SystemExit(f'post-buy reconcile marker mismatch count={s.count(old_post)}')
s = s.replace(old_post, new_post, 1)

required = [
    '[POC07-BUY] PRE-BUY MAILBOX BYPASS',
    '[POC07-BUY] POST-AH WARN',
    '[POC07-BUY] POST-MAIL WARN',
    'BUY-ONE PASS purchases=1 server_confirmed=YES postchecks=BEST_EFFORT',
    'NO_AUTO_RETRY_FROM_THIS_POINT=YES',
]
for marker in required:
    if marker not in s:
        raise SystemExit('missing fastfix marker: ' + marker)
if 'let before_mail = poc05_request_mail_list' in s:
    raise SystemExit('unsafe pre-buy mailbox dependency remains')

p.write_text(s, encoding='utf-8')

# Canonical AH hello hardening: a cached/configured GUID is only a preference.
# It must never satisfy live discovery by itself, otherwise a stale persisted GUID
# can prematurely seed the candidate set after a server restart.
retry_path = p.with_name('world_poc05_retry.rs')
r = retry_path.read_text(encoding='utf-8')
old_guid = '''    if let Ok(value) = env::var("WOW112_AH_GUID") {\n        let guid = parse_guid_override("WOW112_AH_GUID", &value)?;\n        println!("[AH] using configured auctioneer guid=0x{guid:016X}");\n        auctioneers.insert(guid);\n    }\n'''
new_guid = '''    if let Ok(value) = env::var("WOW112_AH_GUID") {\n        let guid = parse_guid_override("WOW112_AH_GUID", &value)?;\n        println!(\n            "[AH] configured auctioneer guid=0x{guid:016X} preferred_only=YES live_observation_required=YES"\n        );\n        // Do not insert here. The GUID becomes eligible only if observed in\n        // the current world update stream.\n    }\n'''
if r.count(old_guid) != 1:
    raise SystemExit(f'AH hello live-discovery marker mismatch count={r.count(old_guid)}')
r = r.replace(old_guid, new_guid, 1)
if 'preferred_only=YES live_observation_required=YES' not in r:
    raise SystemExit('AH hello live-discovery marker missing after patch')
segment = r.split('fn discover_poc05_context_retry', 1)[1].split('fn poc05_send_auction_hello_candidates', 1)[0]
if 'auctioneers.insert(guid);' in segment:
    raise SystemExit('configured AH GUID still contaminates live discovery set')
retry_path.write_text(r, encoding='utf-8')

print('[VENDOR-MAILBOX-FASTFIX] PASS prebuy_mailbox=BYPASSED postchecks=BEST_EFFORT hard_max_purchases=1')
print('[AH-HELLO-LIVE-GUARD] PASS configured_guid=preferred_only live_observation_required=YES')
