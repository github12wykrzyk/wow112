-- AuxVmangos DE valuation safety guard.
-- Loaded after AuxVmangos.lua so it can tighten the live material valuation policy
-- without duplicating the large scanner implementation.
--
-- Problems addressed:
-- 1) a thin/temporarily inflated material book could produce a very high DE value;
-- 2) the player's own material auctions could feed the exact live DE material book
--    and create a self-referential valuation loop.

AVM_DE_PRICE_GUARD_VERSION = 2
AVM_DE_PRICE_GUARD_MIN_DEPTH = 10
AVM_DE_PRICE_GUARD_EXACT_TTL = 2

local AVM_DE_PRICE_GUARD_PRINTED = false
local AVM_DE_PRICE_GUARD_OLD_SLASH = nil
local AVM_DE_PRICE_GUARD_SLASH = nil
local AVM_DE_PRICE_GUARD_ORIG_GET_AUCTION_ITEM_INFO = nil
local AVM_DE_PRICE_GUARD_GET_AUCTION_ITEM_INFO = nil

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

local function avm_de_price_guard_is_own_de_material_row(listType, owner)
	if listType ~= "list" then return false end
	if type(AVM) ~= "table" or tostring(AVM.phase or "") ~= "DE_MAT_REVALIDATE" then return false end
	if not owner or owner == "" or type(UnitName) ~= "function" then return false end
	local player = UnitName("player")
	return player and player ~= "" and owner == player
end

local function avm_de_price_guard_wrap_auction_info()
	if type(GetAuctionItemInfo) ~= "function" then return end
	if AVM_DE_PRICE_GUARD_GET_AUCTION_ITEM_INFO and GetAuctionItemInfo == AVM_DE_PRICE_GUARD_GET_AUCTION_ITEM_INFO then return end

	AVM_DE_PRICE_GUARD_ORIG_GET_AUCTION_ITEM_INFO = GetAuctionItemInfo
	AVM_DE_PRICE_GUARD_GET_AUCTION_ITEM_INFO = function(listType, index)
		local name, texture, count, quality, canUse, level, minBid, minIncrement,
			buyoutPrice, bidAmount, highBidder, owner, saleStatus =
			AVM_DE_PRICE_GUARD_ORIG_GET_AUCTION_ITEM_INFO(listType, index)

		-- Core exact DE verification builds its material price book from the Blizzard
		-- "list" results while AVM.phase == DE_MAT_REVALIDATE. Make the player's own
		-- rows economically invisible only in that narrow phase. The row itself stays
		-- intact for the normal AH UI and for the dedicated owner/exposure scan.
		if avm_de_price_guard_is_own_de_material_row(listType, owner) then
			buyoutPrice = 0
		end

		return name, texture, count, quality, canUse, level, minBid, minIncrement,
			buyoutPrice, bidAmount, highBidder, owner, saleStatus
	end
	GetAuctionItemInfo = AVM_DE_PRICE_GUARD_GET_AUCTION_ITEM_INFO
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
	AVM_DB.deOwnAuctionFilter = true

	if verbose and not AVM_DE_PRICE_GUARD_PRINTED and DEFAULT_CHAT_FRAME then
		AVM_DE_PRICE_GUARD_PRINTED = true
		DEFAULT_CHAT_FRAME:AddMessage(
			"|cff33ff99AuxVmangos DE guard|r: depth >= " ..
			tostring(AVM_DE_PRICE_GUARD_MIN_DEPTH) ..
			", exact cache " .. tostring(AVM_DE_PRICE_GUARD_EXACT_TTL) ..
			"s, own DE listings excluded"
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
avm_de_price_guard_apply(false)

local guard = CreateFrame("Frame")
guard:RegisterEvent("VARIABLES_LOADED")
guard:RegisterEvent("PLAYER_LOGIN")
guard:SetScript("OnEvent", function()
	avm_de_price_guard_wrap_auction_info()
	avm_de_price_guard_apply(event == "PLAYER_LOGIN")
	avm_de_price_guard_wrap_slash()
end)
