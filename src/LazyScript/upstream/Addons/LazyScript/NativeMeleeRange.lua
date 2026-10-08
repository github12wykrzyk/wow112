-- Native fail-closed target melee range for WoW 1.12.1 / build 5875.
-- WoWCastObserver publishes a fresh selected-target range sample derived from
-- verified native world coordinates plus UNIT_FIELD_COMBATREACH. Pure Lua has
-- no reliable generic 5 yd range probe for Warlocks.

lazyScript.nativeTargetMeleeRange = nil
lazyScript.nativeTargetMeleeRangeAt = nil

function lazyScript.OnNativeTargetMeleeRange(state)
	if state ~= 0 and state ~= 1 then
		lazyScript.nativeTargetMeleeRange = nil
		lazyScript.nativeTargetMeleeRangeAt = nil
		return
	end
	lazyScript.nativeTargetMeleeRange = state
	lazyScript.nativeTargetMeleeRangeAt = GetTime()
end

function lazyScript.masks.NativeTargetMeleeRange(expected)
	return function(sayNothing)
		if not UnitExists("target") or not UnitCanAttack("player", "target") then
			return false
		end
		local t = lazyScript.nativeTargetMeleeRangeAt
		local state = lazyScript.nativeTargetMeleeRange
		if not t or state == nil then return false end
		local age = GetTime() - t
		-- Observer emits at least every 100 ms while valid. Missing/stale native
		-- state fails closed for BOTH the positive and negative criteria.
		if age < 0 or age > 0.30 then return false end
		return (state == 1) == expected
	end
end

-- Short aliases requested for Warlock forms:
--   action-meleeRange     -> target IS in melee range
--   action-notMeleeRange  -> target IS NOT in melee range
-- ifMeleeRange / ifNotMeleeRange are accepted as equivalent spellings.
function lazyScript.bitParsers.meleeRange(bit, actions, masks)
	local relaxed = lazyScript.relax(bit)
	local positive = (relaxed == lazyScript.relax("meleeRange") or
					 relaxed == lazyScript.relax("ifMeleeRange"))
	local negative = (relaxed == lazyScript.relax("notMeleeRange") or
					 relaxed == lazyScript.relax("ifNotMeleeRange"))
	if not positive and not negative then return false end

	table.insert(masks, lazyScript.masks.HaveTarget)
	table.insert(masks, lazyScript.negWrapper(lazyScript.masks.TargetFriend, true))
	table.insert(masks, lazyScript.masks.NativeTargetMeleeRange(positive))
	return true
end

-- Preserve the stock criterion for every class, but give WARLOCK the native
-- implementation instead of the upstream "not supported" syntax error.
local baseIfTargetInMeleeRange = lazyScript.bitParsers.ifTargetInMeleeRange
function lazyScript.bitParsers.ifTargetInMeleeRange(bit, actions, masks)
	local _, class = UnitClass("player")
	if class == "WARLOCK" and lazyScript.rebit(bit, "^if(Not)?TargetInMeleeRange$") then
		local negate = lazyScript.negate1()
		table.insert(masks, lazyScript.masks.HaveTarget)
		table.insert(masks, lazyScript.negWrapper(lazyScript.masks.TargetFriend, true))
		table.insert(masks, lazyScript.masks.NativeTargetMeleeRange(not negate))
		return true
	end
	return baseIfTargetInMeleeRange(bit, actions, masks)
end
