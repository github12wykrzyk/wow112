-- AuxVmangos LIQUID_DEPTH v1: low-risk current-order-book arbitrage.
-- Loaded last. Discovery only nominates; every buy gets an exact named full-depth recheck.
AVM_LIQUID_DEPTH_VERSION = "0.1-low-risk"
AVM_LIQUID_DEPTH = AVM_LIQUID_DEPTH or {books={},verify=nil,pending=nil,unknown=nil,sessionCommitted=0,itemCommitted={},recent={},installed=false}
local L = AVM_LIQUID_DEPTH
local function now() return GetTime() or 0 end
local function money(v) v=math.floor(tonumber(v) or 0); return tostring(math.floor(v/10000)).."g"..tostring(math.floor(math.mod(v,10000)/100)).."s"..tostring(math.mod(v,100)).."c" end
local function log(s)
  if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage("[AVM] LIQUID_DEPTH "..tostring(s)) end
  if AVM_DB then
    AVM_DB.diag=AVM_DB.diag or {seq=0,events={},state={}}; AVM_DB.diag.events=AVM_DB.diag.events or {}; AVM_DB.diag.seq=(tonumber(AVM_DB.diag.seq) or 0)+1
    table.insert(AVM_DB.diag.events,tostring(AVM_DB.diag.seq).."@"..tostring(math.floor(now()*1000)).." LIQUID_DEPTH "..tostring(s)); while table.getn(AVM_DB.diag.events)>80 do table.remove(AVM_DB.diag.events,1) end
  end
end
local function defaults()
  if not AVM_DB then return end
  if AVM_DB.liquidDepthEnabled==nil then AVM_DB.liquidDepthEnabled=true end
  if AVM_DB.liquidDepthMaxBuyout==nil then AVM_DB.liquidDepthMaxBuyout=100000 end
  if AVM_DB.liquidDepthMaxItemCommitted==nil then AVM_DB.liquidDepthMaxItemCommitted=200000 end
  if AVM_DB.liquidDepthMaxSessionCommitted==nil then AVM_DB.liquidDepthMaxSessionCommitted=500000 end
  if AVM_DB.liquidDepthEntryPct==nil then AVM_DB.liquidDepthEntryPct=60 end
  if AVM_DB.liquidDepthPreEntryPct==nil then AVM_DB.liquidDepthPreEntryPct=70 end
  if AVM_DB.liquidDepthMinRefUnits==nil then AVM_DB.liquidDepthMinRefUnits=20 end
  if AVM_DB.liquidDepthMinRefSellers==nil then AVM_DB.liquidDepthMinRefSellers=3 end
  if AVM_DB.liquidDepthPreRefUnits==nil then AVM_DB.liquidDepthPreRefUnits=10 end
  if AVM_DB.liquidDepthPreRefSellers==nil then AVM_DB.liquidDepthPreRefSellers=2 end
  if AVM_DB.liquidDepthResalePct==nil then AVM_DB.liquidDepthResalePct=90 end
  if AVM_DB.liquidDepthAhCutPct==nil then AVM_DB.liquidDepthAhCutPct=5 end
  if AVM_DB.liquidDepthMinProfit==nil then AVM_DB.liquidDepthMinProfit=10000 end
  if AVM_DB.liquidDepthMinRoiPct==nil then AVM_DB.liquidDepthMinRoiPct=25 end
end
local function link_data(link)
  if not link then return 0,"" end
  local _,_,id=string.find(link,"item:(%d+)"); local _,_,key=string.find(link,"|H(item:[^|]+)|h"); return tonumber(id) or 0,key or ""
end
local function sig(o) return tostring(o.name).."|"..tostring(o.count).."|"..tostring(o.buyout).."|"..tostring(o.owner).."|"..tostring(o.quality).."|"..tostring(o.level).."|"..tostring(o.itemKey or "") end
local function sellers(t) local n=0; for _ in pairs(t or {}) do n=n+1 end; return n end
local function sort(t) table.sort(t,function(a,b) if a.unit~=b.unit then return a.unit<b.unit end; if a.buyout~=b.buyout then return a.buyout<b.buyout end; return tostring(a.owner or "")<tostring(b.owner or "") end) end
local function depth(offers,entry,needUnits,needSellers)
  local units,set=0,{}; for i=1,table.getn(offers or {}) do local o=offers[i]; if o.unit>entry and o.owner and o.owner~="" then units=units+o.count; set[o.owner]=true; if units>=needUnits and sellers(set)>=needSellers then return o.unit,units,sellers(set) end end end
  return nil,units,sellers(set)
end
local function model(raw,d,pct)
  if not d or raw.unit*100>d*pct then return nil end
  local sale=math.floor(d*(tonumber(AVM_DB.liquidDepthResalePct) or 90)/100); local net=math.floor(sale*raw.count*(100-(tonumber(AVM_DB.liquidDepthAhCutPct) or 5))/100); local profit=net-raw.buyout
  if profit<(tonumber(AVM_DB.liquidDepthMinProfit) or 10000) or profit*100<raw.buyout*(tonumber(AVM_DB.liquidDepthMinRoiPct) or 25) then return nil end
  return {sale=sale,net=net,profit=profit,roi=math.floor(profit*100/raw.buyout)}
end
local function cap(raw)
  local b=raw.buyout; local k=tostring(raw.itemId)
  if b<1 or b>(tonumber(AVM_DB.liquidDepthMaxBuyout) or 100000) then return false,"listing-cap" end
  if L.sessionCommitted+b>(tonumber(AVM_DB.liquidDepthMaxSessionCommitted) or 500000) then return false,"session-cap" end
  if (tonumber(L.itemCommitted[k]) or 0)+b>(tonumber(AVM_DB.liquidDepthMaxItemCommitted) or 200000) then return false,"item-cap" end
  if b>GetMoney() then return false,"wallet" end
  local gs=tonumber(AVM_DB.maxSessionSpend) or 0; if gs>0 and (tonumber(AVM.sessionSpend) or 0)+b>gs then return false,"global-session-cap" end
  local gb=tonumber(AVM_DB.maxSessionBuys) or 0; if gb>0 and (tonumber(AVM.sessionBuys) or 0)>=gb then return false,"global-buy-cap" end
  return true,nil
end
local function recent(raw)
  local k=tostring(raw.itemId).."|"..tostring(raw.count).."|"..tostring(raw.buyout).."|"..tostring(raw.owner or ""); local u=tonumber(L.recent[k]) or 0
  if u<=now() then L.recent[k]=nil; return false end; return true
end
local function add(record)
  if not record then return end
  local name=record.name; local count=tonumber(record.count or record.aux_quantity) or 0; local buyout=tonumber(record.buyout_price or record.buyout) or 0; local id=tonumber(record.item_id or record.itemId) or 0; local ms=tonumber(record.max_stack or record.maxStack) or 0; local owner=record.owner
  if not name or count<1 or buyout<1 or id<1 or ms<5 or (owner and owner==UnitName("player")) then return end
  local k=tostring(id); local b=L.books[k] or {itemId=id,name=name,maxStack=ms,offers={}}; L.books[k]=b; if ms>b.maxStack then b.maxStack=ms end
  table.insert(b.offers,{name=name,count=count,buyout=buyout,unit=math.floor(buyout/count),itemId=id,maxStack=ms,owner=owner})
end
local function pick()
  if not AVM_DB.liquidDepthEnabled or not AVM_DB.auxArbEnabled or not AVM_DB.auxArbLive or L.verify or L.pending or L.unknown then return nil end
  local best=nil; for _,b in pairs(L.books) do sort(b.offers); for i=1,table.getn(b.offers) do local r=b.offers[i]; local ok=cap(r); if ok and not recent(r) then
    local d=depth(b.offers,r.unit,tonumber(AVM_DB.liquidDepthPreRefUnits) or 10,tonumber(AVM_DB.liquidDepthPreRefSellers) or 2); local m=model(r,d,tonumber(AVM_DB.liquidDepthPreEntryPct) or 70)
    if m and (not best or m.profit>best.preProfit or (m.profit==best.preProfit and r.buyout<best.buyout)) then r.preDepth=d; r.preProfit=m.profit; best=r end
  end end end; return best
end
local function busy()
  if AVM.pending or AVM.unknown or AVM.candidate or AVM.bidPending or AVM.bidCandidate then return true end; local a=AVM.auxArb or {}; if a.deVerify or a.flipVerify or a.postscanCandidate or a.paused or a.pausePending or a.resumePending then return true end
  local p=tostring(AVM.phase or ""); return p=="DE_MAT_REVALIDATE" or p=="FLIP_MARKET_REVALIDATE" or p=="REVALIDATE" or p=="BUY_PENDING" or p=="BID_REVALIDATE" or p=="BID_PENDING" or p=="UNKNOWN_HOLD"
end
local function resume(reason) L.verify=nil; L.pending=nil; L.unknown=nil; if AVM.auxLoop then AVM.auxLoop.nextAt=now()+0.25 end; log("RESUME "..tostring(reason)) end
local function reject(reason) if L.verify and L.verify.candidate then local r=L.verify.candidate; L.recent[tostring(r.itemId).."|"..tostring(r.count).."|"..tostring(r.buyout).."|"..tostring(r.owner or "")]=now()+15 end; L.verify=nil; if AVM.auxLoop then AVM.auxLoop.nextAt=now()+0.25 end; log("REJECT "..tostring(reason)) end
local function start(r)
  if not r or busy() then return end; L.verify={candidate=r,page=0,lastPage=0,inflight=false,sent=0,nextAt=now()+0.2,offers={},found=nil,foundPage=nil,stage="scan"}; if AVM.auxLoop then AVM.auxLoop.nextAt=now()+60 end
  log("VERIFY start "..r.name.." buy="..money(r.buyout).." prelimDepth="..money(r.preDepth or 0))
end
local function query()
  local v=L.verify; if not v or v.inflight or AVM.queryInFlight or not AVM.open then return end; v.inflight=true; v.sent=now(); QueryAuctionItems(v.candidate.name,nil,nil,0,0,0,v.page,false,0,false)
end
local function rows(v)
  local n,total=GetNumAuctionItems("list"); n=tonumber(n) or 0; total=tonumber(total) or 0; local found=nil
  for i=1,n do local name,_,count,quality,_,level,_,_,buyout,_,_,owner=GetAuctionItemInfo("list",i); local id,key=link_data(GetAuctionItemLink("list",i)); if name and id==v.candidate.itemId and count and count>0 and buyout and buyout>0 then
    local o={name=name,count=count,buyout=buyout,unit=math.floor(buyout/count),itemId=id,owner=owner,quality=quality,level=level,itemKey=key,index=i,page=v.page}; if v.stage=="scan" then table.insert(v.offers,o) end
    if count==v.candidate.count and buyout==v.candidate.buyout and (not v.candidate.owner or v.candidate.owner=="" or owner==v.candidate.owner) then found=o end
  end end; return found,total
end
local function confirm_record(p,late)
  local c=p.candidate; AVM.stats.confirmed=(tonumber(AVM.stats.confirmed) or 0)+1; AVM.sessionSpend=(tonumber(AVM.sessionSpend) or 0)+c.buyout; AVM.sessionBuys=(tonumber(AVM.sessionBuys) or 0)+1; AVM.recent=AVM.recent or {}; AVM.recent[c.signature]=now()+15
  if AVM_RecordPurchase then AVM_RecordPurchase(c,late and "confirmed-late" or "confirmed") end; log((late and "CONFIRMED_LATE " or "CONFIRMED ")..c.name.." buy="..money(c.buyout).." profit="..money(c.profit).." roi="..tostring(c.liquidRoiPct).."%")
end
local function buy(v,found)
  local r=v.candidate; local ok,why=cap(r); if not ok or not found or found.count~=r.count or found.buyout~=r.buyout then return reject(why or "listing-changed") end
  local m=v.verified; local c={name=found.name,count=found.count,buyout=found.buyout,unit=found.unit,owner=found.owner,quality=found.quality,level=found.level,itemKey=found.itemKey,signature=sig(found),sourcePage=found.page,mode="liquid_depth",route="LIQUID_DEPTH",valuationTotal=m.net,profit=m.profit,liquidDepthUnit=v.depthUnit,liquidSaleUnit=m.sale,liquidRoiPct=m.roi}
  local k=tostring(r.itemId); L.sessionCommitted=L.sessionCommitted+r.buyout; L.itemCommitted[k]=(tonumber(L.itemCommitted[k]) or 0)+r.buyout; L.verify=nil; local before=GetMoney(); PlaceAuctionBid("list",found.index,found.buyout); AVM.stats.buySent=(tonumber(AVM.stats.buySent) or 0)+1; L.pending={candidate=c,moneyBefore=before,sent=now()}
  log("BUY_SENT "..c.name.." buy="..money(c.buyout).." depth="..money(c.liquidDepthUnit).." profit="..money(c.profit).." roi="..tostring(c.liquidRoiPct).."% committed="..money(L.sessionCommitted))
end
local function result()
  local v=L.verify; if not v or not v.inflight then return end; v.inflight=false; local found,total=rows(v)
  if v.stage=="return" then if not found then return reject("listing-missing-final") end; return buy(v,found) end
  if found then v.found=found; v.foundPage=v.page end; v.lastPage=total>0 and math.floor((total-1)/50) or 0; if v.page<v.lastPage then v.page=v.page+1; v.nextAt=now()+0.4; return end; if not v.found then return reject("listing-missing") end
  sort(v.offers); local d,u,s=depth(v.offers,v.candidate.unit,tonumber(AVM_DB.liquidDepthMinRefUnits) or 20,tonumber(AVM_DB.liquidDepthMinRefSellers) or 3); local m=model(v.candidate,d,tonumber(AVM_DB.liquidDepthEntryPct) or 60); local ok,why=cap(v.candidate)
  if not d then return reject("depth "..tostring(u).."u/"..tostring(s).."s") end; if not m then return reject("price/profit/roi") end; if not ok then return reject(why) end
  v.verified=m; v.depthUnit=d; v.stage="return"; v.page=v.foundPage or 0; v.nextAt=now()+0.4; log("VERIFY pass "..v.candidate.name.." ref="..money(d).." units="..tostring(u).." sellers="..tostring(s).." profit="..money(m.profit).." roi="..tostring(m.roi).."%")
end
local function tick_tx(t)
  if L.pending then local p=L.pending; local delta=p.moneyBefore-GetMoney(); if delta==p.candidate.buyout then confirm_record(p,false); return resume("confirmed") end; if t-p.sent>=3 then AVM.stats.unknown=(tonumber(AVM.stats.unknown) or 0)+1; L.unknown={candidate=p.candidate,moneyBefore=p.moneyBefore,untilAt=t+10}; L.pending=nil; log("UNKNOWN "..p.candidate.name.." - hold 10s") end; return true end
  if L.unknown then local u=L.unknown; if u.moneyBefore-GetMoney()==u.candidate.buyout then confirm_record(u,true); return resume("confirmed-late") end; if t>=u.untilAt then return resume("unknown-expired") end; return true end; return false
end
local function install()
  if L.installed or not AVM_DB or not AVM or not AVM_AuxArbScanStart or not AVM_AuxArbAuction or not AVM_AuxArbScanDone then return end; defaults()
  local oldStart=AVM_AuxArbScanStart; AVM_AuxArbScanStart=function(resumeFlag,filter) L.books={}; return oldStart(resumeFlag,filter) end
  local oldAuction=AVM_AuxArbAuction; AVM_AuxArbAuction=function(record) oldAuction(record); if AVM_DB.liquidDepthEnabled and AVM_DB.auxArbEnabled and AVM_DB.auxArbLive then add(record) end end
  local oldDone=AVM_AuxArbScanDone; AVM_AuxArbScanDone=function() local r=pick(); oldDone(); if r and not busy() then start(r) end end
  L.installed=true; log("ACTIVE entry<=60% exactDepth sellers>=3 units>=20 maxBuy=10g itemCap=20g sessionCap=50g")
end
local f=CreateFrame("Frame","AVMLiquidDepthFrame"); f:RegisterEvent("AUCTION_ITEM_LIST_UPDATE"); f:SetScript("OnEvent",function() if L.verify and L.verify.inflight then result() end end)
f:SetScript("OnUpdate",function() install(); local t=now(); if L.pending or L.unknown then if AVM.auxLoop then AVM.auxLoop.nextAt=t+60 end; tick_tx(t); return end; local v=L.verify; if not v then return end; if not AVM_DB.liquidDepthEnabled or not AVM_DB.auxArbEnabled or not AVM_DB.auxArbLive or AVM.hardStop or not AVM.open then return reject("disabled/closed") end; if AVM.auxLoop then AVM.auxLoop.nextAt=t+60 end; if v.inflight then if t-v.sent>8 then reject("query-timeout") end; return end; if t>=(v.nextAt or 0) then query() end end)
install()
