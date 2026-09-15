-- !AutoJunkLock v3
-- WoW 1.12 / Lua 5.0
--
-- Critical safety rule:
-- NEVER call UseContainerItem on a locked junkbox unless Pick Lock has
-- successfully entered spell-targeting mode first.

local GNumSlots   = GetContainerNumSlots
local GItemInfo   = GetContainerItemInfo
local GItemLink   = GetContainerItemLink
local UseItem     = UseContainerItem
local NumSkills   = GetNumSkillLines
local SkillInfo   = GetSkillLineInfo
local NumLoot     = GetNumLootItems
local Loot        = LootSlot

local PICKLOCK_NAME = "Pick Lock"
local LOCKSKILL_NAME = "Lockpicking"

local BOX = {
    [16882] = 1,    -- Battered Junkbox
    [16883] = 70,   -- Worn Junkbox
    [16884] = 175,  -- Sturdy Junkbox
    [16885] = 250,  -- Heavy Junkbox
}

local S = {
    ready = nil,
    combat = nil,
    nextScan = 0,
    busyUntil = 0,
    lootUntil = 0,
    pickSpellSlot = nil,
    pickPending = nil,
    pickItemID = nil,
    pickTimeout = 0,
}

local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffAJL:|r " .. msg)
end

local function Debug(msg)
    if AJL_Config and AJL_Config.debug then
        Print("|cffaaaaaa" .. msg .. "|r")
    end
end

local function ItemID(link)
    local _, _, id
    if not link then return nil end
    _, _, id = string.find(link, "item:(%d+):")
    if id then return tonumber(id) end
    return nil
end

local function FindPickLockSpell()
    local i, name
    for i = 1, 300 do
        name = GetSpellName(i, BOOKTYPE_SPELL)
        if not name then break end
        if name == PICKLOCK_NAME then
            return i
        end
    end
    return nil
end

local function LockSkill()
    local i, name, rank
    if not NumSkills or not SkillInfo then return nil end

    for i = 1, NumSkills() do
        name, _, _, rank = SkillInfo(i)
        if name == LOCKSKILL_NAME then
            return rank
        end
    end
    return nil
end

local Tip = CreateFrame("GameTooltip", "AJLHiddenTooltip", UIParent, "GameTooltipTemplate")
Tip:SetOwner(UIParent, "ANCHOR_NONE")
Tip:Hide()

local function Clean(s)
    if not s then return nil end
    s = string.gsub(s, "^%s+", "")
    s = string.gsub(s, "%s+$", "")
    return s
end

-- 1 = locked, 0 = unlocked, nil = unknown.
-- UNKNOWN is deliberately non-actionable.
local function LockState(bag, slot)
    local link, lines, i, l, r, text
    local sawName = nil

    link = GItemLink(bag, slot)
    if not link then return nil end

    Tip:ClearLines()
    Tip:SetOwner(UIParent, "ANCHOR_NONE")
    Tip:SetBagItem(bag, slot)

    lines = Tip:NumLines()
    if not lines or lines < 1 then
        Tip:Hide()
        return nil
    end

    for i = 1, lines do
        l = getglobal("AJLHiddenTooltipTextLeft" .. i)
        r = getglobal("AJLHiddenTooltipTextRight" .. i)

        if l then
            text = Clean(l:GetText())
            if text and text ~= "" then
                sawName = 1
                if text == "Locked" or (LOCKED and text == LOCKED) then
                    Tip:Hide()
                    return 1
                end
            end
        end

        if r then
            text = Clean(r:GetText())
            if text and (text == "Locked" or (LOCKED and text == LOCKED)) then
                Tip:Hide()
                return 1
            end
        end
    end

    Tip:Hide()

    if sawName then
        return 0
    end

    return nil
end

local function BagSize(bag)
    local n = GNumSlots(bag)
    if bag == 0 and (not n or n == 0) then n = 16 end
    return n or 0
end

local function SlotReady(bag, slot, itemID)
    local link, id, _, _, slotLocked

    link = GItemLink(bag, slot)
    if not link then return nil end

    id = ItemID(link)
    if id ~= itemID then return nil end

    _, _, slotLocked = GItemInfo(bag, slot)
    if slotLocked then return nil end

    return 1
end

local function BlockingUI()
    if MerchantFrame and MerchantFrame:IsVisible() then return 1 end
    if TradeFrame and TradeFrame:IsVisible() then return 1 end
    if AuctionFrame and AuctionFrame:IsVisible() then return 1 end
    if MailFrame and MailFrame:IsVisible() then return 1 end
    if BankFrame and BankFrame:IsVisible() then return 1 end

    if LootFrame and LootFrame:IsVisible() and GetTime() > S.lootUntil then
        return 1
    end

    return nil
end

local function Busy()
    if S.combat then return 1 end
    if UnitHealth("player") <= 0 then return 1 end
    if CursorHasItem and CursorHasItem() then return 1 end
    if SpellIsTargeting and SpellIsTargeting() then return 1 end
    if CastingBarFrame and CastingBarFrame:IsVisible() then return 1 end
    if GetTime() < S.busyUntil then return 1 end
    if BlockingUI() then return 1 end
    return nil
end

-- Returns first verified unlocked box, otherwise first verified locked box.
local function FindBox()
    local bag, slot, n, link, id, state, _, _, slotLocked
    local lb, ls, lid
    local skill = LockSkill()
    local req
    local transient = nil

    for bag = 0, 4 do
        n = BagSize(bag)

        for slot = 1, n do
            link = GItemLink(bag, slot)
            id = ItemID(link)

            if id and BOX[id] then
                _, _, slotLocked = GItemInfo(bag, slot)

                if slotLocked then
                    transient = 1
                else
                    state = LockState(bag, slot)

                    if state == 0 then
                        return "OPEN", bag, slot, id, transient
                    elseif state == 1 then
                        req = BOX[id]
                        if ((not skill) or skill >= req) and not lb then
                            lb, ls, lid = bag, slot, id
                        end
                    else
                        transient = 1
                    end
                end
            end
        end
    end

    if lb then
        return "PICK", lb, ls, lid, transient
    end

    return nil, nil, nil, nil, transient
end

local function OpenBox(bag, slot, itemID)
    if not SlotReady(bag, slot, itemID) then
        Debug("OPEN cancelled: item moved/busy")
        S.nextScan = GetTime() + 0.05
        return
    end

    if LockState(bag, slot) ~= 0 then
        Debug("OPEN cancelled: not positively unlocked")
        S.nextScan = GetTime() + 0.05
        return
    end

    Debug("OPEN item=" .. itemID .. " bag=" .. bag .. " slot=" .. slot)
    UseItem(bag, slot)
    S.lootUntil = GetTime() + 2.5
    S.nextScan = GetTime() + 0.30
end

local function PickBox(bag, slot, itemID)
    if not S.pickSpellSlot then
        S.pickSpellSlot = FindPickLockSpell()
        if not S.pickSpellSlot then
            Debug("Pick Lock not found in spellbook")
            S.nextScan = GetTime() + 2.0
            return
        end
    end

    if not SlotReady(bag, slot, itemID) then
        Debug("PICK cancelled: item moved/busy")
        S.nextScan = GetTime() + 0.05
        return
    end

    if LockState(bag, slot) ~= 1 then
        Debug("PICK cancelled: not positively locked")
        S.nextScan = GetTime() + 0.05
        return
    end

    -- Use spellbook slot instead of blindly casting by name.
    CastSpell(S.pickSpellSlot, BOOKTYPE_SPELL)

    -- THIS IS THE IMPORTANT FIX:
    -- if Pick Lock did not actually enter targeting mode, do not touch the box.
    if not SpellIsTargeting or not SpellIsTargeting() then
        Debug("PICK aborted: Pick Lock did not enter targeting mode")
        S.nextScan = GetTime() + 0.50
        return
    end

    -- Sorter may have moved it between CastSpell and this line.
    if not SlotReady(bag, slot, itemID) then
        Debug("PICK target cancelled: item moved after spell cast")
        if SpellStopTargeting then SpellStopTargeting() end
        S.nextScan = GetTime() + 0.05
        return
    end

    -- Reconfirm it is still locked before feeding it to Pick Lock.
    if LockState(bag, slot) ~= 1 then
        Debug("PICK target cancelled: lock state changed")
        if SpellStopTargeting then SpellStopTargeting() end
        S.nextScan = GetTime() + 0.05
        return
    end

    Debug("PICK target item=" .. itemID .. " bag=" .. bag .. " slot=" .. slot)

    S.pickPending = 1
    S.pickItemID = itemID
    S.pickTimeout = GetTime() + 8.0

    UseItem(bag, slot)

    -- If the target was rejected, clear it instead of accidentally applying
    -- Pick Lock to some later click.
    if SpellIsTargeting and SpellIsTargeting() then
        Debug("PICK target rejected; targeting cancelled")
        if SpellStopTargeting then SpellStopTargeting() end
        S.pickPending = nil
        S.pickItemID = nil
        S.nextScan = GetTime() + 0.30
        return
    end

    S.nextScan = GetTime() + 0.75
end

local function LootSweep()
    local i, n

    if not AJL_Config or not AJL_Config.autoLoot then return end
    if GetTime() > S.lootUntil then return end
    if not LootFrame or not LootFrame:IsVisible() then return end

    n = NumLoot()
    if not n or n < 1 then return end

    for i = n, 1, -1 do
        Loot(i)
    end
end

local function Scan()
    local action, bag, slot, itemID, transient

    if not AJL_Config or not AJL_Config.enabled then
        S.nextScan = GetTime() + 1.0
        return
    end

    if Busy() then
        S.nextScan = GetTime() + 0.10
        return
    end

    action, bag, slot, itemID, transient = FindBox()

    if action == "PICK" then
        PickBox(bag, slot, itemID)
        return
    elseif action == "OPEN" then
        OpenBox(bag, slot, itemID)
        return
    end

    if transient then
        S.nextScan = GetTime() + 0.10
    else
        S.nextScan = GetTime() + 0.50
    end
end

local function Quick(delay)
    local t = GetTime() + (delay or 0.05)
    if S.nextScan == 0 or t < S.nextScan then
        S.nextScan = t
    end
end

local function InitConfig()
    if not AJL_Config then AJL_Config = {} end
    if AJL_Config.enabled == nil then AJL_Config.enabled = 1 end
    if AJL_Config.autoLoot == nil then AJL_Config.autoLoot = 1 end
end

local function DebugScan()
    local bag, slot, n, link, id, state, _, _, slotLocked
    local txt, count
    count = 0

    for bag = 0, 4 do
        n = BagSize(bag)
        for slot = 1, n do
            link = GItemLink(bag, slot)
            id = ItemID(link)

            if id and BOX[id] then
                _, _, slotLocked = GItemInfo(bag, slot)
                state = LockState(bag, slot)

                if state == 1 then txt = "LOCKED"
                elseif state == 0 then txt = "UNLOCKED"
                else txt = "UNKNOWN" end

                Print("item=" .. id ..
                      " bag=" .. bag ..
                      " slot=" .. slot ..
                      " busy=" .. (slotLocked and "YES" or "NO") ..
                      " state=" .. txt)
                count = count + 1
            end
        end
    end

    if count == 0 then Print("brak junkboxów") end
end

SLASH_AUTOJUNKLOCK1 = "/ajl"
SlashCmdList["AUTOJUNKLOCK"] = function(msg)
    local cmd = string.lower(msg or "")

    if cmd == "on" then
        AJL_Config.enabled = 1
        Print("ON")
        Quick(0.01)
    elseif cmd == "off" then
        AJL_Config.enabled = nil
        Print("OFF")
    elseif cmd == "debug" then
        if AJL_Config.debug then
            AJL_Config.debug = nil
            Print("debug OFF")
        else
            AJL_Config.debug = 1
            Print("debug ON")
        end
    elseif cmd == "scan" then
        DebugScan()
    elseif cmd == "loot on" then
        AJL_Config.autoLoot = 1
        Print("autoloot ON")
    elseif cmd == "loot off" then
        AJL_Config.autoLoot = nil
        Print("autoloot OFF")
    else
        Print("status=" .. (AJL_Config.enabled and "ON" or "OFF") ..
              " autoloot=" .. (AJL_Config.autoLoot and "ON" or "OFF") ..
              " debug=" .. (AJL_Config.debug and "ON" or "OFF") ..
              " spellSlot=" .. (S.pickSpellSlot or "?"))
        Print("/ajl on | off | debug | scan | loot on | loot off")
    end
end

local F = CreateFrame("Frame", "AutoJunkLockFrame")

F:RegisterEvent("VARIABLES_LOADED")
F:RegisterEvent("PLAYER_ENTERING_WORLD")
F:RegisterEvent("PLAYER_REGEN_DISABLED")
F:RegisterEvent("PLAYER_REGEN_ENABLED")
F:RegisterEvent("BAG_UPDATE")
F:RegisterEvent("ITEM_LOCK_CHANGED")
F:RegisterEvent("SPELLCAST_START")
F:RegisterEvent("SPELLCAST_STOP")
F:RegisterEvent("SPELLCAST_FAILED")
F:RegisterEvent("SPELLCAST_INTERRUPTED")
F:RegisterEvent("LOOT_OPENED")
F:RegisterEvent("LOOT_CLOSED")
F:RegisterEvent("SKILL_LINES_CHANGED")
F:RegisterEvent("UI_ERROR_MESSAGE")

F:SetScript("OnEvent", function()
    local now = GetTime()

    if event == "VARIABLES_LOADED" then
        InitConfig()
        S.pickSpellSlot = FindPickLockSpell()

        if UnitAffectingCombat then
            S.combat = UnitAffectingCombat("player")
        end

        S.ready = 1
        S.nextScan = now + 0.50
        Print("v3 loaded; /ajl status")

    elseif event == "PLAYER_ENTERING_WORLD" then
        Quick(0.50)

    elseif event == "PLAYER_REGEN_DISABLED" then
        S.combat = 1
        S.lootUntil = 0

    elseif event == "PLAYER_REGEN_ENABLED" then
        S.combat = nil
        Quick(0.20)

    elseif event == "BAG_UPDATE" or event == "ITEM_LOCK_CHANGED" then
        Quick(0.05)

    elseif event == "SKILL_LINES_CHANGED" then
        S.pickSpellSlot = FindPickLockSpell()
        Quick(0.20)

    elseif event == "SPELLCAST_START" then
        if arg2 and arg2 > 0 then
            S.busyUntil = now + (arg2 / 1000) + 0.15
        else
            S.busyUntil = now + 0.50
        end

    elseif event == "SPELLCAST_STOP" then
        S.busyUntil = now + 0.10

        if S.pickPending then
            Debug("Pick Lock finished for item=" .. (S.pickItemID or 0))
            S.pickPending = nil
            S.pickItemID = nil
        end

        Quick(0.15)

    elseif event == "SPELLCAST_FAILED" or event == "SPELLCAST_INTERRUPTED" then
        if S.pickPending then
            Debug("Pick Lock failed/interrupted")
            S.pickPending = nil
            S.pickItemID = nil
        end

        S.busyUntil = now + 0.30
        Quick(0.35)

    elseif event == "LOOT_OPENED" then
        if now <= S.lootUntil then LootSweep() end

    elseif event == "LOOT_CLOSED" then
        if now <= S.lootUntil then
            S.lootUntil = 0
            Quick(0.10)
        end

    elseif event == "UI_ERROR_MESSAGE" then
        if AJL_Config and AJL_Config.debug and S.pickPending then
            Debug("UI error: " .. (arg1 or "?"))
        end
    end
end)

F:SetScript("OnUpdate", function()
    local now = GetTime()

    if not S.ready then return end

    if S.lootUntil > 0 and now <= S.lootUntil then
        LootSweep()
    elseif S.lootUntil > 0 then
        S.lootUntil = 0
    end

    if S.pickPending and now > S.pickTimeout then
        Debug("Pick Lock timeout")
        S.pickPending = nil
        S.pickItemID = nil
    end

    if now >= S.nextScan then
        Scan()
    end
end)
