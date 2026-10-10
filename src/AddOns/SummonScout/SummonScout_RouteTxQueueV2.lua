-- SummonScout RouteTxQueue V2 for WoW 1.12.1 / Lua 5.0.
-- Paces FIRST SEND of R/X/A only. No automatic retry after an uncertain attempt.
-- Background FCV/FCE/H/D yields while a route transaction is active.

local H=W112_SUMMONSCOUT_HOT
if not H or type(H.GetState)~="function" then return end
local F=H.GetState("fallbackrouter")
F.routeAssignments=type(F.routeAssignments)=="table" and F.routeAssignments or {}
F.routeTxFailures=type(F.routeTxFailures)=="table" and F.routeTxFailures or {}

local T={VERSION="2",PROTO="[SSFR1]",GAP=1.60,ACTIVE_MAX=15.0,queue={},nextSend=0,activeUntil=0,base=nil,installed=false}
local function now() return GetTime and GetTime() or 0 end
local function trim(v) local s=tostring(v or ""); s=string.gsub(s,"^%s+",""); return string.gsub(s,"%s+$","") end
local function lower(v) return string.lower(trim(v)) end
local function same(a,b) a=lower(a); b=lower(b); return a~="" and a==b end
local function player() return trim(UnitName and UnitName("player") or "") end
local function split(s) local out,p={},1; s=tostring(s or ""); while true do local a=string.find(s,":",p,true); if not a then out[table.getn(out)+1]=string.sub(s,p); break end; out[table.getn(out)+1]=string.sub(s,p,a-1); p=a+1 end; return out end
local function unhex(s) s=tostring(s or ""); if math.mod(string.len(s),2)~=0 or string.find(s,"[^0-9a-fA-F]") then return nil end; local out=""; for i=1,string.len(s),2 do local b=tonumber(string.sub(s,i,i+1),16); if not b then return nil end; out=out..string.char(b) end; return out end
local function parse(raw)
    raw=tostring(raw or ""); if string.sub(raw,1,string.len(T.PROTO))~=T.PROTO then return nil end
    local parts=split(trim(string.sub(raw,string.len(T.PROTO)+1))); if not parts[1] or parts[1]=="" then return nil end
    local f={}; for i=2,table.getn(parts) do local v=unhex(parts[i]); if v==nil then return parts[1],nil end; f[table.getn(f)+1]=v end
    return parts[1],f
end
local function key(fields) if type(fields)~="table" then return "" end; return lower(fields[1] or "").."@"..lower(fields[2] or "") end
local function countQueue() local n=0; for _ in pairs(T.queue) do n=n+1 end; return n end
function T.active() return countQueue()>0 or now()<(T.activeUntil or 0) end
local function touch(seconds) local untilAt=now()+(tonumber(seconds) or T.ACTIVE_MAX); if untilAt>(T.activeUntil or 0) then T.activeUntil=untilAt end end
local function fail(k,code,why)
    F.routeTxFailures[k]={at=now(),code=code,reason=why or "send_uncertain"}
    local p=F.pendingRoute and F.pendingRoute[k] or nil
    if type(p)=="table" then p.sendUncertain=true; p.phase="FAILED"; p.expires=math.min(tonumber(p.expires) or (now()+1),now()+1) end
    if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage("|cffff4444[SSI ROUTE TX]|r "..tostring(code).." "..tostring(k).." failed: "..tostring(why or "uncertain")) end
end

local function enqueue(message,target,code,fields)
    local k=key(fields); local t=now(); local id=tostring(code).."|"..k.."|"..lower(target)
    if T.queue[id] then return true end
    local due=math.max(t,T.nextSend or 0)
    T.queue[id]={message=message,target=trim(target),code=code,fields=fields,key=k,due=due,created=t}
    touch(T.ACTIVE_MAX)
    if code=="X" then
        local origin=type(fields)=="table" and trim(fields[3] or "") or ""
        F.routeAssignments[k]={provider=trim(target),origin=origin,created=t,expires=t+T.ACTIVE_MAX}
        local p=F.pendingRoute and F.pendingRoute[k] or nil
        if type(p)=="table" then p.selectedProvider=trim(target); p.phase="X_QUEUED"; p.expires=t+T.ACTIVE_MAX end
    elseif code=="R" then
        local p=F.pendingRoute and F.pendingRoute[k] or nil
        if type(p)=="table" then p.phase="R_QUEUED"; p.expires=t+T.ACTIVE_MAX end
    elseif code=="A" then
        touch(5.0)
    end
    return true
end

local BACKGROUND={FCV=true,FCE=true,H=true,D=true}
local ROUTE={R=true,X=true,A=true}
local function outgoing(message,chatType,language,target)
    if string.upper(tostring(chatType or ""))~="WHISPER" then return false end
    local code,fields=parse(message)
    if code then
        if ROUTE[code] then enqueue(message,target,code,fields); return true end
        if BACKGROUND[code] and T.active() then return true end
        return false
    end
    -- Remote route acknowledgement text used to collide with the first X/R packet.
    -- Suppress only the transient "checking" line; final success/failure still goes out.
    if string.sub(tostring(message or ""),1,21)=="Got it - checking the " then return true end
    return false
end

local function install()
    if T.installed or type(SendChatMessage)~="function" then return T.installed end
    T.base=SendChatMessage
    local base=T.base
    W112_SUMMONSCOUT_ROUTE_TX_SEND_WRAPPER=function(message,chatType,language,target)
        local handled=false
        if pcall then local ok,v=pcall(outgoing,message,chatType,language,target); handled=ok and v and true or false else handled=outgoing(message,chatType,language,target) and true or false end
        if handled then return end
        return base(message,chatType,language,target)
    end
    SendChatMessage=W112_SUMMONSCOUT_ROUTE_TX_SEND_WRAPPER
    T.installed=true
    return true
end

local function drain()
    local t=now(); if t<(T.nextSend or 0) then return end
    local bestId,best=nil,nil
    for id,item in pairs(T.queue) do if type(item)=="table" and (item.due or 0)<=t and (not best or item.due<best.due) then bestId=id; best=item end end
    if not best then return end
    T.queue[bestId]=nil; T.nextSend=t+T.GAP; touch(T.ACTIVE_MAX)
    local ok=true
    if pcall then ok=pcall(T.base,best.message,"WHISPER",nil,best.target) else T.base(best.message,"WHISPER",nil,best.target) end
    local p=F.pendingRoute and F.pendingRoute[best.key] or nil
    if not ok then fail(best.key,best.code,"lua_send_error"); return end
    if best.code=="R" and type(p)=="table" then p.phase="R_SENT"; p.expires=t+T.ACTIVE_MAX end
    if best.code=="X" and type(p)=="table" then p.phase="A_WAIT"; p.expires=t+T.ACTIVE_MAX end
    -- SendChatMessage success is not delivery confirmation. Never retry this item.
end

local frame=CreateFrame and CreateFrame("Frame") or nil
if frame then
    frame:RegisterEvent("PLAYER_LOGIN"); frame:RegisterEvent("CHAT_MSG_WHISPER"); frame:RegisterEvent("CHAT_MSG_SYSTEM"); frame:RegisterEvent("UI_ERROR_MESSAGE")
    frame:SetScript("OnEvent",function()
        if event=="PLAYER_LOGIN" then install(); return end
        if event=="CHAT_MSG_WHISPER" then
            local code,fields=parse(arg1 or "")
            if ROUTE[code] then touch(T.ACTIVE_MAX)
                if code=="A" then T.activeUntil=math.max(T.activeUntil or 0,now()+1.0) end
            end
            return
        end
        local s=lower(tostring(arg1 or "").." "..tostring(arg2 or ""))
        if string.find(s,"must wait",1,true) or string.find(s,"before speaking again",1,true) then
            local k="global@route"; F.routeTxFailures[k]={at=now(),code="FLOOD",reason=trim(arg1 or arg2 or "flood")}
        end
    end)
    frame:SetScript("OnUpdate",function() if not T.installed then install() end; drain(); local t=now(); for k,a in pairs(F.routeAssignments) do if type(a)~="table" or t>(tonumber(a.expires) or 0) then F.routeAssignments[k]=nil end end end)
end

W112_SUMMONSCOUT_ROUTE_TX_V2=T
W112_SUMMONSCOUT_ROUTE_TX_VERSION=T.VERSION
