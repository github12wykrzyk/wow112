local baseLoadAddOnByClass = lazyScript.LoadAddOnByClass

local GHOST_WOLF_TEXTURE_TOKEN = "spell_nature_spiritwolf"
local ghostWolfFrame = nil
local ghostWolfPollElapsed = 0
local postKillTargetName = nil
local postKillTargetWasAlive = false
local postKillTargetDeadAt = nil
local lastPlayerHealth = nil
local lastPlayerDamageAt = nil

local POST_KILL_MIN_DELAY = 0.15
local POST_KILL_MAX_WINDOW = 5.00
local POST_KILL_NEW_DAMAGE_QUIET = 0.60

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

local function updatePostKillWolfState(now)
	local hp = UnitHealth("player")
	if lastPlayerHealth and hp < lastPlayerHealth then
		lastPlayerDamageAt = now
	end
	lastPlayerHealth = hp

	if postKillTargetDeadAt and now - postKillTargetDeadAt > POST_KILL_MAX_WINDOW then
		postKillTargetDeadAt = nil
	end

	if not UnitExists("target") then
		postKillTargetName = nil
		postKillTargetWasAlive = false
		return
	end

	local name = UnitName("target")
	if name ~= postKillTargetName then
		postKillTargetName = name
		postKillTargetWasAlive = UnitCanAttack("player", "target") and not UnitIsDead("target")
		if postKillTargetWasAlive then
			postKillTargetDeadAt = nil
		end
		return
	end

	if UnitCanAttack("player", "target") and not UnitIsDead("target") then
		postKillTargetWasAlive = true
		postKillTargetDeadAt = nil
		return
	end

	if UnitIsDead("target") and postKillTargetWasAlive then
		postKillTargetDeadAt = now
		postKillTargetWasAlive = false
	end
end

local function postKillWolfSafe()
	local now = GetTime()
	if not lazyScript.isInCombat then return false end
	if not postKillTargetDeadAt then return false end
	local age = now - postKillTargetDeadAt
	if age < POST_KILL_MIN_DELAY or age > POST_KILL_MAX_WINDOW then return false end
	if lastPlayerDamageAt and lastPlayerDamageAt > postKillTargetDeadAt and now - lastPlayerDamageAt < POST_KILL_NEW_DAMAGE_QUIET then
		return false
	end
	if UnitExists("target") and UnitCanAttack("player", "target") and not UnitIsDead("target") then
		return false
	end
	return true
end

function lazyScript.masks.PostKillWolfSafe()
	return function(sayNothing)
		return postKillWolfSafe()
	end
end

function lazyScript.bitParsers.ifPostKillWolfSafe(bit, actions, masks)
	if not lazyScript.rebit(bit, "^ifPostKillWolfSafe$") then
		return false
	end
	table.insert(masks, lazyScript.masks.PostKillWolfSafe())
	return true
end

local function ensureGhostWolfFrame()
	if ghostWolfFrame then return end
	ghostWolfFrame = CreateFrame("Frame")
	ghostWolfFrame:SetScript("OnUpdate", function()
		ghostWolfPollElapsed = ghostWolfPollElapsed + (arg1 or 0)
		if ghostWolfPollElapsed < 0.03 then return end
		ghostWolfPollElapsed = 0

		local now = GetTime()
		updatePostKillWolfState(now)

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
