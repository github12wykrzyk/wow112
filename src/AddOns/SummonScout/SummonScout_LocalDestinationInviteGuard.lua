-- Hard local-destination + slave-readiness invite guard for SummonScout / WoW 1.12.1 / Lua 5.0.
-- Cold-load module by design: it is kept out of the 256 KiB WhisperConfirm HOT fanout carrier.
-- v3 also preserves the exact rejection reason for routed-invite diagnosis without weakening safety.

local H = W112_SUMMONSCOUT_HOT
if not H or type(H.Register) ~= "function" or type(H.GetState) ~= "function" then return end

local VERSION = "3-destination-slave-safety-route-reason"
local G = H.GetState("localdestinationinviteguard")
local TOKEN = {}
local ENSURE_INTERVAL = 0.50
G.nextEnsureAt = tonumber(G.nextEnsureAt) or 0

local function gdNow()
    if GetTime then return GetTime() end
    return 0
end

local function gdTrim(s)
    s = tostring(s or "")
    s = string.gsub(s, "^%s+", "")
    return string.gsub(s, "%s+$", "")
end

local function gdLower(s)
    return string.lower(gdTrim(s or ""))
end

local function gdSame(a,b)
    a=gdLower(a); b=gdLower(b); return a~="" and a==b
end

local function gdValidName(name)
    name=gdTrim(name)
    return name~="" and string.len(name)<=32 and not string.find(name,"[%c%s:;,=|]")
end

local function gdSafeReason(reason)
    local s=gdLower(reason or "rejected")
    s=string.gsub(s,"[^%w%-%_]","-")
    s=string.gsub(s,"%-+","-")
    if string.len(s)>32 then s=string.sub(s,1,32) end
    if s=="" then s="rejected" end
    return s
end

local function gdReserved(raw)
    raw = tostring(raw or "")
    return string.sub(raw, 1, 7) == "[SSFR1]"
        or string.sub(raw, 1, 7) == "[SSWR1]"
        or string.sub(raw, 1, 5) == "[SSI "
end

local function gdSafetyBlocked()
    if W112_SUMMONSCOUT_SLAVE_SAFETY_READY == false then return true end
    if not SummonScoutDB or SummonScoutDB.enabled ~= true then return true end
    return false
end

local function gdServiceContains(id)
    local service = gdLower(SummonScoutDB and SummonScoutDB.service or "all")
    id = gdLower(id or "")
    if service == "" or service == "all" then return true end
    if id == "" then return false end
    return string.find("," .. service .. ",", "," .. id .. ",", 1, true) ~= nil
end

local function gdResolve(raw)
    local api = W112_SUMMONSCOUT_API_V1
    if type(api) ~= "table" or type(api.FindLocation) ~= "function" then return nil, true end
    if pcall then
        local ok, loc, ambiguous = pcall(api.FindLocation, raw or "")
        if not ok then return nil, true end
        return loc, ambiguous and true or false
    end
    local loc, ambiguous = api.FindLocation(raw or "")
    return loc, ambiguous and true or false
end

local function gdBlockLegacyWhisper(raw)
    if gdSafetyBlocked() then return true, "slave-safety" end
    if gdReserved(raw) then return true, "control" end
    local service = gdLower(SummonScoutDB and SummonScoutDB.service or "all")
    if service == "" or service == "all" then return false, nil end

    local loc, ambiguous = gdResolve(raw)
    if ambiguous then return true, "ambiguous" end
    if type(loc) == "table" and loc.id and not gdServiceContains(loc.id) then
        return true, tostring(loc.label or loc.id)
    end
    return false, nil
end

local function gdDebug(text)
    if SummonScoutDB and SummonScoutDB.debug and DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage("|cffff5555SummonScout invite guard:|r " .. tostring(text or ""))
    end
end

local function gdReportRouteFailure(name,loc,reason)
    local me=gdTrim(UnitName and UnitName("player") or "")
    local master=gdTrim(SummonScoutDB and SummonScoutDB.masterName or "")
    local dest=type(loc)=="table" and gdLower(loc.id or "") or "unknown"
    local safe=gdSafeReason(reason)
    local ready=W112_SUMMONSCOUT_SLAVE_SAFETY_READY==false and "0" or "1"
    local enabled=SummonScoutDB and SummonScoutDB.enabled==true and "1" or "0"
    local service=gdLower(SummonScoutDB and SummonScoutDB.service or "")
    local record={ts=gdNow(),provider=me,customer=gdTrim(name),destination=dest,reason=safe,ready=ready,enabled=enabled,service=service}
    G.lastRouteFailure=record
    W112_SUMMONSCOUT_ROUTE_LAST_FAILURE=record
    gdDebug("ROUTEFAIL customer="..tostring(record.customer).." dest="..dest.." reason="..safe.." ready="..ready.." enabled="..enabled.." service="..service)
    if not SendChatMessage or not gdValidName(master) or gdSame(master,me) then return end
    local payload="[SSI ROUTEFAIL] "..me.." -> "..gdTrim(name).." / "..dest.." / "..safe.." / ready="..ready.." enabled="..enabled.." service="..service
    if string.len(payload)>235 then payload=string.sub(payload,1,235) end
    if pcall then pcall(SendChatMessage,payload,"WHISPER",nil,master) else SendChatMessage(payload,"WHISPER",nil,master) end
end

local function gdDetach()
    if type(G.apiOwner) == "table" and type(G.apiWrapper) == "function"
        and G.apiOwner.tryWhisperInvite == G.apiWrapper then
        G.apiOwner.tryWhisperInvite = G.apiBase
    end
    if type(G.postModule) == "table" and type(G.postWrapper) == "function"
        and G.postModule.OnEvent == G.postWrapper then
        G.postModule.OnEvent = G.postBase
    end
    if type(G.confirmModule) == "table" and type(G.confirmWrapper) == "function"
        and G.confirmModule.OnEvent == G.confirmWrapper then
        G.confirmModule.OnEvent = G.confirmBase
    end

    G.apiOwner, G.apiBase, G.apiWrapper = nil, nil, nil
    G.postModule, G.postBase, G.postWrapper = nil, nil, nil
    G.confirmModule, G.confirmBase, G.confirmWrapper = nil, nil, nil
end

local function gdInstallApi()
    local api = W112_SUMMONSCOUT_API_V1
    if type(api) ~= "table" or type(api.tryWhisperInvite) ~= "function" then return false end
    if G.apiOwner == api and api.tryWhisperInvite == G.apiWrapper then return true end

    if type(G.apiOwner) == "table" and G.apiOwner.tryWhisperInvite == G.apiWrapper then
        G.apiOwner.tryWhisperInvite = G.apiBase
    end

    local base = api.tryWhisperInvite
    local wrapper = function(name, loc)
        if gdSafetyBlocked() then
            gdDebug("core invite blocked -> " .. tostring(name or "?") .. " [slave-safety/disabled]")
            gdReportRouteFailure(name,loc,"slave-safety-blocked")
            return false, "slave-safety-blocked"
        end
        if type(loc) == "table" and loc.id and not gdServiceContains(loc.id) then
            gdDebug("core invite blocked -> " .. tostring(name or "?") .. " ["
                .. tostring(loc.label or loc.id) .. "] serving="
                .. tostring(SummonScoutDB and SummonScoutDB.service or "all"))
            gdReportRouteFailure(name,loc,"wrong-service-hard-guard")
            return false, "wrong-service-hard-guard"
        end
        local ok,reason=base(name, loc)
        if not ok and reason~="duplicate-event" then gdReportRouteFailure(name,loc,reason or "rejected") end
        return ok,reason
    end

    api.tryWhisperInvite = wrapper
    G.apiOwner, G.apiBase, G.apiWrapper = api, base, wrapper
    return true
end

local function gdClearLegacyPending(prefix, sender)
    local key = gdLower(sender or "")
    if prefix == "post" then
        local state = H.GetState("postpay")
        if type(state) == "table" and type(state.directInvitePending) == "table" then
            state.directInvitePending[key] = nil
        end
    else
        local state = H.GetState("whisperconfirm")
        if type(state) == "table" then
            if type(state.candidates) == "table" then state.candidates[key] = nil end
            if type(state.pending) == "table" then state.pending[key] = nil end
            if type(state.confirmations) == "table" then state.confirmations[key] = nil end
        end
    end
end

local function gdInstallModule(moduleName, prefix)
    local module = H.modules and H.modules[moduleName] or nil
    if type(module) ~= "table" or type(module.OnEvent) ~= "function" then return false end

    local mf, bf, wf = prefix .. "Module", prefix .. "Base", prefix .. "Wrapper"
    if G[mf] == module and module.OnEvent == G[wf] then return true end

    if type(G[mf]) == "table" and G[mf].OnEvent == G[wf] then G[mf].OnEvent = G[bf] end

    local base = module.OnEvent
    local wrapper = function(ev, a1, a2, a3)
        if ev == "CHAT_MSG_WHISPER" then
            local blocked, reason = gdBlockLegacyWhisper(a1 or "")
            if blocked then
                gdClearLegacyPending(prefix, a2 or "")
                if reason ~= "control" then
                    gdDebug(moduleName .. " blocked -> " .. tostring(a2 or "?")
                        .. " [" .. tostring(reason or "guard") .. "]")
                end
                return nil
            end
        end
        return base(ev, a1, a2, a3)
    end

    module.OnEvent = wrapper
    G[mf], G[bf], G[wf] = module, base, wrapper
    return true
end

local function gdResetTransient()
    local post = H.GetState("postpay")
    if type(post) == "table" then post.directInvitePending = {} end
    local confirm = H.GetState("whisperconfirm")
    if type(confirm) == "table" then
        confirm.candidates = {}
        confirm.pending = {}
        confirm.confirmations = {}
    end
end

local function gdEnsure()
    gdInstallApi()
    gdInstallModule("postpay", "post")
    gdInstallModule("whisperconfirm", "confirm")
    if gdSafetyBlocked() then gdResetTransient() end
end

local M = {}

function M.Init()
    gdDetach()
    G.ownerToken = TOKEN
    G.nextEnsureAt = 0
    gdResetTransient()
    gdEnsure()
    W112_SUMMONSCOUT_LOCAL_DESTINATION_INVITE_GUARD_VERSION = VERSION
end

function M.OnUpdate()
    local t = gdNow()
    if t < (tonumber(G.nextEnsureAt) or 0) then return end
    G.nextEnsureAt = t + ENSURE_INTERVAL
    gdEnsure()
end

function M.Shutdown()
    if G.ownerToken ~= TOKEN then return end
    gdDetach()
    G.ownerToken = nil
end

H.Register("localdestinationinviteguard", M, VERSION)
W112_SUMMONSCOUT_LOCAL_DESTINATION_INVITE_GUARD_VERSION = VERSION
