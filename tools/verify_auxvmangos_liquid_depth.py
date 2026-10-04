from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "src/AddOns/AuxVmangos/AuxVmangos_LiquidDepth.lua"
TOC = ROOT / "src/AddOns/AuxVmangos/AuxVmangos.toc"

def require(cond, msg):
    if not cond:
        raise SystemExit("LIQUID_DEPTH: FAIL: " + msg)

def model(buyout, count, depth_unit, entry_pct=60, resale_pct=90, cut_pct=5, min_profit=10_000, min_roi=25):
    unit = buyout // count
    if unit * 100 > depth_unit * entry_pct:
        return None
    sale = depth_unit * resale_pct // 100
    net = sale * count * (100 - cut_pct) // 100
    profit = net - buyout
    if profit < min_profit or profit * 100 < buyout * min_roi:
        return None
    return profit

def main():
    text = SRC.read_text(encoding="utf-8")
    toc = TOC.read_text(encoding="utf-8")
    require("AuxVmangos_LiquidDepth.lua" in toc, "TOC does not load route")
    tokens = [
        'AVM_LIQUID_DEPTH_VERSION = "0.1-low-risk"',
        'liquidDepthMaxBuyout==nil then AVM_DB.liquidDepthMaxBuyout=100000',
        'liquidDepthMaxItemCommitted==nil then AVM_DB.liquidDepthMaxItemCommitted=200000',
        'liquidDepthMaxSessionCommitted==nil then AVM_DB.liquidDepthMaxSessionCommitted=500000',
        'liquidDepthEntryPct==nil then AVM_DB.liquidDepthEntryPct=60',
        'liquidDepthMinRefUnits==nil then AVM_DB.liquidDepthMinRefUnits=20',
        'liquidDepthMinRefSellers==nil then AVM_DB.liquidDepthMinRefSellers=3',
        'liquidDepthResalePct==nil then AVM_DB.liquidDepthResalePct=90',
        'liquidDepthAhCutPct==nil then AVM_DB.liquidDepthAhCutPct=5',
        'liquidDepthMinProfit==nil then AVM_DB.liquidDepthMinProfit=10000',
        'liquidDepthMinRoiPct==nil then AVM_DB.liquidDepthMinRoiPct=25',
        'mode="liquid_depth",route="LIQUID_DEPTH"',
        'QueryAuctionItems(v.candidate.name',
        'PlaceAuctionBid("list",found.index,found.buyout)',
        'if L.pending or L.unknown then',
    ]
    for token in tokens:
        require(token in text, "missing contract token: " + token)
    require(model(55_000, 10, 10_000) is not None, "safe deep-discount vector should pass")
    require(model(70_000, 10, 10_000) is None, "70 percent entry should fail exact 60 percent gate")
    require(model(6_000, 1, 10_000) is None, "sub-1g profit should fail")
    for forbidden in ("goto ", "table.unpack", "loadstring("):
        require(forbidden not in text, "unsupported Lua token: " + forbidden)
    print("LIQUID_DEPTH: PASS")

if __name__ == "__main__":
    main()
