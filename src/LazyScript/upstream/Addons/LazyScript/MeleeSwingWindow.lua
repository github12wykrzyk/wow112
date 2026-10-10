local AFTER_MELEE_SWING_WINDOW = 0.50

lazyScript.lastPlayerMeleeSwingAt = nil

local meleeSwingFrame = CreateFrame("Frame")
meleeSwingFrame:RegisterEvent("CHAT_MSG_COMBAT_SELF_HITS")
meleeSwingFrame:RegisterEvent("CHAT_MSG_COMBAT_SELF_MISSES")
meleeSwingFrame:SetScript("OnEvent", function()
	if event == "CHAT_MSG_COMBAT_SELF_HITS" or event == "CHAT_MSG_COMBAT_SELF_MISSES" then
		lazyScript.lastPlayerMeleeSwingAt = GetTime()
	end
end)

function lazyScript.masks.AfterMeleeSwing()
	return function(sayNothing)
		local at = lazyScript.lastPlayerMeleeSwingAt
		if not at then return false end
		local age = GetTime() - at
		return age >= 0 and age <= AFTER_MELEE_SWING_WINDOW
	end
end

function lazyScript.bitParsers.ifAfterMeleeSwing(bit, actions, masks)
	if not lazyScript.rebit(bit, "^ifAfterMeleeSwing$") then
		return false
	end
	table.insert(masks, lazyScript.masks.AfterMeleeSwing())
	return true
end
