-- AuxVmangos 0.1-vmangos
-- Independent implementation for WoW 1.12.1 / vMaNGOS.
-- Default mode is DRY-RUN. LIVE purchase mode requires an explicit /avm live on.

AVM_VERSION = "0.16-live-de-depth3"
AVM_QUERY_TIMEOUT = 5.0
AVM_PENDING_TIMEOUT = 3.0
AVM_UNKNOWN_HOLD = 10.0
AVM_EVENT_SETTLE = 0.35
AVM_EXTRA_EVENT_WINDOW = 1.0
AVM_TICK = 0.05
AVM_WATCH_SLOTS = 16
AVM_WATCH_MAX_PAGES = 100

local AVM_AUX_INFO_OK, AVM_AUX_INFO = pcall(require, "aux.util.info")
local AVM_AUX_DE_OK, AVM_AUX_DE = pcall(require, "aux.core.disenchant")

local AVM_DE_MATERIAL_IDS = {
	[10940]=true,[10938]=true,[10939]=true,[10978]=true,[10998]=true,
	[11083]=true,[11082]=true,[11084]=true,[11134]=true,[11138]=true,
	[11137]=true,[11135]=true,[11139]=true,[11174]=true,[11177]=true,
	[11176]=true,[11175]=true,[11178]=true,[16202]=true,[14343]=true,
	[16204]=true,[16203]=true,[14344]=true,[20725]=true,
}

AVM = {
	open = false,
	phase = "IDLE",
	queryInFlight = false,
	querySeq = 0,
	queryPage = 0,
	queryKind = "",
	querySentAt = 0,
	queryName = "",
	ruleIndex = 1,
	activeRuleName = "",
	boundaryCache = {},
	cacheBoundary = nil,
	cachePrevOk = false,
	nextQueryAt = 0,
	lastResultAt = 0,
	total = 0,
	lastPage = 0,
	boundaryLow = 0,
	boundaryHigh = 0,
	boundaryPage = nil,
	scanOffset = 0,
	bestCandidate = nil,
	watchPagesScanned = 0,
	watchCycles = 0,
	watchRaces = 0,
	rulesDirty = false,
	uiGeneration = 0,
	fastMarketNative = false,
	fastMarketPages = 0,
	fastVendorBest = nil,
	fastVendorArmed = false,
	auxArb = {
		active = false,
		paused = false,
		pausePending = false,
		resumePending = false,
		pageBest = nil,
		bestSeen = nil,
		candidate = nil,
		pages = 0,
		lastPage = 0,
		vendorCandidates = 0,
		deCandidates = 0,
		deNoValue = 0,
		deRawCandidates = {},
		deMaterialBook = {},
		deBest = nil,
		deVerify = nil,
	},
	candidate = nil,
	revalidatePages = nil,
	revalidatePos = 0,
	pending = nil,
	unknown = nil,
	nextTick = 0,
	sessionSpend = 0,
	sessionBuys = 0,
	vendor = {
		active = false,
		requested = false,
		stopRequested = false,
		phase = "IDLE",
		boundary = nil,
		low = 0,
		high = 0,
		page = 0,
		lastPage = 0,
		pagesScanned = 0,
		startedAt = 0,
		best = nil,
		segment = "",
		segmentStart = 0,
		segmentEnd = 0,
		resumeSegment = "HOT",
		resumeSeekIndex = 1,
		seekTargets = {},
		seekIndex = 0,
		seekTarget = 0,
		seekLow = 0,
		seekHigh = 0,
		seekLocatedPage = 0,
		priceCeiling = false,
		consecutiveTimeouts = 0,
	},
	market = {
		active = false,
		requested = false,
		stopRequested = false,
		phase = "IDLE",
		boundary = nil,
		low = 0,
		high = 0,
		page = 0,
		lastPage = 0,
		startedAt = 0,
		items = {},
		auctions = 0,
		units = 0,
		consecutiveTimeouts = 0,
	},
	stats = {
		queries = 0,
		results = 0,
		extraEvents = 0,
		timeouts = 0,
		boundaryQueries = 0,
		cacheVerifications = 0,
		cacheHits = 0,
		cacheMisses = 0,
		walletBlocks = 0,
		candidates = 0,
		watchPages = 0,
		watchBest = 0,
		watchCaps = 0,
		watchEarlyStops = 0,
		watchRaces = 0,
		revalidations = 0,
		buySent = 0,
		confirmed = 0,
		failed = 0,
		unknown = 0,
		marketScans = 0,
		marketPages = 0,
		marketRows = 0,
		marketTimeouts = 0,
		vendorScans = 0,
		vendorPages = 0,
		vendorCandidates = 0,
		vendorBest = 0,
		vendorHotPages = 0,
		vendorSweepPages = 0,
		vendorSweepPasses = 0,
		vendorSeekQueries = 0,
		vendorSeekPages = 0,
		vendorSeekTargets = 0,
		vendorPriceCeilings = 0,
		vendorTimeouts = 0,
		auxArbPages = 0,
		auxArbCandidates = 0,
		auxArbVendorCandidates = 0,
		auxArbDeCandidates = 0,
		auxArbPauses = 0,
		auxArbResumes = 0,
	},
	recent = {},
}

local function avm_diag_record(msg)
	if not AVM_DB then return end
	if not AVM_DB.diag then AVM_DB.diag = { seq = 0, events = {}, state = {} } end
	local d = AVM_DB.diag
	if not d.events then d.events = {} end
	d.seq = (tonumber(d.seq) or 0) + 1
	local stamp = math.floor((GetTime() or 0) * 1000)
	table.insert(d.events, tostring(d.seq) .. "@" .. tostring(stamp) .. " " .. tostring(msg))
	while table.getn(d.events) > 80 do table.remove(d.events, 1) end

	local v = AVM.vendor or {}
	d.version = AVM_VERSION
	d.state = {
		open = AVM.open and true or false,
		live = AVM_DB.live and true or false,
		querySeq = AVM.querySeq or 0,
		queryKind = AVM.queryKind or "",
		queryPage = AVM.queryPage or 0,
		vendorActive = v.active and true or false,
		vendorPhase = v.phase or "",
		vendorSegment = v.segment or "",
		vendorPage = v.page or 0,
		vendorLastPage = v.lastPage or 0,
		vendorBoundary = v.boundary or -1,
		seekIndex = v.seekIndex or 0,
		seekTarget = v.seekTarget or 0,
		seekLow = v.seekLow or 0,
		seekHigh = v.seekHigh or 0,
		seekLocatedPage = v.seekLocatedPage or 0,
		sessionBuys = AVM.sessionBuys or 0,
		sessionSpend = AVM.sessionSpend or 0,
		queries = AVM.stats and AVM.stats.queries or 0,
		results = AVM.stats and AVM.stats.results or 0,
		timeouts = AVM.stats and AVM.stats.timeouts or 0,
		vendorBest = AVM.stats and AVM.stats.vendorBest or 0,
		vendorHotPages = AVM.stats and AVM.stats.vendorHotPages or 0,
		vendorSeekQueries = AVM.stats and AVM.stats.vendorSeekQueries or 0,
		vendorSeekPages = AVM.stats and AVM.stats.vendorSeekPages or 0,
		vendorTimeouts = AVM.stats and AVM.stats.vendorTimeouts or 0,
		auxArbEnabled = AVM_DB.auxArbEnabled and true or false,
		auxArbLive = AVM_DB.auxArbLive and true or false,
		auxArbPages = AVM.auxArb and AVM.auxArb.pages or 0,
		auxArbVendorCandidates = AVM.auxArb and AVM.auxArb.vendorCandidates or 0,
		auxArbDeCandidates = AVM.auxArb and AVM.auxArb.deCandidates or 0,
		auxArbDeRaw = AVM.auxArb and table.getn(AVM.auxArb.deRawCandidates or {}) or 0,
		auxArbDeVerify = AVM.auxArb and AVM.auxArb.deVerify and true or false,
		deDepthUnits = AVM_DB.deDepthUnits or 3,
		deAhCutPct = AVM_DB.deAhCutPct or 5,
		deSafetyMarginPct = AVM_DB.deSafetyMarginPct or 25,
	}
end

local function avm_print(msg)
	avm_diag_record(msg)
	DEFAULT_CHAT_FRAME:AddMessage("|cff60ff00[AVM]|r " .. tostring(msg), 0.8, 0.9, 1)
end

local function avm_money(copper)
	copper = tonumber(copper) or 0
	local g = math.floor(copper / 10000)
	local s = math.floor((copper - g * 10000) / 100)
	local c = mod(copper, 100)
	if g > 0 then
		return g .. "g " .. s .. "s " .. c .. "c"
	elseif s > 0 then
		return s .. "s " .. c .. "c"
	end
	return c .. "c"
end

local function avm_parse_money(text)
	if not text then return nil end
	text = string.lower(text)
	local _,_,g = string.find(text, "(%d+)%s*g")
	local _,_,s = string.find(text, "(%d+)%s*s")
	local _,_,c = string.find(text, "(%d+)%s*c")
	if g or s or c then
		return (tonumber(g) or 0) * 10000 + (tonumber(s) or 0) * 100 + (tonumber(c) or 0)
	end
	return tonumber(text)
end

local function avm_split(text, sep)
	local out = {}
	local start = 1
	while true do
		local a,b = string.find(text, sep, start, true)
		if not a then
			table.insert(out, string.sub(text, start))
			break
		end
		table.insert(out, string.sub(text, start, a - 1))
		start = b + 1
	end
	return out
end

local function avm_trim(text)
	if not text then return "" end
	text = string.gsub(text, "^%s+", "")
	text = string.gsub(text, "%s+$", "")
	return text
end

local function avm_item_link_key(i)
	local link = GetAuctionItemLink("list", i)
	if not link then return "" end
	local _,_,itemKey = string.find(link, "|H(item:[^|]+)|h")
	if itemKey then return itemKey end
	return ""
end

local function avm_defaults()
	if not AVM_DB then AVM_DB = {} end
	if AVM_DB.enabled == nil then AVM_DB.enabled = false end
	if AVM_DB.live == nil then AVM_DB.live = false end
	if AVM_DB.cheapPages == nil then AVM_DB.cheapPages = 4 end -- legacy, retained for SavedVariables compatibility
	if AVM_DB.watchMaxPages == nil then AVM_DB.watchMaxPages = AVM_WATCH_MAX_PAGES end
	if AVM_DB.boundaryRefresh == nil then AVM_DB.boundaryRefresh = 20 end
	if AVM_DB.maxSessionSpend == nil then AVM_DB.maxSessionSpend = 0 end
	if AVM_DB.maxSessionBuys == nil then AVM_DB.maxSessionBuys = 1 end
	if AVM_DB.rules == nil then AVM_DB.rules = {} end
	if AVM_DB.marketDB == nil then AVM_DB.marketDB = {} end
	if AVM_DB.marketMeta == nil then AVM_DB.marketMeta = {} end
	if AVM_DB.marketRetention == nil then AVM_DB.marketRetention = 24 end
	if AVM_DB.marketAutoMinutes == nil then AVM_DB.marketAutoMinutes = 0 end
	if AVM_DB.marketRetrySeconds == nil then AVM_DB.marketRetrySeconds = 300 end
	if AVM_DB.vendorMinProfit == nil then AVM_DB.vendorMinProfit = 500 end
	if AVM_DB.vendorMaxBuyout == nil then AVM_DB.vendorMaxBuyout = 10000 end
	if AVM_DB.vendorMaxPages == nil then AVM_DB.vendorMaxPages = 10 end -- legacy alias for HOT pages
	if AVM_DB.vendorHotPages == nil then AVM_DB.vendorHotPages = AVM_DB.vendorMaxPages end
	if AVM_DB.vendorSweepPages == nil then AVM_DB.vendorSweepPages = 25 end -- legacy 0.10 setting
	if AVM_DB.vendorSeekRadius == nil then AVM_DB.vendorSeekRadius = 1 end
	if AVM_DB.fastVendorLive == nil then AVM_DB.fastVendorLive = false end
	if AVM_DB.auxArbEnabled == nil then AVM_DB.auxArbEnabled = true end
	if AVM_DB.auxArbLive == nil then AVM_DB.auxArbLive = false end
	if AVM_DB.deMinProfit == nil then AVM_DB.deMinProfit = 500 end
	if AVM_DB.deMaxBuyout == nil then AVM_DB.deMaxBuyout = 10000 end
	if AVM_DB.deDepthUnits == nil then AVM_DB.deDepthUnits = 3 end
	if AVM_DB.deAhCutPct == nil then AVM_DB.deAhCutPct = 5 end
	if AVM_DB.deSafetyMarginPct == nil then AVM_DB.deSafetyMarginPct = 25 end
	if AVM_DB.vendorMeta == nil then AVM_DB.vendorMeta = {} end
	if AVM_DB.diag == nil then AVM_DB.diag = { seq = 0, events = {}, state = {} } end
	if AVM_DB.vendorMeta.sweepPass == nil then AVM_DB.vendorMeta.sweepPass = 0 end
end

local function avm_rule_valid(rule)
	if not rule then return false end
	if rule.enabled == false then return false end
	if not rule.name or avm_trim(rule.name) == "" then return false end
	if (tonumber(rule.maxUnit) or 0) <= 0 then return false end
	return true
end

local function avm_rule_matches(rule, name)
	if not avm_rule_valid(rule) or not name then return false end
	if rule.partial then
		return string.find(string.lower(name), string.lower(rule.name), 1, true) ~= nil
	end
	return string.lower(name) == string.lower(rule.name)
end

local function avm_rule_slots()
	return table.getn(AVM_DB.rules)
end

local function avm_rule_count()
	local n = 0
	for i = 1, avm_rule_slots() do
		if avm_rule_valid(AVM_DB.rules[i]) then n = n + 1 end
	end
	return n
end

local function avm_find_rule(startIndex)
	local slots = avm_rule_slots()
	if slots == 0 then return nil, nil end
	local start = tonumber(startIndex) or 1
	if start < 1 then start = 1 end
	if start > slots then start = 1 end
	for offset = 0, slots - 1 do
		local i = start + offset
		while i > slots do i = i - slots end
		local rule = AVM_DB.rules[i]
		if avm_rule_valid(rule) then return rule, i end
	end
	return nil, nil
end

local function avm_active_rule()
	local rule, index = avm_find_rule(AVM.ruleIndex)
	if rule then AVM.ruleIndex = index end
	return rule, index
end

local function avm_rule_cache_key(rule)
	if not rule then return nil end
	return (rule.partial and "p:" or "e:") .. string.lower(rule.name or "")
end

local function avm_cached_boundary(rule)
	local key = avm_rule_cache_key(rule)
	if not key then return nil end
	local row = AVM.boundaryCache[key]
	if not row then return nil end
	return tonumber(row.page)
end

local function avm_store_boundary(rule, page)
	local key = avm_rule_cache_key(rule)
	if not key then return end
	AVM.boundaryCache[key] = { page = page, savedAt = GetTime() }
end

local function avm_invalidate_boundary(rule)
	local key = avm_rule_cache_key(rule)
	if key then AVM.boundaryCache[key] = nil end
end

local function avm_signature(name, count, buyout, owner, quality, level, itemKey)
	return tostring(name) .. "|" .. tostring(count) .. "|" .. tostring(buyout) .. "|" ..
		tostring(owner) .. "|" .. tostring(quality) .. "|" .. tostring(level) .. "|" ..
		tostring(itemKey or "")
end

local function avm_signature_no_owner(name, count, buyout, quality, level, itemKey)
	return tostring(name) .. "|" .. tostring(count) .. "|" .. tostring(buyout) .. "|" ..
		tostring(quality) .. "|" .. tostring(level) .. "|" .. tostring(itemKey or "")
end

local function avm_recent(sig)
	local untilTime = AVM.recent[sig]
	if not untilTime then return false end
	if GetTime() >= untilTime then
		AVM.recent[sig] = nil
		return false
	end
	return true
end

local function avm_candidate_from_row(i)
	local name,_,count,quality,_,level,_,_,buyout,_,_,owner = GetAuctionItemInfo("list", i)
	if not name or not count or count < 1 or not buyout or buyout <= 0 then return nil end
	if owner == UnitName("player") then return nil end

	local rule, ruleIndex = avm_active_rule()
	if not rule or not avm_rule_matches(rule, name) then return nil end

	local unit = math.floor(buyout / count)
	local minStack = tonumber(rule.minStack) or 1
	local maxStack = tonumber(rule.maxStack) or 0
	local maxUnit = tonumber(rule.maxUnit) or 0
	local maxTotal = tonumber(rule.maxTotal) or 0

	if count < minStack then return nil end
	if maxStack > 0 and count > maxStack then return nil end
	if maxUnit <= 0 or unit > maxUnit then return nil end
	if maxTotal > 0 and buyout > maxTotal then return nil end

	local money = GetMoney()
	local affordable = buyout <= money
	local missing = 0
	if not affordable then missing = buyout - money end

	local itemKey = avm_item_link_key(i)
	local sig = avm_signature(name, count, buyout, owner, quality, level, itemKey)
	if avm_recent(sig) then return nil end

	return {
		name = name,
		count = count,
		quality = quality,
		level = level,
		buyout = buyout,
		unit = unit,
		owner = owner,
		affordable = affordable,
		missing = missing,
		itemKey = itemKey,
		signature = sig,
		ruleIndex = ruleIndex,
		sourcePage = AVM.queryPage,
	}
end

local function avm_send_query(kind, page, name)
	if not AVM.open or AVM.queryInFlight then return false end
	if GetTime() < (AVM.nextQueryAt or 0) then return false end
	if not CanSendAuctionQuery() then return false end

	page = tonumber(page) or 0
	if page < 0 then page = 0 end
	name = name or ""

	AVM.querySeq = AVM.querySeq + 1
	AVM.queryInFlight = true
	AVM.queryKind = kind
	AVM.queryPage = page
	AVM.queryName = name
	AVM.querySentAt = GetTime()
	AVM.stats.queries = AVM.stats.queries + 1
	if string.find(kind, "BOUNDARY", 1, true) then
		AVM.stats.boundaryQueries = AVM.stats.boundaryQueries + 1
	end

	QueryAuctionItems(name, nil, nil, 0, 0, 0, page, false, 0, false)
	return true
end

local function avm_restart_boundary(forceFull)
	AVM.boundaryLow = 0
	AVM.boundaryHigh = 0
	AVM.boundaryPage = nil
	AVM.scanOffset = 0
	AVM.bestCandidate = nil
	AVM.watchPagesScanned = 0
	AVM.candidate = nil
	AVM.revalidatePages = nil
	AVM.revalidatePos = 0
	AVM.cacheBoundary = nil
	AVM.cachePrevOk = false

	local rule = avm_active_rule()
	if not rule then
		AVM.activeRuleName = ""
		AVM.phase = "WAIT_RULE"
		return
	end
	AVM.activeRuleName = rule.name or ""

	if not forceFull then
		local cached = avm_cached_boundary(rule)
		if cached and cached >= 0 then
			AVM.cacheBoundary = cached
			AVM.stats.cacheVerifications = AVM.stats.cacheVerifications + 1
			if cached > 0 then
				AVM.phase = "CACHE_VERIFY_PREV"
			else
				AVM.phase = "CACHE_VERIFY_BOUNDARY"
			end
			avm_print("CACHE verify rule='" .. tostring(AVM.activeRuleName) ..
				"' boundary=" .. tostring(cached))
			return
		end
	end

	AVM.phase = "BOUNDARY_INIT"
end

local function avm_advance_rule()
	local current = AVM.ruleIndex
	local slots = avm_rule_slots()
	if slots == 0 or avm_rule_count() == 0 then
		AVM.ruleIndex = 1
		avm_restart_boundary(true)
		return
	end
	local start = current + 1
	if start > slots then start = 1 end
	local rule, nextIndex = avm_find_rule(start)
	if not rule then
		AVM.ruleIndex = 1
		avm_restart_boundary(true)
		return
	end
	if nextIndex <= current then AVM.watchCycles = AVM.watchCycles + 1 end
	AVM.ruleIndex = nextIndex
	avm_restart_boundary()
end

local function avm_start_scan(boundary)
	local rule = avm_active_rule()
	if rule then avm_store_boundary(rule, boundary) end
	AVM.boundaryPage = boundary
	AVM.cacheBoundary = boundary
	AVM.scanOffset = 0
	AVM.bestCandidate = nil
	AVM.watchPagesScanned = 0
	AVM.phase = "CHEAPEST_SCAN"
	avm_print("WATCH rule='" .. tostring(AVM.activeRuleName) .. "' first buyout page=" ..
		tostring(boundary) .. "; scanning all positive pages for best unit price")
end

local avm_is_auxarb_candidate

local function avm_prepare_revalidate(c)
	local pages = {}
	local seen = {}
	local maxPage = AVM.lastPage or 0
	if c and c.mode == "fastvendor" and AVM.market and (tonumber(AVM.market.lastPage) or 0) > maxPage then
		maxPage = tonumber(AVM.market.lastPage) or maxPage
	elseif avm_is_auxarb_candidate(c) and AVM.auxArb then
		maxPage = tonumber(AVM.auxArb.lastPage) or maxPage
		if maxPage < (tonumber(c.sourcePage) or 0) then maxPage = tonumber(c.sourcePage) or maxPage end
	end
	local function add_page(p)
		if p and p >= 0 and p <= maxPage and not seen[p] then
			seen[p] = true
			table.insert(pages, p)
		end
	end
	add_page(c.sourcePage)
	add_page(c.sourcePage - 1)
	add_page(c.sourcePage + 1)
	AVM.revalidatePages = pages
	AVM.revalidatePos = 1
end

local function avm_page_has_positive()
	local n = GetNumAuctionItems("list")
	for i = 1, n do
		local _,_,_,_,_,_,_,_,buyout = GetAuctionItemInfo("list", i)
		if buyout and buyout > 0 then return true end
	end
	return false
end


local function avm_market_identity(i, name)
	local itemKey = avm_item_link_key(i)
	if itemKey ~= "" then
		local parts = avm_split(itemKey, ":")
		local itemId = tonumber(parts[2])
		local enchantId = tonumber(parts[3]) or 0
		local suffixId = tonumber(parts[4]) or 0
		if itemId then
			return itemId, tostring(itemId) .. ":" .. tostring(enchantId) .. ":" .. tostring(suffixId)
		end
	end
	return nil, "n:" .. string.lower(name or "?")
end

local function avm_market_percentile(prices, fraction)
	local n = table.getn(prices)
	if n == 0 then return 0 end
	local pos = math.ceil(n * fraction)
	if pos < 1 then pos = 1 end
	if pos > n then pos = n end
	return prices[pos] or 0
end

local function avm_market_encode_history(row)
	return table.concat({
		tostring(row.t or 0),
		tostring(row.auctions or 0),
		tostring(row.units or 0),
		tostring(row.min or 0),
		tostring(row.p25 or 0),
		tostring(row.median or 0),
		tostring(row.p75 or 0),
		tostring(row.max or 0),
		tostring(row.avg or 0),
		tostring(row.weighted or 0),
		tostring(row.netDown or row.gone or 0),
	}, ",")
end

local function avm_market_decode_history(value)
	if type(value) == "table" then
		return {
			t = tonumber(value.t) or 0,
			auctions = tonumber(value.auctions) or 0,
			units = tonumber(value.units) or 0,
			min = tonumber(value.min) or 0,
			p25 = tonumber(value.p25) or 0,
			median = tonumber(value.median) or 0,
			p75 = tonumber(value.p75) or 0,
			max = tonumber(value.max) or 0,
			avg = tonumber(value.avg) or 0,
			weighted = tonumber(value.weighted) or 0,
			netDown = tonumber(value.netDown or value.gone) or 0,
		}
	end
	local p = avm_split(tostring(value or ""), ",")
	return {
		t = tonumber(p[1]) or 0,
		auctions = tonumber(p[2]) or 0,
		units = tonumber(p[3]) or 0,
		min = tonumber(p[4]) or 0,
		p25 = tonumber(p[5]) or 0,
		median = tonumber(p[6]) or 0,
		p75 = tonumber(p[7]) or 0,
		max = tonumber(p[8]) or 0,
		avg = tonumber(p[9]) or 0,
		weighted = tonumber(p[10]) or 0,
		netDown = tonumber(p[11]) or 0,
	}
end

local function avm_market_push_history(dbrow, row)
	if not dbrow.history then dbrow.history = {} end
	table.insert(dbrow.history, avm_market_encode_history(row))
	local keep = tonumber(AVM_DB.marketRetention) or 24
	if keep < 1 then keep = 1 end
	while table.getn(dbrow.history) > keep do
		table.remove(dbrow.history, 1)
	end
end

local function avm_market_aggregate_page()
	local n = GetNumAuctionItems("list") or 0
	for i = 1, n do
		local name,_,count,quality,_,level,_,_,buyout = GetAuctionItemInfo("list", i)
		if name and count and count > 0 and buyout and buyout > 0 then
			local itemId, key = avm_market_identity(i, name)
			local unit = math.floor(buyout / count)
			local a = AVM.market.items[key]
			if not a then
				a = {
					name = name,
					itemId = itemId,
					quality = quality,
					level = level,
					auctions = 0,
					units = 0,
					value = 0,
					sumUnit = 0,
					minUnit = nil,
					maxUnit = nil,
					prices = {},
				}
				AVM.market.items[key] = a
			end
			a.auctions = a.auctions + 1
			a.units = a.units + count
			a.value = a.value + buyout
			a.sumUnit = a.sumUnit + unit
			if not a.minUnit or unit < a.minUnit then a.minUnit = unit end
			if not a.maxUnit or unit > a.maxUnit then a.maxUnit = unit end
			table.insert(a.prices, unit)
			AVM.market.auctions = AVM.market.auctions + 1
			AVM.market.units = AVM.market.units + count
		end
	end
	AVM.stats.marketPages = AVM.stats.marketPages + 1
	AVM.stats.marketRows = AVM.stats.marketRows + n
end

local function avm_market_finish(save, reason)
	local m = AVM.market
	if save then
		local stamp = time()
		local seen = {}
		local itemCount = 0
		for key,a in pairs(m.items) do
			table.sort(a.prices)
			local n = table.getn(a.prices)
			local avg = 0
			local weighted = 0
			if a.auctions > 0 then avg = math.floor(a.sumUnit / a.auctions) end
			if a.units > 0 then weighted = math.floor(a.value / a.units) end

			local dbrow = AVM_DB.marketDB[key]
			if not dbrow then
				dbrow = { name = a.name, itemId = a.itemId, history = {} }
				AVM_DB.marketDB[key] = dbrow
			end
			dbrow.name = a.name
			dbrow.itemId = a.itemId
			local prev = nil
			if dbrow.history and table.getn(dbrow.history) > 0 then
				prev = avm_market_decode_history(dbrow.history[table.getn(dbrow.history)])
			end
			local netDown = 0
			if prev and prev.units and prev.units > a.units then netDown = prev.units - a.units end
			avm_market_push_history(dbrow, {
				t = stamp,
				auctions = a.auctions,
				units = a.units,
				min = a.minUnit or 0,
				p25 = avm_market_percentile(a.prices, 0.25),
				median = avm_market_percentile(a.prices, 0.50),
				p75 = avm_market_percentile(a.prices, 0.75),
				max = a.maxUnit or 0,
				avg = avg,
				weighted = weighted,
				netDown = netDown,
			})
			seen[key] = true
			itemCount = itemCount + 1
		end

		-- Record a zero observation only when an item existed in the previous
		-- snapshot and is now absent. netDown is only a net supply-decrease proxy.
		for key,dbrow in pairs(AVM_DB.marketDB) do
			if not seen[key] and dbrow.history and table.getn(dbrow.history) > 0 then
				local prev = avm_market_decode_history(dbrow.history[table.getn(dbrow.history)])
				if prev and prev.auctions and prev.auctions > 0 then
					avm_market_push_history(dbrow, {
						t = stamp, auctions = 0, units = 0,
						min = 0, p25 = 0, median = 0, p75 = 0, max = 0,
						avg = 0, weighted = 0, netDown = prev.units or 0,
					})
				end
			end
		end

		AVM_DB.marketMeta.lastScanAt = stamp
		AVM_DB.marketMeta.retryAfter = 0
		AVM_DB.marketMeta.boundary = m.boundary
		AVM_DB.marketMeta.lastPage = m.lastPage
		AVM_DB.marketMeta.items = itemCount
		AVM_DB.marketMeta.auctions = m.auctions
		AVM_DB.marketMeta.units = m.units
		AVM_DB.marketMeta.duration = GetTime() - m.startedAt
		AVM.stats.marketScans = AVM.stats.marketScans + 1
		avm_print("MARKET done items=" .. itemCount ..
			" auctions=" .. m.auctions .. " units=" .. m.units ..
			" boundary=" .. tostring(m.boundary) ..
			" pages=" .. tostring((m.lastPage or 0) - (m.boundary or 0) + 1) ..
			" duration=" .. string.format("%.1f", AVM_DB.marketMeta.duration) .. "s")
	else
		local retry = tonumber(AVM_DB.marketRetrySeconds) or 300
		if retry < 30 then retry = 30 end
		AVM_DB.marketMeta.retryAfter = time() + retry
		avm_print("MARKET stopped: " .. tostring(reason or "cancelled") ..
			"; auto retry backoff=" .. tostring(retry) .. "s")
	end

	m.active = false
	m.requested = false
	m.stopRequested = false
	m.phase = "IDLE"
	m.items = {}
	m.consecutiveTimeouts = 0
	if AVM_DB.enabled then avm_restart_boundary(false) end
end

local avm_vendor_candidate_from_row

-- Native response-paced full-market scan bridge.
-- F6 is owned by WoWAHThrottleNative V8. The native side keeps exactly one
-- CMSG_AUCTION_LIST_ITEMS request in flight and calls these functions only
-- after the exact 0x025C handler has populated the normal client auction list.
function AVM_FastMarketNativeStart()
	if AUXFAST_IsBusy and AUXFAST_IsBusy() then
		avm_print("FAST MARKET blocked: original Aux scan is active")
		return
	end
	if not AVM.open then
		avm_print("FAST MARKET requires open Auction House")
		return
	end
	if AVM.pending or AVM.unknown or AVM.vendor.active or AVM.vendor.requested then
		avm_print("FAST MARKET blocked by purchase/vendor state")
		return
	end
	if AVM.market.active or AVM.market.requested then
		avm_print("FAST MARKET blocked: MARKET already active")
		return
	end
	if AVM_DB.enabled then
		AVM_DB.enabled = false
		avm_print("scanner OFF - FAST MARKET owns AH scheduler")
	end
	AVM.fastVendorArmed = AVM_DB.fastVendorLive and true or false
	if AVM_DB.live then
		AVM_DB.live = false
		avm_print("LIVE OFF - FAST MARKET owns AH scheduler")
	end
	AVM.queryInFlight = false
	AVM.nextQueryAt = 0
	AVM.market.active = true
	AVM.market.requested = false
	AVM.market.stopRequested = false
	AVM.market.phase = "FAST_NATIVE"
	AVM.market.boundary = 0
	AVM.market.page = 0
	AVM.market.lastPage = 0
	AVM.market.startedAt = GetTime()
	AVM.market.items = {}
	AVM.market.auctions = 0
	AVM.market.units = 0
	AVM.market.consecutiveTimeouts = 0
	AVM.fastMarketNative = true
	AVM.fastMarketPages = 0
	AVM.fastVendorBest = nil
	avm_print("FAST MARKET start: response-paced native scan, one query in flight" ..
		(AVM.fastVendorArmed and " + FAST VENDOR ARMED (max 1 buy after revalidate)" or ""))
	local ok,err = pcall(QueryAuctionItems, "", nil, nil, 0, 0, 0, 0, false, 0, false)
	if not ok then
		AVM.fastMarketNative = false
		AVM.market.active = false
		AVM.market.phase = "IDLE"
		avm_print("FAST MARKET baseline ERROR: " .. tostring(err))
	end
end

function AVM_FastMarketNativePage(page, nativeRows)
	if not AVM.fastMarketNative or not AVM.market.active or AVM.market.phase ~= "FAST_NATIVE" then return end
	page = tonumber(page) or 0
	local rows,total = GetNumAuctionItems("list")
	rows = rows or 0
	total = total or 0
	AVM.queryPage = page
	AVM.total = total
	if total > 0 then AVM.market.lastPage = math.floor((total - 1) / 50) end
	if tonumber(nativeRows) and tonumber(nativeRows) ~= rows then
		avm_print("FAST MARKET row mismatch page=" .. tostring(page) ..
			" native=" .. tostring(nativeRows) .. " lua=" .. tostring(rows))
	end
	avm_market_aggregate_page()
	if avm_vendor_candidate_from_row then
		local i,c
		for i = 1, rows do
			c = avm_vendor_candidate_from_row(i)
			if c then
				c.mode = "fastvendor"
				c.sourcePage = page
				if not AVM.fastVendorBest or c.profit > AVM.fastVendorBest.profit or
				   (c.profit == AVM.fastVendorBest.profit and c.buyout < AVM.fastVendorBest.buyout) then
					AVM.fastVendorBest = c
				end
			end
		end
	end
	AVM.fastMarketPages = AVM.fastMarketPages + 1
	AVM.market.page = page + 1
	if page == 0 or mod(page, 25) == 0 or page >= AVM.market.lastPage then
		local pct = 0
		if AVM.market.lastPage > 0 then pct = math.floor((page + 1) * 100 / (AVM.market.lastPage + 1)) end
		if pct > 100 then pct = 100 end
		avm_print("FAST MARKET page=" .. tostring(page) .. "/" .. tostring(AVM.market.lastPage) ..
			" " .. tostring(pct) .. "% auctions=" .. tostring(AVM.market.auctions))
	end
end

function AVM_FastMarketNativeDone(reason)
	reason = tostring(reason or "UNKNOWN")
	if not AVM.fastMarketNative then
		if reason ~= "COMPLETE" then avm_print("FAST MARKET native: " .. reason) end
		return
	end
	AVM.fastMarketNative = false
	if reason == "COMPLETE" and AVM.fastMarketPages > 0 then
		local best = AVM.fastVendorBest
		local armed = AVM.fastVendorArmed
		AVM.market.boundary = 0
		avm_print("FAST MARKET native complete pages=" .. tostring(AVM.fastMarketPages))
		if best then
			avm_print("FAST VENDOR BEST " .. tostring(best.count) .. "x " .. tostring(best.name) ..
				" buy=" .. avm_money(best.buyout) ..
				" vendor=" .. avm_money(best.vendorTotal or 0) ..
				" profit=" .. avm_money(best.profit or 0) ..
				" page=" .. tostring(best.sourcePage))
		else
			avm_print("FAST VENDOR no qualifying <vendor opportunity in full scan")
		end
		avm_market_finish(true, "fast native complete")
		AVM.fastVendorBest = nil
		AVM.fastVendorArmed = false
		if armed and best then
			best.mode = "fastvendor"
			AVM.candidate = best
			AVM_DB.live = true
			avm_prepare_revalidate(best)
			AVM.phase = "REVALIDATE"
			AVM.nextQueryAt = GetTime() + 0.50
			avm_print("FAST VENDOR LIVE: revalidate exact auction on full-AH page " ..
				tostring(best.sourcePage) .. " before one purchase")
		end
	else
		AVM.fastVendorBest = nil
		AVM.fastVendorArmed = false
		avm_market_finish(false, "FAST MARKET " .. reason)
	end
end

local function avm_market_enter_scan(boundary, lastPage)
	local m = AVM.market
	m.boundary = boundary
	m.page = boundary
	m.lastPage = lastPage
	m.phase = "SCAN"
	AVM_DB.marketMeta.boundary = boundary
	avm_print("MARKET first positive-buyout page=" .. tostring(boundary) ..
		" lastPage=" .. tostring(lastPage) .. "; full buyout scan")
end

local function avm_market_begin()
	local m = AVM.market
	if m.active then return end
	if AVM.pending or AVM.unknown then return end
	m.active = true
	m.requested = false
	m.stopRequested = false
	m.low = 0
	m.high = 0
	m.page = 0
	m.lastPage = 0
	m.startedAt = GetTime()
	m.items = {}
	m.auctions = 0
	m.units = 0
	m.consecutiveTimeouts = 0
	local cached = tonumber(AVM_DB.marketMeta.boundary)
	if cached and cached >= 0 then
		m.boundary = cached
		if cached > 0 then m.phase = "VERIFY_PREV" else m.phase = "VERIFY_BOUNDARY" end
		avm_print("MARKET cache verify boundary=" .. tostring(cached))
	else
		m.boundary = nil
		m.phase = "PROBE"
		avm_print("MARKET start: locating vMaNGOS positive-buyout boundary")
	end
end

local function avm_market_request_start()
	if not AVM.open then
		avm_print("MARKET requires open Auction House")
		return
	end
	if AVM.pending or AVM.unknown then
		avm_print("MARKET waits: purchase transaction is pending/unknown")
		return
	end
	if AVM.vendor.active or AVM.vendor.requested then
		avm_print("MARKET blocked while VENDOR owns/requests the AH scheduler")
		return
	end
	if AVM_DB.live then
		AVM_DB.live = false
		avm_print("LIVE OFF - MARKET scan owns the AH query scheduler")
	end
	AVM.market.requested = true
	avm_print("MARKET scan queued")
end

local function avm_market_accept(kind, page, total, positive)
	local m = AVM.market
	m.consecutiveTimeouts = 0
	local lastPage = 0
	if total and total > 0 then lastPage = math.floor((total - 1) / 50) end
	if lastPage > m.lastPage then m.lastPage = lastPage end

	if m.stopRequested then
		avm_market_finish(false, "manual stop")
		return
	end

	if kind == "MARKET_VERIFY_PREV" then
		if positive then
			AVM_DB.marketMeta.boundary = nil
			m.boundary = nil
			m.phase = "PROBE"
			avm_print("MARKET cache miss: previous page is now positive; full boundary search")
		else
			m.phase = "VERIFY_BOUNDARY"
		end
		return
	end

	if kind == "MARKET_VERIFY_BOUNDARY" then
		if positive then
			avm_print("MARKET cache hit boundary=" .. tostring(m.boundary))
			avm_market_enter_scan(m.boundary or 0, lastPage)
		else
			AVM_DB.marketMeta.boundary = nil
			m.boundary = nil
			m.phase = "PROBE"
			avm_print("MARKET cache miss: cached boundary is no longer positive; full boundary search")
		end
		return
	end

	if kind == "MARKET_PROBE" then
		if not total or total <= 0 then
			avm_market_finish(false, "no auction results")
			return
		end
		if positive then
			avm_market_enter_scan(0, lastPage)
			return
		end
		if lastPage <= 0 then
			AVM_DB.marketMeta.boundary = nil
			avm_market_finish(false, "no positive buyouts")
			return
		end
		m.low = 1
		m.high = lastPage
		m.phase = "SEARCH"
		return
	end

	if kind == "MARKET_SEARCH" then
		if positive then m.high = page else m.low = page + 1 end
		if m.low > m.high then
			AVM_DB.marketMeta.boundary = nil
			avm_market_finish(false, "no positive buyouts")
			return
		end
		if m.low == m.high then
			m.boundary = m.low
			m.phase = "FINAL"
		else
			m.phase = "SEARCH"
		end
		return
	end

	if kind == "MARKET_FINAL" then
		if positive then
			avm_market_enter_scan(page, lastPage)
		else
			AVM_DB.marketMeta.boundary = nil
			avm_market_finish(false, "boundary verification failed")
		end
		return
	end

	if kind == "MARKET_SCAN" then
		avm_market_aggregate_page()
		if page == m.boundary or mod(page - (m.boundary or 0), 25) == 0 or page >= m.lastPage then
			local denom = (m.lastPage or page) - (m.boundary or page) + 1
			local done = page - (m.boundary or page) + 1
			local pct = 100
			if denom > 0 then pct = math.floor(done * 100 / denom) end
			avm_print("MARKET progress page=" .. page .. "/" .. m.lastPage ..
				" " .. pct .. "% auctions=" .. m.auctions)
		end
		m.page = page + 1
		if m.page > m.lastPage then
			avm_market_finish(true, "complete")
		end
		return
	end
end

local function avm_market_tick()
	local m = AVM.market
	if not m.active then return end
	if m.stopRequested and not AVM.queryInFlight then
		avm_market_finish(false, "manual stop")
		return
	end
	if m.phase == "VERIFY_PREV" then
		avm_send_query("MARKET_VERIFY_PREV", (m.boundary or 0) - 1, "")
	elseif m.phase == "VERIFY_BOUNDARY" then
		avm_send_query("MARKET_VERIFY_BOUNDARY", m.boundary or 0, "")
	elseif m.phase == "PROBE" then
		avm_send_query("MARKET_PROBE", 0, "")
	elseif m.phase == "SEARCH" then
		local mid = math.floor((m.low + m.high) / 2)
		avm_send_query("MARKET_SEARCH", mid, "")
	elseif m.phase == "FINAL" then
		avm_send_query("MARKET_FINAL", m.boundary or m.low or 0, "")
	elseif m.phase == "SCAN" then
		avm_send_query("MARKET_SCAN", m.page, "")
	end
end

local function avm_market_auto_due()
	local mins = tonumber(AVM_DB.marketAutoMinutes) or 0
	if mins <= 0 then return false end
	if AVM.market.active or AVM.market.requested or AVM.vendor.active or AVM.vendor.requested or AVM_DB.live or AVM.pending or AVM.unknown then return false end
	local now = time()
	local retryAfter = tonumber(AVM_DB.marketMeta.retryAfter) or 0
	if retryAfter > now then return false end
	local last = tonumber(AVM_DB.marketMeta.lastScanAt) or 0
	return last == 0 or (now - last) >= mins * 60
end

local function avm_market_show_status()
	local m = AVM.market
	local meta = AVM_DB.marketMeta or {}
	avm_print("MARKET active=" .. tostring(m.active) ..
		" requested=" .. tostring(m.requested) ..
		" phase=" .. tostring(m.phase) ..
		" page=" .. tostring(m.page) .. "/" .. tostring(m.lastPage) ..
		" boundary=" .. tostring(m.boundary) ..
		" auto=" .. tostring(AVM_DB.marketAutoMinutes or 0) .. "m" ..
		" fastNative=" .. tostring(AVM.fastMarketNative))
	avm_print("MARKET DB items=" .. tostring(meta.items or 0) ..
		" auctions=" .. tostring(meta.auctions or 0) ..
		" units=" .. tostring(meta.units or 0) ..
		" retention=" .. tostring(AVM_DB.marketRetention or 24) ..
		" lastScan=" .. tostring(meta.lastScanAt or 0) ..
		" retryAfter=" .. tostring(meta.retryAfter or 0))
end

local function avm_market_show_item(name)
	name = string.lower(avm_trim(name or ""))
	if name == "" then
		avm_print("usage: /avm market item Black Lotus")
		return
	end
	local found = nil
	for _,row in pairs(AVM_DB.marketDB) do
		if row.name and string.lower(row.name) == name then found = row break end
	end
	if not found then
		for _,row in pairs(AVM_DB.marketDB) do
			if row.name and string.find(string.lower(row.name), name, 1, true) then found = row break end
		end
	end
	if not found or not found.history or table.getn(found.history) == 0 then
		avm_print("MARKET no PriceDB history for '" .. name .. "'")
		return
	end
	local n = table.getn(found.history)
	local row = avm_market_decode_history(found.history[n])
	avm_print("MARKET " .. tostring(found.name) .. " snapshots=" .. n ..
		" auctions=" .. tostring(row.auctions or 0) ..
		" units=" .. tostring(row.units or 0) ..
		" min=" .. avm_money(row.min or 0) ..
		" median=" .. avm_money(row.median or 0) ..
		" p25/p75=" .. avm_money(row.p25 or 0) .. "/" .. avm_money(row.p75 or 0))
	avm_print("MARKET avg=" .. avm_money(row.avg or 0) ..
		" weighted=" .. avm_money(row.weighted or 0) ..
		" netDownUnits=" .. tostring(row.netDown or 0) ..
		" (net supply decrease; not proven sales)")
	local first = n - 3
	if first < 1 then first = 1 end
	for i = first, n - 1 do
		local h = avm_market_decode_history(found.history[i])
		avm_print("  prev t=" .. tostring(h.t or 0) ..
			" median=" .. avm_money(h.median or 0) ..
			" units=" .. tostring(h.units or 0) ..
			" netDown=" .. tostring(h.netDown or 0))
	end
end

local avm_revalidate_candidate

local function avm_market_slash(rest)
	rest = avm_trim(rest or "")
	local _,_,sub,arg = string.find(rest, "^(%S+)%s*(.*)$")
	sub = string.lower(sub or "status")
	arg = arg or ""
	if sub == "start" then
		avm_market_request_start()
	elseif sub == "fast" then
		avm_print("FAST MARKET: open AH, wait for active Search, then press F2 once.")
	elseif sub == "stop" then
		AVM.market.requested = false
		if AVM.market.active then
			AVM.market.stopRequested = true
			avm_print("MARKET stop requested")
		else
			avm_print("MARKET not running")
		end
	elseif sub == "status" then
		avm_market_show_status()
	elseif sub == "item" or sub == "price" then
		avm_market_show_item(arg)
	elseif sub == "auto" then
		local n = tonumber(avm_trim(arg))
		if n and n >= 0 and n <= 1440 then
			AVM_DB.marketAutoMinutes = n
			avm_print("MARKET auto interval=" .. n .. " minutes (0=off)")
		else
			avm_print("market auto must be 0..1440 minutes")
		end
	elseif sub == "retention" then
		local n = tonumber(avm_trim(arg))
		if n and n >= 1 and n <= 96 then
			AVM_DB.marketRetention = n
			avm_print("MARKET history retention=" .. n .. " snapshots/item")
		else
			avm_print("market retention must be 1..96")
		end
	elseif sub == "clear" then
		if AVM.market.active then
			avm_print("MARKET cannot clear DB while scan is running")
		else
			AVM_DB.marketDB = {}
			AVM_DB.marketMeta = {}
			avm_print("MARKET PriceDB cleared")
		end
	else
		avm_print("/avm market start|stop|status|item NAME|auto MIN|retention N|clear")
	end
end


local function avm_vendor_item_id(i)
	local key = avm_item_link_key(i)
	if key == "" then return nil end
	local _,_,id = string.find(key, "^item:(%d+)")
	return tonumber(id)
end

avm_vendor_candidate_from_row = function(i)
	local name,_,count,quality,_,level,_,_,buyout,_,_,owner = GetAuctionItemInfo("list", i)
	if not name or not count or count <= 0 or not buyout or buyout <= 0 then return nil end
	if quality == 0 then return nil end

	local itemId = avm_vendor_item_id(i)
	if not itemId then return nil end
	local vendorSource = "static"
	local vendorUnit = 0
	if aux and aux.account_data and aux.account_data.merchant_sell then
		vendorUnit = tonumber(aux.account_data.merchant_sell[itemId]) or 0
		if vendorUnit > 0 then vendorSource = "aux-learned" end
	end
	if vendorUnit <= 0 and AVM_VENDOR_VALUES then
		vendorUnit = tonumber(AVM_VENDOR_VALUES[itemId]) or 0
	end
	if vendorUnit <= 0 then return nil end

	local vendorTotal = vendorUnit * count
	local profit = vendorTotal - buyout
	local minProfit = tonumber(AVM_DB.vendorMinProfit) or 0
	local maxBuyout = tonumber(AVM_DB.vendorMaxBuyout) or 0
	if profit < minProfit then return nil end
	if maxBuyout > 0 and buyout > maxBuyout then return nil end

	local itemKey = avm_item_link_key(i)
	local sig = avm_signature(name, count, buyout, owner, quality, level, itemKey)
	if avm_recent(sig) then return nil end

	local money = GetMoney()
	local missing = buyout - money
	if missing < 0 then missing = 0 end
	return {
		mode = "vendor",
		name = name,
		itemId = itemId,
		count = count,
		buyout = buyout,
		unit = math.floor(buyout / count),
		vendorUnit = vendorUnit,
		vendorSource = vendorSource,
		vendorTotal = vendorTotal,
		profit = profit,
		owner = owner,
		quality = quality,
		level = level,
		itemKey = itemKey,
		signature = sig,
		sourcePage = AVM.queryPage,
		affordable = buyout <= money,
		missing = missing,
	}
end

avm_is_auxarb_candidate = function(c)
	return c and (c.mode == "auxarb_vendor" or c.mode == "auxarb_de")
end

local function avm_auxarb_candidate_better(a, b)
	if not b then return true end
	if (a.profit or 0) ~= (b.profit or 0) then return (a.profit or 0) > (b.profit or 0) end
	return (a.buyout or 0) < (b.buyout or 0)
end

local function avm_de_book_add(book, itemId, name, count, buyout)
	itemId = tonumber(itemId)
	count = tonumber(count) or 0
	buyout = tonumber(buyout) or 0
	if not itemId or not AVM_DE_MATERIAL_IDS[itemId] or count <= 0 or buyout <= 0 then return end
	local row = book[itemId]
	if not row then
		row = { name = name or "", units = 0, offers = {}, depthCache = {} }
		book[itemId] = row
	elseif (row.name or "") == "" and name then
		row.name = name
	end
	local unit = math.floor(buyout / count)
	if unit <= 0 then return end
	table.insert(row.offers, { unit = unit, count = count })
	row.units = (row.units or 0) + count
	row.depthCache = {}
end

local function avm_de_depth_price(book, itemId, depth)
	local row = book and book[tonumber(itemId)]
	depth = tonumber(depth) or 3
	if depth < 1 then depth = 1 end
	if not row or (row.units or 0) < depth then return nil end
	if row.depthCache and row.depthCache[depth] then return row.depthCache[depth], row end
	table.sort(row.offers, function(a,b)
		if a.unit ~= b.unit then return a.unit < b.unit end
		return a.count > b.count
	end)
	local units = 0
	for i = 1, table.getn(row.offers) do
		units = units + (tonumber(row.offers[i].count) or 0)
		if units >= depth then
			row.depthCache[depth] = row.offers[i].unit
			return row.offers[i].unit, row
		end
	end
	return nil
end

local function avm_de_record_key(record, itemId)
	local itemKey = record and record.itemKey or ""
	if (not itemKey or itemKey == "") and record and record.index then itemKey = avm_item_link_key(record.index) end
	if not itemKey or itemKey == "" then itemKey = "item:" .. tostring(itemId or 0) end
	return itemKey
end

local function avm_de_raw_candidate(record)
	if not AVM_DB.auxArbEnabled or not record then return nil end
	if not AVM_AUX_DE_OK or not AVM_AUX_DE then return nil end
	if record.quality ~= 2 and record.quality ~= 3 and record.quality ~= 4 then return nil end
	if not record.slot then return nil end
	local buyout = tonumber(record.buyout_price) or 0
	local count = tonumber(record.count or record.aux_quantity) or 0
	local itemId = tonumber(record.item_id)
	if buyout <= 0 or count <= 0 or not itemId then return nil end
	local maxBuyout = tonumber(AVM_DB.deMaxBuyout) or 0
	if maxBuyout > 0 and buyout > maxBuyout then return nil end
	local itemKey = avm_de_record_key(record, itemId)
	local sig = avm_signature_no_owner(record.name, count, buyout, record.quality, record.level, itemKey)
	if avm_recent(sig) then return nil end
	return {
		name = record.name, item_id = itemId, itemId = itemId,
		count = count, aux_quantity = count, buyout_price = buyout, buyout = buyout,
		quality = record.quality, level = record.level, slot = record.slot,
		owner = record.owner, itemKey = itemKey, signature = sig,
		page = tonumber(record.page) or AVM.queryPage or 0,
		sourcePage = tonumber(record.page) or AVM.queryPage or 0,
	}
end

local function avm_de_candidate_from_record(record, book)
	if not record or not AVM_AUX_DE_OK or not AVM_AUX_DE then return nil, "no-de-module" end
	local raw = avm_de_raw_candidate(record)
	if not raw then
		-- Revalidation candidates already carry normalized fields rather than buyout_price.
		local buyout = tonumber(record.buyout or record.buyout_price) or 0
		local count = tonumber(record.count or record.aux_quantity) or 0
		local itemId = tonumber(record.itemId or record.item_id)
		if (record.quality ~= 2 and record.quality ~= 3 and record.quality ~= 4) or
		   not record.slot or buyout <= 0 or count <= 0 or not itemId then return nil, "not-de-item" end
		raw = {
			name=record.name,item_id=itemId,itemId=itemId,count=count,aux_quantity=count,
			buyout_price=buyout,buyout=buyout,quality=record.quality,level=record.level,
			slot=record.slot,owner=record.owner,itemKey=avm_de_record_key(record,itemId),
			signature=record.signature,page=record.sourcePage or record.page or 0,
			sourcePage=record.sourcePage or record.page or 0,
		}
	end

	local ok, dist = pcall(AVM_AUX_DE.distribution, raw.slot, raw.quality, raw.level or 0, raw.itemId)
	if not ok or not dist or table.getn(dist) == 0 then return nil, "no-distribution" end

	local depth = tonumber(AVM_DB.deDepthUnits) or 3
	local cutPct = tonumber(AVM_DB.deAhCutPct) or 5
	local marginPct = tonumber(AVM_DB.deSafetyMarginPct) or 25
	if depth < 1 then depth = 1 end
	if cutPct < 0 then cutPct = 0 elseif cutPct > 30 then cutPct = 30 end
	if marginPct < 0 then marginPct = 0 elseif marginPct > 90 then marginPct = 90 end

	local grossExpected, netExpected = 0, 0
	local mats, seen = {}, {}
	for i = 1, table.getn(dist) do
		local event = dist[i]
		local matId = tonumber(event.item_id)
		local floorPrice, row = avm_de_depth_price(book, matId, depth)
		if not floorPrice or not row or not row.name or row.name == "" then
			return nil, "no-depth:" .. tostring(matId)
		end
		local p = tonumber(event.probability) or 0
		local avgQty = ((tonumber(event.min_quantity) or 0) + (tonumber(event.max_quantity) or 0)) / 2
		local netUnit = math.floor(floorPrice * (100 - cutPct) / 100)
		grossExpected = grossExpected + p * avgQty * floorPrice
		netExpected = netExpected + p * avgQty * netUnit
		if not seen[matId] then
			seen[matId] = true
			table.insert(mats, {
				itemId = matId, name = row.name, floor = floorPrice, net = netUnit,
				probability = p, avgQty = avgQty,
			})
		end
	end

	local grossTotal = math.floor(grossExpected * raw.count)
	local netTotal = math.floor(netExpected * raw.count)
	local profit = netTotal - raw.buyout
	local minProfit = tonumber(AVM_DB.deMinProfit) or 0
	local maxBuyout = tonumber(AVM_DB.deMaxBuyout) or 0
	local maxEntry = math.floor(netTotal * (100 - marginPct) / 100)
	if maxBuyout > 0 and raw.buyout > maxBuyout then return nil, "max-buyout" end
	if profit < minProfit then return nil, "min-profit" end
	if raw.buyout > maxEntry then return nil, "safety-margin" end

	local money = GetMoney()
	local missing = raw.buyout - money
	if missing < 0 then missing = 0 end
	return {
		mode = "auxarb_de", route = "disenchant", name = raw.name,
		itemId = raw.itemId, count = raw.count, buyout = raw.buyout,
		unit = math.floor(raw.buyout / raw.count), deGross = grossTotal, deValue = netTotal,
		valuationTotal = netTotal, profit = profit, owner = raw.owner,
		quality = raw.quality, level = raw.level, slot = raw.slot, itemKey = raw.itemKey,
		signature = raw.signature or avm_signature_no_owner(raw.name, raw.count, raw.buyout, raw.quality, raw.level, raw.itemKey),
		ignoreOwnerSignature = true, sourcePage = raw.sourcePage or 0,
		affordable = raw.buyout <= money, missing = missing,
		deDepthUnits = depth, deCutPct = cutPct, deMarginPct = marginPct,
		deMaxEntry = maxEntry, materials = mats,
	}, nil
end

local function avm_auxarb_candidate_from_record(record, requiredMode)
	if not AVM_DB.auxArbEnabled or not record then return nil end
	local buyout = tonumber(record.buyout_price) or 0
	local count = tonumber(record.count or record.aux_quantity) or 0
	if buyout <= 0 or count <= 0 then return nil end
	if record.owner and record.owner == UnitName("player") then return nil end

	local itemId = tonumber(record.item_id)
	if not itemId then return nil end
	local itemKey = avm_de_record_key(record, itemId)
	local sig = avm_signature_no_owner(record.name, count, buyout, record.quality, record.level, itemKey)
	if avm_recent(sig) then return nil end

	local money = GetMoney()
	local missing = buyout - money
	if missing < 0 then missing = 0 end
	if requiredMode == "auxarb_de" then return nil end

	if (not requiredMode or requiredMode == "auxarb_vendor") and record.quality ~= 0 then
		local vendorSource = "static"
		local vendorUnit = 0
		if aux and aux.account_data and aux.account_data.merchant_sell then
			vendorUnit = tonumber(aux.account_data.merchant_sell[itemId]) or 0
			if vendorUnit > 0 then vendorSource = "aux-learned" end
		end
		if vendorUnit <= 0 and AVM_VENDOR_VALUES then vendorUnit = tonumber(AVM_VENDOR_VALUES[itemId]) or 0 end
		if vendorUnit > 0 then
			local total = vendorUnit * count
			local profit = total - buyout
			local minProfit = tonumber(AVM_DB.vendorMinProfit) or 0
			local maxBuyout = tonumber(AVM_DB.vendorMaxBuyout) or 0
			if profit >= minProfit and (maxBuyout <= 0 or buyout <= maxBuyout) then
				return {
					mode = "auxarb_vendor", route = "vendor", name = record.name,
					itemId = itemId, count = count, buyout = buyout,
					unit = math.floor(buyout / count), vendorUnit = vendorUnit,
					vendorSource = vendorSource, vendorTotal = total,
					valuationTotal = total, profit = profit, owner = record.owner,
					quality = record.quality, level = record.level, itemKey = itemKey,
					signature = sig, ignoreOwnerSignature = true,
					sourcePage = tonumber(record.page) or AVM.queryPage or 0,
					affordable = buyout <= money, missing = missing,
				}
			end
		end
	end
	return nil
end

local function avm_de_fail_postscan(candidate, reason)
	local a = AVM.auxArb
	if candidate and candidate.signature then AVM.recent[candidate.signature] = GetTime() + 2 end
	a.deVerify = nil
	a.candidate = nil
	AVM.candidate = nil
	AVM.revalidatePages = nil
	AVM.revalidatePos = 0
	AVM.phase = "IDLE"
	avm_print("AUX_ARB_DE_REJECT " .. tostring(candidate and candidate.name or "?") ..
		" reason=" .. tostring(reason or "unknown"))
end

local function avm_de_begin_live_verify(candidate)
	local a = AVM.auxArb
	if not candidate or not candidate.materials or table.getn(candidate.materials) == 0 then
		avm_de_fail_postscan(candidate, "no-materials")
		return false
	end
	a.deVerify = {
		candidate = candidate, materials = candidate.materials,
		index = 1, page = 0, lastPage = 0, book = {},
	}
	AVM.candidate = candidate
	AVM.phase = "DE_MAT_REVALIDATE"
	AVM.nextQueryAt = GetTime() + 0.05
	avm_print("AUX_ARB_DE_VERIFY start " .. tostring(candidate.name) ..
		" mats=" .. tostring(table.getn(candidate.materials)) ..
		" depth=" .. tostring(AVM_DB.deDepthUnits or 3) ..
		" cut=" .. tostring(AVM_DB.deAhCutPct or 5) .. "%" ..
		" margin=" .. tostring(AVM_DB.deSafetyMarginPct or 25) .. "%")
	return true
end

local function avm_de_live_verify_accept(page, total)
	local a = AVM.auxArb
	local v = a.deVerify
	if not v or not v.candidate then return end
	local mat = v.materials[v.index]
	if not mat then
		avm_de_fail_postscan(v.candidate, "verify-state")
		return
	end

	local n = GetNumAuctionItems("list") or 0
	for i = 1, n do
		local name,_,count,_,_,_,_,_,buyout = GetAuctionItemInfo("list", i)
		if name and count and count > 0 and buyout and buyout > 0 then
			local itemId = avm_vendor_item_id(i)
			if itemId == mat.itemId then avm_de_book_add(v.book, itemId, name, count, buyout) end
		end
	end

	local lastPage = 0
	if total and total > 0 then lastPage = math.floor((total - 1) / 50) end
	v.lastPage = lastPage
	if page < lastPage then
		v.page = page + 1
		return
	end

	local floorPrice = avm_de_depth_price(v.book, mat.itemId, tonumber(AVM_DB.deDepthUnits) or 3)
	if not floorPrice then
		avm_de_fail_postscan(v.candidate, "material-depth:" .. tostring(mat.name))
		return
	end
	avm_print("AUX_ARB_DE_MAT " .. tostring(mat.name) ..
		" depthFloor=" .. avm_money(floorPrice) ..
		" units>=" .. tostring(AVM_DB.deDepthUnits or 3))

	v.index = v.index + 1
	v.page = 0
	v.lastPage = 0
	if v.index <= table.getn(v.materials) then return end

	local fresh, reason = avm_de_candidate_from_record(v.candidate, v.book)
	if not fresh then
		avm_de_fail_postscan(v.candidate, "live-" .. tostring(reason or "valuation"))
		return
	end
	fresh.scanComplete = true
	fresh.deVerifiedBook = v.book
	a.deVerify = nil
	a.candidate = fresh
	AVM.candidate = fresh
	avm_prepare_revalidate(fresh)
	AVM.phase = "REVALIDATE"
	AVM.nextQueryAt = GetTime() + 0.05
	avm_print("AUX_ARB_DE_LIVE_OK " .. tostring(fresh.name) ..
		" buy=" .. avm_money(fresh.buyout) ..
		" netEV=" .. avm_money(fresh.deValue) ..
		" maxEntry=" .. avm_money(fresh.deMaxEntry) ..
		" profit=" .. avm_money(fresh.profit))
end

local function avm_auxarb_resume_search(reason)
	local a = AVM.auxArb
	a.active = false
	a.paused = false
	a.pausePending = false
	a.resumePending = false
	a.pageBest = nil
	a.bestSeen = nil
	a.candidate = nil
	AVM.candidate = nil
	AVM.revalidatePages = nil
	AVM.revalidatePos = 0
	AVM.phase = "IDLE"
	AVM.queryInFlight = false
	AVM.nextQueryAt = GetTime() + 0.05
	if AUXFAST_ResumeSearch then
		local ok, resumed = pcall(AUXFAST_ResumeSearch)
		if ok and resumed then
			AVM.stats.auxArbResumes = AVM.stats.auxArbResumes + 1
			avm_print("AUX_ARB_RESUME " .. tostring(reason or "continue"))
		else
			avm_print("AUX_ARB_RESUME_FAILED " .. tostring(reason or "continue"))
		end
	else
		avm_print("AUX_ARB_RESUME_FAILED bridge unavailable")
	end
end

function AVM_AuxArbScanStart(resume)
	local a = AVM.auxArb
	local keepScanBook = resume and a.deRawCandidates and a.deMaterialBook
	a.active = AVM_DB.auxArbEnabled and true or false
	a.paused = false
	a.pausePending = false
	a.resumePending = false
	a.pageBest = nil
	a.candidate = nil
	a.deVerify = nil
	if not keepScanBook then
		a.bestSeen = nil
		a.pages = 0
		a.lastPage = 0
		a.vendorCandidates = 0
		a.deCandidates = 0
		a.deNoValue = 0
		a.deRawCandidates = {}
		a.deMaterialBook = {}
		a.deBest = nil
	end
	if a.active then
		avm_print((keepScanBook and "AUX_ARB_SCAN resume" or "AUX_ARB_SCAN start") ..
			" live=" .. tostring(AVM_DB.auxArbLive) ..
			" vendorMin=" .. avm_money(AVM_DB.vendorMinProfit or 0) ..
			" DE min=" .. avm_money(AVM_DB.deMinProfit or 0) ..
			" depth=" .. tostring(AVM_DB.deDepthUnits or 3) ..
			" cut=" .. tostring(AVM_DB.deAhCutPct or 5) .. "%" ..
			" margin=" .. tostring(AVM_DB.deSafetyMarginPct or 25) .. "%" ..
			" rawDE=" .. tostring(table.getn(a.deRawCandidates or {})))
	end
end

function AVM_AuxArbAuction(record)
	local a = AVM.auxArb
	if not a.active or a.paused or a.pausePending then return end
	if not record or not record.blizzard_query then return end
	if (record.blizzard_query.name or "") ~= "" then return end

	avm_de_book_add(a.deMaterialBook, record.item_id, record.name,
		record.count or record.aux_quantity, record.buyout_price)
	local rawDe = avm_de_raw_candidate(record)
	if rawDe then table.insert(a.deRawCandidates, rawDe) end

	local c = avm_auxarb_candidate_from_record(record, "auxarb_vendor")
	if not c then return end
	AVM.stats.auxArbCandidates = AVM.stats.auxArbCandidates + 1
	a.vendorCandidates = a.vendorCandidates + 1
	AVM.stats.auxArbVendorCandidates = AVM.stats.auxArbVendorCandidates + 1
	if avm_auxarb_candidate_better(c, a.pageBest) then a.pageBest = c end
	if avm_auxarb_candidate_better(c, a.bestSeen) then a.bestSeen = c end
end

function AVM_AuxArbPageDone(page, lastPage)
	local a = AVM.auxArb
	if not a.active or a.paused then return false end
	a.pages = a.pages + 1
	a.lastPage = tonumber(lastPage) or a.lastPage or 0
	AVM.stats.auxArbPages = AVM.stats.auxArbPages + 1
	local c = a.pageBest
	a.pageBest = nil
	if not c then return false end

	avm_print("AUX_ARB_PAGE page=" .. tostring(page) ..
		" route=vendor " .. tostring(c.name) ..
		" buy=" .. avm_money(c.buyout) ..
		" value=" .. avm_money(c.valuationTotal or 0) ..
		" profit=" .. avm_money(c.profit or 0))

	if not AVM_DB.auxArbLive then return false end
	if AVM.pending or AVM.unknown or AVM.queryInFlight then return false end
	local maxBuys = tonumber(AVM_DB.maxSessionBuys) or 1
	if maxBuys > 0 and AVM.sessionBuys >= maxBuys then
		AVM_DB.auxArbLive = false
		avm_print("AUX_ARB LIVE OFF purchase limit reached (" .. tostring(AVM.sessionBuys) .. "/" .. tostring(maxBuys) .. ")")
		return false
	end
	local maxSpend = tonumber(AVM_DB.maxSessionSpend) or 0
	if not c.affordable or (maxSpend > 0 and AVM.sessionSpend + c.buyout > maxSpend) then return false end
	a.pausePending = true
	a.resumePending = true
	a.candidate = c
	AVM.stats.auxArbPauses = AVM.stats.auxArbPauses + 1
	avm_print("AUX_ARB_CANDIDATE route=vendor page=" .. tostring(c.sourcePage) ..
		" profit=" .. avm_money(c.profit or 0) .. " -> pause/revalidate")
	return true
end

function AVM_AuxArbPaused(page)
	local a = AVM.auxArb
	if not a.pausePending or not a.candidate then return end
	a.active = false
	a.paused = true
	a.pausePending = false
	AVM.candidate = a.candidate
	AVM.lastPage = a.lastPage or math.max(tonumber(page) or 0, AVM.candidate.sourcePage or 0)
	avm_prepare_revalidate(AVM.candidate)
	AVM.phase = "REVALIDATE"
	AVM.nextQueryAt = GetTime() + 0.05
	avm_print("AUX_ARB_PAUSED page=" .. tostring(page) ..
		" revalidatePage=" .. tostring(AVM.candidate.sourcePage))
end

function AVM_AuxArbScanDone()
	local a = AVM.auxArb
	if not a.active then return end
	a.active = false

	local bestDe = nil
	for i = 1, table.getn(a.deRawCandidates or {}) do
		local de, reason = avm_de_candidate_from_record(a.deRawCandidates[i], a.deMaterialBook)
		if de then
			a.deCandidates = a.deCandidates + 1
			AVM.stats.auxArbCandidates = AVM.stats.auxArbCandidates + 1
			AVM.stats.auxArbDeCandidates = AVM.stats.auxArbDeCandidates + 1
			if avm_auxarb_candidate_better(de, bestDe) then bestDe = de end
		elseif reason and string.find(reason, "no-depth:", 1, true) == 1 then
			a.deNoValue = a.deNoValue + 1
		end
	end
	a.deBest = bestDe
	if bestDe and avm_auxarb_candidate_better(bestDe, a.bestSeen) then a.bestSeen = bestDe end

	local best = a.bestSeen
	if best then
		avm_print("AUX_ARB_SCAN_DONE pages=" .. tostring(a.pages) ..
			" best=" .. tostring(best.route) .. ":" .. tostring(best.name) ..
			" buy=" .. avm_money(best.buyout) ..
			" value=" .. avm_money(best.valuationTotal or 0) ..
			" profit=" .. avm_money(best.profit or 0) ..
			" vendorCandidates=" .. tostring(a.vendorCandidates) ..
			" deCandidates=" .. tostring(a.deCandidates) ..
			" deNoDepth=" .. tostring(a.deNoValue or 0))
	else
		avm_print("AUX_ARB_SCAN_DONE pages=" .. tostring(a.pages) ..
			" no qualifying candidate deNoDepth=" .. tostring(a.deNoValue or 0))
	end

	if not AVM_DB.auxArbLive or not bestDe then return end
	if AVM.pending or AVM.unknown or AVM.queryInFlight then return end
	local maxBuys = tonumber(AVM_DB.maxSessionBuys) or 1
	if maxBuys > 0 and AVM.sessionBuys >= maxBuys then
		AVM_DB.auxArbLive = false
		return
	end
	local maxSpend = tonumber(AVM_DB.maxSessionSpend) or 0
	if not bestDe.affordable or (maxSpend > 0 and AVM.sessionSpend + bestDe.buyout > maxSpend) then return end
	bestDe.scanComplete = true
	a.candidate = bestDe
	avm_de_begin_live_verify(bestDe)
end

local function avm_vendor_pick_page_best()
	local n = GetNumAuctionItems("list") or 0
	local best = nil
	local maxSpend = tonumber(AVM_DB.maxSessionSpend) or 0
	for i = 1, n do
		local c = avm_vendor_candidate_from_row(i)
		if c then
			local eligible = true
			if AVM_DB.live then
				if not c.affordable then eligible = false end
				if maxSpend > 0 and AVM.sessionSpend + c.buyout > maxSpend then eligible = false end
			end
			if eligible and (not best or c.profit > best.profit or
				(c.profit == best.profit and c.buyout < best.buyout)) then
				c.index = i
				best = c
			end
		end
	end
	return best
end

local avm_vendor_restart_cycle
local avm_vendor_start_seek

local function avm_vendor_hot_pages()
	local n = tonumber(AVM_DB.vendorHotPages) or tonumber(AVM_DB.vendorMaxPages) or 10
	if n < 1 then n = 1 end
	if n > 100 then n = 100 end
	return math.floor(n)
end

local function avm_vendor_seek_radius()
	local n = tonumber(AVM_DB.vendorSeekRadius) or 1
	if n < 0 then n = 0 end
	if n > 5 then n = 5 end
	return math.floor(n)
end

local function avm_vendor_page_min_positive_buyout()
	local n = GetNumAuctionItems("list") or 0
	local best = nil
	for i = 1, n do
		local _,_,_,_,_,_,_,_,buyout = GetAuctionItemInfo("list", i)
		if buyout and buyout > 0 and (not best or buyout < best) then best = buyout end
	end
	return best
end

local function avm_vendor_page_max_positive_buyout()
	local n = GetNumAuctionItems("list") or 0
	local best = nil
	for i = 1, n do
		local _,_,_,_,_,_,_,_,buyout = GetAuctionItemInfo("list", i)
		if buyout and buyout > 0 and (not best or buyout > best) then best = buyout end
	end
	return best
end

local function avm_vendor_build_seek_targets()
	local ladder = { 500, 1000, 2500, 5000, 10000, 20000, 50000, 100000 }
	local out = {}
	local maxBuyout = tonumber(AVM_DB.vendorMaxBuyout) or 0
	for i = 1, table.getn(ladder) do
		local value = ladder[i]
		if maxBuyout <= 0 or value <= maxBuyout then table.insert(out, value) end
	end
	if maxBuyout > 0 and (table.getn(out) == 0 or out[table.getn(out)] ~= maxBuyout) then
		table.insert(out, maxBuyout)
	end
	return out
end

local function avm_vendor_start_hot()
	local v = AVM.vendor
	if not v.active or v.boundary == nil then return false end
	local startPage = v.boundary
	local endPage = startPage + avm_vendor_hot_pages() - 1
	if endPage > v.lastPage then endPage = v.lastPage end
	v.segment = "HOT"
	v.segmentStart = startPage
	v.segmentEnd = endPage
	v.page = startPage
	v.pagesScanned = 0
	v.best = nil
	v.priceCeiling = false
	v.phase = "SCAN"
	avm_print("VENDOR HOT pages=" .. tostring(startPage) .. "-" .. tostring(endPage))
	return true
end

local function avm_vendor_start_seek_scan(locatedPage)
	local v = AVM.vendor
	local radius = avm_vendor_seek_radius()
	local hotEnd = v.boundary + avm_vendor_hot_pages() - 1
	if locatedPage <= hotEnd then
		avm_print("VENDOR SEEK target=" .. avm_money(v.seekTarget or 0) ..
			" covered-by-HOT page=" .. tostring(locatedPage))
		return avm_vendor_start_seek((v.seekIndex or 0) + 1)
	end
	local startPage = locatedPage - radius
	local endPage = locatedPage + radius
	if startPage <= hotEnd then startPage = hotEnd + 1 end
	if startPage < v.boundary then startPage = v.boundary end
	if endPage > v.lastPage then endPage = v.lastPage end
	v.segment = "SEEK"
	v.segmentStart = startPage
	v.segmentEnd = endPage
	v.page = startPage
	v.pagesScanned = 0
	v.best = nil
	v.seekLocatedPage = locatedPage
	v.priceCeiling = false
	v.phase = "SCAN"
	avm_print("VENDOR SEEK_SCAN target=" .. avm_money(v.seekTarget or 0) ..
		" locatedPage=" .. tostring(locatedPage) ..
		" pages=" .. tostring(startPage) .. "-" .. tostring(endPage))
	return true
end

avm_vendor_start_seek = function(index)
	local v = AVM.vendor
	if not v.active or v.boundary == nil then return false end
	local targets = avm_vendor_build_seek_targets()
	v.seekTargets = targets
	index = tonumber(index) or 1
	if index < 1 then index = 1 end
	local target = targets[index]
	if not target then
		v.resumeSegment = "HOT"
		avm_print("VENDOR SEEK cycle complete targets=" .. tostring(table.getn(targets)))
		avm_vendor_restart_cycle()
		return false
	end
	v.segment = "SEEK"
	v.seekIndex = index
	v.seekTarget = target
	v.seekLow = v.boundary
	v.seekHigh = v.lastPage
	v.seekLocatedPage = 0
	v.pagesScanned = 0
	v.best = nil
	v.priceCeiling = false
	v.phase = "SEEK_SEARCH"
	AVM.stats.vendorSeekTargets = AVM.stats.vendorSeekTargets + 1
	avm_print("VENDOR SEEK target=" .. avm_money(target) ..
		" index=" .. tostring(index) .. "/" .. tostring(table.getn(targets)) ..
		" pageRange=" .. tostring(v.seekLow) .. "-" .. tostring(v.seekHigh))
	return true
end

local function avm_vendor_continue_after_segment()
	local v = AVM.vendor
	if v.segment == "HOT" then
		if avm_vendor_start_seek(1) then return end
	elseif v.segment == "SEEK" then
		if avm_vendor_start_seek((v.seekIndex or 0) + 1) then return end
	end
	v.resumeSegment = "HOT"
	avm_vendor_restart_cycle()
end

local function avm_vendor_resume_after_candidate()
	local v = AVM.vendor
	if not v.active then return end
	if v.resumeSegment == "SEEK" then
		if avm_vendor_start_seek(v.resumeSeekIndex or 1) then return end
	end
	v.resumeSegment = "HOT"
	avm_vendor_restart_cycle()
end

local function avm_resume_after_candidate(c, dryRun)
	if avm_is_auxarb_candidate(c) then
		if c and c.scanComplete then
			local a = AVM.auxArb
			a.paused = false
			a.pausePending = false
			a.resumePending = false
			a.candidate = nil
			a.deVerify = nil
			AVM.candidate = nil
			AVM.revalidatePages = nil
			AVM.revalidatePos = 0
			AVM.phase = "IDLE"
			avm_print("AUX_ARB_POSTSCAN_DONE " .. tostring(dryRun and "dryrun" or "transaction"))
			return
		end
		avm_auxarb_resume_search(dryRun and "dryrun" or "transaction")
		return
	end
	if c and (c.mode == "vendor" or c.mode == "fastvendor") then
		avm_vendor_resume_after_candidate()
		return
	end
	if c and c.mode == "fastvendor" then
		AVM.candidate = nil
		AVM.revalidatePages = nil
		AVM.revalidatePos = 0
		AVM.phase = "IDLE"
		if AVM_DB.live then AVM_DB.live = false end
		avm_print("FAST VENDOR cycle complete; LIVE OFF")
		return
	end
	avm_restart_boundary()
end

local function avm_vendor_finish(reason)
	local v = AVM.vendor
	if AVM_DB.live then
		AVM_DB.live = false
		avm_print("LIVE OFF - VENDOR stopped")
	end
	if AVM.candidate and AVM.candidate.mode == "vendor" then AVM.candidate = nil end
	AVM.revalidatePages = nil
	AVM.revalidatePos = 0
	avm_print("VENDOR stopped: " .. tostring(reason or "stopped"))
	v.active = false
	v.requested = false
	v.stopRequested = false
	v.phase = "IDLE"
	v.best = nil
	v.segment = ""
	v.resumeSegment = "HOT"
	v.resumeSeekIndex = 1
	v.seekTargets = {}
	v.seekIndex = 0
	v.seekTarget = 0
	v.seekLow = 0
	v.seekHigh = 0
	v.seekLocatedPage = 0
	v.priceCeiling = false
	v.consecutiveTimeouts = 0
	if AVM_DB.enabled then avm_restart_boundary(false) end
end

avm_vendor_restart_cycle = function()
	local v = AVM.vendor
	if not v.active then return end
	if v.stopRequested then
		avm_vendor_finish("manual stop")
		return
	end
	v.pagesScanned = 0
	v.best = nil
	v.segment = ""
	v.segmentStart = 0
	v.segmentEnd = 0
	v.resumeSegment = "HOT"
	v.resumeSeekIndex = 1
	v.seekTargets = {}
	v.seekIndex = 0
	v.seekTarget = 0
	v.seekLow = 0
	v.seekHigh = 0
	v.seekLocatedPage = 0
	v.priceCeiling = false
	v.low = 0
	v.high = 0
	v.page = 0
	v.lastPage = 0
	v.consecutiveTimeouts = 0
	local cached = tonumber(AVM_DB.vendorMeta.boundary)
	if cached and cached >= 0 then
		v.boundary = cached
		if cached > 0 then v.phase = "VERIFY_PREV" else v.phase = "VERIFY_BOUNDARY" end
	else
		v.boundary = nil
		v.phase = "PROBE"
	end
end

local function avm_vendor_begin()
	local v = AVM.vendor
	if v.active then return end
	if AVM.pending or AVM.unknown then return end
	v.active = true
	v.requested = false
	v.stopRequested = false
	v.startedAt = GetTime()
	AVM.stats.vendorScans = AVM.stats.vendorScans + 1
	avm_print("VENDOR start minProfit=" .. avm_money(AVM_DB.vendorMinProfit or 0) ..
		" maxBuyout=" .. avm_money(AVM_DB.vendorMaxBuyout or 0) ..
		" HOT=" .. tostring(avm_vendor_hot_pages()) ..
		" FAST_SEEK radius=" .. tostring(avm_vendor_seek_radius()))
	avm_vendor_restart_cycle()
end

local function avm_vendor_request_start()
	if not AVM.open then
		avm_print("VENDOR requires open Auction House")
		return
	end
	if AVM.pending or AVM.unknown then
		avm_print("VENDOR waits: purchase transaction is pending/unknown")
		return
	end
	if AVM.market.active or AVM.market.requested then
		avm_print("VENDOR blocked while MARKET owns/requests the AH scheduler")
		return
	end
	if AVM_DB.live then
		AVM_DB.live = false
		avm_print("LIVE OFF - VENDOR starts in DRY-RUN; arm LIVE explicitly after review")
	end
	AVM.vendor.requested = true
	avm_print("VENDOR scan queued")
end

local function avm_vendor_enter_scan(boundary, lastPage)
	local v = AVM.vendor
	v.boundary = boundary
	v.lastPage = lastPage
	v.pagesScanned = 0
	v.best = nil
	v.resumeSegment = "HOT"
	v.resumeSeekIndex = 1
	AVM_DB.vendorMeta.boundary = boundary
	avm_print("VENDOR first positive-buyout page=" .. tostring(boundary) ..
		" lastPage=" .. tostring(lastPage))
	avm_vendor_start_hot()
end

local function avm_vendor_accept(kind, page, total, positive)
	local v = AVM.vendor
	v.consecutiveTimeouts = 0
	local lastPage = 0
	if total and total > 0 then lastPage = math.floor((total - 1) / 50) end
	if lastPage > v.lastPage then v.lastPage = lastPage end

	if v.stopRequested then
		avm_vendor_finish("manual stop")
		return
	end

	if kind == "VENDOR_VERIFY_PREV" then
		if positive then
			AVM_DB.vendorMeta.boundary = nil
			v.boundary = nil
			v.phase = "PROBE"
		else
			v.phase = "VERIFY_BOUNDARY"
		end
		return
	end

	if kind == "VENDOR_VERIFY_BOUNDARY" then
		if positive then
			avm_print("VENDOR cache hit boundary=" .. tostring(v.boundary))
			avm_vendor_enter_scan(v.boundary or 0, lastPage)
		else
			AVM_DB.vendorMeta.boundary = nil
			v.boundary = nil
			v.phase = "PROBE"
		end
		return
	end

	if kind == "VENDOR_PROBE" then
		if not total or total <= 0 then
			avm_vendor_finish("no auction results")
			return
		end
		if positive then
			avm_vendor_enter_scan(0, lastPage)
			return
		end
		if lastPage <= 0 then
			avm_vendor_finish("no positive buyouts")
			return
		end
		v.low = 1
		v.high = lastPage
		v.phase = "SEARCH"
		return
	end

	if kind == "VENDOR_SEARCH" then
		if positive then v.high = page else v.low = page + 1 end
		if v.low > v.high then
			avm_vendor_finish("no positive buyouts")
			return
		end
		if v.low == v.high then
			v.boundary = v.low
			v.phase = "FINAL"
		else
			v.phase = "SEARCH"
		end
		return
	end

	if kind == "VENDOR_FINAL" then
		if positive then
			avm_vendor_enter_scan(page, lastPage)
		else
			AVM_DB.vendorMeta.boundary = nil
			avm_vendor_finish("boundary verification failed")
		end
		return
	end

	if kind == "VENDOR_SEEK_SEARCH" then
		AVM.stats.vendorSeekQueries = AVM.stats.vendorSeekQueries + 1
		local pageMax = avm_vendor_page_max_positive_buyout()
		if pageMax and pageMax >= (v.seekTarget or 0) then
			v.seekHigh = page
		else
			v.seekLow = page + 1
		end
		if v.seekLow >= v.seekHigh then v.phase = "SEEK_FINAL" end
		return
	end

	if kind == "VENDOR_SEEK_FINAL" then
		AVM.stats.vendorSeekQueries = AVM.stats.vendorSeekQueries + 1
		local pageMax = avm_vendor_page_max_positive_buyout()
		if not pageMax or pageMax < (v.seekTarget or 0) then
			avm_print("VENDOR SEEK target=" .. avm_money(v.seekTarget or 0) ..
				" beyond-market page=" .. tostring(page))
			avm_vendor_restart_cycle()
			return
		end
		avm_print("VENDOR SEEK_HIT target=" .. avm_money(v.seekTarget or 0) ..
			" page=" .. tostring(page) ..
			" pageMax=" .. avm_money(pageMax))
		avm_vendor_start_seek_scan(page)
		return
	end

	if kind == "VENDOR_SCAN" then
		AVM.stats.vendorPages = AVM.stats.vendorPages + 1
		v.pagesScanned = v.pagesScanned + 1
		if v.segment == "HOT" then
			AVM.stats.vendorHotPages = AVM.stats.vendorHotPages + 1
		elseif v.segment == "SEEK" then
			AVM.stats.vendorSeekPages = AVM.stats.vendorSeekPages + 1
		end

		local pageBest = avm_vendor_pick_page_best()
		if pageBest then
			AVM.stats.vendorCandidates = AVM.stats.vendorCandidates + 1
			if not v.best or pageBest.profit > v.best.profit or
				(pageBest.profit == v.best.profit and pageBest.buyout < v.best.buyout) then
				v.best = pageBest
			end
		end

		local priceCeiling = false
		local maxBuyout = tonumber(AVM_DB.vendorMaxBuyout) or 0
		local minPositive = avm_vendor_page_min_positive_buyout()
		if maxBuyout > 0 and minPositive and minPositive > maxBuyout then
			priceCeiling = true
			v.priceCeiling = true
			AVM.stats.vendorPriceCeilings = AVM.stats.vendorPriceCeilings + 1
			avm_print("VENDOR_PRICE_CEILING segment=" .. tostring(v.segment) ..
				" page=" .. tostring(page) ..
				" minBuyout=" .. avm_money(minPositive) ..
				" maxBuyout=" .. avm_money(maxBuyout))
		end

		v.page = page + 1
		local done = priceCeiling or page >= v.segmentEnd or page >= v.lastPage
		if not done then return end

		local segment = v.segment
		if v.best then
			AVM.stats.vendorBest = AVM.stats.vendorBest + 1
			AVM.candidate = v.best
			v.best = nil
			AVM.candidate.vendorSegment = segment
			v.resumeSegment = "SEEK"
			if segment == "HOT" then
				v.resumeSeekIndex = 1
			else
				v.resumeSeekIndex = (v.seekIndex or 0) + 1
			end
			avm_print("VENDOR_BEST segment=" .. tostring(segment) ..
				" " .. AVM.candidate.count .. "x " .. AVM.candidate.name ..
				" buy=" .. avm_money(AVM.candidate.buyout) ..
				" vendor=" .. avm_money(AVM.candidate.vendorTotal) ..
				" profit=" .. avm_money(AVM.candidate.profit) ..
				" page=" .. tostring(AVM.candidate.sourcePage) ..
				" scannedPages=" .. tostring(v.pagesScanned))
			avm_prepare_revalidate(AVM.candidate)
			v.phase = "REVALIDATE"
		else
			avm_print("VENDOR_" .. tostring(segment) .. "_NONE scannedPages=" ..
				tostring(v.pagesScanned) ..
				" seekIndex=" .. tostring(v.seekIndex or 0))
			avm_vendor_continue_after_segment()
		end
		return
	end
	if kind == "VENDOR_REVALIDATE" then
		avm_revalidate_candidate()
		return
	end
end

local function avm_vendor_tick()
	local v = AVM.vendor
	if not v.active then return end
	if v.stopRequested and not AVM.queryInFlight then
		avm_vendor_finish("manual stop")
		return
	end
	if v.phase == "VERIFY_PREV" then
		avm_send_query("VENDOR_VERIFY_PREV", (v.boundary or 0) - 1, "")
	elseif v.phase == "VERIFY_BOUNDARY" then
		avm_send_query("VENDOR_VERIFY_BOUNDARY", v.boundary or 0, "")
	elseif v.phase == "PROBE" then
		avm_send_query("VENDOR_PROBE", 0, "")
	elseif v.phase == "SEARCH" then
		local mid = math.floor((v.low + v.high) / 2)
		avm_send_query("VENDOR_SEARCH", mid, "")
	elseif v.phase == "FINAL" then
		avm_send_query("VENDOR_FINAL", v.boundary or v.low or 0, "")
	elseif v.phase == "SEEK_SEARCH" then
		if v.seekLow >= v.seekHigh then
			v.phase = "SEEK_FINAL"
		else
			local mid = math.floor((v.seekLow + v.seekHigh) / 2)
			avm_send_query("VENDOR_SEEK_SEARCH", mid, "")
		end
	elseif v.phase == "SEEK_FINAL" then
		avm_send_query("VENDOR_SEEK_FINAL", v.seekLow or v.boundary or 0, "")
	elseif v.phase == "SCAN" then
		avm_send_query("VENDOR_SCAN", v.page, "")
	elseif v.phase == "REVALIDATE" then
		if AVM.candidate and AVM.revalidatePages and AVM.revalidatePages[AVM.revalidatePos] then
			avm_send_query("VENDOR_REVALIDATE", AVM.revalidatePages[AVM.revalidatePos], "")
		else
			avm_vendor_restart_cycle()
		end
	end
end

local function avm_vendor_status()
	local v = AVM.vendor
	local targetCount = table.getn(v.seekTargets or {})
	avm_print("VENDOR active=" .. tostring(v.active) ..
		" requested=" .. tostring(v.requested) ..
		" live=" .. tostring(AVM_DB.live) ..
		" phase=" .. tostring(v.phase) ..
		" segment=" .. tostring(v.segment) ..
		" page=" .. tostring(v.page) .. "/" .. tostring(v.lastPage) ..
		" scanned=" .. tostring(v.pagesScanned))
	avm_print("VENDOR minProfit=" .. avm_money(AVM_DB.vendorMinProfit or 0) ..
		" maxBuyout=" .. avm_money(AVM_DB.vendorMaxBuyout or 0) ..
		" HOT=" .. tostring(avm_vendor_hot_pages()) ..
		" seekRadius=" .. tostring(avm_vendor_seek_radius()) ..
		" seek=" .. tostring(v.seekIndex or 0) .. "/" .. tostring(targetCount) ..
		" target=" .. avm_money(v.seekTarget or 0) ..
		" range=" .. tostring(v.seekLow or 0) .. "-" .. tostring(v.seekHigh or 0))
	avm_print("VENDOR buys=" .. tostring(AVM.sessionBuys) .. "/" .. tostring(AVM_DB.maxSessionBuys or 1) ..
		" spend=" .. avm_money(AVM.sessionSpend) ..
		" hotPages=" .. tostring(AVM.stats.vendorHotPages) ..
		" seekQueries=" .. tostring(AVM.stats.vendorSeekQueries) ..
		" seekPages=" .. tostring(AVM.stats.vendorSeekPages) ..
		" timeouts=" .. tostring(AVM.stats.vendorTimeouts))
end

local function avm_vendor_slash(rest)
	rest = avm_trim(rest or "")
	local _,_,sub,arg = string.find(rest, "^(%S+)%s*(.*)$")
	sub = string.lower(sub or "status")
	arg = arg or ""
	if sub == "start" or sub == "on" then
		avm_vendor_request_start()
	elseif sub == "stop" or sub == "off" then
		AVM.vendor.requested = false
		if AVM.vendor.active then
			AVM.vendor.stopRequested = true
			avm_print("VENDOR stop requested")
		else
			avm_print("VENDOR not running")
		end
	elseif sub == "status" then
		avm_vendor_status()
		avm_print("FAST VENDOR live=" .. tostring(AVM_DB.fastVendorLive) .. " (F2 full scan -> best candidate -> exact revalidate -> max 1 buy)")
	elseif sub == "fastlive" then
		local v = string.lower(avm_trim(arg))
		if v == "on" then
			AVM_DB.fastVendorLive = true
			avm_print("FAST VENDOR LIVE ARMED: next F2 scan may buy ONE revalidated <vendor auction")
		elseif v == "off" then
			AVM_DB.fastVendorLive = false
			avm_print("FAST VENDOR LIVE OFF")
		else
			avm_print("usage: /avm vendor fastlive on|off")
		end
	elseif sub == "minprofit" then
		local n = avm_parse_money(avm_trim(arg))
		if n and n >= 0 then
			AVM_DB.vendorMinProfit = n
			avm_print("VENDOR minProfit=" .. avm_money(n))
		else
			avm_print("invalid minprofit")
		end
	elseif sub == "maxbuyout" then
		local n = avm_parse_money(avm_trim(arg))
		if n and n >= 0 then
			AVM_DB.vendorMaxBuyout = n
			avm_print("VENDOR maxBuyout=" .. avm_money(n) .. " (0 = unlimited)")
		else
			avm_print("invalid maxbuyout")
		end
	elseif sub == "pages" or sub == "hotpages" then
		local n = tonumber(avm_trim(arg))
		if n and n >= 1 and n <= 100 then
			AVM_DB.vendorHotPages = math.floor(n)
			AVM_DB.vendorMaxPages = AVM_DB.vendorHotPages
			avm_print("VENDOR HOT pages=" .. tostring(AVM_DB.vendorHotPages))
		else
			avm_print("vendor HOT pages must be 1..100")
		end
	elseif sub == "seekradius" then
		local n = tonumber(avm_trim(arg))
		if n and n >= 0 and n <= 5 then
			AVM_DB.vendorSeekRadius = math.floor(n)
			avm_print("VENDOR SEEK radius=" .. tostring(AVM_DB.vendorSeekRadius))
		else
			avm_print("vendor seekradius must be 0..5")
		end
	elseif sub == "targets" then
		local targets = avm_vendor_build_seek_targets()
		local out = ""
		for i = 1, table.getn(targets) do
			if out ~= "" then out = out .. ", " end
			out = out .. avm_money(targets[i])
		end
		avm_print("VENDOR SEEK targets: " .. out)
	elseif sub == "sweeppages" or sub == "sweepreset" then
		avm_print("VENDOR SWEEP is legacy in 0.11; FAST SEEK is active")
	else
		avm_print("/avm vendor start|stop|status|fastlive on|off|minprofit 5s|maxbuyout 1g|hotpages 10|seekradius 1|targets")
	end
end

local function avm_pick_candidate()
	local n = GetNumAuctionItems("list")
	local best = nil
	local maxSpend = tonumber(AVM_DB.maxSessionSpend) or 0
	for i = 1, n do
		local candidate = avm_candidate_from_row(i)
		if candidate then
			local liveEligible = true
			if AVM_DB.live then
				if not candidate.affordable then liveEligible = false end
				if maxSpend > 0 and AVM.sessionSpend + candidate.buyout > maxSpend then
					liveEligible = false
				end
			end
			if liveEligible and (not best or
				candidate.unit < best.unit or
				(candidate.unit == best.unit and candidate.buyout < best.buyout)) then
				candidate.index = i
				best = candidate
			end
		end
	end
	return best
end

local function avm_candidate_live(c)
	if avm_is_auxarb_candidate(c) then return AVM_DB.auxArbLive and true or false end
	return AVM_DB.live and true or false
end

local function avm_disarm_candidate_live(c)
	if avm_is_auxarb_candidate(c) then AVM_DB.auxArbLive = false else AVM_DB.live = false end
end

avm_revalidate_candidate = function()
	local c = AVM.candidate
	if not c then
		if AVM.vendor.active then avm_vendor_restart_cycle() else avm_restart_boundary() end
		return
	end

	local n = GetNumAuctionItems("list")
	for i = 1, n do
		local name,_,count,quality,_,level,_,_,buyout,_,_,owner = GetAuctionItemInfo("list", i)
		if name and buyout and buyout > 0 then
			local itemKey = avm_item_link_key(i)
			local sig
			if c.ignoreOwnerSignature then
				sig = avm_signature_no_owner(name, count, buyout, quality, level, itemKey)
			else
				sig = avm_signature(name, count, buyout, owner, quality, level, itemKey)
			end
			if sig == c.signature then
				if avm_is_auxarb_candidate(c) then
					local record = AVM_AUX_INFO_OK and AVM_AUX_INFO and AVM_AUX_INFO.auction(i, "list") or nil
					if record then record.index = i record.page = c.sourcePage end
					local fresh
					if c.mode == "auxarb_de" then
						fresh = record and avm_de_candidate_from_record(record, c.deVerifiedBook or AVM.auxArb.deMaterialBook) or nil
					else
						fresh = record and avm_auxarb_candidate_from_record(record, c.mode) or nil
					end
					if not fresh or fresh.signature ~= c.signature then
						AVM.stats.failed = AVM.stats.failed + 1
						AVM.recent[c.signature] = GetTime() + 2
						avm_print("AUX_ARB_REVALIDATE_REJECT " .. tostring(c.name) .. " route=" .. tostring(c.route))
						avm_resume_after_candidate(c, false)
						return
					end
					c.profit = fresh.profit
					c.valuationTotal = fresh.valuationTotal
					c.vendorTotal = fresh.vendorTotal
					c.deValue = fresh.deValue
					c.deGross = fresh.deGross
					c.deMaxEntry = fresh.deMaxEntry
					c.materials = fresh.materials or c.materials
					c.affordable = fresh.affordable
					c.missing = fresh.missing
				end
				c.index = i
				c.revalidatedAt = GetTime()
				AVM.stats.revalidations = AVM.stats.revalidations + 1

				if not avm_candidate_live(c) then
					AVM.recent[c.signature] = GetTime() + 3
					local wallet = " affordable=true"
					if not c.affordable then
						wallet = " affordable=false missing=" .. avm_money(c.missing or 0)
					end
					if avm_is_auxarb_candidate(c) then
						avm_print("AUX_ARB_DRYRUN route=" .. tostring(c.route) .. " " .. c.count .. "x " .. c.name ..
							" buy=" .. avm_money(c.buyout) ..
							" value=" .. avm_money(c.valuationTotal or 0) ..
							" profit=" .. avm_money(c.profit or 0) .. wallet)
					elseif (c.mode == "vendor" or c.mode == "fastvendor") then
						avm_print("VENDOR_DRYRUN " .. c.count .. "x " .. c.name ..
							" buy=" .. avm_money(c.buyout) ..
							" vendor=" .. avm_money(c.vendorTotal or 0) ..
							" profit=" .. avm_money(c.profit or 0) .. wallet)
					else
						avm_print("DRYRUN_BEST " .. c.count .. "x " .. c.name .. " total=" ..
							avm_money(c.buyout) .. " unit=" .. avm_money(c.unit) ..
							" seller=" .. tostring(c.owner) .. wallet)
					end
					avm_resume_after_candidate(c, true)
					return
				end

				if AVM.unknown then
					AVM.phase = "UNKNOWN_HOLD"
					return
				end

				if c.buyout > GetMoney() then
					AVM.stats.walletBlocks = AVM.stats.walletBlocks + 1
					AVM.recent[c.signature] = GetTime() + 3
					avm_print("LIVE_BLOCKED no money for " .. c.name ..
						" need=" .. avm_money(c.buyout) ..
						" have=" .. avm_money(GetMoney()))
					avm_resume_after_candidate(c, false)
					return
				end

				local maxBuys = tonumber(AVM_DB.maxSessionBuys) or 1
				if maxBuys > 0 and AVM.sessionBuys >= maxBuys then
					avm_disarm_candidate_live(c)
					avm_print((avm_is_auxarb_candidate(c) and "AUX_ARB_LIVE_AUTO_OFF" or "LIVE_AUTO_OFF") .. " purchase limit reached (" ..
						tostring(AVM.sessionBuys) .. "/" .. tostring(maxBuys) .. ")")
					avm_resume_after_candidate(c, false)
					return
				end

				local maxSpend = tonumber(AVM_DB.maxSessionSpend) or 0
				if maxSpend > 0 and AVM.sessionSpend + c.buyout > maxSpend then
					avm_print("session spend limit blocks " .. c.name)
					AVM.recent[c.signature] = GetTime() + 10
					avm_resume_after_candidate(c, false)
					return
				end

				local before = GetMoney()
				if c.buyout > before then
					AVM.stats.walletBlocks = AVM.stats.walletBlocks + 1
					avm_print("LIVE_BLOCKED wallet changed before buy " .. c.name)
					avm_resume_after_candidate(c, false)
					return
				end
				AVM.recent[c.signature] = GetTime() + AVM_UNKNOWN_HOLD
				PlaceAuctionBid("list", i, c.buyout)
				AVM.stats.buySent = AVM.stats.buySent + 1
				AVM.pending = {
					candidate = c,
					moneyBefore = before,
					sentAt = GetTime(),
				}
				AVM.candidate = nil
				AVM.phase = "BUY_PENDING"
				if avm_is_auxarb_candidate(c) then
					avm_print("BUY_SENT AUX_ARB route=" .. tostring(c.route) .. " " .. c.count .. "x " .. c.name ..
						" " .. avm_money(c.buyout) .. " expectedProfit=" .. avm_money(c.profit or 0))
				elseif (c.mode == "vendor" or c.mode == "fastvendor") then
					avm_print("BUY_SENT " .. c.count .. "x " .. c.name .. " " .. avm_money(c.buyout) ..
						" expectedVendorProfit=" .. avm_money(c.profit or 0))
				else
					avm_print("BUY_SENT " .. c.count .. "x " .. c.name .. " " .. avm_money(c.buyout))
				end
				return
			end
		end
	end

	if AVM.revalidatePages and AVM.revalidatePos < table.getn(AVM.revalidatePages) then
		AVM.revalidatePos = AVM.revalidatePos + 1
		if c.mode == "vendor" then AVM.vendor.phase = "REVALIDATE" else AVM.phase = "REVALIDATE" end
		return
	end

	AVM.stats.failed = AVM.stats.failed + 1
	AVM.recent[c.signature] = GetTime() + 2
	if avm_is_auxarb_candidate(c) then
		avm_print("AUX_ARB_RACE " .. c.name .. " - opportunity moved/disappeared before revalidate")
	elseif (c.mode == "vendor" or c.mode == "fastvendor") then
		avm_print("VENDOR_RACE " .. c.name .. " - opportunity moved/disappeared before revalidate")
	else
		AVM.stats.watchRaces = AVM.stats.watchRaces + 1
		AVM.watchRaces = AVM.watchRaces + 1
		avm_print("WATCH_RACE " .. c.name .. " - best offer moved/disappeared before revalidate")
	end
	avm_resume_after_candidate(c, false)
end

local function avm_accept_result()
	local rows, total = GetNumAuctionItems("list")
	rows = rows or 0
	total = total or 0
	AVM.total = total
	AVM.lastPage = 0
	if total > 0 then AVM.lastPage = math.floor((total - 1) / 50) end
	AVM.stats.results = AVM.stats.results + 1

	local positive = avm_page_has_positive()
	local kind = AVM.queryKind
	local page = AVM.queryPage
	local latency = GetTime() - AVM.querySentAt
	local isMarket = string.find(kind, "MARKET_", 1, true) == 1
	local isVendor = string.find(kind, "VENDOR_", 1, true) == 1
	if (not isMarket or kind ~= "MARKET_SCAN") and (not isVendor or kind ~= "VENDOR_SCAN") then
		avm_print("RESULT q" .. AVM.querySeq .. " " .. kind .. " rule='" ..
			tostring(AVM.queryName) .. "' page=" .. page ..
			" rows=" .. rows .. "/" .. total .. " positive=" .. tostring(positive) ..
			" latency=" .. string.format("%.3f", latency) .. "s")
	end
	if isMarket then
		avm_market_accept(kind, page, total, positive)
		return
	end
	if isVendor then
		avm_vendor_accept(kind, page, total, positive)
		return
	end
	if kind == "DE_MAT_REVALIDATE" then
		avm_de_live_verify_accept(page, total)
		return
	end

	if AVM.rulesDirty then
		AVM.rulesDirty = false
		avm_print("WATCH_RULES_CHANGED stale scanner result ignored")
		avm_restart_boundary(true)
		return
	end

	if kind == "CACHE_VERIFY_PREV" then
		if positive then
			AVM.stats.cacheMisses = AVM.stats.cacheMisses + 1
			local rule = avm_active_rule()
			avm_invalidate_boundary(rule)
			avm_print("CACHE miss rule='" .. tostring(AVM.activeRuleName) ..
				"' previous page became positive; full search")
			avm_restart_boundary(true)
		else
			AVM.cachePrevOk = true
			AVM.phase = "CACHE_VERIFY_BOUNDARY"
		end
		return
	end

	if kind == "CACHE_VERIFY_BOUNDARY" then
		local prevOk = (AVM.cacheBoundary == 0) or AVM.cachePrevOk
		if positive and prevOk then
			AVM.stats.cacheHits = AVM.stats.cacheHits + 1
			avm_print("CACHE hit rule='" .. tostring(AVM.activeRuleName) ..
				"' boundary=" .. tostring(AVM.cacheBoundary))
			avm_start_scan(AVM.cacheBoundary)
		else
			AVM.stats.cacheMisses = AVM.stats.cacheMisses + 1
			local rule = avm_active_rule()
			avm_invalidate_boundary(rule)
			avm_print("CACHE miss rule='" .. tostring(AVM.activeRuleName) ..
				"' boundary changed; full search")
			avm_restart_boundary(true)
		end
		return
	end

	if kind == "BOUNDARY_INIT" then
		if total == 0 then
			avm_print("rule='" .. tostring(AVM.activeRuleName) .. "' has no auction results")
			avm_advance_rule()
			return
		end
		if positive then
			avm_start_scan(0)
			return
		end
		if AVM.lastPage == 0 then
			avm_print("rule='" .. tostring(AVM.activeRuleName) .. "' has auctions but no buyout")
			avm_advance_rule()
			return
		end
		AVM.boundaryLow = 1
		AVM.boundaryHigh = AVM.lastPage
		AVM.phase = "BOUNDARY_SEARCH"
		return
	end

	if kind == "BOUNDARY_SEARCH" then
		if positive then
			AVM.boundaryHigh = page
		else
			AVM.boundaryLow = page + 1
		end
		if AVM.boundaryLow > AVM.boundaryHigh then
			avm_print("rule='" .. tostring(AVM.activeRuleName) .. "' has no positive buyout page")
			avm_advance_rule()
			return
		end
		if AVM.boundaryLow == AVM.boundaryHigh and page == AVM.boundaryLow then
			if positive then
				avm_start_scan(page)
			else
				avm_advance_rule()
			end
			return
		end
		AVM.phase = "BOUNDARY_SEARCH"
		return
	end

	if kind == "BOUNDARY_FINAL" then
		if positive then
			avm_start_scan(page)
		else
			avm_print("rule='" .. tostring(AVM.activeRuleName) .. "' boundary changed/no buyout")
			avm_advance_rule()
		end
		return
	end

	if kind == "CHEAPEST_SCAN" then
		local pageBest = avm_pick_candidate()
		AVM.watchPagesScanned = AVM.watchPagesScanned + 1
		AVM.stats.watchPages = AVM.stats.watchPages + 1
		if pageBest then
			local best = AVM.bestCandidate
			if not best or pageBest.unit < best.unit or
			   (pageBest.unit == best.unit and pageBest.buyout < best.buyout) then
				AVM.bestCandidate = pageBest
			end
		end

		local cap = tonumber(AVM_DB.watchMaxPages) or AVM_WATCH_MAX_PAGES
		if cap < 1 then cap = 1 end
		if cap > AVM_WATCH_MAX_PAGES then cap = AVM_WATCH_MAX_PAGES end
		local nextPage = AVM.boundaryPage + AVM.scanOffset + 1

		-- vMaNGOS orders filtered browse results by total buyout ascending.
		-- With Max stack = 1, unit price equals total buyout. Therefore the
		-- first scanned page that contains a qualifying candidate already
		-- contains the globally cheapest qualifying unit-price candidate:
		-- every later page has total buyout >= the current page range.
		local earlyStop = false
		local activeRule = avm_active_rule()
		if AVM.bestCandidate and activeRule and
		   (tonumber(activeRule.maxStack) or 0) == 1 and
		   nextPage <= AVM.lastPage then
			earlyStop = true
			AVM.stats.watchEarlyStops = AVM.stats.watchEarlyStops + 1
			avm_print("WATCH_EARLY_STOP rule='" .. tostring(AVM.activeRuleName) ..
				"' reason=maxStack1 page=" .. tostring(AVM.queryPage) ..
				" skippedPages=" .. tostring(AVM.lastPage - AVM.queryPage))
		end

		local canContinue = not earlyStop and
			nextPage <= AVM.lastPage and AVM.watchPagesScanned < cap
		if canContinue then
			AVM.scanOffset = AVM.scanOffset + 1
			AVM.phase = "CHEAPEST_SCAN"
			return
		end

		if not earlyStop and nextPage <= AVM.lastPage and AVM.watchPagesScanned >= cap then
			AVM.stats.watchCaps = AVM.stats.watchCaps + 1
			avm_print("WATCH_CAP rule='" .. tostring(AVM.activeRuleName) ..
				"' scanned=" .. tostring(AVM.watchPagesScanned) ..
				" remainingPages=" .. tostring(AVM.lastPage - (nextPage - 1)))
		end

		if AVM.bestCandidate then
			AVM.stats.candidates = AVM.stats.candidates + 1
			AVM.stats.watchBest = AVM.stats.watchBest + 1
			AVM.candidate = AVM.bestCandidate
			AVM.bestCandidate = nil
			avm_print("WATCH_BEST " .. AVM.candidate.count .. "x " .. AVM.candidate.name ..
				" unit=" .. avm_money(AVM.candidate.unit) ..
				" total=" .. avm_money(AVM.candidate.buyout) ..
				" page=" .. tostring(AVM.candidate.sourcePage) ..
				" scannedPages=" .. tostring(AVM.watchPagesScanned))
			avm_prepare_revalidate(AVM.candidate)
			AVM.phase = "REVALIDATE"
		else
			avm_print("WATCH_NONE rule='" .. tostring(AVM.activeRuleName) ..
				"' scannedPages=" .. tostring(AVM.watchPagesScanned))
			avm_advance_rule()
		end
		return
	end

	if kind == "REVALIDATE" then
		avm_revalidate_candidate()
		return
	end
end

local function avm_handle_list_update()
	local now = GetTime()
	if not AVM.queryInFlight then
		if AVM.open and (AVM_DB.enabled or AVM.market.active or AVM.vendor.active) and AVM.lastResultAt > 0 and
		   now - AVM.lastResultAt <= AVM_EXTRA_EVENT_WINDOW then
			AVM.stats.extraEvents = AVM.stats.extraEvents + 1
		end
		return
	end

	-- Consume exactly one update for the query, then leave a short quiet window
	-- so a delayed duplicate cannot be mistaken for the next query's response.
	AVM.queryInFlight = false
	AVM.lastResultAt = now
	AVM.nextQueryAt = now + AVM_EVENT_SETTLE
	avm_accept_result()
end

local function avm_tick_pending(now)
	if AVM.pending then
		local p = AVM.pending
		local delta = p.moneyBefore - GetMoney()
		if delta == p.candidate.buyout then
			AVM.stats.confirmed = AVM.stats.confirmed + 1
			AVM.sessionSpend = AVM.sessionSpend + p.candidate.buyout
			AVM.sessionBuys = AVM.sessionBuys + 1
			AVM.recent[p.candidate.signature] = now + 15
			if avm_is_auxarb_candidate(p.candidate) then
				avm_print("CONFIRMED AUX_ARB route=" .. tostring(p.candidate.route) .. " " .. p.candidate.name ..
					" " .. avm_money(p.candidate.buyout) .. " expectedProfit=" .. avm_money(p.candidate.profit or 0))
			elseif (p.candidate.mode == "vendor" or p.candidate.mode == "fastvendor") then
				avm_print("CONFIRMED " .. p.candidate.name .. " " .. avm_money(p.candidate.buyout) ..
					" expectedVendorProfit=" .. avm_money(p.candidate.profit or 0))
			else
				avm_print("CONFIRMED " .. p.candidate.name .. " " .. avm_money(p.candidate.buyout))
			end
			local maxBuys = tonumber(AVM_DB.maxSessionBuys) or 1
			if maxBuys > 0 and AVM.sessionBuys >= maxBuys then
				avm_disarm_candidate_live(p.candidate)
				avm_print((avm_is_auxarb_candidate(p.candidate) and "AUX_ARB_LIVE_AUTO_OFF" or "LIVE_AUTO_OFF") .. " purchase limit reached (" ..
					tostring(AVM.sessionBuys) .. "/" .. tostring(maxBuys) .. ")")
			end
			AVM.pending = nil
			avm_resume_after_candidate(p.candidate, false)
			return true
		end

		if now - p.sentAt >= AVM_PENDING_TIMEOUT then
			AVM.stats.unknown = AVM.stats.unknown + 1
			AVM.unknown = {
				candidate = p.candidate,
				moneyBefore = p.moneyBefore,
				since = now,
				untilTime = now + AVM_UNKNOWN_HOLD,
			}
			AVM.recent[p.candidate.signature] = now + AVM_UNKNOWN_HOLD
			AVM.pending = nil
			AVM.phase = "UNKNOWN_HOLD"
			avm_print("UNKNOWN " .. p.candidate.name .. " - no purchase confirmation; live buys paused")
			return true
		end
	end

	if AVM.unknown then
		local u = AVM.unknown
		local delta = u.moneyBefore - GetMoney()
		if delta == u.candidate.buyout then
			AVM.stats.confirmed = AVM.stats.confirmed + 1
			AVM.sessionSpend = AVM.sessionSpend + u.candidate.buyout
			AVM.sessionBuys = AVM.sessionBuys + 1
			if avm_is_auxarb_candidate(u.candidate) then
				avm_print("CONFIRMED_LATE AUX_ARB route=" .. tostring(u.candidate.route) .. " " .. u.candidate.name ..
					" " .. avm_money(u.candidate.buyout) .. " expectedProfit=" .. avm_money(u.candidate.profit or 0))
			elseif (u.candidate.mode == "vendor" or u.candidate.mode == "fastvendor") then
				avm_print("CONFIRMED_LATE " .. u.candidate.name .. " " .. avm_money(u.candidate.buyout) ..
					" expectedVendorProfit=" .. avm_money(u.candidate.profit or 0))
			else
				avm_print("CONFIRMED_LATE " .. u.candidate.name .. " " .. avm_money(u.candidate.buyout))
			end
			local maxBuys = tonumber(AVM_DB.maxSessionBuys) or 1
			if maxBuys > 0 and AVM.sessionBuys >= maxBuys then
				avm_disarm_candidate_live(u.candidate)
				avm_print((avm_is_auxarb_candidate(u.candidate) and "AUX_ARB_LIVE_AUTO_OFF" or "LIVE_AUTO_OFF") .. " purchase limit reached (" ..
					tostring(AVM.sessionBuys) .. "/" .. tostring(maxBuys) .. ")")
			end
			AVM.unknown = nil
			avm_resume_after_candidate(u.candidate, false)
			return true
		end
		if now >= u.untilTime then
			avm_print("UNKNOWN_RELEASE " .. u.candidate.name .. " - reservation expired; rescan")
			AVM.unknown = nil
			avm_resume_after_candidate(u.candidate, false)
			return true
		end
		return true
	end
	return false
end

local function avm_tick()
	if not AVM.open then return end
	local now = GetTime()

	if avm_market_auto_due() then
		AVM.market.requested = true
		avm_print("MARKET auto scan due")
	end

	if avm_tick_pending(now) then return end

	if AVM.queryInFlight then
		if now - AVM.querySentAt >= AVM_QUERY_TIMEOUT then
			AVM.stats.timeouts = AVM.stats.timeouts + 1
			avm_print("QUERY_TIMEOUT q" .. AVM.querySeq .. " " .. AVM.queryKind)
			local marketQuery = string.find(AVM.queryKind or "", "MARKET_", 1, true) == 1
			local vendorQuery = string.find(AVM.queryKind or "", "VENDOR_", 1, true) == 1
			AVM.queryInFlight = false
			if marketQuery and AVM.market.active then
				AVM.stats.marketTimeouts = AVM.stats.marketTimeouts + 1
				AVM.market.consecutiveTimeouts = AVM.market.consecutiveTimeouts + 1
				if AVM.market.consecutiveTimeouts >= 3 then
					avm_market_finish(false, "3 consecutive query timeouts")
				end
			elseif vendorQuery and AVM.vendor.active then
				AVM.stats.vendorTimeouts = AVM.stats.vendorTimeouts + 1
				AVM.vendor.consecutiveTimeouts = AVM.vendor.consecutiveTimeouts + 1
				if AVM.vendor.consecutiveTimeouts >= 3 then
					avm_vendor_finish("3 consecutive query timeouts")
				end
			elseif AVM.queryKind == "DE_MAT_REVALIDATE" and AVM.auxArb.deVerify then
				avm_de_fail_postscan(AVM.auxArb.deVerify.candidate, "material-query-timeout")
				return
			else
				if AVM.queryKind == "REVALIDATE" and avm_is_auxarb_candidate(AVM.candidate) then
					local c = AVM.candidate
					AVM.recent[c.signature] = GetTime() + 2
					avm_print("AUX_ARB_REVALIDATE_TIMEOUT " .. tostring(c.name))
					avm_resume_after_candidate(c, false)
					return
				end
				if AVM.queryKind == "REVALIDATE" then AVM.candidate = nil end
				avm_restart_boundary()
			end
		end
		return
	end

	if AVM.market.requested and not AVM.market.active then
		avm_market_begin()
	end
	if AVM.market.active then
		avm_market_tick()
		return
	end

	if AVM.vendor.requested and not AVM.vendor.active then
		avm_vendor_begin()
	end
	if AVM.vendor.active then
		avm_vendor_tick()
		return
	end

	if AVM.rulesDirty and not AVM.queryInFlight and not AVM.pending and not AVM.unknown then
		AVM.rulesDirty = false
		avm_restart_boundary(true)
	end

	if AVM.phase == "DE_MAT_REVALIDATE" and AVM.auxArb.deVerify then
		local v = AVM.auxArb.deVerify
		local mat = v.materials and v.materials[v.index]
		if not mat or not mat.name or mat.name == "" then
			avm_de_fail_postscan(v.candidate, "material-name-missing")
		else
			avm_send_query("DE_MAT_REVALIDATE", v.page or 0, mat.name)
		end
		return
	end

	if AVM.candidate and (AVM.candidate.mode == "fastvendor" or avm_is_auxarb_candidate(AVM.candidate)) and AVM.phase == "REVALIDATE" then
		if AVM.revalidatePages and AVM.revalidatePages[AVM.revalidatePos] then
			-- FAST/native AUX sourcePage belongs to the unfiltered full-AH ordering.
			-- Revalidate the exact signature on that same unfiltered page.
			avm_send_query("REVALIDATE", AVM.revalidatePages[AVM.revalidatePos], "")
		else
			avm_print("AUX/FAST revalidate has no valid source page; abort")
			avm_resume_after_candidate(AVM.candidate, false)
		end
		return
	end

	if not AVM_DB.enabled then return end

	if AVM.phase == "IDLE" or AVM.phase == "WAIT_RULE" then
		avm_restart_boundary()
	end

	local rule = avm_active_rule()
	if not rule then return end
	local queryName = rule.name or ""

	if AVM.phase == "CACHE_VERIFY_PREV" then
		avm_send_query("CACHE_VERIFY_PREV", AVM.cacheBoundary - 1, queryName)
	elseif AVM.phase == "CACHE_VERIFY_BOUNDARY" then
		avm_send_query("CACHE_VERIFY_BOUNDARY", AVM.cacheBoundary, queryName)
	elseif AVM.phase == "BOUNDARY_INIT" then
		avm_send_query("BOUNDARY_INIT", 0, queryName)
	elseif AVM.phase == "BOUNDARY_SEARCH" then
		if AVM.boundaryLow == AVM.boundaryHigh then
			avm_send_query("BOUNDARY_FINAL", AVM.boundaryLow, queryName)
		else
			local mid = math.floor((AVM.boundaryLow + AVM.boundaryHigh) / 2)
			avm_send_query("BOUNDARY_SEARCH", mid, queryName)
		end
	elseif AVM.phase == "CHEAPEST_SCAN" then
		avm_send_query("CHEAPEST_SCAN", AVM.boundaryPage + AVM.scanOffset, queryName)
	elseif AVM.phase == "REVALIDATE" then
		if AVM.candidate and AVM.revalidatePages and AVM.revalidatePages[AVM.revalidatePos] then
			avm_send_query("REVALIDATE", AVM.revalidatePages[AVM.revalidatePos], AVM.candidate.name)
		else
			avm_restart_boundary()
		end
	end
end

local function avm_status()
	local rule = avm_active_rule()
	avm_print("v" .. AVM_VERSION ..
		" enabled=" .. tostring(AVM_DB.enabled) ..
		" live=" .. tostring(AVM_DB.live) ..
		" phase=" .. AVM.phase ..
		" slot=" .. tostring(AVM.ruleIndex) ..
		" activeRules=" .. tostring(avm_rule_count()) ..
		" '" .. tostring(rule and rule.name or "") .. "'" ..
		" boundary=" .. tostring(AVM.boundaryPage) ..
		" scanPage=" .. tostring((AVM.boundaryPage or 0) + (AVM.scanOffset or 0)) ..
		" scanned=" .. tostring(AVM.watchPagesScanned) ..
		" cache=" .. tostring(avm_cached_boundary(rule)) ..
		" buys=" .. tostring(AVM.sessionBuys) .. "/" .. tostring(AVM_DB.maxSessionBuys or 1) ..
		" spend=" .. avm_money(AVM.sessionSpend))
	avm_print("queries=" .. AVM.stats.queries ..
		" results=" .. AVM.stats.results ..
		" extraEvents=" .. AVM.stats.extraEvents ..
		" timeouts=" .. AVM.stats.timeouts ..
		" cacheV=" .. AVM.stats.cacheVerifications ..
		" cacheHit=" .. AVM.stats.cacheHits ..
		" cacheMiss=" .. AVM.stats.cacheMisses ..
		" walletBlock=" .. AVM.stats.walletBlocks ..
		" candidates=" .. AVM.stats.candidates ..
		" watchPages=" .. AVM.stats.watchPages ..
		" watchBest=" .. AVM.stats.watchBest ..
		" watchCaps=" .. AVM.stats.watchCaps ..
		" watchEarly=" .. AVM.stats.watchEarlyStops ..
		" watchRaces=" .. AVM.stats.watchRaces ..
		" revalidations=" .. AVM.stats.revalidations ..
		" sent=" .. AVM.stats.buySent ..
		" confirmed=" .. AVM.stats.confirmed ..
		" failed=" .. AVM.stats.failed ..
		" unknown=" .. AVM.stats.unknown ..
		" marketScans=" .. AVM.stats.marketScans ..
		" marketPages=" .. AVM.stats.marketPages ..
		" marketTimeouts=" .. AVM.stats.marketTimeouts ..
		" vendorPages=" .. AVM.stats.vendorPages ..
		" vendorBest=" .. AVM.stats.vendorBest ..
		" vendorHot=" .. AVM.stats.vendorHotPages ..
		" vendorSweep=" .. AVM.stats.vendorSweepPages ..
		" vendorPasses=" .. AVM.stats.vendorSweepPasses ..
		" vendorSeekQ=" .. AVM.stats.vendorSeekQueries ..
		" vendorSeekPages=" .. AVM.stats.vendorSeekPages ..
		" vendorSeekTargets=" .. AVM.stats.vendorSeekTargets ..
		" vendorCeilings=" .. AVM.stats.vendorPriceCeilings ..
		" vendorTimeouts=" .. AVM.stats.vendorTimeouts)
	if AVM.vendor.active or AVM.vendor.requested then avm_vendor_status() end
end

local function avm_ensure_rule_slot(index)
	while table.getn(AVM_DB.rules) < index do
		table.insert(AVM_DB.rules, {
			name = "",
			partial = false,
			maxUnit = 0,
			maxTotal = 0,
			minStack = 1,
			maxStack = 0,
			enabled = false,
		})
	end
	return AVM_DB.rules[index]
end

local function avm_list_rules()
	if avm_rule_count() == 0 then
		avm_print("watchlist has no active rules")
	end
	for i = 1, table.getn(AVM_DB.rules) do
		local r = AVM_DB.rules[i]
		if r and (r.name ~= "" or r.enabled) then
			avm_print(i .. ": " .. (r.enabled == false and "OFF " or "ON ") ..
				(r.partial and "partial " or "exact ") .. tostring(r.name or "") ..
				" maxUnit=" .. avm_money(r.maxUnit or 0) ..
				" maxTotal=" .. avm_money(r.maxTotal or 0) ..
				" stack=" .. tostring(r.minStack or 1) .. "-" .. tostring(r.maxStack or 0))
		end
	end
end

local function avm_rule_changed(index)
	AVM_DB.live = false
	AVM.rulesDirty = true
	AVM.uiGeneration = AVM.uiGeneration + 1
	local rule = AVM_DB.rules[index]
	if rule then avm_invalidate_boundary(rule) end
	if not AVM.queryInFlight and not AVM.pending and not AVM.unknown and not AVM.market.active then
		AVM.rulesDirty = false
		if not avm_rule_valid(AVM_DB.rules[AVM.ruleIndex]) then
			local _, nextIndex = avm_find_rule(1)
			AVM.ruleIndex = nextIndex or 1
		end
		avm_restart_boundary(true)
	end
end

local function avm_add_rule(args)
	-- /avm add exact;Black Lotus;60g;120g;1;20
	local p = avm_split(args, ";")
	if table.getn(p) < 3 then
		avm_print("usage: /avm add exact;Item Name;maxUnit;maxTotal;minStack;maxStack")
		return
	end
	local matchType = string.lower(avm_trim(p[1]))
	local name = avm_trim(p[2])
	local maxUnit = avm_parse_money(avm_trim(p[3]))
	local maxTotal = avm_parse_money(avm_trim(p[4] or "0")) or 0
	local minStack = tonumber(avm_trim(p[5] or "1")) or 1
	local maxStack = tonumber(avm_trim(p[6] or "0")) or 0
	if name == "" or not maxUnit or maxUnit <= 0 then
		avm_print("invalid rule: Item + maxUnit > 0 are required")
		return
	end

	local slot = nil
	for i = 1, AVM_WATCH_SLOTS do
		local r = AVM_DB.rules[i]
		if not r or ((r.name or "") == "" and r.enabled == false) then
			slot = i
			break
		end
	end
	if not slot then
		avm_print("watchlist full (" .. tostring(AVM_WATCH_SLOTS) .. " slots)")
		return
	end

	local r = avm_ensure_rule_slot(slot)
	r.name = name
	r.partial = (matchType == "partial")
	r.maxUnit = maxUnit
	r.maxTotal = maxTotal
	r.minStack = math.max(1, math.floor(minStack))
	r.maxStack = math.max(0, math.floor(maxStack))
	r.enabled = true
	avm_print("rule " .. slot .. " added: " .. name .. " <= " .. avm_money(maxUnit) .. "/unit")
	avm_rule_changed(slot)
end

local function avm_auxarb_slash(rest)
	rest = avm_trim(rest or "")
	local _,_,sub,arg = string.find(rest, "^(%S+)%s*(.*)$")
	sub = string.lower(sub or "status")
	arg = arg or ""
	if sub == "on" then
		AVM_DB.auxArbEnabled = true
		avm_print("AUX_ARB ON - original AUX full scans evaluate vendor + disenchant profit")
	elseif sub == "off" then
		AVM_DB.auxArbEnabled = false
		AVM_DB.auxArbLive = false
		avm_print("AUX_ARB OFF")
	elseif sub == "live" then
		local v = string.lower(avm_trim(arg))
		if v == "on" then
			if not AVM.open then
				avm_print("AUX_ARB LIVE requires open Auction House")
			elseif AVM.pending or AVM.unknown or AVM.market.active or AVM.vendor.active then
				avm_print("AUX_ARB LIVE blocked by another AH transaction/scheduler")
			else
				AVM_DB.auxArbEnabled = true
				AVM_DB.auxArbLive = true
				avm_print("AUX_ARB LIVE ARMED - page candidate -> pause -> exact revalidate -> buy -> resume")
			end
		elseif v == "off" then
			AVM_DB.auxArbLive = false
			avm_print("AUX_ARB LIVE OFF - valuation/dry-run only")
		else
			avm_print("usage: /avm auxarb live on|off")
		end
	elseif sub == "demin" then
		local n = avm_parse_money(avm_trim(arg))
		if n and n >= 0 then
			AVM_DB.deMinProfit = n
			avm_print("AUX_ARB DE minProfit=" .. avm_money(n))
		else
			avm_print("invalid demin")
		end
	elseif sub == "demax" then
		local n = avm_parse_money(avm_trim(arg))
		if n and n >= 0 then
			AVM_DB.deMaxBuyout = n
			avm_print("AUX_ARB DE maxBuyout=" .. avm_money(n) .. " (0 = unlimited)")
		else
			avm_print("invalid demax")
		end
	elseif sub == "dedepth" then
		local n = tonumber(avm_trim(arg))
		if n and n >= 1 and n <= 20 then
			AVM_DB.deDepthUnits = math.floor(n)
			avm_print("AUX_ARB DE depthUnits=" .. tostring(AVM_DB.deDepthUnits))
		else
			avm_print("dedepth must be 1..20")
		end
	elseif sub == "decut" then
		local n = tonumber(avm_trim(arg))
		if n and n >= 0 and n <= 30 then
			AVM_DB.deAhCutPct = n
			avm_print("AUX_ARB DE AH cut=" .. tostring(n) .. "%")
		else
			avm_print("decut must be 0..30")
		end
	elseif sub == "demargin" then
		local n = tonumber(avm_trim(arg))
		if n and n >= 0 and n <= 90 then
			AVM_DB.deSafetyMarginPct = n
			avm_print("AUX_ARB DE safety margin=" .. tostring(n) .. "%")
		else
			avm_print("demargin must be 0..90")
		end
	elseif sub == "status" then
		local a = AVM.auxArb
		avm_print("AUX_ARB enabled=" .. tostring(AVM_DB.auxArbEnabled) ..
			" live=" .. tostring(AVM_DB.auxArbLive) ..
			" active=" .. tostring(a.active) ..
			" paused=" .. tostring(a.paused) ..
			" pages=" .. tostring(a.pages) .. "/" .. tostring(a.lastPage))
		avm_print("AUX_ARB vendor min/max=" .. avm_money(AVM_DB.vendorMinProfit or 0) .. "/" .. avm_money(AVM_DB.vendorMaxBuyout or 0) ..
			" DE min/max=" .. avm_money(AVM_DB.deMinProfit or 0) .. "/" .. avm_money(AVM_DB.deMaxBuyout or 0) ..
			" depth=" .. tostring(AVM_DB.deDepthUnits or 3) ..
			" cut=" .. tostring(AVM_DB.deAhCutPct or 5) .. "%" ..
			" margin=" .. tostring(AVM_DB.deSafetyMarginPct or 25) .. "%")
		avm_print("AUX_ARB candidates vendor/de=" .. tostring(a.vendorCandidates or 0) .. "/" .. tostring(a.deCandidates or 0) ..
			" deNoDepth=" .. tostring(a.deNoValue or 0) ..
			" rawDE=" .. tostring(table.getn(a.deRawCandidates or {})))
	else
		avm_print("/avm auxarb on|off|status|live on|off|demin 5s|demax 1g|dedepth 3|decut 5|demargin 25")
	end
end

local function avm_slash(msg)
	avm_defaults()
	msg = avm_trim(msg or "")
	local _,_,cmd,rest = string.find(msg, "^(%S+)%s*(.*)$")
	cmd = string.lower(cmd or "status")
	rest = rest or ""

	if cmd == "on" then
		AVM_DB.enabled = true
		avm_restart_boundary()
		avm_print("scanner ON")
	elseif cmd == "off" then
		AVM_DB.enabled = false
		AVM_DB.live = false
		AVM.queryInFlight = false
		AVM.phase = "IDLE"
		AVM.market.requested = false
		if AVM.market.active then AVM.market.stopRequested = true end
		AVM.vendor.requested = false
		if AVM.vendor.active then AVM.vendor.stopRequested = true end
		avm_print("scanner/LIVE OFF")
	elseif cmd == "live" then
		if string.lower(avm_trim(rest)) == "on" then
			if not AVM.open then
				avm_print("LIVE requires open Auction House")
			elseif AVM.market.active or AVM.market.requested then
				avm_print("LIVE blocked while MARKET owns/requests the AH scheduler")
			elseif not AVM.vendor.active and not AVM.vendor.requested and avm_rule_count() == 0 then
				avm_print("LIVE requires an active WATCH rule or VENDOR scanner")
			else
				AVM_DB.live = true
				avm_print("LIVE ON - only revalidated WATCH/VENDOR offers may be bought")
			end
		else
			AVM_DB.live = false
			avm_print("LIVE OFF - dry-run only")
		end
	elseif cmd == "add" then
		avm_add_rule(rest)
	elseif cmd == "del" then
		local n = tonumber(avm_trim(rest))
		if n and n >= 1 and n <= AVM_WATCH_SLOTS and AVM_DB.rules[n] then
			local old = AVM_DB.rules[n].name or ""
			AVM_DB.rules[n] = {name="",partial=false,maxUnit=0,maxTotal=0,minStack=1,maxStack=0,enabled=false}
			avm_print("rule slot " .. n .. " cleared: " .. old)
			avm_rule_changed(n)
		else
			avm_print("invalid rule slot")
		end
	elseif cmd == "list" then
		avm_list_rules()
	elseif cmd == "pages" then
		local n = tonumber(avm_trim(rest))
		if n and n >= 1 and n <= AVM_WATCH_MAX_PAGES then
			AVM_DB.watchMaxPages = n
			avm_print("watch page cap=" .. n)
		else
			avm_print("pages must be 1.." .. tostring(AVM_WATCH_MAX_PAGES))
		end
	elseif cmd == "budget" then
		local n = avm_parse_money(avm_trim(rest))
		if n then
			AVM_DB.maxSessionSpend = n
			avm_print("session budget=" .. avm_money(n) .. " (0 = unlimited)")
		else
			avm_print("invalid money value")
		end
	elseif cmd == "market" then
		avm_market_slash(rest)
	elseif cmd == "vendor" then
		avm_vendor_slash(rest)
	elseif cmd == "auxarb" then
		avm_auxarb_slash(rest)
	elseif cmd == "maxbuys" then
		local n = tonumber(avm_trim(rest))
		if n and n >= 1 and n <= 100 then
			AVM_DB.maxSessionBuys = n
			avm_print("session live purchase limit=" .. tostring(n))
		else
			avm_print("maxbuys must be 1..100")
		end
	elseif cmd == "reset" then
		if AVM.market.active or AVM.market.requested or AVM.vendor.active or AVM.vendor.requested or AVM.pending or AVM.unknown then
			avm_print("reset blocked while MARKET/VENDOR or purchase transaction is active")
			return
		end
		AVM_DB.live = false
		AVM_DB.auxArbLive = false
		AVM.sessionSpend = 0
		AVM.sessionBuys = 0
		AVM.recent = {}
		AVM.boundaryCache = {}
		for k in AVM.stats do AVM.stats[k] = 0 end
		AVM.pending = nil
		AVM.unknown = nil
		AVM.lastResultAt = 0
		AVM.nextQueryAt = 0
		AVM.ruleIndex = 1
		avm_restart_boundary()
		avm_print("session state reset")
	elseif cmd == "status" then
		avm_status()
	elseif cmd == "gui" then
		if AVM_WATCH_UI and AVM_WATCH_UI.Toggle then AVM_WATCH_UI.Toggle() else avm_print("WATCH GUI unavailable") end
	else
		avm_print("/avm on|off | live on|off | status | gui | list | del N | pages N | budget 100g | maxbuys N")
		avm_print("/avm add exact;Black Lotus;60g;120g;1;20")
		avm_print("/avm vendor start|stop|status|minprofit 5s|maxbuyout 1g|hotpages 10|seekradius 1|targets")
		avm_print("/avm auxarb on|off|status|live on|off|demin 5s|demax 1g")
		avm_print("/avm market start|stop|status|item NAME|auto MIN|retention N|clear")
	end
end

AVM_WATCH_API = {
	Init = function()
		avm_defaults()
		for i = 1, AVM_WATCH_SLOTS do avm_ensure_rule_slot(i) end
		return AVM_WATCH_SLOTS
	end,
	GetRule = function(index)
		avm_defaults()
		if index < 1 or index > AVM_WATCH_SLOTS then return nil end
		return avm_ensure_rule_slot(index)
	end,
	SetRule = function(index, data)
		avm_defaults()
		if index < 1 or index > AVM_WATCH_SLOTS then return false end
		local r = avm_ensure_rule_slot(index)

		local newEnabled = data.enabled and true or false
		local newName = avm_trim(data.name or "")
		local newPartial = data.partial and true or false
		local newMaxUnit = tonumber(data.maxUnit) or 0
		local newMaxTotal = tonumber(data.maxTotal) or 0
		local newMinStack = math.max(1, math.floor(tonumber(data.minStack) or 1))
		local newMaxStack = math.max(0, math.floor(tonumber(data.maxStack) or 0))

		local changed =
			(r.enabled == true) ~= newEnabled or
			(r.name or "") ~= newName or
			(r.partial == true) ~= newPartial or
			(tonumber(r.maxUnit) or 0) ~= newMaxUnit or
			(tonumber(r.maxTotal) or 0) ~= newMaxTotal or
			(tonumber(r.minStack) or 1) ~= newMinStack or
			(tonumber(r.maxStack) or 0) ~= newMaxStack

		if not changed then
			return true
		end

		local oldName = r.name
		r.enabled = newEnabled
		r.name = newName
		r.partial = newPartial
		r.maxUnit = newMaxUnit
		r.maxTotal = newMaxTotal
		r.minStack = newMinStack
		r.maxStack = newMaxStack
		if oldName ~= r.name then AVM.boundaryCache = {} end
		avm_rule_changed(index)
		return true
	end,
	ParseMoney = avm_parse_money,
	Money = avm_money,
	SetScanner = function(on)
		AVM_DB.enabled = on and true or false
		if not AVM_DB.enabled then
			AVM_DB.live = false
			AVM.phase = "IDLE"
		else
			avm_restart_boundary()
		end
		AVM.uiGeneration = AVM.uiGeneration + 1
		return AVM_DB.enabled
	end,
	SetLive = function(on)
		if not on then
			AVM_DB.live = false
			AVM.uiGeneration = AVM.uiGeneration + 1
			return true
		end
		if not AVM.open or AVM.market.active or AVM.market.requested or
		   ((not AVM.vendor.active and not AVM.vendor.requested) and avm_rule_count() == 0) then
			AVM_DB.live = false
			AVM.uiGeneration = AVM.uiGeneration + 1
			return false
		end
		AVM_DB.live = true
		AVM.uiGeneration = AVM.uiGeneration + 1
		return true
	end,
	GetState = function()
		local rule = avm_active_rule()
		return {
			version = AVM_VERSION,
			open = AVM.open,
			enabled = AVM_DB.enabled,
			live = AVM_DB.live,
			phase = AVM.phase,
			activeRules = avm_rule_count(),
			ruleIndex = AVM.ruleIndex,
			ruleName = rule and rule.name or "",
			boundary = AVM.boundaryPage,
			scanPage = (AVM.boundaryPage or 0) + (AVM.scanOffset or 0),
			scannedPages = AVM.watchPagesScanned,
			bestUnit = AVM.bestCandidate and AVM.bestCandidate.unit or (AVM.candidate and AVM.candidate.unit or 0),
			maxUnit = rule and (tonumber(rule.maxUnit) or 0) or 0,
			maxTotal = rule and (tonumber(rule.maxTotal) or 0) or 0,
			sessionBuys = AVM.sessionBuys,
			maxSessionBuys = AVM_DB.maxSessionBuys or 1,
			sessionSpend = AVM.sessionSpend,
			generation = AVM.uiGeneration,
		}
	end,
}

local frame = CreateFrame("Frame", "AuxVmangosFrame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("AUCTION_HOUSE_SHOW")
frame:RegisterEvent("AUCTION_HOUSE_CLOSED")
frame:RegisterEvent("AUCTION_ITEM_LIST_UPDATE")
frame:RegisterEvent("CHAT_MSG_SYSTEM")
frame:RegisterEvent("UI_INFO_MESSAGE")
frame:RegisterEvent("UI_ERROR_MESSAGE")

frame:SetScript("OnEvent", function()
	if event == "ADDON_LOADED" and arg1 == "AuxVmangos" then
		avm_defaults()
		for i = 1, AVM_WATCH_SLOTS do avm_ensure_rule_slot(i) end
		-- LIVE modes are intentionally session-only; never carry an armed state across reload/login.
		AVM_DB.live = false
		AVM_DB.auxArbLive = false
		SLASH_AUXVMANGOS1 = "/avm"
		SlashCmdList["AUXVMANGOS"] = avm_slash
		avm_print("loaded " .. AVM_VERSION .. " - DRY-RUN default")
	elseif event == "AUCTION_HOUSE_SHOW" then
		AVM.open = true
		AVM.queryInFlight = false
		AVM.lastResultAt = 0
		AVM.nextQueryAt = 0
		AVM.pending = nil
		AVM.unknown = nil
		avm_restart_boundary(false)
		if AVM_DB.enabled then avm_print("AH open; cached boundary verification armed") end
	elseif event == "AUCTION_HOUSE_CLOSED" then
		AVM_DB.live = false
		AVM_DB.auxArbLive = false
		if AVM.vendor.active or AVM.vendor.requested then
			AVM.vendor.active = false
			AVM.vendor.requested = false
			AVM.vendor.stopRequested = false
			AVM.vendor.best = nil
			avm_print("VENDOR aborted: Auction House closed")
		end
		if AVM.market.active or AVM.market.requested then
			AVM.market.active = false
			AVM.market.requested = false
			AVM.market.stopRequested = false
			AVM.market.items = {}
			avm_print("MARKET aborted: Auction House closed")
		end
		AVM.open = false
		AVM.fastMarketNative = false
		AVM.fastMarketPages = 0
		AVM.fastVendorBest = nil
		AVM.fastVendorArmed = false
		AVM.auxArb.active = false
		AVM.auxArb.paused = false
		AVM.auxArb.pausePending = false
		AVM.auxArb.resumePending = false
		AVM.auxArb.deRawCandidates = {}
		AVM.auxArb.deMaterialBook = {}
		AVM.auxArb.deVerify = nil
		AVM_DB.live = false
		AVM.queryInFlight = false
		AVM.lastResultAt = 0
		AVM.nextQueryAt = 0
		AVM.pending = nil
		AVM.unknown = nil
		AVM.phase = "IDLE"
	elseif event == "AUCTION_ITEM_LIST_UPDATE" then
		avm_handle_list_update()
	elseif (event == "CHAT_MSG_SYSTEM" or event == "UI_INFO_MESSAGE" or event == "UI_ERROR_MESSAGE") and AVM.pending then
		-- Raw event evidence only. Locale-specific text is deliberately not promoted to success.
		avm_print("BUY_EVENT " .. event .. " " .. tostring(arg1))
	end
end)

frame:SetScript("OnUpdate", function()
	local now = GetTime()
	if now < AVM.nextTick then return end
	AVM.nextTick = now + AVM_TICK
	avm_tick()
end)
