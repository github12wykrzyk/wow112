-- AuxVmangos AutoSell AH-session compatibility for WoW 1.12.1 / AUX.
-- AUX can keep its own AH UI usable while Blizzard AuctionFrame:IsVisible()
-- reports false. AVM.open is driven by AUCTION_HOUSE_SHOW/CLOSED and is the
-- authoritative session state. Scope the visibility compatibility strictly to
-- AutoSell work so other AUX/Blizzard tabs keep the original frame semantics.

local aux = require 'aux'

AVM_AUTOSELL_AH_SESSION = AVM_AUTOSELL_AH_SESSION or {}
local C = AVM_AUTOSELL_AH_SESSION
C.installed = C.installed and true or false
C.originalIsVisible = C.originalIsVisible or nil

local function autosell_needs_session_visibility()
    if not (AVM and AVM.open) then return false end

    if aux.get_tab then
        local tab = aux.get_tab()
        if tab and tostring(tab.name or '') == 'AutoSell' then return true end
    end

    if AVM_AUTOSELL and AVM_AUTOSELL.Status then
        local ok, st = pcall(AVM_AUTOSELL.Status)
        if ok and st then
            if st.manualActive then return true end
            if st.ownerRefreshRequested then return true end
        end
    end
    return false
end

local function install()
    if C.installed then return true end
    if not AuctionFrame or type(AuctionFrame.IsVisible) ~= 'function' then return false end

    C.originalIsVisible = AuctionFrame.IsVisible
    AuctionFrame.IsVisible = function(self)
        if autosell_needs_session_visibility() then return true end
        return C.originalIsVisible(self)
    end
    C.installed = true
    return true
end

local events = CreateFrame('Frame', 'AuxVmangosAutoSellAHSessionEvents')
events:RegisterEvent('PLAYER_LOGIN')
events:RegisterEvent('ADDON_LOADED')
events:RegisterEvent('AUCTION_HOUSE_SHOW')
events:SetScript('OnEvent', function() install() end)

install()
