-- SummonScout fleet control-chat burst guard for WoW 1.12.1 / Lua 5.0.
--
-- The canonical FleetPresence bridge already reuses FCV to refresh fallbackrouter
-- provider TTLs, so the older H/D heartbeat path is redundant for configured fleet
-- clients. FleetCounter also used to fan FCE to every peer every HB in addition to
-- replying to each FCV, which created server-side chat flood throttling on the master.
--
-- This guard keeps transaction traffic (R/X/A, grants, acks) untouched. It only:
--   * suppresses redundant fallback H/D background chatter while canonical FCV is active;
--   * disables periodic FleetCounter full fanout;
--   * serializes FCV->FCE capability replies on the master with a safe gap;
--   * coalesces duplicate pending FCE replies per peer.

local H=W112_SUMMONSCOUT_HOT
local C=W112_SUMMONSCOUT_FLEET_COUNTER_V1
if not H or type(H.GetState)~="function" or type(C)~="table" then return end

local VERSION="1"
local SEND_GAP=2.20
local SUPPRESS_HELLO_FOR=3600
local G={pending={},order={},nextSend=0,nextTick=0}

local function trim(v)
    local s=tostring(v or "")
    s=string.gsub(s,"^%s+","")
    return string.gsub(s,"%s+$","")
end
local function lower(v) return string.lower(trim(v)) end
local function now() return GetTime and GetTime() or 0 end

local function validName(v)
    if type(C.validName)=="function" then return C.validName(v) end
    v=trim(v)
    return string.len(v)>=2 and string.len(v)<=24 and not string.find(v,"[^%a%-]")
end

local function localServiceCsv()
    local raw=lower(SummonScoutDB and SummonScoutDB.service or "")
    if raw=="" or raw=="all" then return "" end
    local out,seen={},{}
    local token
    for token in string.gfind(raw,"[^,]+") do
        token=lower(token)
        if token~="" and not seen[token] then
            seen[token]=true
            out[table.getn(out)+1]=token
        end
    end
    table.sort(out)
    return table.concat(out,",")
end

local function enqueueCapability(target)
    target=trim(target)
    if not validName(target) then return false end
    local key=lower(target)
    if not G.pending[key] then
        G.order[table.getn(G.order)+1]=key
    end
    G.pending[key]=target
    return true
end

local baseCapability=C.capability
if type(baseCapability)=="function" and not C.__fleetChatBurstCapabilityV1 then
    C.capability=function(target)
        return enqueueCapability(target)
    end
    C.__fleetChatBurstCapabilityV1=true
end

-- Periodic full-fleet fanout is unnecessary: every subordinate sends FCV and
-- receives a fresh FCE reply. GUI setting changes propagate on the next FCV.
if type(C.broadcast)=="function" and not C.__fleetChatBurstBroadcastV1 then
    C.broadcast=function() return true end
    C.__fleetChatBurstBroadcastV1=true
end

local function drainCapability()
    if type(C.isMaster)~="function" or not C.isMaster() then
        G.pending={}; G.order={}; return
    end
    local t=now()
    if t<(G.nextSend or 0) then return end

    while table.getn(G.order)>0 do
        local key=table.remove(G.order,1)
        local target=G.pending[key]
        G.pending[key]=nil
        if target and validName(target) then
            G.nextSend=t+SEND_GAP
            baseCapability(target)
            return
        end
    end
end

local function suppressLegacyFallbackChatter()
    local F=H.GetState("fallbackrouter")
    if type(F)~="table" or type(C.master)~="function" or type(C.isMaster)~="function" then return end
    local master=C.master()
    if not validName(master) then return end

    if C.isMaster() then
        -- FleetPresence keeps canonical providers current from FCV. Do not turn
        -- every provider refresh into a full D broadcast to all peers.
        F.directoryDirty=false
        F.nextDirectoryPushAt=now()+SUPPRESS_HELLO_FOR
        return
    end

    -- Non-master directory is refreshed from FCE by CrossRouteTransaction.
    -- Match frServicesCsv so frSendHello sees no service change and remains idle.
    F.lastHelloServices=localServiceCsv()
    F.nextHelloAt=now()+SUPPRESS_HELLO_FOR
end

local frame=CreateFrame and CreateFrame("Frame") or nil
if frame then
    frame:RegisterEvent("PLAYER_LOGIN")
    frame:SetScript("OnEvent",function()
        if event=="PLAYER_LOGIN" then
            G.nextSend=now()+0.75
            suppressLegacyFallbackChatter()
        end
    end)
    frame:SetScript("OnUpdate",function()
        local t=now()
        if t<(G.nextTick or 0) then return end
        G.nextTick=t+0.10
        suppressLegacyFallbackChatter()
        drainCapability()
    end)
end

W112_SUMMONSCOUT_FLEET_CHAT_BURST_GUARD_VERSION=VERSION
