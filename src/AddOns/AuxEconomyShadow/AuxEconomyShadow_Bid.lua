local R = W112_AH_SHADOW
if type(R) ~= "table" or type(R.ReplaceModule) ~= "function" then
    error("AuxEconomyShadow bid strategy requires persistent anchor")
end

local REVISION = "1-active-vendor-de-bid-parity"
local ok = R.ReplaceModule("bid", REVISION, function(state)
    state.evaluated = tonumber(state.evaluated) or 0
    state.accepted = tonumber(state.accepted) or 0
    state.vendorAccepted = tonumber(state.vendorAccepted) or 0
    state.deAccepted = tonumber(state.deAccepted) or 0
    local api = {}
    api.revision = REVISION

    local function cfgValue(ctx, key, default)
        local cfg = ctx and (ctx.config or ctx) or {}
        local value = tonumber(cfg[key])
        if value == nil then return default end
        return value
    end

    local function clampMargin(value)
        value = tonumber(value) or 0
        if value < 0 then return 0 end
        if value > 90 then return 90 end
        return value
    end

    local function prepare(raw, ctx)
        local contracts = R.GetModule("contracts")
        if not contracts then return nil, "contracts-unavailable" end
        local record, reason = contracts.NormalizeListing(raw)
        if not record then return nil, reason end
        if record.buyout > 0 then return nil, "has-buyout" end
        local playerName = tostring((ctx and ctx.playerName) or "")
        if playerName ~= "" and tostring(record.owner or "") == playerName then return nil, "own-auction" end
        if record.highBidder then return nil, "high-bidder" end
        local maxDuration = cfgValue(ctx, "bidMaxDuration", 1)
        if record.duration <= 0 or record.duration > maxDuration then return nil, "duration" end
        local amount = tonumber(record.bidAmount) or 0
        if amount <= 0 then return nil, "no-bid" end
        local maxAmount = cfgValue(ctx, "bidMaxAmount", 50000)
        if maxAmount > 0 and amount > maxAmount then return nil, "max-amount" end
        local signature = table.concat({
            tostring(record.name or ""), tostring(record.count or 0), tostring(amount),
            tostring(record.owner or ""), tostring(record.itemKey or ""), tostring(record.duration or 0),
        }, "|")
        local recentFn = ctx and (ctx.bidRecent or ctx.recent) or nil
        if type(recentFn) == "function" then
            local okRecent, recent = pcall(recentFn, signature)
            if not okRecent then return nil, "recent-check-error" end
            if recent then return nil, "recent" end
        end
        return record, signature
    end

    local function finish(record, signature, kind, value, maxBid, source, extra, ctx)
        local amount = tonumber(record.bidAmount) or 0
        local profit = value - amount
        local minProfit = cfgValue(ctx, "bidMinProfit", 1000)
        if profit < minProfit then return nil, "min-profit" end
        if amount > maxBid then return nil, "safety-margin" end
        local money = tonumber(ctx and ctx.money) or 0
        local placements = tonumber(ctx and ctx.sessionBids) or 0
        local maxPlacements = cfgValue(ctx, "bidMaxSessionPlacements", 10)
        local liveEligible = amount <= money and (maxPlacements <= 0 or placements < maxPlacements)
        local route = kind == "vendor" and "bid-vendor" or "bid-de"
        local out = {
            mode = "auxarb_bid",
            route = route,
            bidKind = kind,
            name = record.name,
            itemId = record.itemId,
            count = record.count,
            buyout = amount,
            bidAmount = amount,
            duration = record.duration,
            valuationTotal = value,
            profit = profit,
            maxBid = maxBid,
            source = tostring(source or ""),
            owner = record.owner,
            quality = record.quality,
            level = record.level,
            slot = record.slot,
            itemKey = record.itemKey,
            signature = signature,
            sourcePage = record.sourcePage,
            affordable = amount <= money,
            liveEligible = liveEligible,
            missing = amount > money and (amount - money) or 0,
        }
        if type(extra) == "table" then
            for key, val in pairs(extra) do out[key] = val end
        end
        return out, nil
    end

    function api.EvaluateVendor(raw, ctx)
        state.evaluated = state.evaluated + 1
        ctx = ctx or {}
        local record, signatureOrReason = prepare(raw, ctx)
        if not record then return nil, signatureOrReason end
        local vendor = R.GetModule("vendor")
        if not vendor or type(vendor.ResolveValue) ~= "function" then return nil, "vendor-unavailable" end
        local vendorUnit, vendorSource = vendor.ResolveValue(record.itemId, ctx)
        vendorUnit = tonumber(vendorUnit) or 0
        if vendorUnit <= 0 then return nil, "no-vendor" end
        local value = vendorUnit * record.count
        local margin = clampMargin(cfgValue(ctx, "bidVendorMarginPct", 20))
        local maxBid = math.floor(value * (100 - margin) / 100)
        local candidate, reason = finish(record, signatureOrReason, "vendor", value, maxBid, vendorSource, {
            vendorUnit = vendorUnit,
            bidMarginPct = margin,
        }, ctx)
        if candidate then
            state.accepted = state.accepted + 1
            state.vendorAccepted = state.vendorAccepted + 1
        end
        return candidate, reason
    end

    function api.EvaluateDisenchant(raw, ctx)
        state.evaluated = state.evaluated + 1
        ctx = ctx or {}
        local record, signatureOrReason = prepare(raw, ctx)
        if not record then return nil, signatureOrReason end
        local disenchant = R.GetModule("disenchant")
        if not disenchant or type(disenchant.Evaluate) ~= "function" then return nil, "disenchant-unavailable" end
        local fake = {
            name = record.name,
            itemId = record.itemId,
            count = record.count,
            buyout = record.bidAmount,
            quality = record.quality,
            level = record.level,
            slot = record.slot,
            owner = record.owner,
            itemKey = record.itemKey,
            historyKey = record.historyKey,
            signature = signatureOrReason,
            sourcePage = record.sourcePage,
            maxStack = record.maxStack,
        }
        local de, reason = disenchant.Evaluate(fake, ctx)
        if not de then return nil, reason or "no-de" end
        local value = tonumber(de.deValue or de.valuationTotal) or 0
        if value <= 0 then return nil, "no-de-value" end
        local margin = clampMargin(cfgValue(ctx, "bidDeMarginPct", 40))
        local deMargin = tonumber(de.deMarginPct) or 0
        if deMargin > margin then margin = deMargin end
        margin = clampMargin(margin)
        local maxBid = math.floor(value * (100 - margin) / 100)
        local candidate, finishReason = finish(record, signatureOrReason, "de", value, maxBid, de.deSource or "de-live", {
            bidMarginPct = margin,
            deMarginPct = deMargin,
            deDepthUnits = de.deDepthUnits,
            materials = de.materials,
        }, ctx)
        if candidate then
            state.accepted = state.accepted + 1
            state.deAccepted = state.deAccepted + 1
        end
        return candidate, finishReason
    end

    function api.Evaluate(raw, ctx)
        local contracts = R.GetModule("contracts")
        if not contracts then return nil, "contracts-unavailable" end
        local vendorCandidate = api.EvaluateVendor(raw, ctx)
        local deCandidate = api.EvaluateDisenchant(raw, ctx)
        if deCandidate and contracts.BetterCandidate(deCandidate, vendorCandidate) then return deCandidate, nil end
        if vendorCandidate then return vendorCandidate, nil end
        if deCandidate then return deCandidate, nil end
        return nil, "no-bid-candidate"
    end

    function api.BestFromRecords(records, ctx)
        if type(records) ~= "table" then return nil, nil, "records-unavailable" end
        local contracts = R.GetModule("contracts")
        if not contracts then return nil, nil, "contracts-unavailable" end
        local best = nil
        local bestLive = nil
        for i = 1, table.getn(records) do
            local candidate = api.Evaluate(records[i], ctx)
            if candidate and contracts.BetterCandidate(candidate, best) then best = candidate end
            if candidate and candidate.liveEligible and contracts.BetterCandidate(candidate, bestLive) then bestLive = candidate end
        end
        return best, bestLive, nil
    end

    function api.stats()
        return {
            evaluated = state.evaluated,
            accepted = state.accepted,
            vendorAccepted = state.vendorAccepted,
            deAccepted = state.deAccepted,
        }
    end

    return api
end)
if not ok then error(R.lastHotError or "bid replacement failed") end
