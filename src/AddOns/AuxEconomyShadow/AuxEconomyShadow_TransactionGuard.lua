local R = W112_AH_SHADOW
if type(R) ~= "table" or type(R.ReplaceModule) ~= "function" then
    error("AuxEconomyShadow transaction guard requires persistent anchor")
end

local REVISION = "1-fail-closed-shadow"
local ok = R.ReplaceModule("transaction_guard", REVISION, function(state)
    state.serial = tonumber(state.serial) or 0
    state.pending = state.pending or nil
    state.last = state.last or nil
    state.realActionsEnabled = false

    local api = {}
    api.revision = REVISION

    local function candidateKey(c)
        if type(c) ~= "table" then return "" end
        return table.concat({
            tostring(c.route or ""), tostring(c.itemId or 0), tostring(c.count or 0),
            tostring(c.buyout or 0), tostring(c.signature or ""), tostring(c.sourcePage or 0),
        }, "|")
    end

    function api.RealActionsEnabled()
        return state.realActionsEnabled and true or false
    end

    function api.SetRealActionsEnabled(enabled)
        -- Shadow consolidation is deliberately incapable of arming real actions
        -- until a later cutover-specific implementation replaces this module.
        state.realActionsEnabled = false
        return false, enabled and "shadow-real-actions-locked" or "already-disabled"
    end

    function api.Prepare(candidate, context)
        if type(candidate) ~= "table" then return nil, "no-candidate" end
        if state.pending then return nil, "transaction-already-pending" end
        context = context or {}
        local amount = tonumber(candidate.buyout) or 0
        if amount <= 0 then return nil, "invalid-amount" end
        local money = tonumber(context.money) or 0
        if amount > money then return nil, "wallet" end
        if context.queryInFlight then return nil, "query-in-flight" end
        if context.unknownHold then return nil, "unknown-hold" end
        if context.signatureCurrent == false then return nil, "stale-signature" end

        state.serial = state.serial + 1
        local token = "shadow-tx-" .. tostring(state.serial) .. "-" .. candidateKey(candidate)
        state.pending = {
            token = token,
            key = candidateKey(candidate),
            route = tostring(candidate.route or ""),
            itemId = tonumber(candidate.itemId) or 0,
            amount = amount,
            preparedAt = tonumber(context.now) or 0,
            shadowOnly = true,
        }
        return token, nil
    end

    function api.Validate(token, candidate, context)
        local p = state.pending
        if not p then return false, "nothing-pending" end
        if tostring(token or "") ~= tostring(p.token or "") then return false, "token-mismatch" end
        if p.key ~= candidateKey(candidate) then return false, "candidate-changed" end
        context = context or {}
        if (tonumber(context.money) or 0) < (tonumber(p.amount) or 0) then return false, "wallet-changed" end
        if context.queryInFlight then return false, "query-in-flight" end
        if context.unknownHold then return false, "unknown-hold" end
        if context.signatureCurrent == false then return false, "stale-signature" end
        if not state.realActionsEnabled then return false, "shadow-real-actions-locked" end
        return true, nil
    end

    function api.MarkSimulated(token, outcome)
        local p = state.pending
        if not p then return false, "nothing-pending" end
        if tostring(token or "") ~= tostring(p.token or "") then return false, "token-mismatch" end
        p.outcome = tostring(outcome or "simulated")
        p.completed = true
        state.last = p
        state.pending = nil
        return true
    end

    function api.Abort(token, reason)
        local p = state.pending
        if not p then return false, "nothing-pending" end
        if token and tostring(token) ~= tostring(p.token or "") then return false, "token-mismatch" end
        p.outcome = "aborted:" .. tostring(reason or "unknown")
        p.completed = true
        state.last = p
        state.pending = nil
        return true
    end

    function api.Snapshot()
        return {
            serial = state.serial,
            pending = state.pending,
            last = state.last,
            realActionsEnabled = false,
        }
    end

    return api
end)
if not ok then error(R.lastHotError or "transaction guard replacement failed") end
