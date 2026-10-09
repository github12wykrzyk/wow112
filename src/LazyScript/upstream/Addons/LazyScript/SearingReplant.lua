-- Smart Searing Totem relocation support for WoW 1.12.1 / 5875.
--
-- LazyScript syntax:
--   searingTotem-ifSearingNeedsReplant
--   <action>-ifNotSearingNeedsReplant
--
-- The criterion becomes true for the initial plant, on normal totem expiry,
-- or when the player has materially relocated and the current target has not
-- been hit by Searing Totem for a short grace period.  The movement signal
-- prefers the native MovementCore bridge and falls back to zone-map position.

if lazyScript and lazyScript.bitParsers and lazyScript.masks then
	local MIN_REPLANT_AGE = 8.0
	local NO_HIT_GRACE = 4.5
	local HARD_REFRESH_AGE = 28.0
	local MOVING_SECONDS_REQUIRED = 1.25
	local NATIVE_MOVEMENT_MAX_AGE = 0.35
	local MAP_MOVE_THRESHOLD = 0.0025
	local MAP_MOVE_THRESHOLD_SQ = MAP_MOVE_THRESHOLD * MAP_MOVE_THRESHOLD

	local state = lazyScript.searingReplantState or {}
	lazyScript.searingReplantState = state

	local function resetState()
		state.actionTimer = nil
		state.placedAt = nil
		state.lastHitAt = nil
		state.lastEvalAt = nil
		state.movingSeconds = 0
		state.placeX = nil
		state.placeY = nil
		state.placeZone = nil
		state.targetName = nil
	end

	local function getMapPosition()
		if type(GetPlayerMapPosition) ~= "function" then return nil end
		local x, y = GetPlayerMapPosition("player")
		if (not x) or (not y) or (x == 0 and y == 0) then
			local shown = WorldMapFrame and WorldMapFrame.IsVisible and WorldMapFrame:IsVisible()
			if type(SetMapToCurrentZone) == "function" and not shown then
				SetMapToCurrentZone()
				x, y = GetPlayerMapPosition("player")
			end
		end
		if (not x) or (not y) or (x == 0 and y == 0) then return nil end
		return x, y, GetZoneText()
	end

	local function syncPlacement(now)
		local action = lazyScript.actions and lazyScript.actions.searingTotem
		if not action then return end
		local timer = action.everyTimer
		if timer and timer > 0 and timer ~= state.actionTimer then
			state.actionTimer = timer
			state.placedAt = timer
			state.lastHitAt = timer
			state.lastEvalAt = now
			state.movingSeconds = 0
			state.targetName = UnitName("target")
			state.placeX, state.placeY, state.placeZone = getMapPosition()
		end
	end

	local function nativeMoving(now)
		local at = lazyScript.nativePlayerMovingAt
		local moving = lazyScript.nativePlayerMoving
		if not at or moving == nil then return nil end
		local age = now - at
		if age < 0 or age > NATIVE_MOVEMENT_MAX_AGE then return nil end
		return moving == 1 or moving == true
	end

	local function updateMovement(now)
		local last = state.lastEvalAt
		local dt = last and (now - last) or 0
		if dt < 0 or dt > 0.5 then dt = 0 end
		state.lastEvalAt = now

		local moving = nativeMoving(now)
		if moving == true then
			state.movingSeconds = (state.movingSeconds or 0) + dt
			if state.movingSeconds > 3 then state.movingSeconds = 3 end
		end

		local movedByMap = false
		if state.placeX and state.placeY then
			local x, y, zone = getMapPosition()
			if x and y then
				if state.placeZone and zone and state.placeZone ~= zone then
					movedByMap = true
				else
					local dx = x - state.placeX
					local dy = y - state.placeY
					movedByMap = (dx * dx + dy * dy) >= MAP_MOVE_THRESHOLD_SQ
				end
			end
		end

		return (state.movingSeconds or 0) >= MOVING_SECONDS_REQUIRED or movedByMap
	end

	local function targetSuitableForReplant()
		if not UnitExists("target") then return false end
		if UnitIsDead and UnitIsDead("target") then return false end
		if UnitCanAttack and not UnitCanAttack("player", "target") then return false end
		-- Replant only when the new totem has a reasonable chance to engage.
		if CheckInteractDistance and not CheckInteractDistance("target", 4) then return false end
		return true
	end

	function lazyScript.masks.SearingNeedsReplant(sayNothing)
		local now = GetTime()
		syncPlacement(now)

		if not targetSuitableForReplant() then return false end
		if not state.placedAt then return true end

		local age = now - state.placedAt
		if age < 0 then
			resetState()
			return true
		end
		if age >= HARD_REFRESH_AGE then return true end
		if age < MIN_REPLANT_AGE then return false end

		local moved = updateMovement(now)
		local lastHit = state.lastHitAt or state.placedAt
		local noHitFor = now - lastHit
		local currentTarget = UnitName("target")
		local targetChanged = state.targetName and currentTarget and state.targetName ~= currentTarget

		if noHitFor >= NO_HIT_GRACE and (moved or targetChanged) then
			if not sayNothing then
				lazyScript.d("Searing replant: age="..string.format("%.1f", age)..
					" noHit="..string.format("%.1f", noHitFor)..
					" moved="..tostring(moved).." targetChanged="..tostring(targetChanged))
			end
			return true
		end
		return false
	end

	function lazyScript.bitParsers.ifSearingNeedsReplant(bit, actions, masks)
		local negate = false
		if lazyScript.rebit(bit, "^ifSearingNeedsReplant$") then
			negate = false
		elseif lazyScript.rebit(bit, "^ifNotSearingNeedsReplant$") then
			negate = true
		else
			return false
		end
		table.insert(masks, lazyScript.negWrapper(lazyScript.masks.SearingNeedsReplant, negate))
		return true
	end

	local function searingName()
		local action = lazyScript.actions and lazyScript.actions.searingTotem
		return (action and action.name) or "Searing Totem"
	end

	local function onDamageMessage(msg)
		if not msg or msg == "" then return end
		local now = GetTime()
		syncPlacement(now)
		if not state.placedAt then return end

		local name = searingName()
		if not string.find(msg, name, 1, true) then return end

		-- Prefer hits involving the current target.  This avoids an old Searing
		-- Totem attacking a previous target from suppressing relocation.
		local currentTarget = UnitName("target")
		if currentTarget and not string.find(msg, currentTarget, 1, true) then return end

		state.lastHitAt = now
		state.targetName = currentTarget or state.targetName
	end

	local frame = CreateFrame("Frame")
	frame:RegisterEvent("CHAT_MSG_SPELL_CREATURE_VS_CREATURE_DAMAGE")
	frame:RegisterEvent("CHAT_MSG_SPELL_CREATURE_VS_SELF_DAMAGE")
	frame:RegisterEvent("CHAT_MSG_SPELL_FRIENDLYPLAYER_DAMAGE")
	frame:RegisterEvent("CHAT_MSG_SPELL_PARTY_DAMAGE")
	frame:RegisterEvent("CHAT_MSG_SPELL_SELF_DAMAGE")
	frame:RegisterEvent("PLAYER_ENTERING_WORLD")
	frame:RegisterEvent("PLAYER_REGEN_ENABLED")
	frame:SetScript("OnEvent", function()
		if event == "PLAYER_ENTERING_WORLD" or event == "PLAYER_REGEN_ENABLED" then
			resetState()
		else
			onDamageMessage(arg1)
		end
	end)
end
