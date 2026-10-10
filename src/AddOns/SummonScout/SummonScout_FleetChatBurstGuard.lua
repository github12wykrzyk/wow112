-- SummonScout fleet control-chat cadence guard for WoW 1.12.1 / Lua 5.0.
-- Claude-reviewed v2 design: FCV stays the single presence heartbeat; FCE is
-- state-change + slow keepalive, never an unconditional reply to every FCV.
-- Transaction traffic (R/X/A, advert grant/ack) is not queued here.

local H=W112_SUMMONSCOUT_HOT
local C=W112_SUMMONSCOUT_FLEET_COUNTER_V1
if not H or type(H.GetState)~="function" or type(C)~="table" then return end

local VERSION="2"
local SEND_GAP=4.50
local KEEPALIVE=28.0
local STARTUP_GRACE=3.0
local SUPPRESS_HELLO_FOR=3600
local G={pending={},nextSend=0,nextTick=0,lastSent={},lastHash={},globalHash="",startupAt=0}

local function trim(v)
    local s=tostring(v or "")
    s=string.gsub(s,"^%s+",""); return string.gsub(s,"%s+$","")
end
local function lower(v) return string.lower(trim(v)) end
local function now() return GetTime and GetTime() or 0 end
local function validName(v)
    if type(C.validName)=="function" then return C.validName(v) end
    v=trim(v); return string.len(v)>=2 and string.len(v)<=24 and not string.find(v,"[^%a%-]")
end
local function freshPeer(p)
    return type(p)=="table" and (now()-(tonumber(p.seen) or -100000))<=(tonumber(C.TTL) or 38)
end
local function payloadHash()
    local active=(type(C.active)=="function" and C.active()) and "1" or "0"
    local price=type(C.price)=="function" and tostring(C.price()) or "0"
    local roster=type(C.rosterCsv)=="function" and tostring(C.rosterCsv() or "") or ""
    local svc=type(C.freshServices)=="function" and tostring(C.freshServices() or "") or ""
    return active.."|"..price.."|"..roster.."|"..svc
end
local function livePeers()
    local out={}; local k,p
    for k,p in pairs(C.peers or {}) do
        if freshPeer(p) and validName(p.name) then out[table.getn(out)+1]=p.name end
    end
    table.sort(out,function(a,b) return lower(a)<lower(b) end)
    return out
end
local function enqueue(target,due,force)
    target=trim(target); if not validName(target) then return false end
    local key=lower(target); due=tonumber(due) or now()
    local old=G.pending[key]
    if not old then
        G.pending[key]={name=target,due=due,force=force and true or false}
    else
        old.name=target
        if due<(old.due or due) then old.due=due end
        if force then old.force=true end
    end
    return true
end

local baseCapability=C.capability
if type(baseCapability)=="function" and not C.__fleetChatCadenceV2 then
    C.capability=function(target)
        -- onHeartbeat still calls capability after every FCV. Do not answer every
        -- heartbeat; the cadence loop below decides whether this peer is due.
        target=trim(target); if not validName(target) then return false end
        local key=lower(target); local t=now(); local age=t-(tonumber(G.lastSent[key]) or -100000)
        if G.lastSent[key]==nil then enqueue(target,math.max(t,G.startupAt),true)
        elseif age>=KEEPALIVE then enqueue(target,t,false) end
        return true
    end
    C.__fleetChatCadenceV2=true
end

-- GUI/state changes are detected by payloadHash and fanned out with pacing.
if type(C.broadcast)=="function" and not C.__fleetChatCadenceBroadcastV2 then
    C.broadcast=function()
        G.globalHash="" -- force state-change detection on next cadence tick
        return true
    end
    C.__fleetChatCadenceBroadcastV2=true
end

local function queueStateChange()
    if type(C.isMaster)~="function" or not C.isMaster() then return end
    local hash=payloadHash()
    if hash==G.globalHash then return end
    G.globalHash=hash
    local peers=livePeers(); local i; local base=math.max(now(),G.startupAt)
    for i=1,table.getn(peers) do
        enqueue(peers[i],base+(i-1)*SEND_GAP,true)
    end
end

local function queueKeepalives()
    if type(C.isMaster)~="function" or not C.isMaster() then return end
    local peers=livePeers(); local i,name,key,t=1,nil,nil,now()
    for i=1,table.getn(peers) do
        name=peers[i]; key=lower(name)
        if G.lastSent[key]==nil then
            enqueue(name,math.max(t,G.startupAt)+(i-1)*SEND_GAP,true)
        elseif (t-(tonumber(G.lastSent[key]) or 0))>=KEEPALIVE then
            enqueue(name,t+(i-1)*SEND_GAP,false)
        end
    end
end

local function drainCapability()
    if type(C.isMaster)~="function" or not C.isMaster() then G.pending={}; return end
    local t=now(); if t<(G.nextSend or 0) then return end
    local bestKey,best=nil,nil; local k,item
    for k,item in pairs(G.pending) do
        if type(item)=="table" and (item.due or 0)<=t then
            if not best or (item.due or 0)<(best.due or 0) or ((item.due or 0)==(best.due or 0) and k<bestKey) then
                bestKey=k; best=item
            end
        end
    end
    if not best then return end
    G.pending[bestKey]=nil
    G.nextSend=t+SEND_GAP
    local ok=baseCapability(best.name)
    if ok then
        G.lastSent[bestKey]=t; G.lastHash[bestKey]=payloadHash()
    end
end

local function localServiceCsv()
    local raw=lower(SummonScoutDB and SummonScoutDB.service or "")
    if raw=="" or raw=="all" then return "" end
    local out,seen={},{}; local token
    for token in string.gfind(raw,"[^,]+") do token=lower(token); if token~="" and not seen[token] then seen[token]=true; out[table.getn(out)+1]=token end end
    table.sort(out); return table.concat(out,",")
end
local function suppressLegacyFallbackChatter()
    local F=H.GetState("fallbackrouter")
    if type(F)~="table" or type(C.master)~="function" or type(C.isMaster)~="function" then return end
    local master=C.master(); if not validName(master) then return end
    if C.isMaster() then
        F.directoryDirty=false; F.nextDirectoryPushAt=now()+SUPPRESS_HELLO_FOR
    else
        F.lastHelloServices=localServiceCsv(); F.nextHelloAt=now()+SUPPRESS_HELLO_FOR
    end
end

local frame=CreateFrame and CreateFrame("Frame") or nil
if frame then
    frame:RegisterEvent("PLAYER_LOGIN")
    frame:SetScript("OnEvent",function()
        if event=="PLAYER_LOGIN" then
            G.startupAt=now()+STARTUP_GRACE; G.nextSend=G.startupAt; G.globalHash=""
            suppressLegacyFallbackChatter()
        end
    end)
    frame:SetScript("OnUpdate",function()
        local t=now(); if t<(G.nextTick or 0) then return end; G.nextTick=t+0.25
        suppressLegacyFallbackChatter(); queueStateChange(); queueKeepalives(); drainCapability()
    end)
end

W112_SUMMONSCOUT_FLEET_CHAT_BURST_GUARD_VERSION=VERSION
