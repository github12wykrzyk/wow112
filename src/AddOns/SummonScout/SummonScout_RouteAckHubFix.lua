-- SummonScout 1.83: hub-origin routed ACK bridge for WoW 1.12.1 / Lua 5.0.
--
-- Canonical FallbackRouter accepts provider Acks for non-hub origins, but the
-- hub-origin case (customer whispered Feltaxi directly) falls through to the
-- non-master branch and silently drops A from the remote provider. The pending
-- route then expires and the customer receives a false "unavailable".
--
-- This cold-load bridge fixes only that missing transaction edge. It does not
-- create invites, bypass readiness/safety, alter provider selection, or retry.

local H=W112_SUMMONSCOUT_HOT
if not H or type(H.GetState)~="function" then return end

local VERSION="1"
local PROTO="[SSFR1]"
local PROVIDER_TTL=38.0

local function trim(v)
    local s=tostring(v or "")
    s=string.gsub(s,"^%s+","")
    return string.gsub(s,"%s+$","")
end
local function lower(v) return string.lower(trim(v)) end
local function same(a,b) a=lower(a); b=lower(b); return a~="" and a==b end
local function now() return GetTime and GetTime() or 0 end

local function unhex(s)
    s=tostring(s or "")
    if math.mod(string.len(s),2)~=0 or string.find(s,"[^0-9a-fA-F]") then return nil end
    local out=""; local i
    for i=1,string.len(s),2 do
        local b=tonumber(string.sub(s,i,i+1),16)
        if not b then return nil end
        out=out..string.char(b)
    end
    return out
end

local function split(s,delimiter)
    local out={}; s=tostring(s or ""); delimiter=tostring(delimiter or ":")
    local startAt=1
    while true do
        local at=string.find(s,delimiter,startAt,true)
        if at then
            out[table.getn(out)+1]=string.sub(s,startAt,at-1)
            startAt=at+string.len(delimiter)
        else
            out[table.getn(out)+1]=string.sub(s,startAt)
            break
        end
    end
    return out
end

local function parseAck(raw)
    raw=tostring(raw or "")
    if string.sub(raw,1,string.len(PROTO))~=PROTO then return nil end
    local rest=trim(string.sub(raw,string.len(PROTO)+1))
    local parts=split(rest,":")
    if parts[1]~="A" or table.getn(parts)~=5 then return nil end
    local fields={}; local i
    for i=2,5 do
        local v=unhex(parts[i]); if v==nil then return nil end
        fields[table.getn(fields)+1]=v
    end
    return fields
end

local LABELS={hydraxian="Hydraxis",hyjal="Hyjal",winterspring="Winterspring",silithus="Silithus",tanaris="Tanaris"}
local function label(destination)
    local id=lower(destination)
    return LABELS[id] or trim(destination)
end

local function liveProvider(F,destination,sender)
    local providers=F.providers and F.providers[lower(destination)] or nil
    local item=type(providers)=="table" and providers[lower(sender)] or nil
    if type(item)~="table" then return false end
    return (now()-(tonumber(item.seen) or 0))<=PROVIDER_TTL
end

local function sendCustomer(customer,destination,status)
    if not SendChatMessage then return false end
    customer=trim(customer); if customer=="" then return false end
    local text
    if tostring(status or "") == "1" then
        text="Got it - the "..label(destination).." summoner is inviting you now."
    else
        text=label(destination).." is currently unavailable. Please try again shortly."
    end
    if pcall then return pcall(SendChatMessage,text,"WHISPER",nil,customer) end
    SendChatMessage(text,"WHISPER",nil,customer); return true
end

local function patchRouter()
    local module=H.modules and H.modules["fallbackrouter"] or nil
    if type(module)~="table" or type(module.OnEvent)~="function" then return false end
    if module.__routeAckHubFixV1 then return true end
    local original=module.OnEvent
    module.OnEvent=function(ev,a1,a2,a3)
        if ev=="CHAT_MSG_WHISPER" then
            local fields=parseAck(a1)
            if fields then
                local customer,destination,origin,status=fields[1],fields[2],fields[3],fields[4]
                local me=trim(UnitName and UnitName("player") or "")
                local master=trim(SummonScoutDB and SummonScoutDB.masterName or "")
                if same(me,master) and same(origin,me) then
                    local F=H.GetState("fallbackrouter")
                    local key=lower(customer).."@"..lower(destination)
                    local pending=type(F)=="table" and F.pendingRoute and F.pendingRoute[key] or nil
                    if type(pending)=="table" and liveProvider(F,destination,a2) then
                        F.pendingRoute[key]=nil
                        sendCustomer(customer,destination,status)
                        if SummonScoutDB and SummonScoutDB.debug and DEFAULT_CHAT_FRAME then
                            DEFAULT_CHAT_FRAME:AddMessage("|cff55ddffSummon route:|r hub ACK "..trim(a2).." -> "..trim(customer).." / "..lower(destination).." / "..tostring(status))
                        end
                        return true
                    end
                end
            end
        end
        return original(ev,a1,a2,a3)
    end
    module.__routeAckHubFixV1=true
    return true
end

patchRouter()
local frame=CreateFrame and CreateFrame("Frame") or nil
if frame then
    local nextPatch=0
    frame:SetScript("OnUpdate",function()
        local t=now(); if t<nextPatch then return end; nextPatch=t+1.0; patchRouter()
    end)
end

W112_SUMMONSCOUT_ROUTE_ACK_HUB_FIX_VERSION=VERSION
