-- Fleet Advert NOW GUI hotfix v2 for SummonScout / WoW 1.12.1 Lua 5.0.
-- Persistent cold-load/reload-safe attach to the canonical Control Center.

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
    local master = faTrim(type(A.master) == "function" and A.master() or "")
    if type(A.validName) ~= "function" or not A.validName(master) then
        return false, "set a valid Master first"
    end
    if type(A.isMaster) ~= "function" or not A.isMaster() then
        return false, "use this button on master " .. master
    end
    if A.pendingGrant then
        return false, "previous fleet advert grant is still pending"
    end
    local csv = type(A.destinationCsv) == "function" and A.destinationCsv() or ""
    if csv == "" then
        return false, "no live summon destinations yet; wait for canonical router discovery"
    end
    local providers = type(A.providers) == "function" and A.providers() or {}
    if table.getn(providers) == 0 then
        return false, "no live fleet speakers yet"
    end
    if type(A.grant) ~= "function" then
        return false, "coordinator grant API unavailable"
    end
    A.grant()
    return true, "triggered one fleet advert cycle | " .. csv
end

local nextProbe = 0

local function attachButton()
    local host = getglobal and getglobal("SummonScoutOptionsFrame") or nil
    if not host then return false end

    local b = getglobal and getglobal("SummonScoutFleetAdvertNowButton") or nil
    if not b then
        b = CreateFrame("Button", "SummonScoutFleetAdvertNowButton", host, "UIPanelButtonTemplate")
        b:SetWidth(150)
        b:SetHeight(24)
        b:SetText("Fleet Advert NOW")
        b:SetScript("OnClick", function()
            local ok, detail = A.forceNow()
            if ok then faChat("NOW -> " .. tostring(detail or "triggered"))
            else faChat("NOW blocked -> " .. tostring(detail or "unknown reason")) end
        end)
    else
        if b.SetParent then b:SetParent(host) end
    end

    b:ClearAllPoints()
    b:SetPoint("BOTTOMRIGHT", host, "BOTTOMRIGHT", -18, 18)
    b:Show()
    return true
end

local frame = CreateFrame and CreateFrame("Frame", "SummonScoutFleetAdvertNowAttachFrame") or nil
if frame then
    frame:RegisterEvent("PLAYER_LOGIN")
    frame:SetScript("OnEvent", function() nextProbe = 0; attachButton() end)
    frame:SetScript("OnUpdate", function()
        local t = GetTime and GetTime() or 0
        if t < nextProbe then return end
        nextProbe = t + 0.50
        attachButton()
    end)
end

W112_SUMMONSCOUT_FLEET_ADVERT_NOW_GUI_VERSION = "2"
