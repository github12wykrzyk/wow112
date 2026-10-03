W112_AH_SHADOW = W112_AH_SHADOW or {}
local R = W112_AH_SHADOW

R.schemaVersion = 3
R.modules = R.modules or {}
R.moduleState = R.moduleState or {}
R.failures = R.failures or {}
R.generation = tonumber(R.generation) or 0
R.hotPayloadGeneration = tonumber(R.hotPayloadGeneration) or 0
R.lastHotError = R.lastHotError or nil
R._hotBatch = nil
R.hotPayloadApplying = false

local function recordFailure(name, revision, phase, err)
    local row = { name=tostring(name or "?"), revision=tostring(revision or "?"), phase=tostring(phase or "?"), error=tostring(err or "unknown") }
    table.insert(R.failures, row)
    while table.getn(R.failures) > 20 do table.remove(R.failures, 1) end
    R.lastHotError = row.phase .. ": " .. row.error
end

local function cloneValue(value, seen)
    if type(value) ~= "table" then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local out = {}
    seen[value] = out
    for k, v in pairs(value) do out[cloneValue(k, seen)] = cloneValue(v, seen) end
    return out
end

local function liveRow(name) return R.modules[tostring(name or "")] end

function R.GetModule(name)
    name = tostring(name or "")
    local batch = R._hotBatch
    if batch and batch.staged and batch.staged[name] then return batch.staged[name].api end
    local row = liveRow(name)
    return row and row.api or nil
end

function R.GetModuleRevision(name)
    name = tostring(name or "")
    local batch = R._hotBatch
    if batch and batch.staged and batch.staged[name] then return batch.staged[name].revision end
    local row = liveRow(name)
    return row and row.revision or nil
end

local function currentRealActionsEnabled()
    local row = liveRow("transaction_guard")
    local api = row and row.api or nil
    if not api or type(api.RealActionsEnabled) ~= "function" then return false, nil end
    local ok, enabled = pcall(api.RealActionsEnabled)
    if not ok then return nil, "guard-status-error" end
    return enabled and true or false, nil
end

local function prepareGenerationState(name, state, generation, preserveLiveLifecycle)
    generation = tonumber(generation) or 0
    if tonumber(state.boundHotGeneration) == generation then return end

    if name == "marketbook" then
        state.books = {}
        state.nextGeneration = 0
    elseif name == "aux_adapter" then
        state.materialBook = {}
        state.activeScanSerial = nil
    elseif name == "coordinator" then
        state.phase = "IDLE"
        state.previousPhase = nil
        state.records = 0
        state.pages = 0
        state.bestVendor = nil
        state.bestDe = nil
        state.filter = nil
        state.startedAt = 0
        state.lastReason = "hot-generation-reset"
        state.lastError = nil
    elseif name == "transaction_guard" then
        if not preserveLiveLifecycle then state.pending = nil end
    elseif name == "autosell" then
        if not preserveLiveLifecycle then
            state.entries = {}
            state.serial = 0
            state.completed = 0
            state.blocked = 0
        end
    elseif name == "parity" then
        state.rows = {}
        state.counts = {}
        state.serial = 0
    end
    state.boundHotGeneration = generation
end

local function guardPendingReason(api)
    if api and type(api.Snapshot) == "function" then
        local ok, snap = pcall(api.Snapshot)
        if not ok then return "guard-snapshot-error" end
        if type(snap) == "table" and snap.pending then return "guard-pending" end
    end
    return nil
end

local function hardenCoordinator(api)
    if type(api) ~= "table" or api.__criticalHardened then return api end
    local originalReset, originalStop, originalResume = api.Reset, api.Stop, api.RequestResume

    local function pendingReason()
        local snap = type(api.Snapshot) == "function" and api.Snapshot() or nil
        local phase = type(snap) == "table" and tostring(snap.phase or "") or ""
        if phase == "TRANSACTION_PENDING" or phase == "UNKNOWN_HOLD" then return "coordinator-" .. string.lower(phase) end
        return guardPendingReason(R.GetModule("transaction_guard"))
    end

    if type(originalReset) == "function" then
        api.Reset = function(reason)
            local pending = pendingReason()
            if pending then return false, "reset-blocked:" .. pending end
            return originalReset(reason)
        end
    end
    if type(originalStop) == "function" then
        api.Stop = function(reason)
            local pending = pendingReason()
            if pending then return false, "stop-blocked:" .. pending end
            return originalStop(reason)
        end
    end
    if type(originalResume) == "function" then
        api.RequestResume = function(reason)
            local snap = type(api.Snapshot) == "function" and api.Snapshot() or nil
            local phase = type(snap) == "table" and tostring(snap.phase or "") or ""
            if phase == "TRANSACTION_PENDING" or phase == "UNKNOWN_HOLD" then
                local pending = pendingReason()
                if pending then return false, "resume-blocked:" .. pending end
            end
            return originalResume(reason)
        end
    end
    api.__criticalHardened = true
    return api
end

local function hardenAutoSell(api, state)
    if type(api) ~= "table" or api.__criticalHardened then return api end
    api.NextIntent = function(now)
        local bestActionable, bestBlocked = nil, nil
        for _, entry in pairs(state.entries or {}) do
            if entry.state ~= "DONE" then
                if entry.state == "BLOCKED" then
                    if not bestBlocked or (tonumber(entry.serial) or 0) < (tonumber(bestBlocked.serial) or 0) then bestBlocked = entry end
                elseif not bestActionable or (tonumber(entry.serial) or 0) < (tonumber(bestActionable.serial) or 0) then
                    bestActionable = entry
                end
            end
        end
        local best = bestActionable or bestBlocked
        if not best then return nil end
        local intent = { lifecycleKey=best.lifecycleKey, state=best.state, at=tonumber(now) or 0 }
        if best.state == "OWNED" then intent.kind = "cancel_request"
        elseif best.state == "CANCEL_REQUESTED" then intent.kind = "owner_verify"
        elseif best.state == "WAIT_RETURN" then intent.kind = "mail_bag_verify"
        elseif best.state == "WAIT_REPRICE" then intent.kind = "reprice_probe"
        elseif best.state == "POST_READY" then intent.kind = "post_request"
        elseif best.state == "POST_PENDING" or best.state == "POST_RECOVER" then intent.kind = "owner_post_verify"
        elseif best.state == "BLOCKED" then intent.kind = "blocked"
        else intent.kind = "none" end
        return intent
    end
    api.__criticalHardened = true
    return api
end

local function hardenParity(api)
    if type(api) ~= "table" or api.__criticalHardened then return api end
    api.CutoverGate = function(policy)
        policy = type(policy) == "table" and policy or {}
        local summary = type(api.Summary) == "function" and api.Summary() or {}
        local counts = summary.counts or {}
        local compared = tonumber(summary.decisionCompared) or 0
        local matchPct = tonumber(summary.decisionMatchPct) or 0
        local minCompared = tonumber(policy.minDecisionComparisons) or 100
        local minMatchPct = tonumber(policy.minMatchPct) or 100
        local maxExtra = tonumber(policy.maxShadowExtra) or 0
        local maxMiss = tonumber(policy.maxShadowMiss) or 0
        local maxDifferent = tonumber(policy.maxDifferentCandidate) or 0
        local maxLifecycleDiff = tonumber(policy.maxLifecycleDiff) or 0

        if R.hotPayloadApplying then return false, "hot-payload-applying", summary end
        if tostring(R.lastHotError or "") ~= "" then return false, "hot-payload-error", summary end
        if (tonumber(R.hotPayloadGeneration) or 0) > 0 and tonumber(R.lastHotAppliedGeneration) ~= tonumber(R.hotPayloadGeneration) then
            return false, "hot-generation-not-committed", summary
        end
        if compared < minCompared then return false, "insufficient-decisions", summary end
        if (tonumber(counts["shadow-extra"]) or 0) > maxExtra then return false, "shadow-extra", summary end
        if (tonumber(counts["shadow-miss"]) or 0) > maxMiss then return false, "shadow-miss", summary end
        if (tonumber(counts["different-candidate"]) or 0) > maxDifferent then return false, "different-candidate", summary end
        if (tonumber(counts["lifecycle-diff"]) or 0) > maxLifecycleDiff then return false, "lifecycle-diff", summary end
        if matchPct < minMatchPct then return false, "match-percent", summary end
        return true, "ready", summary
    end
    api.__criticalHardened = true
    return api
end

local function hardenTransactionGuard(api)
    if type(api) ~= "table" or api.__criticalHardened then return api end
    local originalSet = api.SetRealActionsEnabled
    if type(originalSet) == "function" then
        api.SetRealActionsEnabled = function(enabled, policy)
            if enabled then
                local parity = R.GetModule("parity")
                if not parity or type(parity.CutoverGate) ~= "function" then return false, "parity-gate-unavailable" end
                local ready, reason = parity.CutoverGate(policy)
                if not ready then return false, "parity-gate:" .. tostring(reason) end
            end
            return originalSet(enabled)
        end
    end
    api.__criticalHardened = true
    return api
end

local function hardenApi(name, api, state)
    if name == "coordinator" then return hardenCoordinator(api) end
    if name == "autosell" then return hardenAutoSell(api, state) end
    if name == "parity" then return hardenParity(api) end
    if name == "transaction_guard" then return hardenTransactionGuard(api) end
    return api
end

local function rollbackImmediate(old, newApi, oldUninstalled, newInstallAttempted)
    if newInstallAttempted and newApi and type(newApi.uninstall) == "function" then pcall(newApi.uninstall, "rollback_after_failed_replace") end
    if oldUninstalled and old and old.api and type(old.api.install) == "function" then pcall(old.api.install, "rollback_after_failed_replace") end
end

local function replaceImmediate(name, revision, factory)
    local old = liveRow(name)
    local state = cloneValue(R.moduleState[name] or {})
    prepareGenerationState(name, state, R.hotPayloadGeneration, false)
    local okFactory, newApi = pcall(factory, state, old and old.api or nil)
    if not okFactory or type(newApi) ~= "table" then recordFailure(name, revision, "factory", okFactory and "factory returned non-table" or newApi); return false end
    newApi = hardenApi(name, newApi, state)

    local oldUninstalled = false
    if old and old.api and type(old.api.uninstall) == "function" then
        local okUninstall, errUninstall = pcall(old.api.uninstall, "replace")
        if not okUninstall then recordFailure(name, revision, "old_uninstall", errUninstall); return false end
        oldUninstalled = true
    end
    local installAttempted = false
    if type(newApi.install) == "function" then
        installAttempted = true
        local okInstall, errInstall = pcall(newApi.install, old and "replace" or "cold_install")
        if not okInstall then rollbackImmediate(old, newApi, oldUninstalled, installAttempted); recordFailure(name, revision, "new_install", errInstall); return false end
    end
    R.moduleState[name] = state
    R.modules[name] = { revision=revision, api=newApi }
    R.generation = R.generation + 1
    return true
end

function R.ReplaceModule(name, revision, factory)
    name, revision = tostring(name or ""), tostring(revision or "")
    if name == "" or revision == "" or type(factory) ~= "function" then recordFailure(name, revision, "validate", "invalid module replacement request"); return false end
    local batch = R._hotBatch
    if not batch then return replaceImmediate(name, revision, factory) end
    if batch.failed then return false end
    if batch.staged[name] then batch.failed=true; batch.error="duplicate module in hot batch: " .. name; recordFailure(name, revision, "batch_duplicate", batch.error); return false end

    local old = liveRow(name)
    local stagedState = cloneValue(R.moduleState[name] or {})
    prepareGenerationState(name, stagedState, batch.generation, batch.realActionsEnabled)
    local okFactory, newApi = pcall(factory, stagedState, old and old.api or nil)
    if not okFactory or type(newApi) ~= "table" then
        batch.failed = true
        batch.error = okFactory and "factory returned non-table" or tostring(newApi)
        recordFailure(name, revision, "batch_factory", batch.error)
        return false
    end
    newApi = hardenApi(name, newApi, stagedState)
    batch.staged[name] = { name=name, revision=revision, api=newApi, state=stagedState, old=old }
    table.insert(batch.order, name)
    return true
end

local function unsafeLiveHotReloadReason(realEnabled)
    if not realEnabled then return nil end
    local tx = liveRow("transaction_guard"); tx = tx and tx.api or nil
    local reason = guardPendingReason(tx)
    if reason then return reason end
    local coord = liveRow("coordinator"); coord = coord and coord.api or nil
    if coord and type(coord.Snapshot) == "function" then
        local ok, snap = pcall(coord.Snapshot)
        if not ok then return "coordinator-snapshot-error" end
        local phase = type(snap) == "table" and tostring(snap.phase or "") or ""
        if phase == "TRANSACTION_PENDING" or phase == "UNKNOWN_HOLD" then return "coordinator-" .. string.lower(phase) end
    end
    local autosell = liveRow("autosell"); autosell = autosell and autosell.api or nil
    if autosell and type(autosell.Snapshot) == "function" then
        local ok, snap = pcall(autosell.Snapshot)
        if not ok then return "autosell-snapshot-error" end
        local counts = type(snap) == "table" and snap.counts or {}
        local unsafe = { "CANCEL_REQUESTED", "WAIT_RETURN", "WAIT_REPRICE", "POST_READY", "POST_PENDING", "POST_RECOVER" }
        for i = 1, table.getn(unsafe) do if (tonumber(counts and counts[unsafe[i]]) or 0) > 0 then return "autosell-inflight:" .. unsafe[i] end end
    end
    return nil
end

function R.BeginHotPayload(revision)
    revision = tostring(revision or "unknown")
    if R.hotPayloadApplying or R._hotBatch then recordFailure("bundle", revision, "batch_begin", "hot payload already applying"); return false, "hot-payload-already-applying" end
    local realEnabled, enabledErr = currentRealActionsEnabled()
    if realEnabled == nil then recordFailure("bundle", revision, "batch_begin", enabledErr); return false, enabledErr end
    local unsafe = unsafeLiveHotReloadReason(realEnabled)
    if unsafe then recordFailure("bundle", revision, "batch_begin", unsafe); return false, unsafe end

    R.hotPayloadGeneration = R.hotPayloadGeneration + 1
    R.hotPayloadRevision = revision
    R.hotPayloadApplying = true
    R.lastHotError = nil
    R._hotBatch = { revision=revision, generation=R.hotPayloadGeneration, previousGeneration=R.generation, staged={}, order={}, failed=false, error=nil, realActionsEnabled=realEnabled and true or false }
    return true, R.hotPayloadGeneration
end

local function rollbackBatchSideEffects(applied)
    for i = table.getn(applied), 1, -1 do
        local row = applied[i]
        if row.newInstallAttempted and row.newApi and type(row.newApi.uninstall) == "function" then pcall(row.newApi.uninstall, "rollback_after_failed_batch") end
        if row.oldUninstalled and row.oldApi and type(row.oldApi.install) == "function" then pcall(row.oldApi.install, "rollback_after_failed_batch") end
    end
end

function R.EndHotPayload(ok, err)
    local batch = R._hotBatch
    if not batch then R.hotPayloadApplying=false; R.lastHotError=tostring(err or "hot payload ended without active batch"); return false, R.lastHotError end
    if not ok or batch.failed then
        local why = tostring(err or batch.error or "hot payload failed")
        R._hotBatch=nil; R.hotPayloadApplying=false; recordFailure("bundle", batch.revision, "batch_abort", why); return false, why
    end
    if table.getn(batch.order) == 0 then R._hotBatch=nil; R.hotPayloadApplying=false; recordFailure("bundle", batch.revision, "batch_commit", "empty hot batch"); return false, "empty-hot-batch" end

    local applied = {}
    for i = 1, table.getn(batch.order) do
        local name = batch.order[i]
        local staged = batch.staged[name]
        local oldApi = staged.old and staged.old.api or nil
        local row = { name=name, oldApi=oldApi, newApi=staged.api, oldUninstalled=false, newInstallAttempted=false }
        table.insert(applied, row)
        if oldApi and type(oldApi.uninstall) == "function" then
            local okUninstall, errUninstall = pcall(oldApi.uninstall, "atomic_hot_replace")
            if not okUninstall then rollbackBatchSideEffects(applied); R._hotBatch=nil; R.hotPayloadApplying=false; recordFailure(name, staged.revision, "batch_old_uninstall", errUninstall); return false, tostring(errUninstall) end
            row.oldUninstalled = true
        end
        if type(staged.api.install) == "function" then
            row.newInstallAttempted = true
            local okInstall, errInstall = pcall(staged.api.install, staged.old and "atomic_hot_replace" or "atomic_cold_install")
            if not okInstall then rollbackBatchSideEffects(applied); R._hotBatch=nil; R.hotPayloadApplying=false; recordFailure(name, staged.revision, "batch_new_install", errInstall); return false, tostring(errInstall) end
        end
    end

    for i = 1, table.getn(batch.order) do
        local name = batch.order[i]
        local staged = batch.staged[name]
        R.moduleState[name] = staged.state
        R.modules[name] = { revision=staged.revision, api=staged.api }
    end
    R.generation = batch.previousGeneration + table.getn(batch.order)
    R.lastHotAppliedGeneration = batch.generation
    R._hotBatch=nil; R.hotPayloadApplying=false; R.lastHotError=nil
    return true, batch.generation
end

function R.Snapshot()
    local modules = {}
    for name, row in pairs(R.modules) do modules[name] = row.revision end
    local staged = R._hotBatch and R._hotBatch.order and table.getn(R._hotBatch.order) or 0
    return { schemaVersion=R.schemaVersion, generation=R.generation, hotPayloadGeneration=R.hotPayloadGeneration, hotPayloadRevision=R.hotPayloadRevision,
        lastHotAppliedGeneration=R.lastHotAppliedGeneration, hotPayloadApplying=R.hotPayloadApplying and true or false, stagedModules=staged,
        lastHotError=R.lastHotError, modules=modules }
end
