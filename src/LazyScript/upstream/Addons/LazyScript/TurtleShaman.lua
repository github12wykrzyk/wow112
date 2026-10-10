local baseLoadAddOnByClass = lazyScript.LoadAddOnByClass

local GHOST_WOLF_TEXTURE_TOKEN = "spell_nature_spiritwolf"
local ghostWolfFrame = nil
local ghostWolfPollElapsed = 0

local function findGhostWolfBuffIndex()
	for slot = 0, 15 do
		local index = GetPlayerBuff(slot, "HELPFUL")
		if index and index >= 0 then
			local texture = GetPlayerBuffTexture(index)
			if texture and string.find(string.lower(texture), GHOST_WOLF_TEXTURE_TOKEN, 1, true) then
				return index
			end
		end
	end
	return nil
end

local function freshNativeTargetMelee()
	if not UnitExists("target") or not UnitCanAttack("player", "target") then return false end
	local at = lazyScript.nativeTargetMeleeRangeAt
	local state = lazyScript.nativeTargetMeleeRange
	if not at or state == nil then return false end
	local age = GetTime() - at
	if age < 0 or age > 0.30 then return false end
	return state == 1
end

local function freshNativeTargetWithin(yards)
	if not UnitExists("target") or not UnitCanAttack("player", "target") then return false end
	local at = lazyScript.nativeTargetRangeAt
	local rangeSquared = lazyScript.nativeTargetRangeSquared
	if not at or rangeSquared == nil then return false end
	local age = GetTime() - at
	if age < 0 or age > 0.30 then return false end
	return rangeSquared <= yards * yards
end

local function ensureGhostWolfFrame()
	if ghostWolfFrame then return end
	ghostWolfFrame = CreateFrame("Frame")
	ghostWolfFrame:SetScript("OnUpdate", function()
		ghostWolfPollElapsed = ghostWolfPollElapsed + (arg1 or 0)
		if ghostWolfPollElapsed < 0.03 then return end
		ghostWolfPollElapsed = 0

		local buffIndex = findGhostWolfBuffIndex()
		if not buffIndex then return end

		local shouldCancel = freshNativeTargetMelee()
		if not shouldCancel and lazyScript.isInCombat then
			shouldCancel = freshNativeTargetWithin(20)
		end
		if shouldCancel then
			CancelPlayerBuff(buffIndex)
		end
	end)
end

function lazyScript.LoadAddOnByClass(class)
	local result1, result2 = baseLoadAddOnByClass(class)
	if class == "SHAMAN" and lazyScript.actions then
		if not lazyScript.actions.lightningStrike then
			lazyScript.actions.lightningStrike = lazyScript.Action:New("lightningStrike", nil, false, true, false, "Lightning Strike")
		end
		ensureGhostWolfFrame()
	end
	return result1, result2
end
