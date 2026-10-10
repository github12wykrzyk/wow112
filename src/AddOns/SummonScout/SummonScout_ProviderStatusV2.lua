-- SummonScout Provider Status V2 for WoW 1.12.1 / Lua 5.0.
-- One source of truth for current READY/BLOCKED/OFFLINE route state.
-- Online presence is intentionally distinct from route readiness.

local H=W112_SUMMONSCOUT_HOT
local C=W112_SUMMONSCOUT_FLEET_COUNTER_V1
if not H or type(H.GetState)~="function" or type(C)~="table" then return end

local P={VERSION="2",TTL=38}
local S=H.GetState("providerstatusv2")
S.remote=type(S.remote)=="table" and S.remote or {}
S.lastLocalSig=S.lastLocalSig or ""
S.lastGuiSig=S.lastGuiSig or ""

P.ORDER={"hydraxian","hyjal","winterspring","silithus","tanaris"}
P.LABEL={hydraxian="Hydraxis",hyjal="Hyjal",winterspring="Winterspring",silithus="Silithus",tanaris="Tanaris"}
P.SHORT={hydraxian="HYD",hyjal="HYJ",winterspring="WIN",silithus="SIL",tanaris="TAN"}
P.OWNER={hydraxian="Feltaxi",hyjal="Bolthyjal",winterspring="Taxiwinter",silithus="Kalisum",tanaris="Teletanaris"}

local function now() return GetTime and GetTime() or 0 end
local function trim(v) local s=tostring(v or ""); s=string.gsub(s,"^%s+",""); return string.gsub(s,"%s+$","") end
local function lower(v) return string.lower(trim(v)) end
local function same(a,b) a=lower(a); b=lower(b); return a~="" and a==b end
local function me() return trim(UnitName and UnitName("player") or "") end
local function servicesCsv()
    local raw=lower(SummonScoutDB and SummonScoutDB.service or "")
    if raw=="" or raw=="all" then return "" end
    local seen,out={},{}; local token,i
    for token in string.gfind(raw,"[^,]+") do seen[lower(token)]=true end
    for i=1,table.getn(P.ORDER) do token=P.ORDER[i]; if seen[token] then out[table.getn(out)+1]=token end end
    return table.concat(out,",")
end
local function missingLocal()
    local pair=H.GetState("slavemasterpairs")
    if type(pair)~="table" then return "" end
    return trim(pair.slaveSafetyMissing or "")
end

function P.localVerdict()
    local svc=servicesCsv()
    if svc=="" then return "OFFLINE","no_service","",svc end
    local pair=H.GetState("slavemasterpairs")
    if W112_SUMMONSCOUT_SLAVE_SAFETY_READY==false or (type(pair)=="table" and pair.slaveSafetyReady==false) then
        return "BLOCKED","missing_slaves",missingLocal(),svc
    end
    if not SummonScoutDB or SummonScoutDB.enabled~=true then return "BLOCKED","disabled","",svc end
    return "READY","","",svc
end

function P.observe(sender,csv,state,reason,missing,seenAt)
    sender=trim(sender); csv=lower(csv); state=string.upper(trim(state)); reason=lower(reason); missing=trim(missing)
    if sender=="" then return end
    if state~="READY" and state~="BLOCKED" then state=(csv~="" and "READY" or "OFFLINE") end
    local t=tonumber(seenAt) or now(); local token
    -- Remove the sender's previous service records before applying this heartbeat.
    for _,token in pairs(P.ORDER) do
        local r=S.remote[token]
        if type(r)=="table" and same(r.provider,sender) then S.remote[token]=nil end
    end
    for token in string.gfind(csv,"[^,]+") do
        token=lower(token)
        if P.OWNER[token] and same(P.OWNER[token],sender) then
            S.remote[token]={provider=sender,state=state,reason=reason,missing=missing,seenAt=t,changedAt=t}
        end
    end
end

function P.get(service)
    service=lower(service); local owner=P.OWNER[service]
    if not owner then return {service=service,state="OFFLINE",reason="unknown_service",provider="",age=9999,missing=""} end
    if same(owner,me()) then
        local st,rs,mi,csv=P.localVerdict(); local serves=false; local tok
        for tok in string.gfind(csv,"[^,]+") do if lower(tok)==service then serves=true end end
        if not serves then st="OFFLINE"; rs="no_service"; mi="" end
        return {service=service,state=st,reason=rs,provider=owner,age=0,missing=mi}
    end
    local r=S.remote[service]
    if type(r)~="table" then return {service=service,state="OFFLINE",reason="no_presence",provider=owner,age=9999,missing=""} end
    local age=now()-(tonumber(r.seenAt) or -100000)
    if age>P.TTL then return {service=service,state="OFFLINE",reason="stale_presence",provider=owner,age=age,missing=""} end
    return {service=service,state=r.state or "OFFLINE",reason=r.reason or "",provider=r.provider or owner,age=age,missing=r.missing or ""}
end

function P.readyServicesCsv()
    local out={}; local i,id,s
    for i=1,table.getn(P.ORDER) do id=P.ORDER[i]; s=P.get(id); if s.state=="READY" then out[table.getn(out)+1]=id end end
    return table.concat(out,",")
end
function P.counts()
    local a,b,o=0,0,0; local i,s
    for i=1,table.getn(P.ORDER) do s=P.get(P.ORDER[i]); if s.state=="READY" then a=a+1 elseif s.state=="BLOCKED" then b=b+1 else o=o+1 end end
    return a,b,o
end
function P.compact()
    local out={}; local i,id,s,x
    for i=1,table.getn(P.ORDER) do
        id=P.ORDER[i]; s=P.get(id); x=P.SHORT[id]..":"..string.sub(s.state,1,1)
        if s.state=="BLOCKED" and s.reason=="missing_slaves" then x=x.."(slaves)" end
        out[table.getn(out)+1]=x
    end
    return table.concat(out," ")
end
function P.describe(service)
    local s=P.get(service); local text=(P.LABEL[s.service] or s.service).." "..s.state.." via "..tostring(s.provider or "?")
    if s.reason~="" then text=text.." reason="..s.reason end
    if s.missing~="" then text=text.." missing="..s.missing end
    if s.age and s.age<9999 then text=text.." age="..string.format("%.1fs",s.age) end
    return text
end
function P.noteBlockedRequest(service,customer)
    local s=P.get(service)
    if s.state=="READY" then return false end
    if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage("|cffffaa00[SSI ROUTE]|r "..P.describe(service).." customer="..trim(customer)) end
    return true
end

-- V2 presence payload: FCV {version, services, lastAdvert, state, reason, missing}.
-- It is still one heartbeat; blocked providers keep reporting their configured service.
local baseHeartbeat=C.heartbeat
C.heartbeat=function()
    if type(C.isMaster)=="function" and C.isMaster() then return false end
    if type(C.validName)~="function" or type(C.master)~="function" or not C.validName(C.master()) then return false end
    local st,rs,mi,svc=P.localVerdict()
    if svc=="" then return false end
    if type(C.sendCtl)~="function" then return false end
    return C.sendCtl(C.master(),"FCV",{C.VERSION,svc,tostring(tonumber(SummonScoutDB.lastAdvertWall) or 0),st,rs,mi})
end

-- Fleet decisions and GUI are live, not latched rollout history.
C.freshServices=function() return P.readyServicesCsv() end
C.owners=function() local r=P.counts(); return r end
C.rollout=function()
    if type(C.isMaster)=="function" and C.isMaster() then local r=P.counts(); SummonScoutDB.fleetCounterRolloutReady=r>0 end
end
C.active=function()
    local r=P.counts()
    return type(C.isMaster)=="function" and C.isMaster() and SummonScoutDB.fleetCounterEnabled~=false and r>0
end

local baseRefresh=C.refreshGui
C.refreshGui=function()
    if not C.gui then return end
    if type(C.isMaster)=="function" and C.isMaster() then
        local r,b,o=P.counts(); C.gCheck:SetChecked(SummonScoutDB.fleetCounterEnabled~=false and 1 or nil)
        if not C.gPriceFocus then C.gPrice:SetText(tostring(C.price())) end
        C.gStatus:SetText("Fleet: "..r.."/5 READY | "..b.." BLOCKED | "..o.." OFFLINE | "..C.price().."g\n"..P.compact())
        return
    end
    return baseRefresh()
end

local frame=CreateFrame and CreateFrame("Frame") or nil
if frame then
    local nextAt=0
    frame:SetScript("OnUpdate",function()
        local t=now(); if t<nextAt then return end; nextAt=t+0.5
        local st,rs,mi,svc=P.localVerdict(); local sig=st.."|"..rs.."|"..mi.."|"..svc
        if sig~=S.lastLocalSig then S.lastLocalSig=sig; C.nextHb=0; if type(C.broadcast)=="function" then C.broadcast() end end
    end)
end

W112_SUMMONSCOUT_PROVIDER_STATUS_V2=P
W112_SUMMONSCOUT_PROVIDER_STATUS_VERSION=P.VERSION
