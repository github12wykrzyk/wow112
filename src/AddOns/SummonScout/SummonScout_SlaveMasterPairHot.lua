-- SummonScout fixed slave <-> master party ownership for WoW 1.12.1 / Lua 5.0.
--
-- Pairing is explicit and fail-closed. A slave only trusts its assigned master.
-- A master only accepts/invites its explicitly assigned slaves.
--
-- Slave behavior:
--   * when ungrouped, invite assigned master (5 s anti-spam cooldown),
--   * accept PARTY_INVITE_REQUEST only from assigned master,
--   * when slave is party leader and master is present, promote master.
--
-- Master behavior:
--   * accept an invite only from one of its assigned slaves,
--   * once grouped and party leader, invite any missing assigned slave.
--
-- This converges the intended 2 slaves + 1 master topology without touching
-- unrelated parties/raids and without trusting arbitrary invite senders.

local H = W112_SUMMONSCOUT_HOT
if not H or type(H.Register) ~= "function" or type(H.GetState) ~= "function" then
    return
end

local VERSION = "4-fixed-pairs-hyjalonee"
local WATCH_INTERVAL = 2.00
local INVITE_COOLDOWN = 5.00
local PROMOTE_COOLDOWN = 2.00
local ACCEPT_COOLDOWN = 1.00

local SLAVE_TO_MASTER = {
    silione   = "Kalisum",
    silitwo   = "Kalisum",
    hyjaluno  = "Bolthyjal",
    hyjalonee = "Bolthyjal",
    hydratwo  = "Feltaxi",
    hydraone  = "Feltaxi",
    winterone = "Taxiwinter",
    wintertwoo = "Taxiwinter",
}

local MASTER_TO_SLAVES = {
    kalisum = {
        silione = true,
        silitwo = true,
    },
    bolthyjal = {
        hyjaluno = true,
        hyjalonee = true,
    },
    feltaxi = {
        hydratwo = true,
        hydraone = true,
    },
    taxiwinter = {
        winterone = true,
        wintertwoo = true,
    },
}

local MASTER_SLAVE_LIST = {
    kalisum = { "Silione", "Silitwo" },
    bolthyjal = { "Hyjaluno", "Hyjalonee" },
    feltaxi = { "Hydratwo", "Hydraone" },
    taxiwinter = { "Winterone", "Wintertwoo" },
}

local S = H.GetState("slavemasterpairs")
S.nextWatchAt = tonumber(S.nextWatchAt) or 0
S.nextInviteAt = tonumber(S.nextInviteAt) or 0
S.nextPromoteAt = tonumber(S.nextPromoteAt) or 0
S.nextAcceptAt = tonumber(S.nextAcceptAt) or 0
S.masterInviteAt = type(S.masterInviteAt) == "table" and S.masterInviteAt or {}
S.lastInviteMaster = S.lastInviteMaster or ""
S.lastAcceptedFrom = S.lastAcceptedFrom or ""
S.lastPromotedMaster = S.lastPromotedMaster or ""
S.lastMasterRepairTarget = S.lastMasterRepairTarget or ""
S.lastRole = S.lastRole or "inactive"
S.lastOwner = S.lastOwner or ""

local function smNow()
    if GetTime then return GetTime() end
    return 0
end

local function smTrim(s)
    s = tostring(s or "")
    s = string.gsub(s, "^%s+", "")
    s = string.gsub(s, "%s+$", "")
    return s
end

local function smKey(name)
    return string.lower(smTrim(name))
end

local function smPlayerName()
    if type(UnitName) ~= "function" then return "" end
    return UnitName("player") or ""
end

local function smDebug(text)
    if SummonScoutDB and SummonScoutDB.debug and DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffSummonScout pairs:|r " .. tostring(text or ""))
    end
end

local function smPartyCount()
    if type(GetNumPartyMembers) ~= "function" then return 0 end
    return tonumber(GetNumPartyMembers()) or 0
end

local function smRaidCount()
    if type(GetNumRaidMembers) ~= "function" then return 0 end
    return tonumber(GetNumRaidMembers()) or 0
end

local function smGrouped()
    return smPartyCount() > 0 or smRaidCount() > 0
end

local function smFindPartyMember(wantedKey)
    if wantedKey == "" or type(UnitName) ~= "function" then return nil end
    local count = smPartyCount()
    local i, name
    for i = 1, count do
        name = UnitName("party" .. i)
        if name and smKey(name) == wantedKey then
            return name
        end
    end
    return nil
end

local function smTrustedInvite(playerKey, inviterKey)
    if playerKey == "" or inviterKey == "" then return false, "" end

    local master = SLAVE_TO_MASTER[playerKey]
    if master and smKey(master) == inviterKey then
        return true, "master"
    end

    local owned = MASTER_TO_SLAVES[playerKey]
    if owned and owned[inviterKey] then
        return true, "slave"
    end

    return false, ""
end

local function smAcceptTrusted(inviter)
    if type(AcceptGroup) ~= "function" then return end

    local t = smNow()
    if t < (S.nextAcceptAt or 0) then return end

    local playerKey = smKey(smPlayerName())
    local inviterKey = smKey(inviter)
    local trusted, relation = smTrustedInvite(playerKey, inviterKey)
    if not trusted then return end

    S.nextAcceptAt = t + ACCEPT_COOLDOWN
    S.lastAcceptedFrom = tostring(inviter or "")
    AcceptGroup()
    if type(StaticPopup_Hide) == "function" then
        StaticPopup_Hide("PARTY_INVITE")
    end
    smDebug("accepted " .. relation .. " invite <- " .. tostring(inviter or "?"))
end

local function smInviteAssignedMaster(master)
    if type(InviteByName) ~= "function" then return end

    local t = smNow()
    if t < (S.nextInviteAt or 0) then return end

    S.nextInviteAt = t + INVITE_COOLDOWN
    S.lastInviteMaster = master
    InviteByName(master)
    smDebug("slave invite -> " .. tostring(master))
end

local function smPromoteAssignedMaster(masterKey)
    if type(UnitIsPartyLeader) ~= "function" or type(PromoteByName) ~= "function" then return end
    if not UnitIsPartyLeader("player") then return end

    local actualName = smFindPartyMember(masterKey)
    if not actualName then return end

    local t = smNow()
    if t < (S.nextPromoteAt or 0) then return end

    S.nextPromoteAt = t + PROMOTE_COOLDOWN
    S.lastPromotedMaster = actualName
    PromoteByName(actualName)
    smDebug("leader handoff -> " .. tostring(actualName))
end

local function smMasterRepairMissingSlaves(masterKey)
    if type(InviteByName) ~= "function" or type(UnitIsPartyLeader) ~= "function" then return end
    if smRaidCount() > 0 or smPartyCount() <= 0 then return end
    if not UnitIsPartyLeader("player") then return end

    local list = MASTER_SLAVE_LIST[masterKey]
    if type(list) ~= "table" then return end

    local t = smNow()
    local i, slave, slaveKey, nextAt
    for i = 1, table.getn(list) do
        slave = list[i]
        slaveKey = smKey(slave)
        if not smFindPartyMember(slaveKey) then
            nextAt = tonumber(S.masterInviteAt[slaveKey]) or 0
            if t >= nextAt then
                S.masterInviteAt[slaveKey] = t + INVITE_COOLDOWN
                S.lastMasterRepairTarget = slave
                InviteByName(slave)
                smDebug("master repair invite -> " .. tostring(slave))
            end
        end
    end
end

local function smWatchdog()
    local playerKey = smKey(smPlayerName())
    local master = SLAVE_TO_MASTER[playerKey]

    if master then
        local masterKey = smKey(master)
        S.lastRole = "slave"
        S.lastOwner = master

        -- Never tear down or replace an existing group. Only create the pair
        -- when this slave is genuinely ungrouped.
        if not smGrouped() then
            smInviteAssignedMaster(master)
            return
        end

        -- Promotion is party-only. Existing raids are left untouched.
        if smRaidCount() <= 0 then
            smPromoteAssignedMaster(masterKey)
        end
        return
    end

    if MASTER_TO_SLAVES[playerKey] then
        S.lastRole = "master"
        S.lastOwner = ""
        smMasterRepairMissingSlaves(playerKey)
    else
        S.lastRole = "inactive"
        S.lastOwner = ""
    end
end

local M = {}

function M.Init()
    S.nextWatchAt = 0
    S.nextInviteAt = 0
    S.nextPromoteAt = 0
    S.nextAcceptAt = 0
    if type(H.RegisterEvent) == "function" then
        H.RegisterEvent("PARTY_INVITE_REQUEST")
        H.RegisterEvent("PARTY_MEMBERS_CHANGED")
        H.RegisterEvent("RAID_ROSTER_UPDATE")
    end
    smWatchdog()
end

function M.OnEvent(eventName, a1)
    if eventName == "PARTY_INVITE_REQUEST" then
        smAcceptTrusted(a1)
        return
    end

    if eventName == "PARTY_MEMBERS_CHANGED" or eventName == "RAID_ROSTER_UPDATE" then
        S.nextWatchAt = 0
    end
end

function M.OnUpdate()
    local t = smNow()
    if t < (S.nextWatchAt or 0) then return end
    S.nextWatchAt = t + WATCH_INTERVAL
    smWatchdog()
end

function M.Shutdown()
    -- State persists in HotHost; no global API is wrapped here.
end

H.Register("slavemasterpairs", M, VERSION)

W112_SUMMONSCOUT_SLAVE_MASTER_PAIRS_VERSION = VERSION
W112_SUMMONSCOUT_SLAVE_MASTER_PAIRS_ACTIVE = {
    Silione = "Kalisum",
    Silitwo = "Kalisum",
    Hyjaluno = "Bolthyjal",
    Hyjalonee = "Bolthyjal",
    Hydratwo = "Feltaxi",
    Hydraone = "Feltaxi",
    Winterone = "Taxiwinter",
    Wintertwoo = "Taxiwinter",
}
