-- SummonScout legacy RouteAckHubFix compatibility shim.
-- Routing Core V2 owns provider-bound ACK handling in fallbackrouter_hub_ack.
-- Keep only a version marker so mixed saved state/load manifests fail harmlessly.

local H=W112_SUMMONSCOUT_HOT
if H and type(H.GetState)=="function" then
    local F=H.GetState("fallbackrouter")
    if type(F)=="table" and type(F.caps)=="table" and F.caps.providerBoundAck then
        W112_SUMMONSCOUT_ROUTE_ACK_HUB_FIX_VERSION="retired-v2"
        return
    end
end
W112_SUMMONSCOUT_ROUTE_ACK_HUB_FIX_VERSION="retired-v2-no-cap"
