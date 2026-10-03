-- AuxFastBridge v3.10 TURBO isolation fix.
-- Restore the v3.7 Manual Headless / AVM resume semantics and keep TURBO as a
-- separate, optional routing override. TURBO OFF must not alter the legacy path.

local okSearchTab, searchTab = pcall(require, "aux.tabs.search")
if not okSearchTab or not searchTab or not searchTab.execute then return end

AuxFastBridgeDB = AuxFastBridgeDB or {}
AUXFAST_RUNTIME = AUXFAST_RUNTIME or {}
if AUXFAST_RUNTIME.turboIsolationInstalled then return end

-- v3.8 mirrored manualHeadless <-> turbo, destroying the independent legacy
-- preference. The original v3.7 default was ON, so restore that default once
-- when separating the states again. Subsequent user changes persist normally.
if not AuxFastBridgeDB.turboIsolationMigrated then
	AuxFastBridgeDB.manualHeadless = true
	if AuxFastBridgeDB.turbo == nil then AuxFastBridgeDB.turbo = false end
	AuxFastBridgeDB.turboIsolationMigrated = true
end
if AuxFastBridgeDB.manualHeadless == nil then AuxFastBridgeDB.manualHeadless = true end
if AuxFastBridgeDB.turbo == nil then AuxFastBridgeDB.turbo = false end

local baseBeginScan = AUXFAST_BeginScan
local baseResumeSearch = AUXFAST_ResumeSearch
local baseRestartSearch = AUXFAST_RestartSearch
local baseStatus = AUXFAST_Status

local function iso_out(msg)
	if DEFAULT_CHAT_FRAME then
		DEFAULT_CHAT_FRAME:AddMessage("|cff66ff99[AUX FAST]|r " .. tostring(msg))
	end
end

-- Context flags let the unchanged v3.8 implementation reuse its local
-- headlessState while exposing the old v3.7 behavior externally.
function AUXFAST_TurboEnabled()
	if AUXFAST_RUNTIME.legacyForceHeadless or AUXFAST_RUNTIME.legacyManualHeadlessBridge then
		return true
	end
	return AuxFastBridgeDB.turbo and true or false
end

function AUXFAST_ManualHeadlessEnabled()
	return AuxFastBridgeDB.manualHeadless and true or false
end

function AUXFAST_UpdateManualHeadlessButton()
	local button = AUXFAST_RUNTIME and AUXFAST_RUNTIME.manualHeadlessButton
	if not button or not button.SetText then return end
	button:SetText(AUXFAST_ManualHeadlessEnabled() and "Manual Headless: ON" or "Manual Headless: OFF")
end

function AUXFAST_SetManualHeadless(enabled)
	AuxFastBridgeDB.manualHeadless = enabled and true or false
	AUXFAST_UpdateManualHeadlessButton()
	iso_out("manual headless=" .. tostring(AUXFAST_ManualHeadlessEnabled()) ..
		" (legacy v3.7 path; independent from TURBO)")
	return AUXFAST_ManualHeadlessEnabled()
end

-- TURBO controls only its own flag. It no longer rewrites manualHeadless and it
-- no longer clears a legacy AVM resume/restart arm when switched OFF.
function AUXFAST_SetTurbo(enabled)
	AuxFastBridgeDB.turbo = enabled and true or false
	if AUXFAST_UpdateTurboGui then AUXFAST_UpdateTurboGui() end
	iso_out("turbo=" .. tostring(AuxFastBridgeDB.turbo and true or false) ..
		" (separate override; OFF preserves legacy routing)")
	return AuxFastBridgeDB.turbo and true or false
end

-- Preserve the original manual full-Search behavior when TURBO is OFF. We only
-- borrow the existing v3.8 headless implementation for this single call; the
-- persisted TURBO state is never changed.
if baseBeginScan then
	AUXFAST_BeginScan = function(fullSearchScan, isResume)
		local legacyManual = fullSearchScan and not (AuxFastBridgeDB.turbo and true or false) and
			AUXFAST_ManualHeadlessEnabled()
		AUXFAST_RUNTIME.legacyManualHeadlessBridge = legacyManual and true or false
		local headless, source, scanId = baseBeginScan(fullSearchScan, isResume)
		AUXFAST_RUNTIME.legacyManualHeadlessBridge = false
		if legacyManual and source == "turbo-gui" then source = "manual-gui" end
		return headless, source, scanId
	end
end

-- v3.7 invariant: AVM continuation/restart is always armed headless, regardless
-- of the manual toggle. Keep the context flag active through execute(true), so
-- the v3.9 routing shim also keeps an AVM full-Search continuation on full Search.
if baseResumeSearch then
	AUXFAST_ResumeSearch = function()
		AUXFAST_RUNTIME.legacyForceHeadless = true
		local ok, detail = baseResumeSearch()
		AUXFAST_RUNTIME.legacyForceHeadless = false
		return ok, detail
	end
end

if baseRestartSearch then
	AUXFAST_RestartSearch = function()
		AUXFAST_RUNTIME.legacyForceHeadless = true
		local ok = baseRestartSearch()
		AUXFAST_RUNTIME.legacyForceHeadless = false
		return ok
	end
end

if baseStatus then
	AUXFAST_Status = function()
		local s = baseStatus() or {}
		s.turbo = AuxFastBridgeDB.turbo and true or false
		s.manualHeadless = AUXFAST_ManualHeadlessEnabled()
		s.turboIsolation = true
		return s
	end
end

local function install_isolated_gui()
	local env = getfenv(searchTab.execute)
	if not env or not env.frame then return false end

	-- Keep the legacy Manual Headless button in its original bottom-right slot.
	local manual = AUXFAST_RUNTIME.manualHeadlessButton
	if not manual or manual == AUXFAST_RUNTIME.turboButton then
		manual = CreateFrame("Button", "AuxFastManualHeadlessButton", env.frame, "GameMenuButtonTemplate")
		manual:SetWidth(145)
		manual:SetHeight(22)
		manual:SetPoint("BOTTOMRIGHT", env.frame, "BOTTOMRIGHT", -8, 6)
		manual:SetScript("OnClick", function()
			AUXFAST_SetManualHeadless(not AUXFAST_ManualHeadlessEnabled())
		end)
		AUXFAST_RUNTIME.manualHeadlessButton = manual
	end

	-- TURBO is a second button, not a replacement for the legacy control.
	local turbo = AUXFAST_RUNTIME.turboButton
	if turbo then
		if turbo.ClearAllPoints then turbo:ClearAllPoints() end
		turbo:SetPoint("BOTTOMRIGHT", manual, "BOTTOMLEFT", -8, 0)
	end
	AUXFAST_UpdateManualHeadlessButton()
	if AUXFAST_UpdateTurboGui then AUXFAST_UpdateTurboGui() end
	return true
end

function AUXFAST_InstallManualHeadlessGui()
	return install_isolated_gui()
end

install_isolated_gui()
AUXFAST_RUNTIME.turboIsolationInstalled = true
iso_out("v3.10 loaded: legacy Manual Headless/AVM routing restored; TURBO isolated")
