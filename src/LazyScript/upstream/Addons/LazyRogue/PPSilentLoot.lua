-- WoW 1.12.1 build 5875. Presentation-only: native AutoLootPP owns the loot transaction.
-- Do NOT hide LootFrame: its stock OnHide invokes CloseLoot() before the native drain.
-- Alpha=0 keeps the frame logically open so native LootSlot/LootAll may finish.
local _, class = UnitClass("player")
if class == "ROGUE" and LootFrame then
    if W112PPSilentLootEnabled == nil then
        W112PPSilentLootEnabled = true
    end

    local oldOnShow = LootFrame:GetScript("OnShow")
    local oldOnHide = LootFrame:GetScript("OnHide")

    LootFrame:SetScript("OnShow", function()
        if oldOnShow then oldOnShow() end
        if W112PPSilentLootEnabled then
            LootFrame:SetAlpha(0)
        else
            LootFrame:SetAlpha(1)
        end
    end)

    LootFrame:SetScript("OnHide", function()
        if oldOnHide then oldOnHide() end
        -- Restore visibility for the next normal/manual loot window.
        LootFrame:SetAlpha(1)
    end)

    SLASH_W112PPSILENTLOOT1 = "/ppsilentloot"
    SlashCmdList["W112PPSILENTLOOT"] = function(msg)
        msg = string.lower(msg or "")
        if msg == "off" then
            W112PPSilentLootEnabled = false
        elseif msg == "on" then
            W112PPSilentLootEnabled = true
        else
            DEFAULT_CHAT_FRAME:AddMessage("[PP] /ppsilentloot on | off")
            return
        end
        if LootFrame:IsShown() then
            LootFrame:SetAlpha(W112PPSilentLootEnabled and 0 or 1)
        end
        DEFAULT_CHAT_FRAME:AddMessage(W112PPSilentLootEnabled
            and "[PP] Silent loot ON (all rogue loot windows)."
            or "[PP] Silent loot OFF (normal loot window).")
    end
end
