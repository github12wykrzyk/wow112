local R = W112_AH_SHADOW
if type(R) ~= "table" or type(R.ReplaceModule) ~= "function" then
    error("AuxEconomyShadow contracts require persistent anchor")
end

local REVISION = "2-normalized-listing"
local ok = R.ReplaceModule("contracts", REVISION, function(state)
    state.normalized = tonumber(state.normalized) or 0
    state.listings = tonumber(state.listings) or 0
    local api = {}
    api.revision = REVISION

    local function normalize(raw, allowBidOnly)
        if type(raw) ~= "table" then return nil, "no-record" end
        local itemId = tonumber(raw.itemId or raw.item_id)
        local count = tonumber(raw.count or raw.aux_quantity) or 0
        local buyout = tonumber(raw.buyout or raw.buyout_price) or 0
        local bidAmount = tonumber(raw.bidAmount or raw.bid_amount or raw.bid_price or raw.blizzard_bid or raw.start_price or raw.bid) or 0
        if not itemId then return nil, "no-item-id" end
        if count <= 0 then return nil, "no-count" end
        if buyout <= 0 and (not allowBidOnly or bidAmount <= 0) then
            return nil, allowBidOnly and "no-price" or "no-buyout"
        end
        local itemKey = tostring(raw.itemKey or raw.item_key or ("item:" .. tostring(itemId)))
        local out = {
            name = tostring(raw.name or ""),
            itemId = itemId,
            count = count,
            buyout = buyout,
            bidAmount = bidAmount,
            quality = tonumber(raw.quality),
            level = tonumber(raw.level) or 0,
            slot = raw.slot,
            owner = raw.owner,
            itemKey = itemKey,
            historyKey = tostring(raw.historyKey or raw.history_key or itemKey),
            suffixId = tonumber(raw.suffixId or raw.suffix_id) or 0,
            signature = raw.signature,
            sourcePage = tonumber(raw.sourcePage or raw.page) or 0,
            maxStack = tonumber(raw.maxStack or raw.max_stack) or 0,
            duration = tonumber(raw.duration) or 0,
            highBidder = raw.highBidder or raw.high_bidder,
        }
        if buyout > 0 then
            out.unit = math.floor(buyout / count)
            out.unitExact = tonumber(raw.unitExact or raw.unit_buyout_price) or (buyout / count)
        else
            out.unit = 0
            out.unitExact = 0
        end
        state.normalized = state.normalized + 1
        if allowBidOnly then state.listings = state.listings + 1 end
        return out, nil
    end

    function api.NormalizeListing(raw)
        return normalize(raw, true)
    end

    function api.NormalizeAuction(raw)
        return normalize(raw, false)
    end

    function api.Signature(record, includeOwner)
        if type(record) ~= "table" then return "" end
        local owner = includeOwner and tostring(record.owner or "") or ""
        return table.concat({
            tostring(record.name or ""), tostring(record.count or 0),
            tostring(record.buyout or 0), owner,
            tostring(record.quality or -1), tostring(record.level or 0),
            tostring(record.itemKey or ""),
        }, "|")
    end

    function api.BetterCandidate(a, b)
        if not a then return false end
        if not b then return true end
        local ap = tonumber(a.profit) or 0
        local bp = tonumber(b.profit) or 0
        if ap ~= bp then return ap > bp end
        return (tonumber(a.buyout) or 0) < (tonumber(b.buyout) or 0)
    end

    function api.stats()
        return { normalized = state.normalized, listings = state.listings }
    end

    return api
end)
if not ok then error(R.lastHotError or "contracts replacement failed") end
