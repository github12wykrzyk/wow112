-- AuxVmangos defensive arbitrage rules v3.
-- Supersedes the legacy BID executor at runtime without modifying the proven Vendor/DE buyout core.
-- BID v3 accepts auctions with or without buyout, revalidates exact item results, and fails closed.

AVM_BID_V3_VERSION = "0.3-defensive-bid-resell"
AVM_BID_V3 = AVM_BID_V3 or {
	installed = false,
	books = {},
	bidRows = {},
	ready = nil,
	verify = nil,
	sessionCommitted = 0,
	sessionPlaced = 0,
}
local B = AVM_BID_V3

local okAux, aux = pcall(require, "aux")
local okInfo, info = pcall(require, "aux.util.info")
local okDe, de = pcall(require, "aux.core.disenchant")
local okHistory, history = pcall(require, "aux.core.history")

local function now() return tonumber(GetTime()) or 0 end
local function clamp(v, lo, hi)
	v = tonumber(v) or lo
	if v < lo then return lo end
	if v > hi then return hi end
	return v
end
local function money(v)
	v = math.floor(tonumber(v) or 0)
	local g = math.floor(v / 10000)
	local s = math.floor(math.mod(v,10000) / 100)
	local c = math.mod(v,100)
	if g > 0 then return tostring(g).."g"..tostring(s).."s"..tostring(c).."c" end
	if s > 0 then return tostring(s).."s"..tostring(c).."c" end
	return tostring(c).."c"
end
local function log(msg)
	if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage("|cff60ff00[AVM]|r BID_V3 "..tostring(msg)) end
	if AVM_DB then
		AVM_DB.diag = AVM_DB.diag or {seq=0,events={},state={}}
		AVM_DB.diag.events = AVM_DB.diag.events or {}
		AVM_DB.diag.seq = (tonumber(AVM_DB.diag.seq) or 0) + 1
		table.insert(AVM_DB.diag.events, tostring(AVM_DB.diag.seq).."@"..tostring(math.floor(now()*1000)).." BID_V3 "..tostring(msg))
		while table.getn(AVM_DB.diag.events) > 80 do table.remove(AVM_DB.diag.events,1) end
	end
end

function AVM_BID_RULES_EnsureDefaults()
	if type(AVM_DB) ~= "table" then return end
	-- BUYOUT controls. Zero vendor margin preserves the gameplay-confirmed Vendor behavior until user changes it.
	if AVM_DB.vendorSafetyMarginPct == nil then AVM_DB.vendorSafetyMarginPct = 0 end
	-- BID route controls.
	if AVM_DB.bidArbEnabled == nil then AVM_DB.bidArbEnabled = true end
	if AVM_DB.bidVendorEnabled == nil then AVM_DB.bidVendorEnabled = true end
	if AVM_DB.bidDeEnabled == nil then AVM_DB.bidDeEnabled = true end
	if AVM_DB.bidResellEnabled == nil then AVM_DB.bidResellEnabled = true end
	if AVM_DB.bidVendorMarginPct == nil then AVM_DB.bidVendorMarginPct = 25 end
	if AVM_DB.bidVendorMinProfit == nil then AVM_DB.bidVendorMinProfit = 5000 end -- 50s
	if AVM_DB.bidVendorMaxAmount == nil then AVM_DB.bidVendorMaxAmount = 50000 end -- 5g
	if AVM_DB.bidDeMarginPct == nil then AVM_DB.bidDeMarginPct = 45 end
	if AVM_DB.bidDeMinProfit == nil then AVM_DB.bidDeMinProfit = 10000 end -- 1g
	if AVM_DB.bidDeMaxAmount == nil then AVM_DB.bidDeMaxAmount = 50000 end
	if AVM_DB.bidResellMarginPct == nil then AVM_DB.bidResellMarginPct = 40 end
	if AVM_DB.bidResellMinProfit == nil then AVM_DB.bidResellMinProfit = 10000 end
	if AVM_DB.bidResellMaxAmount == nil then AVM_DB.bidResellMaxAmount = 50000 end
	if AVM_DB.bidResellHistMaxPct == nil then AVM_DB.bidResellHistMaxPct = 60 end
	if AVM_DB.bidResellMinHistoryDays == nil then AVM_DB.bidResellMinHistoryDays = 3 end
	if AVM_DB.bidResellDepthUnits == nil then AVM_DB.bidResellDepthUnits = 10 end
	if AVM_DB.bidResellMinSellers == nil then AVM_DB.bidResellMinSellers = 3 end
	if AVM_DB.bidResellResalePct == nil then AVM_DB.bidResellResalePct = 90 end
	if AVM_DB.bidResellAhCutPct == nil then AVM_DB.bidResellAhCutPct = 5 end
	if AVM_DB.bidV3MaxDuration == nil then AVM_DB.bidV3MaxDuration = 1 end
	if AVM_DB.bidV3MaxSessionPlacements == nil then AVM_DB.bidV3MaxSessionPlacements = 6 end
	if AVM_DB.bidV3MaxSessionCommitted == nil then AVM_DB.bidV3MaxSessionCommitted = 300000 end -- 30g cumulative commitment
	if AVM_DB.bidV3RecentSeconds == nil then AVM_DB.bidV3RecentSeconds = 30 end
	if AVM_DB.bidV3VerifyMaxAge == nil then AVM_DB.bidV3VerifyMaxAge = 45 end
end

local function seller_count(t)
	local n = 0
	for _ in pairs(t or {}) do n = n + 1 end
	return n
end

local function item_key(record)
	if record and record.item_key and record.item_key ~= "" then return tostring(record.item_key) end
	local id = tonumber(record and (record.item_id or record.itemId)) or 0
	local suffix = tonumber(record and (record.suffix_id or record.suffixId)) or 0
	return tostring(id)..":"..tostring(suffix)
end

local function vendor_value(itemId)
	itemId = tonumber(itemId)
	if not itemId then return 0,"" end
	local learned = 0
	if okAux and aux and aux.account_data and aux.account_data.merchant_sell then learned = tonumber(aux.account_data.merchant_sell[itemId]) or 0 end
	if learned > 0 then return learned,"aux-learned" end
	local static = AVM_VENDOR_VALUES and tonumber(AVM_VENDOR_VALUES[itemId]) or 0
	if static > 0 then return static,"turtle-db" end
	return 0,""
end

local function history_value(record)
	if not okHistory or not history or not history.value then return 0,0 end
	local key = item_key(record)
	local ok,v = pcall(history.value,key)
	if not ok or not tonumber(v) then return 0,0 end
	local days = 0
	if history.data_points then
		local okp,p = pcall(history.data_points,key)
		if okp and type(p)=="table" then days=table.getn(p) end
	end
	return tonumber(v) or 0,days
end

local function bid_raw(record)
	if not record or not AVM_DB or not AVM_DB.bidArbEnabled then return nil end
	if record.owner and record.owner == UnitName("player") then return nil end
	if record.high_bidder then return nil end
	local id = tonumber(record.item_id or record.itemId)
	local count = tonumber(record.aux_quantity or record.count) or 0
	local bid = tonumber(record.bid_price) or 0
	local buyout = tonumber(record.buyout_price or record.buyout) or 0
	local duration = tonumber(record.duration) or 0
	local maxDuration = tonumber(AVM_DB.bidV3MaxDuration) or 1
	if not id or count < 1 or bid < 1 then return nil end
	if duration < 1 or duration > maxDuration then return nil end
	-- Auctions with buyout are valid BID targets, but never bid at/above their buyout.
	if buyout > 0 and bid >= buyout then return nil end
	return {
		name=tostring(record.name or ""), itemId=id, item_id=id, count=count, aux_quantity=count,
		quality=tonumber(record.quality), level=tonumber(record.level) or 0, slot=record.slot,
		owner=record.owner, itemKey=item_key(record), duration=duration,
		bidAmount=math.floor(bid), buyoutPrice=math.floor(buyout),
		startPrice=tonumber(record.start_price) or 0, maxStack=tonumber(record.max_stack or record.maxStack) or 0,
		sourcePage=tonumber(record.page) or 0, discoveredAt=now(),
	}
end

local function offer_add(book,record)
	if not record then return end
	local buyout = tonumber(record.buyout_price or record.buyout) or 0
	local count = tonumber(record.aux_quantity or record.count) or 0
	local id = tonumber(record.item_id or record.itemId)
	if not id or count < 1 or buyout < 1 then return end
	local key = item_key(record)
	local row = book[key]
	if not row then row={itemId=id,key=key,offers={}};book[key]=row end
	table.insert(row.offers,{
		unit=buyout/count,count=count,buyout=buyout,owner=record.owner,
		startPrice=tonumber(record.start_price) or 0,bidAmount=tonumber(record.bid_price) or 0,
	})
end

local function same_listing(offer,raw)
	if not offer or not raw then return false end
	if raw.owner and raw.owner ~= "" and offer.owner and offer.owner ~= raw.owner then return false end
	return tonumber(offer.count)==tonumber(raw.count) and tonumber(offer.buyout)==tonumber(raw.buyoutPrice) and tonumber(offer.startPrice)==tonumber(raw.startPrice)
end

local function reference_floor(book,raw)
	local row = book and book[raw.itemKey]
	if not row then return nil,0,0 end
	local offers = {}
	for i=1,table.getn(row.offers or {}) do
		local o=row.offers[i]
		if not same_listing(o,raw) then table.insert(offers,o) end
	end
	table.sort(offers,function(a,b) if a.unit~=b.unit then return a.unit<b.unit end return a.count>b.count end)
	local needUnits = math.max(1,math.floor(tonumber(AVM_DB.bidResellDepthUnits) or 10))
	local needSellers = math.max(1,math.floor(tonumber(AVM_DB.bidResellMinSellers) or 3))
	local units,set=0,{}
	for i=1,table.getn(offers) do
		local o=offers[i]
		units=units+(tonumber(o.count) or 0)
		if o.owner and o.owner~="" then set[o.owner]=true end
		if units>=needUnits and seller_count(set)>=needSellers then return tonumber(o.unit),units,seller_count(set) end
	end
	return nil,units,seller_count(set)
end

local function de_depth_price(book,itemId,depth)
	local row=book and book[tonumber(itemId)]
	depth=math.max(1,math.floor(tonumber(depth) or 3))
	if not row or (tonumber(row.units) or 0)<depth then return nil end
	local offers={}
	for i=1,table.getn(row.offers or {}) do
		local o=row.offers[i]
		if o and (tonumber(o.unit) or 0)>0 and (tonumber(o.count) or 0)>0 then table.insert(offers,{unit=tonumber(o.unit),count=tonumber(o.count)}) end
	end
	table.sort(offers,function(a,b) if a.unit~=b.unit then return a.unit<b.unit end return a.count>b.count end)
	local units=0
	for i=1,table.getn(offers) do units=units+offers[i].count;if units>=depth then return offers[i].unit end end
	return nil
end

local function de_value(raw,book)
	if not okDe or not de then return 0,"no-de-module" end
	if raw.quality~=2 and raw.quality~=3 and raw.quality~=4 then return 0,"quality" end
	if not raw.slot then return 0,"slot" end
	if AVM_TURTLE_DISENCHANT_BLOCK and AVM_TURTLE_DISENCHANT_BLOCK[raw.itemId] then return 0,"blocked" end
	local dist,source=nil,""
	if AVM_TURTLE_DISENCHANT_IDS then
		local did=tonumber(AVM_TURTLE_DISENCHANT_IDS[raw.itemId])
		if did and did>0 then dist=AVM_TURTLE_DISENCHANT_LOOT and AVM_TURTLE_DISENCHANT_LOOT[did];source="turtle-db" end
	end
	if not dist then
		local ok,d=pcall(de.distribution,raw.slot,raw.quality,raw.level or 0,raw.itemId)
		if ok then dist=d;source="aux-fallback" end
	end
	if type(dist)~="table" or table.getn(dist)==0 then return 0,"no-distribution" end
	local depth=math.max(1,math.floor(tonumber(AVM_DB.deDepthUnits) or 3))
	local cut=clamp(AVM_DB.deAhCutPct or 5,0,30)
	local expected=0
	for i=1,table.getn(dist) do
		local e=dist[i];local mid=tonumber(e.item_id);local floor=de_depth_price(book,mid,depth)
		if not floor then return 0,"material-depth" end
		local p=tonumber(e.probability) or 0
		local q=((tonumber(e.min_quantity) or 0)+(tonumber(e.max_quantity) or 0))/2
		expected=expected+p*q*math.floor(floor*(100-cut)/100)
	end
	return math.floor(expected*raw.count),source
end

local function route_candidate(raw,route,book,marketBook)
	if not raw then return nil end
	local value,maxBid,minProfit,maxAmount,source=0,0,0,0,""
	if route=="vendor" then
		if not AVM_DB.bidVendorEnabled then return nil end
		local unit,s=vendor_value(raw.itemId);if unit<=0 then return nil end
		value=unit*raw.count;source=s
		maxBid=math.floor(value*(100-clamp(AVM_DB.bidVendorMarginPct or 25,0,90))/100)
		minProfit=tonumber(AVM_DB.bidVendorMinProfit) or 0;maxAmount=tonumber(AVM_DB.bidVendorMaxAmount) or 0
	elseif route=="de" then
		if not AVM_DB.bidDeEnabled then return nil end
		value,source=de_value(raw,book);if value<=0 then return nil end
		maxBid=math.floor(value*(100-clamp(AVM_DB.bidDeMarginPct or 45,0,90))/100)
		minProfit=tonumber(AVM_DB.bidDeMinProfit) or 0;maxAmount=tonumber(AVM_DB.bidDeMaxAmount) or 0
	elseif route=="resell" then
		if not AVM_DB.bidResellEnabled then return nil end
		local hist,days=history_value(raw);if hist<=0 or days<(tonumber(AVM_DB.bidResellMinHistoryDays) or 3) then return nil end
		if (raw.bidAmount/raw.count)*100>hist*clamp(AVM_DB.bidResellHistMaxPct or 60,1,100) then return nil end
		local floor,units,sellers=reference_floor(marketBook,raw);if not floor then return nil end
		local resale=math.floor(floor*clamp(AVM_DB.bidResellResalePct or 90,1,100)/100)
		if resale>hist then resale=math.floor(hist) end
		if resale<=0 then return nil end
		local cut=clamp(AVM_DB.bidResellAhCutPct or 5,0,30)
		value=math.floor(resale*raw.count*(100-cut)/100);source="history+live-depth"
		maxBid=math.floor(value*(100-clamp(AVM_DB.bidResellMarginPct or 40,0,90))/100)
		minProfit=tonumber(AVM_DB.bidResellMinProfit) or 0;maxAmount=tonumber(AVM_DB.bidResellMaxAmount) or 0
		raw.resellFloor=math.floor(floor);raw.resellHistory=math.floor(hist);raw.resellHistoryDays=days;raw.resellDepthUnits=units;raw.resellSellers=sellers
	else return nil end
	local amount=tonumber(raw.bidAmount) or 0
	if amount<=0 or value<=0 or amount>maxBid then return nil end
	if maxAmount>0 and amount>maxAmount then return nil end
	local profit=value-amount;if profit<minProfit then return nil end
	local routeName="bid-"..route
	return {
		mode="auxarb_bid_v3",route=routeName,bidKind=route,name=raw.name,itemId=raw.itemId,count=raw.count,
		bidAmount=amount,buyout=amount,buyoutPrice=raw.buyoutPrice,valuationTotal=value,profit=profit,maxBid=maxBid,
		owner=raw.owner,quality=raw.quality,level=raw.level,slot=raw.slot,itemKey=raw.itemKey,duration=raw.duration,
		bidSource=source,sourcePage=raw.sourcePage or 0,discoveredAt=raw.discoveredAt or now(),
		resellFloor=raw.resellFloor,resellHistory=raw.resellHistory,resellHistoryDays=raw.resellHistoryDays,
		resellDepthUnits=raw.resellDepthUnits,resellSellers=raw.resellSellers,
		bidKey="BIDV3|"..routeName.."|"..tostring(raw.itemKey or raw.itemId),
	}
end

local function better(a,b)
	if not a then return false end
	if not b then return true end
	local ap,bp=tonumber(a.profit) or 0,tonumber(b.profit) or 0
	if ap~=bp then return ap>bp end
	return (tonumber(a.bidAmount) or 0)<(tonumber(b.bidAmount) or 0)
end

local function gates(c)
	if not c or not AVM_DB.bidArbEnabled or not AVM_DB.auxArbLive then return false,"live-off" end
	if (tonumber(c.bidAmount) or 0)>(GetMoney() or 0) then return false,"wallet" end
	local pcap=tonumber(AVM_DB.bidV3MaxSessionPlacements) or 0
	if pcap>0 and (tonumber(B.sessionPlaced) or 0)>=pcap then return false,"placement-cap" end
	local scap=tonumber(AVM_DB.bidV3MaxSessionCommitted) or 0
	if scap>0 and (tonumber(B.sessionCommitted) or 0)+(tonumber(c.bidAmount) or 0)>scap then return false,"capital-cap" end
	if AVM.recent and c.bidKey and AVM.recent[c.bidKey] and now()<(tonumber(AVM.recent[c.bidKey]) or 0) then return false,"recent" end
	return true,"ok"
end

local function pick(book,marketBook,rows)
	local best=nil
	for i=1,table.getn(rows or {}) do
		local raw=rows[i]
		local c=route_candidate(raw,"vendor",book,marketBook);if c and gates(c) and better(c,best) then best=c end
		c=route_candidate(raw,"de",book,marketBook);if c and gates(c) and better(c,best) then best=c end
		c=route_candidate(raw,"resell",book,marketBook);if c and gates(c) and better(c,best) then best=c end
	end
	return best
end

local function busy()
	if not AVM or AVM.hardStop or not AVM.open then return true end
	if AVM.pending or AVM.unknown or AVM.bidPending or AVM.bidCandidate or AVM.queryInFlight then return true end
	local a=AVM.auxArb or {}
	if a.active or a.paused or a.pausePending or a.resumePending or a.deVerify or a.flipVerify or a.postscanCandidate then return true end
	local l=AVM_LIQUID_DEPTH
	if l and (l.verify or l.pending or l.unknown) then return true end
	return false
end

local function start_verify(c)
	local ok,why=gates(c);if not ok then B.ready=nil;log("BLOCK "..tostring(c.name).." reason="..tostring(why));return false end
	local maxAge=tonumber(AVM_DB.bidV3VerifyMaxAge) or 45
	if now()-(tonumber(c.discoveredAt) or now())>maxAge then B.ready=nil;log("REJECT stale "..tostring(c.name));return false end
	B.ready=nil
	B.verify={candidate=c,page=0,lastPage=0,inflight=false,sentAt=0,nextAt=now()+0.15,rows={},book={}}
	AVM.bidCandidate=c
	if AVM.auxLoop then AVM.auxLoop.nextAt=now()+60 end
	log("VERIFY start route="..tostring(c.route).." "..tostring(c.name).." bid="..money(c.bidAmount).." ceiling="..money(c.maxBid).." buyout="..money(c.buyoutPrice or 0))
	return true
end

local function verify_query()
	local v=B.verify
	if not v or v.inflight or not AVM.open or AVM.queryInFlight then return end
	v.inflight=true;v.sentAt=now()
	QueryAuctionItems(v.candidate.name,nil,nil,0,0,0,v.page,false,0,false)
end

local function verify_result()
	local v=B.verify;if not v or not v.inflight then return end
	v.inflight=false
	local n,total=GetNumAuctionItems("list");n=tonumber(n) or 0;total=tonumber(total) or 0
	for i=1,n do
		local r=okInfo and info and info.auction and info.auction(i,"list") or nil
		if r and tonumber(r.item_id)==tonumber(v.candidate.itemId) and item_key(r)==tostring(v.candidate.itemKey) then
			r.index=i;r.page=v.page
			offer_add(v.book,r)
			local raw=bid_raw(r);if raw then raw.index=i;raw.page=v.page;table.insert(v.rows,raw) end
		end
	end
	v.lastPage=total>0 and math.floor((total-1)/50) or 0
	if v.page<v.lastPage then v.page=v.page+1;v.nextAt=now()+0.35;return end
	local route=string.sub(tostring(v.candidate.route or ""),5)
	local best=nil
	for i=1,table.getn(v.rows) do
		local c=route_candidate(v.rows[i],route,AVM.auxArb and AVM.auxArb.deMaterialBook or {},v.book)
		if c and gates(c) and better(c,best) then best=c;best.index=v.rows[i].index;best.page=v.rows[i].page end
	end
	if not best or not best.index then
		AVM.bidCandidate=nil;B.verify=nil;log("REJECT route="..tostring(v.candidate.route).." "..tostring(v.candidate.name).." reason=fresh-threshold-or-listing");if AVM.auxLoop then AVM.auxLoop.nextAt=now()+0.25 end;return
	end
	local before=GetMoney() or 0
	if best.bidAmount>before then AVM.bidCandidate=nil;B.verify=nil;log("REJECT wallet-changed");return end
	local recent=math.max(5,tonumber(AVM_DB.bidV3RecentSeconds) or 30)
	AVM.recent=AVM.recent or {};AVM.recent[best.bidKey]=now()+recent
	B.sessionCommitted=(tonumber(B.sessionCommitted) or 0)+best.bidAmount
	B.sessionPlaced=(tonumber(B.sessionPlaced) or 0)+1
	AVM.bidCandidate=nil;B.verify=nil
	PlaceAuctionBid("list",best.index,best.bidAmount)
	-- Reuse the proven core wallet-delta confirmation path.
	AVM.bidPending={candidate=best,moneyBefore=before,sentAt=now()}
	AVM.phase="BID_PENDING"
	log("SENT route="..tostring(best.route).." "..tostring(best.name).." bid="..money(best.bidAmount).." ceiling="..money(best.maxBid).." value="..money(best.valuationTotal).." profit="..money(best.profit).." committed="..money(B.sessionCommitted))
end

local function sanitize_vendor_buyout()
	local a=AVM and AVM.auxArb
	local c=a and a.pageBest
	if not c or tostring(c.route)~="vendor" then return end
	local margin=clamp(AVM_DB.vendorSafetyMarginPct or 0,0,90)
	if margin<=0 then return end
	local value=tonumber(c.valuationTotal) or 0;local buy=tonumber(c.buyout) or 0
	if value<=0 or buy*100>value*(100-margin) then
		a.pageBest=nil
		if a.bestSeen==c then a.bestSeen=nil end
	end
end

local function install()
	if B.installed or not AVM or not AVM_DB or not AVM_AuxArbScanStart or not AVM_AuxArbAuction or not AVM_AuxArbScanDone then return end
	AVM_BID_RULES_EnsureDefaults()
	local oldStart=AVM_AuxArbScanStart
	AVM_AuxArbScanStart=function(resumeFlag,filter)
		if not resumeFlag then B.books={};B.bidRows={} end
		return oldStart(resumeFlag,filter)
	end
	local oldAuction=AVM_AuxArbAuction
	AVM_AuxArbAuction=function(record)
		local master=AVM_DB.bidArbEnabled
		-- Suppress only the legacy BID collector; buyout Vendor/DE/Flip remain unchanged.
		AVM_DB.bidArbEnabled=false
		oldAuction(record)
		AVM_DB.bidArbEnabled=master
		sanitize_vendor_buyout()
		if master and record and record.blizzard_query then
			offer_add(B.books,record)
			local raw=bid_raw(record);if raw then table.insert(B.bidRows,raw) end
		end
	end
	local oldDone=AVM_AuxArbScanDone
	AVM_AuxArbScanDone=function()
		local master=AVM_DB.bidArbEnabled
		local nominated=master and pick(AVM.auxArb and AVM.auxArb.deMaterialBook or {},B.books,B.bidRows) or nil
		AVM_DB.bidArbEnabled=false
		oldDone()
		AVM_DB.bidArbEnabled=master
		if nominated then
			B.ready=nominated
			if AVM.auxLoop then AVM.auxLoop.nextAt=now()+60 end
			if not busy() then start_verify(nominated) end
		end
	end
	B.installed=true
	log("ACTIVE buyout-bids=allowed routes=vendor/de/resell exact-recheck=true")
end

local f=CreateFrame("Frame","AVMDefensiveBidV3Frame")
f:RegisterEvent("AUCTION_HOUSE_SHOW")
f:RegisterEvent("AUCTION_HOUSE_CLOSED")
f:RegisterEvent("AUCTION_ITEM_LIST_UPDATE")
f:SetScript("OnEvent",function()
	if event=="AUCTION_HOUSE_SHOW" then B.sessionCommitted=0;B.sessionPlaced=0;B.ready=nil;B.verify=nil
	elseif event=="AUCTION_HOUSE_CLOSED" then B.ready=nil;B.verify=nil;AVM.bidCandidate=nil
	elseif event=="AUCTION_ITEM_LIST_UPDATE" and B.verify and B.verify.inflight then verify_result() end
end)
f:SetScript("OnUpdate",function()
	install();if not B.installed or not AVM_DB then return end
	if B.ready and not busy() then start_verify(B.ready) end
	local v=B.verify;if not v then return end
	if not AVM_DB.bidArbEnabled or not AVM_DB.auxArbLive or AVM.hardStop or not AVM.open then B.verify=nil;AVM.bidCandidate=nil;log("REJECT disabled/closed");return end
	if AVM.auxLoop then AVM.auxLoop.nextAt=now()+60 end
	if v.inflight then if now()-v.sentAt>8 then B.verify=nil;AVM.bidCandidate=nil;log("REJECT query-timeout") end;return end
	if now()>=(v.nextAt or 0) then verify_query() end
end)
install()
