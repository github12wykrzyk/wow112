-- Production transport safety shim for AuxFastBridge.
-- The production AH companion is intentionally inert (no packet/send/receive hooks),
-- so the v3.7 native-response correlation path must not own AUX list completion.
-- Capture the upstream aux.core.scan wait function before AuxFastBridge.lua patches
-- it, then restore that exact function after this addon finishes loading.

local okScan, scan = pcall(require, "aux.core.scan")
if not okScan or not scan or not scan.start then return end

local scanEnv = getfenv(scan.start)
if not scanEnv or type(scanEnv.wait_for_list_results) ~= "function" then return end

local stockWaitForListResults = scanEnv.wait_for_list_results

AUXFAST_RUNTIME = AUXFAST_RUNTIME or {}
AUXFAST_RUNTIME.productionStockWait = true
AUXFAST_RUNTIME.productionStockWaitInstalled = false

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:SetScript("OnEvent", function()
	if arg1 ~= "AuxFastBridge" then return end
	frame:UnregisterEvent("ADDON_LOADED")
	if scanEnv and stockWaitForListResults then
		scanEnv.wait_for_list_results = stockWaitForListResults
		AUXFAST_RUNTIME.productionStockWaitInstalled = true
		if DEFAULT_CHAT_FRAME then
			DEFAULT_CHAT_FRAME:AddMessage("|cff66ff99[AUX FAST]|r production transport=stock AUX wait")
		end
	end
end)
