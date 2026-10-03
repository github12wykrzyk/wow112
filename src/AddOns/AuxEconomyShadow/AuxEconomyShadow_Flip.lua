local R = W112_AH_SHADOW
if type(R) ~= "table" or type(R.ReplaceModule) ~= "function" then
    error("AuxEconomyShadow flip strategy requires persistent anchor")
end

local REVISION = "1-active-history-depth-parity"
local ok = R.ReplaceModule("flip", REVISION, function(state)
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

    local function historyFor(record, ctx)
        local key = tostring(record.historyKey or record.itemKey or record.itemId)
        local source = nil
        if type(ctx) == "table" and type(ctx.historyByKey) == "table" then
            source = ctx.historyByKey[key] or ctx.historyByKey[record.itemId]
        end
        if source == nil and type(ctx) == "table" and type(ctx.history) == "function" then
            local okHistory, value = pcall(ctx.history, record)
            if not okHistory then return nil, nil, key, "history-error" end
            source = value
        end
        if type(source) == "number" then return source, 0, key, nil end
        if type(source) ~= "table" then return nil, nil, key, "no-history" end
        local value = tonumber(source.value or source.unit or source.price)
        local days = tonumber(source.days or source.dataDays or source.data_days) or 0
        local overrideKey = source.key or source.historyKey or source.history_key
        if overrideKey ~= nil then key = tostring(overrideKey) end
        if not value or value <= 0 then return nil, days, key, "no-history" end
        return value, days, key, nil
    end

    local function sellerCount(row)
        local count = 0
        for _ in pairs(row.sellers) do count = count + 1 end
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

    local function sortedPrices(row)
        local prices = {}
        for unit in pairs(row.levels) do table.insert(prices, unit) end
        table.sort(prices, function(a, b) return a < b end)
        return prices
    end

    function api.ReferenceFloor(row, candidate, depthUnits)
        if type(row) ~= "table" or type(candidate) ~= "table" then return nil end
        local required = tonumber(depthUnits) or 10
        local ownCount = tonumber(candidate.record and candidate.record.count) or 0
        if ownCount > required then required = ownCount end
        if required < 1 then required = 1 end
        local units = 0
        local prices = sortedPrices(row)
        for i = 1, table.getn(prices) do
            local price = prices[i]
            local amount = tonumber(row.levels[price]) or 0
            if price == candidate.unitExact then amount = amount - ownCount end
            if amount > 0 then
                units = units + amount
                if units >= required then return price end
            end
        end
        return nil
    end

    function api.BuildBook(records, ctx)
        if type(records) ~= "table" then return nil, "records-unavailable" end
        local contracts = R.GetModule("contracts")
        if not contracts then return nil, "contracts-unavailable" end
        local book = { rows = {}, candidates = {}, count = 0 }
        for i = 1, table.getn(records) do
            local record = contracts.NormalizeAuction(records[i])
            if record and record.quality ~= 0 then
                local playerName = type(ctx) == "table" and tostring(ctx.playerName or "") or ""
                if playerName == "" or tostring(record.owner or "") ~= playerName then
                    local histValue, histDays, historyKey = historyFor(record, ctx or {})
                    local candidate = {
                        record = record,
                        histValue = histValue,
                        histDays = tonumber(histDays) or 0,
                        historyKey = historyKey,
                        unitExact = tonumber(record.unitExact) or 0,
                    }
                    local row = book.rows[historyKey]
                    if not row then
                        row = { key = historyKey, levels = {}, sellers = {}, candidates = {} }
                        book.rows[historyKey] = row
                    end
                    row.levels[candidate.unitExact] = (tonumber(row.levels[candidate.unitExact]) or 0) + record.count
                    local owner = tostring(record.owner or "")
                    if owner ~= "" then row.sellers[owner] = true end
                    table.insert(row.candidates, candidate)
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

        local maxBuyout = cfgValue(ctx, "flipMaxBuyout", 100000)
        if maxBuyout > 0 and record.buyout > maxBuyout then return nil, "max-buyout" end
        local minDays = cfgValue(ctx, "flipMinHistoryDays", 2)
        if histDays < minDays then return nil, "history-days" end
        local histMaxPct = cfgValue(ctx, "flipHistMaxPct", 70)
        if candidate.unitExact > histValue * histMaxPct / 100 then return nil, "history-entry" end
        local minSellers = cfgValue(ctx, "flipMinSellers", 3)
        if sellerCount(row) < minSellers then return nil, "seller-depth" end

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

        local depth = cfgValue(ctx, "flipDepthUnits", 10)
        if depth < 10 then depth = 10 end
        local floorPrice = api.ReferenceFloor(row, candidate, depth)
        if not floorPrice then return nil, "no-depth" end
        local grossExitUnit = floorPrice
        if grossExitUnit > 1 then grossExitUnit = grossExitUnit - 1 end
        if grossExitUnit > histValue then grossExitUnit = histValue end
        if grossExitUnit <= candidate.unitExact then return nil, "no-spread" end

        local cutPct = cfgValue(ctx, "flipAhCutPct", 5)
        local marginPct = cfgValue(ctx, "flipSafetyMarginPct", 25)
        local netUnit = math.floor(grossExitUnit * (100 - cutPct) / 100)
        local netExit = netUnit * record.count
        local profit = netExit - record.buyout
        local minProfit = cfgValue(ctx, "flipMinProfit", 1000)
        if profit < minProfit then return nil, "min-profit" end
        local maxEntry = math.floor(netExit * (100 - marginPct) / 100)
        if record.buyout > maxEntry then return nil, "safety-margin" end

        local money = tonumber(ctx.money) or 0
        local missing = record.buyout - money
        if missing < 0 then missing = 0 end
        state.accepted = state.accepted + 1
        return {
            mode = "auxarb_flip",
            route = "flip",
            name = record.name,
            itemId = record.itemId,
            count = record.count,
            buyout = record.buyout,
            unit = record.unit,
            unitExact = candidate.unitExact,
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
            for i = 1, table.getn(row.candidates) do
                local candidate = api.EvaluateCandidate(row.candidates[i], row, ctx)
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
if not ok then error(R.lastHotError or "flip replacement failed") end
