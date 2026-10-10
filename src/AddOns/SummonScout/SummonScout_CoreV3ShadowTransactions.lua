-- SummonScout Core V3 shadow transaction store.
--
-- Stage 2 of the controlled-core-replacement plan. This module is observation-only:
-- it reads legacy state/logs and builds a bounded transaction/audit projection.
-- It MUST NOT invite, whisper, cast, change routing, change party ownership, or retry work.
-- WoW 1.12.1 / Lua 5.0 compatible.

SummonScoutDB = SummonScoutDB or {}

local VERSION = "p1-shadow-transactions"
local MAX_TRANSACTIONS = 200
local MAX_AUDIT = 1000
local POLL_SECONDS = 0.20

local S = W112_SUMMON_CORE_V3_SHADOW
if type(S) ~= "table" then
    S = {}
    W112_SUMMON_CORE_V3_SHADOW = S
end

S.version = VERSION
S.transactions = type(S.transactions) == "table" and S.transactions or {}
S.byId = type(S.byId) == "table" and S.byId or {}
S.audit = type(S.audit) == "table" and S.audit or {}
S.nextSeq = tonumber(S.nextSeq) or 0
S.nextPollAt = tonumber(S.nextPollAt) or 0
S.lastInviteName = tostring(S.lastInviteName or "")
S.lastInviteAt = tonumber(S.lastInviteAt) or 0
S.lastSummonName = tostring(S.lastSummonName or "")
S.lastSummonStarted = S.lastSummonStarted and true or false
S.sessionId = tostring(S.sessionId or "")
S.seenRequestRows = type(S.seenRequestRows) == "table" and S.seenRequestRows or {}
S.seenPaymentRows = type(S.seenPaymentRows) == "table" and S.seenPaymentRows or {}

local function now()
    if GetTime then return tonumber(GetTime()) or 0 end
    return 0
end

local function wall()
    if time then return tonumber(time()) or 0 end
    return 0
end

local function trim(value)
    local s = tostring(value or "")
    s = string.gsub(s, "^%s+", "")
    s = string.gsub(s, "%s+$", "")
    return s
end

local function key(value)
    return string.lower(trim(value))
end

local function appendBounded(list, item, maxCount)
    list[table.getn(list) + 1] = item
    while table.getn(list) > maxCount do
        table.remove(list, 1)
    end
end

local function ensureSession()
    if S.sessionId ~= "" then return end
    S.sessionId = tostring(wall()) .. "-" .. tostring(math.floor(now() * 1000))
end

local function audit(kind, tx, detail)
    local row = {
        ts = wall(),
        mono = now(),
        kind = tostring(kind or "OBS"),
        txId = tx and tx.id or "",
        customer = tx and tx.customer or "",
        destinationId = tx and tx.destinationId or "",
        detail = tostring(detail or "")
    }
    appendBounded(S.audit, row, MAX_AUDIT)
end

local function rebuildIndex()
    S.byId = {}
    local i, tx
    for i = 1, table.getn(S.transactions) do
        tx = S.transactions[i]
        if type(tx) == "table" and tx.id then S.byId[tx.id] = tx end
    end
end

local function newTransaction(customer, destinationId, source, rawMessage, sourceTs)
    ensureSession()
    S.nextSeq = S.nextSeq + 1
    local tx = {
        id = S.sessionId .. "-" .. tostring(S.nextSeq),
        customer = trim(customer),
        customerKey = key(customer),
        destinationId = key(destinationId),
        source = tostring(source or "legacy-observer"),
        rawMessage = tostring(rawMessage or ""),
        createdAt = tonumber(sourceTs) or wall(),
        phase = "CLASSIFIED",
        legacyEvidence = {},
        paymentCopper = 0,
        closed = false
    }
    appendBounded(S.transactions, tx, MAX_TRANSACTIONS)
    rebuildIndex()
    audit("TX_CREATED", tx, tx.source)
    return tx
end

local function newestOpenForCustomer(name)
    local wanted = key(name)
    if wanted == "" then return nil end
    local i, tx
    for i = table.getn(S.transactions), 1, -1 do
        tx = S.transactions[i]
        if type(tx) == "table" and not tx.closed and tx.customerKey == wanted then
            return tx
        end
    end
    return nil
end

local function setPhase(tx, phase, evidence)
    if type(tx) ~= "table" or tx.closed then return end
    phase = tostring(phase or "")
    if phase == "" then return end
    tx.phase = phase
    tx.updatedAt = wall()
    if evidence and evidence ~= "" then
        appendBounded(tx.legacyEvidence, tostring(evidence), 20)
    end
    audit("PHASE", tx, phase .. (evidence and (":" .. tostring(evidence)) or ""))
end

local function seedSeenRows(log, seen)
    local i, row
    if type(log) ~= "table" or type(seen) ~= "table" then return end
    for i = 1, table.getn(log) do
        row = log[i]
        if type(row) == "table" then seen[row] = true end
    end
end

local function observeRequestLog()
    local log = SummonScoutDB and SummonScoutDB.requestLog
    if type(log) ~= "table" then return end
    local i, row
    for i = 1, table.getn(log) do
        row = log[i]
        if type(row) == "table" and not S.seenRequestRows[row] then
            S.seenRequestRows[row] = true
            newTransaction(row.sender or "", row.locationId or "unknown", "legacy-request-log", row.message or "", row.ts)
        end
    end
end

local function observeInvite(core)
    if type(core) ~= "table" then return end
    local name = trim(core.lastInvitedName or "")
    local at = tonumber(core.lastInvitedAt) or 0
    if name == "" or at <= 0 then return end
    if name == S.lastInviteName and at == S.lastInviteAt then return end
    S.lastInviteName = name
    S.lastInviteAt = at

    local tx = newestOpenForCustomer(name)
    if tx then
        tx.invitedAt = wall()
        setPhase(tx, "INVITED", "legacy-lastInvitedName")
    else
        audit("ORPHAN_INVITE", nil, name)
    end
end

local function observeSummon(core)
    if type(core) ~= "table" then return end
    local name = trim(core.summonActiveName or "")
    local started = core.summonActiveStarted and true or false

    if name ~= "" and name ~= S.lastSummonName then
        local tx = newestOpenForCustomer(name)
        if tx then
            tx.summonObservedAt = wall()
            setPhase(tx, "SUMMON_ACTIVE", "legacy-summonActiveName")
        else
            audit("ORPHAN_SUMMON_ACTIVE", nil, name)
        end
    end

    if name ~= "" and started and (name ~= S.lastSummonName or not S.lastSummonStarted) then
        local tx = newestOpenForCustomer(name)
        if tx then
            tx.castStartedObservedAt = wall()
            setPhase(tx, "CAST_STARTED_OBSERVED", "legacy-summonActiveStarted")
        else
            audit("ORPHAN_CAST_START", nil, name)
        end
    end

    -- Deliberately do not mark SUMMON_COMPLETED when the legacy active slot clears.
    -- The legacy implementation can clear on watchdog/retry paths, so completion
    -- requires a stronger explicit signal in a later Core V3 stage.
    if S.lastSummonName ~= "" and name == "" then
        local tx = newestOpenForCustomer(S.lastSummonName)
        if tx then audit("LEGACY_SUMMON_SLOT_CLEARED", tx, S.lastSummonStarted and "after-start" or "without-start") end
    end

    S.lastSummonName = name
    S.lastSummonStarted = started
end

local function observePayments()
    local log = SummonScoutDB and SummonScoutDB.paymentLog
    if type(log) ~= "table" then return end
    local i, row, tx, copper
    for i = 1, table.getn(log) do
        row = log[i]
        if type(row) == "table" and not S.seenPaymentRows[row] then
            S.seenPaymentRows[row] = true
            tx = newestOpenForCustomer(row.player or "")
            copper = math.floor(tonumber(row.copper) or 0)
            if tx and copper > 0 then
                tx.paymentCopper = (tonumber(tx.paymentCopper) or 0) + copper
                tx.paymentObservedAt = tonumber(row.ts) or wall()
                setPhase(tx, "PAID_OBSERVED", "legacy-payment-log")
                tx.closed = true
                tx.closedAt = wall()
                audit("TX_CLOSED", tx, "payment-observed")
            else
                audit("ORPHAN_PAYMENT", nil, trim(row.player or "") .. ":" .. tostring(copper))
            end
        end
    end
end

local function poll()
    observeRequestLog()
    local core = W112_SUMMONSCOUT_STATE
    observeInvite(core)
    observeSummon(core)
    observePayments()
end

local frame = CreateFrame and CreateFrame("Frame", "SummonScoutCoreV3ShadowFrame") or nil
if frame then
    frame:RegisterEvent("PLAYER_LOGIN")
    frame:SetScript("OnEvent", function()
        if event ~= "PLAYER_LOGIN" then return end
        ensureSession()
        -- Mark pre-login bounded log rows as already seen. Tracking row identity,
        -- rather than table length, remains correct after the legacy logs hit their
        -- size cap and rotate one old row out for each new row.
        S.seenRequestRows = {}
        S.seenPaymentRows = {}
        seedSeenRows(SummonScoutDB and SummonScoutDB.requestLog, S.seenRequestRows)
        seedSeenRows(SummonScoutDB and SummonScoutDB.paymentLog, S.seenPaymentRows)
        S.lastInviteName = ""
        S.lastInviteAt = 0
        S.lastSummonName = ""
        S.lastSummonStarted = false
        audit("SESSION_START", nil, VERSION)
    end)
    frame:SetScript("OnUpdate", function()
        local t = now()
        if t < (S.nextPollAt or 0) then return end
        S.nextPollAt = t + POLL_SECONDS
        poll()
    end)
end

W112_SUMMON_CORE_V3_SHADOW_API = {
    version = VERSION,
    GetState = function() return S end,
    FindTransaction = function(id) return S.byId[tostring(id or "")] end,
    FindNewestOpenForCustomer = newestOpenForCustomer
}
