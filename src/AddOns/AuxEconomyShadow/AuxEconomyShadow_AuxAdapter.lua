-- AuxEconomyShadow AUX adapter contract.
-- This is intentionally inert. It does not replace AUX functions, register events,
-- send queries or submit transactions. It only defines the interface that the
-- future consolidated owner will implement behind one boundary.

AVM_SHADOW = AVM_SHADOW or {}
AVM_SHADOW_AUX = AVM_SHADOW_AUX or {}

local A = AVM_SHADOW_AUX

A.scanOpen = A.scanOpen and true or false
A.scanSerial = tonumber(A.scanSerial) or 0
A.recordsObserved = tonumber(A.recordsObserved) or 0
A.pagesObserved = tonumber(A.pagesObserved) or 0
A.lastSource = A.lastSource or ""

function A.BeginObservedScan(source)
    if A.scanOpen then return false, "scan-already-open" end
    A.scanOpen = true
    A.scanSerial = (tonumber(A.scanSerial) or 0) + 1
    A.recordsObserved = 0
    A.pagesObserved = 0
    A.lastSource = tostring(source or "shadow")
    return true, A.scanSerial
end

function A.ObserveAuction(record)
    if not A.scanOpen then return nil, "scan-not-open" end
    A.recordsObserved = (tonumber(A.recordsObserved) or 0) + 1
    if AVM_SHADOW.NormalizeAuctionRecord then
        return AVM_SHADOW.NormalizeAuctionRecord(record)
    end
    return record
end

function A.ObservePage()
    if not A.scanOpen then return false, "scan-not-open" end
    A.pagesObserved = (tonumber(A.pagesObserved) or 0) + 1
    return true, A.pagesObserved
end

function A.EndObservedScan()
    if not A.scanOpen then return false, "scan-not-open" end
    A.scanOpen = false
    return true, A.Snapshot()
end

function A.Snapshot()
    return {
        scanOpen = A.scanOpen and true or false,
        scanSerial = tonumber(A.scanSerial) or 0,
        recordsObserved = tonumber(A.recordsObserved) or 0,
        pagesObserved = tonumber(A.pagesObserved) or 0,
        lastSource = tostring(A.lastSource or ""),
    }
end
