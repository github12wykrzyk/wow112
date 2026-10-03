local R = W112_AH_SHADOW
if type(R) ~= "table" or type(R.ReplaceModule) ~= "function" then
    error("AuxEconomyShadow coordinator requires persistent anchor")
end

local REVISION = "1-readonly-state-machine"
local ok = R.ReplaceModule("coordinator", REVISION, function(state)
    state.phase = state.phase or "IDLE"
    state.scanSerial = tonumber(state.scanSerial) or 0
    state.records = tonumber(state.records) or 0
    state.pages = tonumber(state.pages) or 0
    state.bestVendor = state.bestVendor or nil
    state.bestDe = state.bestDe or nil
    state.lastReason = state.lastReason or ""

    local api = {}
    api.revision = REVISION

    local allowed = {
        IDLE = { SCANNING=true, STOPPED=true },
        SCANNING = { PAUSE_REQUESTED=true, IDLE=true, STOPPED=true },
        PAUSE_REQUESTED = { PAUSED=true, SCANNING=true, STOPPED=true },
        PAUSED = { VERIFYING=true, RESUME_PENDING=true, IDLE=true, STOPPED=true },
        VERIFYING = { TRANSACTION_PENDING=true, RESUME_PENDING=true, IDLE=true, STOPPED=true },
        TRANSACTION_PENDING = { UNKNOWN_HOLD=true, RESUME_PENDING=true, IDLE=true, STOPPED=true },
        UNKNOWN_HOLD = { RESUME_PENDING=true, IDLE=true, STOPPED=true },
        RESUME_PENDING = { SCANNING=true, IDLE=true, STOPPED=true },
        STOPPED = { IDLE=true },
    }

    local function transition(nextPhase, reason)
        nextPhase = tostring(nextPhase or "")
        local current = tostring(state.phase or "IDLE")
        if nextPhase == current then
            state.lastReason = tostring(reason or state.lastReason or "")
            return true
        end
        if not allowed[current] or not allowed[current][nextPhase] then
            state.lastError = "invalid transition " .. current .. " -> " .. nextPhase
            return false, state.lastError
        end
        state.previousPhase = current
        state.phase = nextPhase
        state.lastReason = tostring(reason or "")
        state.transitionSerial = (tonumber(state.transitionSerial) or 0) + 1
        return true
    end

    function api.BeginScan(meta)
        if state.phase == "STOPPED" then
            local resetOk = transition("IDLE", "restart")
            if not resetOk then return false end
        end
        if state.phase ~= "IDLE" and state.phase ~= "RESUME_PENDING" then
            return false, "scan-begin-from-" .. tostring(state.phase)
        end
        local moved, err = transition("SCANNING", meta and meta.resume and "resume" or "new-scan")
        if not moved then return false, err end
        state.scanSerial = state.scanSerial + 1
        if not (meta and meta.resume) then
            state.records = 0
            state.pages = 0
            state.bestVendor = nil
            state.bestDe = nil
        end
        state.filter = tostring(meta and meta.filter or state.filter or "")
        state.startedAt = tonumber(meta and meta.now) or state.startedAt or 0
        return true, state.scanSerial
    end

    function api.ObserveCandidate(candidate)
        if state.phase ~= "SCANNING" or type(candidate) ~= "table" then return false end
        local contracts = R.GetModule("contracts")
        if not contracts then return false end
        state.records = state.records + 1
        if candidate.route == "vendor" then
            if contracts.BetterCandidate(candidate, state.bestVendor) then state.bestVendor = candidate end
        elseif candidate.route == "disenchant" then
            if contracts.BetterCandidate(candidate, state.bestDe) then state.bestDe = candidate end
        end
        return true
    end

    function api.PageDone()
        if state.phase ~= "SCANNING" then return false end
        state.pages = state.pages + 1
        return true
    end

    function api.RequestPause(reason)
        if state.phase ~= "SCANNING" then return false, "not-scanning" end
        return transition("PAUSE_REQUESTED", reason or "candidate")
    end

    function api.MarkPaused(reason)
        if state.phase ~= "PAUSE_REQUESTED" then return false, "pause-not-requested" end
        return transition("PAUSED", reason or "bridge-paused")
    end

    function api.BeginVerify(reason)
        if state.phase ~= "PAUSED" then return false, "not-paused" end
        return transition("VERIFYING", reason or "verify")
    end

    function api.MarkTransactionPending(reason)
        if state.phase ~= "VERIFYING" then return false, "not-verifying" end
        return transition("TRANSACTION_PENDING", reason or "transaction")
    end

    function api.MarkUnknown(reason)
        if state.phase ~= "TRANSACTION_PENDING" then return false, "no-transaction" end
        return transition("UNKNOWN_HOLD", reason or "unknown")
    end

    function api.RequestResume(reason)
        local phase = tostring(state.phase or "IDLE")
        if phase ~= "PAUSED" and phase ~= "VERIFYING" and phase ~= "TRANSACTION_PENDING" and phase ~= "UNKNOWN_HOLD" then
            return false, "resume-from-" .. phase
        end
        return transition("RESUME_PENDING", reason or "resume")
    end

    function api.FinishScan(reason)
        local phase = tostring(state.phase or "IDLE")
        if phase == "SCANNING" or phase == "RESUME_PENDING" or phase == "PAUSED" or phase == "VERIFYING" then
            return transition("IDLE", reason or "scan-done")
        end
        if phase == "IDLE" then return true end
        return false, "finish-from-" .. phase
    end

    function api.Stop(reason)
        if state.phase == "STOPPED" then return true end
        return transition("STOPPED", reason or "stop")
    end

    function api.Reset(reason)
        state.phase = "IDLE"
        state.previousPhase = nil
        state.lastReason = tostring(reason or "reset")
        state.bestVendor = nil
        state.bestDe = nil
        state.records = 0
        state.pages = 0
        return true
    end

    function api.Snapshot()
        return {
            phase = state.phase,
            previousPhase = state.previousPhase,
            scanSerial = state.scanSerial,
            transitionSerial = state.transitionSerial or 0,
            records = state.records,
            pages = state.pages,
            bestVendor = state.bestVendor,
            bestDe = state.bestDe,
            lastReason = state.lastReason,
            lastError = state.lastError,
            filter = state.filter,
        }
    end

    return api
end)
if not ok then error(R.lastHotError or "coordinator replacement failed") end
