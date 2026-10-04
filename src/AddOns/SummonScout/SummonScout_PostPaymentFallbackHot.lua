-- Hot-loaded reliability guard for SummonScout post-payment marketing whispers.
-- It observes trusted payment ledger rows independently from the primary postpay
-- module and sends one bounded fallback only when no primary thank-you/offer was
-- observed for that payer within the normal send+retry window.

local H = W112_SUMMONSCOUT_HOT
if not H or type(H.Register) ~= "function" or type(H.GetState) ~= "function" then
    return
end

local GUARD_VERSION = "2-live-destinations1"
local G = H.GetState("postpay_fallback")
G.pending = G.pending or {}
G.seenRows = G.seenRows or {}
G.nextPollAt = tonumber(G.nextPollAt) or 0

local FALLBACK_DELAY = 2.20

local function gfNow()
    if GetTime then return GetTime() end
    return 0
end

local function gfTrim(s)
    s = s or ""
    s = string.gsub(s, "^%s+", "")
    s = string.gsub(s, "%s+$", "")
    return s
end

local function gfValidName(name)
    name = gfTrim(name)
    return name ~= "" and string.upper(name) ~= "UNKNOWN"
end

local function gfSamePlayer(a, b)
    a = string.lower(gfTrim(a or ""))
    b = string.lower(gfTrim(b or ""))
    return a ~= "" and a == b
end

local function gfEnabled()
    return SummonScoutDB and SummonScoutDB.postPaymentOfferEnabled == true
end

local function gfChat(text)
    if DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffSummonScout:|r " .. tostring(text or ""))
    end
end

local function gfLooksLikePrimaryPostpay(message)
    if type(H.IsPostPaymentOfferMessage) == "function" then
        if pcall then
            local ok, result = pcall(H.IsPostPaymentOfferMessage, message or "")
            if ok and result then return true end
        elseif H.IsPostPaymentOfferMessage(message or "") then
            return true
        end
    end

    -- Compatibility with the pre-live-directory primary while clients hot-migrate.
    local s = string.lower(message or "")
    if string.find(s, "hyjal", 1, true)
        and string.find(s, "hydraxis", 1, true)
        and string.find(s, "winterspring", 1, true) then
        return true
    end
    return string.find(s, "we also summon to ", 1, true) ~= nil
end

local function gfBuildMessage()
    if type(H.BuildPostPaymentOfferMessage) == "function" then
        if pcall then
            local ok, message = pcall(H.BuildPostPaymentOfferMessage)
            if ok and type(message) == "string" and message ~= "" then return message end
        else
            local message = H.BuildPostPaymentOfferMessage()
            if type(message) == "string" and message ~= "" then return message end
        end
    end
    -- Fail closed when the primary builder is unavailable: thank the payer but
    -- never advertise a destination whose provider state we cannot verify.
    return "Thank you!"
end

local function gfSeedRows()
    local seen = {}
    local log = SummonScoutDB and SummonScoutDB.paymentLog
    if type(log) == "table" then
        local i
        for i = 1, table.getn(log) do
            local row = log[i]
            if type(row) == "table" then
                seen[row] = true
            end
        end
    end
    G.seenRows = seen
end

local function gfReset()
    G.pending = {}
    G.nextPollAt = 0
    gfSeedRows()
end

local function gfQueuePayment(row)
    if not gfEnabled() or type(row) ~= "table" then return end
    local name = gfTrim(row.player or "")
    if not gfValidName(name) then
        if SummonScoutDB and SummonScoutDB.debug then
            gfChat("post-payment fallback skipped -> unresolved payer")
        end
        return
    end

    G.pending[table.getn(G.pending) + 1] = {
        name = name,
        dueAt = gfNow() + FALLBACK_DELAY,
        row = row,
        primarySeen = false
    }

    if SummonScoutDB and SummonScoutDB.debug then
        gfChat("post-payment fallback armed -> " .. name)
    end
end

local function gfObserveLedger()
    local log = SummonScoutDB and SummonScoutDB.paymentLog
    if type(log) ~= "table" then return end

    local previous = G.seenRows or {}
    local nextSeen = {}
    local i
    for i = 1, table.getn(log) do
        local row = log[i]
        if type(row) == "table" then
            nextSeen[row] = true
            if not previous[row] then
                gfQueuePayment(row)
            end
        end
    end
    G.seenRows = nextSeen
end

local function gfConfirmPrimary(message, name)
    if not gfLooksLikePrimaryPostpay(message) or not gfValidName(name) then return false end

    local matched = false
    local i
    for i = 1, table.getn(G.pending) do
        local item = G.pending[i]
        if item and gfSamePlayer(item.name, name) then
            item.primarySeen = true
            matched = true
        end
    end
    return matched
end

local function gfProcessPending()
    if table.getn(G.pending) == 0 then return end
    if not gfEnabled() then
        G.pending = {}
        return
    end

    local t = gfNow()
    local i
    for i = table.getn(G.pending), 1, -1 do
        local item = G.pending[i]
        if not item or item.primarySeen then
            table.remove(G.pending, i)
        elseif t >= (tonumber(item.dueAt) or 0) then
            local name = gfTrim(item.name or "")
            if gfValidName(name) and SendChatMessage then
                local message = gfBuildMessage()
                local ok = true
                if pcall then
                    ok = pcall(SendChatMessage, message, "WHISPER", nil, name)
                else
                    SendChatMessage(message, "WHISPER", nil, name)
                end
                if SummonScoutDB and SummonScoutDB.debug then
                    gfChat((ok and "post-payment fallback sent -> " or "post-payment fallback call failed -> ") .. name)
                end
            end
            -- One bounded fallback only. The primary module owns its own retry
            -- policy; this guard must never create an unbounded duplicate loop.
            table.remove(G.pending, i)
        end
    end
end

local M = {}

function M.Init()
    if G.moduleVersion ~= GUARD_VERSION then
        gfReset()
        G.moduleVersion = GUARD_VERSION
    elseif not G.seenRows then
        gfSeedRows()
    end
    H.RegisterEvent("PLAYER_LOGIN")
    H.RegisterEvent("CHAT_MSG_WHISPER_INFORM")
    W112_SUMMONSCOUT_POSTPAY_FALLBACK_VERSION = GUARD_VERSION
end

function M.OnEvent(ev, a1, a2)
    if ev == "PLAYER_LOGIN" then
        gfReset()
        G.moduleVersion = GUARD_VERSION
        W112_SUMMONSCOUT_POSTPAY_FALLBACK_VERSION = GUARD_VERSION
        return
    end

    if ev == "CHAT_MSG_WHISPER_INFORM" then
        gfConfirmPrimary(a1 or "", a2 or "")
    end
end

function M.OnUpdate()
    local t = gfNow()
    if t >= (G.nextPollAt or 0) then
        G.nextPollAt = t + 0.10
        gfObserveLedger()
    end
    gfProcessPending()
end

H.Register("postpay_fallback", M, GUARD_VERSION)
