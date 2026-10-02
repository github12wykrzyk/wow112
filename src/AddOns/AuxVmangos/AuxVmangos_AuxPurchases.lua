-- Native AUX purchase-history tab for WoW 1.12.1.
local T = require 'T'
local aux = require 'aux'
local gui = require 'aux.gui'
local listing_lib = require 'aux.gui.listing'
local money = require 'aux.util.money'

AVM_AUX_UI = AVM_AUX_UI or {}
if not AVM_AUX_UI.layoutApplied and aux.frame and UIParent then
	local sw = tonumber(UIParent:GetWidth()) or 1024
	local sh = tonumber(UIParent:GetHeight()) or 768
	local w = math.min(1100, math.max(768, sw - 40))
	local h = math.min(560, math.max(447, sh - 120))
	aux.frame:SetWidth(w)
	aux.frame:SetHeight(h)
	aux.frame:ClearAllPoints()
	aux.frame:SetPoint('CENTER', UIParent, 'CENTER', 0, 0)
	AVM_AUX_UI.layoutApplied = true
end

function AVM_AUX_UI.BottomStatusWidth(reserved)
	return math.max(265, (tonumber(aux.frame and aux.frame:GetWidth()) or 768) - (tonumber(reserved) or 225))
end

local function sort_value(row, spec)
	local v = row and row[spec.key]
	if spec.numeric then return tonumber(v) or 0 end
	return string.lower(tostring(v or ''))
end

function AVM_AUX_UI.SortRecords(rows, listing)
	local specs = listing and listing.avmSortSpecs
	local idx = listing and listing.avmSortIndex
	local spec = specs and specs[idx]
	if not spec then return end
	local descending = listing.avmSortDescending and true or false
	table.sort(rows, function(a,b)
		local av,bv = sort_value(a,spec),sort_value(b,spec)
		if av == bv then
			local as,bs = tonumber(a and a.seq) or 0, tonumber(b and b.seq) or 0
			if as == bs then
				local an = tostring(a and (a.item or a.name) or '')
				local bn = tostring(b and (b.item or b.name) or '')
				if an == bn then return false end
				if descending then return an > bn end
				return an < bn
			end
			if descending then return as > bs end
			return as < bs
		end
		if descending then return av > bv end
		return av < bv
	end)
end

function AVM_AUX_UI.ApplySortLabels(listing)
	if not listing or not listing.avmSortSpecs then return end
	for i=1,table.getn(listing.avmSortSpecs) do
		local spec=listing.avmSortSpecs[i]
		local suffix=''
		if i==listing.avmSortIndex then suffix=listing.avmSortDescending and ' v' or ' ^' end
		if listing.colInfo and listing.colInfo[i] then listing.colInfo[i].name=tostring(spec.label or '')..suffix end
	end
end

function AVM_AUX_UI.InstallSortable(listing, specs, callback, defaultIndex, defaultDescending)
	listing.avmSortSpecs=specs
	listing.avmSortIndex=defaultIndex or 1
	listing.avmSortDescending=defaultDescending and true or false
	listing.avmSortCallback=callback
	for i=1,table.getn(listing.headCols or {}) do
		local col=listing.headCols[i]
		col:EnableMouse(true)
		col.avmSortIndex=i
		col:SetScript('OnMouseDown',function()
			local st=this.st
			local idx=this.avmSortIndex
			if not st or not idx then return end
			if st.avmSortIndex==idx then
				st.avmSortDescending=not st.avmSortDescending
			else
				st.avmSortIndex=idx
				local spec=st.avmSortSpecs and st.avmSortSpecs[idx]
				st.avmSortDescending=spec and spec.defaultDescending and true or false
			end
			if st.avmSortCallback then st.avmSortCallback() end
		end)
	end
	AVM_AUX_UI.ApplySortLabels(listing)
	listing:Update()
end

AVM_AUX_PURCHASES = AVM_AUX_PURCHASES or {}
local tab = aux.tab 'Purchases'
local API = AVM_WATCH_API
local frame = CreateFrame('Frame', nil, aux.frame)
frame:SetAllPoints()
frame:Hide()

local panel = gui.panel(frame)
panel:SetPoint('TOP', frame, 'TOP', 0, -8)
panel:SetPoint('BOTTOMLEFT', aux.frame.content, 'BOTTOMLEFT', 0, 0)
panel:SetPoint('BOTTOMRIGHT', aux.frame.content, 'BOTTOMRIGHT', 0, 0)

local history = listing_lib.new(panel)
history:SetColInfo{
	{name='Time',width=.10,align='CENTER'},
	{name='Route',width=.08,align='CENTER'},
	{name='Item',width=.26,align='LEFT'},
	{name='Qty',width=.05,align='CENTER'},
	{name='Paid',width=.11,align='RIGHT'},
	{name='Hist%',width=.09,align='RIGHT'},
	{name='Value',width=.11,align='RIGHT'},
	{name='Profit',width=.11,align='RIGHT'},
	{name='Source',width=.09,align='CENTER'},
}

local status = gui.status_bar(frame)
status:SetWidth(AVM_AUX_UI.BottomStatusWidth(225))
status:SetHeight(25)
status:SetPoint('TOPLEFT', aux.frame.content, 'BOTTOMLEFT', 0, -6)
status:update_status(1, 1)
status:set_text('')

local refresh = gui.button(frame)
refresh:SetPoint('TOPLEFT', status, 'TOPRIGHT', 5, 0)
refresh:SetText('Refresh')

local lastCount,lastConfirmed,lastSpend,lastProfit=-1,-1,-1,-1
local nextRefresh=0

local function route_text(route)
	if route=='disenchant' then return 'DE' end
	if route=='vendor' then return 'VENDOR' end
	if route=='flip' then return 'FLIP' end
	return string.upper(tostring(route or ''))
end

local function short_time(v)
	v=tostring(v or '')
	if string.len(v)>=8 then return string.sub(v,-8) end
	return v
end

local function history_pct_text(h)
	local pct=tonumber(h and h.historyPct) or 0
	local days=tonumber(h and h.historyDays) or 0
	if pct<=0 or days<=0 then return '' end
	return string.format('%.1f%%',pct)
end

local sortSpecs={
	{label='Time',key='seq',numeric=true,defaultDescending=true},
	{label='Route',key='route'},
	{label='Item',key='name'},
	{label='Qty',key='count',numeric=true,defaultDescending=true},
	{label='Paid',key='buyout',numeric=true,defaultDescending=true},
	{label='Hist%',key='historyPct',numeric=true,defaultDescending=true},
	{label='Value',key='value',numeric=true,defaultDescending=true},
	{label='Profit',key='profit',numeric=true,defaultDescending=true},
	{label='Source',key='source'},
}

local function refresh_history(force)
	if not API or not API.GetPurchaseHistoryCount then return end
	local count=API.GetPurchaseHistoryCount() or 0
	local s=API.GetPurchaseHistorySummary and API.GetPurchaseHistorySummary() or {}
	local confirmed=tonumber(s.confirmed) or 0
	local spend=tonumber(s.spend) or 0
	local expected=tonumber(s.expectedProfit) or 0
	if not force and count==lastCount and confirmed==lastConfirmed and spend==lastSpend and expected==lastProfit then return end
	lastCount,lastConfirmed,lastSpend,lastProfit=count,confirmed,spend,expected
	local records={}
	for i=1,count do
		local h=API.GetPurchaseHistory(i)
		if h then table.insert(records,h) end
	end
	AVM_AUX_UI.SortRecords(records,history)
	AVM_AUX_UI.ApplySortLabels(history)
	local rows=T.acquire()
	for i=1,table.getn(records) do
		local h=records[i]
		tinsert(rows,T.map('cols',T.list(
			T.map('value',short_time(h.at)),
			T.map('value',route_text(h.route)),
			T.map('value',tostring(h.name or '')),
			T.map('value',tostring(h.count or 0)),
			T.map('value',money.to_string(tonumber(h.buyout) or 0,true,true)),
			T.map('value',history_pct_text(h)),
			T.map('value',money.to_string(tonumber(h.value) or 0,true,true)),
			T.map('value',money.to_string(tonumber(h.profit) or 0,true,true)),
			T.map('value',tostring(h.source or ''))
		),'record',h))
	end
	history:SetData(rows)
	local limit=tonumber(s.limit) or 500
	status:set_text('Confirmed '..tostring(confirmed)..' | saved '..tostring(count)..'/'..tostring(limit)..' | spent '..money.to_string(spend,true,true)..' | expected '..money.to_string(expected,true,true))
end

AVM_AUX_UI.InstallSortable(history,sortSpecs,function() refresh_history(true) end,1,true)

refresh:SetScript('OnClick',function() refresh_history(true) end)
frame:SetScript('OnUpdate',function()
	if GetTime()<nextRefresh then return end
	nextRefresh=GetTime()+.5
	refresh_history(false)
end)

function tab.OPEN() frame:Show();refresh_history(true) end
function tab.CLOSE() frame:Hide() end

function AVM_AUX_PURCHASES.Show()
	if aux.frame and aux.frame:IsShown() then aux.set_tab(5) end
end
