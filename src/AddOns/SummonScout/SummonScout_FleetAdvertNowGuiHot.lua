-- Fleet Advert NOW GUI hotfix for SummonScout / WoW 1.12.1 Lua 5.0.
-- Adds one manual test control to the existing Control Center without touching
-- the legacy Periodic World advert scheduler.

local A = W112_SUMMONSCOUT_FLEET_ADVERT
if type(A) ~= "table" then return end

local function faTrim(v)
    local s = tostring(v or "")
    s = string.gsub(s, "^%s+", "")
    s = string.gsub(s, "%s+$", "")
    return s
end

local function faChat(text)
    if DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage("|cff55ddffSummon fleet advert:|r " .. tostring(text or ""))
    end
end

function A.forceNow()
    if type(A.enabled) ~= "function" or not A.enabled() then
        return false, "fleet advert disabled or master is not configured"
    end
    if type(A.master) ~= "function" or type(A.validName) ~= "function" then
        return false, "coordinator API unavailable"
    end

    local master = faTrim(A.master())
    if not A.validName(master) then
        return false, "set a valid Master first"
    end
    if type(A.isMaster) ~= "function" or not A.isMaster() then
        return false, "use this button on master " .. master
    end
    if A.pendingGrant then
        return false, "previous fleet advert grant is still pending"
    end
    if type(A.destinationCsv) ~= "function" or A.destinationCsv() == "" then
        return false, "no live summon destinations yet; wait for heartbeats"
    end
    if type(A.providers) ~= "function" or table.getn(A.providers()) == 0 then
        return false, "no live fleet speakers yet"
    end
    if type(A.grant) ~= "function" then
        return false, "coordinator grant API unavailable"
    end

    -- One explicit manual trigger. A.grant() keeps the existing speaker rotation,
    -- live-destination union and no-auto-retry semantics.
    A.grant()
    return true, "triggered one fleet advert cycle"
end

local created = false
local nextProbe = 0

local function createButton()
    if created then return true end
    local host = getglobal and getglobal("SummonScoutOptionsFrame") or SummonScoutOptionsFrame
    if not host then return false end

    local b = CreateFrame("Button", "SummonScoutFleetAdvertNowButton", host, "UIPanelButtonTemplate")
    b:SetWidth(150)
    b:SetHeight(24)
    b:SetPoint("BOTTOMRIGHT", host, "BOTTOMRIGHT", -18, 18)
    b:SetText("Fleet Advert NOW")
    b:SetScript("OnClick", function()
        local ok, detail = A.forceNow()
        if ok then
            faChat("NOW -> " .. tostring(detail or "triggered"))
        else
            faChat("NOW blocked -> " .. tostring(detail or "unknown reason"))
        end
    end)
    b:Show()
    created = true
    return true
end

local frame = CreateFrame and CreateFrame("Frame") or nil
if frame then
    frame:SetScript("OnUpdate", function()
        if created then return end
        local t = GetTime and GetTime() or 0
        if t < nextProbe then return end
        nextProbe = t + 0.5
        createButton()
    end)
end

W112_SUMMONSCOUT_FLEET_ADVERT_NOW_GUI_VERSION = "1"
