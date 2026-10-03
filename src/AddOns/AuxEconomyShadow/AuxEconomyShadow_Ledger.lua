local R = W112_AH_SHADOW
if type(R) ~= "table" or type(R.ReplaceModule) ~= "function" then
    error("AuxEconomyShadow ledger requires persistent anchor")
end

local REVISION = "1-pure-ledger"
local ok = R.ReplaceModule("ledger", REVISION, function(state)
    state.rows = type(state.rows) == "table" and state.rows or {}
    state.maxRows = tonumber(state.maxRows) or 500
    state.serial = tonumber(state.serial) or 0
    local api = {}
    api.revision = REVISION

    local function trim()
        while table.getn(state.rows) > state.maxRows do table.remove(state.rows, 1) end
    end

    function api.SetMaxRows(value)
        value = tonumber(value) or state.maxRows
        if value < 50 then value = 50 end
        if value > 5000 then value = 5000 end
        state.maxRows = math.floor(value)
        trim()
        return state.maxRows
    end

    function api.Record(kind, row)
        row = type(row) == "table" and row or {}
        state.serial = state.serial + 1
        local copy = {
            serial = state.serial,
            kind = tostring(kind or row.kind or "event"),
            at = tonumber(row.at) or 0,
            route = tostring(row.route or ""),
            itemId = tonumber(row.itemId) or 0,
            name = tostring(row.name or ""),
            amount = tonumber(row.amount) or 0,
            value = tonumber(row.value) or 0,
            expectedProfit = tonumber(row.expectedProfit or row.profit) or 0,
            actualProfit = tonumber(row.actualProfit) or 0,
            status = tostring(row.status or ""),
            note = tostring(row.note or ""),
        }
        table.insert(state.rows, copy)
        trim()
        return copy
    end

    function api.Recent(limit)
        limit = tonumber(limit) or 50
        if limit < 1 then limit = 1 end
        if limit > state.maxRows then limit = state.maxRows end
        local out = {}
        local first = table.getn(state.rows) - limit + 1
        if first < 1 then first = 1 end
        for i = first, table.getn(state.rows) do table.insert(out, state.rows[i]) end
        return out
    end

    function api.Summary()
        local totals = { rows = table.getn(state.rows), spent = 0, value = 0, expectedProfit = 0, actualProfit = 0, byKind = {} }
        for i = 1, table.getn(state.rows) do
            local row = state.rows[i]
            totals.spent = totals.spent + (tonumber(row.amount) or 0)
            totals.value = totals.value + (tonumber(row.value) or 0)
            totals.expectedProfit = totals.expectedProfit + (tonumber(row.expectedProfit) or 0)
            totals.actualProfit = totals.actualProfit + (tonumber(row.actualProfit) or 0)
            local kind = tostring(row.kind or "event")
            totals.byKind[kind] = (tonumber(totals.byKind[kind]) or 0) + 1
        end
        return totals
    end

    function api.Reset()
        state.rows = {}
        return true
    end

    return api
end)
if not ok then error(R.lastHotError or "ledger replacement failed") end
