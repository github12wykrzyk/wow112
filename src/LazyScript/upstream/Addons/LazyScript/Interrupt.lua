lazyScript.metadata:updateRevisionFromKeyword("$Revision: 622 $")

-- Build-5875 hybrid observer: native AutoKick remains sole automatic Kick owner.
lazyScript.interrupt = {}
local I = lazyScript.interrupt
I.targetCasting = nil
I.castingDetectedAt = 0
I.lastSpellInterrupted = nil -- only an explicit verified success may set this
I.native = {seen=false,guid=nil,spell=0,remaining=0,kind=0,owned=false,updatedAt=0}
I.lastAttempt = nil

function I.OnTargetChanged()
    I.targetCasting = nil
    I.castingDetectedAt = 0
    I.chatGuid = nil
    I.lastAttempt = nil
    I.native.guid = nil
    I.native.updatedAt = 0
    I.native.spell = 0
    I.native.kind = 0
end

function I.OnNativeCast(guid,spell,remaining,kind,owned)
    if type(guid) ~= "string" or string.len(guid) ~= 16 or
       not UnitExists("target") then return end
    local n = I.native
    if n.guid ~= guid then
        I.targetCasting = nil
        I.castingDetectedAt = 0
        I.chatGuid = nil
        I.lastAttempt = nil
    end
    n.seen = true
    n.guid = guid
    n.spell = tonumber(spell) or 0
    n.remaining = tonumber(remaining) or 0
    n.kind = tonumber(kind) or 0
    n.owned = owned == 1
    n.updatedAt = GetTime()
    if n.spell == 0 or n.kind == 0 then
        I.targetCasting = nil
        I.chatGuid = nil
    end
end

function I.NativeFresh()
    local n = I.native
    return n.seen and n.guid and n.updatedAt > 0 and
           GetTime() - n.updatedAt <= 0.25 and UnitExists("target")
end

function I.NativeKickOwner()
    -- Losing the bridge must not reactivate a competing automatic Lua Kick.
    return I.native.seen and I.native.owned
end

function I.OnAttempt(action)
    -- CastSpell/UseAction is not proof that an interrupt succeeded.
    I.lastAttempt = {action=action, at=GetTime(), guid=I.native.guid,
                     spell=I.native.spell}
end

function I.TargetIsCasting(nameRegex)
    local now = GetTime()
    local n = I.native
    if n.seen then
        if not I.NativeFresh() or n.spell == 0 or n.kind == 0 then return false end
        if n.kind == 1 and n.remaining <= 350 then return false end
        if not nameRegex or nameRegex == "" then return true end
        if not I.targetCasting or I.chatGuid ~= n.guid or
           now - I.castingDetectedAt > 0.7 then return false end
    else
        -- Legacy-only fallback when no native observer has ever been seen.
        if not I.targetCasting or now - I.castingDetectedAt > 0.35 or
           not UnitExists("target") then return false end
        if I.lastAttempt and now - I.lastAttempt.at < 0.4 then return false end
        if not nameRegex or nameRegex == "" then return true end
    end
    if lsConfGlobal.SpellType[I.targetCasting] and
       lsConfGlobal.SpellType[I.targetCasting][nameRegex] then return true end
    return string.find(I.targetCasting,nameRegex) ~= nil
end

function I.OnChatMsgSpell(arg1)
    local tName = UnitName("target")
    local starts = lazyScript.getLocaleString("SPELLCASTOTHERSTART")
    local performs = lazyScript.getLocaleString("SPELLPERFORMOTHERSTART")
    if not starts or not performs or not tName or not arg1 then return end
    local n = I.native
    if n.seen and not I.NativeFresh() then return end
    for _,pat in ipairs({starts,performs}) do
        for mob,spell in string.gfind(arg1,pat) do
            if mob == tName then
                I.targetCasting = spell
                I.castingDetectedAt = GetTime()
                I.chatGuid = I.NativeFresh() and n.guid or nil
                I.lastAttempt = nil
                if lazyScript.perPlayerConf.showTargetCasts then
                    lazyScript.p(tName..IS_CASTING..spell..".")
                end
                return
            end
        end
    end
end


-- Interrupt Criteria Edit Box

lazyScript.interruptEditBox = {}

lazyScript.interruptEditBox.cancelEdit = false

function lazyScript.interruptEditBox.OnShow()
	local text = table.concat(lsConf.interruptExceptionCriteria, "\n")
	LazyScriptInterruptExceptionCriteriaEditFrameForm:SetText(text)
end

function lazyScript.interruptEditBox.OnHide()
	if (lazyScript.interruptEditBox.cancelEdit) then
		lazyScript.interruptEditBox.cancelEdit = false
		return
	end
	
	local text = LazyScriptInterruptExceptionCriteriaEditFrameForm:GetText()
	
	local args = {}
	for arg in string.gfind(text, "[^\r\n]+") do
		table.insert(args, arg)
	end
	lsConf.interruptExceptionCriteria = args
	
	lazyScript.p(GLOBAL_INTERRUPT_CRITERIA_UPDATED)
	lazyScript.masks.parsingInterruptExceptionCriteria = true
	lazyScript.parsedInterruptExceptionCriteriaCache = lazyScript.ParseForm("interruptExceptionCriteria", lsConf.interruptExceptionCriteria)
	lazyScript.masks.parsingInterruptExceptionCriteria = false
end