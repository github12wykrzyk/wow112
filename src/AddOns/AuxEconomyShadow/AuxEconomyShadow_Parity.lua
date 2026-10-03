local R = W112_AH_SHADOW
if type(R) ~= "table" or type(R.ReplaceModule) ~= "function" then
    error("AuxEconomyShadow parity diagnostics require persistent anchor")
end

local REVISION = "1-pure-parity"
local ok = R.ReplaceModule("parity", REVISION, function(state)
    state.rows = type(state.rows) == "table" and state.rows or {}
    state.maxRows = tonumber(state.maxRows) or 500
    state.serial = tonumber(state.serial) or 0
    state.counts = type(state.counts) == "table" and state.counts or {}

    local api = {}
    api.revision = REVISION

    local function trim()
        while table.getn(state.rows) > state.maxRows do table.remove(state.rows, 1) end
    end

    local function candidateKey(c)
        if type(c) ~= "table" then return "" end
        return table.concat({
            tostring(c.route or c.mode or ""),
            tostring(tonumber(c.itemId) or 0),
            tostring(tonumber(c.count) or 0),
            tostring(tonumber(c.buyout) or 0),
            tostring(c.signature or ""),
        }, "|")
    end

    local function bump(kind)
        kind = tostring(kind or "unknown")
        state.counts[kind] = (tonumber(state.counts[kind]) or 0) + 1
        return kind
    end

    local function append(row)
        state.serial = state.serial + 1
        row.serial = state.serial
        table.insert(state.rows, row)
        trim()
        return row
    end

    function api.SetMaxRows(value)
        value = tonumber(value) or state.maxRows
        if value < 50 then value = 50 end
        if value > 5000 then value = 5000 end
        state.maxRows = math.floor(value)
        trim()
        return state.maxRows
    end

    function api.RecordDecision(active, shadow, now, note)
        local activeKey = candidateKey(active)
        local shadowKey = candidateKey(shadow)
        local outcome
        if activeKey == "" and shadowKey == "" then
            outcome = "both-reject"
        elseif activeKey == "" then
            outcome = "shadow-extra"
        elseif shadowKey == "" then
            outcome = "shadow-miss"
        elseif activeKey == shadowKey then
            outcome = "match"
        else
            outcome = "different-candidate"
        end
        bump(outcome)
        return append({
            kind = "decision",
            outcome = outcome,
            at = tonumber(now) or 0,
            activeKey = activeKey,
            shadowKey = shadowKey,
            activeRoute = type(active) == "table" and tostring(active.route or active.mode or "") or "",
            shadowRoute = type(shadow) == "table" and tostring(shadow.route or shadow.mode or "") or "",
            activeProfit = type(active) == "table" and (tonumber(active.profit) or 0) or 0,
            shadowProfit = type(shadow) == "table" and (tonumber(shadow.profit) or 0) or 0,
            note = tostring(note or ""),
        })
    end

    function api.RecordLifecycle(activeState, shadowState, now, key, note)
        activeState = tostring(activeState or "")
        shadowState = tostring(shadowState or "")
        local outcome = activeState == shadowState and "lifecycle-match" or "lifecycle-diff"
        bump(outcome)
        return append({
            kind = "lifecycle",
            outcome = outcome,
            at = tonumber(now) or 0,
            lifecycleKey = tostring(key or ""),
            activeState = activeState,
            shadowState = shadowState,
            note = tostring(note or ""),
        })
    end

    function api.RecordHotGeneration(now)
        return append({
            kind = "hot-generation",
            outcome = bump("hot-generation"),
            at = tonumber(now) or 0,
            runtimeGeneration = tonumber(R.generation) or 0,
            hotPayloadGeneration = tonumber(R.hotPayloadGeneration) or 0,
            hotPayloadRevision = tostring(R.hotPayloadRevision or ""),
            lastHotError = tostring(R.lastHotError or ""),
        })
    end

    function api.Recent(limit)
        limit = tonumber(limit) or 50
        if limit < 1 then limit = 1 end
        if limit > state.maxRows then limit = state.maxRows end
        local out = {}
        local first = table.getn(state.rows) - limit + 1
        if first < 1 then first = 1 end
        for i = first, table.getn(state.rows) do out[#out + 1] = state.rows[i] end
        return out
    end

    function api.Summary()
        local counts = {}
        for k, v in pairs(state.counts) do counts[k] = v end
        local compared = (tonumber(counts.match) or 0) +
            (tonumber(counts["shadow-extra"]) or 0) +
            (tonumber(counts["shadow-miss"]) or 0) +
            (tonumber(counts["different-candidate"]) or 0)
        local matched = tonumber(counts.match) or 0
        local matchPct = 0
        if compared > 0 then matchPct = matched * 100 / compared end
        return {
            rows = table.getn(state.rows),
            serial = state.serial,
            counts = counts,
            decisionCompared = compared,
            decisionMatched = matched,
            decisionMatchPct = matchPct,
        }
    end

    function api.RuntimeSnapshot()
        local modules = {}
        for name, row in pairs(R.modules or {}) do modules[name] = row.revision end
        return {
            generation = tonumber(R.generation) or 0,
            hotPayloadGeneration = tonumber(R.hotPayloadGeneration) or 0,
            hotPayloadRevision = tostring(R.hotPayloadRevision or ""),
            lastHotAppliedGeneration = tonumber(R.lastHotAppliedGeneration) or 0,
            lastHotError = tostring(R.lastHotError or ""),
            modules = modules,
        }
    end

    function api.Reset()
        state.rows = {}
        state.counts = {}
        return true
    end

    return api
end)
if not ok then error(R.lastHotError or "parity replacement failed") end
