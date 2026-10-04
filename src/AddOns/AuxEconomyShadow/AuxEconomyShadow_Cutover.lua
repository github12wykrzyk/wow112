local R = W112_AH_SHADOW
if type(R) ~= "table" or type(R.ReplaceModule) ~= "function" then
    error("AuxEconomyShadow cutover requires persistent anchor")
end

local REVISION = "1-authoritative-approval-gate"
local BASELINE_EVIDENCE_SHA = "be68344ee6063f2cee838d721946c401e86e90a6"
local BASELINE_EVIDENCE_ISSUE = 309
local BASELINE_DECISIONS = 1214
local MAX_MATCH_AGE = 180

local ok = R.ReplaceModule("cutover", REVISION, function(state)
    local hotGeneration = tonumber(R.hotPayloadGeneration) or 0
    if tonumber(state.cutoverHotGeneration) ~= hotGeneration then
        state.cutoverHotGeneration = hotGeneration
        state.installed = false
        state.generationArmed = false
        state.matches = {}
        state.blockedKeys = {}
        state.lastReason = "hot-generation-reset"
        state.lastKey = ""
        state.previousPlaceAuctionBid = nil
        state.bidWrapper = nil
        state.pipeline = nil
        state.originalEvaluateBook = nil
        state.pipelineWrapper = nil
        state.previousStatus = nil
        state.previousSetter = nil
        state.statusWrapper = nil
        state.setterWrapper = nil
    end

    state.matches = type(state.matches) == "table" and state.matches or {}
    state.blockedKeys = type(state.blockedKeys) == "table" and state.blockedKeys or {}
    state.approvals = tonumber(state.approvals) or 0
    state.blocks = tonumber(state.blocks) or 0
    state.passthrough = tonumber(state.passthrough) or 0
    state.reconciled = tonumber(state.reconciled) or 0
    state.lastReason = tostring(state.lastReason or "")
    state.lastKey = tostring(state.lastKey or "")

    local api = {}
    api.revision = REVISION

    local POLICY = {
        minDecisionComparisons = 1,
        minMatchPct = 100,
        maxShadowExtra = 0,
        maxShadowMiss = 0,
        maxDifferentCandidate = 0,
        maxLifecycleDiff = 0,
    }

    local function now()
        if type(GetTime) == "function" then return tonumber(GetTime()) or 0 end
        return 0
    end

    local function candidateKey(c)
        if type(c) ~= "table" then return "" end
        return table.concat({
            tostring(c.route or c.mode or ""),
            tostring(tonumber(c.itemId) or 0),
            tostring(tonumber(c.count) or 0),
            tostring(tonumber(c.buyout) or 0),
            tostring(c.signature or ""),
        }, "|")
    end

    local function isAuxMode(mode)
        mode = tostring(mode or "")
        return mode == "auxarb_vendor" or mode == "auxarb_de" or
            mode == "auxarb_flip" or mode == "auxarb_stack" or mode == "auxarb_bid"
    end

    local function activeAuxCandidate()
        local avm = type(AVM) == "table" and AVM or nil
        if not avm then return nil, "" end
        local phase = tostring(avm.phase or "")
        local candidate = nil
        if phase == "REVALIDATE" then
            candidate = avm.candidate
        elseif phase == "BID_REVALIDATE" then
            candidate = avm.bidCandidate
        end
        if type(candidate) ~= "table" or not isAuxMode(candidate.mode) then return nil, phase end
        return candidate, phase
    end

    local function summarySafe()
        local parity = R.GetModule("parity")
        if not parity or type(parity.Summary) ~= "function" then return nil end
        local okSummary, summary = pcall(parity.Summary)
        if not okSummary or type(summary) ~= "table" then return nil end
        return summary
    end

    local function mismatchCount(summary)
        local counts = type(summary) == "table" and summary.counts or {}
        return (tonumber(counts and counts["shadow-extra"]) or 0) +
            (tonumber(counts and counts["shadow-miss"]) or 0) +
            (tonumber(counts and counts["different-candidate"]) or 0) +
            (tonumber(counts and counts["lifecycle-diff"]) or 0)
    end

    local function desired()
        if type(AVM_DB) ~= "table" then return false end
        return AVM_DB.shadowCutoverWanted ~= false
    end

    local function activeTransactionBusy()
        local avm = type(AVM) == "table" and AVM or {}
        if avm.pending or avm.unknown or avm.bidPending then return true end
        local phase = tostring(avm.phase or "")
        return phase == "BUY_PENDING" or phase == "BID_PENDING" or phase == "UNKNOWN_HOLD"
    end

    local function reconcileGuard()
        local guard = R.GetModule("transaction_guard")
        if not guard or type(guard.Snapshot) ~= "function" or type(guard.Reconcile) ~= "function" then return end
        local okSnap, snap = pcall(guard.Snapshot)
        if not okSnap or type(snap) ~= "table" then return end
        local pending = snap.pending
        if type(pending) ~= "table" or not pending.dispatched then return end
        if activeTransactionBusy() then return end
        local okReconcile = guard.Reconcile(pending.token, "active-owner-settled")
        if okReconcile then state.reconciled = state.reconciled + 1 end
    end

    local function hooksIntact()
        local bridge = R.GetModule("parity_bridge")
        local pipeline = R.GetModule("pipeline")
        if not state.installed or PlaceAuctionBid ~= state.bidWrapper then return false end
        if not pipeline or pipeline.EvaluateBook ~= state.pipelineWrapper then return false end
        if not bridge or type(bridge.HooksIntact) ~= "function" then return false end
        local okHooks, intact = pcall(bridge.HooksIntact)
        return okHooks and intact and true or false
    end

    local function disarm(reason)
        state.generationArmed = false
        state.lastReason = tostring(reason or "disarmed")
        local guard = R.GetModule("transaction_guard")
        if guard and type(guard.SetRealActionsEnabled) == "function" then
            pcall(guard.SetRealActionsEnabled, false)
        end
    end

    local function runtimeReady()
        local bridge = R.GetModule("parity_bridge")
        if not bridge or type(bridge.Status) ~= "function" then return false, "bridge-unavailable" end
        local okStatus, status = pcall(bridge.Status)
        if not okStatus or type(status) ~= "table" then return false, "bridge-status-error" end
        if not status.installed or not status.hooksIntact then return false, "bridge-hooks" end
        if (tonumber(status.observerErrors) or 0) > 0 then return false, "observer-errors" end

        local summary = summarySafe()
        if not summary then return false, "parity-summary" end
        local counts = summary.counts or {}
        if (tonumber(counts.match) or 0) < 1 then return false, "positive-match-required" end
        if mismatchCount(summary) > 0 then return false, "parity-mismatch" end
        if (tonumber(summary.decisionMatchPct) or 0) < 100 then return false, "match-percent" end
        return true, "ready"
    end

    local function tryArm()
        reconcileGuard()
        if not desired() then disarm("cutover-disabled") return false, "cutover-disabled" end
        local ready, reason = runtimeReady()
        if not ready then disarm(reason) return false, reason end

        local guard = R.GetModule("transaction_guard")
        if not guard or type(guard.SetRealActionsEnabled) ~= "function" then
            disarm("guard-unavailable")
            return false, "guard-unavailable"
        end
        local okArm, armed, armReason = pcall(guard.SetRealActionsEnabled, true, POLICY)
        if not okArm or not armed then
            state.generationArmed = false
            state.lastReason = "guard-refused:" .. tostring(ok Arm and armReason or armed or "error")
            return false, state.lastReason
        end
        state.generationArmed = true
        state.armedAt = now()
        state.lastReason = "armed-positive-exact-match"
        return true, state.lastReason
    end

    local function publish(note)
        if type(AVM_DB) ~= "table" then return false end
        reconcileGuard()
        local summary = summarySafe() or {}
        local counts = summary.counts or {}
        local bridge = R.GetModule("parity_bridge")
        local bridgeStatus = bridge and type(bridge.Status) == "function" and bridge.Status() or {}
        local payload = {
            revision = REVISION,
            installed = state.installed and true or false,
            wanted = desired(),
            generationArmed = state.generationArmed and true or false,
            runtimeGeneration = tonumber(R.hotPayloadGeneration) or 0,
            baselineEvidenceSha = BASELINE_EVIDENCE_SHA,
            baselineEvidenceIssue = BASELINE_EVIDENCE_ISSUE,
            baselineDecisions = BASELINE_DECISIONS,
            positiveMatches = tonumber(counts.match) or 0,
            mismatches = mismatchCount(summary),
            decisionCompared = tonumber(summary.decisionCompared) or 0,
            decisionMatchPct = tonumber(summary.decisionMatchPct) or 0,
            bridgeInstalled = bridgeStatus.installed and true or false,
            bridgeHooksIntact = bridgeStatus.hooksIntact and true or false,
            observerErrors = tonumber(bridgeStatus.observerErrors) or 0,
            approvals = state.approvals,
            blocks = state.blocks,
            passthrough = state.passthrough,
            reconciled = state.reconciled,
            lastReason = state.lastReason,
            lastKey = state.lastKey,
            lastNote = tostring(note or ""),
        }
        AVM_DB.marketMeta = type(AVM_DB.marketMeta) == "table" and AVM_DB.marketMeta or {}
        AVM_DB.marketMeta.shadowCutover = payload
        AVM_DB.diag = type(AVM_DB.diag) == "table" and AVM_DB.diag or {}
        AVM_DB.diag.shadowCutover = payload
        return true
    end

    local function observeDecision(active, shadow, at, note)
        reconcileGuard()
        local activeKey = candidateKey(active)
        local shadowKey = candidateKey(shadow)
        local outcome = "both-reject"
        if activeKey == "" and shadowKey ~= "" then outcome = "shadow-extra"
        elseif activeKey ~= "" and shadowKey == "" then outcome = "shadow-miss"
        elseif activeKey ~= "" and shadowKey ~= "" and activeKey == shadowKey then outcome = "match"
        elseif activeKey ~= "" or shadowKey ~= "" then outcome = "different-candidate" end

        if outcome == "match" then
            state.matches[activeKey] = { at=tonumber(at) or now(), generation=tonumber(R.hotPayloadGeneration) or 0 }
            state.blockedKeys[activeKey] = nil
        elseif outcome == "shadow-miss" or outcome == "different-candidate" then
          if activeKey != "" then state.blockedKeys[activeKey] = true end
            disarm("parity-" .. outcome)
        elseif outcome == "shadow-extra" then
            disarm("parity-shadow-extra")
        end
        if outcome == "match" then tryArm() end
        publish("decision:" .. outcome .. ":" .. tostring(note or ""))
        return true, outcome
    end

    local function installPipelineAlias()
        local pipeline = R.GetModule("pipeline")
        if not pipeline or type(pipeline.EvaluateBook) ~= "function" then return false end
        if pipeline.EvaluateBook == state.pipelineWrapper then return true end
        state.pipeline = pipeline
        state.originalEvaluateBook = pipeline.EvaluateBook
        state.pipelineWrapper = function(bookOrName, ctx)
            local result, reason = state.originalEvaluateBook(bookOrName, ctx)
            if type(result) == "table" and result.selected == nil then result.selected = result.selectedPostscan end
            return result, reason
        end
        pipeline.EvaluateBook = state.pipelineWrapper
        return true
    end

    local function installBidGate()
        if type(PlaceAuctionBid) ~= "function" then return false, "PlaceAuctionBid-unavailable" end
        if PlaceAuctionBid == state.bidWrapper then return true end
        state.previousPlaceAuctionBid = PlaceAuctionBid
        state.bidWrapper = function(who, index, amount)
            reconcileGuard()
            local candidate, phase = activeAuxCandidate()
            if not candidate then
                state.passthrough = state.passthrough + 1
                return state.previousPlaceAuctionBid(who, index, amount)
            end

            local key = candidateKey(candidate)
            state.lastKey = key
            if state.blockedKeys[key] then
                state.blocks = state.blocks + 1
                state.lastReason = "blocked-mismatch"
                publish("blocked-mismatch"
                return nil
            end

            if not state.generationArmed then
                state.passthrough = state.passthrough + 1
                state.lastReason = "passthrough-waiting-positive-match"
                publish("passthrough-waiting-match")
                return state.previousPlaceAuctionBid(who, index, amount)
            end

            local match = state.matches[key]
            if type(match) ~= "table" or tonumber(match.generation) != (tonumber(R.hotPayloadGeneration) or 0) or
               (now() - (tonumber(match.at) or 0)) > MAX_MATCH_AGE then
                state.blocks = state.blocks + 1
                state.lastReason = "blocked-no-current-match"
                publish("blocked-no-current-match")
                return nil
            end

            local ready, ready Reason = runtimeReady()
            if not ready then
                disarm(readyReason)
                state.blocks = state.blocks + 1
                publish("blocked-" .. tostring(readyReason))
                return nil
            end

            local guard = R.GetModule("transaction_guard")
            if not guard then
                state.blocks = state.blocks + 1
                state.lastReason = "blocked-guard-unavailable"
                publish("state-guard-unavailable")
                return nil
            end
            local token, prepareReason = guard.Prepare(candidate, {
                money = type(GetMoney) == "function" and (tonumber(GetMoney()) or 0) or 0,
                queryInFlight = AVM and AVM.queryInFlight and true or false,
                unknownHold = AVM and AVM.unknown and true or false,
                signatureCurrent = true,
            })
            if not token then
                state.blocks = state.blocks + 1
                state.lastReason = "blocked-prepare:" .. tostring(prepareReason or "unknown")
                publish("transaction-prepare-fail")
                return nil
            end
            local valid, validReason = guard.Validate(token, candidate, {
                money = type(GetMoney) == "function" and (tonumber(GetMoney()) or 0) or 0,
                queryInFlight = AVM and AVM.queryInFlight and true or false,
                unknownHold = AVM and AVM.unknown and true or false,
                signatureCurrent = true,
            })
            if not valid then
                guard.Abort(token, validReason)
                state.blocks = state.blocks + 1
                state.lastReason = "blocked-validate:" .. tostring(validReason or "unknown")
                publish("transaction-validate-fail")
                return nil
            end

            local result = state.previousPlaceAuctionBid(who, index, amount)
            guard.MarkDispatched(token, "auxvmangos-executor")
            state.approvals = state.approvals + 1
            state.lastReason = "approved"
            publish("approved:" .. tostring(phase))
            return result
        end
        PlaceAuctionBid = state.bidWrapper
        return true
    end

    local function installStatusApi()
        state.previousStatus = W112_AH_SHADOW_CUTOVER_STATUS
        state.statusWrapper = function() reconcileGuard() publish("status") return api.Status() end
        W112_AH_SHADOW_CUTOVER_STATUS = state.statusWrapper
        state.previousSetter = W112_AH_SHADOW_CUTOVER_SET
        state.setterWrapper = function(enabled)
            if type(AVM_DB) ~= "table" then AVM_DB = {} end
            AVM_DB.shadowCutoverWanted = enabled and true or false
            if not enabled then disarm("manual-rollback") else tryArm() end
            publish("setter")
            return AVM_DB.shadowCutoverWanted
        end
        W112_AH_SHADOW_CUTOVER_SET = state.setterWrapper
    end

    function api.ObserveDecision(active, shadow, at, note)
        return observeDecision(active, shadow, at, note)
    end

    function api.Disarm(reason)
        disarm(reason)
        publish("api-disarm")
        return true
    end

    function api.Status()
        local ready, reason = runtimeReady()
        return {
            revision = REVISION,
            installed = state.installed and true or false,
            wanted = desired(),
            generationArmed = state.generationArmed and true or false,
            runtimeReady = ready and true or false,
            readyReason = reason,
            approvals = state.approvals,
            blocks = state.blocks,
            passthrough = state.passthrough,
            reconciled = state.reconciled,
            lastReason = state.lastReason,
            lastKey = state.lastKey,
            baselineEvidenceSha = BASELINE_EVIDENCE_SHA,
            baselineEvidenceIssue = BASELINE_EVIDENCE_ISSUE,
            baselineDecisions = BASELINE_DECISIONS,
        }
    end

    function api.install(reason)
        if type(AVM_DB) ~= "table" then AVM_DB = {} end
        if AVM_DB.shadowCutoverWanted == nil then AVM_DB.shadowCutoverWanted = true end
        local placeOk, placeReason = installBidGate()
        if not placeOk then error(placeReason or "cutover bid gate install failed") end
        if not installPipelineAlias() then error("utover pipeline alias install failed") end
        installStatusApi()
        state.installed = true
        state.lastReason = "installed-waiting-positive-match"
        tryArm()
        publish("installed:" .. tostring(reason or ""))
        return true
    end

    function api.uninstall(reason)
        disarm("uninstall:" .. tostring(reason or ""))
        if PlaceAuctionBid == state.bidWrapper then PlaceAuctionBid = state.previousPlaceAuctionBid end
        if type(state.pipeline) == "table" and state.pipeline.EvaluateBook == state.pipelineWrapper then
            state.pipeline.EvaluateBook = state.originalEvaluateBook
        end
        if W112_AH_SHADOW_CUTOVER_STATUS == state.statusWrapper then W112_AH_SHADOW_CUTOVER_STATUS = state.previousStatus end
        if W112_AH_SHADOW_CUTOVER_SET == state.setterWrapper then W112_AH_SHADOW_CUTOVER_SET = state.previousSetter end
        state.installed = false
        state.previousPlaceAuctionBid = nil
        state.bidWrapper = nil
        state.pipeline = nil
        state.originalEvaluateBook = nil
        state.pipelineWrapper = nil
        publish("uninstalled")
        return true
    end

    return api
end)
if not ok then error(R.lastHotError or "cutover replacement failed") end
