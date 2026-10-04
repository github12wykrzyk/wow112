local R = W112_AH_SHADOW
if type(R) ~= "table" or type(R.ReplaceModule) ~= "function" then
    error("AuxEconomyShadow parity export requires persistent anchor")
end

local REVISION = "5-persistent-evidence"
local EVIDENCE_SCHEMA = 1
local MIGRATE_REVISION = "4-cutover-decision-feed"
local ok = R.ReplaceModule("parity_export", REVISION, function(state)
    local api = {}
    api.revision = REVISION

    local function copyCounts(source)
        local out = {}
        if type(source) == "table" then
            for k, v in pairs(source) do out[k] = tonumber(v) or 0 end
        end
        return out
    end

    local function zeroSeen()
        return {
            scans = 0,
            pages = 0,
            records = 0,
            observerErrors = 0,
            counts = {},
        }
    end

    local function snapshotCurrent(summary, status)
        return {
            scans = tonumber(status.scans) or 0,
            pages = tonumber(status.pages) or 0,
            records = tonumber(status.records) or 0,
            observerErrors = tonumber(status.observerErrors) or 0,
            counts = copyCounts(summary.counts),
        }
    end

    local function counterDelta(current, previous)
        current = tonumber(current) or 0
        previous = tonumber(previous) or 0
        if current >= previous then return current - previous end
        return current
    end

    local function decisionSummary(counts)
        counts = type(counts) == "table" and counts or {}
        local bothReject = tonumber(counts["both-reject"]) or 0
        local exactMatch = tonumber(counts.match) or 0
        local compared = bothReject + exactMatch +
            (tonumber(counts["shadow-extra"]) or 0) +
            (tonumber(counts["shadow-miss"]) or 0) +
            (tonumber(counts["different-candidate"]) or 0)
        local matched = bothReject + exactMatch
        local pct = 0
        if compared > 0 then pct = matched * 100 / compared end
        local mismatches =
            (tonumber(counts["shadow-extra"]) or 0) +
            (tonumber(counts["shadow-miss"]) or 0) +
            (tonumber(counts["different-candidate"]) or 0) +
            (tonumber(counts["lifecycle-diff"]) or 0)
        return compared, matched, pct, mismatches
    end

    local function evidenceKey(parity, status)
        return "parity=" .. tostring(parity.revision or "") ..
            "|bridge=" .. tostring(status.revision or "")
    end

    local function newEvidence(key, parity, status)
        return {
            schemaVersion = EVIDENCE_SCHEMA,
            compatibilityKey = key,
            parityRevision = tostring(parity.revision or ""),
            bridgeRevision = tostring(status.revision or ""),
            scans = 0,
            pages = 0,
            records = 0,
            observerErrors = 0,
            counts = {},
            updates = 0,
            migratedFromRevision = "",
            lastError = "",
            lastNote = "",
        }
    end

    local function migrateLegacy(evidence, old, status)
        if type(old) ~= "table" then return false end
        if tostring(old.revision or "") ~= MIGRATE_REVISION then return false end
        if tostring(old.sourceRevision or "") ~= tostring(status.revision or "") then return false end
        evidence.scans = tonumber(old.scans) or 0
        evidence.pages = tonumber(old.pages) or 0
        evidence.records = tonumber(old.records) or 0
        evidence.observerErrors = tonumber(old.observerErrors) or 0
        evidence.counts = copyCounts(old.counts)
        evidence.lastError = tostring(old.lastError or "")
        evidence.lastNote = "migrated-legacy-shadowParity"
        evidence.migratedFromRevision = MIGRATE_REVISION
        return true
    end

    local function ensureEvidence(parity, summary, status)
        AVM_DB.marketMeta = type(AVM_DB.marketMeta) == "table" and AVM_DB.marketMeta or {}
        local key = evidenceKey(parity, status)
        local evidence = AVM_DB.marketMeta.shadowParityEvidence
        local valid = type(evidence) == "table" and
            tonumber(evidence.schemaVersion) == EVIDENCE_SCHEMA and
            tostring(evidence.compatibilityKey or "") == key

        if not valid then
            local old = AVM_DB.marketMeta.shadowParity
            evidence = newEvidence(key, parity, status)
            local migrated = migrateLegacy(evidence, old, status)
            AVM_DB.marketMeta.shadowParityEvidence = evidence
            state.evidenceKey = key
            if migrated then
                state.lastSeen = snapshotCurrent(summary, status)
            else
                state.lastSeen = zeroSeen()
            end
        elseif tostring(state.evidenceKey or "") ~= key then
            state.evidenceKey = key
            state.lastSeen = zeroSeen()
        end

        state.lastSeen = type(state.lastSeen) == "table" and state.lastSeen or zeroSeen()
        state.lastSeen.counts = type(state.lastSeen.counts) == "table" and state.lastSeen.counts or {}
        evidence.counts = type(evidence.counts) == "table" and evidence.counts or {}
        return evidence
    end

    local function syncEvidence(evidence, summary, status, note)
        local last = state.lastSeen
        local scalars = { "scans", "pages", "records", "observerErrors" }
        for i = 1, table.getn(scalars) do
            local key = scalars[i]
            local current = tonumber(status[key]) or 0
            evidence[key] = (tonumber(evidence[key]) or 0) + counterDelta(current, last[key])
            last[key] = current
        end

        local currentCounts = type(summary.counts) == "table" and summary.counts or {}
        local allKeys = {}
        for key in pairs(currentCounts) do allKeys[key] = true end
        for key in pairs(last.counts) do allKeys[key] = true end
        for key in pairs(allKeys) do
            local current = tonumber(currentCounts[key]) or 0
            evidence.counts[key] = (tonumber(evidence.counts[key]) or 0) +
                counterDelta(current, last.counts[key])
            last.counts[key] = current
        end

        local lastError = tostring(status.lastError or "")
        if lastError ~= "" then evidence.lastError = lastError end
        evidence.lastNote = tostring(note or status.lastNote or "")
        evidence.lastHotPayloadGeneration = tonumber(R.hotPayloadGeneration) or 0
        evidence.updates = (tonumber(evidence.updates) or 0) + 1
        return evidence
    end

    local function evidenceGate(evidence, status)
        local compared, matched, pct, mismatches = decisionSummary(evidence.counts)
        if not status.installed or not status.hooksIntact then return false, "bridge-hooks", compared, matched, pct, mismatches end
        if (tonumber(evidence.observerErrors) or 0) > 0 then return false, "observer-errors", compared, matched, pct, mismatches end
        if mismatches > 0 then return false, "recorded-parity-mismatch", compared, matched, pct, mismatches end
        if compared < 100 then return false, "insufficient-decisions", compared, matched, pct, mismatches end
        if pct < 100 then return false, "match-percent", compared, matched, pct, mismatches end
        return true, "ready", compared, matched, pct, mismatches
    end

    local function emitPingOnce()
        if state.lastChatPingRevision == REVISION then return end
        local frame = DEFAULT_CHAT_FRAME or ChatFrame1
        if frame and type(frame.AddMessage) == "function" then
            frame:AddMessage("|cff00ff00[GPT]|r AH parity evidence persistence hot-reload OK")
            state.lastChatPingRevision = REVISION
        end
    end

    local function publish(note)
        if type(AVM_DB) ~= "table" then return false end
        local parity = R.GetModule("parity")
        local bridge = R.GetModule("parity_bridge")
        if type(parity) ~= "table" or type(parity.Summary) ~= "function" then return false end
        if type(bridge) ~= "table" or type(bridge.Status) ~= "function" then return false end

        local summary = parity.Summary() or {}
        local status = bridge.Status() or {}
        if tostring(status.revision or "") == "" then return false end

        local evidence = ensureEvidence(parity, summary, status)
        syncEvidence(evidence, summary, status, note)

        local ready, reason = false, "parity-unavailable"
        if type(parity.CutoverGate) == "function" then ready, reason = parity.CutoverGate() end
        local evidenceReady, evidenceReason, compared, matched, pct, mismatches = evidenceGate(evidence, status)

        AVM_DB.marketMeta.shadowParity = {
            revision = REVISION,
            evidenceSchema = EVIDENCE_SCHEMA,
            evidenceCompatibilityKey = tostring(evidence.compatibilityKey or ""),
            sourceRevision = tostring(status.revision or ""),
            installed = status.installed and true or false,
            hooksIntact = status.hooksIntact and true or false,
            scans = tonumber(evidence.scans) or 0,
            pages = tonumber(evidence.pages) or 0,
            records = tonumber(evidence.records) or 0,
            observerErrors = tonumber(evidence.observerErrors) or 0,
            lastError = tostring(evidence.lastError or status.lastError or ""),
            lastNote = tostring(note or status.lastNote or ""),
            lastActiveSource = tostring(status.lastActiveSource or ""),
            lastShadowSource = tostring(status.lastShadowSource or ""),
            decisionCompared = compared,
            decisionMatched = matched,
            decisionMatchPct = pct,
            counts = copyCounts(evidence.counts),
            currentScans = tonumber(status.scans) or 0,
            currentPages = tonumber(status.pages) or 0,
            currentRecords = tonumber(status.records) or 0,
            currentObserverErrors = tonumber(status.observerErrors) or 0,
            currentDecisionCompared = tonumber(summary.decisionCompared) or 0,
            currentDecisionMatched = tonumber(summary.decisionMatched) or 0,
            currentDecisionMatchPct = tonumber(summary.decisionMatchPct) or 0,
            currentCounts = copyCounts(summary.counts),
            evidenceMismatches = mismatches,
            evidenceReady = evidenceReady and true or false,
            evidenceReason = tostring(evidenceReason or ""),
            cutoverReady = ready and true or false,
            cutoverReason = tostring(reason or ""),
            hotPayloadGeneration = tonumber(R.hotPayloadGeneration) or 0,
        }
        state.lastDecisionSerial = tonumber(summary.serial) or 0
        return true
    end

    function api.Publish(note)
        return publish(note)
    end

    function api.EvidenceSummary()
        if type(AVM_DB) ~= "table" or type(AVM_DB.marketMeta) ~= "table" then return nil end
        local evidence = AVM_DB.marketMeta.shadowParityEvidence
        if type(evidence) ~= "table" then return nil end
        local compared, matched, pct, mismatches = decisionSummary(evidence.counts)
        return {
            schemaVersion = tonumber(evidence.schemaVersion) or 0,
            compatibilityKey = tostring(evidence.compatibilityKey or ""),
            scans = tonumber(evidence.scans) or 0,
            pages = tonumber(evidence.pages) or 0,
            records = tonumber(evidence.records) or 0,
            observerErrors = tonumber(evidence.observerErrors) or 0,
            decisionCompared = compared,
            decisionMatched = matched,
            decisionMatchPct = pct,
            mismatches = mismatches,
            counts = copyCounts(evidence.counts),
        }
    end

    function api.install(reason)
        local parity = R.GetModule("parity")
        if type(parity) ~= "table" or type(parity.RecordDecision) ~= "function" then
            error("parity export cannot install without parity RecordDecision")
        end
        if parity.RecordDecision == state.wrapper then
            publish("install-existing:" .. tostring(reason or ""))
            emitPingOnce()
            return true
        end

        state.parity = parity
        state.originalRecordDecision = parity.RecordDecision
        state.wrapper = function(active, shadow, at, note)
            local row = state.originalRecordDecision(active, shadow, at, note)
            local cutover = R.GetModule("cutover")
            if type(cutover) == "table" and type(cutover.ObserveDecision) == "function" then
                local okCutover, errCutover = pcall(cutover.ObserveDecision, active, shadow, at, note)
                if not okCutover then
                    AVM_DB = type(AVM_DB) == "table" and AVM_DB or {}
                    AVM_DB.diag = type(AVM_DB.diag) == "table" and AVM_DB.diag or {}
                    AVM_DB.diag.shadowCutoverFeedError = tostring(errCutover or "unknown")
                end
            end
            publish("record-decision")
            return row
        end
        parity.RecordDecision = state.wrapper
        publish("installed:" .. tostring(reason or ""))
        emitPingOnce()
        return true
    end

    function api.uninstall(reason)
        if type(state.parity) == "table" and state.parity.RecordDecision == state.wrapper then
            state.parity.RecordDecision = state.originalRecordDecision
        end
        state.lastUninstallReason = tostring(reason or "")
        state.parity = nil
        state.originalRecordDecision = nil
        state.wrapper = nil
        return true
    end

    return api
end)
if not ok then error(R.lastHotError or "parity export replacement failed") end
