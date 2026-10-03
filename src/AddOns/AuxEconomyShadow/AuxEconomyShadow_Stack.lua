local R = W112_AH_SHADOW
if type(R) ~= "table" or type(R.ReplaceModule) ~= "function" then
    error("AuxEconomyShadow stack strategy requires persistent anchor")
end

local REVISION = "1-active-small-large-parity"
local ok = R.ReplaceModule("stack", REVISION, function(state)
    state.evaluated = tonumber(state.evaluated) or 0
    state.accepted = tonumber(state.accepted) or 0
    state.booksBuilt = tonumber(state.booksBuilt) or 0
    local api = {}
    api.revision = REVISION

    local function cfgValue(ctx, key, default)
        local cfg = ctx and (ctx.config or ctx) or {}
        local value = tonumber(cfg[key])
        if value == nil then return default end
        return value
    end

    local function sellerCount(row)
        local count = 0
        for _ in pairs(row.smallSellers) do count = count + 1 end
        return count
    end

    local function exposureFor(candidate, ctx)
        local book = type(ctx) == "table" and ctx.itemExposure or nil
        if type(book) ~= "table" then return 0, 0 end
        local row = book[candidate.historyKey] or book[candidate.record.itemId] or {}
        return tonumber(row.spend) or 0, tonumber(row.buys) or 0
    end

    local function isRecent(signature, ctx)
        if type(ctx) ~= "table" or type(ctx.recent) ~= "function" then return false, nil end
        local okRecent, recent = pcall(ctx.recent, signature)
        if not okRecent then return false, "recent-check-error" end
        return recent and true or false, nil
    end

    function api.ReferenceFloor(row, depthUnits)
        if type(row) ~= "table" or type(row.smallOffers) ~= "table" then return nil end
        local required = tonumber(depthUnits) or 10
        if required < 1 then required = 1 end
        local offers = {}
        for i = 1, table.getn(row.smallOffers) do offers[i] = row.smallOffers[i] end
        table.sort(offers, function(a, b)
            if a.unitExact ~= b.unitExact then return a.unitExact < b.unitExact end
            return a.count > b.count
        end)
        local units = 0
        for i = 1, table.getn(offers) do
            units = units + (tonumber(offers[i].count) or 0)
            if units >= required then return offers[i].unitExact end
        end
        return nil
    end

    function api.BuildBook(records, ctx)
        local flip = R.GetModule("flip")
        if not flip or type(flip.BuildBook) ~= "function" then return nil, "flip-unavailable" end
        local base, reason = flip.BuildBook(records, ctx)
        if not base then return nil, reason end
        local book = { rows = {}, candidates = {}, count = 0 }
        local smallPct = cfgValue(ctx, "stackSmallPct", 25)
        local largePct = cfgValue(ctx, "stackLargePct", 75)

        for i = 1, table.getn(base.candidates) do
            local candidate = base.candidates[i]
            local record = candidate.record
            local maxStack = tonumber(record.maxStack) or 0
            if maxStack >= 5 then
                local smallMax = math.floor(maxStack * smallPct / 100)
                if smallMax < 1 then smallMax = 1 end
                if smallMax >= maxStack then smallMax = maxStack - 1 end
                local largeMin = math.ceil(maxStack * largePct / 100)
                if largeMin <= smallMax then largeMin = smallMax + 1 end
                if largeMin > maxStack then largeMin = maxStack end

                local row = book.rows[candidate.historyKey]
                if not row then
                    row = { key = candidate.historyKey, smallOffers = {}, smallSellers = {}, largeCandidates = {} }
                    book.rows[candidate.historyKey] = row
                end
                if record.count <= smallMax then
                    table.insert(row.smallOffers, {
                        unitExact = candidate.unitExact,
                        count = record.count,
                        owner = record.owner,
                    })
                    local owner = tostring(record.owner or "")
                    if owner ~= "" then row.smallSellers[owner] = true end
                end
                if record.count >= largeMin then
                    candidate.smallMax = smallMax
                    candidate.largeMin = largeMin
                    table.insert(row.largeCandidates, candidate)
                    table.insert(book.candidates, candidate)
                    book.count = book.count + 1
                end
            end
        end
        state.booksBuilt = state.booksBuilt + 1
        return book, nil
    end

    function api.EvaluateCandidate(candidate, row, ctx)
        state.evaluated = state.evaluated + 1
        ctx = ctx or {}
        if type(candidate) ~= "table" or type(candidate.record) ~= "table" then return nil, "no-candidate" end
        local record = candidate.record
        local histValue = tonumber(candidate.histValue) or 0
        local histDays = tonumber(candidate.histDays) or 0
        if histValue <= 0 then return nil, "no-history" end

        local maxBuyout = cfgValue(ctx, "stackMaxBuyout", 100000)
        if maxBuyout > 0 and record.buyout > maxBuyout then return nil, "max-buyout" end
        local minDays = cfgValue(ctx, "stackMinHistoryDays", 2)
        if histDays < minDays then return nil, "history-days" end
        local minSellers = cfgValue(ctx, "stackMinSmallSellers", 3)
        if sellerCount(row) < minSellers then return nil, "small-seller-depth" end

        local contracts = R.GetModule("contracts")
        if not contracts then return nil, "contracts-unavailable" end
        local signature = record.signature or contracts.Signature(record, true)
        local recent, recentError = isRecent(signature, ctx)
        if recentError then return nil, recentError end
        if recent then return nil, "recent" end

        local spend, buys = exposureFor(candidate, ctx)
        local maxSpend = cfgValue(ctx, "flipMaxItemSpend", 200000)
        local maxBuys = cfgValue(ctx, "flipMaxItemBuys", 3)
        if maxSpend > 0 and spend + record.buyout > maxSpend then return nil, "item-budget" end
        if maxBuys > 0 and buys >= maxBuys then return nil, "item-buy-cap" end

        local depth = cfgValue(ctx, "stackSmallDepthUnits", 10)
        local floorPrice = api.ReferenceFloor(row, depth)
        if not floorPrice then return nil, "no-small-depth" end
        local grossExitUnit = floorPrice
        if grossExitUnit > 1 then grossExitUnit = grossExitUnit - 1 end
        if grossExitUnit > histValue then grossExitUnit = histValue end
        if grossExitUnit <= candidate.unitExact then return nil, "no-spread" end

        local cutPct = cfgValue(ctx, "stackAhCutPct", 5)
        local marginPct = cfgValue(ctx, "stackSafetyMarginPct", 25)
        local netUnit = math.floor(grossExitUnit * (100 - cutPct) / 100)
        local netExit = netUnit * record.count
        local profit = netExit - record.buyout
        local minProfit = cfgValue(ctx, "stackMinProfit", 1000)
        if profit < minProfit then return nil, "min-profit" end
        local maxEntry = math.floor(netExit * (100 - marginPct) / 100)
        if record.buyout > maxEntry then return nil, "safety-margin" end

        local money = tonumber(ctx.money) or 0
        local missing = record.buyout - money
        if missing < 0 then missing = 0 end
        state.accepted = state.accepted + 1
        return {
            mode = "auxarb_stack",
            route = "stack",
            name = record.name,
            itemId = record.itemId,
            count = record.count,
            buyout = record.buyout,
            unit = record.unit,
            unitExact = candidate.unitExact,
            maxStack = record.maxStack,
            smallMax = candidate.smallMax,
            largeMin = candidate.largeMin,
            historyKey = candidate.historyKey,
            histValue = histValue,
            histDays = histDays,
            referenceFloor = floorPrice,
            grossExitUnit = grossExitUnit,
            netExitUnit = netUnit,
            valuationTotal = netExit,
            profit = profit,
            maxEntry = maxEntry,
            owner = record.owner,
            itemKey = record.itemKey,
            signature = signature,
            sourcePage = record.sourcePage,
            affordable = record.buyout <= money,
            missing = missing,
        }, nil
    end

    function api.BestFromBook(book, ctx)
        if type(book) ~= "table" or type(book.rows) ~= "table" then return nil, "book-unavailable" end
        local contracts = R.GetModule("contracts")
        if not contracts then return nil, "contracts-unavailable" end
        local best = nil
        local bestAffordable = nil
        for _, row in pairs(book.rows) do
            for i = 1, table.getn(row.largeCandidates) do
                local candidate = api.EvaluateCandidate(row.largeCandidates[i], row, ctx)
                if candidate and contracts.BetterCandidate(candidate, best) then best = candidate end
                if candidate and candidate.affordable and contracts.BetterCandidate(candidate, bestAffordable) then
                    bestAffordable = candidate
                end
            end
        end
        return best, bestAffordable
    end

    function api.stats()
        return { evaluated = state.evaluated, accepted = state.accepted, booksBuilt = state.booksBuilt }
    end

    return api
end)
if not ok then error(R.lastHotError or "stack replacement failed") end
