-- Native fail-closed target melee/range criteria for WoW 1.12.1 / build 5875.
-- WoWCastObserver publishes fresh selected-target samples derived from verified
-- native world coordinates. Pure Lua has no reliable arbitrary-yard target
-- distance probe, and some stock melee probes are level/class dependent.

lazyScript.nativeTargetMeleeRange = nil
lazyScript.nativeTargetMeleeRangeAt = nil
lazyScript.nativeTargetRangeSquared100 = nil
lazyScript.nativeTargetRangeAt = nil

function lazyScript.OnNativeTargetMeleeRange(state)
	if state ~= 0 and state ~= 1 then
		lazyScript.nativeTargetMeleeRange = nil
		lazyScript.nativeTargetMeleeRangeAt = nil
		return
	end
	lazyScript.nativeTargetMeleeRange = state
	lazyScript.nativeTargetMeleeRangeAt = GetTime()
end

function lazyScript.OnNativeTargetRangeSquared(value)
	if type(value) ~= "number" or value < 0 then
		lazyScript.nativeTargetRangeSquared100 = nil
		lazyScript.nativeTargetRangeAt = nil
		return
	end
	lazyScript.nativeTargetRangeSquared100 = value
	lazyScript.nativeTargetRangeAt = GetTime()
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

function lazyScript.masks.NativeTargetInRangeYards(yards, expected)
	local limit = yards * yards * 100
	return function(sayNothing)
		if not UnitExists("target") then return false end
		local t = lazyScript.nativeTargetRangeAt
		local value = lazyScript.nativeTargetRangeSquared100
		if not t or value == nil then return false end
		local age = GetTime() - t
		-- Fail closed for positive AND negative checks when native telemetry is
		-- absent/stale. Value is squared 3D center distance scaled by 100.
		if age < 0 or age > 0.30 then return false end
		if expected then return value <= limit end
		return value > limit
	end
end

-- Generic arbitrary-yard syntax:
--   action-ifTargetInRange10Yards
--   action-ifNotTargetInRange10Yards
-- Optional '=' is also accepted: ifTargetInRange=10Yards.
function lazyScript.bitParsers.ifTargetInRangeYards(bit, actions, masks)
	if not lazyScript.rebit(bit, "^if(Not)?TargetInRange=?([0-9]+)Yards$") then
		return false
	end
	local negate = lazyScript.negate1()
	local yards = tonumber(lazyScript.match2)
	if not yards or yards < 1 or yards > 500 then
		lazyScript.p("Target range must be between 1 and 500 yards.")
		return nil
	end
	table.insert(masks, lazyScript.masks.HaveTarget)
	table.insert(masks, lazyScript.masks.NativeTargetInRangeYards(yards, not negate))
	return true
end

-- Short aliases:
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

-- Preserve the stock criterion for classes with a reliable low-level range
-- action. WARLOCK and SHAMAN use the native sample instead. In particular,
-- upstream SHAMAN points getRangeCheckAction() at Stormstrike; below the level
-- where that action exists this is nil and the stock parser dereferences
-- rangeAction.name. Native range avoids both the crash and the level coupling.
local baseIfTargetInMeleeRange = lazyScript.bitParsers.ifTargetInMeleeRange
function lazyScript.bitParsers.ifTargetInMeleeRange(bit, actions, masks)
	local _, class = UnitClass("player")
	if (class == "WARLOCK" or class == "SHAMAN") and lazyScript.rebit(bit, "^if(Not)?TargetInMeleeRange$") then
		local negate = lazyScript.negate1()
		table.insert(masks, lazyScript.masks.HaveTarget)
		table.insert(masks, lazyScript.negWrapper(lazyScript.masks.TargetFriend, true))
		table.insert(masks, lazyScript.masks.NativeTargetMeleeRange(not negate))
		return true
	end
	return baseIfTargetInMeleeRange(bit, actions, masks)
end