-- SummonScout Core V3 shadow control transport observer.
-- Stage 3 of the controlled-core-replacement plan.
-- Observation-only: parse existing fleet control whispers without sending or mutating legacy runtime.
-- WoW 1.12.1 / Lua 5.0 compatible.

local VERSION = "p1-shadow-control-transport"
local PROTO = "[SSFR1]"
local MAX_MESSAGES = 256

local S = W112_SUMMON_CORE_V3_TRANSPORT_SHADOW
if type(S) ~= "table" then
    S = {}
    W112_SUMMON_CORE_V3_TRANSPORT_SHADOW = S
end

S.version = VERSION
S.seq = tonumber(S.seq) or 0
S.messages = type(S.messages) == "table" and S.messages or {}
S.parseErrors = tonumber(S.parseErrors) or 0
S.lastSeenByPeer = type(S.lastSeenByPeer) == "table" and S.lastSeenByPeer or {}

local function now()
    if GetTime then return tonumber(GetTime()) or 0 end
    return 0
end

local function wall()
    if time then return tonumber(time()) or 0 end
    return 0
end

local function trim(value)
    local s = tostring(value or "")
    s = string.gsub(s, "^%s+", "")
    s = string.gsub(s, "%s+$", "")
    return s
end

local function lower(value)
    return string.lower(trim(value))
end

local function split(value)
    local s = tostring(value or "")
    local out = {}
    local p = 1
    while true do
        local at = string.find(s, ":", p, true)
        if not at then
            out[table.getn(out) + 1] = string.sub(s, p)
            break
        end
        out[table.getn(out) + 1] = string.sub(s, p, at - 1)
        p = at + 1
    end
    return out
end

local function unhex(value)
    local s = tostring(value or "")
    if math.mod(string.len(s), 2) ~= 0 then return nil end
    if string.find(s, "[^0-9a-fA-F]") then return nil end
    local out = ""
    local i
    for i = 1, string.len(s), 2 do
        local b = tonumber(string.sub(s, i, i + 1), 16)
        if not b then return nil end
        out = out .. string.char(b)
    end
    return out
end

local function parse(raw)
    raw = tostring(raw or "")
    if string.sub(raw, 1, string.len(PROTO)) ~= PROTO then return nil end
    local rest = trim(string.sub(raw, string.len(PROTO) + 1))
    if rest == "" then return nil end
    local parts = split(rest)
    local code = trim(parts[1] or "")
    if code == "" then return nil end
    local fields = {}
    local i
    for i = 2, table.getn(parts) do
        local decoded = unhex(parts[i])
        if decoded == nil then return nil, "invalid-hex" end
        fields[table.getn(fields) + 1] = decoded
    end
    return code, fields
end

local function appendBounded(list, item, maxCount)
    list[table.getn(list) + 1] = item
    while table.getn(list) > maxCount do table.remove(list, 1) end
end

local function observe(direction, raw, peer)
    local code, fields = parse(raw)
    if not code then
        if string.sub(tostring(raw or ""), 1, string.len(PROTO)) == PROTO then
            S.parseErrors = (tonumber(S.parseErrors) or 0) + 1
        end
        return false
    end

    S.seq = (tonumber(S.seq) or 0) + 1
    local envelope = {
        seq = S.seq,
        ts = wall(),
        mono = now(),
        direction = tostring(direction or "UNKNOWN"),
        peer = trim(peer),
        peerKey = lower(peer),
        code = code,
        fields = fields,
        rawLength = string.len(tostring(raw or ""))
    }
    appendBounded(S.messages, envelope, MAX_MESSAGES)
    if envelope.peerKey ~= "" then S.lastSeenByPeer[envelope.peerKey] = envelope.mono end
    return true
end

local function getSince(seq)
    local out = {}
    seq = tonumber(seq) or 0
    local i, item
    for i = 1, table.getn(S.messages) do
        item = S.messages[i]
        if type(item) == "table" and (tonumber(item.seq) or 0) > seq then
            out[table.getn(out) + 1] = item
        end
    end
    return out
end

local frame = CreateFrame and CreateFrame("Frame", "SummonScoutCoreV3ShadowTransportFrame") or nil
if frame then
    frame:RegisterEvent("CHAT_MSG_WHISPER")
    frame:RegisterEvent("CHAT_MSG_WHISPER_INFORM")
    frame:SetScript("OnEvent", function()
        if event == "CHAT_MSG_WHISPER" then
            observe("IN", arg1 or "", arg2 or "")
        elseif event == "CHAT_MSG_WHISPER_INFORM" then
            observe("OUT", arg1 or "", arg2 or "")
        end
    end)
end

W112_SUMMON_CORE_V3_TRANSPORT_SHADOW_API = {
    version = VERSION,
    Parse = parse,
    GetState = function() return S end,
    GetSince = getSince
}
