-- SummonScout SSWR1 -> native WIM presentation (WoW 1.12.1 / Lua 5.0).
-- Transport stays the canonical WHISPER protocol. This module only renders it.
local H=W112_SUMMONSCOUT_HOT
if not H or type(H.Register)~="function" or type(H.GetState)~="function" then return end
local V, P, W = "2-native-whisper-wim", "[SSWR1]", H.GetState("whisperrelaywim")
W.chunks=W.chunks or {}; W.shown=W.shown or {}; W.nextClean=tonumber(W.nextClean) or 0

local function trim(s) s=tostring(s or ""); s=string.gsub(s,"^%s+",""); return string.gsub(s,"%s+$","") end
local function low(s) return string.lower(trim(s)) end
local function same(a,b) a=low(a); b=low(b); return a~="" and a==b end
local function now() if GetTime then return GetTime() end return 0 end
local function wall() if time then return time() end return 0 end
local function player() return trim(UnitName and UnitName("player") or "") end
local function master() return trim(SummonScoutDB and SummonScoutDB.masterName or "") end
local function isMaster() local a,b=player(),master(); return a~="" and b~="" and same(a,b) end
local function starts(s,p) s=tostring(s or ""); return string.sub(s,1,string.len(p))==p end
local function valid(n) n=trim(n); return n~="" and string.len(n)<=32 and not string.find(n,"[%c%s:;,=|]") end
local function unesc(s)
 s=tostring(s or ""); s=string.gsub(s,"%%0A","\n"); s=string.gsub(s,"%%0D","\r")
 s=string.gsub(s,"%%7[Cc]","|"); s=string.gsub(s,"%%3[Aa]",":"); return string.gsub(s,"%%25","%%")
end
local function split(s)
 local t,p={},1; s=tostring(s or "")
 while true do local a=string.find(s,":",p,true); if not a then t[table.getn(t)+1]=string.sub(s,p); break end
  t[table.getn(t)+1]=string.sub(s,p,a-1); p=a+1 end
 return t
end
local function packet(raw)
 if not starts(raw,P) then return nil end
 local r=trim(string.sub(raw,string.len(P)+1)); if r=="" then return nil end
 local a=split(r); local c=a[1]; if not c or c=="" then return nil end
 local f={}; for i=2,table.getn(a) do f[table.getn(f)+1]=unesc(a[i]) end; return c,f
end
local function chat(s) if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffRelay whisper:|r "..tostring(s or "")) end end
local function session(sid,summoner,customer)
 local D=SummonScoutDB and SummonScoutDB.whisperRelayV1; D=D and D.sessions
 local x=D and D[trim(sid)] or nil; if type(x)~="table" or x.status~="ACTIVE" then return nil end
 if not same(x.summoner_name,summoner) or not same(x.customer_name,customer) then return nil end
 local age=wall()-(tonumber(x.last_activity_at) or 0); if age<0 or age>1800 then return nil end; return x
end
local function boxFor(summoner)
 local q=type(WIM_Windows)=="table" and WIM_Windows[summoner] or nil
 if type(q)~="table" or type(q.frame)~="string" or not getglobal then return nil end
 return getglobal(q.frame.."MsgBox")
end
local function route(box)
 if not box then return false end
 local sid=trim(box.W112RelaySid or "")
 local s=trim(box.W112RelaySummoner or "")
 local c=trim(box.W112RelayCustomer or "")
 if sid=="" or s=="" or c=="" then return false end
 local text=trim(box.GetText and box:GetText() or ""); if text=="" then if box.SetText then box:SetText("") end; return true end
 if string.sub(text,1,1)=="/" then return false end
 if not isMaster() or not session(sid,s,c) then chat("reply blocked: stale/wrong relay session"); return true end
 local fn=SlashCmdList and SlashCmdList["SUMMONSCOUTRELAY"] or nil
 if type(fn)~="function" then chat("reply blocked: /ssr router unavailable"); return true end
 local cmd=s.." "..c.." "..text
 if pcall then local ok,e=pcall(fn,cmd); if not ok then chat("reply blocked: "..tostring(e or "router error")); return true end else fn(cmd) end
 if box.AddHistoryLine then box:AddHistoryLine(text) end; if box.SetText then box:SetText("") end; return true
end
local function enter()
 local b=this; local fn=W112_SUMMONSCOUT_RELAY_WIM_DISPATCH
 if type(fn)=="function" then local handled=false
  if pcall then local ok,v=pcall(fn,b); handled=ok and v and true or false; if not ok and b and trim(b.W112RelaySid or "")~="" then handled=true; chat("reply dispatch error; send suppressed") end
  else handled=fn(b) and true or false end
  if handled then return end
 end
 local base=b and b.W112RelayBaseEnter; if type(base)=="function" then return base() end
end
local function attach(summoner,sid,customer)
 local b=boxFor(summoner); if not b then return false end
 b.W112RelaySid=tostring(sid or ""); b.W112RelaySummoner=summoner; b.W112RelayCustomer=customer
 if not b.W112RelayBaseEnter and b.GetScript then b.W112RelayBaseEnter=b:GetScript("OnEnterPressed") end
 if not b.W112RelayEnterInstalled and b.SetScript then b:SetScript("OnEnterPressed",enter); b.W112RelayEnterInstalled=true end
 return true
end
local function show(sender,sid,customer,seq,raw,outgoing)
 sender=trim(sender); customer=trim(customer); raw=tostring(raw or "")
 if not valid(sender) or not valid(customer) or raw=="" or type(WIM_PostMessage)~="function" then return false end
 local k=low(sender).."|"..sid.."|"..tostring(seq).."|"..(outgoing and "O" or "I"); if W.shown[k] then return true end
 local msg=(outgoing and "|cffaaaaaa[to " or "|cff66ccff[")..customer.."]|r "..raw
 local typ=outgoing and 2 or 1; local from=outgoing and player() or sender; local ok=true
 if pcall then ok=pcall(WIM_PostMessage,sender,msg,typ,from,raw) else WIM_PostMessage(sender,msg,typ,from,raw) end
 if not ok then return false end; W.shown[k]=now(); attach(sender,sid,customer); return true
end
local function begin(sender,f)
 local sid,c,count=f[1] or "",f[2] or "",tonumber(f[9]) or 0; if sid=="" or not valid(c) or count<1 or count>20 then return true end
 W.chunks[low(sender).."|"..sid]={sender=sender,sid=sid,customer=c,seq=f[7] or "0",count=count,p={},at=now()}; return true
end
local function part(sender,f)
 local sid=f[1] or ""
 local idx=tonumber(f[2]) or 0
 local k=low(sender).."|"..sid
 local x=W.chunks[k]
 if type(x)~="table" or not same(x.sender,sender) or idx<1 or idx>x.count then return true end; x.p[idx]=f[3] or ""
 for i=1,x.count do if x.p[i]==nil then return true end end
 local raw=""; for i=1,x.count do raw=raw..x.p[i] end; W.chunks[k]=nil; return show(sender,x.sid,x.customer,x.seq,raw,false)
end
local function consume(ev,raw,sender)
 if ev~="CHAT_MSG_WHISPER" or not isMaster() or not starts(raw,P) then return false end
 local c,f=packet(raw); if not c then return true end
 if c=="I" then return show(sender,f[1] or "",f[2] or "",f[7] or "0",f[9] or "",false) end
 if c=="IB" then return begin(sender,f) end; if c=="IC" then return part(sender,f) end
 if c=="E" then local kind=f[5] or ""; if kind=="WHISPER_OUT_AUTO" or kind=="WHISPER_OUT_MASTER" then return show(sender,f[1] or "",f[2] or "",f[4] or "0",f[7] or "",true) end end
 return true
end
local function installWim()
 if type(WIM_ChatFrame_OnEvent)~="function" then return false end
 if type(W112_SUMMONSCOUT_RELAY_WIM_BASE)~="function" then W112_SUMMONSCOUT_RELAY_WIM_BASE=WIM_ChatFrame_OnEvent end
 if type(W112_SUMMONSCOUT_RELAY_WIM_WRAPPER)~="function" then
  W112_SUMMONSCOUT_RELAY_WIM_WRAPPER=function(ev)
   local fn=W112_SUMMONSCOUT_RELAY_WIM_EVENT; if type(fn)=="function" then local h=false
    if pcall then local ok,v=pcall(fn,ev,arg1,arg2); h=ok and v and true or false else h=fn(ev,arg1,arg2) and true or false end
    if h then return end end
   local b=W112_SUMMONSCOUT_RELAY_WIM_BASE; if type(b)=="function" then return b(ev) end
  end
 end
 W112_SUMMONSCOUT_RELAY_WIM_EVENT=consume; WIM_ChatFrame_OnEvent=W112_SUMMONSCOUT_RELAY_WIM_WRAPPER; return true
end
local function filterText(text)
 if not isMaster() or type(WIM_PostMessage)~="function" then return false end
 text=tostring(text or ""); return string.find(text,"SummonRelay:|r [",1,true)~=nil or string.find(text,"SummonRelay: [",1,true)~=nil
end
local function installChat()
 if not DEFAULT_CHAT_FRAME or type(DEFAULT_CHAT_FRAME.AddMessage)~="function" then return false end
 if type(W112_SUMMONSCOUT_RELAY_CHAT_BASE)~="function" then W112_SUMMONSCOUT_RELAY_CHAT_BASE=DEFAULT_CHAT_FRAME.AddMessage end
 if type(W112_SUMMONSCOUT_RELAY_CHAT_WRAPPER)~="function" then
  W112_SUMMONSCOUT_RELAY_CHAT_WRAPPER=function(self,text,r,g,b,id,hold)
   local fn=W112_SUMMONSCOUT_RELAY_CHAT_FILTER; if type(fn)=="function" then local h=false
    if pcall then local ok,v=pcall(fn,text); h=ok and v and true or false else h=fn(text) and true or false end; if h then return end end
   local base=W112_SUMMONSCOUT_RELAY_CHAT_BASE; if type(base)=="function" then return base(self,text,r,g,b,id,hold) end
  end
 end
 W112_SUMMONSCOUT_RELAY_CHAT_FILTER=filterText; DEFAULT_CHAT_FRAME.AddMessage=W112_SUMMONSCOUT_RELAY_CHAT_WRAPPER; return true
end
local function clean()
 local t=now(); for k,x in pairs(W.chunks) do if type(x)~="table" or t-(tonumber(x.at) or 0)>20 then W.chunks[k]=nil end end
 for k,a in pairs(W.shown) do if t-(tonumber(a) or 0)>120 then W.shown[k]=nil end end
end
local M={}
function M.Init() W112_SUMMONSCOUT_RELAY_WIM_DISPATCH=route; installWim(); installChat(); W.nextClean=now()+2; W112_SUMMONSCOUT_WHISPER_RELAY_WIM_VERSION=V end
function M.OnUpdate() installWim(); installChat(); local t=now(); if t>=(tonumber(W.nextClean) or 0) then W.nextClean=t+2; clean() end end
function M.Shutdown()
 if W112_SUMMONSCOUT_RELAY_WIM_DISPATCH==route then W112_SUMMONSCOUT_RELAY_WIM_DISPATCH=nil end
 if W112_SUMMONSCOUT_RELAY_WIM_EVENT==consume then W112_SUMMONSCOUT_RELAY_WIM_EVENT=nil end
 if W112_SUMMONSCOUT_RELAY_CHAT_FILTER==filterText then W112_SUMMONSCOUT_RELAY_CHAT_FILTER=nil end
end
H.Register("whisperrelaywim",M,V)
