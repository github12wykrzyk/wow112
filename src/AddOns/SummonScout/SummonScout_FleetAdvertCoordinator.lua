-- Fleet-wide World advert coordinator for SummonScout.
-- WoW 1.12.1 / Lua 5.0 compatible.
--
-- Goals:
--   * one World advert for the whole summon fleet instead of one per client;
--   * rotate the speaking bot among fresh/healthy summon providers;
--   * advertise only destinations currently represented by fresh providers;
--   * leave whisper routing, invites, Ritual, payment and ledger semantics untouched.
--
-- Coordination reuses the trusted fleet control-whisper transport prefix already used by
-- FallbackRouter/FleetCounter. Customer whispers never use these control codes.

SummonScoutDB = SummonScoutDB or {}

local A = {}
A.VERSION = "1"
A.PROTO = "[SSFR1]"
A.HB_SECONDS = 12
A.PEER_TTL = 38
A.DEFAULT_MIN = 300
A.DEFAULT_MAX = 480
A.MIN_FLOOR = 120
A.MAX_CEIL = 1800
A.GRANT_TTL = 12
A.MAX_PACKET = 235
A.peers = {}
A.seq = 0
A.nextHb = 0
A.nextTick = 0
A.nextAdvertAt = 0
A.pendingGrant = nil
A.lastSpeaker = ""
A.lastGrantId = ""
A.metrics = { heartbeats=0, grants=0, sends=0, suppressed=0, failures=0 }

local LABEL = {
    hyjal="Hyjal",
    hydraxian="Hydraxian",
    hydraxis="Hydraxian",
    winterspring="Winterspring",
    silithus="Silithus",
    tanaris="Tanaris",
    azshara="Azshara"
}

function A.now() return GetTime and GetTime() or 0 end
function A.wall() return time and tonumber(time()) or math.floor(A.now()) end
function A.trim(v)
    local s=tostring(v or "")
    s=string.gsub(s,"^%s+","")
    s=string.gsub(s,"%s+$","")
    return s
end
function A.lower(v) return string.lower(A.trim(v)) end
function A.same(a,b)
    a=A.lower(a); b=A.lower(b)
    return a~="" and a==b
end
function A.me() return A.trim(UnitName and UnitName("player") or "") end
function A.master() return A.trim(SummonScoutDB.masterName or "") end
function A.isMaster() return A.same(A.me(),A.master()) end
function A.validName(v)
    v=A.trim(v)
    return string.len(v)>=2 and string.len(v)<=24 and not string.find(v,"[^%a%-]")
end
function A.debug(v)
    if SummonScoutDB.debug and DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage("|cff55ddffSummon fleet advert:|r "..tostring(v or ""))
    end
end
function A.hex(v)
    local s=tostring(v or ""); local out=""; local i
    for i=1,string.len(s) do out=out..string.format("%02x",string.byte(s,i)) end
    return out
end
function A.unhex(v)
    local s=tostring(v or ""); local out=""; local i
    if math.mod(string.len(s),2)~=0 or string.find(s,"[^0-9a-fA-F]") then return nil end
    for i=1,string.len(s),2 do
        local b=tonumber(string.sub(s,i,i+1),16)
        if not b then return nil end
        out=out..string.char(b)
    end
    return out
end
function A.split(v)
    local s=tostring(v or ""); local out={}; local p=1; local at
    while true do
        at=string.find(s,":",p,true)
        if not at then out[table.getn(out)+1]=string.sub(s,p); break end
        out[table.getn(out)+1]=string.sub(s,p,at-1); p=at+1
    end
    return out
end
function A.parse(raw)
    raw=tostring(raw or "")
    if string.sub(raw,1,string.len(A.PROTO))~=A.PROTO then return nil end
    local rest=A.trim(string.sub(raw,string.len(A.PROTO)+1))
    local parts=A.split(rest); local f={}; local i
    if not parts[1] or parts[1]=="" then return nil end
    for i=2,table.getn(parts) do
        local d=A.unhex(parts[i]); if d==nil then return nil end
        f[table.getn(f)+1]=d
    end
    return parts[1],f
end
function A.sendCtl(target,code,fields)
    target=A.trim(target)
    if not A.validName(target) or not SendChatMessage then return false end
    local p=A.PROTO.." "..tostring(code or ""); local i; fields=fields or {}
    for i=1,table.getn(fields) do p=p..":"..A.hex(fields[i] or "") end
    if string.len(p)>A.MAX_PACKET then return false end
    if pcall then return pcall(SendChatMessage,p,"WHISPER",nil,target) end
    SendChatMessage(p,"WHISPER",nil,target); return true
end

function A.serviceCsv()
    local raw=A.lower(SummonScoutDB.service or "")
    if raw=="" or raw=="all" then return "" end
    local seen={}; local out={}; local x
    for x in string.gfind(raw,"[^,]+") do
        x=A.lower(x)
        if x~="" and not seen[x] and string.len(x)<=24 and not string.find(x,"[^%a%-]") then
            seen[x]=true; out[table.getn(out)+1]=x
        end
    end
    table.sort(out)
    return table.concat(out,",")
end
function A.label(id)
    id=A.lower(id)
    if LABEL[id] then return LABEL[id] end
    if id=="" then return "" end
    return string.upper(string.sub(id,1,1))..string.sub(id,2)
end
function A.intervalBounds()
    local lo=math.floor(tonumber(SummonScoutDB.fleetAdvertMinSeconds) or A.DEFAULT_MIN)
    local hi=math.floor(tonumber(SummonScoutDB.fleetAdvertMaxSeconds) or A.DEFAULT_MAX)
    if lo<A.MIN_FLOOR then lo=A.MIN_FLOOR end
    if lo>A.MAX_CEIL then lo=A.MAX_CEIL end
    if hi<lo then hi=lo end
    if hi>A.MAX_CEIL then hi=A.MAX_CEIL end
    return lo,hi
end
function A.nextDelay()
    A.seq=A.seq+1
    local lo,hi=A.intervalBounds(); local span=hi-lo+1
    local salt=A.wall()*37 + math.floor(A.now()*10)*17 + A.seq*7919
    local me=A.lower(A.me()); local i
    for i=1,string.len(me) do salt=salt+string.byte(me,i)*(i+31) end
    return lo+math.mod(salt,span)
end
function A.schedule(reason)
    if not A.isMaster() then return end
    local d=A.nextDelay()
    A.nextAdvertAt=A.now()+d
    A.debug("next fleet advert in "..tostring(d).."s ["..tostring(reason or "schedule").."]")
end

function A.enabled()
    if SummonScoutDB.fleetAdvertEnabled==nil then SummonScoutDB.fleetAdvertEnabled=true end
    return SummonScoutDB.enabled~=false and SummonScoutDB.fleetAdvertEnabled~=false
end

-- Keep the legacy per-client advert scheduler dormant while fleet mode is active.
-- Do not flip spamEnabled: the user's GUI preference remains intact and becomes effective
-- again immediately if fleetAdvertEnabled is disabled.
function A.suppressLegacyScheduler()
    if not A.enabled() then return end
    local s=W112_SUMMONSCOUT_STATE
    if type(s)=="table" then
        local floor=A.now()+3600
        if not s.nextSpamAt or s.nextSpamAt<floor then s.nextSpamAt=floor end
    end
end

function A.recordPeer(name,services,seen)
    name=A.trim(name); if not A.validName(name) then return end
    local csv=tostring(services or "")
    A.peers[A.lower(name)]={name=name,services=csv,seen=tonumber(seen) or A.now()}
end
function A.prune()
    local t=A.now(); local k,p
    for k,p in pairs(A.peers) do
        if type(p)~="table" or t-(tonumber(p.seen) or -100000)>A.PEER_TTL then A.peers[k]=nil end
    end
end
function A.heartbeat()
    if not A.enabled() then return end
    local master=A.master(); local me=A.me(); local svc=A.serviceCsv()
    if A.isMaster() then
        if svc~="" then A.recordPeer(me,svc,A.now()) end
        return
    end
    if not A.validName(master) or svc=="" then return end
    if A.sendCtl(master,"FAH",{A.VERSION,svc}) then A.metrics.heartbeats=A.metrics.heartbeats+1 end
end
function A.onHeartbeat(sender,f)
    if not A.isMaster() or table.getn(f)~=2 or f[1]~=A.VERSION then return end
    if A.serviceCsv()=="" and not A.validName(sender) then return end
    A.recordPeer(sender,f[2],A.now())
end
function A.providers()
    A.prune()
    local out={}; local k,p
    for k,p in pairs(A.peers) do
        if type(p)=="table" and A.validName(p.name) and tostring(p.services or "")~="" then out[table.getn(out)+1]=p.name end
    end
    local me=A.me(); local svc=A.serviceCsv(); local found=false; local i
    if svc~="" and A.validName(me) then
        for i=1,table.getn(out) do if A.same(out[i],me) then found=true end end
        if not found then out[table.getn(out)+1]=me end
    end
    table.sort(out)
    return out
end
function A.destinations()
    A.prune()
    local seen={}; local out={}; local k,p,x
    local function add(csv)
        for x in string.gfind(tostring(csv or ""),"[^,]+") do
            x=A.lower(x)
            if x~="" and not seen[x] then seen[x]=true; out[table.getn(out)+1]=x end
        end
    end
    add(A.serviceCsv())
    for k,p in pairs(A.peers) do if type(p)=="table" then add(p.services) end end
    table.sort(out)
    return out
end
function A.destinationCsv()
    return table.concat(A.destinations(),",")
end
function A.chooseSpeaker()
    local p=A.providers(); local n=table.getn(p)
    if n==0 then return nil end
    local candidates={}; local i
    for i=1,n do if not A.same(p[i],A.lastSpeaker) then candidates[table.getn(candidates)+1]=p[i] end end
    if table.getn(candidates)==0 then candidates=p end
    A.seq=A.seq+1
    local pick=1+math.mod(A.wall()+A.seq*7919,table.getn(candidates))
    return candidates[pick]
end
function A.buildAdvert(csv)
    local labels={}; local x
    for x in string.gfind(tostring(csv or ""),"[^,]+") do labels[table.getn(labels)+1]=A.label(x) end
    if table.getn(labels)==0 then return nil end
    local prefix=A.trim(SummonScoutDB.fleetAdvertPrefix or "Summons")
    local suffix=A.trim(SummonScoutDB.fleetAdvertSuffix or "whisper destination for invite")
    local msg=prefix..": "..table.concat(labels," / ")
    if suffix~="" then msg=msg.." - "..suffix end
    if string.len(msg)>230 then return nil end
    return msg
end
function A.sendWorld(csv)
    local msg=A.buildAdvert(csv)
    if not msg or not SendChatMessage or not GetChannelName then return false,"message" end
    local ch=GetChannelName(SummonScoutDB.channel or "World")
    if type(ch)~="number" or ch<=0 then return false,"channel" end
    local ok=true
    if pcall then ok=pcall(SendChatMessage,msg,"CHANNEL",nil,ch) else SendChatMessage(msg,"CHANNEL",nil,ch) end
    if not ok then return false,"send" end
    SummonScoutDB.lastAdvertWall=A.wall()
    SummonScoutDB.lastAdvertNormalized=string.lower(msg)
    local s=W112_SUMMONSCOUT_STATE
    if type(s)=="table" then s.lastAdvertMessage=msg; s.lastAdvertSentAt=A.now() end
    return true,"sent"
end
function A.grant()
    if not A.isMaster() or not A.enabled() then return end
    local csv=A.destinationCsv(); if csv=="" then A.metrics.suppressed=A.metrics.suppressed+1; A.schedule("no-destinations"); return end
    local speaker=A.chooseSpeaker(); if not speaker then A.metrics.suppressed=A.metrics.suppressed+1; A.schedule("no-speaker"); return end
    A.seq=A.seq+1
    local id=tostring(A.wall()).."-"..tostring(A.seq)
    A.lastSpeaker=speaker; A.lastGrantId=id
    if A.same(speaker,A.me()) then
        local ok=A.sendWorld(csv)
        if ok then A.metrics.sends=A.metrics.sends+1 else A.metrics.failures=A.metrics.failures+1 end
        A.schedule(ok and "sent-local" or "local-failed")
        return
    end
    if A.sendCtl(speaker,"FAG",{A.VERSION,id,csv}) then
        A.pendingGrant={id=id,speaker=speaker,expires=A.now()+A.GRANT_TTL}
        A.metrics.grants=A.metrics.grants+1
    else
        A.metrics.failures=A.metrics.failures+1
        A.schedule("grant-send-failed")
    end
end
function A.onGrant(sender,f)
    if A.isMaster() or not A.same(sender,A.master()) or table.getn(f)~=3 or f[1]~=A.VERSION then return end
    local id=tostring(f[2] or ""); local csv=tostring(f[3] or "")
    if id=="" or id==A.lastGrantId then return end
    A.lastGrantId=id
    local ok,reason=A.sendWorld(csv)
    A.sendCtl(A.master(),"FAA",{A.VERSION,id,ok and "1" or "0",tostring(reason or "")})
    if ok then A.metrics.sends=A.metrics.sends+1 else A.metrics.failures=A.metrics.failures+1 end
end
function A.onAck(sender,f)
    if not A.isMaster() or table.getn(f)~=4 or f[1]~=A.VERSION then return end
    local g=A.pendingGrant
    if not g or f[2]~=g.id or not A.same(sender,g.speaker) then return end
    local ok=f[3]=="1"
    A.pendingGrant=nil
    if ok then A.metrics.sends=A.metrics.sends+1 else A.metrics.failures=A.metrics.failures+1 end
    -- No automatic retry after an uncertain/failed send. Schedule a fresh future cycle.
    A.schedule(ok and "ack" or "ack-failed")
end
function A.onWhisper(msg,sender)
    local code,f=A.parse(msg)
    if not code then return end
    if code=="FAH" then A.onHeartbeat(sender,f)
    elseif code=="FAG" then A.onGrant(sender,f)
    elseif code=="FAA" then A.onAck(sender,f) end
end
function A.tick()
    local t=A.now()
    A.suppressLegacyScheduler()
    if t>=A.nextHb then A.nextHb=t+A.HB_SECONDS; A.heartbeat() end
    if not A.isMaster() or not A.enabled() then return end
    if A.nextAdvertAt<=0 then A.schedule("startup") end
    if A.pendingGrant and t>(A.pendingGrant.expires or 0) then
        -- Unknown grant outcome: never retry. Advance to a later independent cycle.
        A.metrics.failures=A.metrics.failures+1
        A.pendingGrant=nil
        A.schedule("grant-timeout")
        return
    end
    if not A.pendingGrant and t>=A.nextAdvertAt then A.grant() end
end

if SummonScoutDB.fleetAdvertEnabled==nil then SummonScoutDB.fleetAdvertEnabled=true end
if SummonScoutDB.fleetAdvertMinSeconds==nil then SummonScoutDB.fleetAdvertMinSeconds=A.DEFAULT_MIN end
if SummonScoutDB.fleetAdvertMaxSeconds==nil then SummonScoutDB.fleetAdvertMaxSeconds=A.DEFAULT_MAX end

local frame=CreateFrame and CreateFrame("Frame") or nil
if frame then
    frame:RegisterEvent("PLAYER_LOGIN")
    frame:RegisterEvent("CHAT_MSG_WHISPER")
    frame:SetScript("OnEvent",function()
        local ev=event
        if ev=="PLAYER_LOGIN" then
            A.nextHb=0; A.nextAdvertAt=0; A.pendingGrant=nil
            A.suppressLegacyScheduler()
        elseif ev=="CHAT_MSG_WHISPER" then
            A.onWhisper(arg1,arg2)
        end
    end)
    frame:SetScript("OnUpdate",function()
        local t=A.now(); if t<A.nextTick then return end
        A.nextTick=t+0.25
        A.tick()
    end)
end

W112_SUMMONSCOUT_FLEET_ADVERT=A
W112_SUMMONSCOUT_FLEET_ADVERT_VERSION=A.VERSION
