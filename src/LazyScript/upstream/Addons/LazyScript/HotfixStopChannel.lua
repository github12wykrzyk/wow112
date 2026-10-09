-- LazyScript hotfix: dedicated channel interruption pseudo-actions.
--
-- stopCasting intentionally remains cast-only. This hotfix keeps the generic
-- stopChannel action and also tracks the exact active channel spell reported by
-- WoW 1.12 SPELLCAST_CHANNEL_START (arg2 = localized spell name).  stopFunnel
-- therefore interrupts only a real Health Funnel channel and cannot kill Drain
-- Life / Drain Soul just because the pet crossed a health threshold.

if lazyScript and lazyScript.PseudoAction and lazyScript.bitParsers then
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
