-- Tiny slash-command compatibility shim. It shares the single TELE10 ledger
-- storage/API and only disambiguates `partial` as query vs `partial on|off`.
local Q = CreateFrame("Frame", "SummonScoutTradePaymentLedgerQueryFrame")
Q:RegisterEvent("PLAYER_LOGIN")
Q:SetScript("OnEvent", function()
    local base = SlashCmdList and SlashCmdList["TELE10LEDGER"] or nil
    local api = W112_TELE10_LEDGER_V1
    if type(base) ~= "function" or type(api) ~= "table" or type(api.ShowSummons) ~= "function" then return end
    SlashCmdList["TELE10LEDGER"] = function(msg)
        msg = tostring(msg or "")
        msg = string.gsub(msg, "^%s+", "")
        msg = string.gsub(msg, "%s+$", "")
        local _, _, cmd, rest = string.find(msg, "^(%S*)%s*(.-)$")
        cmd = string.lower(cmd or "")
        rest = string.lower(rest or "")
        if cmd == "partial" and rest ~= "on" and rest ~= "off" then
            api.ShowSummons("partial", tonumber(rest) or 10, nil)
            return
        end
        base(msg)
    end
end)
