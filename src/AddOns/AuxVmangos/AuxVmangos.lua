-- AuxVmangos 0.1-vmangos
-- Independent implementation for WoW 1.12.1 / vMaNGOS.
-- Default mode is DRY-RUN. LIVE purchase mode requires an explicit /avm live on.

AVM_VERSION = "0.2-vmangos-watch"
AVM_QUERY_TIMEOUT = 5.0
AVM_PENDING_TIMEOUT = 3.0
AVM_UNKNOWN_HOLD = 10.0
AVM_EVENT_SETTLE = 0.35
AVM_EXTRA_EVENT_WINDOW = 1.0
AVM_TICK = 0.05

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
	nextQueryAt = 0,
	lastResultAt = 0,
	total = 0,
	lastPage = 0,
	boundaryLow = 0,
	boundaryHigh = 0,
	boundaryPage = nil,
	scanOffset = 0,
	candidate = nil,
	revalidatePages = nil,
	revalidatePos = 0,
	pending = nil,
	unknown = nil,
	nextTick = 0,
	sessionSpend = 0,
	stats = {
		queries = 0,
		results = 0,
		extraEvents = 0,
		timeouts = 0,
		boundaryQueries = 0,
		candidates = 0,
		revalidations = 0,
		buySent = 0,
		confirmed = 0,
		failed = 0,
		unknown = 0,
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

local function avm_defaults()
	if not AVM_DB then AVM_DB = {} end
	if AVM_DB.enabled == nil then AVM_DB.enabled = false end
	if AVM_DB.live == nil then AVM_DB.live = false end
	if AVM_DB.cheapPages == nil then AVM_DB.cheapPages = 4 end
	if AVM_DB.boundaryRefresh == nil then AVM_DB.boundaryRefresh = 20 end
	if AVM_DB.maxSessionSpend == nil then AVM_DB.maxSessionSpend = 0 end
	if AVM_DB.rules == nil then AVM_DB.rules = {} end
end

local function avm_rule_matches(rule, name)
	if not rule or rule.enabled == false or not name then return false end
	if rule.partial then
		return string.find(string.lower(name), string.lower(rule.name), 1, true) ~= nil
	end
	return string.lower(name) == string.lower(rule.name)
end

local function avm_rule_count()
	return table.getn(AVM_DB.rules)
end

local function avm_active_rule()
	local n = avm_rule_count()
	if n == 0 then return nil, nil end
	if AVM.ruleIndex < 1 or AVM.ruleIndex > n then AVM.ruleIndex = 1 end
	return AVM_DB.rules[AVM.ruleIndex], AVM.ruleIndex
end

local function avm_signature(name, count, buyout, owner, quality, level)
	return tostring(name) .. "|" .. tostring(count) .. "|" .. tostring(buyout) .. "|" ..
		tostring(owner) .. "|" .. tostring(quality) .. "|" .. tostring(level)
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
	if maxUnit > 0 and unit > maxUnit then return nil end
	if maxTotal > 0 and buyout > maxTotal then return nil end
	if buyout > GetMoney() then return nil end

	local sig = avm_signature(name, count, buyout, owner, quality, level)
	if avm_recent(sig) then return nil end

	return {
		name = name,
		count = count,
		quality = quality,
		level = level,
		buyout = buyout,
		unit = unit,
		owner = owner,
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

local function avm_restart_boundary()
	AVM.boundaryLow = 0
	AVM.boundaryHigh = 0
	AVM.boundaryPage = nil
	AVM.scanOffset = 0
	AVM.candidate = nil
	AVM.revalidatePages = nil
	AVM.revalidatePos = 0

	local rule = avm_active_rule()
	if not rule then
		AVM.activeRuleName = ""
		AVM.phase = "WAIT_RULE"
		return
	end
	AVM.activeRuleName = rule.name or ""
	AVM.phase = "BOUNDARY_INIT"
end

local function avm_advance_rule()
	local n = avm_rule_count()
	if n == 0 then
		AVM.ruleIndex = 1
		avm_restart_boundary()
		return
	end
	AVM.ruleIndex = AVM.ruleIndex + 1
	if AVM.ruleIndex > n then AVM.ruleIndex = 1 end
	avm_restart_boundary()
end

local function avm_start_scan(boundary)
	AVM.boundaryPage = boundary
	AVM.scanOffset = 0
	AVM.phase = "CHEAPEST_SCAN"
	avm_print("rule='" .. tostring(AVM.activeRuleName) .. "' first buyout page=" ..
		tostring(boundary) .. "; scanning cheapest matching buyouts")
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

local function avm_pick_candidate()
	local n = GetNumAuctionItems("list")
	for i = 1, n do
		local c = avm_candidate_from_row(i)
		if c then
			c.index = i
			return c
		end
	end
	return nil
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
			local sig = avm_signature(name, count, buyout, owner, quality, level)
			if sig == c.signature then
				c.index = i
				c.revalidatedAt = GetTime()
				AVM.stats.revalidations = AVM.stats.revalidations + 1

				if not AVM_DB.live then
					AVM.recent[c.signature] = GetTime() + 3
					avm_print("DRYRUN " .. c.count .. "x " .. c.name .. " total=" ..
						avm_money(c.buyout) .. " unit=" .. avm_money(c.unit) ..
						" seller=" .. tostring(c.owner))
					AVM.candidate = nil
					AVM.scanOffset = AVM.scanOffset + 1
					AVM.phase = "CHEAPEST_SCAN"
					return
				end

				if AVM.unknown then
					AVM.phase = "UNKNOWN_HOLD"
					return
				end

				local maxSpend = tonumber(AVM_DB.maxSessionSpend) or 0
				if maxSpend > 0 and AVM.sessionSpend + c.buyout > maxSpend then
					avm_print("session spend limit blocks " .. c.name)
					AVM.recent[c.signature] = GetTime() + 10
					AVM.candidate = nil
					AVM.phase = "CHEAPEST_SCAN"
					return
				end

				local before = GetMoney()
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
	AVM.recent[c.signature] = GetTime() + 2
	avm_print("revalidate miss: " .. c.name .. " - stale/raced candidate")
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
	avm_print("RESULT q" .. AVM.querySeq .. " " .. kind .. " rule='" ..
		tostring(AVM.queryName) .. "' page=" .. page ..
		" rows=" .. rows .. "/" .. total .. " positive=" .. tostring(positive) ..
		" latency=" .. string.format("%.3f", latency) .. "s")

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
			AVM.phase = "BOUNDARY_INIT"
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
			AVM.phase = "BOUNDARY_INIT"
			return
		end
		if AVM.boundaryLow == AVM.boundaryHigh and page == AVM.boundaryLow then
			if positive then
				avm_start_scan(page)
			else
				AVM.phase = "BOUNDARY_INIT"
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
			avm_restart_boundary()
		end
		return
	end

	if kind == "CHEAPEST_SCAN" then
		local candidate = avm_pick_candidate()
		if candidate then
			AVM.stats.candidates = AVM.stats.candidates + 1
			AVM.candidate = candidate
			avm_prepare_revalidate(candidate)
			AVM.phase = "REVALIDATE"
			return
		end

		AVM.scanOffset = AVM.scanOffset + 1
		if AVM.scanOffset >= (tonumber(AVM_DB.cheapPages) or 4) or
		   AVM.boundaryPage + AVM.scanOffset > AVM.lastPage then
			avm_advance_rule()
		else
			AVM.phase = "CHEAPEST_SCAN"
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
		if AVM.open and AVM_DB.enabled and AVM.lastResultAt > 0 and
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
			AVM.recent[p.candidate.signature] = now + 15
			avm_print("CONFIRMED " .. p.candidate.name .. " " .. avm_money(p.candidate.buyout))
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
			avm_print("CONFIRMED_LATE " .. u.candidate.name .. " " .. avm_money(u.candidate.buyout))
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
	if not AVM.open or not AVM_DB.enabled then return end
	local now = GetTime()

	if avm_tick_pending(now) then return end

	if AVM.queryInFlight then
		if now - AVM.querySentAt >= AVM_QUERY_TIMEOUT then
			AVM.stats.timeouts = AVM.stats.timeouts + 1
			avm_print("QUERY_TIMEOUT q" .. AVM.querySeq .. " " .. AVM.queryKind)
			AVM.queryInFlight = false
			if AVM.queryKind == "REVALIDATE" then AVM.candidate = nil end
			avm_restart_boundary()
		end
		return
	end

	if AVM.phase == "IDLE" or AVM.phase == "WAIT_RULE" then
		avm_restart_boundary()
	end

	local rule = avm_active_rule()
	if not rule then return end
	local queryName = rule.name or ""

	if AVM.phase == "BOUNDARY_INIT" then
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
		" rule=" .. tostring(AVM.ruleIndex) .. "/" .. tostring(avm_rule_count()) ..
		" '" .. tostring(rule and rule.name or "") .. "'" ..
		" boundary=" .. tostring(AVM.boundaryPage) ..
		" spend=" .. avm_money(AVM.sessionSpend))
	avm_print("queries=" .. AVM.stats.queries ..
		" results=" .. AVM.stats.results ..
		" extraEvents=" .. AVM.stats.extraEvents ..
		" timeouts=" .. AVM.stats.timeouts ..
		" candidates=" .. AVM.stats.candidates ..
		" revalidations=" .. AVM.stats.revalidations ..
		" sent=" .. AVM.stats.buySent ..
		" confirmed=" .. AVM.stats.confirmed ..
		" failed=" .. AVM.stats.failed ..
		" unknown=" .. AVM.stats.unknown)
end

local function avm_list_rules()
	if table.getn(AVM_DB.rules) == 0 then
		avm_print("watchlist empty")
		return
	end
	for i = 1, table.getn(AVM_DB.rules) do
		local r = AVM_DB.rules[i]
		avm_print(i .. ": " .. (r.partial and "partial " or "exact ") .. r.name ..
			" maxUnit=" .. avm_money(r.maxUnit or 0) ..
			" maxTotal=" .. avm_money(r.maxTotal or 0) ..
			" stack=" .. tostring(r.minStack or 1) .. "-" .. tostring(r.maxStack or 0))
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
		avm_print("invalid rule")
		return
	end
	table.insert(AVM_DB.rules, {
		name = name,
		partial = (matchType == "partial"),
		maxUnit = maxUnit,
		maxTotal = maxTotal,
		minStack = minStack,
		maxStack = maxStack,
		enabled = true,
	})
	avm_print("rule added: " .. name .. " <= " .. avm_money(maxUnit) .. "/unit")
	avm_restart_boundary()
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
		AVM.queryInFlight = false
		AVM.phase = "IDLE"
		avm_print("scanner OFF")
	elseif cmd == "live" then
		if string.lower(avm_trim(rest)) == "on" then
			AVM_DB.live = true
			avm_print("LIVE ON - qualifying revalidated auctions may be bought")
		else
			AVM_DB.live = false
			avm_print("LIVE OFF - dry-run only")
		end
	elseif cmd == "add" then
		avm_add_rule(rest)
	elseif cmd == "del" then
		local n = tonumber(avm_trim(rest))
		if n and AVM_DB.rules[n] then
			local old = AVM_DB.rules[n].name
			table.remove(AVM_DB.rules, n)
			if AVM.ruleIndex > table.getn(AVM_DB.rules) then AVM.ruleIndex = 1 end
			avm_print("rule removed: " .. old)
			avm_restart_boundary()
		else
			avm_print("invalid rule index")
		end
	elseif cmd == "list" then
		avm_list_rules()
	elseif cmd == "pages" then
		local n = tonumber(avm_trim(rest))
		if n and n >= 1 and n <= 50 then
			AVM_DB.cheapPages = n
			avm_print("cheap pages=" .. n)
		else
			avm_print("pages must be 1..50")
		end
	elseif cmd == "budget" then
		local n = avm_parse_money(avm_trim(rest))
		if n then
			AVM_DB.maxSessionSpend = n
			avm_print("session budget=" .. avm_money(n) .. " (0 = unlimited)")
		else
			avm_print("invalid money value")
		end
	elseif cmd == "reset" then
		AVM.sessionSpend = 0
		AVM.recent = {}
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
	else
		avm_print("/avm on|off | live on|off | status | list | del N | pages N | budget 100g")
		avm_print("/avm add exact;Black Lotus;60g;120g;1;20")
	end
end

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
		avm_restart_boundary()
		if AVM_DB.enabled then avm_print("AH open; boundary search armed") end
	elseif event == "AUCTION_HOUSE_CLOSED" then
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
