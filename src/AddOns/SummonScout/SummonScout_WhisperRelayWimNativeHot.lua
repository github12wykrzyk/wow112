-- SummonScout Whisper Relay native WIM bridge for WoW 1.12.1 / Lua 5.0.
--
-- Purpose:
--   * the transport between summoner and Master remains the canonical [SSWR1]
--     WHISPER protocol;
--   * technical [SSWR1] packets stay hidden by the spam guard/WIM filter;
--   * mirrored customer conversation is rendered in a normal WIM conversation
--     named after the customer;
--   * text typed into that relay-managed WIM window is routed through the exact
--     owning summoner via canonical /ssr logic, never whispered directly by the
--     Master to the customer;
--   * no ChatFrame/WIM global event handler replacement and no SendChatMessage
--     path is introduced here.

local H = W112_SUMMONSCOUT_HOT
if not H or type(H.Register) ~= "function" or type(H.GetState) ~= "function" then
    return
end

local VERSION = "1-native-wim-conversation"
local W = H.GetState("whisperrelaywim")
W.lastSeqBySession = W.lastSeqBySession or {}
W.nextScanAt = tonumber(W.nextScanAt) or 0

local function wnNow()
    if GetTime then return GetTime() end
    return 0
end

local function wnWall()
    if time then return time() end
    return 0
end

local function wnTrim(s)
    s = tostring(s or "")
    s = string.gsub(s, "^%s+", "")
    s = string.gsub(s, "%s+$", "")
    return s
end

local function wnLower(s)
    return string.lower(wnTrim(s or ""))
end

local function wnSame(a, b)
    a = wnLower(a)
    b = wnLower(b)
    return a ~= "" and a == b
end

local function wnPlayer()
    return wnTrim(UnitName and UnitName("player") or "")
end

local function wnMaster()
    return wnTrim(SummonScoutDB and SummonScoutDB.masterName or "")
end

local function wnIsMasterLocal()
    local me = wnPlayer()
    local master = wnMaster()
    return me ~= "" and master ~= "" and wnSame(me, master)
end

local function wnDb()
    local root = SummonScoutDB and SummonScoutDB.whisperRelayV1
    if type(root) ~= "table" or type(root.sessions) ~= "table" then return nil end
    return root
end

local function wnSessionActive(session)
    if type(session) ~= "table" or session.status ~= "ACTIVE" then return false end
    local age = wnWall() - (tonumber(session.last_activity_at) or 0)
    return age >= 0 and age <= 1800
end

local function wnChat(text)
    if DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffSummonRelay WIM:|r " .. tostring(text or ""))
    end
end

local function wnFrameAndBox(customer)
    if type(WIM_Windows) ~= "table" then return nil, nil end
    local info = WIM_Windows[customer]
    if type(info) ~= "table" then return nil, nil end
    local frameName = info.frame
    if type(frameName) ~= "string" or frameName == "" or not getglobal then return nil, nil end
    local frame = getglobal(frameName)
    local box = getglobal(frameName .. "MsgBox")
    return frame, box
end

local function wnFailClosedDispatch(box, message)
    if message and message ~= "" then wnChat(message) end
    return true
end

local function wnDispatch(box)
    if not box then return false end
    local sid = wnTrim(box.W112RelaySessionId or "")
    if sid == "" then return false end

    local text = wnTrim(box.GetText and box:GetText() or "")
    if text == "" then
        if box.SetText then box:SetText("") end
        return true
    end
    if string.sub(text, 1, 1) == "/" then
        -- Slash commands keep native WIM behavior.
        return false
    end
    if not wnIsMasterLocal() then
        return wnFailClosedDispatch(box, "reply blocked: this relay window is not on configured Master")
    end

    local D = wnDb()
    local session = D and D.sessions and D.sessions[sid] or nil
    if not wnSessionActive(session) then
        return wnFailClosedDispatch(box, "reply blocked: relay session is no longer ACTIVE")
    end
    local customer = wnTrim(session.customer_name or "")
    local summoner = wnTrim(session.summoner_name or "")
    if customer == "" or summoner == "" or wnSame(summoner, wnPlayer()) then
        return wnFailClosedDispatch(box, "reply blocked: invalid relay ownership")
    end
    if box.W112RelayCustomer and not wnSame(box.W112RelayCustomer, customer) then
        return wnFailClosedDispatch(box, "reply blocked: WIM customer/session mismatch")
    end

    local slash = SlashCmdList and SlashCmdList["SUMMONSCOUTRELAY"] or nil
    if type(slash) ~= "function" then
        return wnFailClosedDispatch(box, "reply blocked: canonical /ssr router unavailable")
    end

    -- Reuse canonical exact-owner validation and no-retry send semantics.
    local command = summoner .. " " .. customer .. " " .. text
    if pcall then
        local ok, err = pcall(slash, command)
        if not ok then
            wnChat("reply router error; nothing sent directly: " .. tostring(err or "unknown"))
            return true
        end
    else
        slash(command)
    end

    if box.AddHistoryLine then box:AddHistoryLine(text) end
    if box.SetText then box:SetText("") end
    return true
end

local function wnStableEnterPressed()
    local box = this
    local dispatch = W112_SUMMONSCOUT_RELAY_WIM_DISPATCH
    if type(dispatch) == "function" then
        local handled = false
        if pcall then
            local ok, value = pcall(dispatch, box)
            if ok then
                handled = value and true or false
            else
                handled = box and wnTrim(box.W112RelaySessionId or "") ~= ""
                wnChat("WIM dispatch error; direct send suppressed")
            end
        else
            handled = dispatch(box) and true or false
        end
        if handled then return end
    end

    local base = box and box.W112RelayBaseOnEnter or nil
    if type(base) == "function" then
        return base()
    end
end

local function wnAttachRouter(customer, session)
    local frame, box = wnFrameAndBox(customer)
    if not frame or not box or type(session) ~= "table" then return false end

    box.W112RelaySessionId = tostring(session.session_id or "")
    box.W112RelayCustomer = tostring(session.customer_name or customer or "")
    box.W112RelaySummoner = tostring(session.summoner_name or "")

    if not box.W112RelayBaseOnEnter and box.GetScript then
        box.W112RelayBaseOnEnter = box:GetScript("OnEnterPressed")
    end
    if not box.W112RelayRouterInstalled and box.SetScript then
        box:SetScript("OnEnterPressed", wnStableEnterPressed)
        box.W112RelayRouterInstalled = true
    end
    return true
end

local function wnPostWim(session, eventRow, incoming)
    if type(WIM_PostMessage) ~= "function" or type(WIM_Windows) ~= "table" then
        return false
    end
    local customer = wnTrim(session and session.customer_name or "")
    local summoner = wnTrim(session and session.summoner_name or "")
    local raw = tostring(eventRow and (eventRow.raw or eventRow.value) or "")
    if customer == "" or summoner == "" or raw == "" then return true end

    local label = "|cff66ccff[via " .. summoner .. "]|r "
    local ttype = incoming and 1 or 2
    local from = incoming and customer or wnPlayer()
    local ok = true
    if pcall then
        ok = pcall(WIM_PostMessage, customer, label .. raw, ttype, from, raw)
    else
        WIM_PostMessage(customer, label .. raw, ttype, from, raw)
    end
    if not ok then return false end
    wnAttachRouter(customer, session)
    return true
end

local function wnRenderableRemoteEvent(eventRow)
    if type(eventRow) ~= "table" or eventRow.remote_seq == nil then return false end
    local kind = tostring(eventRow.kind or "")
    return kind == "WHISPER_IN" or kind == "WHISPER_OUT_AUTO" or kind == "WHISPER_OUT_MASTER"
end

local function wnRenderEvent(session, eventRow)
    local kind = tostring(eventRow.kind or "")
    if kind == "WHISPER_IN" then
        return wnPostWim(session, eventRow, true)
    end
    if kind == "WHISPER_OUT_AUTO" or kind == "WHISPER_OUT_MASTER" then
        return wnPostWim(session, eventRow, false)
    end
    return true
end

local function wnScanSession(session)
    if type(session) ~= "table" then return end
    local sid = tostring(session.session_id or "")
    if sid == "" then return end
    if wnSame(session.summoner_name, wnPlayer()) then
        -- Local summoner/customer whispers are already native WIM traffic.
        W.lastSeqBySession[sid] = tonumber(session.event_seq) or 0
        return
    end

    local last = tonumber(W.lastSeqBySession[sid]) or 0
    local events = type(session.events) == "table" and session.events or {}
    local i
    for i = 1, table.getn(events) do
        local eventRow = events[i]
        local seq = type(eventRow) == "table" and (tonumber(eventRow.seq) or 0) or 0
        if seq > last then
            if wnRenderableRemoteEvent(eventRow) then
                if not wnRenderEvent(session, eventRow) then
                    -- WIM may not be loaded yet. Preserve cursor and retry later.
                    return
                end
            end
            last = seq
            W.lastSeqBySession[sid] = last
        end
    end
end

local function wnBaselineExisting()
    local D = wnDb()
    if not D then return end
    local order = type(D.sessionOrder) == "table" and D.sessionOrder or {}
    local i
    for i = 1, table.getn(order) do
        local sid = order[i]
        local session = D.sessions[sid]
        if type(session) == "table" and W.lastSeqBySession[sid] == nil then
            W.lastSeqBySession[sid] = tonumber(session.event_seq) or 0
        end
    end
end

local M = {}

function M.Init()
    wnBaselineExisting()
    W.nextScanAt = 0
    W112_SUMMONSCOUT_RELAY_WIM_DISPATCH = wnDispatch
    W112_SUMMONSCOUT_WHISPER_RELAY_WIM_VERSION = VERSION
end

function M.OnUpdate()
    if not wnIsMasterLocal() then return end
    local t = wnNow()
    if t < (tonumber(W.nextScanAt) or 0) then return end
    W.nextScanAt = t + 0.10

    local D = wnDb()
    if not D then return end
    local order = type(D.sessionOrder) == "table" and D.sessionOrder or {}
    local i
    for i = 1, table.getn(order) do
        local session = D.sessions[order[i]]
        wnScanSession(session)
    end
end

function M.Shutdown()
    -- Existing relay-managed WIM boxes keep a stable wrapper that resolves the
    -- current global dispatcher at keypress time. During fanout replacement,
    -- fail closed rather than falling back to WIM's direct customer whisper.
    if W112_SUMMONSCOUT_RELAY_WIM_DISPATCH == wnDispatch then
        W112_SUMMONSCOUT_RELAY_WIM_DISPATCH = function(box)
            if box and wnTrim(box.W112RelaySessionId or "") ~= "" then
                wnChat("relay UI is reloading; reply not sent")
                return true
            end
            return false
        end
    end
end

H.Register("whisperrelaywim", M, VERSION)
