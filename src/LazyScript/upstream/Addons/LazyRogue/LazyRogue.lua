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
end

-- Conservative tick estimate from vanilla UNIT_ENERGY events, not a native timer.
-- Two uncapped +20 gains separated by ~2s are needed to establish a phase.
function lazyRogueLoad.ResetEnergyTickClock()
	lazyRogue.energyTickProbeAt = nil
	lazyRogue.energyTickSyncedAt = nil
	lazyRogue.latestEnergy = UnitMana("player")
end

function lazyRogueLoad.UpdateEnergyTickClock(previousEnergy, currentEnergy, now)
	local gain = currentEnergy - previousEnergy
	if (gain ~= 20 or previousEnergy > UnitManaMax("player") - 20) then
		-- Tea, procs or otherwise unexpected energy gains invalidate synchronization.
		if (gain > 0) then
			lazyRogue.energyTickProbeAt = nil
			lazyRogue.energyTickSyncedAt = nil
		end
		return
	end
	local previousTick = lazyRogue.energyTickProbeAt
	lazyRogue.energyTickProbeAt = now
	if (previousTick and now - previousTick >= 1.7 and now - previousTick <= 2.3) then
		lazyRogue.energyTickSyncedAt = now
	else
		lazyRogue.energyTickSyncedAt = nil
	end
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