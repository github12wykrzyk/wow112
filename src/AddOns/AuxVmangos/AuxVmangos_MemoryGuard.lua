-- AuxVmangos runtime memory guard for WoW 1.12.1 / Lua 5.0.
-- Keeps MARKET history functionally available while avoiding thousands of
-- permanently expanded per-item history arrays after login/reload.

AVM_MEMORY_GUARD_VERSION = "1.0-market-history-compact"

local GUARD = {
	loginDue = nil,
	lastSweep = 0,
	lastCompactRows = 0,
	lastCompactEntries = 0,
	lastGcKb = 0,
}

local ROW_MT = {}

local function split_plain(value, sep)
	local out = {}
	local text = tostring(value or "")
	if text == "" then return out end
	local start = 1
	while true do
		local a, b = string.find(text, sep, start, true)
		if not a then
			table.insert(out, string.sub(text, start))
			break
		end
		table.insert(out, string.sub(text, start, a - 1))
		start = b + 1
	end
	return out
end

ROW_MT.__index = function(row, key)
	if key ~= "history" then return nil end
	local packed = rawget(row, "_avmHistoryPacked")
	local hist = {}
	if packed and packed ~= "" then
		hist = split_plain(packed, ";")
	end
	rawset(row, "history", hist)
	return hist
end

local function scrub_diag_saved_copies()
	if not AVM_DB or type(AVM_DB.diag) ~= "table" then return end
	local d = AVM_DB.diag
	-- These are authoritative at top level. SavedVariables serializes repeated
	-- table references as repeated table literals, so keeping the diagnostic
	-- aliases needlessly inflates the next login/reload working set.
	d.purchaseHistory = nil
	d.saleHistory = nil
	d.bidHistory = nil
	if type(d.autoSell) == "table" then d.autoSell.history = nil end
end

local function market_busy()
	if not AVM then return false end
	local m = AVM.market or {}
	if m.active or m.processing or m.requested or m.manualRequested then return true end
	local a = AVM.auxArb or {}
	if a.active or a.paused or a.resumePending or a.revalidateCurrent or a.flipVerify then return true end
	if AVM.queryInFlight or AVM.pending or AVM.unknown or AVM.bidPending then return true end
	return false
end

local function compact_market_history(reason, force)
	if not AVM or type(AVM.marketDB) ~= "table" then return false end
	if not force and market_busy() then return false end

	local rows = 0
	local entries = 0
	local changed = false
	for _, row in pairs(AVM.marketDB) do
		if type(row) == "table" then
			rows = rows + 1
			local hist = rawget(row, "history")
			if type(hist) == "table" then
				entries = entries + table.getn(hist)
				rawset(row, "_avmHistoryPacked", table.concat(hist, ";"))
				rawset(row, "history", nil)
				changed = true
			elseif rawget(row, "_avmHistoryPacked") == nil then
				rawset(row, "_avmHistoryPacked", "")
			end
			if getmetatable(row) ~= ROW_MT then setmetatable(row, ROW_MT) end
		end
	end

	GUARD.lastCompactRows = rows
	GUARD.lastCompactEntries = entries
	if changed then
		if collectgarbage then pcall(collectgarbage) end
		if gcinfo then GUARD.lastGcKb = gcinfo() end
	end
	return changed
end

local function status()
	local kb = gcinfo and gcinfo() or 0
	local msg = "MEMGUARD " .. AVM_MEMORY_GUARD_VERSION ..
		" rows=" .. tostring(GUARD.lastCompactRows) ..
		" entries=" .. tostring(GUARD.lastCompactEntries) ..
		" luaKB=" .. tostring(kb)
	if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage("|cff60ff00[AVM]|r " .. msg) end
end

-- Drop bulky serialized diagnostic copies immediately during addon load, before
-- PLAYER_LOGIN rebuilds normal runtime diagnostic aliases if they are needed.
scrub_diag_saved_copies()

local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("PLAYER_LOGOUT")
f:RegisterEvent("AUCTION_HOUSE_CLOSED")

f:SetScript("OnEvent", function()
	if event == "PLAYER_LOGIN" then
		-- Main AuxVmangos initializes/unpacks MARKET on PLAYER_LOGIN. Defer this
		-- guard by a fraction of a second so we compact after that initialization.
		GUARD.loginDue = (GetTime() or 0) + 0.50
	elseif event == "AUCTION_HOUSE_CLOSED" then
		compact_market_history("ah-closed", true)
		scrub_diag_saved_copies()
	elseif event == "PLAYER_LOGOUT" then
		compact_market_history("logout", true)
		scrub_diag_saved_copies()
	end
end)

f:SetScript("OnUpdate", function()
	local now = GetTime() or 0
	if GUARD.loginDue and now >= GUARD.loginDue then
		GUARD.loginDue = nil
		compact_market_history("login", true)
		scrub_diag_saved_copies()
		status()
	end
	if now - (GUARD.lastSweep or 0) >= 2.0 then
		GUARD.lastSweep = now
		if not market_busy() then compact_market_history("idle", false) end
	end
end)

SLASH_AVMMEM1 = "/avmmem"
SlashCmdList["AVMMEM"] = function(msg)
	local cmd = string.lower(tostring(msg or ""))
	if cmd == "compact" then
		compact_market_history("manual", true)
		scrub_diag_saved_copies()
	end
	status()
end
