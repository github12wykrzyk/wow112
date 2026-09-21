lazyScript.metadata:updateRevisionFromKeyword("$Revision: 622 $")

-- Parallel: native read-only CastObserver provides spell state; LazyScript alone dispatches Kick.
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
    if type(guid) ~= "string" then return end
    local n = I.native
    -- Explicit idle snapshot: cleared native slot/channel; no stale chat Kick.
    if guid == "" then
        n.seen = true
        n.guid = nil
        n.spell = 0
        n.remaining = 0
        n.kind = 0
        n.owned = false
        n.updatedAt = GetTime()
        I.targetCasting = nil
        I.chatGuid = nil
        return
    end
    if string.len(guid) ~= 16 or not UnitExists("target") then return end
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
    n.owned = false -- Observer NEVER owns or dispatches Kick.
    n.updatedAt = GetTime()
    if n.spell == 0 or n.kind == 0 then
        I.targetCasting = nil
        I.chatGuid = nil
    end
end

function I.NativeFresh()
    local n = I.native
    return n.seen and n.guid and n.updatedAt > 0 and
           GetTime() - n.updatedAt <= 0.12 and UnitExists("target")
end

function I.NativeKickOwner()
    -- Only an explicitly owned observer would suppress LazyScript Kick.
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
    -- Fail closed: chat start messages alone never authorize a Kick.
    -- The current selected target must have an ongoing native cast/channel.
    if not I.NativeFresh() or n.spell == 0 or n.kind == 0 then return false end
    -- 65535 is "unknown remaining", not 65.5 seconds of cast. The native
    -- unit slot must still be live; never infer activity from a cached time.
    if n.kind == 1 and n.remaining ~= 65535 and n.remaining <= 250 then
        return false
    end
    if not nameRegex or nameRegex == "" then return true end
    -- Optional name/regex filters retain the chat-derived *name* only when
    -- it belongs to the exact same active native GUID.
    if not I.targetCasting or I.chatGuid ~= n.guid or
       now - I.castingDetectedAt > 0.7 then return false end
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