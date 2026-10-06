from pathlib import Path
import sys
if len(sys.argv)!=3: raise SystemExit('usage: UNIFIED_RS WORLD_POC07_RS')
u=Path(sys.argv[1]).read_text(encoding='utf-8')
w=Path(sys.argv[2]).read_text(encoding='utf-8')
checks={
'full_ah':'FULL_AH_ALL_CLASSES_ALL_QUALITIES_ALL_STACKS' in u,
'no_order_assumption':'ordering_assumption=NONE' in u,
'dedupe':'dedupe=AUCTION_ID' in u,
'fullscan_failclosed':'POC08_UNIFIED_FULL_AH_TRUNCATED' in u,
'auto_mode':'Poc08F1Action::AutoBest' in u,
'vendor_mode':'Poc08F1Action::VendorBest' in u,
'de_mode':'Poc08F1Action::DeBest' in u,
'profit_first':'PROFIT_DESC_VENDOR_TIE' in u,
'noop':'NO_ELIGIBLE_LIVE_ROUTE' in u,
'one_buy':'LIVE BUY-ONE PASS purchases=1' in u,
'capy_agreement0':'Some("CapyDB")' in u and 'agreement_bps' in u,
'one_process_guard':'WOW112_AUTOBUY_MAX_PURCHASES' in u and '!= 1' in u,
'neighborhood':'POC07_REVALIDATE_RADIUS: u32 = 5' in w,
'exact_tuple':'exact_tuple=YES' in w and 'Poc06AhAction::GuardedBuy' in w,
'no_retry':'NO_AUTO_RETRY_FROM_THIS_POINT=YES' in w,
'uncertain_guard':'AH_MUTATION_UNCERTAIN' in w,
'mutation_latch':'AH_MUTATION_BLOCKED' in w,
}
login=u[u.find('pub fn login_poc08_economy_audit('):]
checks['no_filtered_scan_call']='poc07_de_scan_class_v4(stream, &mut crypto' not in login
vg=u[u.find('let vendor_ok='):u.find('let de_ok=')]
dg=u[u.find('let de_ok='):u.find('let selection:')]
checks['vendor_stacks']='count==1' not in vg and 'count == 1' not in vg
checks['de_count1']='count==1' in dg or 'count == 1' in dg
checks['de_risk']='de_risk_pass' in dg and 'in_f0(c)' in dg
checks['de_capy_exact']='Some("CapyDB")' in dg and '==0' in dg
for k,v in checks.items(): print(f'[SMOKE] {k}={"PASS" if v else "FAIL"}')
if not all(checks.values()): raise SystemExit('UNIFIED STATIC SMOKE FAIL')
# Synthetic policy contract: vendor stacks allowed; DE stacks blocked; best safe profit wins.
def choose(rows,mode='auto'):
 r=[]
 for x in rows:
  vok=x['vendor_profit']>=1
  dok=x['count']==1 and x['de_profit']>=500 and x['roi']>=2000 and x['ploss']<=4000 and x['agreement']==0 and x['source'] in ('OctoWow','CapyDB')
  if mode!='de' and vok:r.append((x['vendor_profit'],0,'vendor',x['id']))
  if mode!='vendor' and dok:r.append((x['de_profit'],1,'de',x['id']))
 return sorted(r,key=lambda z:(-z[0],z[1],z[3]))[0] if r else None
rows=[{'id':1,'count':5,'vendor_profit':300,'de_profit':900,'roi':9000,'ploss':0,'agreement':0,'source':'CapyDB'}, {'id':2,'count':1,'vendor_profit':100,'de_profit':500,'roi':3000,'ploss':1000,'agreement':0,'source':'CapyDB'}]
assert choose(rows)==(500,1,'de',2)
rows[1]['agreement']=1
assert choose(rows)==(300,0,'vendor',1)
rows[1]['agreement']=0;rows[1]['de_profit']=300;rows[1]['vendor_profit']=300
assert choose(rows)[2]=='vendor'
print('[SMOKE] synthetic_policy=PASS')
print('[SMOKE] UNIFIED STATIC+POLICY PASS')
