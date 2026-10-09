-- LazyScript hotfix: channel interruption + portable player-level criteria.
--
-- Keep stopCasting cast-only.  stopChannel interrupts any live channel.
-- stopFunnel tracks the exact spell reported by SPELLCAST_CHANNEL_START and
-- interrupts only Health Funnel, so Drain Life / Drain Soul are not affected.
--
-- Also provides form criteria:
--   ifPlayerLevel<N
--   ifPlayerLevel=N
--   ifPlayerLevel>N
-- This lives in an already-loaded hotfix file so delivery does not depend on
-- adding a new .toc entry.

if lazyScript and lazyScript.PseudoAction and lazyScript.bitParsers and lazyScript.masks then
	-- ------------------------------------------------------------------------
	-- Player level criteria
	-- ------------------------------------------------------------------------
	function lazyScript.masks.PlayerLevel(gtLtEq, val)
		return function()
			local level = UnitLevel("player") or 0
			if gtLtEq == ">" then
				return level > val
			elseif gtLtEq == "<" then
				return level < val
			elseif gtLtEq == "=" then
				return level == val
			end
			return false
		end
	end

	function lazyScript.bitParsers.ifPlayerLevel(bit, actions, masks)
		if not lazyScript.rebit(bit, "^ifPlayerLevel([<=>])(%d+)$") then
			return false
		end
		local gtLtEq = lazyScript.match1
		local val = tonumber(lazyScript.match2)
		if not val then
			return nil
		end
		table.insert(masks, lazyScript.masks.PlayerLevel(gtLtEq, val))
		return true
	end

	-- ------------------------------------------------------------------------
	-- Exact active-channel tracking
	-- ------------------------------------------------------------------------
	lazyScript.activeChannelSpellName = nil

	local channelTracker = CreateFrame("Frame", "LazyScriptStopChannelTracker")
	channelTracker:RegisterEvent("SPELLCAST_CHANNEL_START")
	channelTracker:RegisterEvent("SPELLCAST_CHANNEL_STOP")
	channelTracker:RegisterEvent("PLAYER_ENTERING_WORLD")
	channelTracker:SetScript("OnEvent", function()
		if event == "SPELLCAST_CHANNEL_START" then
			lazyScript.activeChannelSpellName = arg2
		elseif event == "SPELLCAST_CHANNEL_STOP" or event == "PLAYER_ENTERING_WORLD" then
			lazyScript.activeChannelSpellName = nil
		end
	end)

	local function UseStopChannel(self)
		SpellStopCasting()
		lazyScript.recordAction(self.code)
		self.everyTimer = GetTime()
		self.nowAndEveryTimer = self.everyTimer
	end

	-- ------------------------------------------------------------------------
	-- Generic stopChannel
	-- ------------------------------------------------------------------------
	lazyScript.pseudoActions.stopChannel = lazyScript.PseudoAction:New("stopChannel", "Stop Channel", false)
	lazyScript.pseudoActions.stopChannel.Use = UseStopChannel

	function lazyScript.pseudoActions.stopChannel:IsUsable(sayNothing)
		return lazyScript.channellingInProgress == true
	end

	function lazyScript.bitParsers.stopChannel(bit, actions, masks)
		if not lazyScript.rebit(bit, lazyScript.pseudoActions.stopChannel.codePattern) then
			return false
		end
		table.insert(actions, lazyScript.pseudoActions.stopChannel)
		return true
	end

	-- ------------------------------------------------------------------------
	-- Health Funnel-only stop
	-- ------------------------------------------------------------------------
	lazyScript.pseudoActions.stopFunnel = lazyScript.PseudoAction:New("stopFunnel", "Stop Health Funnel", false)
	lazyScript.pseudoActions.stopFunnel.Use = UseStopChannel

	function lazyScript.pseudoActions.stopFunnel:IsUsable(sayNothing)
		if lazyScript.channellingInProgress ~= true then
			return false
		end
		local funnelAction = lazyScript.actions and lazyScript.actions.funnel
		if not funnelAction or not funnelAction.name then
			return false
		end
		return lazyScript.activeChannelSpellName == funnelAction.name
	end

	function lazyScript.bitParsers.stopFunnel(bit, actions, masks)
		if not lazyScript.rebit(bit, lazyScript.pseudoActions.stopFunnel.codePattern) then
			return false
		end
		table.insert(actions, lazyScript.pseudoActions.stopFunnel)
		return true
	end
end
