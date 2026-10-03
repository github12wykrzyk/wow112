local R = W112_AH_SHADOW
if type(R) ~= "table" or type(R.ReplaceModule) ~= "function" then
    error("AuxEconomyShadow candidate pipeline requires persistent anchor")
end

local REVISION = "1-vendor-de-pipeline"
local ok = R.ReplaceModule("pipeline", REVISION, function(state)
    state.evaluated = tonumber(state.evaluated) or 0
    state.accepted = tonumber(state.accepted) or 0
    state.strategyAccepted = type(state.strategyAccepted) == "table" and state.strategyAccepted or {}
    local api = {}
    api.revision = REVISION

    local STRATEGIES = { "vendor", "disenchant" }

    local function enabled(ctx, name)
        local map = ctx and ctx.enabledStrategies
        if type(map) ~= "table" then return true end
        return map[name] ~= false
    end

    local function better(contracts, a, b)
        if not b then return true end
        return contracts.BetterCandidate(a, b)
    end

    function api.Evaluate(raw, ctx)
        state.evaluated = state.evaluated + 1
        ctx = ctx or {}
        local contracts = R.GetModule("contracts")
        if not contracts then return nil, "contracts-unavailable" end
        local record, reason = contracts.NormalizeAuction(raw)
        if not record then return nil, reason end

        local candidates = {}
        local rejected = {}
        local best = nil
        local bestAffordable = nil

        for i = 1, table.getn(STRATEGIES) do
            local name = STRATEGIES[i]
            if enabled(ctx, name) then
                local strategy = R.GetModule(name)
                if not strategy or type(strategy.Evaluate) ~= "function" then
                    rejected[name] = "strategy-unavailable"
                else
                    local okEval, candidate, why = pcall(strategy.Evaluate, record, ctx)
                    if not okEval then
                        rejected[name] = "strategy-error:" .. tostring(candidate)
                    elseif candidate then
                        candidate.strategy = candidate.strategy or name
                        table.insert(candidates, candidate)
                        state.strategyAccepted[name] = (tonumber(state.strategyAccepted[name]) or 0) + 1
                        if better(contracts, candidate, best) then best = candidate end
                        if candidate.affordable and better(contracts, candidate, bestAffordable) then
                            bestAffordable = candidate
                        end
                    else
                        rejected[name] = tostring(why or "rejected")
                    end
                end
            else
                rejected[name] = "disabled"
            end
        end

        table.sort(candidates, function(a, b) return contracts.BetterCandidate(a, b) end)
        if best then state.accepted = state.accepted + 1 end
        return {
            record = record,
            candidates = candidates,
            best = best,
            bestAffordable = bestAffordable,
            rejected = rejected,
        }, nil
    end

    function api.EvaluateBook(bookOrName, ctx)
        local marketbook = R.GetModule("marketbook")
        if not marketbook then return nil, "marketbook-unavailable" end
        local records = marketbook.Records(bookOrName)
        if type(records) ~= "table" then return nil, "book-unavailable" end
        local rows = {}
        local best = nil
        local bestAffordable = nil
        local contracts = R.GetModule("contracts")
        if not contracts then return nil, "contracts-unavailable" end

        for i = 1, table.getn(records) do
            local result = api.Evaluate(records[i], ctx)
            if result then
                table.insert(rows, result)
                if result.best and better(contracts, result.best, best) then best = result.best end
                if result.bestAffordable and better(contracts, result.bestAffordable, bestAffordable) then
                    bestAffordable = result.bestAffordable
                end
            end
        end

        return {
            rows = rows,
            best = best,
            bestAffordable = bestAffordable,
            recordCount = table.getn(records),
        }, nil
    end

    function api.stats()
        local accepted = {}
        for name, count in pairs(state.strategyAccepted) do accepted[name] = count end
        return {
            evaluated = state.evaluated,
            accepted = state.accepted,
            strategyAccepted = accepted,
        }
    end

    return api
end)
if not ok then error(R.lastHotError or "pipeline replacement failed") end
