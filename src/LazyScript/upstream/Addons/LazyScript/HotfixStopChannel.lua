-- LazyScript hotfix: dedicated channel interruption pseudo-action.
--
-- stopCasting intentionally remains cast-only.  This hotfix adds stopChannel
-- so forms can interrupt a live channel without changing stopCasting semantics.
-- The action is usable only while LazyScript's channel state is active.

if lazyScript and lazyScript.PseudoAction and lazyScript.bitParsers then
	lazyScript.pseudoActions.stopChannel = lazyScript.PseudoAction:New("stopChannel", "Stop Channel", false)

	function lazyScript.pseudoActions.stopChannel:Use()
		SpellStopCasting()
		lazyScript.recordAction(self.code)
		self.everyTimer = GetTime()
		self.nowAndEveryTimer = self.everyTimer
	end

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
end
