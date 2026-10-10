local baseLoadAddOnByClass = lazyScript.LoadAddOnByClass

local GHOST_WOLF_TEXTURE_TOKEN = "spell_nature_spiritwolf"
local ghostWolfHoldUntil = nil
local ghostWolfFrame = nil
local ghostWolfPollElapsed = 0

local function stopGhostWolfMovement()
	if MoveForwardStop then MoveForwardStop() end
	if MoveBackwardStop then MoveBackwardStop() end
	if StrafeLeftStop then StrafeLeftStop() end
	if StrafeRightStop then StrafeRightStop() end
end

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
		local now = GetTime()
		if ghostWolfHoldUntil then
			if findGhostWolfBuffIndex() then
				ghostWolfHoldUntil = nil
			elseif now <= ghostWolfHoldUntil then
				stopGhostWolfMovement()
			else
				ghostWolfHoldUntil = nil
			end
		end

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

local function installGhostWolfSmartAction()
	local action = lazyScript.actions and lazyScript.actions.ghostWolf
	if not action or action.w112GhostWolfSmartInstalled then return end
	local baseUse = action.Use
	function action:Use()
		stopGhostWolfMovement()
		ghostWolfHoldUntil = GetTime() + 1.35
		baseUse(self)
	end
	action.w112GhostWolfSmartInstalled = true
	ensureGhostWolfFrame()
end

function lazyScript.LoadAddOnByClass(class)
	local result1, result2 = baseLoadAddOnByClass(class)
	if class == "SHAMAN" and lazyScript.actions then
		if not lazyScript.actions.lightningStrike then
			lazyScript.actions.lightningStrike = lazyScript.Action:New("lightningStrike", nil, false, true, false, "Lightning Strike")
		end
		installGhostWolfSmartAction()
	end
	return result1, result2
end
