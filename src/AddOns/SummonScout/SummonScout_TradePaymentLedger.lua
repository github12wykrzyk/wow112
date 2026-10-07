-- TELE10 Trade + Payment Ledger for WoW 1.12.1 (5875).
-- Scope: persistent summon/payment accounting, strict trade correlation,
-- idempotent settlement and a fail-closed gate for the existing AutoSummonAssist
-- payer-first AcceptTrade() mechanism. No summon routing/teleport logic lives here.

SummonScoutDB = SummonScoutDB or {}

local TL_VERSION = "1.0.0"
local TL = {
    trade = nil,
    tradeRequestedBy = nil,
    nextPolicyAt = 0,
    policyBlockOwned = false,
    hooksInstalled = false
}

local function tlNow()
    if GetTime then return GetTime() end
    return 0
end

local function tlWall()
    if time then return time() end
    return 0
end

local function tlTrim(s)
    s = tostring(s or "")
    s = string.gsub(s, "^%s+", "")
    s = string.gsub(s, "%s+$", "")
    return s
end

local function tlLower(s)
    return string.lower(tlTrim(s or ""))
end

local function tlSame(a, b)
    local aa = tlLower(a)
    local bb = tlLower(b)
    return aa ~= "" and aa == bb
end

local function tlChat(text)
    if DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffTELE10 Ledger:|r " .. tostring(text or ""))
    end
end

local function tlDB()
    if type(SummonScoutDB.tele10Ledger) ~= "table" then
        SummonScoutDB.tele10Ledger = {}
    end
    local db = SummonScoutDB.tele10Ledger
    if db.schema_version == nil then db.schema_version = 1 end
    if type(db.summons) ~= "table" then db.summons = {} end
    if type(db.payments) ~= "table" then db.payments = {} end
    if type(db.settlement_ids) ~= "table" then db.settlement_ids = {} end
    if db.summon_seq == nil then db.summon_seq = 0 end
    if db.payment_event_seq == nil then db.payment_event_seq = 0 end
    if db.settlement_seq == nil then db.settlement_seq = 0 end
    if db.trade_seq == nil then db.trade_seq = 0 end
    if db.expected_price_copper == nil then db.expected_price_copper = 40000 end
    if db.partial_enabled == nil then db.partial_enabled = true end
    if db.active_session_seconds == nil then db.active_session_seconds = 600 end
    if db.correlation_window_seconds == nil then db.correlation_window_seconds = 21600 end
    if db.received_copper_total == nil then db.received_copper_total = 0 end
    return db
end

local function tlCap(list, maxCount)
    while table.getn(list) > maxCount do
        table.remove(list, 1)
    end
end

local function tlMoney(copper)
    copper = math.floor(tonumber(copper) or 0)
    if copper < 0 then copper = 0 end
    local g = math.floor(copper / 10000)
    local s = math.floor(math.mod(copper, 10000) / 100)
    local c = math.mod(copper, 100)
    if g > 0 then return tostring(g) .. "g " .. tostring(s) .. "s " .. tostring(c) .. "c" end
    if s > 0 then return tostring(s) .. "s " .. tostring(c) .. "c" end
    return tostring(c) .. "c"
end

local function tlParseMoney(text)
    text = tlLower(text)
    text = string.gsub(text, "%s+", "")
    if text == "" then return nil end
    if string.find(text, "^%d+$") then return tonumber(text) end
    local total = 0
    local matched = false
    local _, _, g = string.find(text, "(%d+)g")
    local _, _, s = string.find(text, "(%d+)s")
    local _, _, c = string.find(text, "(%d+)c")
    if g then total = total + (tonumber(g) or 0) * 10000; matched = true end
    if s then total = total + (tonumber(s) or 0) * 100; matched = true end
    if c then total = total + (tonumber(c) or 0); matched = true end
    if not matched then return nil end
    return total
end

local function tlClock(ts)
    ts = tonumber(ts) or 0
    if ts > 0 and date then return date("%H:%M", ts) end
    return tostring(ts)
end

local function tlFindSummon(id)
    if not id or id == "" then return nil end
    local list = tlDB().summons
    local i
    for i = table.getn(list), 1, -1 do
        if list[i].summon_id == id then return list[i] end
    end
    return nil
end

local function tlRecentTrigger(name)
    local log = SummonScoutDB.requestLog
    if type(log) ~= "table" then return "" end
    local t = tlWall()
    local i
    for i = table.getn(log), 1, -1 do
        local item = log[i]
        if type(item) == "table" and tlSame(item.sender, name) then
            local ts = tonumber(item.ts) or 0
            if ts == 0 or t == 0 or (t - ts) <= 600 then
                return tostring(item.message or "")
            end
            return ""
        end
    end
    return ""
end

local function tlDestination()
    local api = W112_SUMMONSCOUT_API_V1
    if type(api) == "table" and type(api.summonDestinationLabel) == "function" then
        local value = tlTrim(api.summonDestinationLabel() or "")
        if value ~= "" then return value end
    end
    return tlTrim(SummonScoutDB.service or "unknown")
end

local function tlExpireOlderActiveSessions(clientName)
    local list = tlDB().summons
    local i
    for i = 1, table.getn(list) do
        local rec = list[i]
        if tlSame(rec.client_name, clientName)
            and rec.payment_status ~= "paid"
            and rec.payment_status ~= "overpaid" then
            rec.payment_session_active_until = 0
        end
    end
end

local function tlStartSummon(name)
    name = tlTrim(name)
    if name == "" then return nil end
    local state = W112_SUMMONSCOUT_STATE
    if type(state) == "table" and state.tele10LedgerActiveId then
        local existing = tlFindSummon(state.tele10LedgerActiveId)
        if existing and tlSame(existing.client_name, name) then return existing end
    end

    local db = tlDB()
    tlExpireOlderActiveSessions(name)
    db.summon_seq = (tonumber(db.summon_seq) or 0) + 1
    local stamp = tlWall()
    local id = "S" .. tostring(stamp) .. "-" .. tostring(db.summon_seq)
    local rec = {
        summon_id = id,
        timestamp_created = stamp,
        timestamp_started = stamp,
        client_name = name,
        summoner_name = UnitName and tlTrim(UnitName("player") or "") or "",
        destination = tlDestination(),
        trigger_message = tlRecentTrigger(name),
        expected_price_copper = math.floor(tonumber(db.expected_price_copper) or 0),
        summon_status = "ritual_started",
        payment_status = "unpaid",
        amount_paid_copper = 0,
        payment_timestamp = nil,
        trade_partner = nil,
        payment_event_id = nil,
        settlement_id = nil,
        last_update = stamp,
        failure_reason = nil,
        payment_session_active_until = 0
    }
    db.summons[table.getn(db.summons) + 1] = rec
    tlCap(db.summons, 1000)
    if type(state) == "table" then state.tele10LedgerActiveId = id end
    return rec
end

local function tlFinishSummon(id, started, failure)
    local rec = tlFindSummon(id)
    local state = W112_SUMMONSCOUT_STATE
    if rec then
        local stamp = tlWall()
        rec.last_update = stamp
        if started then
            rec.summon_status = "summoned"
            rec.timestamp_summoned = stamp
            rec.payment_session_active_until = stamp + (tonumber(tlDB().active_session_seconds) or 600)
            rec.failure_reason = nil
        else
            rec.summon_status = "failed"
            rec.failure_reason = tlTrim(failure or "core_finish_without_confirmed_start")
        end
    end
    if type(state) == "table" and state.tele10LedgerActiveId == id then
        state.tele10LedgerActiveId = nil
    end
end

local function tlOpenPaymentStatus(rec)
    if not rec then return false end
    if rec.summon_status ~= "summoned" then return false end
    return rec.payment_status == "unpaid" or rec.payment_status == "partial"
end

local function tlFindCandidate(partner)
    partner = tlTrim(partner)
    if partner == "" then return nil, "partner_unknown" end
    local db = tlDB()
    local nowWall = tlWall()
    local active = {}
    local fallback = {}
    local uncertain = 0
    local i
    for i = 1, table.getn(db.summons) do
        local rec = db.summons[i]
        if tlSame(rec.client_name, partner) then
            if rec.payment_status == "uncertain" then uncertain = uncertain + 1 end
            if tlOpenPaymentStatus(rec) then
                local created = tonumber(rec.timestamp_summoned or rec.timestamp_created) or 0
                local age = nowWall - created
                if age >= 0 and age <= (tonumber(db.correlation_window_seconds) or 21600) then
                    fallback[table.getn(fallback) + 1] = rec
                    if nowWall <= (tonumber(rec.payment_session_active_until) or 0) then
                        active[table.getn(active) + 1] = rec
                    end
                end
            end
        end
    end
    if table.getn(active) == 1 then return active[1], "active_session_exact" end
    if table.getn(active) > 1 then return nil, "ambiguous_active_sessions" end
    if table.getn(fallback) == 1 then return fallback[1], "unique_unpaid_window" end
    if table.getn(fallback) > 1 then return nil, "ambiguous_unpaid_summons" end
    if uncertain > 0 then return nil, "hard_stop_uncertain" end
    return nil, "no_matching_unpaid_summon"
end

local function tlStrictTradePartner()
    local name
    if UnitName then
        name = UnitName("NPC")
        if tlTrim(name or "") ~= "" then return tlTrim(name) end
    end
    if TradeFrameRecipientNameText and TradeFrameRecipientNameText.GetText then
        name = TradeFrameRecipientNameText:GetText()
        if tlTrim(name or "") ~= "" then return tlTrim(name) end
    end
    if tlTrim(TL.tradeRequestedBy or "") ~= "" then return tlTrim(TL.tradeRequestedBy) end
    return ""
end

local function tlOffer()
    if GetTargetTradeMoney then return math.floor(tonumber(GetTargetTradeMoney()) or 0) end
    return 0
end

local function tlNewTrade()
    if TL.trade then return end
    local db = tlDB()
    db.trade_seq = (tonumber(db.trade_seq) or 0) + 1
    local partner = tlStrictTradePartner()
    local rec, reason = tlFindCandidate(partner)
    TL.trade = {
        trade_session_id = "T" .. tostring(tlWall()) .. "-" .. tostring(db.trade_seq),
        partner = partner,
        before = GetMoney and (GetMoney() or 0) or 0,
        offered = tlOffer(),
        both_accepted = false,
        linked_summon_id = rec and rec.summon_id or nil,
        correlation_reason = reason,
        closed = false,
        closed_at = 0,
        deadline = 0,
        settlement_id = nil,
        settled = false
    }
end

local function tlRefreshTradeIdentity()
    local t = TL.trade
    if not t or t.closed then return end
    local partner = tlStrictTradePartner()
    if partner ~= "" then t.partner = partner end
    t.offered = tlOffer()
    if not t.linked_summon_id then
        local rec, reason = tlFindCandidate(t.partner)
        t.linked_summon_id = rec and rec.summon_id or nil
        t.correlation_reason = reason
    end
end

local function tlBlockAutoAccept(reason, summonId, remaining)
    W112_AUTOGOLD_POLICY_ALLOWED = "0"
    W112_AUTOGOLD_POLICY_REASON = tostring(reason or "blocked")
    W112_AUTOGOLD_POLICY_SUMMON_ID = tostring(summonId or "")
    W112_AUTOGOLD_POLICY_REMAINING = tostring(math.floor(tonumber(remaining) or 0))
    -- AutoSummonAssist uses this exact latch to guarantee one AcceptTrade per
    -- payer-accept cycle. Reasserting it every 50 ms is safely faster than its
    -- 250 ms offer-stability gate, so an unsafe trade cannot reach AcceptTrade.
    W112_AUTOGOLD_TARGET_LATCH = 1
    TL.policyBlockOwned = true
end

local function tlAllowAutoAccept(reason, summonId, remaining)
    W112_AUTOGOLD_POLICY_ALLOWED = "1"
    W112_AUTOGOLD_POLICY_REASON = tostring(reason or "allowed")
    W112_AUTOGOLD_POLICY_SUMMON_ID = tostring(summonId or "")
    W112_AUTOGOLD_POLICY_REMAINING = tostring(math.floor(tonumber(remaining) or 0))
    if TL.policyBlockOwned then
        W112_AUTOGOLD_TARGET_LATCH = nil
        TL.policyBlockOwned = false
    end
end

local function tlRefreshPolicy()
    local t = TL.trade
    if not t or t.closed then
        tlBlockAutoAccept("no_active_trade", nil, 0)
        return
    end
    tlRefreshTradeIdentity()
    local rec = tlFindSummon(t.linked_summon_id)
    if not rec or not tlSame(rec.client_name, t.partner) then
        tlBlockAutoAccept(t.correlation_reason or "uncorrelated_partner", nil, 0)
        return
    end
    if rec.payment_status == "uncertain" then
        tlBlockAutoAccept("summon_payment_uncertain_hard_stop", rec.summon_id, 0)
        return
    end
    local expected = math.floor(tonumber(rec.expected_price_copper) or 0)
    local paid = math.floor(tonumber(rec.amount_paid_copper) or 0)
    local remaining = expected - paid
    if remaining < 0 then remaining = 0 end
    local offered = math.floor(tonumber(t.offered) or 0)
    if offered <= 0 then
        tlBlockAutoAccept("no_gold_offer", rec.summon_id, remaining)
        return
    end
    if not tlDB().partial_enabled and offered < remaining then
        tlBlockAutoAccept("underpay_policy_block", rec.summon_id, remaining)
        return
    end
    local reason = offered < remaining and "partial_allowed"
        or (offered > remaining and "overpay_allowed" or "exact_price")
    tlAllowAutoAccept(reason, rec.summon_id, remaining)
end

local function tlPaymentEvent(status, t, received, reason, summonId, settlementId)
    local db = tlDB()
    db.payment_event_seq = (tonumber(db.payment_event_seq) or 0) + 1
    local ev = {
        payment_event_id = "E" .. tostring(tlWall()) .. "-" .. tostring(db.payment_event_seq),
        settlement_id = settlementId,
        summon_id = summonId,
        timestamp = tlWall(),
        trade_session_id = t and t.trade_session_id or nil,
        trade_partner = t and t.partner or "",
        offered_copper = t and (tonumber(t.offered) or 0) or 0,
        received_copper = math.floor(tonumber(received) or 0),
        status = status,
        reason = tostring(reason or "")
    }
    db.payments[table.getn(db.payments) + 1] = ev
    tlCap(db.payments, 2000)
    return ev
end

local function tlCompatibilityPayment(rec, ev, received)
    if type(SummonScoutDB.paymentLog) ~= "table" then SummonScoutDB.paymentLog = {} end
    SummonScoutDB.revenueCopper = (tonumber(SummonScoutDB.revenueCopper) or 0) + received
    SummonScoutDB.paymentCount = (tonumber(SummonScoutDB.paymentCount) or 0) + 1
    SummonScoutDB.paymentLog[table.getn(SummonScoutDB.paymentLog) + 1] = {
        ts = ev.timestamp,
        player = rec.client_name,
        copper = received,
        summon_id = rec.summon_id,
        settlement_id = ev.settlement_id
    }
    tlCap(SummonScoutDB.paymentLog, 100)
end

local function tlApplySettlement(t, received)
    local db = tlDB()
    if not t.settlement_id then
        db.settlement_seq = (tonumber(db.settlement_seq) or 0) + 1
        t.settlement_id = "SET" .. tostring(tlWall()) .. "-" .. tostring(db.settlement_seq)
    end
    if db.settlement_ids[t.settlement_id] then return false, "duplicate_settlement" end

    local rec = tlFindSummon(t.linked_summon_id)
    if not rec or not tlSame(rec.client_name, t.partner) or not tlOpenPaymentStatus(rec) then
        local ev = tlPaymentEvent("uncertain", t, received, "correlation_lost_before_settlement", nil, t.settlement_id)
        db.settlement_ids[t.settlement_id] = ev.payment_event_id
        db.received_copper_total = (tonumber(db.received_copper_total) or 0) + received
        return false, "correlation_lost"
    end

    local ev = tlPaymentEvent("settled", t, received, "wallet_delta_matches_offer_and_both_accepted", rec.summon_id, t.settlement_id)
    db.settlement_ids[t.settlement_id] = ev.payment_event_id
    db.received_copper_total = (tonumber(db.received_copper_total) or 0) + received

    rec.amount_paid_copper = (tonumber(rec.amount_paid_copper) or 0) + received
    rec.payment_timestamp = ev.timestamp
    rec.trade_partner = t.partner
    rec.payment_event_id = ev.payment_event_id
    rec.settlement_id = t.settlement_id
    rec.last_update = ev.timestamp
    rec.failure_reason = nil
    if rec.amount_paid_copper < (tonumber(rec.expected_price_copper) or 0) then
        rec.payment_status = "partial"
        rec.payment_session_active_until = ev.timestamp + (tonumber(db.active_session_seconds) or 600)
    elseif rec.amount_paid_copper == (tonumber(rec.expected_price_copper) or 0) then
        rec.payment_status = "paid"
        rec.payment_session_active_until = 0
    else
        rec.payment_status = "overpaid"
        rec.payment_session_active_until = 0
    end
    tlCompatibilityPayment(rec, ev, received)
    return true, rec.payment_status
end

local function tlCloseTrade()
    local t = TL.trade
    if not t or t.closed then return end
    tlRefreshTradeIdentity()
    t.closed = true
    t.closed_at = tlNow()
    t.deadline = t.closed_at + 2.0
    tlBlockAutoAccept("trade_closed_waiting_settlement", t.linked_summon_id, 0)
end

local function tlMarkUncertain(t, received, reason)
    local rec = tlFindSummon(t and t.linked_summon_id)
    local ev = tlPaymentEvent("uncertain", t, received, reason, rec and rec.summon_id or nil, nil)
    if received > 0 then
        tlDB().received_copper_total = (tonumber(tlDB().received_copper_total) or 0) + received
    end
    if rec then
        rec.payment_status = "uncertain"
        rec.last_update = ev.timestamp
        rec.failure_reason = "trade_settlement_uncertain:" .. tostring(reason or "unknown")
        rec.payment_session_active_until = 0
    end
end

local function tlProcessClosedTrade()
    local t = TL.trade
    if not t or not t.closed or t.settled then return end
    local after = GetMoney and (GetMoney() or t.before) or t.before
    local delta = math.floor((tonumber(after) or 0) - (tonumber(t.before) or 0))
    local offered = math.floor(tonumber(t.offered) or 0)

    if delta > 0 and delta == offered and offered > 0 and t.both_accepted and t.linked_summon_id then
        tlApplySettlement(t, delta)
        t.settled = true
        TL.trade = nil
        return
    end

    if tlNow() < (tonumber(t.deadline) or 0) then return end

    if delta <= 0 then
        if offered > 0 or t.both_accepted then
            tlPaymentEvent("cancelled", t, 0, "trade_closed_without_positive_wallet_delta", t.linked_summon_id, nil)
        end
    else
        local reason = "uncertain_trade_result"
        if not t.both_accepted then reason = "wallet_gain_without_both_accepted_observed"
        elseif offered <= 0 then reason = "wallet_gain_without_positive_offer_snapshot"
        elseif delta ~= offered then reason = "wallet_delta_does_not_match_offer" end
        tlMarkUncertain(t, delta, reason)
    end
    t.settled = true
    TL.trade = nil
end

local function tlInstallHooks()
    if TL.hooksInstalled then return true end
    local api = W112_SUMMONSCOUT_API_V1
    local state = W112_SUMMONSCOUT_STATE
    if type(api) ~= "table" or type(state) ~= "table" then return false end
    if state.tele10LedgerHooksInstalled then
        TL.hooksInstalled = true
        return true
    end

    local originalStart = api.markActiveSummonStarted
    local originalFinish = api.finishActiveSummon
    local originalFinishTrade = api.finishTrade

    if type(originalStart) == "function" then
        api.markActiveSummonStarted = function(source)
            local name = tlTrim(state.summonActiveName or "")
            originalStart(source)
            if name ~= "" then tlStartSummon(name) end
        end
    end

    if type(originalFinish) == "function" then
        api.finishActiveSummon = function(name)
            local activeName = tlTrim(name or state.summonActiveName or "")
            local id = state.tele10LedgerActiveId
            local started = state.summonActiveStarted and true or false
            local failure = state.lastSummonError
            originalFinish(name)
            if id then tlFinishSummon(id, started, failure) end
        end
    end

    if type(originalFinishTrade) == "function" then
        api.finishTrade = function()
            -- Reuse the core's session cleanup, but disable its legacy two-second
            -- settlement worker. This module is the single authoritative writer.
            originalFinishTrade()
            state.pendingTrade = nil
        end
    end

    state.tele10LedgerHooksInstalled = true
    TL.hooksInstalled = true
    return true
end

local function tlSummonLine(rec)
    local paidAt = rec.payment_timestamp and tlClock(rec.payment_timestamp) or "-"
    return tostring(rec.client_name or "?") .. " | " .. tlClock(rec.timestamp_created)
        .. " | " .. tostring(rec.destination or "?")
        .. " | expected " .. tlMoney(rec.expected_price_copper)
        .. " | paid " .. tlMoney(rec.amount_paid_copper)
        .. " | " .. paidAt
        .. " | " .. string.upper(tostring(rec.payment_status or "unpaid"))
        .. " | " .. tostring(rec.summon_id or "-")
end

local function tlShowSummons(filter, limit, sinceSeconds)
    local list = tlDB().summons
    limit = math.floor(tonumber(limit) or 10)
    if limit < 1 then limit = 1 end
    if limit > 30 then limit = 30 end
    local shown = 0
    local i
    local since = sinceSeconds and (tlWall() - sinceSeconds) or nil
    for i = table.getn(list), 1, -1 do
        local rec = list[i]
        local matches = true
        if filter and filter ~= "" and filter ~= "all" then
            local f = tlLower(filter)
            if f == "unpaid" or f == "partial" or f == "paid" or f == "overpaid" or f == "uncertain" then
                matches = rec.payment_status == f
            else
                matches = tlSame(rec.client_name, filter)
            end
        end
        if since and (tonumber(rec.timestamp_created) or 0) < since then matches = false end
        if matches then
            tlChat(tlSummonLine(rec))
            shown = shown + 1
            if shown >= limit then break end
        end
    end
    if shown == 0 then tlChat("no matching summon ledger rows") end
end

local function tlShowPayments(filter, limit)
    local list = tlDB().payments
    limit = math.floor(tonumber(limit) or 10)
    if limit < 1 then limit = 1 end
    if limit > 30 then limit = 30 end
    local shown = 0
    local i
    for i = table.getn(list), 1, -1 do
        local ev = list[i]
        local match = filter == nil or filter == "" or filter == "all" or tlSame(ev.trade_partner, filter)
        if match then
            tlChat(tostring(ev.trade_partner or "?") .. " | " .. tlClock(ev.timestamp)
                .. " | offered " .. tlMoney(ev.offered_copper)
                .. " | received " .. tlMoney(ev.received_copper)
                .. " | " .. string.upper(tostring(ev.status or "?"))
                .. " | summon=" .. tostring(ev.summon_id or "UNASSIGNED")
                .. " | settlement=" .. tostring(ev.settlement_id or "-"))
            shown = shown + 1
            if shown >= limit then break end
        end
    end
    if shown == 0 then tlChat("no matching payment events") end
end

local function tlSlash(msg)
    msg = tlTrim(msg or "")
    local _, _, cmd, rest = string.find(msg, "^(%S*)%s*(.-)$")
    cmd = tlLower(cmd or "")
    rest = tlTrim(rest or "")
    local db = tlDB()

    if cmd == "price" then
        if rest == "" then
            tlChat("expected price = " .. tlMoney(db.expected_price_copper))
        else
            local value = tlParseMoney(rest)
            if value == nil or value < 0 then tlChat("use: /ssledger price 4g | 4g50s | copper")
            else db.expected_price_copper = math.floor(value); tlChat("future summon price -> " .. tlMoney(value)) end
        end
        return
    end
    if cmd == "partial" then
        local v = tlLower(rest)
        if v == "on" then db.partial_enabled = true
        elseif v == "off" then db.partial_enabled = false
        else tlChat("use: /ssledger partial on|off"); return end
        tlChat("partial auto-accept policy -> " .. (db.partial_enabled and "ON" or "OFF"))
        return
    end
    if cmd == "payments" then
        local _, _, who, n = string.find(rest, "^(%S*)%s*(%d*)$")
        tlShowPayments(who or "all", tonumber(n) or 10)
        return
    end
    if cmd == "since" then
        local mins = tonumber(rest)
        if not mins or mins <= 0 then tlChat("use: /ssledger since <minutes>")
        else tlShowSummons("all", 30, mins * 60) end
        return
    end
    if cmd == "unpaid" or cmd == "partial" or cmd == "paid" or cmd == "overpaid" or cmd == "uncertain" or cmd == "all" then
        tlShowSummons(cmd, tonumber(rest) or 10, nil)
        return
    end
    if cmd == "status" or cmd == "" then
        tlChat("v" .. TL_VERSION .. " summons=" .. tostring(table.getn(db.summons))
            .. " payments=" .. tostring(table.getn(db.payments))
            .. " received=" .. tlMoney(db.received_copper_total)
            .. " price=" .. tlMoney(db.expected_price_copper)
            .. " partial=" .. (db.partial_enabled and "ON" or "OFF"))
        tlChat("query: /ssledger <player> | unpaid|partial|paid|uncertain|all [n] | payments <player> [n] | since <minutes>")
        return
    end
    tlShowSummons(cmd, tonumber(rest) or 10, nil)
end

local frame = CreateFrame("Frame", "SummonScoutTradePaymentLedgerFrame")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("TRADE_REQUEST")
frame:RegisterEvent("TRADE_SHOW")
frame:RegisterEvent("TRADE_MONEY_CHANGED")
frame:RegisterEvent("TRADE_ACCEPT_UPDATE")
frame:RegisterEvent("TRADE_CLOSED")
frame:SetScript("OnEvent", function()
    if event == "PLAYER_LOGIN" then
        tlDB()
        tlInstallHooks()
        W112_TELE10_TRADE_LEDGER_VERSION = TL_VERSION
        tlBlockAutoAccept("no_active_trade", nil, 0)
        return
    end
    if event == "TRADE_REQUEST" then
        TL.tradeRequestedBy = tlTrim(arg1 or "")
        return
    end
    if event == "TRADE_SHOW" then
        tlNewTrade()
        tlRefreshPolicy()
        return
    end
    if event == "TRADE_MONEY_CHANGED" then
        tlRefreshTradeIdentity()
        tlRefreshPolicy()
        return
    end
    if event == "TRADE_ACCEPT_UPDATE" then
        tlRefreshTradeIdentity()
        if TL.trade then TL.trade.both_accepted = (arg1 == 1 and arg2 == 1) and true or false end
        tlRefreshPolicy()
        return
    end
    if event == "TRADE_CLOSED" then
        tlCloseTrade()
        TL.tradeRequestedBy = nil
        return
    end
end)
frame:SetScript("OnUpdate", function()
    local t = tlNow()
    if not TL.hooksInstalled then tlInstallHooks() end
    if t >= (TL.nextPolicyAt or 0) then
        TL.nextPolicyAt = t + 0.05
        tlRefreshPolicy()
    end
    tlProcessClosedTrade()
end)

SLASH_TELE10LEDGER1 = "/ssledger"
SLASH_TELE10LEDGER2 = "/sspay"
SlashCmdList["TELE10LEDGER"] = tlSlash

W112_TELE10_LEDGER_V1 = {
    version = TL_VERSION,
    FindCandidate = tlFindCandidate,
    FindSummon = tlFindSummon,
    ShowSummons = tlShowSummons,
    ShowPayments = tlShowPayments
}
