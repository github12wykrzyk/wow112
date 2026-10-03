local R = W112_AH_SHADOW
if type(R) ~= "table" or type(R.ReplaceModule) ~= "function" then
    error("AuxEconomyShadow vendor strategy requires persistent anchor")
end

local REVISION = "1-current-rollback-parity"
local ok = R.ReplaceModule("vendor", REVISION, function(state)
    state.evaluated = tonumber(state.evaluated) or 0
    state.accepted = tonumber(state.accepted) or 0
    local api = {}
    api.revision = REVISION

    local function valueFor(itemId, ctx)
        local learned = 0
        local merchantSell = ctx and ctx.merchantSell
        if type(merchantSell) == "table" then learned = tonumber(merchantSell[itemId]) or 0 end
        if learned > 0 then return learned, "aux-learned" end

        local fallback = ctx and ctx.vendorValues
        local static = type(fallback) == "table" and (tonumber(fallback[itemId]) or 0) or 0
        if static > 0 then return static, "turtle-db" end
        return 0, (ctx and ctx.vendorTrustedOnly) and "trusted-missing" or "none"
    end

    function api.ResolveValue(itemId, ctx)
        return valueFor(tonumber(itemId), ctx or {})
    end

    function api.Evaluate(raw, ctx)
        state.evaluated = state.evaluated + 1
        ctx = ctx or {}
        local contracts = R.GetModule("contracts")
        if not contracts then return nil, "contracts-unavailable" end
        local record, reason = contracts.NormalizeAuction(raw)
        if not record then return nil, reason end
        if record.quality == 0 then return nil, "grey" end

        local vendorUnit, vendorSource = valueFor(record.itemId, ctx)
        if vendorUnit <= 0 then return nil, "no-vendor-value" end

        local vendorTotal = vendorUnit * record.count
        local profit = vendorTotal - record.buyout
        local cfg = ctx.config or ctx
        local minProfit = tonumber(cfg.vendorMinProfit) or 0
        local maxBuyout = tonumber(cfg.vendorMaxBuyout) or 0
        if profit < minProfit then return nil, "min-profit" end
        if maxBuyout > 0 and record.buyout > maxBuyout then return nil, "max-buyout" end

        local signature = record.signature or contracts.Signature(record, true)
        if type(ctx.recent) == "function" then
            local okRecent, isRecent = pcall(ctx.recent, signature)
            if not okRecent then return nil, "recent-check-error" end
            if isRecent then return nil, "recent" end
        end

        local money = tonumber(ctx.money) or 0
        local missing = record.buyout - money
        if missing < 0 then missing = 0 end
        state.accepted = state.accepted + 1
        return {
            mode = "vendor",
            route = "vendor",
            name = record.name,
            itemId = record.itemId,
            count = record.count,
            buyout = record.buyout,
            unit = record.unit,
            vendorUnit = vendorUnit,
            vendorSource = vendorSource,
            vendorTotal = vendorTotal,
            valuationTotal = vendorTotal,
            profit = profit,
            owner = record.owner,
            quality = record.quality,
            level = record.level,
            itemKey = record.itemKey,
            signature = signature,
            sourcePage = record.sourcePage,
            affordable = record.buyout <= money,
            missing = missing,
        }, nil
    end

    function api.stats()
        return { evaluated = state.evaluated, accepted = state.accepted }
    end

    return api
end)
if not ok then error(R.lastHotError or "vendor replacement failed") end
