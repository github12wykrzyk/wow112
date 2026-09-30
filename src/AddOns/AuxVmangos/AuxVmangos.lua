-- AuxVmangos 0.1-vmangos
-- Independent implementation for WoW 1.12.1 / vMaNGOS.
-- Default mode is DRY-RUN. LIVE purchase mode requires an explicit /avm live on.

AVM_VERSION = "0.8-vmangos-watchlist"
AVM_QUERY_TIMEOUT = 5.0
AVM_PENDING_TIMEOUT = 3.0
AVM_UNKNOWN_HOLD = 10.0
AVM_EVENT_SETTLE = 0.35
AVM_EXTRA_EVENT_WINDOW = 1.0
AVM_TICK = 0.05
AVM_WATCH_SLOTS = 16
AVM_WATCH_MAX_PAGES = 100

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
	candidate = nil,
	revalidatePages = nil,
	revalidatePos = 0,
	pending = nil,
	unknown = nil,
	nextTick = 0,
	sessionSpend = 0,
	sessionBuys = 0,
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
	},
	recent = {},
}

local function avm_print(msg)
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

local function avm_prepare_revalidate(c)
	local pages = {}
	local seen = {}
	local function add_page(p)
		if p and p >= 0 and p <= AVM.lastPage and not seen[p] then
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
	if AVM.market.active or AVM.market.requested or AVM_DB.live or AVM.pending or AVM.unknown then return false end
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
		" auto=" .. tostring(AVM_DB.marketAutoMinutes or 0) .. "m")
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

local function avm_market_slash(rest)
	rest = avm_trim(rest or "")
	local _,_,sub,arg = string.find(rest, "^(%S+)%s*(.*)$")
	sub = string.lower(sub or "status")
	arg = arg or ""
	if sub == "start" then
		avm_market_request_start()
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

local function avm_revalidate_candidate()
	local c = AVM.candidate
	if not c then
		avm_restart_boundary()
		return
	end

	local n = GetNumAuctionItems("list")
	for i = 1, n do
		local name,_,count,quality,_,level,_,_,buyout,_,_,owner = GetAuctionItemInfo("list", i)
		if name and buyout and buyout > 0 then
			local itemKey = avm_item_link_key(i)
			local sig = avm_signature(name, count, buyout, owner, quality, level, itemKey)
			if sig == c.signature then
				c.index = i
				c.revalidatedAt = GetTime()
				AVM.stats.revalidations = AVM.stats.revalidations + 1

				if not AVM_DB.live then
					AVM.recent[c.signature] = GetTime() + 3
					local wallet = " affordable=true"
					if not c.affordable then
						wallet = " affordable=false missing=" .. avm_money(c.missing or 0)
					end
					avm_print("DRYRUN_BEST " .. c.count .. "x " .. c.name .. " total=" ..
						avm_money(c.buyout) .. " unit=" .. avm_money(c.unit) ..
						" seller=" .. tostring(c.owner) .. wallet)
					AVM.candidate = nil
					AVM.revalidatePages = nil
					AVM.revalidatePos = 0
					avm_advance_rule()
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
					AVM.candidate = nil
					AVM.revalidatePages = nil
					AVM.revalidatePos = 0
					avm_restart_boundary()
					return
				end

				local maxBuys = tonumber(AVM_DB.maxSessionBuys) or 1
				if maxBuys > 0 and AVM.sessionBuys >= maxBuys then
					AVM_DB.live = false
					avm_print("LIVE_AUTO_OFF purchase limit reached (" ..
						tostring(AVM.sessionBuys) .. "/" .. tostring(maxBuys) .. ")")
					AVM.candidate = nil
					AVM.revalidatePages = nil
					AVM.revalidatePos = 0
					avm_restart_boundary()
					return
				end

				local maxSpend = tonumber(AVM_DB.maxSessionSpend) or 0
				if maxSpend > 0 and AVM.sessionSpend + c.buyout > maxSpend then
					avm_print("session spend limit blocks " .. c.name)
					AVM.recent[c.signature] = GetTime() + 10
					AVM.candidate = nil
					AVM.revalidatePages = nil
					AVM.revalidatePos = 0
					avm_restart_boundary()
					return
				end

				local before = GetMoney()
				if c.buyout > before then
					AVM.stats.walletBlocks = AVM.stats.walletBlocks + 1
					avm_print("LIVE_BLOCKED wallet changed before buy " .. c.name)
					AVM.candidate = nil
					AVM.revalidatePages = nil
					AVM.revalidatePos = 0
					avm_restart_boundary()
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
				avm_print("BUY_SENT " .. c.count .. "x " .. c.name .. " " .. avm_money(c.buyout))
				return
			end
		end
	end

	if AVM.revalidatePages and AVM.revalidatePos < table.getn(AVM.revalidatePages) then
		AVM.revalidatePos = AVM.revalidatePos + 1
		AVM.phase = "REVALIDATE"
		return
	end

	AVM.stats.failed = AVM.stats.failed + 1
	AVM.stats.watchRaces = AVM.stats.watchRaces + 1
	AVM.watchRaces = AVM.watchRaces + 1
	AVM.recent[c.signature] = GetTime() + 2
	avm_print("WATCH_RACE " .. c.name .. " - best offer moved/disappeared before revalidate")
	AVM.candidate = nil
	AVM.revalidatePages = nil
	AVM.revalidatePos = 0
	avm_restart_boundary()
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
	if not isMarket or kind ~= "MARKET_SCAN" then
		avm_print("RESULT q" .. AVM.querySeq .. " " .. kind .. " rule='" ..
			tostring(AVM.queryName) .. "' page=" .. page ..
			" rows=" .. rows .. "/" .. total .. " positive=" .. tostring(positive) ..
			" latency=" .. string.format("%.3f", latency) .. "s")
	end
	if isMarket then
		avm_market_accept(kind, page, total, positive)
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
		local canContinue = nextPage <= AVM.lastPage and AVM.watchPagesScanned < cap
		if canContinue then
			AVM.scanOffset = AVM.scanOffset + 1
			AVM.phase = "CHEAPEST_SCAN"
			return
		end

		if nextPage <= AVM.lastPage and AVM.watchPagesScanned >= cap then
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
		if AVM.open and (AVM_DB.enabled or AVM.market.active) and AVM.lastResultAt > 0 and
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
			avm_print("CONFIRMED " .. p.candidate.name .. " " .. avm_money(p.candidate.buyout))
			local maxBuys = tonumber(AVM_DB.maxSessionBuys) or 1
			if maxBuys > 0 and AVM.sessionBuys >= maxBuys then
				AVM_DB.live = false
				avm_print("LIVE_AUTO_OFF purchase limit reached (" ..
					tostring(AVM.sessionBuys) .. "/" .. tostring(maxBuys) .. ")")
			end
			AVM.pending = nil
			avm_restart_boundary()
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
			avm_print("CONFIRMED_LATE " .. u.candidate.name .. " " .. avm_money(u.candidate.buyout))
			local maxBuys = tonumber(AVM_DB.maxSessionBuys) or 1
			if maxBuys > 0 and AVM.sessionBuys >= maxBuys then
				AVM_DB.live = false
				avm_print("LIVE_AUTO_OFF purchase limit reached (" ..
					tostring(AVM.sessionBuys) .. "/" .. tostring(maxBuys) .. ")")
			end
			AVM.unknown = nil
			avm_restart_boundary()
			return true
		end
		if now >= u.untilTime then
			avm_print("UNKNOWN_RELEASE " .. u.candidate.name .. " - reservation expired; rescan")
			AVM.unknown = nil
			avm_restart_boundary()
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
			AVM.queryInFlight = false
			if marketQuery and AVM.market.active then
				AVM.stats.marketTimeouts = AVM.stats.marketTimeouts + 1
				AVM.market.consecutiveTimeouts = AVM.market.consecutiveTimeouts + 1
				if AVM.market.consecutiveTimeouts >= 3 then
					avm_market_finish(false, "3 consecutive query timeouts")
				end
			else
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

	if AVM.rulesDirty and not AVM.queryInFlight and not AVM.pending and not AVM.unknown then
		AVM.rulesDirty = false
		avm_restart_boundary(true)
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
		" watchRaces=" .. AVM.stats.watchRaces ..
		" revalidations=" .. AVM.stats.revalidations ..
		" sent=" .. AVM.stats.buySent ..
		" confirmed=" .. AVM.stats.confirmed ..
		" failed=" .. AVM.stats.failed ..
		" unknown=" .. AVM.stats.unknown ..
		" marketScans=" .. AVM.stats.marketScans ..
		" marketPages=" .. AVM.stats.marketPages ..
		" marketTimeouts=" .. AVM.stats.marketTimeouts)
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
		avm_print("scanner/LIVE OFF")
	elseif cmd == "live" then
		if string.lower(avm_trim(rest)) == "on" then
			if not AVM.open then
				avm_print("LIVE requires open Auction House")
			elseif AVM.market.active or AVM.market.requested then
				avm_print("LIVE blocked while MARKET owns/requests the AH scheduler")
			elseif avm_rule_count() == 0 then
				avm_print("LIVE requires at least one active rule with Item + maxUnit")
			else
				AVM_DB.live = true
				avm_print("LIVE ON - only full-scan WATCH_BEST offers may be bought")
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
	elseif cmd == "maxbuys" then
		local n = tonumber(avm_trim(rest))
		if n and n >= 1 and n <= 100 then
			AVM_DB.maxSessionBuys = n
			avm_print("session live purchase limit=" .. tostring(n))
		else
			avm_print("maxbuys must be 1..100")
		end
	elseif cmd == "reset" then
		if AVM.market.active or AVM.market.requested or AVM.pending or AVM.unknown then
			avm_print("reset blocked while MARKET or purchase transaction is active")
			return
		end
		AVM_DB.live = false
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
		local oldName = r.name
		r.enabled = data.enabled and true or false
		r.name = avm_trim(data.name or "")
		r.partial = data.partial and true or false
		r.maxUnit = tonumber(data.maxUnit) or 0
		r.maxTotal = tonumber(data.maxTotal) or 0
		r.minStack = math.max(1, math.floor(tonumber(data.minStack) or 1))
		r.maxStack = math.max(0, math.floor(tonumber(data.maxStack) or 0))
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
		if not AVM.open or AVM.market.active or AVM.market.requested or avm_rule_count() == 0 then
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
		-- LIVE is intentionally session-only; never carry an armed state across reload/login.
		AVM_DB.live = false
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
		if AVM.market.active or AVM.market.requested then
			AVM.market.active = false
			AVM.market.requested = false
			AVM.market.stopRequested = false
			AVM.market.items = {}
			avm_print("MARKET aborted: Auction House closed")
		end
		AVM.open = false
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
