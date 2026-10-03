-- AuxEconomyShadow shared contracts.
-- Shadow-only: no AH query, bid, buy, cancel, post or global API wrapping.

AVM_SHADOW = AVM_SHADOW or {}
AVM_SHADOW.VERSION = "0.1-shadow"

AVM_SHADOW.STATE = {
    IDLE = "IDLE",
    SCANNING = "SCANNING",
    PAUSE_REQUESTED = "PAUSE_REQUESTED",
    PAUSED = "PAUSED",
    VERIFYING = "VERIFYING",
    TRANSACTION_PENDING = "TRANSACTION_PENDING",
    UNKNOWN_HOLD = "UNKNOWN_HOLD",
    RESUME_PENDING = "RESUME_PENDING",
    STOPPED = "STOPPED",
}

AVM_SHADOW.STRATEGY = {
    VENDOR = "vendor",
    DISENCHANT = "disenchant",
    FLIP = "flip",
    STACK = "stack",
    BID = "bid",
}

local function number(v)
    return tonumber(v) or 0
end

local function text(v)
    if v == nil then return "" end
    return tostring(v)
end

function AVM_SHADOW.NormalizeAuctionRecord(record)
    record = record or {}
    return {
        itemId = number(record.itemId or record.item_id),
        itemKey = text(record.itemKey or record.item_key),
        name = text(record.name),
        owner = text(record.owner),
        count = number(record.count or record.aux_quantity),
        buyout = number(record.buyout or record.buyout_price),
        bid = number(record.bid or record.bid_price or record.bidAmount),
        page = number(record.page),
        index = number(record.index),
        source = text(record.source),
        raw = record,
    }
end

function AVM_SHADOW.NewCandidate(strategy, record, value, expectedProfit, reason)
    local normalized = AVM_SHADOW.NormalizeAuctionRecord(record)
    return {
        strategy = text(strategy),
        record = normalized,
        value = number(value),
        expectedProfit = number(expectedProfit),
        reason = text(reason),
        verified = false,
        verification = nil,
    }
end

function AVM_SHADOW.MarkVerified(candidate, verification)
    if type(candidate) ~= "table" then return nil end
    candidate.verified = true
    candidate.verification = verification or {}
    return candidate
end
