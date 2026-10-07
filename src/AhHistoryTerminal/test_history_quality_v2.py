#!/usr/bin/env python3
import json
import pathlib
import sqlite3
import sys

sys.path.insert(0, str(pathlib.Path(__file__).parent))
import history_quality_v2 as h

SCHEMA = '''
CREATE TABLE scans(scan_id TEXT PRIMARY KEY, market TEXT NOT NULL, producer TEXT NOT NULL, source TEXT NOT NULL, scope TEXT NOT NULL, status TEXT NOT NULL, started_ms INTEGER NOT NULL, ended_ms INTEGER NOT NULL, quality TEXT NOT NULL, reasons TEXT NOT NULL, record_count INTEGER NOT NULL, unique_count INTEGER NOT NULL, segment_sha256 TEXT NOT NULL);
CREATE TABLE events(event_id TEXT PRIMARY KEY, scan_id TEXT NOT NULL, seq INTEGER NOT NULL, payload TEXT NOT NULL, sha256 TEXT NOT NULL, UNIQUE(scan_id,seq));
CREATE TABLE observations(event_id TEXT NOT NULL, record_index INTEGER NOT NULL, scan_id TEXT NOT NULL, market TEXT NOT NULL, observed_ms INTEGER NOT NULL, auction_id INTEGER NOT NULL, item_id INTEGER NOT NULL, count INTEGER NOT NULL, buyout INTEGER NOT NULL, owner_token TEXT, start_bid INTEGER NOT NULL, current_bid INTEGER NOT NULL, min_increment INTEGER NOT NULL, time_left INTEGER NOT NULL, PRIMARY KEY(event_id,record_index));
'''


def make_db(identity=True, duplicate=False, ended=2000):
    db = sqlite3.connect(':memory:')
    db.executescript(SCHEMA)
    mid = {
        'server_id':'1','realm_id':'realm-x','ah_pool':'neutral','market_epoch':'epoch-1',
        'identity_status':'verified','identity_source':'fixture'
    } if identity else None
    start = {'schema_version':1,'event_id':'s:1','scan_id':'s','producer_seq':1,'market_id':'m','producer_id':'p','source':'live','scope':'full_market','observed_at_utc_ms':1000,'event_type':'ScanStarted'}
    if mid: start['market_identity'] = mid
    rows0 = [
        {'record_index':i,'auction_id':i+1,'item_id':10940,'count':1,'buyout_total_copper':100+i,
         'owner_token':None,'start_bid_copper':0,'current_bid_copper':0,'min_increment_copper':0,'time_left_raw':1}
        for i in range(50)
    ]
    rows1 = [
        {'record_index':0,'auction_id':50 if duplicate else 51,'item_id':10940,'count':2,'buyout_total_copper':210,
         'owner_token':None,'start_bid_copper':0,'current_bid_copper':0,'min_increment_copper':0,'time_left_raw':1}
    ]
    pages = []
    for seq,(page,rows,total) in enumerate([(0,rows0,51),(1,rows1,51)],2):
        e = {'schema_version':1,'event_id':f's:{seq}','scan_id':'s','producer_seq':seq,'market_id':'m','producer_id':'p','source':'live','scope':'full_market','observed_at_utc_ms':1000+seq,'event_type':'PageObserved','page':page,'listfrom':page*50,'total':total,'record_count':len(rows),'records':rows}
        if mid: e['market_identity'] = mid
        pages.append(e)
    finish = {'schema_version':1,'event_id':'s:4','scan_id':'s','producer_seq':4,'market_id':'m','producer_id':'p','source':'live','scope':'full_market','observed_at_utc_ms':ended,'event_type':'ScanFinished','status':'completed','reason':'ok','pages':2}
    events = [start,*pages,finish]
    unique = len({r['auction_id'] for p in pages for r in p['records']})
    db.execute('INSERT INTO scans VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)',('s','m','p','live','full_market','completed',1000,ended,'eligible','[]',sum(len(p['records']) for p in pages),unique,'x'))
    for e in events:
        db.execute('INSERT INTO events VALUES(?,?,?,?,?)',(e['event_id'],'s',e['producer_seq'],json.dumps(e,separators=(',',':')),'x'))
        if e['event_type'] == 'PageObserved':
            for i,r in enumerate(e['records']):
                db.execute('INSERT INTO observations VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)',(e['event_id'],i,'s','m',e['observed_at_utc_ms'],r['auction_id'],r['item_id'],r['count'],r['buyout_total_copper'],None,0,0,0,1))
    db.commit()
    h.ensure_schema(db)
    return db


def test_eligible_and_view():
    db = make_db()
    q = h.evaluate_scan(db,'s',3000)
    assert q['decision'] == 'eligible', q
    v = h.de_material_view(db,'m',3000,now_ms=3000)
    assert v['eligible_scan_count'] == 1
    s = v['samples'][0]
    assert s['item_id'] == 10940 and s['observed_units'] == 52 and s['age_ms'] >= 0
    assert h.shadow_price_map(v)[10940] > 0


def test_identity_required():
    db = make_db(identity=False)
    q = h.evaluate_scan(db,'s')
    assert q['decision'] == 'diagnostic_only'
    assert 'market_identity_not_verified' in q['reasons']


def test_overlap_excluded():
    db = make_db(duplicate=True)
    q = h.evaluate_scan(db,'s')
    assert q['decision'] == 'diagnostic_only'
    assert 'pagination_suffix_prefix_overlap' in q['reasons']
    assert q['metrics']['suffix_prefix_boundaries'] == 1


def test_no_future_leakage():
    db = make_db(ended=5000)
    h.evaluate_scan(db,'s')
    v = h.de_material_view(db,'m',4999,now_ms=4999)
    assert v['eligible_scan_count'] == 0


if __name__ == '__main__':
    tests = [test_eligible_and_view,test_identity_required,test_overlap_excluded,test_no_future_leakage]
    for test in tests:
        test()
        print('PASS', test.__name__)
