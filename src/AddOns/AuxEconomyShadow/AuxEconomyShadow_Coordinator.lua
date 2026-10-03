-- AuxEconomyShadow coordinator model.
-- Pure state/diagnostic model for the future consolidated AH owner.
-- It deliberately has no frame/event hooks and performs no economic action.

AVM_SHADOW = AVM_SHADOW or {}
AVM_SHADOW_COORDINATOR = AVM_SHADOW_COORDINATOR or {}

local C = AVM_SHADOW_COORDINATOR
local S = AVM_SHADOW.STATE or {}

local allowed = {
    IDLE = { SCANNING = true, STOPPED = true },
    SCANNING = { PAUSE_REQUESTED = true, IDLE = true, STOPPED = true },
    PAUSE_REQUESTED = { PAUSED = true, SCANNING = true, STOPPED = true },
    PAUSED = { VERIFYING = true, RESUME_PENDING = true, STOPPED = true },
    VERIFYING = { TRANSACTION_PENDING = true, RESUME_PENDING = true, UNKNOWN_HOLD = true, STOPPED = true },
    TRANSACTION_PENDING = { RESUME_PENDING = true, UNKNOWN_HOLD = true, STOPPED = true },
    UNKNOWN_HOLD = { VERIFYING = true, RESUME_PENDING = true, STOPPED = true },
    RESUME_PENDING = { SCANNING = true, IDLE = true, STOPPED = true },
    STOPPED = { IDLE = true },
}

C.state = C.state or (S.IDLE or "IDLE")
C.serial = tonumber(C.serial) or 0
C.lastReason = C.lastReason or ""
C.lastFrom = C.lastFrom or ""
C.lastTo = C.lastTo or C.state

function C.CanTransition(nextState)
    nextState = tostring(nextState or "")
    local row = allowed[tostring(C.state or "")]
    return row and row[nextState] and true or false
end

function C.Transition(nextState, reason)
    nextState = tostring(nextState or "")
    if not C.CanTransition(nextState) then
        return false, "invalid-transition:" .. tostring(C.state) .. "->" .. nextState
    end
    local previous = C.state
    C.state = nextState
    C.serial = (tonumber(C.serial) or 0) + 1
    C.lastFrom = tostring(previous or "")
    C.lastTo = nextState
    C.lastReason = tostring(reason or "")
    return true, C.serial
end

function C.Reset(reason)
    C.state = S.IDLE or "IDLE"
    C.serial = (tonumber(C.serial) or 0) + 1
    C.lastFrom = "*"
    C.lastTo = C.state
    C.lastReason = tostring(reason or "reset")
    return C.serial
end

function C.Snapshot()
    return {
        state = tostring(C.state or ""),
        serial = tonumber(C.serial) or 0,
        lastFrom = tostring(C.lastFrom or ""),
        lastTo = tostring(C.lastTo or ""),
        lastReason = tostring(C.lastReason or ""),
    }
end
