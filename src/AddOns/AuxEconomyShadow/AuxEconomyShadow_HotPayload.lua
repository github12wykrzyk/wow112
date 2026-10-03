local R = W112_AH_SHADOW
if type(R) ~= "table" or type(R.ReplaceModule) ~= "function" then
    error("AuxEconomyShadow hot payload requires persistent anchor")
end

local PAYLOAD_REVISION = "0.2-bootstrap"
R.BeginHotPayload(PAYLOAD_REVISION)

local ok, err = pcall(function()
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
            }
        end
        return api
    end)
    if not replaced then
        error(R.lastHotError or "bootstrap replacement failed")
    end
end)

R.EndHotPayload(ok, err)
if not ok then error(err) end
