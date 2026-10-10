-- SummonScout Core V3 shadow route coordinator.
-- Stage 4 of controlled core replacement. Observation/prediction only.
-- Models R -> X -> A routing, provider-bound ACK and route-control pacing without sending anything.
-- WoW 1.12.1 / Lua 5.0 compatible.

SummonScoutDB = SummonScoutDB or {}

local VERSION = "p1-shadow-route-coordinator"
local ACTIVE_TTL = 15.0
local MIN_GAP = 1.60
local MAX_ROUTES = 128
local MAX_HISTORY = 256

local S = W112_SUMMON_CORE_V3_ROUTE_SHADOW
if type(S) ~= "table" then
    S = {}
    W112_SUMMON_CORE_V3_ROUTE_SHADOW = S
end

S.version = VERSION
S.routes = type(S.routes) == "table" and S.routes or {}
S.order = type(S.order) == "table" and S.order or {}
S.history = type(S.history) == "table" and S.history or {}
S.lastAssigned = type(S.lastAssigned) == "table" and S.lastAssigned or {}
S.transportCursor = tonumber(S.transportCursor) or 0
S.lastMutationAt = tonumber(S.lastMutationAt) or -100000
S.metrics = type(S.metrics) == "table" and S.metrics or {
    predicted = 0, assignmentMatches = 0, assignmentMismatches = 0,
    assignmentConflicts = 0, ackVerified = 0, ackRejected = 0,
    fastBursts = 0, expired = 0
}

local function now()
    if GetTime then return tonumber(GetTime()) or 0 end
    return 0
end

local function wall()
    if time then return tonumber(time()) or 0 end
    return 0
end

local function trim(v)
    local s = tostring(v or "")
    s = string.gsub(s, "^%s+", "")
    s = string.gsub(s, "%s+$", "")
    return s
end

local function lower(v) return string.lower(trim(v)) end
local function same(a,b) a=lower(a); b=lower(b); return a~="" and a==b end
local function me() return trim(UnitName and UnitName("player") or "") end
local function master() return trim(SummonScoutDB and SummonScoutDB.masterName or "") end
local function isHub() return same(me(), master()) end

local function appendBounded(list, item, maxCount)
    list[table.getn(list) + 1] = item
    while table.getn(list) > maxCount do table.remove(list, 1) end
end

local function routeKey(customer, destination, origin)
    return lower(customer) .. "@" .. lower(destination) .. "@" .. lower(origin)
end

local function history(kind, route, detail)
    appendBounded(S.history, {
        ts = wall(), mono = now(), kind = tostring(kind or "OBS"),
        key = route and route.key or "", customer = route and route.customer or "",
        destination = route and route.destination or "", origin = route and route.origin or "",
        detail = tostring(detail or "")
    }, MAX_HISTORY)
end

local function rememberRouteKey(key)
    S.order[table.getn(S.order) + 1] = key
    while table.getn(S.order) > MAX_ROUTES do
        local old = table.remove(S.order, 1)
        if old then S.routes[old] = nil end
    end
end

local function ensureRoute(customer, destination, origin)
    customer=trim(customer); destination=lower(destination); origin=trim(origin)
    if customer=="" or destination=="" or origin=="" then return nil end
    local key=routeKey(customer,destination,origin)
    local r=S.routes[key]
    if type(r)~="table" then
        r={key=key,customer=customer,destination=destination,origin=origin,
            phase="OBSERVED",createdAt=now(),updatedAt=now(),expiresAt=now()+ACTIVE_TTL}
        S.routes[key]=r
        rememberRouteKey(key)
        history("ROUTE_CREATED",r,"")
    else
        r.updatedAt=now(); r.expiresAt=now()+ACTIVE_TTL
    end
    return r
end

local function readyProviders(destination)
    local api=W112_SUMMON_CORE_V3_PROVIDER_REGISTRY_SHADOW_API
    if type(api)~="table" or type(api.ReadyProviders)~="function" then return {} end
    local ok,result=true,nil
    if pcall then ok,result=pcall(api.ReadyProviders,destination) else result=api.ReadyProviders(destination) end
    if not ok or type(result)~="table" then return {} end
    return result
end

local function chooseProvider(destination)
    local providers=readyProviders(destination)
    local best=nil; local bestAt=nil; local i,name,at
    for i=1,table.getn(providers) do
        name=providers[i]; at=tonumber(S.lastAssigned[lower(name)]) or -100000
        if not best or at<bestAt or (at==bestAt and tostring(name)<tostring(best)) then
            best=name; bestAt=at
        end
    end
    if best then S.lastAssigned[lower(best)]=now() end
    return best
end

local function notePacing(envelope)
    local code=tostring(envelope and envelope.code or "")
    if code~="R" and code~="X" and code~="A" then return end
    local t=tonumber(envelope.mono) or now()
    local gap=t-(tonumber(S.lastMutationAt) or -100000)
    if S.lastMutationAt and S.lastMutationAt>-99999 and gap<MIN_GAP then
        S.metrics.fastBursts=(tonumber(S.metrics.fastBursts) or 0)+1
        history("PACE_OBSERVED",nil,string.format("%s gap=%.2f",code,gap))
    end
    S.lastMutationAt=t
end

local function handleR(envelope, f)
    if table.getn(f)<3 then return end
    local customer,destination,origin=f[1],f[2],f[3]
    local r=ensureRoute(customer,destination,origin); if not r then return end
    if envelope.direction=="IN" and isHub() then
        r.requestSender=trim(envelope.peer)
        if r.predictionObserved then
            history("R_DUPLICATE",r,r.predictedProvider or "NONE")
            return
        end
        r.predictionObserved=true
        r.predictedProvider=chooseProvider(destination)
        r.phase=r.predictedProvider and "SHADOW_SELECTED" or "SHADOW_NO_PROVIDER"
        S.metrics.predicted=(tonumber(S.metrics.predicted) or 0)+1
        history("PREDICT",r,r.predictedProvider or "NONE")
    elseif envelope.direction=="OUT" then
        r.phase="ROUTE_REQUEST_OBSERVED"
        history("R_OUT",r,trim(envelope.peer))
    end
end

local function handleX(envelope, f)
    if table.getn(f)<3 then return end
    local customer,destination,origin=f[1],f[2],f[3]
    local r=ensureRoute(customer,destination,origin); if not r then return end
    local actual
    if envelope.direction=="OUT" and isHub() then actual=trim(envelope.peer)
    elseif envelope.direction=="IN" then actual=me() end
    if actual=="" then return end

    if r.actualProvider then
        if same(r.actualProvider,actual) then
            history("X_DUPLICATE",r,actual)
        else
            S.metrics.assignmentConflicts=(tonumber(S.metrics.assignmentConflicts) or 0)+1
            history("X_CONFLICT",r,actual.." existing="..tostring(r.actualProvider or ""))
        end
        return
    end

    r.actualProvider=actual
    r.phase="ASSIGNED_OBSERVED"
    if r.predictedProvider then
        if same(r.predictedProvider,actual) then
            S.metrics.assignmentMatches=(tonumber(S.metrics.assignmentMatches) or 0)+1
            r.selectionParity="MATCH"
        else
            S.metrics.assignmentMismatches=(tonumber(S.metrics.assignmentMismatches) or 0)+1
            r.selectionParity="MISMATCH"
        end
    else
        r.selectionParity="UNKNOWN"
    end
    history("X_OBSERVED",r,actual..":"..r.selectionParity)
end

local function handleA(envelope, f)
    if table.getn(f)<4 then return end
    local customer,destination,origin,status=f[1],f[2],f[3],f[4]
    local r=ensureRoute(customer,destination,origin); if not r then return end
    if envelope.direction=="IN" and isHub() then
        if not r.actualProvider or not same(envelope.peer,r.actualProvider) then
            S.metrics.ackRejected=(tonumber(S.metrics.ackRejected) or 0)+1
            history("ACK_REJECTED",r,trim(envelope.peer).." expected="..tostring(r.actualProvider or ""))
            return
        end
        if r.ackAt then
            history("ACK_DUPLICATE",r,trim(envelope.peer)..":"..tostring(status or "0"))
            return
        end
        S.metrics.ackVerified=(tonumber(S.metrics.ackVerified) or 0)+1
        r.ackStatus=tostring(status or "0")
        r.phase="ACK_PROVIDER_VERIFIED"
        r.ackAt=now()
        history("ACK_VERIFIED",r,r.ackStatus)
    elseif envelope.direction=="IN" and not isHub() and same(envelope.peer,master()) then
        if r.ackAt then
            history("ACK_DUPLICATE",r,trim(envelope.peer)..":"..tostring(status or "0"))
            return
        end
        r.ackStatus=tostring(status or "0")
        r.phase="ACK_ORIGIN_OBSERVED"
        r.ackAt=now()
        history("ACK_ORIGIN",r,r.ackStatus)
    elseif envelope.direction=="OUT" then
        history("A_OUT",r,trim(envelope.peer)..":"..tostring(status or "0"))
    end
end

local function consumeTransport()
    local api=W112_SUMMON_CORE_V3_TRANSPORT_SHADOW_API
    if type(api)~="table" or type(api.GetSince)~="function" then return end
    local messages=api.GetSince(S.transportCursor)
    local i,e,f
    for i=1,table.getn(messages) do
        e=messages[i]
        if type(e)=="table" then
            notePacing(e)
            f=e.fields
            if type(f)=="table" then
                if e.code=="R" then handleR(e,f)
                elseif e.code=="X" then handleX(e,f)
                elseif e.code=="A" then handleA(e,f) end
            end
            if (tonumber(e.seq) or 0)>S.transportCursor then S.transportCursor=tonumber(e.seq) or S.transportCursor end
        end
    end
end

local function expireRoutes()
    local t=now(); local key,r
    for key,r in pairs(S.routes) do
        if type(r)=="table" and r.phase~="EXPIRED_SHADOW" and t>(tonumber(r.expiresAt) or 0)
            and r.phase~="ACK_PROVIDER_VERIFIED" and r.phase~="ACK_ORIGIN_OBSERVED" then
            r.phase="EXPIRED_SHADOW"; r.expiredAt=t
            S.metrics.expired=(tonumber(S.metrics.expired) or 0)+1
            history("EXPIRED",r,"")
        end
    end
end

local function getRoute(customer,destination,origin)
    return S.routes[routeKey(customer,destination,origin)]
end

local frame=CreateFrame and CreateFrame("Frame","SummonScoutCoreV3ShadowRouteCoordinatorFrame") or nil
if frame then
    frame:SetScript("OnUpdate",function()
        consumeTransport(); expireRoutes()
    end)
end

W112_SUMMON_CORE_V3_ROUTE_SHADOW_API={
    version=VERSION,
    minGap=MIN_GAP,
    GetState=function() return S end,
    GetRoute=getRoute,
    ChooseProvider=chooseProvider
}
