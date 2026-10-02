-- AuxFastBridge stale MarketWorker handoff guard for WoW 1.12.1 / 5875.
-- A valid worker pause closes the AH almost immediately. If the AH stays visible
-- after the worker handoff timeout window, the pause is stale and must not block
-- manual Auctions refresh or AutoSell price probes indefinitely.

AUXFAST_HANDOFF_GUARD = AUXFAST_HANDOFF_GUARD or {
    mode = '',
    since = 0,
    nextTick = 0,
}

local G = AUXFAST_HANDOFF_GUARD

local function out(msg)
    if DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage('|cff66ff99[AUX FAST]|r ' .. tostring(msg))
    end
end

local function reset_watch()
    G.mode = ''
    G.since = 0
end

local function release(reason)
    if not AUXFAST_ServiceWorkerRelease then return false end
    local ok, released = pcall(AUXFAST_ServiceWorkerRelease)
    if ok and released then
        reset_watch()
        out('SERVICE_HANDOFF_AUTORELEASE reason=' .. tostring(reason or 'stale'))
        return true
    end
    return false
end

local function tick(now)
    if not AUXFAST_ServiceWorkerStatus then
        reset_watch()
        return
    end
    local ok, st = pcall(AUXFAST_ServiceWorkerStatus)
    if not ok or type(st) ~= 'table' then
        reset_watch()
        return
    end
    local mode = st.paused and 'paused' or (st.pending and 'pending' or '')
    if mode == '' then
        reset_watch()
        return
    end
    -- Never release while the worker has actually left the AH. The handoff is
    -- intentional there and MarketWorker owns restoration back to AH.
    if not AuctionFrame or not AuctionFrame.IsVisible or not AuctionFrame:IsVisible() then
        reset_watch()
        return
    end
    if G.mode ~= mode or G.since <= 0 then
        G.mode = mode
        G.since = now
        return
    end
    -- MarketWorker waits up to 10 s for a pending safe boundary, but once AUX
    -- reports fully paused it should close AH within its 3 s close timeout.
    local limit = mode == 'paused' and 4.0 or 12.0
    if now - G.since >= limit then
        release(mode .. '-with-visible-ah')
    end
end

local frame = CreateFrame('Frame', 'AuxFastServiceHandoffGuard')
frame:SetScript('OnUpdate', function()
    local now = GetTime()
    if now < (G.nextTick or 0) then return end
    G.nextTick = now + 0.25
    tick(now)
end)

SLASH_AUXFASTRELEASE1 = '/auxrelease'
SlashCmdList['AUXFASTRELEASE'] = function()
    if release('manual-command') then return end
    out('service handoff already released or bridge unavailable')
end
