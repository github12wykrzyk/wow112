-- SummonScout provider-bound ACK core V2 for WoW 1.12.1 / Lua 5.0.
-- Accepts a routed provider ACK only from the exact provider selected for that
-- customer@destination transaction. Replaces the historical overlapping ACK bridges.

local H=W112_SUMMONSCOUT_HOT
if not H or type(H.Register)~="function" or type(H.GetState)~="function" then return end
local VERSION="6-provider-bound-ack-v2"
local F=H.GetState("fallbackrouter"); F.caps=type(F.caps)=="table" and F.caps or {}; F.caps.providerBoundAck=true
local PROTO="[SSFR1]"; local S={handled={}}
local function now() return GetTime and GetTime() or 0 end
local function trim(v) local s=tostring(v or ""); s=string.gsub(s,"^%s+",""); return string.gsub(s,"%s+$","") end
local function lower(v) return string.lower(trim(v)) end
local function same(a,b) a=lower(a); b=lower(b); return a~="" and a==b end
local function me() return trim(UnitName and UnitName("player") or "") end
local function master() return trim(SummonScoutDB and SummonScoutDB.masterName or "") end
local function isHub() return same(me(),master()) end
local function split(s) local t,p={},1; while true do local a=string.find(s,":",p,true); if not a then t[table.getn(t)+1]=string.sub(s,p); break end; t[table.getn(t)+1]=string.sub(s,p,a-1); p=a+1 end; return t end
local function unhex(s) s=tostring(s or ""); if math.mod(string.len(s),2)~=0 or string.find(s,"[^0-9a-fA-F]") then return nil end; local o=""; for i=1,string.len(s),2 do local b=tonumber(string.sub(s,i,i+1),16); if not b then return nil end; o=o..string.char(b) end; return o end
local function hex(s) local o=""; s=tostring(s or ""); for i=1,string.len(s) do o=o..string.format("%02x",string.byte(s,i)) end; return o end
local function parse(raw)
    raw=tostring(raw or ""); if string.sub(raw,1,string.len(PROTO))~=PROTO then return nil end
    local parts=split(trim(string.sub(raw,string.len(PROTO)+1))); if parts[1]~="A" then return nil end
    local f={}; for i=2,table.getn(parts) do local v=unhex(parts[i]); if v==nil then return nil end; f[table.getn(f)+1]=v end
    if table.getn(f)<4 then return nil end; return f
end
local LABEL={hydraxian="Hydraxis",hyjal="Hyjal",winterspring="Winterspring",silithus="Silithus",tanaris="Tanaris"}
local function sendCustomer(customer,destination,status)
    if not SendChatMessage or trim(customer)=="" then return false end
    local l=LABEL[lower(destination)] or trim(destination); local text
    if tostring(status)=="1" then text="Got it - the "..l.." summoner is inviting you now." else text=l.." is currently unavailable. Please try again shortly." end
    if pcall then return pcall(SendChatMessage,text,"WHISPER",nil,trim(customer)) end; SendChatMessage(text,"WHISPER",nil,trim(customer)); return true
end
local function sendAck(target,customer,destination,origin,status,provider)
    if not SendChatMessage or trim(target)=="" then return false end
    local fields={customer,destination,origin,status,provider or ""}; local text=PROTO.." A"
    for i=1,table.getn(fields) do text=text..":"..hex(fields[i] or "") end
    if pcall then return pcall(SendChatMessage,text,"WHISPER",nil,trim(target)) end; SendChatMessage(text,"WHISPER",nil,trim(target)); return true
end
local function fingerprint(sender,f) return lower(sender).."|"..lower(f[1]).."@"..lower(f[2]).."|"..lower(f[3]).."|"..tostring(f[4]) end
local function seen(sender,f)
    local k=fingerprint(sender,f); local t=now(); local at=tonumber(S.handled[k])
    if at and (t-at)<3 then return true end; return false
end
local function mark(sender,f) S.handled[fingerprint(sender,f)]=now() end
local function assignmentFor(key,pending)
    local a=F.routeAssignments and F.routeAssignments[key] or nil
    local expected=type(pending)=="table" and trim(pending.selectedProvider or "") or ""
    if expected=="" and type(a)=="table" then expected=trim(a.provider or "") end
    return expected,a
end

local A={}
function A.HandleRaw(raw,sender)
    local f=parse(raw); if not f then return false end
    if seen(sender,f) then return true end
    local customer,destination,origin,status=f[1],f[2],f[3],f[4]
    local key=lower(customer).."@"..lower(destination); local pending=F.pendingRoute and F.pendingRoute[key] or nil
    if isHub() then
        local expected,a=assignmentFor(key,pending)
        if expected=="" or not same(sender,expected) then
            if SummonScoutDB and SummonScoutDB.debug and DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage("|cffff4444[SSI ROUTE]|r ACK rejected from "..trim(sender).." expected="..expected.." key="..key) end
            return true
        end
        mark(sender,f)
        if F.routeAssignments then F.routeAssignments[key]=nil end
        if same(origin,me()) then
            if type(pending)~="table" then return true end
            F.pendingRoute[key]=nil; pending.phase="DONE"; sendCustomer(customer,destination,status)
            return true
        end
        -- Hub forwards a verified provider result to the original fleet node once.
        sendAck(origin,customer,destination,origin,status,expected)
        return true
    end
    -- Non-hub origin trusts only its configured master and requires its local pending route.
    if not same(sender,master()) or not same(origin,me()) or type(pending)~="table" then return false end
    mark(sender,f); F.pendingRoute[key]=nil; pending.phase="DONE"; sendCustomer(customer,destination,status); return true
end

local M={}
function M.Init() H.RegisterEvent("CHAT_MSG_WHISPER"); W112_SUMMONSCOUT_ACK_CORE_V2=A; W112_SUMMONSCOUT_FALLBACK_HUB_ACK_VERSION=VERSION end
function M.OnEvent(ev,a1,a2) if ev=="CHAT_MSG_WHISPER" then A.HandleRaw(a1 or "",a2 or "") end end
function M.OnUpdate()
    local t=now(); for k,v in pairs(S.handled) do if (t-(tonumber(v) or 0))>30 then S.handled[k]=nil end end
end
function M.Shutdown() end
H.Register("fallbackrouter_hub_ack",M,VERSION)
W112_SUMMONSCOUT_ACK_CORE_V2=A
W112_SUMMONSCOUT_FALLBACK_HUB_ACK_VERSION=VERSION
