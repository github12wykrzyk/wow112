local R = W112_AH_SHADOW
if type(R) ~= "table" or type(R.ReplaceModule) ~= "function" then
    error("AuxEconomyShadow disenchant strategy requires persistent anchor")
end

local REVISION = "1-live-depth-no-history-cap"
local ok = R.ReplaceModule("disenchant", REVISION, function(state)
    state.evaluated = tonumber(state.evaluated) or 0
    state.accepted = tonumber(state.accepted) or 0
    local api = {}
    api.revision = REVISION

    function api.NewMaterialBook()
        return {}
    end

    function api.AddMaterialOffer(book, itemId, name, count, buyout, allowedMaterialIds)
        itemId = tonumber(itemId)
        count = tonumber(count) or 0
        buyout = tonumber(buyout) or 0
        if type(book) ~= "table" or not itemId or count <= 0 or buyout <= 0 then return false end
        if type(allowedMaterialIds) == "table" and not allowedMaterialIds[itemId] then return false end
        local unit = math.floor(buyout / count)
        if unit <= 0 then return false end
        local row = book[itemId]
        if not row then
            row = { name = tostring(name or ""), units = 0, offers = {}, depthCache = {}, warm = false }
            book[itemId] = row
        elseif row.name == "" and name then
            row.name = tostring(name)
        end
        table.insert(row.offers, { unit = unit, count = count })
        row.units = (tonumber(row.units) or 0) + count
        row.depthCache = {}
        return true
    end

    function api.DepthPrice(book, itemId, depth)
        itemId = tonumber(itemId)
        depth = tonumber(depth) or 3
        if depth < 1 then depth = 1 end
        local row = type(book) == "table" and book[itemId] or nil
        if not row or (tonumber(row.units) or 0) < depth then return nil, row end
        row.depthCache = row.depthCache or {}
        if row.depthCache[depth] then return row.depthCache[depth], row end
        table.sort(row.offers, function(a, b)
            if a.unit ~= b.unit then return a.unit < b.unit end
            return a.count > b.count
        end)
        local units = 0
        for i = 1, table.getn(row.offers) do
            units = units + (tonumber(row.offers[i].count) or 0)
            if units >= depth then
                row.depthCache[depth] = row.offers[i].unit
                return row.offers[i].unit, row
            end
        end
        return nil, row
    end

    local function clamp(value, low, high)
        value = tonumber(value) or low
        if value < low then return low end
        if value > high then return high end
        return value
    end

    function api.Evaluate(raw, ctx)
        state.evaluated = state.evaluated + 1
        ctx = ctx or {}
        local contracts = R.GetModule("contracts")
        if not contracts then return nil, "contracts-unavailable" end
        local record, reason = contracts.NormalizeAuction(raw)
        if not record then return nil, reason end
        if record.quality ~= 2 and record.quality ~= 3 and record.quality ~= 4 then return nil, "not-de-quality" end
        if not record.slot then return nil, "not-de-slot" end

        local cfg = ctx.config or ctx
        local maxBuyout = tonumber(cfg.deMaxBuyout) or 0
        if maxBuyout > 0 and record.buyout > maxBuyout then return nil, "max-buyout" end
        if type(ctx.disenchantBlocked) == "table" and ctx.disenchantBlocked[record.itemId] then
            return nil, "disenchant-blocked"
        end

        local signature = record.signature or contracts.Signature(record, false)
        if type(ctx.recent) == "function" then
            local okRecent, isRecent = pcall(ctx.recent, signature)
            if not okRecent then return nil, "recent-check-error" end
            if isRecent then return nil, "recent" end
        end

        if type(ctx.distribution) ~= "function" then return nil, "distribution-unavailable" end
        local okDist, dist, deSource, disenchantId, distReason = pcall(ctx.distribution, record)
        if not okDist then return nil, "distribution-error" end
        if type(dist) ~= "table" or table.getn(dist) == 0 then return nil, distReason or "no-distribution" end

        local depth = tonumber(cfg.deDepthUnits) or 3
        if depth < 1 then depth = 1 end
        local cutPct = clamp(cfg.deAhCutPct or 5, 0, 30)
        local baseMarginPct = clamp(cfg.deSafetyMarginPct or 25, 0, 90)
        local book = ctx.materialBook
        if type(book) ~= "table" then return nil, "material-book-unavailable" end

        local grossExpected = 0
        local netExpected = 0
        local mats = {}
        local seen = {}
        local usedWarm = false
        for i = 1, table.getn(dist) do
            local event = dist[i]
            local matId = tonumber(event and event.item_id)
            if not matId then return nil, "invalid-material" end
            local floorPrice, row = api.DepthPrice(book, matId, depth)
            if not floorPrice or not row or not row.name or row.name == "" then
                return nil, "no-depth:" .. tostring(matId)
            end
            if row.warm then usedWarm = true end
            local probability = tonumber(event.probability) or 0
            local avgQty = ((tonumber(event.min_quantity) or 0) + (tonumber(event.max_quantity) or 0)) / 2
            local netUnit = math.floor(floorPrice * (100 - cutPct) / 100)
            local grossContribution = probability * avgQty * floorPrice
            local netContribution = probability * avgQty * netUnit
            grossExpected = grossExpected + grossContribution
            netExpected = netExpected + netContribution
            local matIndex = seen[matId]
            if not matIndex then
                table.insert(mats, {
                    itemId = matId,
                    name = row.name,
                    floor = floorPrice,
                    net = netUnit,
                    probability = probability,
                    avgQty = avgQty,
                    netContribution = netContribution,
                })
                seen[matId] = table.getn(mats)
            else
                mats[matIndex].netContribution = (tonumber(mats[matIndex].netContribution) or 0) + netContribution
            end
        end
        if netExpected <= 0 then return nil, "no-value" end

        local marginPct = baseMarginPct
        local maxOwnSharePct = 0
        local maxOwnUnits = 0
        if cfg.deExposureGuard then
            if not ctx.exposureReady then return nil, "exposure-unavailable" end
            local ownBook = ctx.exposureBook or {}
            local minEvPct = tonumber(cfg.deExposureMinEvPct) or 15
            local shareSoft = tonumber(cfg.deExposureShareSoftPct) or 20
            local shareHard = tonumber(cfg.deExposureShareHardPct) or 35
            local shareBlock = tonumber(cfg.deExposureBlockPct) or 50
            local marginSoft = tonumber(cfg.deExposureSoftMarginPct) or 30
            local marginHard = tonumber(cfg.deExposureHardMarginPct) or 35
            local maxOwnStacks = tonumber(cfg.deExposureMaxOwnStacks) or 2
            if maxOwnStacks < 1 then maxOwnStacks = 1 end

            for i = 1, table.getn(mats) do
                local mat = mats[i]
                local marketRow = book[mat.itemId]
                local own = ownBook[mat.itemId] or {}
                local marketUnits = tonumber(marketRow and marketRow.units) or 0
                local ownUnits = tonumber(own.units) or 0
                local maxStack = tonumber(own.maxStack) or 20
                if maxStack < 1 then maxStack = 20 end
                local ownUnitCap = math.max(1, math.floor(maxStack * maxOwnStacks))
                local ownSharePct = 0
                if marketUnits > 0 then ownSharePct = ownUnits * 100 / marketUnits end
                if ownSharePct > 100 then ownSharePct = 100 end
                local evSharePct = (tonumber(mat.netContribution) or 0) * 100 / netExpected
                mat.evSharePct = evSharePct
                mat.marketUnits = marketUnits
                mat.ownUnits = ownUnits
                mat.ownAuctions = tonumber(own.auctions) or 0
                mat.ownAuctionValue = tonumber(own.buyout) or 0
                mat.ownUnitCap = ownUnitCap
                mat.ownSharePct = ownSharePct
                if ownSharePct > maxOwnSharePct then maxOwnSharePct = ownSharePct end
                if ownUnits > maxOwnUnits then maxOwnUnits = ownUnits end
                if evSharePct >= minEvPct then
                    if ownUnits >= ownUnitCap then return nil, "exposure-units:" .. tostring(mat.itemId) end
                    if ownSharePct > shareBlock then
                        return nil, "exposure-share:" .. tostring(mat.itemId)
                    elseif ownSharePct >= shareHard then
                        if marginHard > marginPct then marginPct = marginHard end
                    elseif ownSharePct >= shareSoft then
                        if marginSoft > marginPct then marginPct = marginSoft end
                    end
                end
            end
        end

        local grossTotal = math.floor(grossExpected * record.count)
        local netTotal = math.floor(netExpected * record.count)
        local profit = netTotal - record.buyout
        local minProfit = tonumber(cfg.deMinProfit) or 0
        local maxEntry = math.floor(netTotal * (100 - marginPct) / 100)
        if profit < minProfit then return nil, "min-profit" end
        if record.buyout > maxEntry then return nil, "safety-margin" end

        local money = tonumber(ctx.money) or 0
        local missing = record.buyout - money
        if missing < 0 then missing = 0 end
        state.accepted = state.accepted + 1
        return {
            mode = "auxarb_de",
            route = "disenchant",
            name = record.name,
            itemId = record.itemId,
            count = record.count,
            buyout = record.buyout,
            unit = record.unit,
            deGross = grossTotal,
            deValue = netTotal,
            valuationTotal = netTotal,
            profit = profit,
            owner = record.owner,
            quality = record.quality,
            level = record.level,
            slot = record.slot,
            itemKey = record.itemKey,
            signature = signature,
            ignoreOwnerSignature = true,
            sourcePage = record.sourcePage,
            affordable = record.buyout <= money,
            missing = missing,
            deDepthUnits = depth,
            deCutPct = cutPct,
            deBaseMarginPct = baseMarginPct,
            deMarginPct = marginPct,
            deExposureMaxSharePct = maxOwnSharePct,
            deExposureMaxOwnUnits = maxOwnUnits,
            deMaxEntry = maxEntry,
            materials = mats,
            deSource = tostring(deSource or ""),
            disenchantId = tonumber(disenchantId) or 0,
            deWarmPrefilter = usedWarm,
        }, nil
    end

    function api.stats()
        return { evaluated = state.evaluated, accepted = state.accepted }
    end

    return api
end)
if not ok then error(R.lastHotError or "disenchant replacement failed") end
