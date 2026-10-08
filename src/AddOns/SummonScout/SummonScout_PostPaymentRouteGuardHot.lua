-- Route-aware guard for SummonScout_PostPaymentOfferHot direct-prefix invites.
--
-- PostPaymentOfferHot intentionally keeps a typo-tolerant fast path for inv*,
-- port*, taxi*, buy* and wtb*. This guard runs outside the hot-host fanout and
-- temporarily removes only the postpay module when the canonical whisper
-- classifier says the destination belongs elsewhere / is ambiguous, or when a
-- multi-word buy*/wtb* message is ordinary commerce chatter rather than summon
-- intent. FallbackRouter and every other whisper module still receive the event.

local H = W112_SUMMONSCOUT_HOT
if not H or type(H.Register) ~= "function" or type(H.GetState) ~= "function" then
    return
end

local VERSION = "1-canonical-route-aware-prefix-guard"
local G = H.GetState("postpayrouteguard")
local OWN_WRAPPER = nil
local OWN_BASE = nil

local function pgTrim(s)
    s = tostring(s or "")
    s = string.gsub(s, "^%s+", "")
    s = string.gsub(s, "%s+$", "")
    return s
end

local function pgNormalize(s)
    s = string.lower(tostring(s or ""))
    s = string.gsub(s, "|c%x%x%x%x%x%x%x%x", " ")
    s = string.gsub(s, "|r", " ")
    s = string.gsub(s, "|H.-|h(.-)|h", "%1")
    s = string.gsub(s, "[%p%c]", " ")
    s = string.gsub(s, "%s+", " ")
    return pgTrim(s)
end

local function pgTokenCount(s)
    local count = 0
    local token
    for token in string.gfind(pgNormalize(s), "%S+") do
        count = count + 1
    end
    return count
end

local function pgCommercePrefix(s)
    local token
    for token in string.gfind(pgNormalize(s), "%S+") do
        if string.len(token) >= 3 and string.sub(token, 1, 3) == "buy" then return true end
        if string.len(token) >= 3 and string.sub(token, 1, 3) == "wtb" then return true end
    end
    return false
end

local function pgResolveApi()
    local api = W112_SUMMONSCOUT_API_V1
    if type(api) ~= "table"
        or type(api.whisperInviteDecision) ~= "function" then
        return nil
    end
    return api
end

local function pgDecision(api, message)
    if pcall then
        local ok, accept, loc, reason = pcall(api.whisperInviteDecision, message or "")
        if not ok then return false, nil, "classifier-error" end
        return accept and true or false, loc, reason
    end
    local accept, loc, reason = api.whisperInviteDecision(message or "")
    return accept and true or false, loc, reason
end

local function pgSuppressPostpay(message)
    local api = pgResolveApi()
    if not api then
        -- Fail closed only for the postpay shortcut. Core/fallback processing
        -- remains untouched and can still handle the whisper normally.
        return true, "classifier-unavailable"
    end

    local accept, loc, reason = pgDecision(api, message)
    if accept then return false, nil end

    if reason == "other-location" or reason == "ambiguous-location" then
        return true, reason
    end

    -- Preserve one-token typo shorthand (e.g. "wtbb") but never let ordinary
    -- trade chatter such as "buying arcane crystals" become an invite.
    if pgCommercePrefix(message) and pgTokenCount(message) > 1 and not loc then
        return true, "commerce-chatter"
    end

    return false, nil
end

local function pgDetachPrevious()
    if not H.frame or not H.frame.GetScript or not H.frame.SetScript then return end
    if G.wrapper and G.base and H.frame:GetScript("OnEvent") == G.wrapper then
        H.frame:SetScript("OnEvent", G.base)
    end
end

local function pgInstall()
    if not H.frame or not H.frame.GetScript or not H.frame.SetScript then return false end

    pgDetachPrevious()
    local current = H.frame:GetScript("OnEvent")
    if type(current) ~= "function" then return false end

    OWN_BASE = current
    OWN_WRAPPER = function()
        if event ~= "CHAT_MSG_WHISPER" then
            return OWN_BASE()
        end

        local suppress, reason = pgSuppressPostpay(arg1 or "")
        if not suppress then
            return OWN_BASE()
        end

        local postpay = H.modules and H.modules["postpay"] or nil
        if not postpay then
            return OWN_BASE()
        end

        H.modules["postpay"] = nil
        local ok, err = true, nil
        if pcall then
            ok, err = pcall(OWN_BASE)
        else
            OWN_BASE()
        end
        H.modules["postpay"] = postpay

        if SummonScoutDB and SummonScoutDB.debug and DEFAULT_CHAT_FRAME then
            DEFAULT_CHAT_FRAME:AddMessage("|cffffaa00SummonScout route guard:|r postpay invite suppressed ["
                .. tostring(reason or "blocked") .. "] -> " .. tostring(arg2 or "?"))
        end

        if not ok then error(err) end
    end

    G.base = OWN_BASE
    G.wrapper = OWN_WRAPPER
    G.version = VERSION
    H.frame:SetScript("OnEvent", OWN_WRAPPER)
    return true
end

local M = {}

function M.Init()
    pgInstall()
end

function M.Shutdown()
    if H.frame and H.frame.GetScript and H.frame.SetScript
        and OWN_WRAPPER and OWN_BASE
        and H.frame:GetScript("OnEvent") == OWN_WRAPPER then
        H.frame:SetScript("OnEvent", OWN_BASE)
    end
    if G.wrapper == OWN_WRAPPER then
        G.wrapper = nil
        G.base = nil
    end
end

H.Register("postpayrouteguard", M, VERSION)
W112_SUMMONSCOUT_POSTPAY_ROUTE_GUARD_VERSION = VERSION
