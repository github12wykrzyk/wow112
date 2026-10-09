-- Native hostile-target Magic dispel condition for WoW 1.12.1 / 5875.
-- WoWTargetAuraReveal publishes Spell.dbc DispelType for every positive aura.
-- Spell.dbc DispelType: 1=Magic, 2=Curse, 3=Disease, 4=Poison.
--
-- Script syntax:
--   devourMagic-ifTargetHasMagicBuff
--   purge-ifTargetHasMagicBuff
--   <action>-ifNotTargetHasMagicBuff

if lazyScript and lazyScript.bitParsers and lazyScript.masks then
	local DISPEL_MAGIC = 1

	local function nativeRows()
		return W112NativeTargetBuffs or lazyScript.nativeTargetBuffs
	end

	function lazyScript.masks.TargetHasMagicBuff(sayNothing)
		local rows = nativeRows()
		if not rows or rows.hostile ~= 1 then
			return false
		end

		-- Fast path supplied by the native bridge.
		if rows.hasMagic == 1 then
			if not sayNothing then
				for i = 1, (rows.count or 0) do
					local row = rows[i]
					if row and row.dispelType == DISPEL_MAGIC then
						lazyScript.d("Native target Magic buff: "..(row.name or "unknown").." spellId="..(row.spellId or 0))
						break
					end
				end
			end
			return true
		end

		-- Compatibility path if a table was published without hasMagic.
		for i = 1, (rows.count or 0) do
			local row = rows[i]
			if row and row.dispelType == DISPEL_MAGIC then
				if not sayNothing then
					lazyScript.d("Native target Magic buff: "..(row.name or "unknown").." spellId="..(row.spellId or 0))
				end
				return true
			end
		end
		return false
	end

	function lazyScript.bitParsers.targetHasMagicBuff(bit, actions, masks)
		local negate = false
		if lazyScript.rebit(bit, "^ifTargetHasMagicBuff$") then
			negate = false
		elseif lazyScript.rebit(bit, "^ifNotTargetHasMagicBuff$") then
			negate = true
		else
			return false
		end

		table.insert(masks, lazyScript.masks.UnitExists("target"))
		table.insert(masks, function(sayNothing)
			local hasMagic = lazyScript.masks.TargetHasMagicBuff(sayNothing)
			if negate then
				return not hasMagic
			end
			return hasMagic
		end)
		return true
	end
end
