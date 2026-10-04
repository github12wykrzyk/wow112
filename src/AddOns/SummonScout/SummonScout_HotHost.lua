-- Stable SummonScout hot-reload host for WoW 1.12.1 / Lua 5.0.
-- Loaded once by the TOC. Hot payload files replace module tables only;
-- this host owns the persistent frame, event registrations and state buckets.

W112_SUMMONSCOUT_HOT = W112_SUMMONSCOUT_HOT or {}
local H = W112_SUMMONSCOUT_HOT
H.modules = H.modules or {}
H.state = H.state or {}
H.generations = H.generations or {}
H.moduleOrder = H.moduleOrder or {}
H.lastError = H.lastError or ""

local function hotChat(text)
    if DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage("|cff66ff66SummonScout hot:|r " .. tostring(text or ""))
    end
end

local function callSafe(fn, a, b, c, d)
    if type(fn) ~= "function" then return true end
    if pcall then
        return pcall(fn, a, b, c, d)
    end
    fn(a, b, c, d)
    return true
end

local function rememberModule(name)
    local i
    for i = 1, table.getn(H.moduleOrder) do
        if H.moduleOrder[i] == name then return end
    end
    H.moduleOrder[table.getn(H.moduleOrder) + 1] = name
end

function H.GetState(name)
    name = tostring(name or "")
    if name == "" then return nil end
    if type(H.state[name]) ~= "table" then H.state[name] = {} end
    return H.state[name]
end

function H.RegisterEvent(eventName)
    if H.frame and eventName and eventName ~= "" then
        H.frame:RegisterEvent(eventName)
    end
end

-- HOT fanout replaces several modules in one synchronous payload. Older host
-- behavior initialized each replacement before shutting down the previous
-- generation, leaving nested SummonScoutFrame/H.frame wrapper chains behind.
-- Repeated live updates could therefore grow the call stack until Lua reported
-- "C stack overflow" from WhisperConfirmSpam. Fanout calls this once, before
-- executing the replacement modules, so old wrappers are peeled in reverse
-- registration order and both shared dispatch surfaces return to their stable
-- bases before the new generation installs.
function H.PrepareFanoutReload()
    local i
    for i = table.getn(H.moduleOrder), 1, -1 do
        local name = H.moduleOrder[i]
        local module = H.modules[name]
        if module and type(module.Shutdown) == "function" then
            callSafe(module.Shutdown)
        end
    end

    H.modules = {}
    H.moduleOrder = {}

    if SummonScoutFrame and SummonScoutFrame.GetScript and SummonScoutFrame.SetScript
        and type(H.coreBaseOnEvent) == "function" then
        SummonScoutFrame:SetScript("OnEvent", H.coreBaseOnEvent)
    end
    if H.frame and H.frame.SetScript then
        if type(H.hostBaseOnEvent) == "function" then
            H.frame:SetScript("OnEvent", H.hostBaseOnEvent)
        end
        if type(H.hostBaseOnUpdate) == "function" then
            H.frame:SetScript("OnUpdate", H.hostBaseOnUpdate)
        end
    end

    H.lastError = ""
    H.fanoutResets = (tonumber(H.fanoutResets) or 0) + 1
    return true
end

function H.Register(name, module, version)
    if type(name) ~= "string" or name == "" or type(module) ~= "table" then
        H.lastError = "invalid module registration"
        return false
    end

    local old = H.modules[name]
    local ok, err = true, nil
    if type(module.Init) == "function" then
        if pcall then
            ok, err = pcall(module.Init)
        else
            module.Init()
        end
    end
    if not ok then
        H.lastError = tostring(err or "Init failed")
        hotChat(name .. " reload rejected: " .. H.lastError)
        return false
    end

    H.modules[name] = module
    rememberModule(name)
    H.generations[name] = (tonumber(H.generations[name]) or 0) + 1
    H.lastError = ""
    W112_SUMMONSCOUT_HOT_GENERATION = (tonumber(W112_SUMMONSCOUT_HOT_GENERATION) or 0) + 1

    if old and type(old.Shutdown) == "function" then
        callSafe(old.Shutdown)
    end

    if old then
        hotChat(name .. " -> v" .. tostring(version or "?")
            .. " gen " .. tostring(H.generations[name]))
    end
    return true
end

if not H.coreBaseOnEvent and SummonScoutFrame and SummonScoutFrame.GetScript then
    local base = SummonScoutFrame:GetScript("OnEvent")
    if type(base) == "function" then H.coreBaseOnEvent = base end
end

if not H.frame then
    local frame = CreateFrame("Frame", "SummonScoutHotHostFrame")
    H.frame = frame

    frame:SetScript("OnEvent", function()
        local name, module
        for name, module in pairs(H.modules) do
            if module and type(module.OnEvent) == "function" then
                local ok, err = callSafe(module.OnEvent, event, arg1, arg2, arg3)
                if not ok then
                    H.lastError = tostring(err or "OnEvent failed")
                    hotChat(name .. " OnEvent error: " .. H.lastError)
                end
            end
        end
    end)

    frame:SetScript("OnUpdate", function()
        local name, module
        for name, module in pairs(H.modules) do
            if module and type(module.OnUpdate) == "function" then
                local ok, err = callSafe(module.OnUpdate, arg1)
                if not ok then
                    H.lastError = tostring(err or "OnUpdate failed")
                    hotChat(name .. " OnUpdate error: " .. H.lastError)
                end
            end
        end
    end)
end

if H.frame and H.frame.GetScript then
    if not H.hostBaseOnEvent then
        local baseEvent = H.frame:GetScript("OnEvent")
        if type(baseEvent) == "function" then H.hostBaseOnEvent = baseEvent end
    end
    if not H.hostBaseOnUpdate then
        local baseUpdate = H.frame:GetScript("OnUpdate")
        if type(baseUpdate) == "function" then H.hostBaseOnUpdate = baseUpdate end
    end
end

W112_SUMMONSCOUT_HOT_HOST_VERSION = "2-fanout-reset"