
B_AS_VERSION = "2.0-vmangos-autobuy"

B_AS_RecipeNames = {
	"Pattern", "Schematic", "Plans", "Recipe", "Manual", "Formula",
	"Book", "Codex"
}

B_AS_QualityList = {
	[0] = "Poor", "Common", "Uncommon", "Rare", "Epic", "Legendary", "Artifact"
}
for k,v in B_AS_QualityList do
	B_AS_QualityList[k] = ITEM_QUALITY_COLORS[k].hex .. v .. "|r"
end

B_AS_ClassNames = {
	[0] = "ALL", "Weapon", "Armor", "Container",
	"Consumable", "Trade Goods", "Projectile", "Quiver",
	"Recipe", "Reagent", "Miscellaneous"
}

-- Minimum time between 2 auction house scan queries
B_AS_SCAN_BASE = 5.0

-- Maximum random time added if RandomInterval is on
B_AS_SCAN_RANDOM = 0.5

-- Minimum time between 2 item buyouts using SlowBuy
B_AS_SLOWBUY_BASE = 1.0

-- Maximum random time added to SlowBuy (always applied)
B_AS_SLOWBUY_RANDOM = 0.5

-- Maximum time sync skew in seconds
B_AS_SYNC_MAXSKEW = 0.5


-------------------------------------------------------------------------------

B_AS_I_NAME		= 1
B_AS_I_PARTIAL		= 2
B_AS_I_QUALITY		= 3
B_AS_I_STACK		= 4


B_AS_T_BOOL		= 1		-- Button is an ON/OFF toggle button
B_AS_T_LIST		= 2		-- Button switches between multiple values
B_AS_T_TEXT		= 3		-- EditBox with just one line
B_AS_T_NUMBER		= 4		-- EditBox with one number
B_AS_T_LINES		= 5		-- EditBox with many lines
B_AS_T_MISC		= 6		-- Something else

B_AS_S_TYPE		= 1		-- Setting type: BOOL/LIST
B_AS_S_DEFAULT		= 2		-- Default value (set on first time addon use)
B_AS_S_GUI		= 3		-- GUI Button element for this setting
B_AS_S_TEXT		= 4		-- Text on the GUI button
B_AS_S_VALUES		= 5		-- Only LISTs. Array of all possible values
B_AS_S_RANGE_S		= 6		-- Only LISTs. First item index in array
B_AS_S_RANGE_E		= 7		-- Only LISTs. Last item index in array
B_AS_S_CALLBACK		= 8		-- function(newValue) callback when value is changed

B_AS_VarSettings = {
	--			Type		Default		GUI Button			GUI Text		Value names		Value Array Range
	["AutoScan"]		= {B_AS_T_BOOL,		false,	B_AS_Button_AutoScanToggle,		"AutoScan"							},
	["AutoBuy"]		= {B_AS_T_BOOL,		false,	B_AS_Button_AutoBuyToggle,		"AutoBuy LIVE"							},
	["AutoSlowBuy"]		= {B_AS_T_BOOL,		false,	B_AS_Button_AutoSlowBuyToggle,		"DryRun"							},
	["PageLock"]  		= {B_AS_T_BOOL,		true,	B_AS_Button_PageLockToggle,		"LowBuyout"							},
	["PageFixed"]  		= {B_AS_T_BOOL,		false,	B_AS_Button_PageFixedToggle,		"FixedPage"							},
	["WhichPage"]  		= {B_AS_T_NUMBER,	0,	B_AS_Input_WhichPage,											},
	["Sync"]  		= {B_AS_T_BOOL,		false,	B_AS_Button_SyncToggle,			"TimeSync"							},
	["SyncChars"]  		= {B_AS_T_NUMBER,	1,	B_AS_Input_SyncChars,											},
	["SyncIndex"]  		= {B_AS_T_NUMBER,	1,	B_AS_Input_SyncIndex,											},
	["ScanMinQuality"]	= {B_AS_T_LIST,		1,	B_AS_Button_ScanMinQuality,		"Scan Q",		B_AS_QualityList,	1, 5		},
	["BuyMinQuality"]	= {B_AS_T_LIST,		4,	B_AS_Button_BuyMinQuality,		"Buy Q",		B_AS_QualityList,	1, 5		},
	["RecipeMinQuality"]	= {B_AS_T_LIST,		5,	B_AS_Button_RecipeMinQuality,		"Recipe Q",		B_AS_QualityList,	1, 5		},
	["ScanClass"]		= {B_AS_T_LIST,		0,	B_AS_Button_ScanClass,			"Class",		B_AS_ClassNames,	0, 10		},
	["Output"] 		= {B_AS_T_BOOL,		false,	B_AS_Button_OutputToggle,		"Debug Output"							},
	["Log"] 		= {B_AS_T_LINES,	{},	B_AS_LogBox												},
	["ShowLog"] 		= {B_AS_T_BOOL,		true,														},
	["ShowOptions"] 	= {B_AS_T_BOOL,		true,														},
	["ShowItems"] 		= {B_AS_T_BOOL,		false,														},

	["OptionPriceQuality1"]	= {B_AS_T_NUMBER,	50,		B_AS_Input_OptionPriceQuality1,									},
	["OptionPriceQuality2"]	= {B_AS_T_NUMBER,	1000,		B_AS_Input_OptionPriceQuality2,									},
	["OptionPriceQuality3"]	= {B_AS_T_NUMBER,	10000,		B_AS_Input_OptionPriceQuality3,									},
	["OptionPriceQuality4"]	= {B_AS_T_NUMBER,	110000,		B_AS_Input_OptionPriceQuality4,									},
	["OptionPriceQuality5"]	= {B_AS_T_NUMBER,	2000000,	B_AS_Input_OptionPriceQuality5,									},
	["OptionPriceQuality6"]	= {B_AS_T_NUMBER,	5000000,	B_AS_Input_OptionPriceQuality6,									},
	["IgnoreLowGear"]	= {B_AS_T_BOOL,		true,		B_AS_Button_IgnoreLowGearToggle,	"IgnoreLowGear"						},
	["LowGearLevel"]	= {B_AS_T_NUMBER,	50,		B_AS_Input_IgnoreLowGearLevel,									},

	["BuyMaxSession"]	= {B_AS_T_NUMBER,	500000,		nil,											},
	["BuyMaxCount"]		= {B_AS_T_NUMBER,	20,			nil,											},

	["Items"] 		= {B_AS_T_MISC,		{},														},
}

-- AutoBuy and SlowBuy are mutually exclusive
-- Callback: AutoBuy turns off SlowBuy
B_AS_VarSettings["AutoBuy"][B_AS_S_CALLBACK] = function(setting, value)
	if (value == true) then
		B_AS_SetVar("AutoSlowBuy", false)
	end
end
-- Callback: SlowBuy turns off AutoBuy
B_AS_VarSettings["AutoSlowBuy"][B_AS_S_CALLBACK] = function(setting, value)
	if (value == true) then
		B_AS_SetVar("AutoBuy", false)
	end
end
-- PageLock and PageFixed are mutually exclusive
-- Callback: PageLock
B_AS_VarSettings["PageLock"][B_AS_S_CALLBACK] = function(setting, value)
	if (value == true) then
		B_AS_SetVar("PageFixed", false)
	end
	if B_AS_VM then
		local changed = (B_AS_VM.pageLockValue == nil or B_AS_VM.pageLockValue ~= value)
		B_AS_VM.pageLockValue = value
		if changed and B_AS_VM_ResetCheapSearch then
			B_AS_VM.stateResets = B_AS_VM.stateResets + 1
			B_AS_VM_ResetCheapSearch(true)
		end
	end
end
-- Callback: PageFixed
B_AS_VarSettings["PageFixed"][B_AS_S_CALLBACK] = function(setting, value)
	if (value == true) then
		B_AS_SetVar("PageLock", false)
	end
end
-- Callback: Show Log
B_AS_VarSettings["ShowLog"][B_AS_S_CALLBACK] = function(setting, value)
	if value then
		B_AS_LogBoxContainer:Show()
	else
		B_AS_LogBoxContainer:Hide()
	end
end
-- Callback: Show Options
B_AS_VarSettings["ShowOptions"][B_AS_S_CALLBACK] = function(setting, value)
	if value then
		B_AS_OptionsContainer:Show()
	else
		B_AS_OptionsContainer:Hide()
	end
end
-- Callback: Show Items
B_AS_VarSettings["ShowItems"][B_AS_S_CALLBACK] = function(setting, value)
	if value then
		B_AS_ItemsContainer:Show()
	else
		B_AS_ItemsContainer:Hide()
	end
end
-- Callback: Options: Setting price quality changes money text
B_AS_OptionPriceQuality_Callback = function(setting, value)
	local numberValue = tonumber(value)
	if (numberValue ~= nil) then
		getglobal("B_AS_Text_" .. setting):SetText(B_AS_MoneyToText(numberValue))
	end
end
B_AS_VarSettings["OptionPriceQuality1"][B_AS_S_CALLBACK] = B_AS_OptionPriceQuality_Callback
B_AS_VarSettings["OptionPriceQuality2"][B_AS_S_CALLBACK] = B_AS_OptionPriceQuality_Callback
B_AS_VarSettings["OptionPriceQuality3"][B_AS_S_CALLBACK] = B_AS_OptionPriceQuality_Callback
B_AS_VarSettings["OptionPriceQuality4"][B_AS_S_CALLBACK] = B_AS_OptionPriceQuality_Callback
B_AS_VarSettings["OptionPriceQuality5"][B_AS_S_CALLBACK] = B_AS_OptionPriceQuality_Callback
B_AS_VarSettings["OptionPriceQuality6"][B_AS_S_CALLBACK] = B_AS_OptionPriceQuality_Callback

-------------------------------------------------------------------------------

-- True if the auction house window is shown
B_AS_IsOpen = false

-- Absolute time in SECONDS when last item was bought using the SlowBuy option
B_AS_SlowBuy_LastTime = 0.0

-- Relative to SlowBuy_LastTime: How many SECONDS to wait until next item buy
B_AS_SlowBuy_WaitTime = 0.0

-- Number of auctions on the currently shown page
B_AS_CurrentPageAuctions = 0

-- Total number of auctions in this auction house
B_AS_TotalAuctions = 0

-- Currently opened auction house page number
B_AS_Page = 0

-- vMaNGOS query + transaction state machine.
B_AS_VM_LIVE_BUY = true
B_AS_VM_QUERY_TIMEOUT = 12.0
B_AS_VM_DUP_GUARD = 0.20
B_AS_VM_CHEAP_WINDOW_PAGES = 10
B_AS_VM_BUY_TIMEOUT = 5.0
B_AS_VM_BUY_RESCAN_DELAY = 0.25
B_AS_VM_LOG_LIMIT = 500

B_AS_VM = {
	queryInFlight = false,
	querySentAt = 0.0,
	nextQueryAt = 0.0,
	querySeq = 0,
	queryPage = 0,
	queryName = "",
	watchIndex = 1,
	watchPage = 0,
	lastLatency = 0.0,
	seen = 0,
	positiveBuyouts = 0,
	zeroBuyouts = 0,
	candidates = 0,
	orderViolations = 0,
	timeouts = 0,
	duplicateListEvents = 0,
	verbose = false,
	lastEvaluatedSeq = -1,
	cheapPhase = "probe",
	cheapLow = 0,
	cheapHigh = 0,
	cheapCandidate = nil,
	cheapBoundary = nil,
	cheapWindowStart = nil,
	cheapScanPage = 0,
	cheapLastPage = 0,
	cheapCycles = 0,
	cheapVerifications = 0,
	cheapFallbacks = 0,
	stateResets = 0,
	pageLockValue = nil,
	buyPending = false,
	buySentAt = 0.0,
	buySeq = 0,
	buyCandidate = nil,
	buyAttempts = 0,
	buyConfirmed = 0,
	buyFailed = 0,
	buyTimeouts = 0,
	sessionSpent = 0,
	sessionPurchases = 0,
	forcedQueryPage = nil,
	forcedQueryName = nil,
	suppressAdvanceOnce = false,
	lastBuyResult = "none",
}


-------------------------------------------------------------------------------

--[[
	Converts an amount of money into a readable text
	Argument: money - not negative integer amount of copper
	Returns: string: money as text
]]
function B_AS_MoneyToText(money)
	-- Conversion copied from Blizzard's MoneyFrame.lua, line 185
	local gold = floor(money / (COPPER_PER_SILVER * SILVER_PER_GOLD))
	local silver = floor((money - (gold * COPPER_PER_SILVER * SILVER_PER_GOLD)) / COPPER_PER_SILVER)
	local copper = mod(money, COPPER_PER_SILVER)

	local o = ""

	if (gold > 0) then
		o = o .. "|cffffff00" .. gold .. "g|r"
	end
	if (silver > 0) then
		o = o .. "|cfff0f0f0" .. silver .. "s|r"
	end
	if ((copper > 0) or (o == "")) then
		o = o .. "|cffff9020" .. copper .. "c|r"
	end
	return o
end

--[[
	Prints a table recursively
	http://stackoverflow.com/a/27028488
]]
function B_AS_PrintTable(o)
	if type(o) == 'table' then
		local s = '{'
		for k,v in pairs(o) do
			local kk = k
			if type(kk) ~= 'number' then kk = '"'..kk..'"' end
			s = s .. '['..kk..']=' .. B_AS_PrintTable(v) .. ','
		end
		return s .. '}'
	elseif type(o) == 'string' then
		return '"' .. o .. '"'
	else
		return tostring(o)
	end
end


-------------------------------------------------------------------------------


--[[
	Print text in the chat frame if the "Output" setting is enabled
	Argument: msg - the text that you want to print
]]
function B_AS_Print(msg)
	if (B_AS_GS["Output"]) then
		DEFAULT_CHAT_FRAME:AddMessage("[AS] "..msg, 1, 0.3, 1)
	end
end

--[[
	Add a line of text to the log (even if the log window is hidden)
	Argument: msg - the text to be logged
]]
function B_AS_Log(msg)
	table.insert(B_AS_GS["Log"], msg)
	while table.getn(B_AS_GS["Log"]) > B_AS_VM_LOG_LIMIT do
		table.remove(B_AS_GS["Log"], 1)
	end
	B_AS_LogBox:AddMessage(msg)
end

--[[
	Delete all messages in the log
]]
function B_AS_LogClear()
	B_AS_GS["Log"] = {}
	B_AS_LogBox:Clear()
end

--[[
	Enter a log message that shows what item was bought, the time and the price
]]
function B_AS_LogBuyout(name, count, quality, level, buyPrice, owner, link)

	local desc = link
	if desc == nil then
		desc = name
	end

	local msg = count .. "x " .. desc .. " " .. B_AS_MoneyToText(buyPrice)
		.. " " .. owner .. " " .. date("%H:%M:%S %d.%m.%y")
	B_AS_Log(msg)
	B_AS_Print("Buying: " .. msg)
end


-------------------------------------------------------------------------------


--[[
	Buys all items that meet the user's specified requirements.
	Argument: buyAll
		- True: Buy all items at once
		- False: Buy only 1 item at maximum
]]
function B_AS_VM_WatchCount()
	if not B_AS_VM_Watchlist then
		return 0
	end
	return table.getn(B_AS_VM_Watchlist)
end

function B_AS_VM_RuleMatches(rule, name)
	if not rule or not name or rule.enabled == false or not rule.name or rule.name == "" then
		return false
	end
	if rule.partial then
		return string.find(name, rule.name, 1, true) ~= nil
	end
	return name == rule.name
end

function B_AS_VM_FindRule(name)
	local count = B_AS_VM_WatchCount()
	for i = 1, count do
		local rule = B_AS_VM_Watchlist[i]
		if B_AS_VM_RuleMatches(rule, name) then
			return rule
		end
	end
	return nil
end

function B_AS_VM_ResetCheapSearch(clearBoundary)
	B_AS_VM.cheapPhase = "probe"
	B_AS_VM.cheapLow = 0
	B_AS_VM.cheapHigh = 0
	B_AS_VM.cheapCandidate = nil
	B_AS_VM.cheapWindowStart = nil
	B_AS_VM.cheapScanPage = 0
	B_AS_VM.cheapLastPage = 0
	if clearBoundary then
		B_AS_VM.cheapBoundary = nil
	end
end

function B_AS_VM_BeginCachedVerify()
	local boundary = B_AS_VM.cheapBoundary
	if boundary == nil then
		boundary = B_AS_VM.cheapWindowStart
	end
	if boundary == nil then
		boundary = B_AS_VM.cheapScanPage - (B_AS_VM_CHEAP_WINDOW_PAGES - 1)
		if boundary < 0 then
			boundary = 0
		end
		B_AS_Log("[VM-CACHE] recovered boundary from scan window="..boundary)
	end

	if B_AS_VM.cheapLastPage > 0 and boundary > B_AS_VM.cheapLastPage then
		boundary = B_AS_VM.cheapLastPage
	end

	B_AS_VM.cheapBoundary = boundary
	B_AS_VM.cheapVerifications = B_AS_VM.cheapVerifications + 1
	if boundary > 0 then
		B_AS_VM.cheapPhase = "verify_prev"
	else
		B_AS_VM.cheapPhase = "verify_current"
	end
	B_AS_Log("[VM-STATE] scan-end boundary="..boundary.." next="..B_AS_VM.cheapPhase)
	B_AS_Log("[VM-CACHE] verify boundary="..boundary)
end

function B_AS_VM_GetQuery()
	if B_AS_VM.forcedQueryPage ~= nil then
		local page = B_AS_VM.forcedQueryPage
		local name = B_AS_VM.forcedQueryName or ""
		B_AS_VM.forcedQueryPage = nil
		B_AS_VM.forcedQueryName = nil
		return name, page, nil
	end

	local count = B_AS_VM_WatchCount()
	if count > 0 then
		if B_AS_VM.watchIndex < 1 or B_AS_VM.watchIndex > count then
			B_AS_VM.watchIndex = 1
		end
		local rule = B_AS_VM_Watchlist[B_AS_VM.watchIndex]
		return rule.name or "", B_AS_VM.watchPage, rule
	end

	if B_AS_GS["PageLock"] then
		local page = 0
		if B_AS_VM.cheapPhase == "search" then
			page = math.floor((B_AS_VM.cheapLow + B_AS_VM.cheapHigh) / 2)
		elseif B_AS_VM.cheapPhase == "scan" then
			page = B_AS_VM.cheapScanPage
		elseif B_AS_VM.cheapPhase == "verify_prev" then
			page = (B_AS_VM.cheapBoundary or 0) - 1
		elseif B_AS_VM.cheapPhase == "verify_current" then
			page = B_AS_VM.cheapBoundary or 0
		elseif B_AS_VM.cheapPhase == "verify_next" then
			page = (B_AS_VM.cheapBoundary or 0) + 1
		end
		if page < 0 then page = 0 end
		if B_AS_VM.cheapLastPage > 0 and page > B_AS_VM.cheapLastPage then
			page = B_AS_VM.cheapLastPage
		end
		return "", page, nil
	elseif B_AS_GS["PageFixed"] then
		return "", tonumber(B_AS_GS["WhichPage"]) or 0, nil
	end

	return "", B_AS_Page, nil
end

function B_AS_VM_StartSearch(lowPage, highPage, candidate, reason)
	B_AS_VM.cheapLow = lowPage
	B_AS_VM.cheapHigh = highPage
	B_AS_VM.cheapCandidate = candidate
	B_AS_VM.cheapPhase = "search"
	B_AS_VM.cheapFallbacks = B_AS_VM.cheapFallbacks + 1
	B_AS_Log("[VM-BOUNDARY] "..reason.." low="..lowPage.." high="..highPage)
end

function B_AS_VM_EnterScan(boundary, lastPage, reason)
	B_AS_VM.cheapBoundary = boundary
	B_AS_VM.cheapWindowStart = boundary
	B_AS_VM.cheapScanPage = boundary
	B_AS_VM.cheapLastPage = lastPage
	B_AS_VM.cheapPhase = "scan"
	B_AS_Log("[VM-BOUNDARY] "..reason.." page="..boundary.." lastPage="..lastPage)
end

function B_AS_VM_AdvanceCheap(totalAuctions, positiveCount)
	local lastPage = 0
	if totalAuctions and totalAuctions > 0 then
		lastPage = math.floor((totalAuctions - 1) / 50)
	end
	B_AS_VM.cheapLastPage = lastPage

	if B_AS_VM.cheapPhase == "probe" then
		if positiveCount > 0 then
			B_AS_VM_EnterScan(0, lastPage, "first positive-buyout")
		elseif lastPage <= 0 then
			B_AS_VM.cheapPhase = "empty"
			B_AS_Log("[VM-BOUNDARY] no positive buyouts found")
		else
			B_AS_VM_StartSearch(1, lastPage, nil, "initial search")
		end
		return
	end

	if B_AS_VM.cheapPhase == "search" then
		local page = B_AS_VM.queryPage
		if positiveCount > 0 then
			B_AS_VM.cheapCandidate = page
			B_AS_VM.cheapHigh = page - 1
		else
			B_AS_VM.cheapLow = page + 1
		end

		if B_AS_VM.cheapHigh > lastPage then
			B_AS_VM.cheapHigh = lastPage
		end

		if B_AS_VM.cheapLow > B_AS_VM.cheapHigh then
			if B_AS_VM.cheapCandidate then
				B_AS_VM_EnterScan(B_AS_VM.cheapCandidate, lastPage, "found first positive-buyout")
			else
				B_AS_VM.cheapPhase = "empty"
				B_AS_Log("[VM-BOUNDARY] no positive buyouts found through page "..lastPage)
			end
		end
		return
	end

	if B_AS_VM.cheapPhase == "scan" then
		local boundary = B_AS_VM.cheapBoundary or 0
		local maxPage = boundary + B_AS_VM_CHEAP_WINDOW_PAGES - 1
		if maxPage > lastPage then
			maxPage = lastPage
		end
		if B_AS_VM.cheapScanPage < maxPage then
			B_AS_VM.cheapScanPage = B_AS_VM.cheapScanPage + 1
		else
			B_AS_VM.cheapCycles = B_AS_VM.cheapCycles + 1
			B_AS_VM_BeginCachedVerify()
		end
		return
	end

	if B_AS_VM.cheapPhase == "verify_prev" then
		if positiveCount > 0 then
			local candidate = B_AS_VM.queryPage
			B_AS_VM_StartSearch(0, candidate - 1, candidate, "cached boundary moved earlier")
		else
			B_AS_VM.cheapPhase = "verify_current"
		end
		return
	end

	if B_AS_VM.cheapPhase == "verify_current" then
		if positiveCount > 0 then
			B_AS_VM_EnterScan(B_AS_VM.queryPage, lastPage, "cached boundary confirmed")
		elseif B_AS_VM.queryPage >= lastPage then
			B_AS_VM.cheapPhase = "empty"
			B_AS_Log("[VM-BOUNDARY] cached boundary vanished at last page")
		else
			B_AS_VM.cheapPhase = "verify_next"
		end
		return
	end

	if B_AS_VM.cheapPhase == "verify_next" then
		if positiveCount > 0 then
			B_AS_VM_EnterScan(B_AS_VM.queryPage, lastPage, "cached boundary advanced")
		else
			local low = B_AS_VM.queryPage + 1
			if low <= lastPage then
				B_AS_VM_StartSearch(low, lastPage, nil, "cached boundary moved later")
			else
				B_AS_VM.cheapPhase = "empty"
				B_AS_Log("[VM-BOUNDARY] no positive buyouts remain")
			end
		end
		return
	end

	if B_AS_VM.cheapPhase == "empty" then
		B_AS_VM.cheapCycles = B_AS_VM.cheapCycles + 1
		B_AS_VM_ResetCheapSearch(true)
	end
end

function B_AS_VM_AdvanceQuery(totalAuctions, positiveCount)
	local lastPage = 0
	if totalAuctions and totalAuctions > 0 then
		lastPage = math.floor((totalAuctions - 1) / 50)
	end

	local count = B_AS_VM_WatchCount()
	if count > 0 then
		if B_AS_VM.watchPage < lastPage then
			B_AS_VM.watchPage = B_AS_VM.watchPage + 1
		else
			B_AS_VM.watchPage = 0
			B_AS_VM.watchIndex = B_AS_VM.watchIndex + 1
			if B_AS_VM.watchIndex > count then
				B_AS_VM.watchIndex = 1
			end
		end
		return
	end

	if B_AS_GS["PageLock"] then
		B_AS_VM_AdvanceCheap(totalAuctions, positiveCount or 0)
		return
	end

	if not B_AS_GS["PageFixed"] then
		B_AS_Page = B_AS_Page + 1
		if B_AS_Page > lastPage then
			B_AS_Page = 0
		end
	end
end

function B_AS_VM_IsCandidate(name, count, buyPrice, owner, quality, level)
	if not name or not count or count < 1 or not buyPrice or buyPrice <= 0 then
		return false
	end
	if owner == UnitName("player") then
		return false
	end
	if B_AS_TraderWhitelist[owner] == true then
		return false
	end

	local rule = B_AS_VM_FindRule(name)
	if rule then
		local minStack = tonumber(rule.minStack) or 1
		local maxUnitPrice = tonumber(rule.maxUnitPrice) or 0
		local maxTotalPrice = tonumber(rule.maxTotalPrice) or 0
		local unitPrice = math.floor(buyPrice / count)
		if count < minStack then
			return false
		end
		if maxUnitPrice > 0 and unitPrice > maxUnitPrice then
			return false
		end
		if maxTotalPrice > 0 and buyPrice > maxTotalPrice then
			return false
		end
		return true
	end

	if B_AS_VM_WatchCount() > 0 then
		return false
	end
	return B_AS_CheckItem(name, count, quality, level, buyPrice, owner)
end

function B_AS_VM_AnalyzeResults()
	local numBatch, totalAuctions = GetNumAuctionItems("list")
	B_AS_CurrentPageAuctions = numBatch or 0
	B_AS_TotalAuctions = totalAuctions or 0

	local now = GetTime()
	B_AS_VM.lastLatency = now - B_AS_VM.querySentAt
	B_AS_VM.queryInFlight = false
	B_AS_VM.nextQueryAt = now + B_AS_VM_DUP_GUARD

	local zeroCount = 0
	local positiveCount = 0
	local minBuy = nil
	local maxBuy = nil
	local minUnit = nil
	local maxUnit = nil
	local prevBuy = nil
	local violations = 0

	for i = 1, B_AS_CurrentPageAuctions do
		local name,_,count,quality,_,level,_,_,buyPrice,_,_,owner = GetAuctionItemInfo("list", i)
		if name then
			B_AS_VM.seen = B_AS_VM.seen + 1
		end
		if buyPrice and buyPrice > 0 and count and count > 0 then
			positiveCount = positiveCount + 1
			B_AS_VM.positiveBuyouts = B_AS_VM.positiveBuyouts + 1
			local unitPrice = math.floor(buyPrice / count)
			if not minBuy or buyPrice < minBuy then minBuy = buyPrice end
			if not maxBuy or buyPrice > maxBuy then maxBuy = buyPrice end
			if not minUnit or unitPrice < minUnit then minUnit = unitPrice end
			if not maxUnit or unitPrice > maxUnit then maxUnit = unitPrice end
			if prevBuy and buyPrice < prevBuy then
				violations = violations + 1
				B_AS_VM.orderViolations = B_AS_VM.orderViolations + 1
			end
			prevBuy = buyPrice
			if B_AS_VM.verbose then
				B_AS_Log("[VM-ITEM] q"..B_AS_VM.querySeq.." p"..B_AS_VM.queryPage.." #"..i.." "..count.."x "..name.." total="..B_AS_MoneyToText(buyPrice).." unit="..B_AS_MoneyToText(unitPrice).." seller="..tostring(owner))
			end
		else
			zeroCount = zeroCount + 1
			B_AS_VM.zeroBuyouts = B_AS_VM.zeroBuyouts + 1
		end
	end

	local rangeText = "none"
	if minBuy then
		rangeText = B_AS_MoneyToText(minBuy).."-"..B_AS_MoneyToText(maxBuy)
	end
	local unitText = "none"
	if minUnit then
		unitText = B_AS_MoneyToText(minUnit).."-"..B_AS_MoneyToText(maxUnit)
	end
	B_AS_Log("[VM-RESULT] q"..B_AS_VM.querySeq.." name='"..B_AS_VM.queryName.."' page="..B_AS_VM.queryPage.." rows="..B_AS_CurrentPageAuctions.."/"..B_AS_TotalAuctions.." latency="..string.format("%.3f", B_AS_VM.lastLatency).."s zero="..zeroCount.." buyouts="..positiveCount.." totalRange="..rangeText.." unitRange="..unitText.." orderViol="..violations.." phase="..B_AS_VM.cheapPhase)

	if B_AS_VM.suppressAdvanceOnce then
		B_AS_VM.suppressAdvanceOnce = false
		B_AS_Log("[BUY-RESCAN] refreshed page="..B_AS_VM.queryPage.." without advancing scan state")
	else
		B_AS_VM_AdvanceQuery(B_AS_TotalAuctions, positiveCount)
	end
end

function B_AS_VM_ResetStats()
	B_AS_VM.seen = 0
	B_AS_VM.positiveBuyouts = 0
	B_AS_VM.zeroBuyouts = 0
	B_AS_VM.candidates = 0
	B_AS_VM.orderViolations = 0
	B_AS_VM.timeouts = 0
	B_AS_VM.duplicateListEvents = 0
	B_AS_VM.lastLatency = 0.0
	B_AS_VM.nextQueryAt = 0.0
	B_AS_VM.watchIndex = 1
	B_AS_VM.watchPage = 0
	B_AS_VM.cheapCycles = 0
	B_AS_VM.cheapVerifications = 0
	B_AS_VM.cheapFallbacks = 0
	B_AS_VM.stateResets = 0
	B_AS_VM.buyAttempts = 0
	B_AS_VM.buyConfirmed = 0
	B_AS_VM.buyFailed = 0
	B_AS_VM.buyTimeouts = 0
	B_AS_VM.lastBuyResult = "none"
	B_AS_VM_ResetCheapSearch(true)
	B_AS_Page = 0
	B_AS_Log("[VM-DIAG] stats reset")
end

function B_AS_VM_Status()
	local boundary = "?"
	if B_AS_VM.cheapBoundary then
		boundary = tostring(B_AS_VM.cheapBoundary)
	end
	local windowStart = "?"
	if B_AS_VM.cheapWindowStart then
		windowStart = tostring(B_AS_VM.cheapWindowStart)
	end
	DEFAULT_CHAT_FRAME:AddMessage("[AS VM] q="..B_AS_VM.querySeq.." queryPending="..tostring(B_AS_VM.queryInFlight).." buyPending="..tostring(B_AS_VM.buyPending).." seen="..B_AS_VM.seen.." candidates="..B_AS_VM.candidates.." cheapPhase="..B_AS_VM.cheapPhase.." boundary="..boundary.." scanPage="..B_AS_VM.cheapScanPage.." buys="..B_AS_VM.buyConfirmed.."/"..B_AS_VM.buyAttempts.." failed="..B_AS_VM.buyFailed.." spent="..B_AS_MoneyToText(B_AS_VM.sessionSpent).." sessionCount="..B_AS_VM.sessionPurchases.." lastBuy="..B_AS_VM.lastBuyResult, 0.37, 1, 0)
end

function B_AS_VM_IsBuyScanPhase()
	if B_AS_VM_WatchCount() > 0 then
		return true
	end
	if B_AS_GS["PageLock"] then
		return B_AS_VM.cheapPhase == "scan"
	end
	return true
end

function B_AS_VM_MaxSessionSpend()
	local value = tonumber(B_AS_GS["BuyMaxSession"]) or 500000
	if value < 0 then value = 0 end
	return value
end

function B_AS_VM_MaxSessionCount()
	local value = tonumber(B_AS_GS["BuyMaxCount"]) or 20
	if value < 0 then value = 0 end
	return value
end

function B_AS_VM_StopLiveBuy(reason)
	if B_AS_GS["AutoBuy"] == true then
		B_AS_SetVar("AutoBuy", false)
	end
	B_AS_VM.lastBuyResult = "STOP:"..tostring(reason)
	B_AS_Log("[BUY-STOP] "..tostring(reason))
	DEFAULT_CHAT_FRAME:AddMessage("[AS] AutoBuy LIVE stopped: "..tostring(reason), 1, 0.25, 0.25)
end

function B_AS_VM_CheckSessionLimit()
	local maxCount = B_AS_VM_MaxSessionCount()
	local maxSpend = B_AS_VM_MaxSessionSpend()
	if maxCount > 0 and B_AS_VM.sessionPurchases >= maxCount then
		B_AS_VM_StopLiveBuy("session purchase limit "..maxCount.." reached")
		return false
	end
	if maxSpend > 0 and B_AS_VM.sessionSpent >= maxSpend then
		B_AS_VM_StopLiveBuy("session spend limit "..B_AS_MoneyToText(maxSpend).." reached")
		return false
	end
	return true
end

function B_AS_VM_BuyFailureReason(message)
	if not message then return nil end
	if ERR_ITEM_NOT_FOUND and message == ERR_ITEM_NOT_FOUND then return "item_not_found" end
	if ERR_NOT_ENOUGH_MONEY and message == ERR_NOT_ENOUGH_MONEY then return "not_enough_money" end
	if ERR_AUCTION_BID_OWN and message == ERR_AUCTION_BID_OWN then return "own_auction" end
	if ERR_AUCTION_HIGHER_BID and message == ERR_AUCTION_HIGHER_BID then return "higher_bid" end
	if ERR_AUCTION_DATABASE_ERROR and message == ERR_AUCTION_DATABASE_ERROR then return "database_error" end
	if ERR_AUCTION_BID_INCREMENT and message == ERR_AUCTION_BID_INCREMENT then return "bid_increment" end
	if ERR_AUCTION_MIN_BID and message == ERR_AUCTION_MIN_BID then return "min_bid" end
	return nil
end

function B_AS_VM_FinishBuy(success, reason, hardStop)
	if not B_AS_VM.buyPending or not B_AS_VM.buyCandidate then
		return false
	end

	local p = B_AS_VM.buyCandidate
	B_AS_VM.buyPending = false
	B_AS_VM.buyCandidate = nil

	if success then
		B_AS_VM.buyConfirmed = B_AS_VM.buyConfirmed + 1
		B_AS_VM.sessionPurchases = B_AS_VM.sessionPurchases + 1
		B_AS_VM.sessionSpent = B_AS_VM.sessionSpent + p.buyPrice
		B_AS_VM.lastBuyResult = "OK:"..p.name
		B_AS_Log("[BUY-OK] #"..p.buySeq.." "..p.count.."x "..p.desc.." total="..B_AS_MoneyToText(p.buyPrice).." seller="..tostring(p.owner).." spent="..B_AS_MoneyToText(B_AS_VM.sessionSpent).." count="..B_AS_VM.sessionPurchases)
	else
		B_AS_VM.buyFailed = B_AS_VM.buyFailed + 1
		if reason == "timeout" then
			B_AS_VM.buyTimeouts = B_AS_VM.buyTimeouts + 1
		end
		B_AS_VM.lastBuyResult = "FAIL:"..tostring(reason)
		B_AS_Log("[BUY-FAIL] #"..p.buySeq.." "..p.count.."x "..p.desc.." total="..B_AS_MoneyToText(p.buyPrice).." reason="..tostring(reason))
	end

	B_AS_VM.forcedQueryPage = p.page
	B_AS_VM.forcedQueryName = p.queryName or ""
	B_AS_VM.suppressAdvanceOnce = true
	B_AS_VM.nextQueryAt = GetTime() + B_AS_VM_BUY_RESCAN_DELAY

	if hardStop then
		B_AS_VM_StopLiveBuy(reason)
	elseif success then
		B_AS_VM_CheckSessionLimit()
	end
	return true
end

function B_AS_VM_HandleMessage(eventName, message)
	local handled = false
	if B_AS_VM.buyPending and message then
		if (eventName == "CHAT_MSG_SYSTEM" or eventName == "UI_INFO_MESSAGE")
			and ERR_AUCTION_BID_PLACED and message == ERR_AUCTION_BID_PLACED then
			handled = B_AS_VM_FinishBuy(true, "bid_accepted", false)
		elseif eventName == "UI_ERROR_MESSAGE" then
			local reason = B_AS_VM_BuyFailureReason(message)
			if reason then
				local hardStop = (reason == "not_enough_money" or reason == "database_error")
				handled = B_AS_VM_FinishBuy(false, reason, hardStop)
			end
		end
	end

	if B_AS_IsOpen and message and message ~= "" then
		if handled or B_AS_VM.verbose then
			B_AS_Log("[VM-EVENT] "..eventName.." "..tostring(message))
		end
	end
end

function B_AS_VM_BuyStatus()
	local maxSpend = B_AS_VM_MaxSessionSpend()
	local maxCount = B_AS_VM_MaxSessionCount()
	DEFAULT_CHAT_FRAME:AddMessage("[AS BUY] live="..tostring(B_AS_GS["AutoBuy"] == true).." pending="..tostring(B_AS_VM.buyPending).." confirmed="..B_AS_VM.buyConfirmed.." failed="..B_AS_VM.buyFailed.." spent="..B_AS_MoneyToText(B_AS_VM.sessionSpent).."/"..B_AS_MoneyToText(maxSpend).." count="..B_AS_VM.sessionPurchases.."/"..maxCount, 0.37, 1, 0)
end

function B_AS_VM_BuySlash(msg)
	local text = string.lower(msg or "")
	local _,_,spendGold,maxCount = string.find(text, "^%s*limits%s+(%d+)%s+(%d+)%s*$")
	if spendGold and maxCount then
		B_AS_SetVar("BuyMaxSession", tonumber(spendGold) * 10000)
		B_AS_SetVar("BuyMaxCount", tonumber(maxCount))
		B_AS_VM_BuyStatus()
		return
	end
	if text == "reset" then
		if B_AS_VM.buyPending then
			DEFAULT_CHAT_FRAME:AddMessage("[AS BUY] Cannot reset while a buy is pending.", 1, 0.25, 0.25)
			return
		end
		B_AS_VM.sessionSpent = 0
		B_AS_VM.sessionPurchases = 0
		B_AS_VM.lastBuyResult = "reset"
		B_AS_VM_BuyStatus()
	elseif text == "off" then
		B_AS_VM_StopLiveBuy("manual stop")
	else
		B_AS_VM_BuyStatus()
		DEFAULT_CHAT_FRAME:AddMessage("[AS BUY] /asbuy status | limits <gold> <count> | reset | off", 0.37, 1, 0)
	end
end

function B_AS_VM_Slash(msg)
	local cmd = string.lower(msg or "")
	if cmd == "reset" then
		B_AS_VM_ResetStats()
	elseif cmd == "verbose" then
		B_AS_VM.verbose = not B_AS_VM.verbose
		DEFAULT_CHAT_FRAME:AddMessage("[AS VM] verbose="..tostring(B_AS_VM.verbose), 0.37, 1, 0)
	else
		B_AS_VM_Status()
		DEFAULT_CHAT_FRAME:AddMessage("[AS VM] /asdiag status | reset | verbose", 0.37, 1, 0)
	end
end

function B_AS_VM_AttemptBuy(candidate)
	if B_AS_VM.buyPending then
		return false
	end
	if not B_AS_VM_CheckSessionLimit() then
		return false
	end

	local maxSpend = B_AS_VM_MaxSessionSpend()
	if maxSpend > 0 and B_AS_VM.sessionSpent + candidate.buyPrice > maxSpend then
		B_AS_VM_StopLiveBuy("candidate would exceed session spend limit")
		return false
	end
	if candidate.buyPrice > GetMoney() then
		B_AS_VM_StopLiveBuy("not enough money for candidate")
		return false
	end

	B_AS_VM.buySeq = B_AS_VM.buySeq + 1
	B_AS_VM.buyAttempts = B_AS_VM.buyAttempts + 1
	candidate.buySeq = B_AS_VM.buySeq
	candidate.page = B_AS_VM.queryPage
	candidate.queryName = B_AS_VM.queryName
	B_AS_VM.buyPending = true
	B_AS_VM.buySentAt = GetTime()
	B_AS_VM.buyCandidate = candidate
	B_AS_VM.lastBuyResult = "PENDING:"..candidate.name

	B_AS_Log("[BUY-SENT] #"..candidate.buySeq.." index="..candidate.index.." page="..candidate.page.." "..candidate.count.."x "..candidate.desc.." total="..B_AS_MoneyToText(candidate.buyPrice).." unit="..B_AS_MoneyToText(candidate.unitPrice).." seller="..tostring(candidate.owner))
	PlaceAuctionBid("list", candidate.index, candidate.buyPrice)
	return true
end

-- AutoBuy LIVE submits at most one buyout from a fresh list result.
-- With AutoBuy OFF, Manual Buy / DryRun only log matching candidates.
function B_AS_Buy(buyAll)
	if B_AS_IsOpen == false or B_AS_VM.buyPending then
		return
	end
	if B_AS_VM.lastEvaluatedSeq == B_AS_VM.querySeq then
		return
	end
	B_AS_VM.lastEvaluatedSeq = B_AS_VM.querySeq

	if not B_AS_VM_IsBuyScanPhase() then
		return
	end

	local live = (B_AS_GS["AutoBuy"] == true)
	local found = 0
	local best = nil
	local maxSpend = B_AS_VM_MaxSessionSpend()
	local remaining = 0
	if maxSpend > 0 then
		remaining = maxSpend - B_AS_VM.sessionSpent
	end

	for auctionIndex = 1, B_AS_CurrentPageAuctions do
		local name,_,count,quality,_,level,_,_,buyPrice,_,_,owner = GetAuctionItemInfo("list", auctionIndex)
		local link = GetAuctionItemLink("list", auctionIndex)
		if B_AS_VM_IsCandidate(name, count, buyPrice, owner, quality, level) then
			found = found + 1
			B_AS_VM.candidates = B_AS_VM.candidates + 1
			local unitPrice = math.floor(buyPrice / count)
			local desc = link or name
			if not live then
				B_AS_Log("[DRYRUN] candidate "..count.."x "..desc.." total="..B_AS_MoneyToText(buyPrice).." unit="..B_AS_MoneyToText(unitPrice).." seller="..tostring(owner).." q="..B_AS_VM.querySeq.." page="..B_AS_VM.queryPage)
				if not buyAll then
					break
				end
			else
				local fitsSession = (maxSpend <= 0 or buyPrice <= remaining)
				if fitsSession and (not best or buyPrice < best.buyPrice or (buyPrice == best.buyPrice and unitPrice < best.unitPrice)) then
					best = {
						index = auctionIndex,
						name = name,
						count = count,
						quality = quality,
						level = level,
						buyPrice = buyPrice,
						unitPrice = unitPrice,
						owner = owner,
						desc = desc,
					}
				end
			end
		end
	end

	if live then
		if best then
			B_AS_VM_AttemptBuy(best)
		elseif found > 0 and maxSpend > 0 then
			B_AS_VM_StopLiveBuy("matching candidates exceed remaining session budget")
		end
	else
		B_AS_Print("Dry-run candidates on result: "..found)
	end
end

--[[
	Queries an auction house page using the user's defined settings.
]]
function B_AS_Scan()
	if B_AS_IsOpen == false or B_AS_VM.buyPending then
		return
	end

	local now = GetTime()
	if now < B_AS_VM.nextQueryAt then
		return
	end
	if B_AS_VM.queryInFlight then
		if now - B_AS_VM.querySentAt < B_AS_VM_QUERY_TIMEOUT then
			return
		end
		B_AS_VM.queryInFlight = false
		B_AS_VM.nextQueryAt = now + B_AS_VM_DUP_GUARD
		B_AS_VM.timeouts = B_AS_VM.timeouts + 1
		B_AS_Log("[VM-TIMEOUT] query #"..B_AS_VM.querySeq.." age="..string.format("%.3f", now - B_AS_VM.querySentAt).."s")
	end

	if not CanSendAuctionQuery() then
		return
	end

	local queryName, queryPage, rule = B_AS_VM_GetQuery()
	queryPage = tonumber(queryPage) or 0
	if queryPage < 0 then queryPage = 0 end

	B_AS_VM.querySeq = B_AS_VM.querySeq + 1
	B_AS_VM.queryInFlight = true
	B_AS_VM.querySentAt = now
	B_AS_VM.queryPage = queryPage
	B_AS_VM.queryName = queryName or ""

	AuctionFrameBrowse.page = queryPage
	B_AS_Print("VM query #"..B_AS_VM.querySeq.." page "..queryPage.." name='"..B_AS_VM.queryName.."'")

	QueryAuctionItems(B_AS_VM.queryName, nil, nil, 0, B_AS_GS["ScanClass"], 0, queryPage, false, B_AS_GS["ScanMinQuality"], false)
end

--[[
	Check if an item should be bought or not
	Arguments:
		name		Item Name
		quality		Item quality number
		level		Required item level to use this item
		buyPrice	Buyout price
		owner		Player name of the seller

	Returns a boolean. True: Buy the item; False: Do NOT buy the item
]]
function B_AS_CheckItem(name, count, quality, level, buyPrice, owner)

	local doNotIgnoreLowGear = false	-- Ignore the min. gear level check if true

	-- Do not buy your own auctions
	if (owner == UnitName("player")) then
		return false
	end

	-- Check if the seller is whitelisted
	if (B_AS_TraderWhitelist[owner] == true) then
		return false
	end

	--[[
		Check if this item is in the Specials list and
		save the item's custom quality level in priceQuality
	]]
	local priceQuality = quality
	for specialName, specialQuality in B_AS_Specials do
		if string.find(name, specialName, 1, true) ~= nil then
			priceQuality = specialQuality
			doNotIgnoreLowGear = true
			break
		end
	end

	--[[
		Check if the item is in the SpecialsExact list
	]]
	if B_AS_SpecialsExact[name] then
		priceQuality = B_AS_SpecialsExact[name]
		doNotIgnoreLowGear = true
	end

	--[[
		Check if the item is in the SpecialsExactConditional list and the stack
		minimum is reached.
	]]
	if B_AS_SpecialsExactConditional[name] then
		local specialQuality	= B_AS_SpecialsExactConditional[name][1]
		local minStack		= B_AS_SpecialsExactConditional[name][2]
		if count >= minStack then
			priceQuality = specialQuality
			doNotIgnoreLowGear = true
		end
	end

	--[[
		Check if the item is a recipe/plan/pattern by checking if
		the item name contains strings like "Pattern: " or "Plans: "
	]]
	local isRecipe = false
	for _, recipeName in B_AS_RecipeNames do
		if string.find(name, recipeName..": ", 1, true) ~= nil then
			isRecipe = true
			break
		end
	end

	-- Do not buy the item if it's a recipe with quality below RecipeMinQuality
	if (isRecipe and priceQuality < B_AS_GS["RecipeMinQuality"]) then
		return false
	end

	-- Do not buy the item if it's quality is below BuyMinQuality
	if (priceQuality < B_AS_GS["BuyMinQuality"]) then
		return false
	end

	-- Do not buy gray items
	if (priceQuality == 0) then
		return false
	end

	-- Do not buy the item if it's too expensive for its quality
	if (buyPrice > tonumber(B_AS_GS["OptionPriceQuality" .. priceQuality])) then
		return false
	end

	--[[
		Ignore items with required lvl between 1 and LowGearLevel
		if the option IgnoreLowGear is active
	]]
	if (doNotIgnoreLowGear == false and B_AS_GS["IgnoreLowGear"] == true) then
		local minLevel = tonumber(B_AS_GS["LowGearLevel"])
		if (minLevel ~= nil) then
			if (level > 1 and level < minLevel) then
				return false
			end
		end
	end

	-- Do not buy auctions that cost more than you have
	if (buyPrice > GetMoney()) then
		-- Warn the user that you need more money
		B_AS_Print(">>> " .. name .. " too expensive: " .. B_AS_MoneyToText(buyPrice))
		return false
	end

	-- Buy the item
	return true
end


-------------------------------------------------------------------------------


function B_AS_SetVar(var, value)

	local settings = B_AS_VarSettings[var]
	if not settings then
		return
	end

	local type	= settings[B_AS_S_TYPE]
	local gui	= settings[B_AS_S_GUI]
	local text	= settings[B_AS_S_TEXT]
	local values	= settings[B_AS_S_VALUES]
	local callback	= settings[B_AS_S_CALLBACK]

	local doSetValue = true

	if (gui ~= nil) then
		local valueText = nil

		if (type == B_AS_T_BOOL) then
			if (value == true) then
				valueText = "|cFF00FF00[ON]|r"
			else
				valueText = "|cFFFF5050[OFF]|r"
			end
		elseif (type == B_AS_T_LIST) then
			if (values[value] ~= nil) then
				valueText = "|cFFA0A0FF" .. values[value] .. "|r"
			else
				valueText = value
			end
		elseif (type == B_AS_T_TEXT) then
			gui:SetText(value)
		elseif (type == B_AS_T_NUMBER) then
			value = tonumber(value)
			if (value~= nil) then
				gui:SetText(value)
			else
				doSetValue = false
			end
		elseif (type == B_AS_T_LINES) then
			gui:Clear()
			for _,v in value do
				gui:AddMessage(v)
			end
		end

		if (valueText == nil) then
			valueText = tostring(value)
		end

		if (text and valueText) then
			gui:SetText(text .. ": " .. valueText)
			B_AS_Print("SET "..var.." = "..valueText)
		else
			B_AS_Print("SET "..var)
		end
	else
		B_AS_Print("SET "..var)
	end

	if (doSetValue == true) then
		B_AS_GS[var] = value
	end

	if (callback ~= nil) then
		callback(var, value)
	end

end
function B_AS_ToggleVar(var)

	local newValue = not B_AS_GS[var]
	B_AS_SetVar(var, newValue)
end
function B_AS_IncreaseVar(var)

	local settings	= B_AS_VarSettings[var]
	local values	= settings[B_AS_S_VALUES]
	local startNum	= settings[B_AS_S_RANGE_S]
	local endNum	= settings[B_AS_S_RANGE_E]

	local newValue = B_AS_GS[var] + 1
	if newValue > endNum then
		newValue = startNum
	end

	B_AS_SetVar(var, newValue)
end

function B_AS_InitializeSettings()
	if (B_AS_GS == nil) then
		B_AS_GS = {}
	end

	-- Migration-safe defaults: old SavedVariables gain newly introduced keys.
	for var, settings in B_AS_VarSettings do
		if B_AS_GS[var] == nil then
			B_AS_GS[var] = settings[B_AS_S_DEFAULT]
		end
	end

	for var, value in B_AS_GS do
		B_AS_SetVar(var, value)
	end
end

function B_AS_InitializeItems()
	local numItems = 22

	for i = 1, numItems do
		local settingsItem = B_AS_GS["Items"][i]

		if not settingsItem then
			B_AS_GS["Items"][i] = {}
			settingsItem = B_AS_GS["Items"][i]
			settingsItem[B_AS_I_NAME] = ""
			settingsItem[B_AS_I_PARTIAL] = false
			settingsItem[B_AS_I_QUALITY] = 1
			settingsItem[B_AS_I_STACK] = 1
		end

		local frameItem = CreateFrame("frame", "B_AS_Item" .. i, B_AS_ItemsContainer, "B_AS_ItemTemplate")
		local frameName, framePartial, frameQuality, frameStack = frameItem:GetChildren()

		frameName:SetText(settingsItem[B_AS_I_NAME])
		frameName:SetScript("OnTextChanged", function()
			settingsItem[B_AS_I_NAME] = frameName:GetText()
		end)

		framePartial:SetChecked(settingsItem[B_AS_I_PARTIAL])
		framePartial:SetScript("OnClick", function()
			settingsItem[B_AS_I_PARTIAL] = framePartial:GetChecked()
		end)

		UIDropDownMenu_Initialize(frameQuality, function()
			local info = {}
			for i = 1, table.getn(B_AS_QualityList) do
				info.text = B_AS_QualityList[i]
				info.value = i
				info.func = function()
					UIDropDownMenu_SetSelectedID(frameQuality, this:GetID())
					settingsItem[B_AS_I_QUALITY] = this:GetID()
				end
				info.checked = nil
				UIDropDownMenu_AddButton(info, 1)
			end
		end)
		UIDropDownMenu_SetSelectedID(frameQuality, settingsItem[B_AS_I_QUALITY])

		frameStack:SetText(settingsItem[B_AS_I_STACK])
		frameStack:SetScript("OnTextChanged", function()
			local number = tonumber(frameStack:GetText())
			if (number ~= nil) then
				settingsItem[B_AS_I_STACK] = frameStack:GetText()
			end
		end)

		frameItem:SetPoint("TOPLEFT", B_AS_ItemsContainer, "TOPLEFT", 20, -20 + i * -16)
		frameItem:Show()
	end
end

-------------------------------------------------------------------------------


function B_AS_OnLoad()
	this:RegisterEvent("ADDON_LOADED")
	this:RegisterEvent("AUCTION_HOUSE_SHOW")
	this:RegisterEvent("AUCTION_HOUSE_CLOSED")
	this:RegisterEvent("AUCTION_ITEM_LIST_UPDATE")
	this:RegisterEvent("CHAT_MSG_SYSTEM")
	this:RegisterEvent("UI_INFO_MESSAGE")
	this:RegisterEvent("UI_ERROR_MESSAGE")
end

function B_AS_OnEvent()
	if (event == "ADDON_LOADED") then
		if (string.lower(arg1) == "auctionsniper") then
			B_AS_InitializeSettings()
			B_AS_InitializeItems()
			-- Migration safety: old dry-run AutoBuy=ON never becomes live automatically.
			B_AS_SetVar("AutoBuy", false)
			B_AS_SetVar("AutoSlowBuy", false)
			SLASH_AUCTIONSNIPERDIAG1 = "/asdiag"
			SlashCmdList["AUCTIONSNIPERDIAG"] = B_AS_VM_Slash
			SLASH_AUCTIONSNIPERBUY1 = "/asbuy"
			SlashCmdList["AUCTIONSNIPERBUY"] = B_AS_VM_BuySlash
			DEFAULT_CHAT_FRAME:AddMessage("AuctionSniper " .. B_AS_VERSION .. " loaded - AutoBuy LIVE is OFF. Enable it explicitly to spend gold.", 0.37, 1, 0)
		end

	elseif (event == "AUCTION_HOUSE_SHOW") then
		B_AS_Frame:Show()
		B_AS_IsOpen = true
		B_AS_VM.queryInFlight = false
		B_AS_VM.nextQueryAt = 0.0
		B_AS_VM.watchIndex = 1
		B_AS_VM.watchPage = 0
		B_AS_VM_ResetCheapSearch(true)
		B_AS_VM.buyPending = false
		B_AS_VM.buyCandidate = nil
		B_AS_VM.forcedQueryPage = nil
		B_AS_VM.forcedQueryName = nil
		B_AS_VM.suppressAdvanceOnce = false
		B_AS_Page = 0
		B_AS_Log("[VM] auction house opened; AutoBuy LIVE="..tostring(B_AS_GS["AutoBuy"] == true).." sessionLimit="..B_AS_MoneyToText(B_AS_VM_MaxSessionSpend()).." countLimit="..B_AS_VM_MaxSessionCount())

	elseif (event == "AUCTION_HOUSE_CLOSED") then
		B_AS_Frame:Hide()
		B_AS_IsOpen = false
		B_AS_VM.queryInFlight = false
		if B_AS_VM.buyPending then
			B_AS_VM_FinishBuy(false, "auction_house_closed", true)
		end

	elseif (event == "AUCTION_ITEM_LIST_UPDATE") then
		if B_AS_VM.queryInFlight then
			B_AS_VM_AnalyzeResults()
			if (B_AS_GS["AutoBuy"] == true) then
				B_AS_Buy(true)
			elseif (B_AS_GS["AutoSlowBuy"] == true) then
				B_AS_Buy(false)
			end
		else
			B_AS_VM.duplicateListEvents = B_AS_VM.duplicateListEvents + 1
			if B_AS_VM.verbose then
				B_AS_Log("[VM-DUP] ignored AUCTION_ITEM_LIST_UPDATE with no query in flight")
			end
		end

	elseif (event == "CHAT_MSG_SYSTEM" or event == "UI_INFO_MESSAGE" or event == "UI_ERROR_MESSAGE") then
		B_AS_VM_HandleMessage(event, arg1)
	end
end

function B_AS_SlowBuyTick(currTime)
	-- DryRun candidates are evaluated only when a fresh result arrives.
	return
end
function B_AS_SyncTime()
	if B_AS_GS["Sync"] == true then
		local timePart = mod(GetTime(), B_AS_SCAN_BASE)
		local timeWait = (B_AS_SCAN_BASE / B_AS_GS["SyncChars"]) * (B_AS_GS["SyncIndex"] - 1)

		if timePart < timeWait or timePart > timeWait + B_AS_SYNC_MAXSKEW then
			return false
		end
	end
	return true
end
function B_AS_AutoScanTick(currTime)
	if B_AS_SyncTime() then
		B_AS_Scan()
	end
end
function B_AS_OnUpdate()

	if (B_AS_IsOpen == true) then

		local currTime = GetTime()

		if B_AS_VM.buyPending and currTime - B_AS_VM.buySentAt >= B_AS_VM_BUY_TIMEOUT then
			B_AS_VM_FinishBuy(false, "timeout", true)
		end

		if B_AS_GS["AutoSlowBuy"] == true then
			B_AS_SlowBuyTick(currTime)
		end

		if B_AS_GS["AutoScan"] == true then
			B_AS_AutoScanTick(currTime)
		end
	end
end