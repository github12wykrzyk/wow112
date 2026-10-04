-- SummonScout fallback question + live destination router for WoW 1.12.1 / Lua 5.0.
--
-- Customer behavior:
--   * normal understood whisper requests are left entirely to the core;
--   * an unknown/question-like whisper gets a concise list of currently available routes;
--   * a recognized destination selection is handled locally when this client serves it,
--     otherwise it is handed through the configured master to a live summoner serving it.
--
-- Fleet behavior:
--   * summon clients advertise their configured service to SummonScoutDB.masterName;
--   * the master keeps a short-TTL live directory and forwards route requests;
--   * customer/player fields in control whispers are hex encoded so they cannot trip the
--     existing direct-prefix buyer parser; the protocol also avoids WoW's literal-pipe escapes.
--
-- No Ritual, payment, roster, World-chat or native coordinator behavior is replaced here.

local H = W112_SUMMONSCOUT_HOT
if not H or type(H.Register) ~= "function" or type(H.GetState) ~= "function" then
    return
end

local VERSION = "1-live-master-router"
local F = H.GetState("fallbackrouter")
F.pendingChoice = F.pendingChoice or {}
F.promptRecent = F.promptRecent or {}
F.pendingRoute = F.pendingRoute or {}
F.providers = F.providers or {}
F.peers = F.peers or {}
F.directory = F.directory or {}
F.nextHelloAt = tonumber(F.nextHelloAt) or 0
F.nextMaintenanceAt = tonumber(F.nextMaintenanceAt) or 0
F.nextDirectoryPushAt = tonumber(F.nextDirectoryPushAt) or 0
F.lastHelloServices = F.lastHelloServices or ""
F.directoryDirty = F.directoryDirty and true or false
F.hubLearned = F.hubLearned and true or false

local PROTO = "[SSFR1]"
local HELLO_INTERVAL = 12.0
local PROVIDER_TTL = 38.0
local PEER_TTL = 55.0
local CHOICE_TTL = 45.0
local PROMPT_DEDUPE = 12.0
local ROUTE_TIMEOUT = 6.0
local MAX_DIRECTORY_DESTINATIONS = 12

local DISPLAY_LABELS = {
    hyjal = "Hyjal",
    hydraxian = "Hydraxis",
    winterspring = "Winterspring"
}

local SOCIAL_NOISE = {
    ["ty"] = true, ["thx"] = true, ["thanks"] = true, ["thank you"] = true,
    ["ok"] = true, ["okay"] = true, ["kk"] = true, ["k"] = true,
    ["np"] = true, ["nice"] = true, ["cool"] = true, ["cheers"] = true,
    ["wait"] = true, ["sec"] = true, ["one sec"] = true, ["brb"] = true
}

local QUESTION_CUES = {
    "where", "which", "what", "how much", "price", "cost", "available",
    "location", "locations", "destination", "destinations", "places",
    "can you", "could you", "do you", "summon", "summons", "taxi"
}

local function frNow()
    if GetTime then return GetTime() end
    return 0
end

local function frTrim(s)
    s = tostring(s or "")
    s = string.gsub(s, "^%s+", "")
    s = string.gsub(s, "%s+$", "")
    return s
end

local function frLower(s)
    return string.lower(frTrim(s or ""))
end

local function frSame(a, b)
    a = frLower(a)
    b = frLower(b)
    return a ~= "" and a == b
end

local function frNormalize(s)
    s = string.lower(tostring(s or ""))
    s = string.gsub(s, "|c%x%x%x%x%x%x%x%x", " ")
    s = string.gsub(s, "|r", " ")
    s = string.gsub(s, "|H.-|h(.-)|h", "%1")
    s = string.gsub(s, "[%p%c]", " ")
    s = string.gsub(s, "%s+", " ")
    return frTrim(s)
end

local function frPhraseHas(s, phrase)
    s = frNormalize(s)
    phrase = frNormalize(phrase)
    if s == "" or phrase == "" then return false end
    return string.find(" " .. s .. " ", " " .. phrase .. " ", 1, true) ~= nil
end

local function frHex(s)
    s = tostring(s or "")
    local out = ""
    local i
    for i = 1, string.len(s) do
        out = out .. string.format("%02x", string.byte(s, i))
    end
    return out
end

local function frUnhex(s)
    s = tostring(s or "")
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

local function frSplit(s, delimiter)
    local result = {}
    s = tostring(s or "")
    delimiter = tostring(delimiter or ":")
    if delimiter == "" then return result end
    local startAt = 1
    while true do
        local at = string.find(s, delimiter, startAt, true)
        if at then
            result[table.getn(result) + 1] = string.sub(s, startAt, at - 1)
            startAt = at + string.len(delimiter)
        else
            result[table.getn(result) + 1] = string.sub(s, startAt)
            break
        end
    end
    return result
end

local function frValidPlayerName(name)
    name = frTrim(name)
    if name == "" or string.len(name) > 32 then return false end
    if string.find(name, "[%c%s:;,=|]") then return false end
    return true
end

local function frResolveApi()
    local api = W112_SUMMONSCOUT_API_V1
    if type(api) ~= "table"
        or type(api.whisperInviteDecision) ~= "function"
        or type(api.tryWhisperInvite) ~= "function"
        or type(api.FindLocation) ~= "function"
        or type(api.GetLocationCatalog) ~= "function" then
        return nil
    end
    return api
end

local function frCatalog(api)
    local byId = {}
    if not api or type(api.GetLocationCatalog) ~= "function" then return byId end
    local list = api.GetLocationCatalog()
    if type(list) ~= "table" then return byId end
    local i
    for i = 1, table.getn(list) do
        local loc = list[i]
        if type(loc) == "table" and loc.id then
            byId[frLower(loc.id)] = loc
        end
    end
    return byId
end

local function frDisplayLabel(api, destination)
    destination = frLower(destination)
    if DISPLAY_LABELS[destination] then return DISPLAY_LABELS[destination] end
    local loc = frCatalog(api)[destination]
    return loc and tostring(loc.label or loc.id) or destination
end

local function frCurrentServices(api)
    local result = {}
    local seen = {}
    local service = frLower(SummonScoutDB and SummonScoutDB.service or "")
    if service == "" or service == "all" then return result end
    local catalog = frCatalog(api)
    local token
    for token in string.gfind(service, "[^,]+") do
        local id = frLower(token)
        if id ~= "" and not seen[id] and catalog[id] then
            seen[id] = true
            result[table.getn(result) + 1] = id
        end
    end
    table.sort(result)
    return result
end

local function frServicesCsv(api)
    return table.concat(frCurrentServices(api), ",")
end

local function frLocalServes(api, destination)
    destination = frLower(destination)
    if destination == "" then return false end
    local services = frCurrentServices(api)
    local i
    for i = 1, table.getn(services) do
        if services[i] == destination then return true end
    end
    return false
end

local function frMasterName()
    return frTrim(SummonScoutDB and SummonScoutDB.masterName or "")
end

local function frPlayerName()
    return frTrim(UnitName and UnitName("player") or "")
end

local function frIsHub()
    local me = frPlayerName()
    local master = frMasterName()
    return F.hubLearned or (me ~= "" and master ~= "" and frSame(me, master))
end

local function frSendRawWhisper(target, text)
    target = frTrim(target)
    text = tostring(text or "")
    if not frValidPlayerName(target) or text == "" or string.len(text) > 240 or not SendChatMessage then
        return false
    end
    if pcall then
        local ok = pcall(SendChatMessage, text, "WHISPER", nil, target)
        return ok and true or false
    end
    SendChatMessage(text, "WHISPER", nil, target)
    return true
end

local function frSendCustomer(target, text)
    if not frValidPlayerName(target) then return false end
    text = tostring(text or "")
    if string.len(text) > 240 then text = string.sub(text, 1, 240) end
    return frSendRawWhisper(target, text)
end

local function frControl(target, code, fields)
    local text = PROTO .. " " .. tostring(code or "")
    local i
    fields = fields or {}
    for i = 1, table.getn(fields) do
        text = text .. ":" .. frHex(fields[i] or "")
    end
    return frSendRawWhisper(target, text)
end

local function frParseControl(raw)
    raw = tostring(raw or "")
    if string.sub(raw, 1, string.len(PROTO)) ~= PROTO then return nil end
    local rest = frTrim(string.sub(raw, string.len(PROTO) + 1))
    if rest == "" then return nil end
    local parts = frSplit(rest, ":")
    local code = parts[1]
    if not code or code == "" then return nil end
    local fields = {}
    local i
    for i = 2, table.getn(parts) do
        local decoded = frUnhex(parts[i])
        if decoded == nil then return nil end
        fields[table.getn(fields) + 1] = decoded
    end
    return code, fields
end

local function frDebug(text)
    if SummonScoutDB and SummonScoutDB.debug and DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage("|cff55ddffSummon fallback:|r " .. tostring(text or ""))
    end
end

local function frRemovePeerProviders(name)
    local destination, providers
    for destination, providers in pairs(F.providers) do
        if type(providers) == "table" then
            providers[frLower(name)] = nil
            if next(providers) == nil then F.providers[destination] = nil end
        end
    end
end

local function frRegisterProvider(name, services, seenAt)
    name = frTrim(name)
    if not frValidPlayerName(name) then return false end
    seenAt = tonumber(seenAt) or frNow()
    frRemovePeerProviders(name)

    local catalog = frCatalog(frResolveApi())
    local clean = {}
    local service
    for service in string.gfind(tostring(services or ""), "[^,]+") do
        local id = frLower(service)
        if id ~= "" and catalog[id] then
            clean[table.getn(clean) + 1] = id
            if type(F.providers[id]) ~= "table" then F.providers[id] = {} end
            F.providers[id][frLower(name)] = {
                name = name,
                seen = seenAt,
                lastAssigned = 0
            }
        end
    end

    F.peers[frLower(name)] = { name = name, seen = seenAt, services = table.concat(clean, ",") }
    F.directoryDirty = true
    return table.getn(clean) > 0
end

local function frRegisterLocalHub(api)
    if not frIsHub() then return end
    local me = frPlayerName()
    if not frValidPlayerName(me) then return end
    local services = frServicesCsv(api)
    if services == "" then
        frRemovePeerProviders(me)
        return
    end

    -- Refresh local hub entries without deleting remote providers.
    local destination
    for destination in string.gfind(services, "[^,]+") do
        destination = frLower(destination)
        if type(F.providers[destination]) ~= "table" then F.providers[destination] = {} end
        local existing = F.providers[destination][frLower(me)]
        F.providers[destination][frLower(me)] = {
            name = me,
            seen = frNow(),
            lastAssigned = existing and (existing.lastAssigned or 0) or 0
        }
    end
end

local function frPruneDirectory()
    local t = frNow()
    local changed = false
    local destination, providers, key, item
    for destination, providers in pairs(F.providers) do
        if type(providers) == "table" then
            for key, item in pairs(providers) do
                if type(item) ~= "table" or (t - (tonumber(item.seen) or 0)) > PROVIDER_TTL then
                    providers[key] = nil
                    changed = true
                end
            end
            if next(providers) == nil then
                F.providers[destination] = nil
                changed = true
            end
        else
            F.providers[destination] = nil
            changed = true
        end
    end

    for key, item in pairs(F.peers) do
        if type(item) ~= "table" or (t - (tonumber(item.seen) or 0)) > PEER_TTL then
            F.peers[key] = nil
            changed = true
        end
    end
    if changed then F.directoryDirty = true end
end

local function frHubAvailableIds()
    local ids = {}
    local destination, providers
    for destination, providers in pairs(F.providers) do
        if type(providers) == "table" and next(providers) ~= nil then
            ids[table.getn(ids) + 1] = destination
        end
    end
    table.sort(ids)
    while table.getn(ids) > MAX_DIRECTORY_DESTINATIONS do
        table.remove(ids)
    end
    return ids
end

local function frSetRemoteDirectory(csv)
    local nextDirectory = {}
    local api = frResolveApi()
    local catalog = frCatalog(api)
    local token
    for token in string.gfind(tostring(csv or ""), "[^,]+") do
        local id = frLower(token)
        if id ~= "" and catalog[id] then nextDirectory[id] = true end
    end
    F.directory = nextDirectory
end

local function frSendDirectory(target)
    local ids = frHubAvailableIds()
    return frControl(target, "D", { table.concat(ids, ",") })
end

local function frPushDirectory()
    if not frIsHub() then return end
    local key, peer
    for key, peer in pairs(F.peers) do
        if type(peer) == "table" and frValidPlayerName(peer.name) then
            frSendDirectory(peer.name)
        end
    end
    F.directoryDirty = false
end

local function frAvailableIds(api)
    local seen = {}
    local ids = {}
    local localServices = frCurrentServices(api)
    local i, destination
    for i = 1, table.getn(localServices) do
        destination = localServices[i]
        if not seen[destination] then
            seen[destination] = true
            ids[table.getn(ids) + 1] = destination
        end
    end
    for destination in pairs(F.directory) do
        if not seen[destination] then
            seen[destination] = true
            ids[table.getn(ids) + 1] = destination
        end
    end
    if frIsHub() then
        local hubIds = frHubAvailableIds()
        for i = 1, table.getn(hubIds) do
            destination = hubIds[i]
            if not seen[destination] then
                seen[destination] = true
                ids[table.getn(ids) + 1] = destination
            end
        end
    end
    table.sort(ids)
    return ids
end

local function frAvailableText(api)
    local ids = frAvailableIds(api)
    local labels = {}
    local i
    for i = 1, table.getn(ids) do
        labels[table.getn(labels) + 1] = frDisplayLabel(api, ids[i])
    end
    return table.concat(labels, ", ")
end

local function frFindLocationById(api, destination)
    destination = frLower(destination)
    local loc = frCatalog(api)[destination]
    if loc then return loc end
    local found, ambiguous = api.FindLocation(destination)
    if not ambiguous and found and frLower(found.id) == destination then return found end
    return nil
end

local function frQuestionLike(raw, reason)
    local s = frNormalize(raw)
    if s == "" or SOCIAL_NOISE[s] then return false end
    if reason == "multi-service-needs-location" or reason == "ambiguous-location" then return true end
    if string.find(tostring(raw or ""), "?", 1, true) then return true end
    local i
    for i = 1, table.getn(QUESTION_CUES) do
        if frPhraseHas(s, QUESTION_CUES[i]) then return true end
    end
    return false
end

local function frPromptCustomer(api, sender)
    local available = frAvailableText(api)
    if available == "" then return false end
    local key = frLower(sender)
    local t = frNow()
    local last = tonumber(F.promptRecent[key]) or -100000
    F.pendingChoice[key] = { name = frTrim(sender), expires = t + CHOICE_TTL }
    if (t - last) < PROMPT_DEDUPE then return true end
    F.promptRecent[key] = t
    frSendCustomer(sender, "I can help with summons. Available: " .. available .. ". Reply with the destination.")
    frDebug("fallback choices -> " .. tostring(sender) .. " [" .. available .. "]")
    return true
end

local function frAckCustomer(api, customer, destination, ok)
    local label = frDisplayLabel(api, destination)
    if ok then
        frSendCustomer(customer, "Got it - the " .. label .. " summoner is inviting you now.")
    else
        frSendCustomer(customer, label .. " is currently unavailable. Please try again shortly.")
    end
end

local function frHandleRouteAck(api, customer, destination, origin, status)
    if not frSame(origin, frPlayerName()) then return false end
    local key = frLower(customer) .. "@" .. frLower(destination)
    local pending = F.pendingRoute[key]
    if not pending then return false end
    F.pendingRoute[key] = nil
    frAckCustomer(api, customer, destination, tostring(status or "") == "1")
    return true
end

local function frSelectProvider(destination)
    destination = frLower(destination)
    local providers = F.providers[destination]
    if type(providers) ~= "table" then return nil end
    local t = frNow()
    local best = nil
    local item
    for _, item in pairs(providers) do
        if type(item) == "table" and (t - (tonumber(item.seen) or 0)) <= PROVIDER_TTL then
            if not best
                or (tonumber(item.lastAssigned) or 0) < (tonumber(best.lastAssigned) or 0)
                or ((tonumber(item.lastAssigned) or 0) == (tonumber(best.lastAssigned) or 0)
                    and tostring(item.name or "") < tostring(best.name or "")) then
                best = item
            end
        end
    end
    if best then best.lastAssigned = t end
    return best
end

local function frInviteLocally(api, customer, destination)
    if not frLocalServes(api, destination) then return false, "wrong-service" end
    local loc = frFindLocationById(api, destination)
    if not loc then return false, "unknown-destination" end
    if type(api.isInGroup) == "function" and api.isInGroup(customer) then
        return true, "already-grouped"
    end
    local ok, reason = api.tryWhisperInvite(customer, loc)
    if ok or reason == "duplicate-event" then return true, reason or "invited" end
    return false, reason or "rejected"
end

local function frSendAckToOrigin(api, origin, customer, destination, ok)
    if frSame(origin, frPlayerName()) then
        return frHandleRouteAck(api, customer, destination, origin, ok and "1" or "0")
    end
    return frControl(origin, "A", { customer, destination, origin, ok and "1" or "0" })
end

local function frHubRoute(api, origin, customer, destination)
    if not frIsHub() then return false end
    origin = frTrim(origin)
    customer = frTrim(customer)
    destination = frLower(destination)
    if not frValidPlayerName(origin) or not frValidPlayerName(customer) or destination == "" then return false end

    frRegisterLocalHub(api)
    frPruneDirectory()
    local provider = frSelectProvider(destination)
    if not provider or not frValidPlayerName(provider.name) then
        frSendAckToOrigin(api, origin, customer, destination, false)
        return true
    end

    if frSame(provider.name, frPlayerName()) then
        local ok = frInviteLocally(api, customer, destination)
        frSendAckToOrigin(api, origin, customer, destination, ok)
        return true
    end

    if not frControl(provider.name, "X", { customer, destination, origin }) then
        frSendAckToOrigin(api, origin, customer, destination, false)
    end
    return true
end

local function frRouteCustomer(api, customer, destination)
    customer = frTrim(customer)
    destination = frLower(destination)
    if not frValidPlayerName(customer) or destination == "" then return false end

    local key = frLower(customer) .. "@" .. destination
    F.pendingChoice[frLower(customer)] = nil

    if frLocalServes(api, destination) then
        local ok = frInviteLocally(api, customer, destination)
        if ok then
            frSendCustomer(customer, "Got it - inviting you to " .. frDisplayLabel(api, destination) .. ".")
        else
            frAckCustomer(api, customer, destination, false)
        end
        return true
    end

    local available = false
    if F.directory[destination] then available = true end
    if frIsHub() and F.providers[destination] then available = true end
    if not available then
        frAckCustomer(api, customer, destination, false)
        return true
    end

    F.pendingRoute[key] = {
        customer = customer,
        destination = destination,
        started = frNow(),
        expires = frNow() + ROUTE_TIMEOUT
    }
    frSendCustomer(customer, "Got it - checking the " .. frDisplayLabel(api, destination) .. " summoner now.")

    if frIsHub() then
        frHubRoute(api, frPlayerName(), customer, destination)
        return true
    end

    local master = frMasterName()
    if not frValidPlayerName(master) then
        F.pendingRoute[key] = nil
        frAckCustomer(api, customer, destination, false)
        return true
    end
    if not frControl(master, "R", { customer, destination, frPlayerName() }) then
        F.pendingRoute[key] = nil
        frAckCustomer(api, customer, destination, false)
    end
    return true
end

local function frHandleControl(api, sender, code, fields)
    sender = frTrim(sender)
    if not frValidPlayerName(sender) or not code then return true end

    if code == "H" then
        local services = fields[1] or ""
        -- Receiving a valid fleet HELLO is sufficient to learn that this client is
        -- the configured hub even if its own masterName field is intentionally blank.
        F.hubLearned = true
        frRegisterLocalHub(api)
        frRegisterProvider(sender, services, frNow())
        frSendDirectory(sender)
        F.nextDirectoryPushAt = frNow() + 0.20
        return true
    end

    local master = frMasterName()
    if code == "D" then
        if master ~= "" and not frSame(sender, master) then return true end
        frSetRemoteDirectory(fields[1] or "")
        return true
    end

    if code == "R" then
        if not frIsHub() then return true end
        local customer = fields[1] or ""
        local destination = fields[2] or ""
        local origin = fields[3] or ""
        if not frSame(origin, sender) then return true end
        frHubRoute(api, origin, customer, destination)
        return true
    end

    if code == "X" then
        if master == "" or not frSame(sender, master) then return true end
        local customer = fields[1] or ""
        local destination = fields[2] or ""
        local origin = fields[3] or ""
        local ok = false
        if frValidPlayerName(customer) and frValidPlayerName(origin) then
            ok = frInviteLocally(api, customer, destination)
        end
        frControl(master, "A", { customer, destination, origin, ok and "1" or "0" })
        return true
    end

    if code == "A" then
        local customer = fields[1] or ""
        local destination = fields[2] or ""
        local origin = fields[3] or ""
        local status = fields[4] or "0"

        if frIsHub() and not frSame(origin, frPlayerName()) then
            local providers = F.providers[frLower(destination)]
            local provider = providers and providers[frLower(sender)] or nil
            if provider then
                frControl(origin, "A", { customer, destination, origin, status })
            end
            return true
        end

        if master ~= "" and frSame(sender, master) then
            frHandleRouteAck(api, customer, destination, origin, status)
        end
        return true
    end

    return true
end

local function frHandleCustomerWhisper(api, message, sender)
    if not SummonScoutDB or not SummonScoutDB.enabled or not SummonScoutDB.whisperAutoInvite then return end
    sender = frTrim(sender)
    if not frValidPlayerName(sender) or frSame(sender, frPlayerName()) then return end

    local accept, loc, reason = api.whisperInviteDecision(message or "")
    if accept then return end

    local key = frLower(sender)
    local pending = F.pendingChoice[key]
    local destination = loc and frLower(loc.id or "") or ""

    -- A known other destination is an explicit routing decision even when the
    -- customer did not first see our fallback prompt.
    if destination ~= "" and reason == "other-location" then
        frRouteCustomer(api, sender, destination)
        return
    end

    -- During an active fallback choice, a bare recognized destination is enough.
    if pending and frNow() <= (tonumber(pending.expires) or 0) and destination ~= "" then
        frRouteCustomer(api, sender, destination)
        return
    end

    if pending and frNow() > (tonumber(pending.expires) or 0) then
        F.pendingChoice[key] = nil
        pending = nil
    end

    if frQuestionLike(message, reason) then
        frPromptCustomer(api, sender)
    end
end

local function frSendHello(api, force)
    local master = frMasterName()
    local me = frPlayerName()
    if not frValidPlayerName(master) or frSame(master, me) then return false end
    if not SummonScoutDB or not SummonScoutDB.enabled then return false end

    local services = frServicesCsv(api)
    if services == "" then return false end
    local t = frNow()
    if not force and t < (F.nextHelloAt or 0) and services == (F.lastHelloServices or "") then return false end

    if frControl(master, "H", { services }) then
        F.lastHelloServices = services
        F.nextHelloAt = t + HELLO_INTERVAL
        return true
    end
    F.nextHelloAt = t + 3.0
    return false
end

local function frExpireCustomerState(api)
    local t = frNow()
    local key, item
    for key, item in pairs(F.pendingChoice) do
        if type(item) ~= "table" or t > (tonumber(item.expires) or 0) then
            F.pendingChoice[key] = nil
        end
    end

    for key, item in pairs(F.pendingRoute) do
        if type(item) ~= "table" then
            F.pendingRoute[key] = nil
        elseif t > (tonumber(item.expires) or 0) then
            F.pendingRoute[key] = nil
            frAckCustomer(api, item.customer or "", item.destination or "", false)
        end
    end

    for key, item in pairs(F.promptRecent) do
        if (t - (tonumber(item) or 0)) > 180 then F.promptRecent[key] = nil end
    end
end

local M = {}

function M.Init()
    if not SummonScoutDB then SummonScoutDB = {} end
    if SummonScoutDB.fallbackRouterEnabled == nil then SummonScoutDB.fallbackRouterEnabled = true end
    if F.moduleVersion ~= VERSION then
        F.pendingChoice = {}
        F.promptRecent = {}
        F.pendingRoute = {}
        F.providers = {}
        F.peers = {}
        F.directory = {}
        F.hubLearned = false
        F.lastHelloServices = ""
        F.moduleVersion = VERSION
    end
    F.nextHelloAt = frNow() + 0.75
    F.nextMaintenanceAt = 0
    H.RegisterEvent("PLAYER_LOGIN")
    H.RegisterEvent("CHAT_MSG_WHISPER")
    W112_SUMMONSCOUT_FALLBACK_ROUTER_VERSION = VERSION
end

function M.OnEvent(ev, a1, a2)
    local api = frResolveApi()
    if not api then return end

    if ev == "PLAYER_LOGIN" then
        F.nextHelloAt = frNow() + 0.75
        F.lastHelloServices = ""
        frRegisterLocalHub(api)
        return
    end

    if ev ~= "CHAT_MSG_WHISPER" then return end
    local message = tostring(a1 or "")
    local sender = frTrim(a2 or "")
    local code, fields = frParseControl(message)
    if code then
        frHandleControl(api, sender, code, fields)
        return
    end

    if SummonScoutDB and SummonScoutDB.fallbackRouterEnabled then
        frHandleCustomerWhisper(api, message, sender)
    end
end

function M.OnUpdate()
    local api = frResolveApi()
    if not api then return end
    local t = frNow()

    frSendHello(api, false)
    frRegisterLocalHub(api)

    if t >= (F.nextMaintenanceAt or 0) then
        F.nextMaintenanceAt = t + 0.50
        frPruneDirectory()
        frExpireCustomerState(api)
    end

    if frIsHub() and F.directoryDirty and t >= (F.nextDirectoryPushAt or 0) then
        F.nextDirectoryPushAt = t + 0.50
        frPushDirectory()
    end
end

function M.Shutdown()
    -- Persistent state intentionally survives hot replacement. TTLs make stale
    -- peers/routes disappear without touching core SummonScout state.
end

H.Register("fallbackrouter", M, VERSION)
W112_SUMMONSCOUT_FALLBACK_ROUTER_VERSION = VERSION
