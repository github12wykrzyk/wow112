local R = W112_AH_SHADOW
if type(R) ~= "table" or type(R.ReplaceModule) ~= "function" then
    error("AuxEconomyShadow parity export requires persistent anchor")
end

local REVISION = "2-marketmeta-export-chat-ping"
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

    local function emitPingOnce()
        if state.lastChatPingRevision == REVISION then return end
        local frame = DEFAULT_CHAT_FRAME or ChatFrame1
        if frame and type(frame.AddMessage) == "function" then
            frame:AddMessage("|cff00ff00[GPT]|r AH hot-reload ping OK")
            state.lastChatPingRevision = REVISION
        end
    end

    local function publish(note)
        if type(AVM_DB) ~= "table" then return false end
        local parity = R.GetModule("parity")
        local bridge = R.GetModule("parity_bridge")
        if type(parity) ~= "table" or type(parity.Summary) ~= "function" then return false end

        local summary = parity.Summary() or {}
        local status = type(bridge) == "table" and type(bridge.Status) == "function" and bridge.Status() or {}
        local ready, reason = false, "parity-unavailable"
        if type(parity.CutoverGate) == "function" then ready, reason = parity.CutoverGate() end

        AVM_DB.marketMeta = type(AVM_DB.marketMeta) == "table" and AVM_DB.marketMeta or {}
        AVM_DB.marketMeta.shadowParity = {
            revision = REVISION,
            sourceRevision = tostring(status.revision or ""),
            installed = status.installed and true or false,
            hooksIntact = status.hooksIntact and true or false,
            scans = tonumber(status.scans) or 0,
            pages = tonumber(status.pages) or 0,
            records = tonumber(status.records) or 0,
            observerErrors = tonumber(status.observerErrors) or 0,
            lastError = tostring(status.lastError or ""),
            lastNote = tostring(note or status.lastNote or ""),
            lastActiveSource = tostring(status.lastActiveSource or ""),
            lastShadowSource = tostring(status.lastShadowSource or ""),
            decisionCompared = tonumber(summary.decisionCompared) or 0,
            decisionMatched = tonumber(summary.decisionMatched) or 0,
            decisionMatchPct = tonumber(summary.decisionMatchPct) or 0,
            counts = copyCounts(summary.counts),
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

    function api.install(reason)
        local parity = R.GetModule("parity")
        if type(parity) ~= "table" or type(parity.RecordDecision) ~= "function" then
            return false
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
