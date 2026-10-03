local R = W112_AH_SHADOW
if type(R) ~= "table" or type(R.ReplaceModule) ~= "function" then
    error("AuxEconomyShadow autosell requires persistent anchor")
end

local REVISION = "1-pure-lifecycle"
local ok = R.ReplaceModule("autosell", REVISION, function(state)
    state.entries = type(state.entries) == "table" and state.entries or {}
    state.serial = tonumber(state.serial) or 0
    state.completed = tonumber(state.completed) or 0
    state.blocked = tonumber(state.blocked) or 0

    local api = {}
    api.revision = REVISION

    local VALID = {
        OWNED = true,
        CANCEL_REQUESTED = true,
        WAIT_RETURN = true,
        WAIT_REPRICE = true,
        POST_READY = true,
        POST_PENDING = true,
        POST_RECOVER = true,
        DONE = true,
        BLOCKED = true,
    }

    local function copyRow(row)
        if type(row) ~= "table" then return nil end
        local out = {}
        for k, v in pairs(row) do out[k] = v end
        return out
    end

    local function keyFor(row)
        if type(row) ~= "table" then return "" end
        if row.lifecycleKey and tostring(row.lifecycleKey) ~= "" then return tostring(row.lifecycleKey) end
        return table.concat({
            tostring(row.itemKey or row.itemId or ""),
            tostring(tonumber(row.count) or 0),
            tostring(tonumber(row.originalBuyout or row.buyout) or 0),
            tostring(row.signature or ""),
        }, "|")
    end

    local function transition(entry, nextState, now, reason)
        nextState = tostring(nextState or "")
        if not VALID[nextState] then return false, "invalid-state" end
        entry.state = nextState
        entry.updatedAt = tonumber(now) or entry.updatedAt or 0
        entry.lastReason = tostring(reason or "")
        return true
    end

    function api.UpsertOwned(row, now)
        if type(row) ~= "table" then return nil, "no-row" end
        local key = keyFor(row)
        if key == "" then return nil, "no-key" end
        local entry = state.entries[key]
        if not entry then
            state.serial = state.serial + 1
            entry = {
                serial = state.serial,
                lifecycleKey = key,
                itemId = tonumber(row.itemId) or 0,
                itemKey = tostring(row.itemKey or ""),
                name = tostring(row.name or ""),
                count = tonumber(row.count) or 0,
                originalBuyout = tonumber(row.originalBuyout or row.buyout) or 0,
                originalUnit = tonumber(row.originalUnit or row.unit) or 0,
                signature = tostring(row.signature or ""),
                createdAt = tonumber(now) or 0,
                updatedAt = tonumber(now) or 0,
                state = "OWNED",
            }
            state.entries[key] = entry
        else
            entry.itemId = tonumber(row.itemId) or entry.itemId or 0
            entry.itemKey = tostring(row.itemKey or entry.itemKey or "")
            entry.name = tostring(row.name or entry.name or "")
            entry.count = tonumber(row.count) or entry.count or 0
            entry.signature = tostring(row.signature or entry.signature or "")
            entry.updatedAt = tonumber(now) or entry.updatedAt or 0
        end
        return copyRow(entry), nil
    end

    function api.RequestCancel(key, now, reason)
        local entry = state.entries[tostring(key or "")]
        if not entry then return false, "not-found" end
        if entry.state ~= "OWNED" and entry.state ~= "BLOCKED" then return false, "invalid-state:" .. tostring(entry.state) end
        entry.cancelRequestedAt = tonumber(now) or 0
        return transition(entry, "CANCEL_REQUESTED", now, reason or "cancel-intent")
    end

    function api.ObserveOwnerSnapshot(key, stillPresent, now)
        local entry = state.entries[tostring(key or "")]
        if not entry then return false, "not-found" end
        if entry.state ~= "CANCEL_REQUESTED" and entry.state ~= "WAIT_RETURN" then return false, "invalid-state:" .. tostring(entry.state) end
        if stillPresent then
            entry.ownerGone = false
            return true, "still-owned"
        end
        entry.ownerGone = true
        entry.ownerGoneAt = tonumber(now) or 0
        return transition(entry, "WAIT_RETURN", now, "owner-snapshot-missing")
    end

    function api.ObserveReturnedToBag(key, bagQuantity, mailEvidence, now)
        local entry = state.entries[tostring(key or "")]
        if not entry then return false, "not-found" end
        if entry.state ~= "WAIT_RETURN" and entry.state ~= "POST_RECOVER" then return false, "invalid-state:" .. tostring(entry.state) end
        local qty = tonumber(bagQuantity) or 0
        local need = tonumber(entry.count) or 0
        entry.lastBagQuantity = qty
        entry.mailEvidence = mailEvidence and true or false
        if need <= 0 or qty < need then return false, "bag-not-ready" end
        if not entry.mailEvidence and entry.state == "WAIT_RETURN" then return false, "mail-evidence-missing" end
        entry.returnedAt = tonumber(now) or 0
        return transition(entry, "WAIT_REPRICE", now, "item-returned")
    end

    function api.SetReprice(key, targetUnit, marketUnit, now)
        local entry = state.entries[tostring(key or "")]
        if not entry then return false, "not-found" end
        if entry.state ~= "WAIT_REPRICE" then return false, "invalid-state:" .. tostring(entry.state) end
        targetUnit = tonumber(targetUnit) or 0
        if targetUnit <= 0 then
            state.blocked = state.blocked + 1
            entry.blockedReason = "invalid-target"
            transition(entry, "BLOCKED", now, entry.blockedReason)
            return false, entry.blockedReason
        end
        entry.targetUnit = targetUnit
        entry.marketUnit = tonumber(marketUnit) or 0
        entry.targetBuyout = math.floor(targetUnit * (tonumber(entry.count) or 0) + .5)
        return transition(entry, "POST_READY", now, "repriced")
    end

    function api.MarkPostStarted(key, now)
        local entry = state.entries[tostring(key or "")]
        if not entry then return false, "not-found" end
        if entry.state ~= "POST_READY" then return false, "invalid-state:" .. tostring(entry.state) end
        entry.postStartedAt = tonumber(now) or 0
        return transition(entry, "POST_PENDING", now, "post-intent-issued")
    end

    function api.ObservePosted(key, foundMatchingOwnerAuction, bagQuantity, now)
        local entry = state.entries[tostring(key or "")]
        if not entry then return false, "not-found" end
        if entry.state ~= "POST_PENDING" and entry.state ~= "POST_RECOVER" then return false, "invalid-state:" .. tostring(entry.state) end
        if foundMatchingOwnerAuction then
            entry.postConfirmedAt = tonumber(now) or 0
            transition(entry, "DONE", now, "owner-snapshot-confirmed-post")
            state.completed = state.completed + 1
            return true, "done"
        end
        local qty = tonumber(bagQuantity) or 0
        if qty >= (tonumber(entry.count) or 0) and (tonumber(entry.count) or 0) > 0 then
            transition(entry, "WAIT_REPRICE", now, "post-not-found-item-in-bag")
            return true, "retry-reprice"
        end
        transition(entry, "POST_RECOVER", now, "post-unknown")
        return true, "recover"
    end

    function api.Block(key, reason, now)
        local entry = state.entries[tostring(key or "")]
        if not entry then return false, "not-found" end
        if entry.state ~= "BLOCKED" then state.blocked = state.blocked + 1 end
        entry.blockedReason = tostring(reason or "blocked")
        return transition(entry, "BLOCKED", now, entry.blockedReason)
    end

    function api.NextIntent(now)
        local best = nil
        for _, entry in pairs(state.entries) do
            if entry.state ~= "DONE" then
                if not best or (tonumber(entry.serial) or 0) < (tonumber(best.serial) or 0) then best = entry end
            end
        end
        if not best then return nil end
        local intent = { lifecycleKey = best.lifecycleKey, state = best.state, at = tonumber(now) or 0 }
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

    function api.Snapshot()
        local rows = {}
        local counts = {}
        for key, entry in pairs(state.entries) do
            rows[key] = copyRow(entry)
            counts[entry.state] = (tonumber(counts[entry.state]) or 0) + 1
        end
        return {
            serial = state.serial,
            completed = state.completed,
            blocked = state.blocked,
            counts = counts,
            entries = rows,
        }
    end

    return api
end)
if not ok then error(R.lastHotError or "autosell replacement failed") end
