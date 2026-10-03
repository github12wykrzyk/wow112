local R = W112_AH_SHADOW
if type(R) ~= "table" or type(R.ReplaceModule) ~= "function" then
    error("AuxEconomyShadow hot payload requires persistent anchor")
end

-- Bundle-level BeginHotPayload/EndHotPayload is owned by tools/ah_shadow_hot_bundle.py.
-- This module only participates in the same atomic replacement batch.
local PAYLOAD_REVISION = "0.3-atomic-bootstrap"
local replaced = R.ReplaceModule("bootstrap", PAYLOAD_REVISION, function(state)
    state.applyCount = (tonumber(state.applyCount) or 0) + 1
    local api = {}
    api.revision = PAYLOAD_REVISION
    function api.status()
        return {
            revision = PAYLOAD_REVISION,
            applyCount = state.applyCount,
            runtimeGeneration = R.generation,
            hotPayloadGeneration = R.hotPayloadGeneration,
            lastHotAppliedGeneration = R.lastHotAppliedGeneration,
        }
    end
    return api
end)
if not replaced then error(R.lastHotError or "bootstrap replacement failed") end
