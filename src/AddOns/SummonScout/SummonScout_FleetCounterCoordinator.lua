-- Fleet-wide competitive counter coordinator for SummonScout.
-- Cold-loaded on purpose: filename must not end in *Hot.lua.
-- WoW 1.12.1 / Lua 5.0 compatible; grant is a one-shot commit (no retry/reassign).

SummonScoutDB = SummonScoutDB or {}

local C = {}
C.VERSION = "1"
C.PROTO = "[SSFR1]"
C.HB = 12
C.TTL = 38
C.FAIL_SILENT = 30
C.EVENT_TTL = 45
C.COLLECT = 0.8
C.MAX_PACKET = 235
C.MAX_EVENTS = 64
C.EXPECTED = { "hydraxian", "hyjal", "winterspring", "silithus" }
C.LABEL = { hydraxian="HYDRAXIAN", hyjal="HYJAL", winterspring="WINTERSPRING", silithus="SILITHUS" }
C.ALLOWED = { hydraxian=true, hyjal=true, winterspring=true, silithus=true }
C.peers, C.events, C.outbound, C.roster, C.lastSpeaker = {}, {}, {}, {}, {}
C.capAt, C.hadCap, C.masterActive, C.masterPrice = -100000, false, false, 3
C.nextHb, C.nextTick, C.nextGui, C.nextGuiRefresh = 0, 0, 0, 0
C.pending = nil
C.metrics = { grants=0, sends=0, suppressed=0, failed=0 }

function C.now() return GetTime and GetTime() or 0 end
function C.wall() return time and time() or 0 end
function C.trim(v)
    local s=tostring(v or "")
    s=string.gsub(s,"^%s+",""); s=string.gsub(s,"%s+$","")
    return s
end
function C.lower(v) return string.lower(C.trim(v)) end
function C.same(a,b) a=C.lower(a); b=C.lower(b); return a~="" and a==b end
function C.me() return C.trim(UnitName and UnitName("player") or "") end
function C.master() return C.trim(SummonScoutDB.masterName or "") end
function C.isMaster() return C.same(C.me(),C.master()) end
function C.validName(v)
    v=C.trim(v); return string.len(v)>=2 and string.len(v)<=24 and not string.find(v,"[^%a%-]")
end
function C.chat(v)
    local api=W112_SUMMONSCOUT_API_V1
    if type(api)=="table" and type(api.chat)=="function" then api.chat("fleet counter: "..tostring(v or ""))
    elseif DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffSummonScout fleet:|r "..tostring(v or "")) end
end
function C.norm(v)
    local api=W112_SUMMONSCOUT_API_V1
    if type(api)=="table" and type(api.normalizeMessage)=="function" then return api.normalizeMessage(v or "") end
    local s=C.lower(v); s=string.gsub(s,"|c%x%x%x%x%x%x%x%x"," "); s=string.gsub(s,"|r"," ")
    s=string.gsub(s,"|H.-|h(.-)|h","%1"); s=string.gsub(s,"[%p%c]"," "); s=string.gsub(s,"%s+"," ")
    return C.trim(s)
end
function C.hash(v)
    local h=5381; local i; v=tostring(v or "")
    for i=1,string.len(v) do h=math.mod((h*131)+string.byte(v,i),2147483629) end
    return tostring(h)
end
function C.eventType(e) if e=="CHAT_MSG_YELL" then return "Y" elseif e=="CHAT_MSG_SAY" then return "S" end return "C" end
function C.eventId(sender,msg,e) return "e1-"..C.hash(C.lower(sender).."|"..C.eventType(e).."|"..C.norm(msg)) end
function C.validEvent(v) return string.len(tostring(v or ""))<=24 and string.find(tostring(v or ""),"^e1%-%d+$")~=nil end

function C.hex(v)
    local s=tostring(v or ""); local out=""; local i
    for i=1,string.len(s) do out=out..string.format("%02x",string.byte(s,i)) end
    return out
end
function C.unhex(v)
    local s=tostring(v or ""); local out=""; local i
    if math.mod(string.len(s),2)~=0 or string.find(s,"[^0-9a-fA-F]") then return nil end
    for i=1,string.len(s),2 do local b=tonumber(string.sub(s,i,i+1),16); if not b then return nil end; out=out..string.char(b) end
    return out
end
function C.split(v)
    local s=tostring(v or ""); local out={}; local p=1; local at
    while true do at=string.find(s,":",p,true); if not at then out[table.getn(out)+1]=string.sub(s,p); break end
        out[table.getn(out)+1]=string.sub(s,p,at-1); p=at+1 end
    return out
end
function C.parse(raw)
    raw=tostring(raw or ""); if string.sub(raw,1,string.len(C.PROTO))~=C.PROTO then return nil end
    local parts=C.split(C.trim(string.sub(raw,string.len(C.PROTO)+1))); local fields={}; local i
    if not parts[1] or parts[1]=="" then return nil end
    for i=2,table.getn(parts) do local d=C.unhex(parts[i]); if d==nil then return nil end; fields[table.getn(fields)+1]=d end
    return parts[1],fields
end
function C.sendCtl(target,code,fields)
    target=C.trim(target); if not C.validName(target) or not SendChatMessage then return false end
    local p=C.PROTO.." "..tostring(code or ""); local i; fields=fields or {}
    for i=1,table.getn(fields) do p=p..":"..C.hex(fields[i] or "") end
    if string.len(p)>C.MAX_PACKET then return false end
    if pcall then return pcall(SendChatMessage,p,"WHISPER",nil,target) end
    SendChatMessage(p,"WHISPER",nil,target); return true
end

function C.services(csv)
    local seen={}; local out={}; local token; local i
    for token in string.gfind(C.lower(csv),"[^,]+") do token=C.lower(token); if C.ALLOWED[token] then seen[token]=true end end
    for i=1,table.getn(C.EXPECTED) do token=C.EXPECTED[i]; if seen[token] then out[table.getn(out)+1]=token end end
    return table.concat(out,",")
end
function C.localServices()
    local s=C.lower(SummonScoutDB.service or ""); if s=="" or s=="all" then return "" end
    return C.services(s)
end
function C.set(csv) local t={}; local x; for x in string.gfind(C.services(csv),"[^,]+") do t[x]=true end; return t end
function C.price()
    local v=math.floor(tonumber(SummonScoutDB.fleetCounterPrice) or 3); if v<1 then v=1 elseif v>99 then v=99 end; return v
end
function C.cooldown()
    local v=math.floor(tonumber(SummonScoutDB.counterCooldown) or 60); if v<15 then v=15 elseif v>3600 then v=3600 end; return v
end
function C.count(t) local n=0; local k; for k in pairs(t or {}) do n=n+1 end; return n end
function C.cap(t,max)
    while C.count(t)>max do local oldK=nil; local oldT=nil; local k,v
        for k,v in pairs(t) do local x=type(v)=="table" and tonumber(v.seen or v.created or v.sent or v.updated) or 0; x=x or 0
            if oldT==nil or x<oldT then oldT=x; oldK=k end end
        if oldK==nil then break end; t[oldK]=nil end
end

function C.fallback()
    local h=W112_SUMMONSCOUT_HOT; if not h or type(h.GetState)~="function" then return nil end
    if pcall then local ok,s=pcall(h.GetState,"fallbackrouter"); if ok and type(s)=="table" then return s end; return nil end
    local s=h.GetState("fallbackrouter"); if type(s)=="table" then return s end; return nil
end
function C.trusted(name)
    local key=C.lower(name); if key=="" then return false end
    if C.same(name,C.me()) or C.same(name,C.master()) then return true end
    local f=C.fallback(); local d,p; if not f then return false end
    if type(f.peers)=="table" and f.peers[key] then return true end
    if type(f.providers)=="table" then for d,p in pairs(f.providers) do if type(p)=="table" and p[key] then return true end end end
    if type(f.totalPoolOwners)=="table" then for d,p in pairs(f.totalPoolOwners) do if type(p)=="table" and p[key] then return true end end end
    return false
end
function C.fresh(name) local p=C.peers[C.lower(name)]; return p and (C.now()-(p.seen or -100000))<=C.TTL end
function C.recordName(name) if C.validName(name) then C.roster[C.lower(name)]=C.trim(name) end end

function C.freshServices()
    local have=C.set(C.localServices()); local k,p,x; local out={}; local i
    for k,p in pairs(C.peers) do if (C.now()-(p.seen or -100000))<=C.TTL then for x in string.gfind(C.services(p.services),"[^,]+") do have[x]=true end end end
    for i=1,table.getn(C.EXPECTED) do x=C.EXPECTED[i]; if have[x] then out[table.getn(out)+1]=x end end
    return table.concat(out,",")
end
function C.coverage(csv) local s=C.set(csv); local n=0; local i; for i=1,table.getn(C.EXPECTED) do if s[C.EXPECTED[i]] then n=n+1 end end; return n end
function C.owners()
    local n=C.localServices()~="" and 1 or 0; local k,p
    for k,p in pairs(C.peers) do if (C.now()-(p.seen or -100000))<=C.TTL and C.services(p.services)~="" then n=n+1 end end
    return n
end
function C.rosterCsv()
    local out={}; local seen={}; local me=C.me(); local k,p
    if C.validName(me) then out[1]=me; seen[C.lower(me)]=true end
    for k,p in pairs(C.peers) do if (C.now()-(p.seen or -100000))<=C.TTL and C.validName(p.name) and not seen[k] then out[table.getn(out)+1]=p.name; seen[k]=true end end
    table.sort(out); return table.concat(out,",")
end
function C.rollout()
    if not C.isMaster() then return end
    if tonumber(SummonScoutDB.fleetCounterRolloutVersion)~=1 then SummonScoutDB.fleetCounterRolloutVersion=1; SummonScoutDB.fleetCounterRolloutReady=false end
    if not SummonScoutDB.fleetCounterRolloutReady and C.coverage(C.freshServices())>=4 and C.owners()>=4 then
        SummonScoutDB.fleetCounterRolloutReady=true; C.chat("rollout READY 4/4 services + owners") end
end
function C.active()
    return C.isMaster() and SummonScoutDB.fleetCounterEnabled~=false and SummonScoutDB.fleetCounterRolloutReady and C.coverage(C.freshServices())>0
end
function C.known(name)
    local k=C.lower(name); if k=="" then return false end
    return C.same(name,C.me()) or C.same(name,C.master()) or C.roster[k]~=nil or (C.isMaster() and C.fresh(name))
end

function C.capability(target)
    return C.sendCtl(target,"FCE",{C.VERSION,C.active() and "1" or "0",tostring(C.price()),C.rosterCsv(),C.freshServices()})
end
function C.broadcast()
    if not C.isMaster() then return end; local k,p
    for k,p in pairs(C.peers) do if (C.now()-(p.seen or -100000))<=C.TTL then C.capability(p.name) end end
end
function C.heartbeat()
    if C.isMaster() or not C.validName(C.master()) then return false end
    return C.sendCtl(C.master(),"FCV",{C.VERSION,C.localServices(),tostring(tonumber(SummonScoutDB.lastAdvertWall) or 0)})
end
function C.onHeartbeat(sender,f)
    if not C.isMaster() or table.getn(f)~=3 or f[1]~=C.VERSION or not C.trusted(sender) then return end
    local svc=C.services(f[2]); if svc=="" then return end
    C.peers[C.lower(sender)]={name=C.trim(sender),services=svc,seen=C.now(),lastAdvert=tonumber(f[3]) or 0}
    C.recordName(sender); C.cap(C.peers,12); C.rollout(); C.capability(sender)
end
function C.onCapability(sender,f)
    if C.isMaster() or not C.same(sender,C.master()) or table.getn(f)~=5 or f[1]~=C.VERSION then return end
    if f[2]~="0" and f[2]~="1" then return end
    C.capAt=C.now(); C.hadCap=true; C.masterActive=f[2]=="1"; C.masterPrice=tonumber(f[3]) or 3
    if C.masterPrice<1 or C.masterPrice>99 then C.masterPrice=3 end
    C.roster={}; local x; for x in string.gfind(tostring(f[4] or ""),"[^,]+") do if C.validName(x) then C.roster[C.lower(x)]=C.trim(x) end end
    C.recordName(sender)
end

function C.cancelLegacy(sender)
    local s=W112_SUMMONSCOUT_STATE; if type(s)~="table" then return end
    if s.counterSender and not C.same(s.counterSender,sender) then return end
    s.counterAt=0; s.counterSender=nil; s.counterLocationLabel=nil
end
function C.addCandidate(id,typ,name)
    if not C.validEvent(id) then return end; local t=C.now(); local e=C.events[id]; local k=C.lower(name)
    if e and e.state~="collecting" then return end
    if not e then e={created=t,updated=t,deadline=t+C.COLLECT,expires=t+C.EVENT_TTL,state="collecting",typ=typ,candidates={}}; C.events[id]=e end
    e.updated=t; e.candidates[k]={name=C.trim(name),seen=t}; C.cap(C.events,C.MAX_EVENTS)
end
function C.onCandidate(sender,f)
    if not C.isMaster() or table.getn(f)~=3 or f[1]~=C.VERSION or not C.validEvent(f[2]) or not C.fresh(sender) then return end
    C.addCandidate(f[2],f[3],sender)
end

function C.Submit(sender,msg,evt)
    sender=C.trim(sender); if sender=="" or C.same(sender,C.me()) then return true end
    if C.known(sender) then
        if C.isMaster() and C.fresh(sender) then C.peers[C.lower(sender)].lastAdvert=C.wall() end
        C.cancelLegacy(sender); return true
    end
    local id=C.eventId(sender,msg,evt); local t=C.now(); local age
    if C.isMaster() then
        C.cancelLegacy(sender)
        if not C.active() then C.metrics.suppressed=C.metrics.suppressed+1; return true end
        if not C.outbound[id] or t>(C.outbound[id].expires or 0) then C.outbound[id]={sent=t,expires=t+C.EVENT_TTL,granted=false} end
        C.addCandidate(id,C.eventType(evt),C.me()); return true
    end
    age=t-(C.capAt or -100000)
    if C.hadCap and age<=(C.TTL+C.FAIL_SILENT) then
        C.cancelLegacy(sender)
        if age<=C.TTL and C.masterActive and (not C.outbound[id] or t>(C.outbound[id].expires or 0)) then
            C.outbound[id]={sent=t,expires=t+C.EVENT_TTL,granted=false}
            C.sendCtl(C.master(),"FCC",{C.VERSION,id,C.eventType(evt)}); C.cap(C.outbound,C.MAX_EVENTS)
        end
        return true
    end
    return false
end

function C.choose(e)
    local win=nil; local winLast=nil; local k,v
    for k,v in pairs(e.candidates or {}) do
        local eligible=C.same(v.name,C.me()) and C.localServices()~="" or C.fresh(v.name)
        if eligible then local last=tonumber(C.lastSpeaker[k]) or -100000
            if not win or last<winLast or (last==winLast and C.lower(v.name)<C.lower(win)) then win=v.name; winLast=last end end
    end
    return win
end
function C.latestAdvert()
    local latest=tonumber(SummonScoutDB.lastAdvertWall) or 0; local k,p
    for k,p in pairs(C.peers) do if (C.now()-(p.seen or -100000))<=C.TTL and (tonumber(p.lastAdvert) or 0)>latest then latest=tonumber(p.lastAdvert) or latest end end
    return latest
end
function C.queueGrant(id,svc,price)
    local o=C.outbound[id]; if not o or C.now()>(o.expires or 0) or o.granted then return false end
    svc=C.services(svc); price=math.floor(tonumber(price) or 0); if svc=="" or price<1 or price>99 then return false end
    o.granted=true; o.updated=C.now(); C.pending={id=id,svc=svc,price=price,at=C.now()+0.2}; return true
end
function C.onGrant(sender,f)
    if C.isMaster() or not C.same(sender,C.master()) or table.getn(f)~=4 or f[1]~=C.VERSION or not C.validEvent(f[2]) then return end
    C.queueGrant(f[2],f[3],f[4])
end
function C.commit(id,e)
    local t=C.now(); local w=C.wall(); local last=tonumber(SummonScoutDB.fleetCounterLastGrantWall) or 0; local latest=C.latestAdvert()
    e.state="committed"; e.updated=t; C.rollout()
    if not C.active() then e.result="inactive"; C.metrics.suppressed=C.metrics.suppressed+1; return end
    if last>0 and w>=last and (w-last)<C.cooldown() then e.result="cooldown"; C.metrics.suppressed=C.metrics.suppressed+1; return end
    if latest>0 and w>=latest and (w-latest)<15 then e.result="recent-advert"; C.metrics.suppressed=C.metrics.suppressed+1; return end
    local win=C.choose(e); local svc=C.freshServices(); local price=C.price()
    if not win or svc=="" then e.result="no-winner"; C.metrics.suppressed=C.metrics.suppressed+1; return end
    -- GRANT IS COMMIT: never retry/reassign after this point, even if delivery is uncertain.
    SummonScoutDB.fleetCounterLastGrantWall=w; C.lastSpeaker[C.lower(win)]=t; e.winner=win; e.result="granted"; C.metrics.grants=C.metrics.grants+1
    if C.same(win,C.me()) then C.queueGrant(id,svc,price) else C.sendCtl(win,"FCG",{C.VERSION,id,svc,tostring(price)}) end
end

function C.render(svc,price)
    local set=C.set(svc); local labels={}; local i,id
    for i=1,table.getn(C.EXPECTED) do id=C.EXPECTED[i]; if set[id] then labels[table.getn(labels)+1]=C.LABEL[id] end end
    price=math.floor(tonumber(price) or 0); if table.getn(labels)==0 or price<1 or price>99 then return nil end
    return "WTS "..table.concat(labels,"/").." SUMMON "..tostring(price).."G"
end
function C.sendAdvert(text)
    local msg=C.trim(text); if msg=="" or string.len(msg)>220 or not SendChatMessage then return false,"invalid" end
    local norm=C.norm(msg); local w=C.wall(); local last=tonumber(SummonScoutDB.lastAdvertWall) or 0; local s=W112_SUMMONSCOUT_STATE
    if norm~="" and norm==(SummonScoutDB.lastAdvertNormalized or "") and last>0 and w>=last and (w-last)<15 then return true,"suppressed" end
    if type(s)=="table" and norm==C.norm(s.lastAdvertMessage or "") and (C.now()-(s.lastAdvertSentAt or -100000))<15 then return true,"suppressed" end
    if not GetChannelName then return false,"no-channel" end
    local ch=GetChannelName(SummonScoutDB.channel or "World"); if type(ch)~="number" or ch<=0 then return false,"no-channel" end
    if pcall and not pcall(SendChatMessage,msg,"CHANNEL",nil,ch) then return false,"send-error" elseif not pcall then SendChatMessage(msg,"CHANNEL",nil,ch) end
    SummonScoutDB.lastAdvertNormalized=norm; SummonScoutDB.lastAdvertWall=w
    if type(s)=="table" then s.lastAdvertMessage=msg; s.lastAdvertSentAt=C.now(); s.lastCounterAt=C.now(); if SummonScoutDB.spamEnabled then s.nextSpamAt=C.now()+(tonumber(SummonScoutDB.spamInterval) or 120) end end
    return true,"sent"
end
function C.processGrant()
    local g=C.pending; if not g or C.now()<(g.at or 0) then return end; C.pending=nil
    local text=C.render(g.svc,g.price); local ok,res=false,"invalid"; if text then ok,res=C.sendAdvert(text) end
    if ok and res=="sent" then C.metrics.sends=C.metrics.sends+1 elseif ok then C.metrics.suppressed=C.metrics.suppressed+1 else C.metrics.failed=C.metrics.failed+1 end
    if C.isMaster() then C.lastAck={id=g.id,status=res,at=C.now()} else C.sendCtl(C.master(),"FCA",{C.VERSION,g.id,res}) end
end
function C.onAck(sender,f)
    if not C.isMaster() or table.getn(f)~=3 or f[1]~=C.VERSION or not C.validEvent(f[2]) or not C.fresh(sender) then return end
    C.lastAck={id=f[2],status=C.trim(f[3]),at=C.now(),sender=C.trim(sender)}
end

function C.prune()
    local t=C.now(); local k,v
    for k,v in pairs(C.peers) do if (t-(v.seen or -100000))>(C.TTL+C.FAIL_SILENT) then C.peers[k]=nil end end
    for k,v in pairs(C.events) do if t>(v.expires or ((v.created or t)+C.EVENT_TTL)) then C.events[k]=nil end end
    for k,v in pairs(C.outbound) do if t>(v.expires or ((v.sent or t)+C.EVENT_TTL)) then C.outbound[k]=nil end end
    C.cap(C.events,C.MAX_EVENTS); C.cap(C.outbound,C.MAX_EVENTS)
end
function C.tickEvents()
    if not C.isMaster() then return end; local t=C.now(); local k,v
    for k,v in pairs(C.events) do if v.state=="collecting" and t>=(v.deadline or 0) then C.commit(k,v) end end
end
function C.onWhisper(raw,sender)
    local code,f=C.parse(raw); if not code then return end
    if code=="FCV" then C.onHeartbeat(sender,f) elseif code=="FCE" then C.onCapability(sender,f)
    elseif code=="FCC" then C.onCandidate(sender,f) elseif code=="FCG" then C.onGrant(sender,f) elseif code=="FCA" then C.onAck(sender,f) end
end

function C.guiMaster()
    if C.isMaster() then return true end; C.chat("settings are controlled on master "..(C.master()~="" and C.master() or "<unset>")); return false
end
function C.savePrice()
    if not C.guiMaster() or not C.gPrice then return end; local v=tonumber(C.trim(C.gPrice:GetText() or ""))
    if not v or v<1 or v>99 then C.chat("group price must be 1-99g"); C.gPrice:SetText(tostring(C.price())); return end
    SummonScoutDB.fleetCounterPrice=math.floor(v); C.gPrice:SetText(tostring(C.price())); C.broadcast(); C.chat("group price -> "..tostring(C.price()).."g")
end
function C.toggle()
    if not C.guiMaster() or not C.gCheck then C.refreshGui(); return end
    SummonScoutDB.fleetCounterEnabled=C.gCheck:GetChecked() and true or false; C.broadcast(); C.refreshGui()
end
function C.attachGui()
    if C.gui then return true end; local f=getglobal and getglobal("SummonScoutOptionsFrame") or nil; if not f then return false end
    C.gCheck=CreateFrame("CheckButton",nil,f,"UICheckButtonTemplate"); C.gCheck:SetPoint("TOPLEFT",f,"TOPLEFT",368,-468); C.gCheck:SetWidth(20); C.gCheck:SetHeight(20); C.gCheck:SetScript("OnClick",C.toggle)
    C.gLabel=f:CreateFontString(nil,"OVERLAY","GameFontNormalSmall"); C.gLabel:SetPoint("TOPLEFT",f,"TOPLEFT",390,-470); C.gLabel:SetText("Fleet counter")
    C.gPriceLabel=f:CreateFontString(nil,"OVERLAY","GameFontNormalSmall"); C.gPriceLabel:SetPoint("TOPLEFT",f,"TOPLEFT",500,-470); C.gPriceLabel:SetText("Price:")
    C.gPrice=CreateFrame("EditBox",nil,f,"InputBoxTemplate"); C.gPrice:SetPoint("TOPLEFT",f,"TOPLEFT",536,-465); C.gPrice:SetWidth(34); C.gPrice:SetHeight(20); C.gPrice:SetAutoFocus(false); C.gPrice:SetMaxLetters(2)
    C.gPriceFocus=false; C.gPrice:SetScript("OnEditFocusGained",function() C.gPriceFocus=true end); C.gPrice:SetScript("OnEditFocusLost",function() C.gPriceFocus=false end)
    C.gPrice:SetScript("OnEnterPressed",function() C.savePrice(); C.gPrice:ClearFocus() end); C.gPrice:SetScript("OnEscapePressed",function() C.gPrice:ClearFocus() end)
    C.gButton=CreateFrame("Button",nil,f,"UIPanelButtonTemplate"); C.gButton:SetPoint("TOPLEFT",f,"TOPLEFT",574,-465); C.gButton:SetWidth(40); C.gButton:SetHeight(20); C.gButton:SetText("Set"); C.gButton:SetScript("OnClick",C.savePrice)
    C.gStatus=f:CreateFontString(nil,"OVERLAY","GameFontNormalSmall"); C.gStatus:SetPoint("TOPLEFT",f,"TOPLEFT",370,-498); C.gui=true; C.refreshGui(); return true
end
function C.refreshGui()
    if not C.gui then return end; local status
    if C.isMaster() then
        local cov=C.coverage(C.freshServices()); local owners=C.owners(); C.gCheck:SetChecked(SummonScoutDB.fleetCounterEnabled~=false and 1 or nil)
        if not C.gPriceFocus then C.gPrice:SetText(tostring(C.price())) end
        if not SummonScoutDB.fleetCounterRolloutReady then status="Fleet: WAIT "..cov.."/4 svc, "..owners.."/4 owners"
        elseif C.active() then status="Fleet: ACTIVE "..cov.."/4 | "..C.price().."g" else status="Fleet: OFF | online "..cov end
    else
        local age=C.now()-(C.capAt or -100000); C.gCheck:SetChecked((C.hadCap and C.masterActive) and 1 or nil); if not C.gPriceFocus then C.gPrice:SetText(tostring(C.masterPrice)) end
        if C.hadCap and age<=C.TTL then status="Fleet: master "..(C.masterActive and "ACTIVE" or "WAIT/OFF").." | hb "..math.floor(age).."s"
        elseif C.hadCap and age<=(C.TTL+C.FAIL_SILENT) then status="Fleet: master LOST | fail-silent" else status="Fleet: legacy fallback" end
    end
    C.gStatus:SetText(status)
end

function C.defaults()
    if SummonScoutDB.fleetCounterEnabled==nil then SummonScoutDB.fleetCounterEnabled=true end
    if SummonScoutDB.fleetCounterPrice==nil then SummonScoutDB.fleetCounterPrice=3 end; SummonScoutDB.fleetCounterPrice=C.price()
    if tonumber(SummonScoutDB.fleetCounterRolloutVersion)~=1 then SummonScoutDB.fleetCounterRolloutVersion=1; SummonScoutDB.fleetCounterRolloutReady=false end
    if SummonScoutDB.fleetCounterLastGrantWall==nil then SummonScoutDB.fleetCounterLastGrantWall=0 end
end
function C.update()
    local t=C.now()
    if t>=C.nextHb then C.nextHb=t+C.HB; if C.isMaster() then C.rollout(); C.broadcast() else C.heartbeat() end end
    if t>=C.nextTick then C.nextTick=t+0.1; C.prune(); C.tickEvents(); C.processGrant() end
    if not C.gui and t>=C.nextGui then C.nextGui=t+1; C.attachGui() end
    if C.gui and t>=C.nextGuiRefresh then C.nextGuiRefresh=t+1; C.refreshGui() end
end

C.defaults(); C.recordName(C.master()); C.recordName(C.me())
C.frame=CreateFrame("Frame","SummonScoutFleetCounterFrame"); C.frame:RegisterEvent("PLAYER_LOGIN"); C.frame:RegisterEvent("CHAT_MSG_WHISPER")
C.frame:SetScript("OnEvent",function() if event=="PLAYER_LOGIN" then C.defaults(); C.nextHb=C.now()+1 elseif event=="CHAT_MSG_WHISPER" then C.onWhisper(arg1,arg2) end end)
C.frame:SetScript("OnUpdate",function() C.update() end)

W112_SUMMONSCOUT_FLEET_COUNTER_V1=C
W112_SUMMONSCOUT_FLEET_COUNTER_VERSION=C.VERSION
