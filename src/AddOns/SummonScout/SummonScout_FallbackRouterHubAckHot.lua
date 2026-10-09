-- Hub-origin ACK bridge + compact fixed-fleet routing hotfix.
local H = W112_SUMMONSCOUT_HOT
if not H or type(H.Register) ~= "function" or type(H.GetState) ~= "function" then return end

local VERSION = "4-total-pool-tanaris"
local F = H.GetState("fallbackrouter")
local PROTO = "[SSFR1]"
local POOL = { "silithus", "winterspring", "hydraxian", "hyjal", "tanaris" }
F.totalPoolOwners = F.totalPoolOwners or {}

local function trim(s)
    s = tostring(s or "")
    s = string.gsub(s, "^%s+", "")
    return string.gsub(s, "%s+$", "")
end
local function lower(s) return string.lower(trim(s)) end
local function same(a,b) a=lower(a); b=lower(b); return a~="" and a==b end
local function inPool(id)
    return id=="silithus" or id=="winterspring" or id=="hydraxian" or id=="hyjal" or id=="tanaris"
end

local function split(s)
    local out, p = {}, 1
    while true do
        local at = string.find(s, ":", p, true)
        if not at then out[table.getn(out)+1]=string.sub(s,p); break end
        out[table.getn(out)+1]=string.sub(s,p,at-1); p=at+1
    end
    return out
end

local function unhex(s)
    s=tostring(s or "")
    if math.mod(string.len(s),2)~=0 or string.find(s,"[^0-9a-fA-F]") then return nil end
    local out=""
    local i
    for i=1,string.len(s),2 do
        local b=tonumber(string.sub(s,i,i+1),16)
        if not b then return nil end
        out=out..string.char(b)
    end
    return out
end

local function control(raw)
    raw=tostring(raw or "")
    if string.sub(raw,1,string.len(PROTO))~=PROTO then return nil end
    local parts=split(trim(string.sub(raw,string.len(PROTO)+1)))
    local code=parts[1]
    if not code or code=="" then return nil end
    local fields={}
    local i
    for i=2,table.getn(parts) do
        fields[table.getn(fields)+1]=unhex(parts[i])
        if fields[table.getn(fields)]==nil then return nil end
    end
    return code,fields
end

local function remember(name,csv)
    name=trim(name)
    local key=lower(name)
    if key=="" then return end
    local i,id,owners
    for i=1,table.getn(POOL) do
        id=POOL[i]; owners=F.totalPoolOwners[id]
        if type(owners)=="table" then owners[key]=nil end
    end
    local token
    for token in string.gfind(tostring(csv or ""),"[^,]+") do
        id=lower(token)
        if inPool(id) then
            if type(F.totalPoolOwners[id])~="table" then F.totalPoolOwners[id]={} end
            F.totalPoolOwners[id][key]=name
        end
    end
end

local function seed()
    F.directory=F.directory or {}
    F.providers=F.providers or {}
    local t=GetTime and GetTime() or 0
    local i,id,key,p,name,owners
    for i=1,table.getn(POOL) do
        id=POOL[i]; F.directory[id]=true
        if type(F.totalPoolOwners[id])~="table" then F.totalPoolOwners[id]={} end
        owners=F.totalPoolOwners[id]
        if type(F.providers[id])=="table" then
            for key,p in pairs(F.providers[id]) do
                if type(p)=="table" and trim(p.name)~="" then owners[lower(key)]=trim(p.name) end
            end
        end
        for key,name in pairs(owners) do
            if type(F.providers[id])~="table" then F.providers[id]={} end
            p=F.providers[id][key]
            if type(p)~="table" then p={name=name,lastAssigned=0}; F.providers[id][key]=p end
            p.name=name; p.seen=t; p.totalPoolSticky=true
        end
    end
    W112_SUMMONSCOUT_TOTAL_POOL_CSV="silithus,winterspring,hydraxian,hyjal,tanaris"
end

local function send(name,text)
    if trim(name)=="" or not SendChatMessage then return end
    if pcall then pcall(SendChatMessage,text,"WHISPER",nil,name)
    else SendChatMessage(text,"WHISPER",nil,name) end
end

local function label(id)
    id=lower(id)
    if id=="hyjal" then return "Hyjal" end
    if id=="hydraxian" then return "Hydraxis" end
    if id=="winterspring" then return "Winterspring" end
    if id=="silithus" then return "Silithus" end
    if id=="tanaris" then return "Tanaris" end
    return id
end

local M={}
function M.Init()
    H.RegisterEvent("CHAT_MSG_WHISPER")
    seed()
    W112_SUMMONSCOUT_FALLBACK_HUB_ACK_VERSION=VERSION
    W112_SUMMONSCOUT_TOTAL_POOL_VERSION=VERSION
end

function M.OnEvent(ev,a1,a2)
    if ev~="CHAT_MSG_WHISPER" then return end
    local code,f=control(a1 or "")
    if code=="H" and table.getn(f)==1 then remember(a2 or "",f[1]); seed(); return end
    if code~="A" or table.getn(f)~=4 then return end
    local customer,destination,origin,status=f[1],f[2],f[3],f[4]
    if not same(origin,UnitName and UnitName("player") or "") then return end
    local key=lower(customer).."@"..lower(destination)
    if not (F.pendingRoute and F.pendingRoute[key]) then return end
    local providers=F.providers and F.providers[lower(destination)]
    if not (providers and providers[lower(a2 or "")]) then return end
    F.pendingRoute[key]=nil
    if tostring(status)=="1" then
        send(customer,"Got it - the "..label(destination).." summoner is inviting you now.")
    else
        send(customer,label(destination).." is currently unavailable. Please try again shortly.")
    end
end

function M.OnUpdate() seed() end
H.Register("fallbackrouter_hub_ack",M,VERSION)
W112_SUMMONSCOUT_FALLBACK_HUB_ACK_VERSION=VERSION
W112_SUMMONSCOUT_TOTAL_POOL_VERSION=VERSION
