lazyWarlock = {}
lazyWarlockLoad = {}

lazyWarlockLoad.metadata = lazyScript.Metadata:new("LazyWarlock")
lazyWarlockLoad.metadata:updateRevisionFromKeyword("$Revision: 414 $")

function lazyWarlockLoad.OnLoad()
	-- Check that this player is the correct class
	local localeClass, class = UnitClass("player")
	if class ~= "WARLOCK" then
		return
	end
	
	-- Check that we're compatible with LazyScript
	if not lazyScript.CheckCompatibility(lazyWarlockLoad.metadata) then
		return
	end
	
	-- I like everything with the same name. It makes S&R so easy
	lazyWarlock = lazyScript
	lazyWarlockLocale = lsLocale
	-- Unfortunately this overwrites everything that we already had called lazyWarlock.
	-- Load everything else in class specific files using these loading functions
	-- Localization must be loaded first!
	lazyWarlockLoad.LoadWarlockLocalization(GetLocale())
	lazyWarlockLoad.LoadParseWarlock()
	
	this:RegisterEvent("VARIABLES_LOADED")
	this:RegisterEvent("PLAYER_LOGIN")
	
	this:RegisterEvent("BAG_UPDATE")
	-- Internal wand/melee weave tracking; no external swing-timer addon required.
	this:RegisterEvent("CHAT_MSG_COMBAT_SELF_HITS")
	this:RegisterEvent("CHAT_MSG_COMBAT_SELF_MISSES")
	this:RegisterEvent("CHAT_MSG_SPELL_SELF_DAMAGE")
	this:RegisterEvent("PLAYER_TARGET_CHANGED")
	this:RegisterEvent("PLAYER_ENTERING_WORLD")
end

function lazyWarlockLoad.OnEvent()
	if (event == "CHAT_MSG_COMBAT_SELF_HITS" or event == "CHAT_MSG_COMBAT_SELF_MISSES") then
		if lazyWarlock.OnMeleeWeaveSwing then lazyWarlock.OnMeleeWeaveSwing() end
	elseif (event == "CHAT_MSG_SPELL_SELF_DAMAGE") then
		if lazyWarlock.OnMeleeWeaveSpellDamage then lazyWarlock.OnMeleeWeaveSpellDamage(arg1) end
	elseif (event == "PLAYER_TARGET_CHANGED") then
		if lazyWarlock.OnMeleeWeaveTargetChanged then lazyWarlock.OnMeleeWeaveTargetChanged() end
	elseif (event == "PLAYER_ENTERING_WORLD") then
		if lazyWarlock.ResetMeleeWeave then lazyWarlock.ResetMeleeWeave() end
	elseif (event == "BAG_UPDATE") then
		lazyWarlock.CheckStones()
		elseif (event == "VARIABLES_LOADED") then
		-- Nothing yet
		elseif (event == "PLAYER_LOGIN") then
		lazyWarlock.chat(lazyWarlockLoad.metadata:getNameVersionRevisionString()..WARLOCK_ADDON_LOADED..lazyScript.metadata.name.."!")
	end
end