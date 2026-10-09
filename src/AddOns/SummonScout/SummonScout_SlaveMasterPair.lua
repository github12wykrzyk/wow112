-- SummonScout fixed slave <-> master party ownership for WoW 1.12.1 / Lua 5.0.
-- Explicit, fail-closed character ownership. Tanaris is master-initiated by design.
-- Cold-loaded intentionally: fixed ownership is configuration/state policy, not HOT fanout payload.
local H = W112_SUMMONSCOUT_HOT
if not H or type(H.Register) ~= "function" or type(H.GetState) ~= "function" then return end

local VERSION = "6-tanaris-master-owned-cold"
local WATCH_INTERVAL = 2.00
local INVITE_COOLDOWN = 5.00
local PROMOTE_COOLDOWN = 2.00
local ACCEPT_COOLDOWN = 1.00

local SLAVE_TO_MASTER = {
    silione="Kalisum", silitwo="Kalisum",
    hyjaluno="Bolthyjal", hyjalonee="Bolthyjal",
    hydratwo="Feltaxi", hydraone="Feltaxi",
    winterone="Taxiwinter", wintertwoo="Taxiwinter",
    tanarisone="Teletanaris", tanaristwo="Teletanaris",
}
local MASTER_TO_SLAVES = {
    kalisum={silione=true,silitwo=true},
    bolthyjal={hyjaluno=true,hyjalonee=true},
    feltaxi={hydratwo=true,hydraone=true},
    taxiwinter={winterone=true,wintertwoo=true},
    teletanaris={tanarisone=true,tanaristwo=true},
}
local MASTER_SLAVE_LIST = {
    kalisum={"Silione","Silitwo"},
    bolthyjal={"Hyjaluno","Hyjalonee"},
    feltaxi={"Hydratwo","Hydraone"},
    taxiwinter={"Winterone","Wintertwoo"},
    teletanaris={"Tanarisone","Tanaristwo"},
}
local MASTER_INITIATED = { teletanaris=true }

local S=H.GetState("slavemasterpairs")
S.nextWatchAt=tonumber(S.nextWatchAt) or 0
S.nextInviteAt=tonumber(S.nextInviteAt) or 0
S.nextPromoteAt=tonumber(S.nextPromoteAt) or 0
S.nextAcceptAt=tonumber(S.nextAcceptAt) or 0
S.masterInviteAt=type(S.masterInviteAt)=="table" and S.masterInviteAt or {}

local function now() return GetTime and GetTime() or 0 end
local function trim(v) v=tostring(v or ""); v=string.gsub(v,"^%s+",""); return string.gsub(v,"%s+$","") end
local function key(v) return string.lower(trim(v)) end
local function me() return UnitName and (UnitName("player") or "") or "" end
local function partyCount() return GetNumPartyMembers and (tonumber(GetNumPartyMembers()) or 0) or 0 end
local function raidCount() return GetNumRaidMembers and (tonumber(GetNumRaidMembers()) or 0) or 0 end
local function grouped() return partyCount()>0 or raidCount()>0 end
local function debug(v)
    if SummonScoutDB and SummonScoutDB.debug and DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffSummonScout pairs:|r "..tostring(v or ""))
    end
end
local function findParty(wanted)
    local i,name
    for i=1,partyCount() do name=UnitName("party"..i); if name and key(name)==wanted then return name end end
    return nil
end
local function trusted(player,inviter)
    if player=="" or inviter=="" then return false,"" end
    local master=SLAVE_TO_MASTER[player]
    if master and key(master)==inviter then return true,"master" end
    local owned=MASTER_TO_SLAVES[player]
    if owned and owned[inviter] then return true,"slave" end
    return false,""
end
local function acceptTrusted(inviter)
    if type(AcceptGroup)~="function" then return end
    local t=now(); if t<(S.nextAcceptAt or 0) then return end
    local ok,relation=trusted(key(me()),key(inviter)); if not ok then return end
    S.nextAcceptAt=t+ACCEPT_COOLDOWN; S.lastAcceptedFrom=tostring(inviter or "")
    AcceptGroup(); if type(StaticPopup_Hide)=="function" then StaticPopup_Hide("PARTY_INVITE") end
    debug("accepted "..relation.." invite <- "..tostring(inviter or "?"))
end
local function inviteMaster(master)
    if type(InviteByName)~="function" then return end
    local t=now(); if t<(S.nextInviteAt or 0) then return end
    S.nextInviteAt=t+INVITE_COOLDOWN; S.lastInviteMaster=master; InviteByName(master)
    debug("slave invite -> "..tostring(master))
end
local function promoteMaster(masterKey)
    if type(UnitIsPartyLeader)~="function" or type(PromoteByName)~="function" or not UnitIsPartyLeader("player") then return end
    local name=findParty(masterKey); if not name then return end
    local t=now(); if t<(S.nextPromoteAt or 0) then return end
    S.nextPromoteAt=t+PROMOTE_COOLDOWN; S.lastPromotedMaster=name; PromoteByName(name)
    debug("leader handoff -> "..tostring(name))
end
local function inviteMissingSlaves(masterKey,allowUngrouped)
    if type(InviteByName)~="function" then return end
    if raidCount()>0 then return end
    if grouped() and (type(UnitIsPartyLeader)~="function" or not UnitIsPartyLeader("player")) then return end
    if not grouped() and not allowUngrouped then return end
    local list=MASTER_SLAVE_LIST[masterKey]; if type(list)~="table" then return end
    local t=now(); local i,slave,slaveKey,nextAt
    for i=1,table.getn(list) do
        slave=list[i]; slaveKey=key(slave)
        if not findParty(slaveKey) then
            nextAt=tonumber(S.masterInviteAt[slaveKey]) or 0
            if t>=nextAt then
                S.masterInviteAt[slaveKey]=t+INVITE_COOLDOWN; S.lastMasterRepairTarget=slave
                InviteByName(slave); debug("master invite/repair -> "..tostring(slave))
            end
        end
    end
end
local function seedPairBlacklist()
    SummonScoutDB=SummonScoutDB or {}; if type(SummonScoutDB.inviteBlacklist)~="table" then SummonScoutDB.inviteBlacklist={} end
    SummonScoutDB.inviteBlacklist.tanarisone=SummonScoutDB.inviteBlacklist.tanarisone or "fixed-pair-slave"
    SummonScoutDB.inviteBlacklist.tanaristwo=SummonScoutDB.inviteBlacklist.tanaristwo or "fixed-pair-slave"
end
local function watchdog()
    local player=key(me()); local master=SLAVE_TO_MASTER[player]
    if master then
        S.lastRole="slave"; S.lastOwner=master
        if not grouped() then
            if key(master)~="teletanaris" then inviteMaster(master) end
            return
        end
        if raidCount()<=0 then promoteMaster(key(master)) end
        return
    end
    if MASTER_TO_SLAVES[player] then
        S.lastRole="master"; S.lastOwner=""
        inviteMissingSlaves(player,MASTER_INITIATED[player] and true or false)
    else S.lastRole="inactive"; S.lastOwner="" end
end

local M={}
function M.Init()
    seedPairBlacklist(); S.nextWatchAt=0; S.nextInviteAt=0; S.nextPromoteAt=0; S.nextAcceptAt=0
    H.RegisterEvent("PARTY_INVITE_REQUEST"); H.RegisterEvent("PARTY_MEMBERS_CHANGED"); H.RegisterEvent("RAID_ROSTER_UPDATE")
    watchdog()
end
function M.OnEvent(ev,a1)
    if ev=="PARTY_INVITE_REQUEST" then acceptTrusted(a1); return end
    if ev=="PARTY_MEMBERS_CHANGED" or ev=="RAID_ROSTER_UPDATE" then S.nextWatchAt=0 end
end
function M.OnUpdate()
    local t=now(); if t<(S.nextWatchAt or 0) then return end; S.nextWatchAt=t+WATCH_INTERVAL; watchdog()
end
function M.Shutdown() end
H.Register("slavemasterpairs",M,VERSION)
W112_SUMMONSCOUT_SLAVE_MASTER_PAIRS_VERSION=VERSION
W112_SUMMONSCOUT_SLAVE_MASTER_PAIRS_ACTIVE={
    Silione="Kalisum",Silitwo="Kalisum",Hyjaluno="Bolthyjal",Hyjalonee="Bolthyjal",
    Hydratwo="Feltaxi",Hydraone="Feltaxi",Winterone="Taxiwinter",Wintertwoo="Taxiwinter",
    Tanarisone="Teletanaris",Tanaristwo="Teletanaris"
}
