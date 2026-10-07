from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

if len(sys.argv) != 3:
    raise SystemExit('usage: UNIFIED_RS WORLD_POC07_RS')

unified = Path(sys.argv[1])
patch = Path(__file__).with_name('poc08_unified_multibuy_v3_patch.py')

# Smoke must never mutate the build artifact it validates. The historical
# multibuy-v3 patch is exercised against a temporary copy only.
with tempfile.TemporaryDirectory(prefix='wow112-unified-smoke-') as td:
    smoke_unified = Path(td) / unified.name
    shutil.copy2(unified, smoke_unified)
    subprocess.run([sys.executable, str(patch), str(smoke_unified)], check=True)
    u = smoke_unified.read_text(encoding='utf-8')

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
    'vendor_unlimited': 'vendor_limit=UNLIMITED' in u,
    'de_limit': 'WOW112_UNIFIED_DE_MAX_PURCHASES' in u,
    'capy_agreement0': 'Some("CapyDB")' in u and 'agreement_bps' in u,
    'one_mutation_guard': 'WOW112_AUTOBUY_MAX_PURCHASES' in u and '!= 1' in u,
    'neighborhood': 'POC07_REVALIDATE_RADIUS: u32 = 5' in w,
    'exact_tuple': 'exact_tuple=YES' in w and 'Poc06AhAction::GuardedBuy' in w,
    'no_retry': 'NO_AUTO_RETRY_FROM_THIS_POINT=YES' in w,
    'uncertain_guard': 'AH_MUTATION_UNCERTAIN' in w,
    'mutation_latch': 'AH_MUTATION_BLOCKED' in w,
    'stale_skip': 'POC07_BUY_TARGET_STALE' in u and 'STALE SKIP' in u,
}
login = u[u.find('pub fn login_poc08_economy_audit('):]
checks['no_filtered_scan_call'] = 'poc07_de_scan_class_v4(stream, &mut crypto' not in login

# Scope route-policy assertions to the real combined decision function. Audit-only
# helpers are allowed to independently reconstruct route predicates and must not
# change the meaning of this smoke test.
decision_start = u.find('fn poc08_build_combined_decisions(')
if decision_start < 0:
    raise SystemExit('combined decision function missing')
decision_end = u.find('\nfn ', decision_start + 4)
if decision_end < 0:
    decision_end = len(u)
decision = u[decision_start:decision_end]
vendor_start = decision.find('let vendor_ok=')
de_start = decision.find('let de_ok=')
whitelist_start = decision.find('if matches!(f1_action,Poc08F1Action::DeWhitelist)')
if min(vendor_start, de_start, whitelist_start) < 0 or not (vendor_start < de_start < whitelist_start):
    raise SystemExit('combined decision policy anchors missing or reordered')
vg = decision[vendor_start:de_start]
dg = decision[de_start:whitelist_start]
checks['vendor_stacks'] = 'count==1' not in vg and 'count == 1' not in vg
checks['de_count1'] = 'count==1' in dg or 'count == 1' in dg
checks['de_risk'] = 'de_risk_pass' in dg and 'in_f0(c)' in dg
checks['de_capy_exact'] = 'Some("CapyDB")' in dg and '==0' in dg

for key, ok in checks.items():
    print(f'[SMOKE] {key}={"PASS" if ok else "FAIL"}')
if not all(checks.values()):
    raise SystemExit('UNIFIED V3 STATIC SMOKE FAIL')
print('[SMOKE] UNIFIED MULTIBUY V3 STATIC+POLICY PASS non_destructive=YES scoped_decision=YES')
