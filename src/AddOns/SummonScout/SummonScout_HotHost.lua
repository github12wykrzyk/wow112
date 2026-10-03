-- Stable SummonScout hot-reload host for WoW 1.12.1 / Lua 5.0.
-- Loaded once by the TOC. Hot payload files replace module tables only;
-- this host owns the persistent frame, event registrations and state buckets.

W112_SUMMONSCOUT_HOT = W112_SUMMONSCOUT_HOT or {}
local H = W112_SUMMONSCOUT_HOT
H.modules = H.modules or {}
H.state = H.state or {}
H.generations = H.generations or {}
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

W112_SUMMONSCOUT_HOT_HOST_VERSION = "1"
