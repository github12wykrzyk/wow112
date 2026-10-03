-- AuxVmangos DE valuation and own-auction safety guard.
-- Loaded after AuxVmangos.lua so it can tighten the live DE policy without
-- duplicating the large scanner implementation.
--
-- Problems addressed:
-- 1) a thin/temporarily inflated material book could produce a very high DE value;
-- 2) the player's own material auctions could feed the exact live DE material book;
-- 3) the player's own equipment auction could survive into AUX_ARB DE revalidation
--    and reach PlaceAuctionBid(), which the server rejects as a self-bid;
-- 4) a genuinely deep but temporarily absurd live material market can still be
--    many multiples above AUX history, making DE expected value economically fake.

AVM_DE_PRICE_GUARD_VERSION = 4
AVM_DE_PRICE_GUARD_MIN_DEPTH = 10
AVM_DE_PRICE_GUARD_EXACT_TTL = 2
AVM_DE_PRICE_GUARD_HISTORY_CAP_PCT = 200
AVM_DE_PRICE_GUARD_HISTORY_MIN_POINTS = 2

local AVM_DE_PRICE_GUARD_PRINTED = false
local AVM_DE_PRICE_GUARD_OLD_SLASH = nil
local AVM_DE_PRICE_GUARD_SLASH = nil
local AVM_DE_PRICE_GUARD_ORIG_GET_AUCTION_ITEM_INFO = nil
local AVM_DE_PRICE_GUARD_GET_AUCTION_ITEM_INFO = nil
local AVM_DE_PRICE_GUARD_ORIG_AUXARB_AUCTION = nil
local AVM_DE_PRICE_GUARD_AUXARB_AUCTION = nil
local AVM_DE_PRICE_GUARD_HISTORY_OK, AVM_DE_PRICE_GUARD_HISTORY = pcall(require, "aux.core.history")

local function avm_de_price_guard_is_player_owner(owner)
	if not owner or owner == "" or type(UnitName) ~= "function" then return false end
	local player = UnitName("player")
	if not player or player == "" then return false end
	return string.lower(tostring(owner)) == string.lower(tostring(player))
end

local function avm_de_price_guard_clear_caches()
	if type(AVM_DB) == "table" then
		AVM_DB.deWarmMaterialBook = {}
	end
	if type(AVM) == "table" and type(AVM.auxArb) == "table" then
		AVM.auxArb.deExactCache = {}
		AVM.auxArb.deVerifyRejectFingerprint = {}
		AVM.auxArb.dePricingBook = {}
		AVM.auxArb.deMaterialBook = {}
	end
end

local function avm_de_price_guard_is_auxarb_candidate(c)
	if type(c) ~= "table" then return false end
	local mode = tostring(c.mode or "")
	return mode == "auxarb_de" or mode == "auxarb_vendor" or
		mode == "auxarb_flip" or mode == "auxarb_stack"
end

local function avm_de_price_guard_hide_own_list_row(listType, owner)
	if listType ~= "list" or not avm_de_price_guard_is_player_owner(owner) then return false end
	if type(AVM) ~= "table" then return false end

	local phase = tostring(AVM.phase or "")
	-- Exact DE material valuation must never use our own auctions as market depth.
	if phase == "DE_MAT_REVALIDATE" then return true end

	-- Exact candidate revalidation scans the filtered result page and then calls
	-- PlaceAuctionBid on the first matching signature. Core signatures deliberately
	-- ignore owner, so an identical self-listed auction can otherwise be selected.
	-- Hiding only its buyout in this narrow internal phase makes core skip that row
	-- and continue looking for a genuinely purchasable listing on the same page.
	if phase == "REVALIDATE" and avm_de_price_guard_is_auxarb_candidate(AVM.candidate) then
		return true
	end
	return false
end

local function avm_de_price_guard_history_cap(listType, index, count, buyoutPrice)
	if listType ~= "list" or type(AVM) ~= "table" then return buyoutPrice end
	if tostring(AVM.phase or "") ~= "DE_MAT_REVALIDATE" then return buyoutPrice end
	count = tonumber(count) or 0
	buyoutPrice = tonumber(buyoutPrice) or 0
	if count <= 0 or buyoutPrice <= 0 then return buyoutPrice end
	if not AVM_DE_PRICE_GUARD_HISTORY_OK or not AVM_DE_PRICE_GUARD_HISTORY or
	   type(AVM_DE_PRICE_GUARD_HISTORY.value) ~= "function" then
		return buyoutPrice
	end
	if type(GetAuctionItemLink) ~= "function" then return buyoutPrice end

	local link = GetAuctionItemLink(listType, index)
	if not link then return buyoutPrice end
	local _, _, itemIdText = string.find(tostring(link), "item:(%d+):")
	local itemId = tonumber(itemIdText)
	if not itemId then return buyoutPrice end

	local key = tostring(itemId) .. ":0"
	local okValue, histValue = pcall(AVM_DE_PRICE_GUARD_HISTORY.value, key)
	histValue = okValue and tonumber(histValue) or 0
	if histValue <= 0 then return buyoutPrice end

	local points = 0
	if type(AVM_DE_PRICE_GUARD_HISTORY.data_points) == "function" then
		local okPoints, rows = pcall(AVM_DE_PRICE_GUARD_HISTORY.data_points, key)
		if okPoints and type(rows) == "table" then points = table.getn(rows) end
	end
	if points < AVM_DE_PRICE_GUARD_HISTORY_MIN_POINTS then return buyoutPrice end

	local liveUnit = math.floor(buyoutPrice / count)
	local capUnit = math.floor(histValue * AVM_DE_PRICE_GUARD_HISTORY_CAP_PCT / 100)
	if capUnit <= 0 or liveUnit <= capUnit then return buyoutPrice end

	if type(AVM_DB) == "table" then
		AVM_DB.deHistoryCapHits = (tonumber(AVM_DB.deHistoryCapHits) or 0) + 1
		AVM_DB.deHistoryCapLast = {
			itemId = itemId,
			liveUnit = liveUnit,
			historyUnit = math.floor(histValue),
			capUnit = capUnit,
			points = points,
		}
	end
	return capUnit * count
end

local function avm_de_price_guard_wrap_auction_info()
	if type(GetAuctionItemInfo) ~= "function" then return end
	if AVM_DE_PRICE_GUARD_GET_AUCTION_ITEM_INFO and GetAuctionItemInfo == AVM_DE_PRICE_GUARD_GET_AUCTION_ITEM_INFO then return end

	AVM_DE_PRICE_GUARD_ORIG_GET_AUCTION_ITEM_INFO = GetAuctionItemInfo
	AVM_DE_PRICE_GUARD_GET_AUCTION_ITEM_INFO = function(listType, index)
		local name, texture, count, quality, canUse, level, minBid, minIncrement,
			buyoutPrice, bidAmount, highBidder, owner, saleStatus =
			AVM_DE_PRICE_GUARD_ORIG_GET_AUCTION_ITEM_INFO(listType, index)

		-- Keep the physical row intact for normal AH UI and the dedicated owner scan,
		-- but make a self-owned row economically invisible to AVM internal valuation /
		-- revalidation phases where buying it would be impossible.
		if avm_de_price_guard_hide_own_list_row(listType, owner) then
			buyoutPrice = 0
		else
			-- During exact DE material verification use current live depth, but do not
			-- let a temporary market dislocation value a shard/dust at more than 200%
			-- of AUX history once at least two history points exist. The existing 25%
			-- DE safety margin is applied later by core, so this remains conservative
			-- without hard-rejecting an item whose other disenchant outputs are valid.
			buyoutPrice = avm_de_price_guard_history_cap(listType, index, count, buyoutPrice)
		end

		return name, texture, count, quality, canUse, level, minBid, minIncrement,
			buyoutPrice, bidAmount, highBidder, owner, saleStatus
	end
	GetAuctionItemInfo = AVM_DE_PRICE_GUARD_GET_AUCTION_ITEM_INFO
end

local function avm_de_price_guard_wrap_auxarb_auction()
	local current = AVM_AuxArbAuction
	if type(current) ~= "function" then return end
	if AVM_DE_PRICE_GUARD_AUXARB_AUCTION and current == AVM_DE_PRICE_GUARD_AUXARB_AUCTION then return end

	AVM_DE_PRICE_GUARD_ORIG_AUXARB_AUCTION = current
	AVM_DE_PRICE_GUARD_AUXARB_AUCTION = function(record)
		-- AUX Search can legitimately return the player's own listings. They are
		-- useful to the dedicated owner/exposure scan but are never purchasable, so
		-- do not let them enter vendor/DE/flip/stack candidate books at discovery.
		if record and avm_de_price_guard_is_player_owner(record.owner) then
			if type(AVM_DB) == "table" then
				AVM_DB.deOwnAuctionSkips = (tonumber(AVM_DB.deOwnAuctionSkips) or 0) + 1
			end
			return
		end
		return AVM_DE_PRICE_GUARD_ORIG_AUXARB_AUCTION(record)
	end
	AVM_AuxArbAuction = AVM_DE_PRICE_GUARD_AUXARB_AUCTION
end

local function avm_de_price_guard_apply(verbose)
	-- Core code reads this global at cache lookup time, so changing it here
	-- immediately shortens the reuse window for every later DE verification.
	AVM_DE_EXACT_CACHE_MAX_AGE = AVM_DE_PRICE_GUARD_EXACT_TTL

	if type(AVM_DB) ~= "table" then return end

	local oldDepth = tonumber(AVM_DB.deDepthUnits) or 0
	local oldVersion = tonumber(AVM_DB.dePriceGuardVersion) or 0
	local changed = false

	if oldDepth < AVM_DE_PRICE_GUARD_MIN_DEPTH then
		AVM_DB.deDepthUnits = AVM_DE_PRICE_GUARD_MIN_DEPTH
		changed = true
	end

	-- Preserve the existing 25% safety policy if the SavedVariables entry is
	-- missing/corrupt, but do not silently make a user's stricter margin looser.
	local margin = tonumber(AVM_DB.deSafetyMarginPct)
	if not margin or margin < 25 then
		AVM_DB.deSafetyMarginPct = 25
		changed = true
	end

	if oldVersion ~= AVM_DE_PRICE_GUARD_VERSION or changed then
		avm_de_price_guard_clear_caches()
	end

	AVM_DB.dePriceGuardVersion = AVM_DE_PRICE_GUARD_VERSION
	AVM_DB.dePriceGuardMinDepth = AVM_DE_PRICE_GUARD_MIN_DEPTH
	AVM_DB.dePriceGuardExactTtl = AVM_DE_PRICE_GUARD_EXACT_TTL
	AVM_DB.deHistoryCapPct = AVM_DE_PRICE_GUARD_HISTORY_CAP_PCT
	AVM_DB.deHistoryCapMinPoints = AVM_DE_PRICE_GUARD_HISTORY_MIN_POINTS
	AVM_DB.deOwnAuctionFilter = true
	if AVM_DB.deOwnAuctionSkips == nil then AVM_DB.deOwnAuctionSkips = 0 end
	if AVM_DB.deHistoryCapHits == nil then AVM_DB.deHistoryCapHits = 0 end

	if verbose and not AVM_DE_PRICE_GUARD_PRINTED and DEFAULT_CHAT_FRAME then
		AVM_DE_PRICE_GUARD_PRINTED = true
		DEFAULT_CHAT_FRAME:AddMessage(
			"|cff33ff99AuxVmangos DE guard|r: depth >= " ..
			tostring(AVM_DE_PRICE_GUARD_MIN_DEPTH) ..
			", exact cache " .. tostring(AVM_DE_PRICE_GUARD_EXACT_TTL) ..
			"s, hist cap " .. tostring(AVM_DE_PRICE_GUARD_HISTORY_CAP_PCT) ..
			"%, own auctions excluded"
		)
	end
end

local function avm_de_price_guard_wrap_slash()
	if not SlashCmdList then return end
	local current = SlashCmdList["AUXVMANGOS"]
	if type(current) ~= "function" then return end
	if current == AVM_DE_PRICE_GUARD_SLASH then return end

	AVM_DE_PRICE_GUARD_OLD_SLASH = current
	AVM_DE_PRICE_GUARD_SLASH = function(msg)
		AVM_DE_PRICE_GUARD_OLD_SLASH(msg)
		local before = type(AVM_DB) == "table" and (tonumber(AVM_DB.deDepthUnits) or 0) or 0
		avm_de_price_guard_apply(false)
		if before > 0 and before < AVM_DE_PRICE_GUARD_MIN_DEPTH and DEFAULT_CHAT_FRAME then
			DEFAULT_CHAT_FRAME:AddMessage(
				"|cffffcc00AuxVmangos DE guard|r: dedepth below " ..
				tostring(AVM_DE_PRICE_GUARD_MIN_DEPTH) .. " is blocked for safety."
			)
		end
	end
	SlashCmdList["AUXVMANGOS"] = AVM_DE_PRICE_GUARD_SLASH
end

-- SavedVariables are normally available before addon files execute, but apply
-- again on startup so the guard remains correct regardless of 1.12 event order.
avm_de_price_guard_wrap_auction_info()
avm_de_price_guard_wrap_auxarb_auction()
avm_de_price_guard_apply(false)

local guard = CreateFrame("Frame")
guard:RegisterEvent("VARIABLES_LOADED")
guard:RegisterEvent("PLAYER_LOGIN")
guard:SetScript("OnEvent", function()
	avm_de_price_guard_wrap_auction_info()
	avm_de_price_guard_wrap_auxarb_auction()
	avm_de_price_guard_apply(event == "PLAYER_LOGIN")
	avm_de_price_guard_wrap_slash()
end)
