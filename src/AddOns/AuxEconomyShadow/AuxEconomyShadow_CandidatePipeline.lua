local R = W112_AH_SHADOW
if type(R) ~= "table" or type(R.ReplaceModule) ~= "function" then
    error("AuxEconomyShadow candidate pipeline requires persistent anchor")
end

local REVISION = "2-full-economy-strategy-pipeline"
local ok = R.ReplaceModule("pipeline", REVISION, function(state)
    state.evaluated = tonumber(state.evaluated) or 0
    state.accepted = tonumber(state.accepted) or 0
    state.strategyAccepted = type(state.strategyAccepted) == "table" and state.strategyAccepted or {}
    local api = {}
    api.revision = REVISION

    local ROW_STRATEGIES = { "vendor", "disenchant" }

    local function enabled(ctx, name)
        local map = ctx and ctx.enabledStrategies
        if type(map) ~= "table" then return true end
        return map[name] ~= false
    end

    local function better(contracts, a, b)
        if not a then return false end
        if not b then return true end
        return contracts.BetterCandidate(a, b)
    end

    local function rememberBest(contracts, map, candidate)
        if not candidate then return end
        local name = tostring(candidate.strategy or candidate.route or "unknown")
        if better(contracts, candidate, map[name]) then map[name] = candidate end
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

        for i = 1, table.getn(ROW_STRATEGIES) do
            local name = ROW_STRATEGIES[i]
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
        ctx = ctx or {}
        local marketbook = R.GetModule("marketbook")
        if not marketbook then return nil, "marketbook-unavailable" end
        local records = marketbook.Records(bookOrName)
        if type(records) ~= "table" then return nil, "book-unavailable" end
        local contracts = R.GetModule("contracts")
        if not contracts then return nil, "contracts-unavailable" end

        local rows = {}
        local best = nil
        local bestAffordable = nil
        local strategyBest = {}
        local strategyBestAffordable = {}

        for i = 1, table.getn(records) do
            local result = api.Evaluate(records[i], ctx)
            if result then
                table.insert(rows, result)
                for j = 1, table.getn(result.candidates) do
                    local candidate = result.candidates[j]
                    rememberBest(contracts, strategyBest, candidate)
                    if candidate.affordable then rememberBest(contracts, strategyBestAffordable, candidate) end
                end
                if result.best and better(contracts, result.best, best) then best = result.best end
                if result.bestAffordable and better(contracts, result.bestAffordable, bestAffordable) then
                    bestAffordable = result.bestAffordable
                end
            end
        end

        local flipBook = nil
        if enabled(ctx, "flip") then
            local flip = R.GetModule("flip")
            if flip and type(flip.BuildBook) == "function" and type(flip.BestFromBook) == "function" then
                flipBook = flip.BuildBook(records, ctx)
                if flipBook then
                    local flipBest, flipLive = flip.BestFromBook(flipBook, ctx)
                    if flipBest then
                        flipBest.strategy = "flip"
                        strategyBest.flip = flipBest
                        state.strategyAccepted.flip = (tonumber(state.strategyAccepted.flip) or 0) + 1
                        if better(contracts, flipBest, best) then best = flipBest end
                    end
                    if flipLive then
                        flipLive.strategy = "flip"
                        strategyBestAffordable.flip = flipLive
                        if better(contracts, flipLive, bestAffordable) then bestAffordable = flipLive end
                    end
                end
            end
        end

        if enabled(ctx, "stack") then
            local stack = R.GetModule("stack")
            if stack and type(stack.BuildBook) == "function" and type(stack.BestFromBook) == "function" then
                local stackBook = stack.BuildBook(records, ctx)
                if stackBook then
                    local stackBest, stackLive = stack.BestFromBook(stackBook, ctx)
                    if stackBest then
                        stackBest.strategy = "stack"
                        strategyBest.stack = stackBest
                        state.strategyAccepted.stack = (tonumber(state.strategyAccepted.stack) or 0) + 1
                        if better(contracts, stackBest, best) then best = stackBest end
                    end
                    if stackLive then
                        stackLive.strategy = "stack"
                        strategyBestAffordable.stack = stackLive
                        if better(contracts, stackLive, bestAffordable) then bestAffordable = stackLive end
                    end
                end
            end
        end

        local bestBid = nil
        local bestBidLive = nil
        if enabled(ctx, "bid") then
            local bid = R.GetModule("bid")
            if bid and type(bid.BestFromRecords) == "function" then
                bestBid, bestBidLive = bid.BestFromRecords(records, ctx)
                if bestBid then
                    bestBid.strategy = "bid"
                    strategyBest.bid = bestBid
                    state.strategyAccepted.bid = (tonumber(state.strategyAccepted.bid) or 0) + 1
                end
                if bestBidLive then
                    bestBidLive.strategy = "bid"
                    strategyBestAffordable.bid = bestBidLive
                end
            end
        end

        local postscanBest = nil
        local postscanBestAffordable = nil
        local buyoutNames = { "disenchant", "flip", "stack" }
        for i = 1, table.getn(buyoutNames) do
            local name = buyoutNames[i]
            local candidate = strategyBest[name]
            if candidate and better(contracts, candidate, postscanBest) then postscanBest = candidate end
            local live = strategyBestAffordable[name]
            if live and better(contracts, live, postscanBestAffordable) then postscanBestAffordable = live end
        end

        local selectedPostscan = postscanBestAffordable
        local selectionSource = selectedPostscan and "buyout" or nil
        if not selectedPostscan and bestBidLive then
            selectedPostscan = bestBidLive
            selectionSource = "bid-fallback"
        end

        return {
            rows = rows,
            best = best,
            bestAffordable = bestAffordable,
            strategyBest = strategyBest,
            strategyBestAffordable = strategyBestAffordable,
            postscanBest = postscanBest,
            postscanBestAffordable = postscanBestAffordable,
            bestBid = bestBid,
            bestBidLive = bestBidLive,
            selectedPostscan = selectedPostscan,
            selectionSource = selectionSource,
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
