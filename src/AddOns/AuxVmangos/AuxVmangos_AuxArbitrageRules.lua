-- Native AUX tab for configuring BUYOUT and BID risk rules.
local aux = require 'aux'
local gui = require 'aux.gui'
local money = require 'aux.util.money'

AVM_AUX_RULES_UI = AVM_AUX_RULES_UI or {}
local tab = aux.tab 'Arb Rules'
local frame = CreateFrame('Frame', nil, aux.frame)
frame:SetAllPoints()
frame:Hide()

local buyPage = CreateFrame('Frame', nil, frame)
buyPage:SetAllPoints()
local bidPage = CreateFrame('Frame', nil, frame)
bidPage:SetAllPoints()
bidPage:Hide()
local currentPage = 'BUYOUT'
local fields = {}
local checks = {}
local status

local function ensure_defaults()
	if AVM_BID_RULES_EnsureDefaults then AVM_BID_RULES_EnsureDefaults() end
end

local function label(parent,text,x,y,width,template)
	local fs=parent:CreateFontString(nil,'OVERLAY',template or 'GameFontNormalSmall')
	fs:SetPoint('TOPLEFT',parent,'TOPLEFT',x,y)
	fs:SetWidth(width or 150)
	fs:SetJustifyH('LEFT')
	fs:SetText(text or '')
	return fs
end

local function title(parent,text,x,y,width)
	return label(parent,text,x,y,width or 170,'GameFontNormal')
end

local function plain_money(v)
	v=math.floor(tonumber(v) or 0)
	local g=math.floor(v/10000);local s=math.floor(math.mod(v,10000)/100);local c=math.mod(v,100)
	local out=''
	if g>0 then out=out..tostring(g)..'g' end
	if s>0 then out=out..tostring(s)..'s' end
	if c>0 or out=='' then out=out..tostring(c)..'c' end
	return out
end

local function edit(parent,key,labelText,x,y,width,kind,lo,hi)
	label(parent,labelText,x,y,150)
	local e=CreateFrame('EditBox','AuxVmangosRules_'..key,parent,'InputBoxTemplate')
	e:SetWidth(width or 90);e:SetHeight(20);e:SetPoint('TOPLEFT',parent,'TOPLEFT',x+150,y+4);e:SetAutoFocus(false);e:SetMaxLetters(18)
	fields[key]={box=e,kind=kind or 'number',lo=lo,hi=hi}
	return e
end

local function check(parent,key,text,x,y)
	local c=CreateFrame('CheckButton','AuxVmangosRulesCheck_'..key,parent,'UICheckButtonTemplate')
	c:SetPoint('TOPLEFT',parent,'TOPLEFT',x,y);c:SetWidth(24);c:SetHeight(24)
	local t=_G[c:GetName()..'Text'];if t then t:SetText(text);t:SetWidth(160);t:SetJustifyH('LEFT') end
	checks[key]=c
	return c
end

local function clamp(v,lo,hi)
	v=tonumber(v);if not v then return nil end
	if lo and v<lo then v=lo end;if hi and v>hi then v=hi end;return v
end

local function load_fields()
	ensure_defaults()
	for key,row in pairs(fields) do
		local v=AVM_DB and AVM_DB[key]
		if row.kind=='money' then row.box:SetText(plain_money(v or 0)) else row.box:SetText(tostring(v or 0)) end
	end
	for key,c in pairs(checks) do c:SetChecked(AVM_DB and AVM_DB[key] and true or false) end
	local b=AVM_BID_V3 or {}
	if status then status:set_text('BID session: placed '..tostring(b.sessionPlaced or 0)..' | committed '..plain_money(b.sessionCommitted or 0)..' | exact recheck ON') end
end

local function save_fields()
	ensure_defaults()
	for key,row in pairs(fields) do
		local text=row.box:GetText() or ''
		local v
		if row.kind=='money' then v=money.from_string(text) else v=tonumber(text) end
		v=clamp(v,row.lo,row.hi)
		if v~=nil then
			if row.kind=='int' then v=math.floor(v) end
			AVM_DB[key]=v
		end
	end
	for key,c in pairs(checks) do AVM_DB[key]=c:GetChecked() and true or false end
	load_fields()
	if status then status:set_text('Saved. BUYOUT and BID rules apply on the next candidate; no restart required for value changes.') end
end

local function show_page(which)
	currentPage=which
	if which=='BUYOUT' then buyPage:Show();bidPage:Hide() else buyPage:Hide();bidPage:Show() end
	load_fields()
end

local buyBtn=gui.button(frame);buyBtn:SetPoint('TOPLEFT',aux.frame.content,'TOPLEFT',8,-6);buyBtn:SetWidth(100);buyBtn:SetText('BUYOUT')
local bidBtn=gui.button(frame);bidBtn:SetPoint('LEFT',buyBtn,'RIGHT',6,0);bidBtn:SetWidth(100);bidBtn:SetText('BID')
local saveBtn=gui.button(frame);saveBtn:SetPoint('LEFT',bidBtn,'RIGHT',20,0);saveBtn:SetWidth(100);saveBtn:SetText('Save rules')
local reloadBtn=gui.button(frame);reloadBtn:SetPoint('LEFT',saveBtn,'RIGHT',6,0);reloadBtn:SetWidth(80);reloadBtn:SetText('Reload')
buyBtn:SetScript('OnClick',function() show_page('BUYOUT') end)
bidBtn:SetScript('OnClick',function() show_page('BID') end)
saveBtn:SetScript('OnClick',save_fields)
reloadBtn:SetScript('OnClick',load_fields)

status=gui.status_bar(frame);status:SetHeight(25);status:SetPoint('BOTTOMLEFT',aux.frame.content,'BOTTOMLEFT',0,-30);status:SetWidth(math.max(500,(tonumber(aux.frame:GetWidth()) or 768)-40));status:update_status(1,1);status:set_text('')

-- BUYOUT page ---------------------------------------------------------------
title(buyPage,'BUYOUT - Vendor',18,-55,170)
edit(buyPage,'vendorMinProfit','Min profit',18,-82,80,'money',0,nil)
edit(buyPage,'vendorMaxBuyout','Max buyout',18,-108,80,'money',0,nil)
edit(buyPage,'vendorSafetyMarginPct','Safety margin %',18,-134,80,'number',0,90)
label(buyPage,'0% keeps current proven Vendor behavior.',18,-164,250,'GameFontHighlightSmall')

title(buyPage,'BUYOUT - DE',285,-55,170)
edit(buyPage,'deMinProfit','Min profit',285,-82,80,'money',0,nil)
edit(buyPage,'deMaxBuyout','Max buyout',285,-108,80,'money',0,nil)
edit(buyPage,'deSafetyMarginPct','Safety margin %',285,-134,80,'number',0,90)
edit(buyPage,'deDepthUnits','Material depth',285,-160,80,'int',1,200)

title(buyPage,'BUYOUT - Resell/Flip',18,-220,180)
edit(buyPage,'flipMinProfit','Min profit',18,-247,80,'money',0,nil)
edit(buyPage,'flipMaxBuyout','Max buyout',18,-273,80,'money',0,nil)
edit(buyPage,'flipSafetyMarginPct','Safety margin %',18,-299,80,'number',0,90)
edit(buyPage,'flipHistMaxPct','Max history entry %',18,-325,80,'number',1,100)
edit(buyPage,'flipMinSellers','Min sellers',18,-351,80,'int',1,50)
edit(buyPage,'flipDepthUnits','Depth units',18,-377,80,'int',10,200)

title(buyPage,'BUYOUT - Liquid Depth',285,-220,190)
edit(buyPage,'liquidDepthEntryPct','Max depth entry %',285,-247,80,'number',1,100)
edit(buyPage,'liquidDepthMinRoiPct','Min ROI %',285,-273,80,'number',0,500)
edit(buyPage,'liquidDepthMinProfit','Min profit',285,-299,80,'money',0,nil)
edit(buyPage,'liquidDepthMaxBuyout','Max buyout',285,-325,80,'money',0,nil)
edit(buyPage,'liquidDepthMinRefUnits','Ref units',285,-351,80,'int',1,500)
edit(buyPage,'liquidDepthMinRefSellers','Ref sellers',285,-377,80,'int',1,50)

title(buyPage,'BUYOUT - Session',552,-55,170)
edit(buyPage,'maxSessionSpend','Max spend/session',552,-82,80,'money',0,nil)
edit(buyPage,'maxSessionBuys','Max buys/session',552,-108,80,'int',0,100)
label(buyPage,'0 = unlimited. Applies to classic buyout routes.',552,-140,175,'GameFontHighlightSmall')

-- BID page ------------------------------------------------------------------
check(bidPage,'bidArbEnabled','BID master ON',18,-55)
check(bidPage,'bidVendorEnabled','Vendor BID',18,-82)
check(bidPage,'bidDeEnabled','DE BID',18,-109)
check(bidPage,'bidResellEnabled','Resell BID',18,-136)
label(bidPage,'BIDs may target auctions WITH or WITHOUT buyout.',18,-170,245,'GameFontHighlightSmall')

title(bidPage,'BID - Vendor',285,-55,170)
edit(bidPage,'bidVendorMarginPct','Min margin %',285,-82,80,'number',0,90)
edit(bidPage,'bidVendorMinProfit','Min profit',285,-108,80,'money',0,nil)
edit(bidPage,'bidVendorMaxAmount','Max bid',285,-134,80,'money',0,nil)

title(bidPage,'BID - DE',552,-55,170)
edit(bidPage,'bidDeMarginPct','Min margin %',552,-82,80,'number',0,90)
edit(bidPage,'bidDeMinProfit','Min profit',552,-108,80,'money',0,nil)
edit(bidPage,'bidDeMaxAmount','Max bid',552,-134,80,'money',0,nil)

title(bidPage,'BID - Resell',18,-225,180)
edit(bidPage,'bidResellMarginPct','Min margin %',18,-252,80,'number',0,90)
edit(bidPage,'bidResellMinProfit','Min profit',18,-278,80,'money',0,nil)
edit(bidPage,'bidResellMaxAmount','Max bid',18,-304,80,'money',0,nil)
edit(bidPage,'bidResellHistMaxPct','Max history entry %',18,-330,80,'number',1,100)
edit(bidPage,'bidResellMinHistoryDays','History samples',18,-356,80,'int',0,11)

title(bidPage,'BID - Resell depth',285,-225,180)
edit(bidPage,'bidResellDepthUnits','Depth units',285,-252,80,'int',1,500)
edit(bidPage,'bidResellMinSellers','Min sellers',285,-278,80,'int',1,50)
edit(bidPage,'bidResellResalePct','Use floor %',285,-304,80,'number',1,100)
edit(bidPage,'bidResellAhCutPct','AH cut %',285,-330,80,'number',0,30)
label(bidPage,'Value = min(history, conservative live depth).',285,-362,245,'GameFontHighlightSmall')

title(bidPage,'BID - Session safety',552,-225,180)
edit(bidPage,'bidV3MaxDuration','Max duration tier',552,-252,80,'int',1,4)
edit(bidPage,'bidV3MaxSessionPlacements','Max bids/session',552,-278,80,'int',0,100)
edit(bidPage,'bidV3MaxSessionCommitted','Max committed',552,-304,80,'money',0,nil)
edit(bidPage,'bidV3RecentSeconds','Same-item cooldown s',552,-330,80,'int',5,3600)
edit(bidPage,'bidV3VerifyMaxAge','Candidate max age s',552,-356,80,'int',5,300)
label(bidPage,'Default low-risk: short auctions, 6 bids, 30g cumulative.',552,-388,190,'GameFontHighlightSmall')

function tab.OPEN() frame:Show();show_page(currentPage) end
function tab.CLOSE() frame:Hide() end
