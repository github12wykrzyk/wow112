-- SummonScout Winterspring/Everlook service alias bridge for WoW 1.12.1 (5875).
--
-- The core addon historically has two location IDs:
--   winterspring -> Winterspring
--   everlook     -> Everlook
-- For summon service purposes they are the same destination.  Keep the core
-- dictionaries intact, but make both IDs equivalent while processing World
-- requests, direct whispers and same-location competitor adverts.
--
-- The bridge is intentionally event-scoped: SummonScoutDB.service is restored
-- immediately after the core handler returns, so party auto-summon and outgoing
-- summon whispers keep using the user's configured service name.

local BRIDGE_VERSION = "1"

local function wsTrim(s)
    s = s or ""
    s = string.gsub(s, "^%s+", "")
    s = string.gsub(s, "%s+$", "")
    return s
end

local function wsLower(s)
    return string.lower(s or "")
end

local function wsNormalize(s)
    s = wsLower(s)
    s = string.gsub(s, "|c%x%x%x%x%x%x%x%x", " ")
    s = string.gsub(s, "|r", " ")
    s = string.gsub(s, "|H.-|h(.-)|h", "%1")
    s = string.gsub(s, "[%p%c]", " ")
    s = string.gsub(s, "%s+", " ")
    return wsTrim(s)
end

local function wsPhraseHas(s, phrase)
    local p = wsNormalize(phrase)
    if p == "" then return false end
    return string.find(" " .. s .. " ", " " .. p .. " ", 1, true) ~= nil
end

local function wsServiceHas(service, id)
    local s = "," .. wsLower(wsTrim(service or "")) .. ","
    return string.find(s, "," .. id .. ",", 1, true) ~= nil
end

local function wsExtendedServiceForMessage(message)
    if not SummonScoutDB then return nil end

    local service = wsLower(wsTrim(SummonScoutDB.service or "all"))
    if service == "" or service == "all" then return nil end

    local servesWinterspring = wsServiceHas(service, "winterspring")
    local servesEverlook = wsServiceHas(service, "everlook")
    if not servesWinterspring and not servesEverlook then return nil end

    local s = wsNormalize(message or "")
    local mentionsWinterspring = wsPhraseHas(s, "winterspring")
    local mentionsEverlook = wsPhraseHas(s, "everlook")

    if mentionsEverlook and servesWinterspring and not servesEverlook then
        return SummonScoutDB.service .. ",everlook", "Everlook=>Winterspring"
    end
    if mentionsWinterspring and servesEverlook and not servesWinterspring then
        return SummonScoutDB.service .. ",winterspring", "Winterspring=>Everlook"
    end
    return nil
end

local frame = SummonScoutFrame
if frame and frame.GetScript and frame.SetScript then
    local originalOnEvent = frame:GetScript("OnEvent")
    if originalOnEvent then
        frame:SetScript("OnEvent", function()
            local restoreService = nil
            local bridgeReason = nil

            -- These are the three core paths that need destination matching:
            -- World invite + competition and whisper invite. Party auto-summon
            -- happens later and intentionally uses the original configured service.
            if event == "CHAT_MSG_CHANNEL" or event == "CHAT_MSG_WHISPER" then
                local extended, reason = wsExtendedServiceForMessage(arg1 or "")
                if extended then
                    restoreService = SummonScoutDB.service
                    SummonScoutDB.service = extended
                    bridgeReason = reason
                end
            end

            local ok, err = pcall(originalOnEvent)

            if restoreService ~= nil then
                SummonScoutDB.service = restoreService
                if SummonScoutDB.debug and DEFAULT_CHAT_FRAME then
                    DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffSummonScout:|r Winterspring/Everlook alias: "
                        .. tostring(bridgeReason or "matched"))
                end
            end

            if not ok then error(err) end
        end)
        W112_SUMMONSCOUT_WINTERSPRING_EVERLOOK_BRIDGE = BRIDGE_VERSION
    end
end
