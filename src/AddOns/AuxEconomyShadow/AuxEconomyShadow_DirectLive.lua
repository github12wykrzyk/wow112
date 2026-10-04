-- User-authorized direct-live routing after the shadow parity/evidence path proved
-- unreliable as a delivery gate. AuxVmangos remains the authoritative economy
-- executor; AuxEconomyShadow stays loaded for observation and future comparison.

local REVISION = "2-loop-restart-selfheal"

if type(AVM_DB) ~= "table" then AVM_DB = {} end
AVM_DB.shadowCutoverWanted = false

local setterApplied = false
if type(W112_AH_SHADOW_CUTOVER_SET) == "function" then
    local okSet, value = pcall(W112_AH_SHADOW_CUTOVER_SET, false)
    setterApplied = okSet and value == false
end

-- ECONOMY hot updates can reach a client whose in-memory AuxVmangos expects
-- AUXFAST_RestartSearch while the older already-loaded AuxFastBridge only exposes
-- AUXFAST_ResumeSearch (or the lower-level bridge primitives). Repair only that
-- compatibility surface. Never send queries directly and never touch live flags.
local restartCompat = "native"
if type(AUXFAST_RestartSearch) ~= "function" then
    if type(AUXFAST_ResumeSearch) == "function" then
        local legacyResume = AUXFAST_ResumeSearch
        AUXFAST_RestartSearch = function()
            local okResume, started = pcall(legacyResume)
            if not okResume then return false end
            return started and true or false
        end
        restartCompat = "legacy-resume"
    elseif type(AUXFAST_ArmHeadless) == "function" and
           type(AUXFAST_SearchBusy) == "function" and
           type(AUXFAST_BeginScan) == "function" then
        AUXFAST_RestartSearch = function()
            if AVM and AVM.hardStop then return false end

            local okBusy, busy = pcall(AUXFAST_SearchBusy)
            if okBusy and (tonumber(busy) or 0) > 0 then return false end

            local okSearch, searchTab = pcall(require, "aux.tabs.search")
            if not okSearch or not searchTab or type(searchTab.execute) ~= "function" then
                return false
            end

            -- Older bridge builds can hit SetText(nil) on the first automated
            -- restart. Normalize the current Search filter through the module
            -- environment before calling the real upstream execute path.
            local env = getfenv and getfenv(searchTab.execute) or nil
            if env and type(env.current_search) == "function" then
                local okCurrent, search = pcall(env.current_search)
                if okCurrent and search and type(search.filter_string) ~= "string" then
                    local filter = ""
                    if env.search_box and type(env.search_box.GetText) == "function" then
                        local okText, value = pcall(env.search_box.GetText, env.search_box)
                        if okText and value ~= nil then filter = tostring(value) end
                    end
                    search.filter_string = filter
                end
            end

            pcall(AUXFAST_ArmHeadless, "restart-hot-selfheal")
            local okExec = pcall(searchTab.execute, true)
            if not okExec then return false end

            local okAfter, after = pcall(AUXFAST_SearchBusy)
            if not okAfter then return true end
            return (tonumber(after) or 0) > 0
        end
        restartCompat = "bridge-primitives"
    else
        restartCompat = "bridge-missing"
    end
end

AVM_DB.marketMeta = type(AVM_DB.marketMeta) == "table" and AVM_DB.marketMeta or {}
AVM_DB.marketMeta.shadowAuthority = {
    revision = REVISION,
    authoritative = "AuxVmangos",
    shadowRole = "observer-only",
    cutoverWanted = false,
    setterApplied = setterApplied,
    restartCompat = restartCompat,
    restartAvailable = type(AUXFAST_RestartSearch) == "function",
    reason = "user-authorized-direct-live",
}

AVM_SHADOW_DB = type(AVM_SHADOW_DB) == "table" and AVM_SHADOW_DB or {}
AVM_SHADOW_DB.authority = {
    revision = REVISION,
    authoritative = "AuxVmangos",
    shadowRole = "observer-only",
    cutoverWanted = false,
    restartCompat = restartCompat,
    restartAvailable = type(AUXFAST_RestartSearch) == "function",
    reason = "user-authorized-direct-live",
}
