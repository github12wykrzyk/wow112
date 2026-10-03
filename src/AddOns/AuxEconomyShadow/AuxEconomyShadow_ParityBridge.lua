local R = W112_AH_SHADOW
if type(R) ~= "table" or type(R.ReplaceModule) ~= "function" then
    error("AuxEconomyShadow parity bridge requires persistent anchor")
end

local REVISION = "2-scan-done-evidence-hardening"
local ok = R.ReplaceModule("parity_bridge", REVISION, function(state)
    local hotGeneration = tonumber(R.hotPayloadGeneration) or 0
    if tonumber(state.bridgeHotGeneration) ~= hotGeneration then
        state.bridgeHotGeneration = hotGeneration
        state.installed = false
        state.originals = nil
        state.wrappers = nil
        state.statusWrapper = nil
        state.previousStatus = nil
        state.scanning = false
        state.book = nil
        state.materialBook = nil
        state.waitByMat = {}
        state.waitMatBySerial = {}
        state.pageVendorBest = nil
        state.pageDeBest = nil
        state.recordSerial = 0
        state.scanSerial = 0
        state.scans = 0
        state.pages = 0
        state.records = 0
        state.observerErrors = 0
        state.lastError = ""
        state.lastNote = "hot-generation-reset"
        state.lastActiveSource = ""
        state.lastShadowSource = ""
    end

    state.waitByMat = type(state.waitByMat) == "table" and state.waitByMat or {}
    state.waitMatBySerial = type(state.waitMatBySerial) == "table" and state.waitMatBySerial or {}
    state.recordSerial = tonumber(state.recordSerial) or 0
    state.scanSerial = tonumber(state.scanSerial) or 0
    state.scans = tonumber(state.scans) or 0
    state.pages = tonumber(state.pages) or 0
    state.records = tonumber(state.records) or 0
    state.observerErrors = tonumber(state.observerErrors) or 0
    state.lastError = tostring(state.lastError or "")
    state.lastNote = tostring(state.lastNote or "")
    state.lastActiveSource = tostring(state.lastActiveSource or "")
    state.lastShadowSource = tostring(state.lastShadowSource or "")

    local api = {}
    api.revision = REVISION

    local okAux, auxCore = pcall(require, "aux")
    local okHistory, auxHistory = pcall(require, "aux.core.history")
    local okDe, auxDe = pcall(require, "aux.core.disenchant")

    local function now()
        if type(GetTime) == "function" then return tonumber(GetTime()) or 0 end
        return 0
    end

    local function money()
        if type(GetMoney) == "function" then return tonumber(GetMoney()) or 0 end
        return 0
    end

    local function playerName()
        if type(UnitName) == "function" then return tostring(UnitName("player") or "") end
        return ""
    end

    local function snapshotRaw(raw)
        if type(raw) ~= "table" then return nil end
        state.recordSerial = state.recordSerial + 1
        return {
            _shadowSerial = state.recordSerial,
            name = raw.name,
            itemId = raw.itemId,
            item_id = raw.item_id,
            count = raw.count,
            aux_quantity = raw.aux_quantity,
            buyout = raw.buyout,
            buyout_price = raw.buyout_price,
            bidAmount = raw.bidAmount,
            bid_amount = raw.bid_amount,
            bid_price = raw.bid_price,
            blizzard_bid = raw.blizzard_bid,
            start_price = raw.start_price,
            bid = raw.bid,
            quality = raw.quality,
            level = raw.level,
            slot = raw.slot,
            owner = raw.owner,
            itemKey = raw.itemKey,
            item_key = raw.item_key,
            historyKey = raw.historyKey,
            history_key = raw.history_key,
            suffixId = raw.suffixId,
            suffix_id = raw.suffix_id,
            signature = raw.signature,
            sourcePage = raw.sourcePage,
            page = raw.page,
            maxStack = raw.maxStack,
            max_stack = raw.max_stack,
            duration = raw.duration,
            highBidder = raw.highBidder,
            high_bidder = raw.high_bidder,
            unitExact = raw.unitExact,
            unit_buyout_price = raw.unit_buyout_price,
            blizzard_query = raw.blizzard_query,
        }
    end

    local function activeRecent(signature)
        local recent = AVM and AVM.recent
        local untilTime = type(recent) == "table" and tonumber(recent[tostring(signature or "")]) or nil
        return untilTime ~= nil and untilTime > now()
    end

    local function activeBidRecent(signature, record)
        if activeRecent(signature) then return true end
        local recent = AVM and AVM.recent
        if type(recent) ~= "table" or type(record) ~= "table" then return false end
        local itemKey = tostring(record.itemKey or record.item_key or "")
        if itemKey == "" then return false end
        local t = now()
        return (tonumber(recent["BIDRECENT|bid-vendor|" .. itemKey]) or 0) > t or
            (tonumber(recent["BIDRECENT|bid-de|" .. itemKey]) or 0) > t
    end

    local function history(record)
        if not okHistory or type(auxHistory) ~= "table" or type(auxHistory.value) ~= "function" then return nil end
        local key = tostring(record and (record.historyKey or record.history_key or record.itemKey or record.item_key or record.itemId) or "")
        if key == "" then return nil end
        local okValue, value = pcall(auxHistory.value, key)
        value = okValue and tonumber(value) or nil
        if not value or value <= 0 then return nil end
        local days = 0
        if type(auxHistory.data_points) == "function" then
            local okPoints, points = pcall(auxHistory.data_points, key)
            if okPoints and type(points) == "table" then days = table.getn(points) end
        end
        return { value = value, days = days, key = key }
    end

    local function distribution(record)
        local itemId = tonumber(record and (record.itemId or record.item_id))
        if itemId and type(AVM_TURTLE_DISENCHANT_IDS) == "table" then
            local deId = tonumber(AVM_TURTLE_DISENCHANT_IDS[itemId])
            if deId and deId > 0 then
                local dist = type(AVM_TURTLE_DISENCHANT_LOOT) == "table" and AVM_TURTLE_DISENCHANT_LOOT[deId] or nil
                if type(dist) == "table" and table.getn(dist) > 0 then return dist, "turtle-db", deId, nil end
            end
            if type(AVM_TURTLE_DISENCHANT_BLOCK) == "table" and AVM_TURTLE_DISENCHANT_BLOCK[itemId] then
                return nil, "turtle-db", 0, "turtle-not-disenchantable"
            end
        end
        if not okDe or type(auxDe) ~= "table" or type(auxDe.distribution) ~= "function" then
            return nil, "aux-fallback", 0, "no-de-module"
        end
        local okDist, dist = pcall(auxDe.distribution,
            record and record.slot,
            record and record.quality,
            tonumber(record and record.level) or 0,
            itemId)
        if not okDist then return nil, "aux-fallback", 0, "fallback-error" end
        if type(dist) ~= "table" or table.getn(dist) == 0 then return nil, "aux-fallback", 0, "no-distribution" end
        return dist, "aux-fallback", 0, nil
    end

    local function context()
        local merchantSell = nil
        if okAux and type(auxCore) == "table" and type(auxCore.account_data) == "table" then
            merchantSell = auxCore.account_data.merchant_sell
        end
        local db = type(AVM_DB) == "table" and AVM_DB or {}
        local avm = type(AVM) == "table" and AVM or {}
        local exposure = type(avm.deExposure) == "table" and avm.deExposure or {}
        return {
            config = db,
            money = money(),
            playerName = playerName(),
            merchantSell = type(merchantSell) == "table" and merchantSell or {},
            vendorValues = type(AVM_VENDOR_VALUES) == "table" and AVM_VENDOR_VALUES or {},
            recent = activeRecent,
            bidRecent = activeBidRecent,
            history = history,
            distribution = distribution,
            disenchantBlocked = type(AVM_TURTLE_DISENCHANT_BLOCK) == "table" and AVM_TURTLE_DISENCHANT_BLOCK or {},
            materialBook = state.materialBook,
            exposureReady = exposure.ready and true or false,
            exposureBook = type(exposure.book) == "table" and exposure.book or {},
            itemExposure = type(avm.itemExposure) == "table" and avm.itemExposure or {},
            sessionBids = tonumber(avm.sessionBids) or 0,
            enabledStrategies = {
                vendor = true,
                disenchant = true,
                flip = db.flipEnabled ~= false,
                stack = db.stackArbEnabled ~= false,
                bid = db.bidArbEnabled ~= false,
            },
        }
    end

    local function better(candidate, current)
        local contracts = R.GetModule("contracts")
        return contracts and type(contracts.BetterCandidate) == "function" and contracts.BetterCandidate(candidate, current) or false
    end

    local function clearWait(raw)
        local serial = raw and tostring(raw._shadowSerial or "") or ""
        if serial == "" then return end
        local oldMat = state.waitMatBySerial[serial]
        if oldMat then
            local bucket = state.waitByMat[oldMat]
            if type(bucket) == "table" then bucket[serial] = nil end
            state.waitMatBySerial[serial] = nil
        end
    end

    local function setWait(raw, reason)
        clearWait(raw)
        local _, _, matText = string.find(tostring(reason or ""), "^no%-depth:(%d+)$")
        local matId = tonumber(matText)
        if not matId then return false end
        local serial = tostring(raw and raw._shadowSerial or "")
        if serial == "" then return false end
        local bucket = state.waitByMat[matId]
        if type(bucket) ~= "table" then bucket = {} state.waitByMat[matId] = bucket end
        bucket[serial] = raw
        state.waitMatBySerial[serial] = matId
        return true
    end

    local function evaluateDe(raw)
        local de = R.GetModule("disenchant")
        if not de or type(de.Evaluate) ~= "function" then return nil, "de-unavailable" end
        local ctx = context()
        ctx.materialBook = state.materialBook
        local candidate, reason = de.Evaluate(raw, ctx)
        if candidate then
            clearWait(raw)
            if candidate.affordable and better(candidate, state.pageDeBest) then state.pageDeBest = candidate end
            return candidate, nil
        end
        setWait(raw, reason)
        return nil, reason
    end

    local function wakeMaterial(itemId)
        itemId = tonumber(itemId)
        local bucket = itemId and state.waitByMat[itemId] or nil
        if type(bucket) ~= "table" then return end
        local pending = {}
        for serial, raw in pairs(bucket) do
            pending[table.getn(pending) + 1] = raw
            state.waitMatBySerial[serial] = nil
        end
        state.waitByMat[itemId] = nil
        for i = 1, table.getn(pending) do evaluateDe(pending[i]) end
    end

    local function observeAuction(raw)
        if not state.scanning then return end
        local snap = snapshotRaw(raw)
        if not snap then return end
        state.records = state.records + 1

        local marketbook = R.GetModule("marketbook")
        if marketbook and type(marketbook.Add) == "function" and state.book then marketbook.Add(state.book, snap) end

        local de = R.GetModule("disenchant")
        if de and type(de.AddMaterialOffer) == "function" and type(state.materialBook) == "table" then
            de.AddMaterialOffer(state.materialBook,
                tonumber(snap.itemId or snap.item_id), snap.name,
                tonumber(snap.count or snap.aux_quantity) or 0,
                tonumber(snap.buyout or snap.buyout_price) or 0, nil)
            wakeMaterial(tonumber(snap.itemId or snap.item_id))
        end

        local vendor = R.GetModule("vendor")
        if vendor and type(vendor.Evaluate) == "function" then
            local vc = vendor.Evaluate(snap, context())
            if vc and better(vc, state.pageVendorBest) then state.pageVendorBest = vc end
        end
        evaluateDe(snap)
    end

    local function resetLogicalScan(resume, filterString)
        if not resume or not state.scanning then
            local marketbook = R.GetModule("marketbook")
            local de = R.GetModule("disenchant")
            state.scanSerial = state.scanSerial + 1
            state.scans = state.scans + 1
            state.book = marketbook and type(marketbook.New) == "function" and marketbook.New("passive-parity") or nil
            state.materialBook = de and type(de.NewMaterialBook) == "function" and de.NewMaterialBook() or {}
            state.waitByMat = {}
            state.waitMatBySerial = {}
            state.recordSerial = 0
            state.scanPages = 0
            state.filter = tostring(filterString or "")
        end
        state.pageVendorBest = nil
        state.pageDeBest = nil
        state.scanning = true
    end

    local function activeCanBuy()
        if type(AVM_DB) ~= "table" or not AVM_DB.auxArbLive then return false end
        local maxBuys = tonumber(AVM_DB.maxSessionBuys) or 0
        local buys = AVM and tonumber(AVM.sessionBuys) or 0
        if maxBuys > 0 and buys >= maxBuys then return false end
        return true
    end

    local function shadowPageDecision()
        if not activeCanBuy() then return nil end
        if state.pageVendorBest and state.pageVendorBest.affordable then return state.pageVendorBest end
        if state.pageDeBest and state.pageDeBest.affordable then return state.pageDeBest end
        return nil
    end

    local function activeScanDoneDecision()
        local avm = type(AVM) == "table" and AVM or nil
        local arb = avm and type(avm.auxArb) == "table" and avm.auxArb or nil
        if arb and arb.postscanCandidate then return arb.postscanCandidate, "postscanCandidate" end
        if arb and arb.candidate then return arb.candidate, "auxArb.candidate" end
        if avm and avm.candidate then return avm.candidate, "AVM.candidate" end
        if avm and avm.bidCandidate then return avm.bidCandidate, "AVM.bidCandidate" end
        return nil, "none"
    end

    local function publish(note)
        state.lastNote = tostring(note or state.lastNote or "")
        local parity = R.GetModule("parity")
        local summary = parity and type(parity.Summary) == "function" and parity.Summary() or {}
        local ready, reason = false, "parity-unavailable"
        if parity and type(parity.CutoverGate) == "function" then ready, reason = parity.CutoverGate() end
        if type(AVM_DB) == "table" then
            AVM_DB.diag = type(AVM_DB.diag) == "table" and AVM_DB.diag or {}
            AVM_DB.diag.shadowParity = {
                revision = REVISION,
                installed = state.installed and true or false,
                hooksIntact = api.HooksIntact and api.HooksIntact() or false,
                scans = state.scans,
                pages = state.pages,
                records = state.records,
                observerErrors = state.observerErrors,
                lastError = state.lastError,
                lastNote = state.lastNote,
                lastActiveSource = state.lastActiveSource,
                lastShadowSource = state.lastShadowSource,
                decisionCompared = tonumber(summary.decisionCompared) or 0,
                decisionMatched = tonumber(summary.decisionMatched) or 0,
                decisionMatchPct = tonumber(summary.decisionMatchPct) or 0,
                counts = summary.counts or {},
                cutoverReady = ready and true or false,
                cutoverReason = tostring(reason or ""),
                hotPayloadGeneration = tonumber(R.hotPayloadGeneration) or 0,
            }
        end
    end

    local function observerFailure(where, err)
        state.observerErrors = state.observerErrors + 1
        state.lastError = tostring(where or "observer") .. ":" .. tostring(err or "unknown")
        publish("observer-error")
    end

    local function observeStart(resume, filterString)
        local active = AVM and AVM.auxArb and AVM.auxArb.active
        if not active then state.scanning = false publish("scan-inactive") return end
        resetLogicalScan(resume and true or false, filterString)
        publish(resume and "scan-resume" or "scan-start")
    end

    local function observePageDone(page, activePause)
        if not state.scanning then return end
        state.pages = state.pages + 1
        state.scanPages = (tonumber(state.scanPages) or 0) + 1
        local activeCandidate = nil
        if activePause and AVM and AVM.auxArb then activeCandidate = AVM.auxArb.candidate end
        local shadowCandidate = shadowPageDecision()
        local parity = R.GetModule("parity")
        if parity and type(parity.RecordDecision) == "function" then
            parity.RecordDecision(activeCandidate, shadowCandidate, now(), "page:" .. tostring(page or 0))
        end
        state.pageVendorBest = nil
        state.pageDeBest = nil
        publish("page-done")
    end

    local function observeScanDone()
        if not state.scanning then return end
        local pipeline = R.GetModule("pipeline")
        local shadowCandidate = nil
        if pipeline and type(pipeline.EvaluateBook) == "function" and state.book then
            local result = pipeline.EvaluateBook(state.book, context())
            if type(result) == "table" then
                shadowCandidate = result.selected
                state.lastShadowSource = tostring(result.selectionSource or "none")
            end
        end
        if not activeCanBuy() then shadowCandidate = nil state.lastShadowSource = "active-live-disabled" end
        local activeCandidate, activeSource = activeScanDoneDecision()
        state.lastActiveSource = activeSource
        local parity = R.GetModule("parity")
        if parity and type(parity.RecordDecision) == "function" then
            parity.RecordDecision(activeCandidate, shadowCandidate, now(), "scan-done")
        end
        state.scanning = false
        publish("scan-done")
    end

    function api.HooksIntact()
        if not state.installed or type(state.wrappers) ~= "table" then return false end
        return AVM_AuxArbScanStart == state.wrappers.scanStart and
            AVM_AuxArbAuction == state.wrappers.auction and
            AVM_AuxArbPageDone == state.wrappers.pageDone and
            AVM_AuxArbScanDone == state.wrappers.scanDone
    end

    function api.Status()
        local parity = R.GetModule("parity")
        return {
            revision = REVISION,
            installed = state.installed and true or false,
            hooksIntact = api.HooksIntact(),
            scanning = state.scanning and true or false,
            scanSerial = state.scanSerial,
            scans = state.scans,
            pages = state.pages,
            records = state.records,
            observerErrors = state.observerErrors,
            lastError = state.lastError,
            lastNote = state.lastNote,
            lastActiveSource = state.lastActiveSource,
            lastShadowSource = state.lastShadowSource,
            parity = parity and type(parity.Summary) == "function" and parity.Summary() or nil,
        }
    end

    function api.install(reason)
        if api.HooksIntact() then return true end
        if type(AVM_AuxArbScanStart) ~= "function" or type(AVM_AuxArbAuction) ~= "function" or
           type(AVM_AuxArbPageDone) ~= "function" or type(AVM_AuxArbScanDone) ~= "function" then
            state.installed = false
            state.lastError = "active-avm-callbacks-unavailable"
            publish("install-deferred")
            return false
        end

        state.originals = {
            scanStart = AVM_AuxArbScanStart,
            auction = AVM_AuxArbAuction,
            pageDone = AVM_AuxArbPageDone,
            scanDone = AVM_AuxArbScanDone,
        }
        state.wrappers = {}
        state.wrappers.scanStart = function(resume, filterString)
            local result = state.originals.scanStart(resume, filterString)
            local okObserve, errObserve = pcall(observeStart, resume, filterString)
            if not okObserve then observerFailure("scan-start", errObserve) end
            return result
        end
        state.wrappers.auction = function(raw)
            local result = state.originals.auction(raw)
            local okObserve, errObserve = pcall(observeAuction, raw)
            if not okObserve then observerFailure("auction", errObserve) end
            return result
        end
        state.wrappers.pageDone = function(page, lastPage)
            local result = state.originals.pageDone(page, lastPage)
            local okObserve, errObserve = pcall(observePageDone, page, result and true or false)
            if not okObserve then observerFailure("page-done", errObserve) end
            return result
        end
        state.wrappers.scanDone = function()
            local result = state.originals.scanDone()
            local okObserve, errObserve = pcall(observeScanDone)
            if not okObserve then observerFailure("scan-done", errObserve) end
            return result
        end

        AVM_AuxArbScanStart = state.wrappers.scanStart
        AVM_AuxArbAuction = state.wrappers.auction
        AVM_AuxArbPageDone = state.wrappers.pageDone
        AVM_AuxArbScanDone = state.wrappers.scanDone
        state.previousStatus = W112_AH_SHADOW_PARITY_STATUS
        state.statusWrapper = function() return api.Status() end
        W112_AH_SHADOW_PARITY_STATUS = state.statusWrapper
        state.installed = true
        state.lastError = ""
        state.lastNote = "installed:" .. tostring(reason or "")
        local parity = R.GetModule("parity")
        if parity and type(parity.RecordHotGeneration) == "function" then parity.RecordHotGeneration(now()) end
        publish("installed")
        return true
    end

    function api.uninstall(reason)
        if type(state.originals) == "table" and type(state.wrappers) == "table" then
            if AVM_AuxArbScanStart == state.wrappers.scanStart then AVM_AuxArbScanStart = state.originals.scanStart end
            if AVM_AuxArbAuction == state.wrappers.auction then AVM_AuxArbAuction = state.originals.auction end
            if AVM_AuxArbPageDone == state.wrappers.pageDone then AVM_AuxArbPageDone = state.originals.pageDone end
            if AVM_AuxArbScanDone == state.wrappers.scanDone then AVM_AuxArbScanDone = state.originals.scanDone end
        end
        if W112_AH_SHADOW_PARITY_STATUS == state.statusWrapper then W112_AH_SHADOW_PARITY_STATUS = state.previousStatus end
        state.installed = false
        state.scanning = false
        state.lastNote = "uninstalled:" .. tostring(reason or "")
        return true
    end

    return api
end)
if not ok then error(R.lastHotError or "parity bridge replacement failed") end
