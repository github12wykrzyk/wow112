-- AuxVmangos DE absolute profit floor policy.
-- Migrate only the historical 10s default; preserve intentional custom values.

local AVM_DE_OLD_DEFAULT = 1000
local AVM_DE_NEW_DEFAULT = 5000
local avm_de_profit_floor_wrapped = false
local avm_de_profit_floor_original_slash = nil

local function avm_de_profit_floor_migrate()
	if not AVM_DB then return end
	local current = tonumber(AVM_DB.deMinProfit)
	if current == nil or current == AVM_DE_OLD_DEFAULT then
		AVM_DB.deMinProfit = AVM_DE_NEW_DEFAULT
	end
end

local function avm_de_profit_floor_install_reset_guard()
	if avm_de_profit_floor_wrapped or not SlashCmdList then return end
	local handler = SlashCmdList["AUXVMANGOS"]
	if type(handler) ~= "function" then return end
	avm_de_profit_floor_original_slash = handler
	SlashCmdList["AUXVMANGOS"] = function(msg)
		avm_de_profit_floor_original_slash(msg)
		local text = string.lower(tostring(msg or ""))
		local _,_,sub = string.find(text, "^%s*(%S+)")
		if sub == "reset" and AVM_DB then
			AVM_DB.deMinProfit = AVM_DE_NEW_DEFAULT
		end
	end
	avm_de_profit_floor_wrapped = true
end

local avm_de_profit_floor_frame = CreateFrame("Frame")
avm_de_profit_floor_frame:RegisterEvent("ADDON_LOADED")
avm_de_profit_floor_frame:RegisterEvent("PLAYER_LOGIN")
avm_de_profit_floor_frame:SetScript("OnEvent", function()
	if event == "ADDON_LOADED" and arg1 == "AuxVmangos" then
		avm_de_profit_floor_migrate()
		avm_de_profit_floor_install_reset_guard()
	elseif event == "PLAYER_LOGIN" then
		avm_de_profit_floor_migrate()
		avm_de_profit_floor_install_reset_guard()
	end
end)
