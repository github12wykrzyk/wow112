-- Reliable post-payment cross-sell watchdog for WoW 1.12.1 / Lua 5.0.
-- Every NEW trusted payment ledger row must end with a full "other destinations"
-- whisper. Existing primary/fallback modules are allowed to win the race; this
-- module sends only when no complete offer was observed for that payer.
local H = W112_SUMMONSCOUT_HOT
if not H or type(H.Register) ~= "function" or type(H.GetState) ~= "function" then return end

local VERSION = "1-always-full-other-destinations"
local S = H.GetState("postpayment_always_offer")
S.pending = type(S.pending) == "table" and S.pending or {}
S.seenRows = type(S.seenRows) == "table" and S.seenRows or {}
S.nextPollAt = tonumber(S.nextPollAt) or 0

local FIRST_SEND_DELAY = 0.90
local ACK_WAIT = 1.20
local MAX_ATTEMPTS = 2

local DESTINATIONS = {
    { id="hyjal", label="Hyjal" },
    { id="hydraxian", label="Hydraxis" },
    { id="winterspring", label="Winterspring" },
    { id="silithus", label="Silithus" },
    { id="tanaris", label="Tanaris" },
}

local function aoNow()
    if GetTime then return GetTime() end
    return 0
end

local function aoTrim(v)
    v = tostring(v or "")
    v = string.gsub(v, "^%s+", "")
    return string.gsub(v, "%s+$", "")
end

local function aoKey(v)
    return string.lower(aoTrim(v))
end

local function aoSame(a,b)
    a=aoKey(a); b=aoKey(b)
    return a~="" and a==b
end

local function aoValidName(v)
    v=aoTrim(v)
    return v~="" and string.upper(v)~="UNKNOWN"
end

local function aoLocalServices()
    local out={}
    local service=aoKey(SummonScoutDB and SummonScoutDB.service or "")
    if service=="" or service=="all" then return out end
    local token
    for token in string.gfind(service,"[^,]+") do
        token=aoKey(token)
        if token~="" then out[token]=true end
    end
    return out
end

local function aoOtherLabels()
    local localSet=aoLocalServices()
    local labels={}
    local i
    for i=1,table.getn(DESTINATIONS) do
        local d=DESTINATIONS[i]
        if not localSet[d.id] then labels[table.getn(labels)+1]=d.label end
    end
    return labels
end

local function aoJoin(labels)
    local n=table.getn(labels or {})
    if n<=0 then return "" end
    if n==1 then return tostring(labels[1]) end
    if n==2 then return tostring(labels[1]).." and "..tostring(labels[2]) end
    local out=""
    local i
    for i=1,n do
        if i==1 then out=tostring(labels[i])
        elseif i==n then out=out.." and "..tostring(labels[i])
        else out=out..", "..tostring(labels[i]) end
    end
    return out
end

local function aoBuildMessage()
    local routes=aoJoin(aoOtherLabels())
    if routes=="" then return "Thanks for the payment!" end
    -- Prefix intentionally matches the legacy detector so its fallback will not duplicate us.
    return "Thanks. We also summon to "..routes.."."
end

local function aoCompleteOffer(message)
    local s=string.lower(tostring(message or ""))
    if string.find(s,"we also summon to ",1,true)==nil then return false end
    local labels=aoOtherLabels()
    local i
    for i=1,table.getn(labels) do
        if string.find(s,string.lower(labels[i]),1,true)==nil then return false end
    end
    return true
end

local function aoDebug(text)
    if SummonScoutDB and SummonScoutDB.debug and DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffSummonScout postpay-always:|r "..tostring(text or ""))
    end
end

local function aoSeedRows()
    local seen={}
    local log=SummonScoutDB and SummonScoutDB.paymentLog
    if type(log)=="table" then
        local i,row
        for i=1,table.getn(log) do
            row=log[i]
            if type(row)=="table" then seen[row]=true end
        end
    end
    S.seenRows=seen
end

local function aoQueue(row)
    if type(row)~="table" then return end
    local name=aoTrim(row.player or "")
    if not aoValidName(name) then
        aoDebug("skip unresolved payer")
        return
    end
    S.pending[table.getn(S.pending)+1]={
        name=name,
        dueAt=aoNow()+FIRST_SEND_DELAY,
        attempts=0,
        awaitingAck=false,
        confirmed=false,
        message=nil,
    }
    aoDebug("armed -> "..name)
end

local function aoObserveLedger()
    local log=SummonScoutDB and SummonScoutDB.paymentLog
    if type(log)~="table" then return end
    local previous=S.seenRows or {}
    local nextSeen={}
    local i,row
    for i=1,table.getn(log) do
        row=log[i]
        if type(row)=="table" then
            nextSeen[row]=true
            if not previous[row] then aoQueue(row) end
        end
    end
    S.seenRows=nextSeen
end

local function aoConfirm(message,name)
    if not aoValidName(name) or not aoCompleteOffer(message) then return false end
    local matched=false
    local i,item
    for i=1,table.getn(S.pending) do
        item=S.pending[i]
        if item and aoSame(item.name,name) then
            item.confirmed=true
            item.awaitingAck=false
            matched=true
        end
    end
    if matched then aoDebug("complete offer confirmed -> "..aoTrim(name)) end
    return matched
end

local function aoSend(item)
    if type(item)~="table" or not SendChatMessage then return false end
    if not item.message or item.message=="" then item.message=aoBuildMessage() end
    item.attempts=(tonumber(item.attempts) or 0)+1
    item.awaitingAck=true
    item.dueAt=aoNow()+ACK_WAIT
    if pcall then
        local ok=pcall(SendChatMessage,item.message,"WHISPER",nil,item.name)
        if not ok then
            item.awaitingAck=false
            item.dueAt=aoNow()+0.35
            return false
        end
    else
        SendChatMessage(item.message,"WHISPER",nil,item.name)
    end
    aoDebug("offer attempt "..tostring(item.attempts).." -> "..item.name)
    return true
end

local function aoProcess()
    local t=aoNow()
    local i
    for i=table.getn(S.pending),1,-1 do
        local item=S.pending[i]
        if not item or item.confirmed then
            table.remove(S.pending,i)
        elseif t>=(tonumber(item.dueAt) or 0) then
            if item.awaitingAck then
                item.awaitingAck=false
                if (tonumber(item.attempts) or 0)>=MAX_ATTEMPTS then
                    aoDebug("unconfirmed after bounded retry -> "..tostring(item.name or "?"))
                    table.remove(S.pending,i)
                else
                    item.dueAt=t
                end
            end
            if S.pending[i] and not S.pending[i].awaitingAck then
                if (tonumber(S.pending[i].attempts) or 0)>=MAX_ATTEMPTS then
                    table.remove(S.pending,i)
                else
                    aoSend(S.pending[i])
                end
            end
        end
    end
end

local M={}

function M.Init()
    S.pending={}
    S.nextPollAt=0
    aoSeedRows()
    H.RegisterEvent("PLAYER_LOGIN")
    H.RegisterEvent("CHAT_MSG_WHISPER_INFORM")
    W112_SUMMONSCOUT_POSTPAY_ALWAYS_OFFER_VERSION=VERSION
end

function M.OnEvent(ev,a1,a2)
    if ev=="PLAYER_LOGIN" then
        S.pending={}
        S.nextPollAt=0
        aoSeedRows()
        return
    end
    if ev=="CHAT_MSG_WHISPER_INFORM" then
        aoConfirm(a1 or "",a2 or "")
    end
end

function M.OnUpdate()
    local t=aoNow()
    if t>=(S.nextPollAt or 0) then
        S.nextPollAt=t+0.10
        aoObserveLedger()
    end
    aoProcess()
end

function M.Shutdown() end

H.Register("postpayment_always_offer",M,VERSION)
W112_SUMMONSCOUT_POSTPAY_ALWAYS_OFFER_VERSION=VERSION
