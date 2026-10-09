-- LazyScript hotfix: player-level criteria for portable 1-60 forms.
--
-- Adds: ifPlayerLevel<N, ifPlayerLevel=N, ifPlayerLevel>N
-- Example: ifPlayerLevel>9 means level 10+.

if lazyScript and lazyScript.bitParsers and lazyScript.masks then
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
end
