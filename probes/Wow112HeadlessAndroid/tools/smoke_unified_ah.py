from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

if len(sys.argv) != 3:
    raise SystemExit('usage: UNIFIED_RS WORLD_POC07_RS')

unified = Path(sys.argv[1])
patch = Path(__file__).with_name('poc08_unified_multibuy_v3_patch.py')

# Smoke must never mutate the build artifact it validates. If the input is an
# older pre-multibuy source, exercise the historical patch against a temporary
# copy. Fully integrated V4 sources already contain POC08-UNIFIED-MULTI and
# must be validated as-is; reapplying the legacy patch can hit unrelated
# audit-only anchors and produce a false policy failure.
with tempfile.TemporaryDirectory(prefix='wow112-unified-smoke-') as td:
    smoke_unified = Path(td) / unified.name
    shutil.copy2(unified, smoke_unified)
    u = smoke_unified.read_text(encoding='utf-8')
    if 'POC08-UNIFIED-MULTI' not in u:
        subprocess.run([sys.executable, str(patch), str(smoke_unified)], check=True)
        u = smoke_unified.read_text(encoding='utf-8')
        print('[SMOKE] multibuy_patch=APPLIED_TO_TEMP_COPY')
    else:
        print('[SMOKE] multibuy_patch=SKIP_ALREADY_APPLIED')

is_v4 = 'POC08-UNIFIED-V4' in u
w = Path(sys.argv[2]).read_text(encoding='utf-8')
checks = {
    'full_ah': 'FULL_AH_ALL_CLASSES_ALL_QUALITIES_ALL_STACKS' in u,
    'no_order_assumption': 'ordering_assumption=NONE' in u,
    'dedupe': 'dedupe=AUCTION_ID' in u,
    'fullscan_failclosed': 'POC08_UNIFIED_FULL_AH_TRUNCATED' in u,
    'auto_mode': 'Poc08F1Action::AutoBest' in u,
    'vendor_mode': 'Poc08F1Action::VendorBest' in u,
    'de_mode': 'Poc08F1Action::DeBest' in u,
    'profit_first': 'PROFIT_DESC_VENDOR_TIE' in u,
    'noop': 'NO_ELIGIBLE_LIVE_ROUTE' in u,
    'multibuy': 'POC08-UNIFIED-MULTI' in u,
    # V3 had unlimited Vendor count. V4 intentionally replaced that with a
    # bounded shared mutation envelope (vendor / total / spend caps).
    'vendor_limit_policy': (
        'WOW112_UNIFIED_VENDOR_MAX_PURCHASES' in u
        and 'WOW112_UNIFIED_MAX_PURCHASES' in u
        and 'WOW112_UNIFIED_MAX_SPEND' in u
        and 'bought_vendor>=vendor_limit' in u
        and 'bought_total>=total_limit' in u
        and 'bought_spend.saturating_add(c.record.buyout)>spend_limit' in u
    ) if is_v4 else 'vendor_limit=UNLIMITED' in u,
    'de_limit': 'WOW112_UNIFIED_DE_MAX_PURCHASES' in u,
    'capy_agreement0': 'Some("CapyDB")' in u and 'agreement_bps' in u and '==0' in u,
    'one_mutation_guard': 'WOW112_AUTOBUY_MAX_PURCHASES' in u and '!= 1' in u,
    'neighborhood': 'POC07_REVALIDATE_RADIUS: u32 = 5' in w,
    'exact_tuple': 'exact_tuple=YES' in w and 'Poc06AhAction::GuardedBuy' in w,
    'no_retry': 'NO_AUTO_RETRY_FROM_THIS_POINT=YES' in w,
    'uncertain_guard': 'AH_MUTATION_UNCERTAIN' in w,
    'mutation_latch': 'AH_MUTATION_BLOCKED' in w,
    'stale_skip': 'POC07_BUY_TARGET_STALE' in u and 'STALE SKIP' in u,
}

login_start = u.find('pub fn login_poc08_economy_audit(')
if login_start < 0:
    raise SystemExit('live login function missing')
login = u[login_start:]
checks['no_filtered_scan_call'] = 'poc07_de_scan_class_v4(stream, &mut crypto' not in login

# Vendor/DE route predicates live in the live login/queue policy. Audit-only
# helpers are intentionally outside this slice and cannot affect these checks.
vendor_start = login.find('let vendor_ok=')
de_start = login.find('let de_ok=')
whitelist_start = login.find('if matches!(f1_action,Poc08F1Action::DeWhitelist)')
if min(vendor_start, de_start, whitelist_start) < 0 or not (vendor_start < de_start < whitelist_start):
    raise SystemExit('live route policy anchors missing or reordered')
vg = login[vendor_start:de_start]
dg = login[de_start:whitelist_start]
checks['vendor_stacks'] = 'count==1' not in vg and 'count == 1' not in vg
checks['de_count1'] = 'count==1' in dg or 'count == 1' in dg
checks['de_risk'] = 'de_risk_pass' in dg and 'in_f0(c)' in dg
checks['de_capy_exact'] = 'Some("CapyDB")' in dg and '==0' in dg and 'poc08_de_source_confidence(c.record.item_id)>=2' in dg

for key, ok in checks.items():
    print(f'[SMOKE] {key}={"PASS" if ok else "FAIL"}')
if not all(checks.values()):
    raise SystemExit('UNIFIED V3 STATIC SMOKE FAIL')
print('[SMOKE] UNIFIED MULTIBUY V3/V4 STATIC+POLICY PASS non_destructive=YES scoped_live_policy=YES')
