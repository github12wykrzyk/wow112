lazyRogue = {}
lazyRogueLoad = {}

lazyRogueLoad.metadata = lazyScript.Metadata:new("LazyRogue")
lazyRogueLoad.metadata:updateRevisionFromKeyword("$Revision: 521 $")

function lazyRogueLoad.OnLoad()
	-- Check that this player is the correct class
	local localeClass, class = UnitClass("player")
	if class ~= "ROGUE" then
		return
	end
	
	-- Check that we're compatible with LazyScript
	if not lazyScript.CheckCompatibility(lazyRogueLoad.metadata) then
		return
	end
	
	-- I like everything with the same name. It makes S&R so easy
	lazyRogue = lazyScript
	lazyRogueLocale = lsLocale
	-- Unfortunately this overwrites everything that we already had called lazyRogue.
	-- Load everything else in class specific files using these loading functions
	-- Localization must be loaded first!
	lazyRogueLoad.LoadRogueLocalization(GetLocale())
	lazyRogueLoad.LoadParseRogue()
	lazyRogueLoad.LoadEviscTracking()
	
	this:RegisterEvent("VARIABLES_LOADED")
	this:RegisterEvent("PLAYER_LOGIN")
	-- LazyRogue is load-on-demand: PLAYER_LOGIN may already have fired.
	-- Start listening as soon as this addon is loaded, not only at login.
	lazyRogueLoad.ResetEnergyTickClock()
	this:RegisterEvent("UNIT_ENERGY")
	SLASH_LAZYROGUETICK1 = "/lrtick"
	SlashCmdList["LAZYROGUETICK"] = lazyRogueLoad.PrintEnergyTickClock
end

-- An observed uncapped +20 energy gain sets the estimated 2s server-tick
-- phase immediately. The old two-consecutive-uncapped-tick requirement often
-- never synchronized while actively spending energy or approaching the cap.
-- A capped partial (+1..+19) gain can also mark a tick when already near cap.
-- This is an approximation based on client UNIT_ENERGY timing, not a DLL
-- or a claim that GetTime reads the server's native tick clock.
function lazyRogueLoad.ResetEnergyTickClock()
	lazyRogue.energyTickSyncedAt = nil
	lazyRogue.energyTickLastGain = nil
	lazyRogue.energyTickLastEventAt = nil
	lazyRogue.latestEnergy = UnitMana("player")
end

function lazyRogueLoad.UpdateEnergyTickClock(previousEnergy, currentEnergy, now)
	if (type(previousEnergy) ~= "number" or type(currentEnergy) ~= "number") then
		return
	end
	local gain = currentEnergy - previousEnergy
	lazyRogue.energyTickLastGain = gain
	lazyRogue.energyTickLastEventAt = now
	if (gain <= 0) then
		return
	end
	local maxEnergy = UnitManaMax("player")
	if (gain > 20) then
		-- Thistle Tea or a nonstandard positive energy source changes the value
		-- without proving that a natural regeneration tick occurred.
		lazyRogue.energyTickSyncedAt = nil
		return
	end
	if (gain == 20 or (maxEnergy and maxEnergy > 0 and currentEnergy == maxEnergy)) then
		lazyRogue.energyTickSyncedAt = now
	end
end

-- Optional observation only; synchronization is fully automatic.
function lazyRogueLoad.PrintEnergyTickClock()
	local remaining = lazyRogue.masks and lazyRogue.masks.EnergyTickRemainingMs
		and lazyRogue.masks.EnergyTickRemainingMs()
	local energy = UnitMana("player")
	local maximum = UnitManaMax("player")
	local state = remaining and (remaining.." ms to tick (estimated)")
		or "UNSYNCED (wait for natural energy regeneration)"
	local gain = lazyRogue.energyTickLastGain
	lazyRogue.chat("Energy tick: "..state.."; energy "..energy.."/"..maximum
		.."; last change "..(gain and tostring(gain) or "none")..".")
end

function lazyRogueLoad.OnEvent()
	if (event == "VARIABLES_LOADED") then
		if (lrConf and not lazyRogue.perPlayerConf.importedOldLazyRogueSettings) then
			lazyRogue.importOldSettings()
			lazyRogue.importOldForms()
			lazyRogue.perPlayerConf.importedOldLazyRogueSettings = true
			
			StaticPopupDialogs["LAZYROGUE_IMPORTED"] = {
				text = lazyRogue.getLocaleString("IMPORTED", true),
				button1 = TEXT(OKAY),
				timeout = 0,
				whileDead = 1,
				exclusive = 1,
				hideOnEscape = 1
			};
			StaticPopup_Show("LAZYROGUE_IMPORTED");
		end
		
		elseif (event == "PLAYER_LOGIN") then
		
		lazyRogueLoad.ResetEnergyTickClock()
		-- Harmless if already registered by OnLoad; needed for login reloads.
		this:RegisterEvent("UNIT_ENERGY")
		this:RegisterEvent("CHAT_MSG_SPELL_SELF_DAMAGE")
		
		if (not lazyRogue.UseActionOrig) and (lazyRogue.et) then
			lazyRogue.UseActionOrig = UseAction
			UseAction = lazyRogue.et.UseActionHook
		end
		
		if (not lazyRogue.CastSpellOrig) and (lazyRogue.et) then
			lazyRogue.CastSpellOrig = CastSpell
			CastSpell = lazyRogue.et.CastSpellHook
		end
		
		lazyRogue.chat(lazyRogueLoad.metadata:getNameVersionRevisionString()..ROGUE_ADDON_LOADED..lazyScript.metadata.name.."!")
		
		elseif (event == "UNIT_ENERGY") then
		if (arg1 == "player") then
			local currentEnergy = UnitMana("player")
			local now = GetTime()
			lazyRogueLoad.UpdateEnergyTickClock(lazyRogue.latestEnergy, currentEnergy, now)
			if (currentEnergy > lazyRogue.latestEnergy) then
				-- Preserve original LastChance bookkeeping.
				lazyRogue.lastTickTime = now
			end
			lazyRogue.latestEnergy = currentEnergy
		end
		
		elseif (event == "CHAT_MSG_SPELL_SELF_DAMAGE") then
		if lazyRogue.et then
			lazyRogue.et.TrackEviscerates(arg1)
		end
		
	end
end