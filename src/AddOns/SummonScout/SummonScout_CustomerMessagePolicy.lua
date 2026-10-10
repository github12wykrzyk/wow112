-- SummonScout customer-facing message policy for WoW 1.12.1 / Lua 5.0.
-- Keeps fleet control traffic immediate, suppresses human-readable automation
-- between fixed summoners, and serializes short lower-case customer messages.

local H=W112_SUMMONSCOUT_HOT
if not H or type(H.Register)~="function" or type(H.GetState)~="function" then return end

local VERSION="2-silent-summoner-human-comms"
local Q=H.GetState("customermessagepolicy")
Q.pending=type(Q.pending)=="table" and Q.pending or {}
Q.recent=type(Q.recent)=="table" and Q.recent or {}
Q.nextSendAt=tonumber(Q.nextSendAt) or 0

local BASE=nil
local WRAPPER=nil
local MIN_GAP=1.5
local MAX_GAP=2.0
local DEDUPE=30.0
local THANK_DEDUPE=15.0
local MAX_QUEUE=24

local function now() return GetTime and (tonumber(GetTime()) or 0) or 0 end
local function trim(v)
 local s=tostring(v or "")
 s=string.gsub(s,"^%s+","")
 return string.gsub(s,"%s+$","")
end
local function lower(v) return string.lower(trim(v)) end
local function validName(v)
 v=trim(v)
 return v~="" and string.len(v)<=32 and not string.find(v,"[%c%s:;,=|]")
end
local function starts(s,p) return string.sub(s,1,string.len(p))==p end

local function randomGap()
 if math and math.random then return MIN_GAP+(math.random(0,500)/1000) end
 return 1.75
end

local function fixedSummoner(name)
 local wanted=lower(name)
 if wanted=="" then return false end
 local map=W112_SUMMONSCOUT_SLAVE_MASTER_PAIRS_ACTIVE
 if type(map)=="table" then
  local _,master
  for _,master in pairs(map) do if lower(master)==wanted then return true end end
 end
 return wanted=="feltaxi" or wanted=="bolthyjal" or wanted=="kalisum"
  or wanted=="taxiwinter" or wanted=="teletanaris"
end

local function compactCustomerMessage(message)
 local raw=trim(message)
 local s=lower(raw)
 if raw=="" then return nil,nil end

 local p="got it - checking the "
 if starts(s,p) then
  local rest=string.sub(s,string.len(p)+1)
  local at=string.find(rest," summoner",1,true)
  local label=at and trim(string.sub(rest,1,at-1)) or "summoner"
  return "checking "..label,"checking"
 end

 p="got it - the "
 if starts(s,p) and string.find(s," summoner is inviting you now",1,true) then
  local rest=string.sub(s,string.len(p)+1)
  local at=string.find(rest," summoner",1,true)
  local label=at and trim(string.sub(rest,1,at-1)) or "summoner"
  return label.." inviting you","inviting"
 end

 p="got it - inviting you to "
 if starts(s,p) then return "invite coming","inviting" end

 local unavailable=string.find(s," is currently unavailable",1,true)
 if unavailable then
  local label=trim(string.sub(s,1,unavailable-1))
  if label=="" then label="summoner" end
  return label.." unavailable","unavailable"
 end

 p="i can help with summons. available: "
 if starts(s,p) then
  local rest=string.sub(s,string.len(p)+1)
  local at=string.find(rest,". reply",1,true)
  if at then rest=string.sub(rest,1,at-1) end
  rest=trim(rest)
  if rest=="" then return nil,nil end
  return "available: "..rest,"available"
 end

 p="do you need "
 if starts(s,p) and string.find(s," summon?",1,true) then
  local rest=string.sub(s,string.len(p)+1)
  local at=string.find(rest," summon?",1,true)
  local label=at and trim(string.sub(rest,1,at-1)) or trim(rest)
  return "need "..label.."?","probe"
 end

 if string.find(s,"already grouped",1,true) or string.find(s,"already in a group",1,true) then
  return "leave group and whisper again","grouped"
 end

 if starts(s,"thanks") or starts(s,"thank you") or starts(s,"many thanks") or starts(s,"much appreciated") then
  return "thanks","thanks"
 end

 return nil,nil
end

local function dedupeKey(target,category)
 return lower(target).."|"..tostring(category or "msg")
end

local function queueCustomer(target,text,category)
 if not validName(target) or text=="" then return false end
 local t=now()
 local key=dedupeKey(target,category)
 local ttl=category=="thanks" and THANK_DEDUPE or DEDUPE
 local last=tonumber(Q.recent[key]) or -100000
 if (t-last)<ttl then return true end
 Q.recent[key]=t

 while table.getn(Q.pending)>=MAX_QUEUE do table.remove(Q.pending,1) end
 local due=math.max(t,Q.nextSendAt or 0)+randomGap()
 Q.nextSendAt=due
 Q.pending[table.getn(Q.pending)+1]={target=trim(target),text=lower(text),dueAt=due,category=category}
 return true
end

local function install()
 if WRAPPER and SendChatMessage==WRAPPER then return true end
 if type(SendChatMessage)~="function" then return false end
 BASE=SendChatMessage
 WRAPPER=function(message,chatType,language,target)
  if tostring(chatType or "")~="WHISPER" then return BASE(message,chatType,language,target) end
  local raw=tostring(message or "")
  if starts(raw,"[SSFR1]") then return BASE(message,chatType,language,target) end

  local isSummoner=fixedSummoner(target)
  if starts(raw,"[SSI ") and isSummoner then return nil end

  local compact,category=compactCustomerMessage(raw)
  if compact and validName(target) then
   -- Human-readable automation must never bounce around the fleet. Fixed
   -- summoners exchange only SSFR1 control traffic; unknown/manual whispers
   -- are left untouched so operators can still talk to each other manually.
   if isSummoner then return nil end
   queueCustomer(target,compact,category)
   return nil
  end
  return BASE(message,chatType,language,target)
 end
 SendChatMessage=WRAPPER
 Q.wrapper=WRAPPER
 Q.base=BASE
 Q.version=VERSION
 return true
end

local function processQueue()
 if table.getn(Q.pending)==0 or type(BASE)~="function" then return end
 local t=now()
 local item=Q.pending[1]
 if type(item)~="table" then table.remove(Q.pending,1); return end
 if t<(tonumber(item.dueAt) or 0) then return end
 table.remove(Q.pending,1)
 if validName(item.target) and item.text~="" then
  if pcall then pcall(BASE,item.text,"WHISPER",nil,item.target)
  else BASE(item.text,"WHISPER",nil,item.target) end
 end
end

local M={}
function M.Init() install() end
function M.OnUpdate()
 if SendChatMessage~=WRAPPER then install() end
 processQueue()
 local t=now(); local key,stamp
 for key,stamp in pairs(Q.recent) do if (t-(tonumber(stamp) or 0))>120 then Q.recent[key]=nil end end
end
function M.Shutdown()
 if WRAPPER and BASE and SendChatMessage==WRAPPER then SendChatMessage=BASE end
 if Q.wrapper==WRAPPER then Q.wrapper=nil; Q.base=nil end
end

H.Register("customermessagepolicy",M,VERSION)
W112_SUMMONSCOUT_CUSTOMER_MESSAGE_POLICY_VERSION=VERSION
