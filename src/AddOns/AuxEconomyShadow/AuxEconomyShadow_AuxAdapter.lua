local R = W112_AH_SHADOW
if type(R) ~= "table" or type(R.ReplaceModule) ~= "function" then
    error("AuxEconomyShadow AUX adapter requires persistent anchor")
end

local REVISION = "1-observation-only"
local ok = R.ReplaceModule("aux_adapter", REVISION, function(state)
    state.scans = tonumber(state.scans) or 0
    state.records = tonumber(state.records) or 0
    state.pages = tonumber(state.pages) or 0
    state.vendorCandidates = tonumber(state.vendorCandidates) or 0
    state.deCandidates = tonumber(state.deCandidates) or 0
    state.rejects = state.rejects or {}
    state.materialBook = state.materialBook or {}

    local api = {}
    api.revision = REVISION

    local function reject(reason)
        reason = tostring(reason or "unknown")
        state.rejects[reason] = (tonumber(state.rejects[reason]) or 0) + 1
        return nil, reason
    end

    function api.BeginObservedScan(ctx)
        ctx = ctx or {}
        local coordinator = R.GetModule("coordinator")
        local de = R.GetModule("disenchant")
        if not coordinator or not de then return false, "dependencies-unavailable" end
        if not ctx.resume then state.materialBook = de.NewMaterialBook() end
        local okBegin, serialOrReason = coordinator.BeginScan({
            resume = ctx.resume and true or false,
            filter = ctx.filter,
            now = ctx.now,
        })
        if not okBegin then return false, serialOrReason end
        state.scans = state.scans + 1
        state.activeScanSerial = serialOrReason
        return true, serialOrReason
    end

    function api.ObserveMaterialOffer(raw, ctx)
        ctx = ctx or {}
        local de = R.GetModule("disenchant")
        if not de then return false, "de-unavailable" end
        local itemId = tonumber(raw and (raw.itemId or raw.item_id))
        local count = tonumber(raw and (raw.count or raw.aux_quantity)) or 0
        local buyout = tonumber(raw and (raw.buyout or raw.buyout_price)) or 0
        local name = raw and raw.name or ""
        return de.AddMaterialOffer(state.materialBook, itemId, name, count, buyout, ctx.allowedMaterialIds)
    end

    function api.ObserveAuction(raw, ctx)
        ctx = ctx or {}
        local coordinator = R.GetModule("coordinator")
        local vendor = R.GetModule("vendor")
        local de = R.GetModule("disenchant")
        if not coordinator or not vendor or not de then return reject("dependencies-unavailable") end
        local snap = coordinator.Snapshot()
        if not snap or snap.phase ~= "SCANNING" then return reject("not-scanning") end
        state.records = state.records + 1

        api.ObserveMaterialOffer(raw, ctx)

        local vendorCtx = ctx.vendor or ctx
        local vc, vr = vendor.Evaluate(raw, vendorCtx)
        if vc then
            state.vendorCandidates = state.vendorCandidates + 1
            coordinator.ObserveCandidate(vc)
        elseif vr then
            state.rejects["vendor:" .. tostring(vr)] = (tonumber(state.rejects["vendor:" .. tostring(vr)]) or 0) + 1
        end

        local deCtx = ctx.disenchant or {}
        deCtx.materialBook = state.materialBook
        if deCtx.money == nil then deCtx.money = ctx.money end
        local dc, dr = de.Evaluate(raw, deCtx)
        if dc then
            state.deCandidates = state.deCandidates + 1
            coordinator.ObserveCandidate(dc)
        elseif dr then
            state.rejects["de:" .. tostring(dr)] = (tonumber(state.rejects["de:" .. tostring(dr)]) or 0) + 1
        end

        return { vendor = vc, disenchant = dc }, nil
    end

    function api.PageDone()
        local coordinator = R.GetModule("coordinator")
        if not coordinator then return false, "coordinator-unavailable" end
        if not coordinator.PageDone() then return false, "not-scanning" end
        state.pages = state.pages + 1
        return true
    end

    function api.EndObservedScan(reason)
        local coordinator = R.GetModule("coordinator")
        if not coordinator then return false, "coordinator-unavailable" end
        return coordinator.FinishScan(reason or "observed-scan-done")
    end

    function api.RequestObservedPause(reason)
        local coordinator = R.GetModule("coordinator")
        if not coordinator then return false, "coordinator-unavailable" end
        return coordinator.RequestPause(reason or "observed-candidate")
    end

    function api.MarkObservedPaused(reason)
        local coordinator = R.GetModule("coordinator")
        if not coordinator then return false, "coordinator-unavailable" end
        return coordinator.MarkPaused(reason or "observed-bridge-paused")
    end

    function api.Snapshot()
        local coordinator = R.GetModule("coordinator")
        return {
            scans = state.scans,
            records = state.records,
            pages = state.pages,
            vendorCandidates = state.vendorCandidates,
            deCandidates = state.deCandidates,
            activeScanSerial = state.activeScanSerial,
            materialRows = (function()
                local n = 0
                for _ in pairs(state.materialBook or {}) do n = n + 1 end
                return n
            end)(),
            rejects = state.rejects,
            coordinator = coordinator and coordinator.Snapshot() or nil,
        }
    end

    return api
end)
if not ok then error(R.lastHotError or "AUX adapter replacement failed") end
