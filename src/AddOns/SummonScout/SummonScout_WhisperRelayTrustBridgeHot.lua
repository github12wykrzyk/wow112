-- SummonScout Whisper Relay trust bootstrap bridge for WoW 1.12.1 / Lua 5.0.
--
-- Live failure fixed here:
--   summoner queues a real customer whisper -> sends [SSWR1] H to Master ->
--   Master rejects H because V1 requires the sender to be trusted before H can
--   establish that trust -> K never returns -> queued customer text never flushes.
--
-- This bridge breaks only that circular bootstrap. A syntactically valid H from a
-- valid non-self player opens a runtime-only relay peer. Subsequent summoner->Master
-- data packets from that exact peer are temporarily admitted to the canonical V1
-- handler. Master->summoner reply packets keep the original exact-master ACL and are
-- never authorised by this bridge. No SendChatMessage path is added here.

local H = W112_SUMMONSCOUT_HOT
if not H or type(H.Register) ~= "function" or type(H.GetState) ~= "function" then
    return
end

local relay = H.modules and H.modules["whisperrelay"] or nil
if type(relay) ~= "table" or type(relay.OnEvent) ~= "function" then
    return
end

local VERSION = "2-runtime-h-bootstrap"
local PROTO = "[SSWR1]"
local B = H.GetState("whisperrelaytrustbridge")
B.peers = B.peers or {}

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

local function tbCallTemporarilyTrusted(ev, a1, a2, a3)
    local sender = tbTrim(a2 or "")
    local key = tbLower(sender)
    local D = tbEnsureRelayDb()
    local previous = D.trustedSummoners[key]
    local hadPrevious = previous ~= nil

    -- Temporary compatibility admission only. The canonical handler still owns all
    -- packet semantics and all Master reply ACLs.
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
        return tbCallTemporarilyTrusted(ev, a1, a2, a3)
    end

    if tbSummonerDataCode(code) and tbKnownPeer(sender) then
        return tbCallTemporarilyTrusted(ev, a1, a2, a3)
    end

    -- K/R/RB/RC and every unknown code remain entirely canonical. In particular,
    -- this bridge can never authorise a customer-facing Master reply mutation.
    return OWN_RELAY_ON_EVENT(ev, a1, a2, a3)
end

local M = {}

function M.Init()
    relay.OnEvent = tbWrappedOnEvent
    B.peers = {}
    W112_SUMMONSCOUT_WHISPER_RELAY_TRUST_BRIDGE_VERSION = VERSION
end

function M.Shutdown()
    if relay and relay.OnEvent == tbWrappedOnEvent then
        relay.OnEvent = OWN_RELAY_ON_EVENT
    end
end

H.Register("whisperrelaytrustbridge", M, VERSION)
