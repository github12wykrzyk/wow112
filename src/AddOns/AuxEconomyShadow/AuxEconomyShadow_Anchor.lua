W112_AH_SHADOW = W112_AH_SHADOW or {}
local R = W112_AH_SHADOW

R.schemaVersion = 2
R.modules = R.modules or {}
R.moduleState = R.moduleState or {}
R.failures = R.failures or {}
R.generation = tonumber(R.generation) or 0
R.hotPayloadGeneration = tonumber(R.hotPayloadGeneration) or 0
R.lastHotError = R.lastHotError or nil

local function recordFailure(name, revision, phase, err)
    local row = {
        name = tostring(name or "?"),
        revision = tostring(revision or "?"),
        phase = tostring(phase or "?"),
        error = tostring(err or "unknown"),
    }
    table.insert(R.failures, row)
    while table.getn(R.failures) > 20 do table.remove(R.failures, 1) end
    R.lastHotError = row.phase .. ": " .. row.error
end

function R.GetModule(name)
    local row = R.modules[tostring(name or "")]
    return row and row.api or nil
end

function R.GetModuleRevision(name)
    local row = R.modules[tostring(name or "")]
    return row and row.revision or nil
end

function R.ReplaceModule(name, revision, factory)
    name = tostring(name or "")
    revision = tostring(revision or "")
    if name == "" or revision == "" or type(factory) ~= "function" then
        recordFailure(name, revision, "validate", "invalid module replacement request")
        return false
    end

    local old = R.modules[name]
    local state = R.moduleState[name]
    if type(state) ~= "table" then
        state = {}
        R.moduleState[name] = state
    end

    local okFactory, newApi = pcall(factory, state, old and old.api or nil)
    if not okFactory or type(newApi) ~= "table" then
        recordFailure(name, revision, "factory", okFactory and "factory returned non-table" or newApi)
        return false
    end

    if old and old.api and type(old.api.uninstall) == "function" then
        local okUninstall, errUninstall = pcall(old.api.uninstall, "hot_replace")
        if not okUninstall then
            recordFailure(name, revision, "old_uninstall", errUninstall)
            return false
        end
    end

    if type(newApi.install) == "function" then
        local okInstall, errInstall = pcall(newApi.install, old and "hot_replace" or "cold_install")
        if not okInstall then
            recordFailure(name, revision, "new_install", errInstall)
            if old and old.api and type(old.api.install) == "function" then
                pcall(old.api.install, "rollback_after_failed_hot_replace")
            end
            return false
        end
    end

    R.modules[name] = {
        revision = revision,
        api = newApi,
    }
    R.generation = R.generation + 1
    return true
end

function R.BeginHotPayload(revision)
    R.hotPayloadGeneration = R.hotPayloadGeneration + 1
    R.hotPayloadRevision = tostring(revision or "unknown")
    R.hotPayloadApplying = true
    R.lastHotError = nil
    return R.hotPayloadGeneration
end

function R.EndHotPayload(ok, err)
    R.hotPayloadApplying = false
    if not ok then
        R.lastHotError = tostring(err or "hot payload failed")
        return false
    end
    R.lastHotAppliedGeneration = R.hotPayloadGeneration
    return true
end

function R.Snapshot()
    local modules = {}
    for name, row in pairs(R.modules) do
        modules[name] = row.revision
    end
    return {
        schemaVersion = R.schemaVersion,
        generation = R.generation,
        hotPayloadGeneration = R.hotPayloadGeneration,
        hotPayloadRevision = R.hotPayloadRevision,
        lastHotAppliedGeneration = R.lastHotAppliedGeneration,
        lastHotError = R.lastHotError,
        modules = modules,
    }
end
