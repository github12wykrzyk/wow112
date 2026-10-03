-- AuxFastBridge v3.9 TURBO routing hotfix.
-- When TURBO is enabled, force original AUX Search to use the normal full-search
-- path instead of Real Time. Real Time scans only the newest page and does not
-- expose the callbacks that AuxFastBridge uses for headless rendering and AVM.
local okSearchTab, searchTab = pcall(require, "aux.tabs.search")
if not okSearchTab or not searchTab or not searchTab.execute then return end

AUXFAST_RUNTIME = AUXFAST_RUNTIME or {}
if AUXFAST_RUNTIME.turboSearchRoutingInstalled then return end

module "aux.tabs.search"

local originalExecute = M.execute
if not originalExecute then return end

M.execute = function(resume, real_time)
	if AUXFAST_TurboEnabled and AUXFAST_TurboEnabled() then
		local search = current_search and current_search()
		if search then search.real_time = false end
		if update_real_time then update_real_time(false) end
		real_time = false
		AuxFastBridgeDB.turboForcedFullSearches = (tonumber(AuxFastBridgeDB.turboForcedFullSearches) or 0) + 1
		AuxFastBridgeDB.lastTurboRouting = "full-search"
	end
	return originalExecute(resume, real_time)
end

AUXFAST_RUNTIME.turboSearchRoutingInstalled = true
