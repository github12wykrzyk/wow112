-- Shared AH foreground-priority scheduler for WoW 1.12.1 / AUX.
--
-- One physical AH query channel is shared by the long background Search loop,
-- native owner scans and AutoSell exact-price probes. The original AUX module
-- keeps per-type scan state, but the live client/server query transport can still
-- starve owner/foreground work when the continuous list loop immediately reacquires
-- the channel. This coordinator gives interactive auction management priority
-- without adding a second query producer.
--
-- Priority:
--   1) already-started critical AVM transaction (never torn down mid PlaceAuctionBid)
--   2) Auctions owner refresh + AutoSell owner/price/cancel/repost work
--   3) background AUX continuous Search/restart
--
-- Foreground takeover reuses AuxFastBridge's proven safe-boundary service pause:
-- current Search finishes its current response/page, aborts before the next submit,
-- then the service pause is released immediately. While foreground owns the lease,
-- bridge Restart/Resume calls are gated. When foreground drains, the previous Search
-- continuation is resumed first; a fresh loop restart is only a fallback.

AVM_AH_PRIORITY = AVM_AH_PRIORITY or {}
local P = AVM_AH_PRIORITY

P.installed = P.installed or false
P.requested = P.requested or false
P.pauseIssued = P.pauseIssued or false
P.hold = P.hold or false
P.reason = P.reason or ''
P.ownerQueued = P.ownerQueued or nil
P.ownerActive = P.ownerActive or false
P.ownerSource = P.ownerSource or ''
P.ownerStartedAt = P.ownerStartedAt or 0
P.lastActivity = P.lastActivity or 0
P.idleSince = P.idleSince or 0
P.resumeNeeded = P.resumeNeeded or false
P.restartNeeded = P.restartNeeded or false
P.resumePending = P.resumePending or false
P.resumeRetryAt = P.resumeRetryAt or 0
P.resumeRetryUntil = P.resumeRetryUntil or 0
P.inAutoSellTick = P.inAutoSellTick or false
P.nextTick = P.nextTick or 0
P.nextDiag = P.nextDiag or 0

local IDLE_GRACE = 0.65
local OWNER_TIMEOUT = 16.0
local RESUME_RETRY = 0.15
local RESUME_TIMEOUT = 3.0

local function out(msg)
    if DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage('|cff33ccff[AH PRIORITY]|r ' .. tostring(msg))
    end
end

local function auction_open()
    return AuctionFrame and AuctionFrame.IsVisible and AuctionFrame:IsVisible()
end

local function avm_critical_transaction()
    if not AVM then return false end
    local phase = tostring(AVM.phase or 'IDLE')
    return AVM.pending or AVM.unknown or AVM.bidPending or AVM.bidCandidate or
        phase == 'REVALIDATE' or phase == 'BUY_PENDING' or phase == 'BID_REVALIDATE' or
        phase == 'BID_PENDING' or phase == 'UNKNOWN_HOLD' or
        phase == 'DE_MAT_REVALIDATE' or phase == 'FLIP_MARKET_REVALIDATE'
end

local function bridge_busy()
    if not AUXFAST_IsBusy then return false end
    local ok, busy = pcall(AUXFAST_IsBusy)
    return ok and busy and true or false
end

local function bridge_status()
    if not AUXFAST_ServiceWorkerStatus then return nil end
    local ok, st = pcall(AUXFAST_ServiceWorkerStatus)
    if not ok or type(st) ~= 'table' then return nil end
    return st
end

local function autosell_status()
    if not AVM_AUTOSELL or not AVM_AUTOSELL.Status then return nil end
    local ok, st = pcall(AVM_AUTOSELL.Status)
    if not ok or type(st) ~= 'table' then return nil end
    return st
end

local function diag(now)
    if not AVM_DB then return end
    AVM_DB.diag = AVM_DB.diag or { seq = 0, events = {}, state = {} }
    AVM_DB.diag.ahPriority = {
        requested = P.requested and true or false,
        pauseIssued = P.pauseIssued and true or false,
        hold = P.hold and true or false,
        reason = tostring(P.reason or ''),
        ownerQueued = P.ownerQueued and true or false,
        ownerActive = P.ownerActive and true or false,
        ownerSource = tostring(P.ownerSource or ''),
        resumeNeeded = P.resumeNeeded and true or false,
        restartNeeded = P.restartNeeded and true or false,
        resumePending = P.resumePending and true or false,
        bridgeBusy = bridge_busy(),
        critical = avm_critical_transaction() and true or false,
        at = tonumber(now) or GetTime(),
    }
end

local function request_priority(reason)
    reason = tostring(reason or 'foreground')
    if not P.requested and not P.pauseIssued and not P.hold then
        P.reason = reason
        P.requested = true
        P.idleSince = 0
        P.lastActivity = GetTime()
        out('REQUEST ' .. reason)
    elseif P.reason == '' then
        P.reason = reason
    end
    return true
end

local function queue_owner(source, fn)
    if type(fn) ~= 'function' then return false end
    source = tostring(source or 'owner')
    request_priority(source)
    if P.ownerActive or P.ownerQueued then
        -- A complete native owner scan feeds both the Auctions table and AutoSell,
        -- so concurrent manual/AutoSell requests intentionally coalesce.
        return true
    end
    P.ownerQueued = { source = source, fn = fn }
    P.lastActivity = GetTime()
    return true
end

local function clear_background_arbiter()
    if not AVM or not AVM.auxArb then return end
    local a = AVM.auxArb
    -- The service-pause abort happened at submit boundary. Drop only volatile
    -- ownership/transaction intent; keep accumulated DE/flip books so a real
    -- AUXFAST_ResumeSearch can continue the same logical Search afterward.
    a.active = false
    a.paused = false
    a.pausePending = false
    a.resumePending = false
    a.resumeRetryAt = 0
    a.resumeRetryUntil = 0
    a.resumeRetryAttempts = 0
    a.resumeRetryReason = ''
    a.resumeRetryDetail = ''
    a.revalidateCurrent = false
    a.candidate = nil
    AVM.candidate = nil
    if not avm_critical_transaction() then
        AVM.phase = 'IDLE'
        AVM.queryInFlight = false
        AVM.nextQueryAt = 0
    end
end

local function claim_pause(now)
    local st = bridge_status()
    if not st or not st.paused then return false end
    P.resumeNeeded = P.resumeNeeded or (st.hadScan and true or false)
    clear_background_arbiter()
    -- Service pause is only the safe-boundary primitive. Release it immediately
    -- so owner/list foreground scans are allowed; our Restart/Resume wrappers below
    -- keep the background loop from reacquiring the channel.
    if AUXFAST_ServiceWorkerRelease then pcall(AUXFAST_ServiceWorkerRelease) end
    P.requested = false
    P.pauseIssued = false
    P.hold = true
    P.lastActivity = now
    P.idleSince = 0
    out('ACQUIRED ' .. tostring(P.reason or 'foreground') ..
        ' resume=' .. tostring(P.resumeNeeded and true or false))
    return true
end

local function advance_request(now)
    if P.hold then return true end
    if not P.requested and not P.pauseIssued then return false end
    if avm_critical_transaction() and not P.pauseIssued then
        -- Critical purchase/cancel/post path finishes first. Foreground remains
        -- queued and will claim the transport before the next background Search.
        return true
    end

    if P.pauseIssued then
        if claim_pause(now) then return true end
        local st = bridge_status()
        if st and not st.pending and not st.paused then
            -- A foreign release/guard may have cleared the service pause. Reissue.
            P.pauseIssued = false
        end
        return true
    end

    local st = bridge_status()
    if st and (st.pending or st.paused) then
        -- Do not steal MarketWorker's independent service handoff. Wait until its
        -- pause/release lifecycle finishes, then request our own short boundary.
        return true
    end

    if not P.origServicePause then return true end
    local ok, accepted, why = pcall(P.origServicePause)
    if not ok then
        out('pause error: ' .. tostring(accepted))
        return true
    end
    if accepted then
        P.pauseIssued = true
        claim_pause(now)
        return true
    end
    why = tostring(why or '')
    if why == 'pending-submit-boundary' or why == 'paused' then
        P.pauseIssued = true
    end
    return true
end

local function start_queued_owner(now)
    if not P.hold or P.ownerActive or not P.ownerQueued then return false end
    if bridge_busy() or avm_critical_transaction() then return false end
    local q = P.ownerQueued
    P.ownerQueued = nil
    P.ownerActive = true
    P.ownerSource = tostring(q.source or 'owner')
    P.ownerStartedAt = now
    P.lastActivity = now
    local ok, started = pcall(q.fn)
    if not ok or started == false then
        P.ownerActive = false
        P.ownerSource = ''
        P.ownerStartedAt = 0
        out('owner start failed: ' .. tostring(ok and 'bridge-returned-false' or started))
        return false
    end
    out('OWNER START ' .. P.ownerSource)
    return true
end

local function autosell_tick(now)
    if not P.hold or P.ownerActive or P.ownerQueued or bridge_busy() then return false end
    if not AVM_AUTOSELL or not AVM_AUTOSELL.Tick or P.inAutoSellTick then return false end
    P.inAutoSellTick = true
    local ok, claimed = pcall(AVM_AUTOSELL.Tick, now)
    P.inAutoSellTick = false
    if ok and claimed then
        P.lastActivity = now
        P.idleSince = 0
        return true
    end
    return false
end

local function autosell_has_live_work()
    local st = autosell_status()
    if not st then return false end
    return st.ownerRefreshRequested or tostring(st.action or '') ~= '' or tostring(st.candidate or '') ~= ''
end

local function schedule_resume(now)
    local needResume = P.resumeNeeded
    local needRestart = P.restartNeeded
    P.hold = false
    P.requested = false
    P.pauseIssued = false
    P.reason = ''
    P.idleSince = 0
    P.resumeNeeded = false
    P.restartNeeded = false

    if not auction_open() or (AVM and (AVM.hardStop or not (AVM_DB and AVM_DB.auxLoopEnabled))) then
        P.resumePending = false
        return
    end

    if needResume and P.origResume then
        local ok, resumed = pcall(P.origResume)
        if ok and resumed then
            P.resumePending = false
            out('RELEASE resume=continuation')
            return
        end
        P.resumePending = true
        P.resumeRetryAt = now + RESUME_RETRY
        P.resumeRetryUntil = now + RESUME_TIMEOUT
        out('RELEASE resume=retry')
        return
    end

    P.resumePending = false
    if AVM and AVM.auxLoop and AVM_DB and AVM_DB.auxLoopEnabled then
        AVM.auxLoop.nextAt = now + 0.05
    end
    if needRestart then out('RELEASE restart=queued') else out('RELEASE idle') end
end

local function resume_retry_tick(now)
    if not P.resumePending then return false end
    if not auction_open() or (AVM and (AVM.hardStop or not (AVM_DB and AVM_DB.auxLoopEnabled))) then
        P.resumePending = false
        return false
    end
    if now < (tonumber(P.resumeRetryAt) or 0) then return true end
    if P.origResume then
        local ok, resumed = pcall(P.origResume)
        if ok and resumed then
            P.resumePending = false
            out('RESUME recovered')
            return true
        end
    end
    if now >= (tonumber(P.resumeRetryUntil) or 0) then
        P.resumePending = false
        if AVM and AVM.auxLoop and AVM_DB and AVM_DB.auxLoopEnabled then
            AVM.auxLoop.nextAt = now + 0.05
        end
        out('RESUME fallback=fresh-loop')
        return true
    end
    P.resumeRetryAt = now + RESUME_RETRY
    return true
end

local function maybe_release(now)
    if not P.hold then return false end
    if P.ownerQueued or P.ownerActive or bridge_busy() or avm_critical_transaction() then
        P.idleSince = 0
        return false
    end
    if autosell_has_live_work() then
        P.idleSince = 0
        return false
    end
    if P.idleSince <= 0 then
        P.idleSince = now
        return false
    end
    if now - P.idleSince < IDLE_GRACE then return false end
    schedule_resume(now)
    return true
end

local function owner_completed(now)
    if not P.ownerActive then return end
    P.ownerActive = false
    local source = P.ownerSource
    P.ownerSource = ''
    P.ownerStartedAt = 0
    P.lastActivity = now
    P.idleSince = 0
    out('OWNER DONE ' .. tostring(source))
end

local function install()
    if P.installed then return true end
    if not AUXFAST_ServiceWorkerPause or not AUXFAST_ServiceWorkerStatus or
       not AUXFAST_ServiceWorkerRelease or not AUXFAST_RestartSearch or not AUXFAST_ResumeSearch then
        return false
    end
    if not AVM_OWNER_SCAN_BRIDGE or not AVM_OWNER_SCAN_BRIDGE.RequestOwnerSnapshot then return false end

    local ok, auctions = pcall(require, 'aux.tabs.auctions')
    if not ok or not auctions or not auctions.scan_auctions then return false end
    local env = getfenv(auctions.scan_auctions)
    if not env or not env.scan_auctions or not env.update_listing then return false end

    P.origServicePause = AUXFAST_ServiceWorkerPause
    P.origRestart = AUXFAST_RestartSearch
    P.origResume = AUXFAST_ResumeSearch
    P.origNativeOwnerScan = env.scan_auctions
    P.origOwnerSnapshot = AVM_OWNER_SCAN_BRIDGE.RequestOwnerSnapshot
    P.origOwnerUpdate = env.update_listing

    -- Foreground management outranks MarketWorker handoff. The priority manager
    -- itself calls origServicePause directly, so this wrapper only affects other
    -- consumers while our lease is pending/held.
    AUXFAST_ServiceWorkerPause = function()
        if P.requested or P.pauseIssued or P.hold or P.resumePending then
            return false, 'foreground-priority'
        end
        return P.origServicePause()
    end

    AUXFAST_RestartSearch = function(...)
        if P.requested or P.pauseIssued or P.hold or P.resumePending then
            P.restartNeeded = true
            return false, 'foreground-priority'
        end
        return P.origRestart(unpack(arg or {}))
    end

    AUXFAST_ResumeSearch = function(...)
        if P.requested or P.pauseIssued or P.hold or P.resumePending then
            P.resumeNeeded = true
            return false, 'foreground-priority'
        end
        return P.origResume(unpack(arg or {}))
    end

    env.scan_auctions = function()
        return queue_owner('auctions-refresh', P.origNativeOwnerScan)
    end

    AVM_OWNER_SCAN_BRIDGE.RequestOwnerSnapshot = function(reason)
        local why = 'autosell-owner:' .. tostring(reason or 'refresh')
        return queue_owner(why, function() return P.origOwnerSnapshot(reason) end)
    end

    env.update_listing = function()
        local result = P.origOwnerUpdate()
        local text = env.status_bar and env.status_bar.text and env.status_bar.text:GetText() or ''
        if P.ownerActive and (tostring(text) == 'Scan complete' or
           string.find(tostring(text), 'Auctions ', 1, true) == 1) then
            owner_completed(GetTime())
        end
        return result
    end

    P.installed = true
    out('installed: Auctions/AutoSell > background loop')
    return true
end

function AVM_AH_PRIORITY.Status()
    return {
        installed = P.installed and true or false,
        requested = P.requested and true or false,
        hold = P.hold and true or false,
        reason = tostring(P.reason or ''),
        ownerQueued = P.ownerQueued and true or false,
        ownerActive = P.ownerActive and true or false,
        ownerSource = tostring(P.ownerSource or ''),
        resumePending = P.resumePending and true or false,
        resumeNeeded = P.resumeNeeded and true or false,
        restartNeeded = P.restartNeeded and true or false,
    }
end

local frame = CreateFrame('Frame', 'AuxVmangosAHPriorityScheduler')
frame:RegisterEvent('AUCTION_HOUSE_CLOSED')
frame:SetScript('OnEvent', function()
    if event == 'AUCTION_HOUSE_CLOSED' then
        P.ownerQueued = nil
        P.ownerActive = false
        P.ownerSource = ''
        P.ownerStartedAt = 0
        if P.pauseIssued and AUXFAST_ServiceWorkerRelease then pcall(AUXFAST_ServiceWorkerRelease) end
        P.requested = false
        P.pauseIssued = false
        if P.hold then schedule_resume(GetTime()) end
        P.hold = false
        P.resumePending = false
    end
end)

frame:SetScript('OnUpdate', function()
    local now = GetTime()
    if now < (tonumber(P.nextTick) or 0) then return end
    P.nextTick = now + 0.05

    if not P.installed then
        install()
        return
    end

    if P.resumePending then
        resume_retry_tick(now)
        return
    end

    local ast = autosell_status()
    if ast and ast.ownerRefreshRequested then request_priority('autosell-owner') end

    if P.requested or P.pauseIssued then
        advance_request(now)
    end

    if P.hold then
        if P.ownerActive and now - (tonumber(P.ownerStartedAt) or now) > OWNER_TIMEOUT then
            out('OWNER TIMEOUT ' .. tostring(P.ownerSource or ''))
            P.ownerActive = false
            P.ownerSource = ''
            P.ownerStartedAt = 0
            P.lastActivity = now
            P.idleSince = 0
        end
        if not start_queued_owner(now) then
            autosell_tick(now)
        end
        maybe_release(now)
    end

    if now >= (tonumber(P.nextDiag) or 0) then
        P.nextDiag = now + 0.50
        diag(now)
    end
end)

SLASH_AVMAHPRIO1 = '/ahprio'
SlashCmdList['AVMAHPRIO'] = function()
    local s = AVM_AH_PRIORITY.Status()
    out('installed=' .. tostring(s.installed) ..
        ' requested=' .. tostring(s.requested) ..
        ' hold=' .. tostring(s.hold) ..
        ' ownerQueued=' .. tostring(s.ownerQueued) ..
        ' ownerActive=' .. tostring(s.ownerActive) ..
        ' resumePending=' .. tostring(s.resumePending) ..
        ' reason=' .. tostring(s.reason))
end
