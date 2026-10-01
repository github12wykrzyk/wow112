# Aux FAST Bridge

Version 2.7 fixes severe FPS/stutter beginning on the second continuous scan. The pinned upstream Search implementation (`shirsig/aux-addon-vanilla` commit `6b56d0fec36eb2c4465b73727223aeaf547da6d7`, `tabs/search/results.lua`) appends displayed auction records and calls `search.table:SetDatabase()` after every scanned page; that rebuilds/sorts the growing result table. Re-running the same full Search at the native 25 ms AH cadence also replaces the previous records table, creating avoidable allocation/GC pressure. Automatic AVM repeat cycles now call upstream `execute(true)` with no continuation, which restarts from page 0 while preserving the completed first-scan result table. During those automatic repeat cycles the bridge suppresses only the upstream Search UI `on_auction` and `on_page_scanned` callbacks; every fresh auction/page still reaches `AVM_AuxArbAuction` / `AVM_AuxArbPageDone`, native response correlation, pause/revalidate/buy/resume and hard-stop behavior unchanged. Manual first scans keep the normal AUX GUI.

Version 2.0 preserves the full-scan arbitrage cache when AuxVmangos pauses original AUX for a guarded vendor transaction and later resumes the same Search continuation. The bridge marks programmatic resume and passes that fact into `AVM_AuxArbScanStart(resume)`, so current-scan enchanting-material depth data and raw DE candidates survive pause/revalidate/buy/resume cycles instead of being rebuilt from only the tail of the scan.

Version 1.9 fixes the live pause crash after selecting an arbitrage candidate. The upstream module environment exposes abort directly; reading it back through M returned nil. The pause path now calls abort directly.

Version 1.8 fixes report #56. Original AUX Search always creates auto-buy and auto-bid validator functions, even when no saved automatic rule is enabled. Version 1.7 incorrectly used the presence of those functions to decide that the scan was not an ordinary Search, so AuxVmangos never received scan/page/auction callbacks and reported pages=0/0 and candidates=0/0 after a completed scan. v1.8 detects normal full Search by its actual callback shape: on_scan_start + on_start_query + on_page_scanned + on_auction. When AUX arbitrage is enabled, the bridge suppresses the original AUX automatic bid validators for that Search so the guarded AuxVmangos revalidation path remains the only automated transaction path.

Version 1.6 removes the Lua-side CanSendAuctionQuery bypass. Exact 5875 disassembly from the verified Parallel candidate shows the real stock throttle inside QueryAuctionItems: at 0x004CEC47 the client executes `add eax, 0x1388` and stores that deadline at 0x00B72638; the function also checks the same deadline before building/sending CMSG_AUCTION_LIST_ITEMS. The native companion now signature-checks `05 88 13 00 00 A3 38 26 B7 00`, patches only the 32-bit immediate from 5000 ms to 25 ms at runtime, and restores 5000 ms on unload if it still owns the patch.

Because CanSendAuctionQuery reads the same deadline, original AUX can now use the stock gate truthfully. The response-correlated `0x025C` wait remains in place, so pacing is still request -> real response -> next request rather than blind flooding. `/auxfast` reports `cdPatch`, `cdMs`, `gateWait`, `queries`, `stockSent`, `native`, `matched`, and `timeouts`.

Version 1.5 responds to report #54. Ordinary original-AUX list scans now force `ignore_owner=true` because seller names are not needed for market valuation, and the stock Blizzard `AuctionFrameBrowse` is detached from `AUCTION_ITEM_LIST_UPDATE` for the duration of the AUX scan then restored. The native DLL also reports the cumulative count/page of AH list CMSG packets that actually reached `ClientServices::Send`. This separates Lua `QueryAuctionItems` attempts from real outbound requests: `/auxfast` now shows `queries` versus `stockSent`.

Report #54 showed `queries=6 native=3 matched=3 timeouts=3 bypass=3 ownerGrace=0`. That means seller resolution was not the active delay in that run; the exact 1:1 match between bypasses and timeouts instead points at calls attempted while the stock gate was closed. UI isolation is tested because the earlier throughput benchmark deliberately detached Blizzard Browse, but the outbound probe is the decisive evidence for whether stock `QueryAuctionItems` itself suppresses those calls.

This addon preserves the original `aux-addon-vanilla` GUI and scan state machine while replacing its fragile list-response pacing on this WoW 1.12.1 / vMaNGOS target.

Version 1.4 keeps the native-response correlation and caps seller/owner resolution to a 100 ms grace period after the verified auction response. Original AUX can otherwise wait up to 5 seconds for missing seller names on every page; that behavior is useful for complete owner data but defeats fast full-market scans. Fast scans now accept the authoritative auction page after 100 ms even if some seller names remain `?`. `/auxfast` reports `ownerGrace` so this path is visible.

Version 1.3 fixed module-environment binding so the bridge uses the exported `aux` interface captured before entering `aux.core.scan`. This avoids a nil `account_data` reference inside the replacement wait function.

Version 1.2 correlates every original AUX list query with the verified native `SMSG_AUCTION_LIST_RESULT` (0x025C) handler exposed by `WoWAHThrottleNative_5875_v8_FASTMARKET.dll`. The next AUX page is accepted only after a newer real network response has populated the stock client auction list.

This matters because one genuine auction response can generate many `AUCTION_ITEM_LIST_UPDATE` events while owner data resolves. Treating those duplicate UI events as independent page responses can advance AUX too early and then fall into its 5-second retry timeout. The bridge therefore keeps the UI events for diagnostics but does not use them as page-correlation evidence.

The stock `CanSendAuctionQuery` gate is no longer bypassed. Its underlying exact-build deadline is shortened natively to 25 ms. If native response correlation is unavailable for 1.5 seconds, the bridge still falls back to upstream AUX waiting semantics rather than sending overlapping queries.

The original Aux source is not vendored here. The Parallel addon packager fetches the exact upstream commit declared in `runtime/parallel_candidate.json`.

Current pinned upstream:
- repository: `shirsig/aux-addon-vanilla`
- commit: `6b56d0fec36eb2c4465b73727223aeaf547da6d7`

`/auxfast` reports query count, native responses, matched responses, fallback timeouts, UI-event count and gate bypasses. In a healthy scan, `queries`, `native` and `matched` should advance together while `uiEvents` may be much larger.
