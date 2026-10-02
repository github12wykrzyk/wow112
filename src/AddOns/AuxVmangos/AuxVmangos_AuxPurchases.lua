-- Native AUX purchase-history tab for WoW 1.12.1.
local T = require 'T'
local aux = require 'aux'
local gui = require 'aux.gui'
local listing_lib = require 'aux.gui.listing'
local money = require 'aux.util.money'

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
	{name='Time',width=.11,align='CENTER'},
	{name='Route',width=.09,align='CENTER'},
	{name='Item',width=.30,align='LEFT'},
	{name='Qty',width=.05,align='CENTER'},
	{name='Paid',width=.12,align='RIGHT'},
	{name='Value',width=.12,align='RIGHT'},
	{name='Profit',width=.12,align='RIGHT'},
	{name='Source',width=.09,align='CENTER'},
}

local status = gui.status_bar(frame)
status:SetWidth(575)
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

local function refresh_history(force)
	if not API or not API.GetPurchaseHistoryCount then return end
	local count=API.GetPurchaseHistoryCount() or 0
	local s=API.GetPurchaseHistorySummary and API.GetPurchaseHistorySummary() or {}
	local confirmed=tonumber(s.confirmed) or 0
	local spend=tonumber(s.spend) or 0
	local expected=tonumber(s.expectedProfit) or 0
	if not force and count==lastCount and confirmed==lastConfirmed and spend==lastSpend and expected==lastProfit then return end
	lastCount,lastConfirmed,lastSpend,lastProfit=count,confirmed,spend,expected
	local rows=T.acquire()
	for i=1,count do
		local h=API.GetPurchaseHistory(i)
		if h then
			tinsert(rows,T.map('cols',T.list(
				T.map('value',short_time(h.at)),
				T.map('value',route_text(h.route)),
				T.map('value',tostring(h.name or '')),
				T.map('value',tostring(h.count or 0)),
				T.map('value',money.to_string(tonumber(h.buyout) or 0,true,true)),
				T.map('value',money.to_string(tonumber(h.value) or 0,true,true)),
				T.map('value',money.to_string(tonumber(h.profit) or 0,true,true)),
				T.map('value',tostring(h.source or ''))
			),'record',h))
		end
	end
	history:SetData(rows)
	status:set_text('Confirmed '..tostring(confirmed)..'  |  saved '..tostring(count)..'/50  |  spent '..money.to_string(spend,true,true)..'  |  expected profit '..money.to_string(expected,true,true))
end

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
