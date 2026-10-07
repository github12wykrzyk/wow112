# Auction Lifecycle + Mail Settlement V1

Baseline: `dev/windows-ah-canonical` at `99d0a45b1b62a98214f927f960156ba313de252b`.
Feature only: `feature/ah-auction-lifecycle-v1`. No canonical integration/promotion implied.

## Audit (before implementation)

- `world_poc05.rs`: existing mailbox list, money/item actions, COD rejection, correlated
  mail ACK and mailbox postcheck. Reused unchanged. Its inventory snapshot is tolerant
  of partial updates; Lifecycle adds explicit owner/entry/count evidence for POST.
- `world_poc06.rs`: existing 64-byte vanilla auction parser, tuple and guarded BUY.
- `world_poc07.rs`: shared live BUY and AH page requests. V4 workflow applies the
  existing mailbox bypass, neighborhood revalidation and shadow capture. BUY body,
  economics, price gates, multi-buy limits and response semantics are preserved.
- `world.rs`: existing encrypted transport and packet parser. Adds only a mutation
  authorization hook before first byte and observational inventory hook after receive.
- No terminal owner-list / cancel / post orchestration was present. Pinned existing
  `wow_world_messages = 0.3.0` provides vanilla request serializers. New adapters
  reuse them, the existing auction parser, transport and login. No second protocol.
- Authoritative V4 generator chain is the current
  `.github/workflows/build_windows_ah_canonical.yml` on this baseline. Feature CI
  mirrors the canonical V4 generator scripts from its own checkout and attaches
  Lifecycle afterwards; it does not fetch historical branches.

Protocol reference cross-checks (no third-party implementation copied):
https://github.com/gtker/wow_messages/blob/main/wow_message_parser/wowm/world/auction/cmsg/cmsg_auction_sell_item.wowm
https://github.com/gtker/wow_messages/blob/main/wow_message_parser/wowm/world/auction/cmsg/cmsg_auction_remove_item.wowm
https://github.com/gtker/wow_messages/blob/main/wow_message_parser/wowm/world/auction/cmsg/cmsg_auction_list_owner_items.wowm
https://github.com/gtker/wow_messages/blob/main/wow_message_parser/wowm/world/auction/smsg/smsg_auction_owner_list_result.wowm
https://github.com/gtker/wow_messages/blob/main/wow_message_parser/wowm/world/auction/smsg/smsg_auction_command_result.wowm
These establish vanilla layout, not a claim of a live server PASS.

## Architecture

One character session -> shared mutation coordinator -> canonical transport.
`BUY / MAIL / CANCEL / POST` all need a matching permit. One permit allows exactly
one send. A persisted `.pending` intent is flushed BEFORE the encrypted header is
written. A partial send, timeout, malformed/mismatched ACK, failed postcheck, crash,
or journal error blocks the next mutation. No TTL unlock, reconnect retry, restart
retry or automatic clearing of pending state exists. Confirmed failures stop too.
Before-send validation failure sends nothing and may return normally to the caller.

State location: `%LOCALAPPDATA%/WoW112/MutationCoordinatorV1` on Windows.
Key: stable `WOW112_SERVER_ID` (default `octowow`) + observed realm id + character GUID.
The same machine/user uses this location regardless of executable directory.
A `.lock` excludes other participating processes for the whole character session.
Uncertain `.pending` survives process restart. Crash-stale locks require reviewed
reconciliation; this version intentionally has no automatic unlock command.

This V1 is a **single-host coordinator**, not a distributed lock: all writers must
use the same host/user and server identity. Old executables, an in-game addon and
another machine do not participate. Do not claim fleet-wide exclusion until the
same coordinator service gates every writer. The API isolates that future provider.

## Behavior

- `inspect`: complete My Auctions with owner/duplicate/count/page consistency checks.
  Buybox LOST needs a strictly cheaper competitor with matching item + enchant/random
  property signature, compared as rational copper/unit (no float rounding). Ties
  are not loss. Incomplete scans are UNKNOWN, not a claim of winning.
- `settle`: bounded collection of gold/items, re-list before every action, no COD,
  deletion, return or sending mail. Reuses canonical mail action plus postcheck.
- `cancel`: exact approved owned tuple, no active bid, fresh competitor revalidation,
  15-second bounded pre-send evidence, correlated ACK and complete owner-list absence.
- `post`: explicit price floor and bid/buyout/duration, observed owned GUID and exact
  full stack, correlated new auction ACK plus exact owner-list reconciliation.
- `repost`: approve plan before cancel; cancel -> unique newly visible matching mail
  -> confirmed take-item -> unique newly observed owned GUID -> post. V1 supports
  plain items and whole stacks only. Ambiguous mail, merged stack, delayed inventory
  or missing returned item stops. No speculative cancel/POST retry.

Lifecycle dispatch happens after the canonical login, before economic scans. Off by
absence of `WOW112_LIFECYCLE_ACTION`; never combines a lifecycle command with BUY in
one pass. BUY remains gated by its existing settings and gains only serialization
and the durable no-retry boundary.

## Command settings

Use existing canonical account/realm/character settings (never put passwords in repo).

| Variable | Meaning |
|---|---|
| `WOW112_LIFECYCLE_ACTION` | `inspect`, `settle`, `cancel`, `post`, `repost`; unset/off keeps BUY mode |
| `WOW112_LIFECYCLE_CONFIRM` | `YES` required for all lifecycle mutations |
| `WOW112_LIFECYCLE_MAIL_LIMIT` | 1..100 actions; default 20 |
| `WOW112_LIFECYCLE_MAX_PAGES` | 1..4096; default 4096 |
| `WOW112_LIFECYCLE_AUCTION_ID` | exact owned auction for cancel/repost |
| `WOW112_LIFECYCLE_ITEM_ID` / `COUNT` / `EXPECT_BUYOUT` | exact approved cancel/repost tuple |
| `WOW112_LIFECYCLE_ITEM_GUID` | exact owned full-stack GUID for direct post; decimal or 0x hex |
| `WOW112_LIFECYCLE_BID` / `BUYOUT` / `FLOOR` | total stack copper; floor > 0 |
| `WOW112_LIFECYCLE_MINUTES` | 120 / 480 / 1440; default 120 |

No automatic economic appraisal, DE/Vendor rewrite or history DB coupling. Repost
must lower the original price, strictly undercut the witnessed competitor and remain
above the explicit floor. Auction deposits are the existing server rule; no forecast
of profit or deposit refund is claimed.

## Verification and limits

`python src/AuctionLifecycle/test_integration.py` verifies both actual baseline and
complete V4 generator anchors and byte-preservation of the BUY function. Native CI
runs coordinator crash/restart/exclusion tests, serializer/parser/price tests and
Windows x86 compilation. A native candidate is not a live-game validation.

First live sequence: inspect -> settle one mail -> one guarded cancel -> one guarded
post -> one plain-stack repost, with exact log/evidence. Do not run the same character
through old BUY/addon concurrently. Production/repeated trading remains unverified
until these checks pass. No credentials or live trades are exercised by CI.
