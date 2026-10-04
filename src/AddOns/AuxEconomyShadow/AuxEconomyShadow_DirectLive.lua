-- User-authorized direct-live routing after the shadow parity/evidence path proved
-- unreliable as a delivery gate. AuxVmangos remains the authoritative economy
-- executor; AuxEconomyShadow stays loaded for observation and future comparison.

local REVISION = "1-active-auxvmangos"

if type(AVM_DB) ~= "table" then AVM_DB = {} end
AVM_DB.shadowCutoverWanted = false

local setterApplied = false
if type(W112_AH_SHADOW_CUTOVER_SET) == "function" then
    local okSet, value = pcall(W112_AH_SHADOW_CUTOVER_SET, false)
    setterApplied = okSet and value == false
end

AVM_DB.marketMeta = type(AVM_DB.marketMeta) == "table" and AVM_DB.marketMeta or {}
AVM_DB.marketMeta.shadowAuthority = {
    revision = REVISION,
    authoritative = "AuxVmangos",
    shadowRole = "observer-only",
    cutoverWanted = false,
    setterApplied = setterApplied,
    reason = "user-authorized-direct-live",
}

AVM_SHADOW_DB = type(AVM_SHADOW_DB) == "table" and AVM_SHADOW_DB or {}
AVM_SHADOW_DB.authority = {
    revision = REVISION,
    authoritative = "AuxVmangos",
    shadowRole = "observer-only",
    cutoverWanted = false,
    reason = "user-authorized-direct-live",
}
