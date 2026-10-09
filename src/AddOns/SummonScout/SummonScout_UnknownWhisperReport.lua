-- SummonScout unknown-whisper telemetry for WoW 1.12.1 / Lua 5.0.
-- Records only whispers that the existing whisper-confirmation engine itself
-- classifies as unknown (probe path) plus replies it cannot parse while a
-- confirmation probe is pending. Data is persisted in SummonScoutDB so the
-- updater can publish a GPT-readable GitHub report after SavedVariables flush.

local H = W112_SUMMONSCOUT_HOT
if not H or type(H.Register) ~= "function" or type(H.GetState) ~= "function" then
    return
end

local UR_VERSION = "1"
local UR_MAX_ITEMS = 250
local UR_STALE_SECONDS = 4
local WC = H.GetState("whisperconfirm")
local UR = H.GetState("unknownreport")
UR.pending = UR.pending or {}
UR.boundModule = nil
UR.boundOnEvent = nil
UR.originalOnEvent = nil

local function urNow()
    if GetTime then return GetTime() end
    return 0
end

local function urWallTime()
    if time then return time() end
    return 0
end

local function urTrim(s)
    s = s or ""
    s = string.gsub(s, "^%s+", "")
    s = string.gsub(s, "%s+$", "")
    return s
end

local function urLower(s)
    return string.lower(s or "")
end

local function urNormalize(s)
    s = urLower(s)
    s = string.gsub(s, "|c%x%x%x%x%x%x%x%x", " ")
    s = string.gsub(s, "|r", " ")
    s = string.gsub(s, "|H.-|h(.-)|h", "%1")
    s = string.gsub(s, "[%p%c]", " ")
    s = string.gsub(s, "%s+", " ")
    return urTrim(s)
end

local function urKey(name)
    return urLower(urTrim(name or ""))
end

local function urEnsureDB()
    SummonScoutDB = SummonScoutDB or {}
    if type(SummonScoutDB.unknownWhisperReport) ~= "table" then
        SummonScoutDB.unknownWhisperReport = {}
    end
    local db = SummonScoutDB.unknownWhisperReport
    db.schema = 1
    db.version = UR_VERSION
    db.total = tonumber(db.total) or 0
    db.seq = tonumber(db.seq) or 0
    if type(db.items) ~= "table" then db.items = {} end
    return db
end

local function urFindDecisionApi(fn, depth)
    if type(fn) ~= "function" or depth > 3 then return nil end
    if type(debug) ~= "table" or type(debug.getupvalue) ~= "function" then return nil end
    local i
    for i = 1, 32 do
        local ok, name, value
        if pcall then
            ok, name, value = pcall(debug.getupvalue, fn, i)
            if not ok then return nil end
        else
            name, value = debug.getupvalue(fn, i)
        end
        if not name then break end
        if type(value) == "table" and type(value.whisperInviteDecision) == "function" then
            return value
        end
    end
    for i = 1, 32 do
        local ok, name, value
        if pcall then
            ok, name, value = pcall(debug.getupvalue, fn, i)
            if not ok then return nil end
        else
            name, value = debug.getupvalue(fn, i)
        end
        if not name then break end
        if type(value) == "function" then
            local found = urFindDecisionApi(value, depth + 1)
            if found then return found end
        end
    end
    return nil
end

local function urCoreReason(message)
    local frame = SummonScoutFrame
    if not frame or not frame.GetScript then return "unavailable" end
    local api = urFindDecisionApi(frame:GetScript("OnEvent"), 0)
    if not api or type(api.whisperInviteDecision) ~= "function" then return "unavailable" end
    if pcall then
        local ok, accepted, loc, reason = pcall(api.whisperInviteDecision, message or "")
        if not ok then return "decision-error" end
        if accepted then return "accepted" end
        return tostring(reason or "rejected")
    end
    local accepted, loc, reason = api.whisperInviteDecision(message or "")
    if accepted then return "accepted" end
    return tostring(reason or "rejected")
end

local function urAppend(sender, message, reason)
    local db = urEnsureDB()
    db.seq = db.seq + 1
    db.total = db.total + 1
    db.updatedAt = urWallTime()

    local item = {
        seq = db.seq,
        at = urWallTime(),
        sessionAt = urNow(),
        character = UnitName and (UnitName("player") or "") or "",
        sender = urTrim(sender or ""),
        message = urTrim(message or ""),
        normalized = urNormalize(message or ""),
        reason = reason or "unknown",
        coreReason = urCoreReason(message),
        service = SummonScoutDB and tostring(SummonScoutDB.service or "") or "",
        whisperModule = tostring(W112_SUMMONSCOUT_WHISPER_CONFIRM_SPAM_VERSION or ""),
        reporterVersion = UR_VERSION
    }
    table.insert(db.items, item)
    while table.getn(db.items) > UR_MAX_ITEMS do
        table.remove(db.items, 1)
    end
end

local function urQueueCandidate(sender, message, seenAt)
    local key = urKey(sender)
    if key == "" then return end
    if type(UR.pending[key]) ~= "table" then UR.pending[key] = {} end
    table.insert(UR.pending[key], {
        sender = urTrim(sender),
        message = message or "",
        seenAt = seenAt or urNow()
    })
end

local function urSimplePendingAnswer(message)
    local raw = urLower(urTrim(message or ""))
    local s = urNormalize(message or "")
    if raw == "+" or raw == "+1" or raw == "++" or raw == "-" then return true end
    local known = {
        ["yes"] = true, ["yea"] = true, ["yeah"] = true, ["y"] = true,
        ["ye"] = true, ["yep"] = true, ["yup"] = true, ["ok"] = true,
        ["okay"] = true, ["sure"] = true, ["please"] = true, ["pls"] = true,
        ["plz"] = true, ["go"] = true, ["go ahead"] = true,
        ["yes please"] = true, ["yes pls"] = true, ["yes plz"] = true,
        ["yeah please"] = true, ["yeah pls"] = true, ["yeah plz"] = true,
        ["yea please"] = true, ["yea pls"] = true, ["sure please"] = true,
        ["sure pls"] = true, ["summon me"] = true, ["invite me"] = true,
        ["inv"] = true, ["123"] = true,
        ["no"] = true, ["n"] = true, ["nope"] = true, ["nah"] = true,
        ["no thanks"] = true, ["no thank you"] = true, ["no thx"] = true,
        ["cancel"] = true, ["stop"] = true
    }
    return known[s] and true or false
end

local function urBindWhisperModule()
    local target = H.modules and H.modules["whisperconfirm"] or nil
    if type(target) ~= "table" or type(target.OnEvent) ~= "function" then return end
    if UR.boundModule == target and target.OnEvent == UR.boundOnEvent then return end

    if UR.boundModule and UR.boundOnEvent and UR.originalOnEvent
        and UR.boundModule.OnEvent == UR.boundOnEvent then
        UR.boundModule.OnEvent = UR.originalOnEvent
    end

    local base = target.OnEvent
    local wrapper
    wrapper = function(ev, a1, a2, a3)
        if ev ~= "CHAT_MSG_WHISPER" then
            return base(ev, a1, a2, a3)
        end

        local sender = urTrim(a2 or "")
        local key = urKey(sender)
        local message = a1 or ""
        local t = urNow()
        local wasPending = key ~= "" and WC.pending[key] ~= nil
        local wasCandidate = key ~= "" and WC.candidates[key] ~= nil

        local result = base(ev, a1, a2, a3)
        if key == "" then return result end
        if H.IsManualChatLocked and H.IsManualChatLocked(sender) then return result end

        if wasPending then
            if WC.pending[key] ~= nil and not urSimplePendingAnswer(message) then
                urAppend(sender, message, "confirm-unparsed")
            end
            return result
        end

        if WC.candidates[key] ~= nil then
            if (not wasCandidate) or type(UR.pending[key]) == "table" then
                urQueueCandidate(sender, message, t)
            end
        end
        return result
    end

    target.OnEvent = wrapper
    UR.boundModule = target
    UR.boundOnEvent = wrapper
    UR.originalOnEvent = base
end

local function urFlushConfirmedUnknowns()
    local t = urNow()
    local key, list
    for key, list in pairs(UR.pending) do
        if type(list) ~= "table" or table.getn(list) == 0 then
            UR.pending[key] = nil
        else
            local probePending = WC.pending[key]
            if probePending then
                local i
                for i = 1, table.getn(list) do
                    local item = list[i]
                    urAppend(item.sender, item.message, "unknown-probe")
                end
                UR.pending[key] = nil
            else
                local oldest = list[1]
                local age = oldest and (t - (oldest.seenAt or t)) or 0
                if WC.candidates[key] == nil and age > 1.25 then
                    UR.pending[key] = nil
                elseif age > UR_STALE_SECONDS then
                    UR.pending[key] = nil
                end
            end
        end
    end
end

local M = {}

function M.Init()
    urEnsureDB()
    urBindWhisperModule()
    W112_SUMMONSCOUT_UNKNOWN_REPORT_VERSION = UR_VERSION
end

function M.Shutdown()
    if UR.boundModule and UR.boundOnEvent and UR.originalOnEvent
        and UR.boundModule.OnEvent == UR.boundOnEvent then
        UR.boundModule.OnEvent = UR.originalOnEvent
    end
    UR.boundModule = nil
    UR.boundOnEvent = nil
    UR.originalOnEvent = nil
end

function M.OnUpdate()
    urBindWhisperModule()
    urFlushConfirmedUnknowns()
end

H.Register("unknownreport", M, UR_VERSION)
