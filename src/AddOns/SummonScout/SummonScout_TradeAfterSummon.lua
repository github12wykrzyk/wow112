-- Trade-open watchdog after a successful summon for WoW 1.12.1 / Lua 5.0.
-- When a customer summon completes, wait 6s. If that customer has not already
-- initiated/opened trade, start trade from the summoner. Bounded to 2 attempts.
local H = W112_SUMMONSCOUT_HOT
if not H or type(H.Register) ~= "function" or type(H.GetState) ~= "function" then return end

local VERSION = "1-six-second-trade-open"
local S = H.GetState("tradeaftersummon")
S.pending = type(S.pending) == "table" and S.pending or {}
S.recentTrade = type(S.recentTrade) == "table" and S.recentTrade or {}
S.prevActiveName = tostring(S.prevActiveName or "")
S.prevStarted = S.prevStarted and true or false

local OPEN_DELAY = 6.0
local RETRY_DELAY = 2.0
local MAX_ATTEMPTS = 2
local WINDOW_TTL = 30.0

local function taNow()
    if GetTime then return GetTime() end
    return 0
end

local function taTrim(v)
    v=tostring(v or "")
    v=string.gsub(v,"^%s+","")
    return string.gsub(v,"%s+$","")
end

local function taKey(v)
    return string.lower(taTrim(v))
end

local function taSame(a,b)
    a=taKey(a); b=taKey(b)
    return a~="" and a==b
end

local function taDebug(text)
    if SummonScoutDB and SummonScoutDB.debug and DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffSummonScout trade:|r "..tostring(text or ""))
    end
end

local function taCore()
    local core=W112_SUMMONSCOUT_STATE
    if type(core)~="table" then return nil end
    return core
end

local function taGroupUnit(name)
    if not UnitName then return nil end
    local i
    for i=1,(GetNumPartyMembers and GetNumPartyMembers() or 0) do
        local unit="party"..i
        if taSame(UnitName(unit),name) then return unit end
    end
    if GetNumRaidMembers then
        for i=1,(GetNumRaidMembers() or 0) do
            local unit="raid"..i
            local raidName=GetRaidRosterInfo and GetRaidRosterInfo(i) or nil
            if taSame(raidName or UnitName(unit),name) then return unit end
        end
    end
    return nil
end

local function taTradePartner()
    local name
    if UnitName then
        name=UnitName("NPC")
        if taTrim(name or "")~="" then return taTrim(name) end
    end
    if TradeFrameRecipientNameText and TradeFrameRecipientNameText.GetText then
        name=TradeFrameRecipientNameText:GetText()
        if taTrim(name or "")~="" then return taTrim(name) end
    end
    return nil
end

local function taMarkTrade(name)
    name=taTrim(name or "")
    if name=="" then return end
    local key=taKey(name)
    S.recentTrade[key]=taNow()
    if S.pending[key] then
        S.pending[key]=nil
        taDebug("customer opened trade first -> "..name)
    end
end

local function taRecent(name,seconds)
    local at=tonumber(S.recentTrade[taKey(name)]) or -100000
    return (taNow()-at)<(seconds or 12.0)
end

local function taSchedule(name)
    name=taTrim(name or "")
    if name=="" or taRecent(name,12.0) then return end
    local core=taCore()
    local partner=taTradePartner()
    if core and core.tradeActive and partner and taSame(partner,name) then return end
    local key=taKey(name)
    local t=taNow()
    S.pending[key]={
        name=name,
        dueAt=t+OPEN_DELAY,
        expiresAt=t+WINDOW_TTL,
        attempts=0,
        finalWait=false,
    }
    taDebug("armed 6s -> "..name)
end

local function taInTradeRange(unit)
    if not CheckInteractDistance then return true end
    if pcall then
        local ok,result=pcall(CheckInteractDistance,unit,2)
        if not ok then return true end
        return result and true or false
    end
    return CheckInteractDistance(unit,2) and true or false
end

local function taBusy()
    if UnitAffectingCombat and UnitAffectingCombat("player") then return true end
    if CastingBarFrame and (CastingBarFrame.casting or CastingBarFrame.channeling) then return true end
    return false
end

local function taProcessPending()
    local core=taCore()
    local t=taNow()
    local key,item
    for key,item in pairs(S.pending) do
        if not item or taRecent(item.name,12.0) then
            S.pending[key]=nil
        elseif t>=(tonumber(item.expiresAt) or 0) then
            taDebug("trade watchdog expired -> "..tostring(item.name or "?"))
            S.pending[key]=nil
        elseif t>=(tonumber(item.dueAt) or 0) then
            if item.finalWait then
                S.pending[key]=nil
            elseif core and core.tradeActive then
                item.dueAt=t+0.50
            elseif taBusy() then
                item.dueAt=t+0.50
            else
                local unit=taGroupUnit(item.name)
                if not unit then
                    S.pending[key]=nil
                elseif not taInTradeRange(unit) then
                    item.dueAt=t+0.50
                elseif type(InitiateTrade)~="function" then
                    taDebug("InitiateTrade unavailable")
                    S.pending[key]=nil
                else
                    local ok=true
                    if pcall then ok=pcall(InitiateTrade,unit)
                    else InitiateTrade(unit) end
                    item.attempts=(tonumber(item.attempts) or 0)+1
                    if ok then
                        taDebug("open trade attempt "..tostring(item.attempts).." -> "..item.name)
                    end
                    if item.attempts>=MAX_ATTEMPTS then
                        item.finalWait=true
                        item.dueAt=t+RETRY_DELAY
                    else
                        item.dueAt=t+RETRY_DELAY
                    end
                end
            end
        end
    end
end

local function taObserveSummonCompletion()
    local core=taCore()
    if not core then return end
    local active=taTrim(core.summonActiveName or "")
    local started=core.summonActiveStarted and true or false

    if S.prevActiveName~="" and S.prevStarted
        and (active=="" or not taSame(active,S.prevActiveName)) then
        taSchedule(S.prevActiveName)
    end

    S.prevActiveName=active
    S.prevStarted=started
end

local M={}

function M.Init()
    S.pending={}
    S.recentTrade={}
    local core=taCore()
    S.prevActiveName=core and taTrim(core.summonActiveName or "") or ""
    S.prevStarted=core and core.summonActiveStarted and true or false
    H.RegisterEvent("PLAYER_LOGIN")
    H.RegisterEvent("TRADE_REQUEST")
    H.RegisterEvent("TRADE_SHOW")
    W112_SUMMONSCOUT_TRADE_AFTER_SUMMON_VERSION=VERSION
end

function M.OnEvent(ev,a1)
    if ev=="PLAYER_LOGIN" then
        S.pending={}
        S.recentTrade={}
        local core=taCore()
        S.prevActiveName=core and taTrim(core.summonActiveName or "") or ""
        S.prevStarted=core and core.summonActiveStarted and true or false
        return
    end
    if ev=="TRADE_REQUEST" then
        taMarkTrade(a1 or "")
        return
    end
    if ev=="TRADE_SHOW" then
        local partner=taTradePartner()
        if partner then taMarkTrade(partner) end
    end
end

function M.OnUpdate()
    taObserveSummonCompletion()
    taProcessPending()
end

function M.Shutdown() end

H.Register("tradeaftersummon",M,VERSION)
W112_SUMMONSCOUT_TRADE_AFTER_SUMMON_VERSION=VERSION
