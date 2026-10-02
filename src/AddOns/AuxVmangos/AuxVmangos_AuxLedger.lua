-- Native AUX Profit/Loss ledger + Auctions potential-proceeds summary for WoW 1.12.1.
-- Purchase cash-out comes from AVM confirmed buys. Auction income comes from
-- seller invoice mail that is actually present in the mailbox. Expected
-- arbitrage profit stays separate from observed AH cash flow.
local T = require 'T'
local aux = require 'aux'
local gui = require 'aux.gui'
local listing_lib = require 'aux.gui.listing'
local money = require 'aux.util.money'

AVM_AUX_LEDGER = AVM_AUX_LEDGER or {}
local tab = aux.tab 'Profit/Loss'
local frame = CreateFrame('Frame', nil, aux.frame)
frame:SetAllPoints()
frame:Hide()

local panel = gui.panel(frame)
panel:SetPoint('TOP', frame, 'TOP', 0, -8)
panel:SetPoint('BOTTOMLEFT', aux.frame.content, 'BOTTOMLEFT', 0, 0)
panel:SetPoint('BOTTOMRIGHT', aux.frame.content, 'BOTTOMRIGHT', 0, 0)

local ledger = listing_lib.new(panel)
ledger:SetColInfo{
	{name='Time',width=.11,align='CENTER'},
	{name='Type',width=.08,align='CENTER'},
	{name='Route',width=.09,align='CENTER'},
	{name='Item',width=.28,align='LEFT'},
	{name='Spent',width=.11,align='RIGHT'},
	{name='Earned',width=.11,align='RIGHT'},
	{name='Exp P/L',width=.11,align='RIGHT'},
	{name='Source',width=.11,align='CENTER'},
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

local nextRefresh = 0
local lastToken = ''

local function ensure_db()
	AVM_DB = AVM_DB or {}
	AVM_DB.saleHistory = AVM_DB.saleHistory or {}
	AVM_DB.saleHistorySeq = tonumber(AVM_DB.saleHistorySeq) or 0
	AVM_DB.saleMailLiveCounts = AVM_DB.saleMailLiveCounts or {}
	if not AVM_DB.saleStats then
		local earned, confirmed = 0, 0
		for i=1,table.getn(AVM_DB.saleHistory) do
			local h=AVM_DB.saleHistory[i]
			earned=earned+(tonumber(h and h.money) or 0)
			confirmed=confirmed+1
		end
		AVM_DB.saleStats={confirmed=confirmed,earned=earned}
	end
end

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

local function signed_money(v)
	v=tonumber(v) or 0
	if v<0 then return '-'..money.to_string(-v,true,true) end
	if v>0 then return '+'..money.to_string(v,true,true) end
	return money.to_string(0,true,true)
end

local function record_sale(sample)
	if not sample or (tonumber(sample.money) or 0)<=0 then return end
	ensure_db()
	AVM_DB.saleHistorySeq=AVM_DB.saleHistorySeq+1
	local stamp=tostring(math.floor(GetTime() or 0))
	if type(date)=='function' then stamp=date('%Y-%m-%d %H:%M:%S') end
	local row={
		seq=AVM_DB.saleHistorySeq,
		at=stamp,
		item=tostring(sample.item or ''),
		buyer=tostring(sample.buyer or ''),
		subject=tostring(sample.subject or ''),
		money=tonumber(sample.money) or 0,
		bid=tonumber(sample.bid) or 0,
		buyout=tonumber(sample.buyout) or 0,
		deposit=tonumber(sample.deposit) or 0,
		consignment=tonumber(sample.consignment) or 0,
		source='AH mail',
	}
	table.insert(AVM_DB.saleHistory,row)
	while table.getn(AVM_DB.saleHistory)>100 do table.remove(AVM_DB.saleHistory,1) end
	AVM_DB.saleStats.confirmed=(tonumber(AVM_DB.saleStats.confirmed) or 0)+1
	AVM_DB.saleStats.earned=(tonumber(AVM_DB.saleStats.earned) or 0)+row.money
	if AVM_DB.diag then
		AVM_DB.diag.saleHistory=AVM_DB.saleHistory
		AVM_DB.diag.saleStats=AVM_DB.saleStats
	end
	lastToken=''
end

local function mail_signature(item,buyer,subject,mailMoney,bid,buyout,deposit,consignment)
	return table.concat({
		tostring(item or ''),tostring(buyer or ''),tostring(subject or ''),
		tostring(tonumber(mailMoney) or 0),tostring(tonumber(bid) or 0),
		tostring(tonumber(buyout) or 0),tostring(tonumber(deposit) or 0),
		tostring(tonumber(consignment) or 0)
	},'|')
end

function AVM_AUX_LEDGER.ScanSaleMail()
	if not GetInboxNumItems or not GetInboxInvoiceInfo or not GetInboxHeaderInfo then return end
	ensure_db()
	local current,samples={},{}
	local count=GetInboxNumItems() or 0
	for i=1,count do
		local invoiceType,itemName,playerName,bid,buyout,deposit,consignment=GetInboxInvoiceInfo(i)
		if invoiceType=='seller' then
			local _,_,_,subject,mailMoney=GetInboxHeaderInfo(i)
			mailMoney=tonumber(mailMoney) or 0
			if mailMoney>0 then
				local sig=mail_signature(itemName,playerName,subject,mailMoney,bid,buyout,deposit,consignment)
				current[sig]=(current[sig] or 0)+1
				samples[sig]={
					item=itemName,buyer=playerName,subject=subject,money=mailMoney,
					bid=bid,buyout=buyout,deposit=deposit,consignment=consignment,
				}
			end
		end
	end
	local previous=AVM_DB.saleMailLiveCounts or {}
	for sig,n in pairs(current) do
		local old=tonumber(previous[sig]) or 0
		if n>old then
			for k=1,n-old do record_sale(samples[sig]) end
		end
	end
	AVM_DB.saleMailLiveCounts=current
end

local function refresh_ledger(force)
	ensure_db()
	local p=AVM_DB.purchaseStats or {}
	local s=AVM_DB.saleStats or {}
	local ph=AVM_DB.purchaseHistory or {}
	local sh=AVM_DB.saleHistory or {}
	local spent=tonumber(p.spend) or 0
	local earned=tonumber(s.earned) or 0
	local expected=tonumber(p.expectedProfit) or 0
	local token=table.concat({
		tostring(table.getn(ph)),tostring(table.getn(sh)),
		tostring(tonumber(p.confirmed) or 0),tostring(spent),tostring(expected),
		tostring(tonumber(s.confirmed) or 0),tostring(earned)
	},':')
	if not force and token==lastToken then return end
	lastToken=token

	local combined={}
	for i=1,table.getn(ph) do
		local h=ph[i]
		table.insert(combined,{
			at=tostring(h.at or ''),seq=tonumber(h.seq) or 0,kind='BUY',
			route=route_text(h.route),item=tostring(h.name or ''),
			spent=tonumber(h.buyout) or 0,earned=0,expected=tonumber(h.profit) or 0,
			source=tostring(h.source or ''),
		})
	end
	for i=1,table.getn(sh) do
		local h=sh[i]
		table.insert(combined,{
			at=tostring(h.at or ''),seq=tonumber(h.seq) or 0,kind='SALE',
			route='AH',item=tostring(h.item or ''),
			spent=0,earned=tonumber(h.money) or 0,expected=nil,
			source=tostring(h.source or 'AH mail'),
		})
	end
	table.sort(combined,function(a,b)
		if a.at~=b.at then return a.at>b.at end
		if a.kind~=b.kind then return a.kind>b.kind end
		return (a.seq or 0)>(b.seq or 0)
	end)

	local rows=T.acquire()
	for i=1,table.getn(combined) do
		local h=combined[i]
		tinsert(rows,T.map('cols',T.list(
			T.map('value',short_time(h.at)),
			T.map('value',h.kind),
			T.map('value',h.route),
			T.map('value',h.item),
			T.map('value',h.spent>0 and money.to_string(h.spent,true,true) or ''),
			T.map('value',h.earned>0 and money.to_string(h.earned,true,true) or ''),
			T.map('value',h.expected and signed_money(h.expected) or ''),
			T.map('value',h.source)
		),'record',h))
	end
	ledger:SetData(rows)
	status:set_text(
		'Spent '..money.to_string(spent,true,true)..
		'  |  AH income '..money.to_string(earned,true,true)..
		'  |  cash flow '..signed_money(earned-spent)..
		'  |  expected buy P/L '..signed_money(expected)
	)
end

refresh:SetScript('OnClick',function()
	AVM_AUX_LEDGER.ScanSaleMail()
	refresh_ledger(true)
end)

frame:SetScript('OnUpdate',function()
	if GetTime()<nextRefresh then return end
	nextRefresh=GetTime()+.5
	refresh_ledger(false)
end)

function tab.OPEN()
	frame:Show()
	refresh_ledger(true)
end

function tab.CLOSE()
	frame:Hide()
end

-- Count only paid seller invoices. seller_temp_invoice is intentionally ignored,
-- so the later paid invoice cannot be double-counted.
local mailWatcher=CreateFrame('Frame','AuxVmangosProfitLossMailWatcher')
mailWatcher:RegisterEvent('MAIL_SHOW')
mailWatcher:RegisterEvent('MAIL_INBOX_UPDATE')
local mailScanAt=0
mailWatcher:SetScript('OnEvent',function()
	if event=='MAIL_SHOW' and CheckInbox then CheckInbox() end
	mailScanAt=GetTime()+.35
end)
mailWatcher:SetScript('OnUpdate',function()
	if mailScanAt<=0 or GetTime()<mailScanAt then return end
	mailScanAt=0
	AVM_AUX_LEDGER.ScanSaleMail()
	refresh_ledger(true)
end)

function AVM_AUX_LEDGER.UpdateAuctionsSummary(env)
	if not env or not env.status_bar then return end
	local text=env.status_bar.text and env.status_bar.text:GetText() or ''
	if not string.find(text,'Scan complete',1,true) and
	   not string.find(text,'Potential net',1,true) then return end
	local records=env.auction_records or {}
	local gross,noBuyout=0,0
	for i=1,table.getn(records) do
		local r=records[i]
		local bo=tonumber(r and r.buyout_price) or 0
		if bo>0 then gross=gross+bo else noBuyout=noBuyout+1 end
	end
	local cut=tonumber(AVM_DB and AVM_DB.flipAhCutPct) or 5
	if cut<0 then cut=0 elseif cut>30 then cut=30 end
	local net=math.floor(gross*(100-cut)/100)
	env.status_bar:set_text(
		'Auctions '..tostring(table.getn(records))..
		' | Potential net '..money.to_string(net,true,true)..
		' | gross '..money.to_string(gross,true,true)..
		' | cut '..tostring(cut)..'%'..
		(noBuyout>0 and (' | no BO '..tostring(noBuyout)) or '')
	)
end

local function install_auctions_summary()
	local ok,auctions=pcall(require,'aux.tabs.auctions')
	if not ok or not auctions or not auctions.scan_auctions then return end
	local env=getfenv(auctions.scan_auctions)
	if not env or env.AVM_PROFIT_LOSS_SUMMARY_HOOK then return end
	env.AVM_PROFIT_LOSS_SUMMARY_HOOK=true
	local original=env.update_listing
	if original then
		env.update_listing=function()
			original()
			AVM_AUX_LEDGER.UpdateAuctionsSummary(env)
		end
	end
	if env.status_bar then env.status_bar:SetWidth(430) end
	AVM_AUX_LEDGER.UpdateAuctionsSummary(env)
end

install_auctions_summary()
