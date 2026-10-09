-- SummonScout Whisper Relay trust bootstrap bridge for WoW 1.12.1 / Lua 5.0.
--
-- Live failures fixed here:
--   * summoner queues a real customer whisper -> sends [SSWR1] H to Master ->
--     Master rejects H because V1 requires the sender to be trusted before H can
--     establish that trust -> K never returns -> queued customer text never flushes,
--   * Master can see an owned customer conversation but /ssr reply is blocked with
--     summoner-not-trusted because runtime bootstrap trust was restored immediately
--     after admitting the inbound relay packet.
--
-- Runtime H bootstrap remains temporary for unknown peers.  Separately, summoners
-- proven by the canonical fixed slave<->master ownership map are persisted into the
-- relay's canonical trustedSummoners table.  This lets Master replies pass the normal
-- V1 ACL without opening reply authority to arbitrary [SSWR1] senders.
-- K/R/RB/RC are never bridge-admitted and no SendChatMessage path is added here.

local H = W112_SUMMONSCOUT_HOT
if not H or type(H.Register) ~= "function" or type(H.GetState) ~= "function" then
    return
end

local relay = H.modules and H.modules["whisperrelay"] or nil
if type(relay) ~= "table" or type(relay.OnEvent) ~= "function" then
    return
end

local VERSION = "3-fixed-owner-reply-trust"
local PROTO = "[SSWR1]"
local B = H.GetState("whisperrelaytrustbridge")
B.peers = B.peers or {}
B.fixedTrusted = B.fixedTrusted or {}

local OWN_RELAY_ON_EVENT = relay.OnEvent

local function tbTrim(s)
    s = tostring(s or "")
    s = string.gsub(s, "^%s+", "")
    s = string.gsub(s, "%s+$", "")
    return s
end

local function tbLower(s)
    return string.lower(tbTrim(s or ""))
end

local function tbSame(a, b)
    a = tbLower(a)
    b = tbLower(b)
    return a ~= "" and a == b
end

local function tbPlayer()
    return tbTrim(UnitName and UnitName("player") or "")
end

local function tbValidName(name)
    name = tbTrim(name)
    if name == "" or string.len(name) > 32 then return false end
    if string.find(name, "[%c%s:;,=|]") then return false end
    return true
end

local function tbCode(raw)
    raw = tostring(raw or "")
    if string.sub(raw, 1, string.len(PROTO)) ~= PROTO then return nil end
    local rest = tbTrim(string.sub(raw, string.len(PROTO) + 1))
    if rest == "" then return nil end
    local at = string.find(rest, ":", 1, true)
    local code = at and string.sub(rest, 1, at - 1) or rest
    code = tbTrim(code)
    if code == "" then return nil end
    return code
end

local function tbPeerKey(sender)
    sender = tbTrim(sender)
    if not tbValidName(sender) or tbSame(sender, tbPlayer()) then return nil end
    return tbLower(sender)
end

local function tbRememberHello(sender)
    local key = tbPeerKey(sender)
    if not key then return false end
    B.peers[key] = {
        name = tbTrim(sender),
        seen = GetTime and GetTime() or 0
    }
    return true
end

local function tbKnownPeer(sender)
    local key = tbPeerKey(sender)
    if not key then return false end
    return type(B.peers[key]) == "table"
end

local function tbSummonerDataCode(code)
    return code == "I" or code == "IB" or code == "IC" or code == "E"
end

local function tbEnsureRelayDb()
    SummonScoutDB = SummonScoutDB or {}
    if type(SummonScoutDB.whisperRelayV1) ~= "table" then
        SummonScoutDB.whisperRelayV1 = {}
    end
    local D = SummonScoutDB.whisperRelayV1
    if type(D.trustedSummoners) ~= "table" then D.trustedSummoners = {} end
    return D
end

local function tbFixedSummoner(sender)
    local wanted = tbLower(sender)
    local ownership = W112_SUMMONSCOUT_SLAVE_MASTER_PAIRS_ACTIVE
    local _, master
    if wanted == "" or type(ownership) ~= "table" then return false end
    for _, master in pairs(ownership) do
        if tbLower(master) == wanted then return true end
    end
    return false
end

local function tbPersistFixedTrust(sender)
    sender = tbTrim(sender)
    local key = tbPeerKey(sender)
    if not key or not tbFixedSummoner(sender) then return false end
    local D = tbEnsureRelayDb()
    D.trustedSummoners[key] = sender
    B.fixedTrusted[key] = sender
    B.lastFixedTrusted = sender
    return true
end

local function tbSeedFixedTrust()
    local ownership = W112_SUMMONSCOUT_SLAVE_MASTER_PAIRS_ACTIVE
    local seen = {}
    local _, master, key
    local count = 0
    if type(ownership) ~= "table" then
        B.fixedTrustCount = 0
        return 0
    end
    for _, master in pairs(ownership) do
        master = tbTrim(master)
        key = tbLower(master)
        if key ~= "" and not seen[key] and tbValidName(master) then
            seen[key] = true
            if not tbSame(master, tbPlayer()) then
                local D = tbEnsureRelayDb()
                D.trustedSummoners[key] = master
                B.fixedTrusted[key] = master
            end
            count = count + 1
        end
    end
    B.fixedTrustCount = count
    return count
end

local function tbCallTemporarilyTrusted(ev, a1, a2, a3)
    local sender = tbTrim(a2 or "")
    local key = tbLower(sender)
    local D = tbEnsureRelayDb()
    local previous = D.trustedSummoners[key]
    local hadPrevious = previous ~= nil

    -- Unknown runtime peers receive compatibility admission only for this one
    -- canonical handler call. Fixed summoners already have persistent canonical trust.
    D.trustedSummoners[key] = sender

    local ok, result
    if pcall then
        ok, result = pcall(OWN_RELAY_ON_EVENT, ev, a1, a2, a3)
    else
        result = OWN_RELAY_ON_EVENT(ev, a1, a2, a3)
        ok = true
    end

    if hadPrevious then
        D.trustedSummoners[key] = previous
    else
        D.trustedSummoners[key] = nil
    end

    if not ok then error(result) end
    return result
end

local function tbWrappedOnEvent(ev, a1, a2, a3)
    if ev == "PLAYER_LOGIN" then
        B.peers = {}
        B.fixedTrusted = {}
        tbSeedFixedTrust()
        return OWN_RELAY_ON_EVENT(ev, a1, a2, a3)
    end

    if ev ~= "CHAT_MSG_WHISPER" then
        return OWN_RELAY_ON_EVENT(ev, a1, a2, a3)
    end

    local code = tbCode(a1 or "")
    if not code then
        return OWN_RELAY_ON_EVENT(ev, a1, a2, a3)
    end

    local sender = tbTrim(a2 or "")
    if code == "H" then
        if not tbRememberHello(sender) then
            return OWN_RELAY_ON_EVENT(ev, a1, a2, a3)
        end
        tbPersistFixedTrust(sender)
        return tbCallTemporarilyTrusted(ev, a1, a2, a3)
    end

    if tbSummonerDataCode(code) and tbKnownPeer(sender) then
        tbPersistFixedTrust(sender)
        return tbCallTemporarilyTrusted(ev, a1, a2, a3)
    end

    -- K/R/RB/RC and every unknown code remain entirely canonical. Fixed ownership
    -- only seeds canonical trustedSummoners; this wrapper never executes reply packets.
    return OWN_RELAY_ON_EVENT(ev, a1, a2, a3)
end

local M = {}

function M.Init()
    relay.OnEvent = tbWrappedOnEvent
    B.peers = {}
    B.fixedTrusted = {}
    tbSeedFixedTrust()
    W112_SUMMONSCOUT_WHISPER_RELAY_TRUST_BRIDGE_VERSION = VERSION
end

function M.Shutdown()
    if relay and relay.OnEvent == tbWrappedOnEvent then
        relay.OnEvent = OWN_RELAY_ON_EVENT
    end
end

H.Register("whisperrelaytrustbridge", M, VERSION)
