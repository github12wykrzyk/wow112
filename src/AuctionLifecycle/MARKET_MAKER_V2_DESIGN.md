# AH Market Maker V2 — root-cause architecture

Authoritative starting point: `feature/ah-market-maker-v1` at `3f089dd8cf9c2e07129782a5103ef8265cfe98d5`.

V2 is a new execution path. V1 remains available for comparison but is not promoted to production.

## Why V2

Live V1 logs proved four architectural defects:

1. mailbox discovery returned multiple GUIDs but the runtime chose `HashSet::iter().next()` without proving interactability;
2. mailbox, split and ACK waits were packet-count bounded rather than wall-clock bounded;
3. inventory started as `objects=0`, while incremental `SMSG_UPDATE_OBJECT` packets were frequently dropped by stateless parsing with `Missing object TYPE`; V1 therefore could not prove item GUID + entry + stack + physical slot for MAIL/SPLIT/POST;
4. mutation decisions were revalidated by additional full ~54k-row AH scans, making the supposedly fresh decision stale by construction.

Independent Claude reviews converged on the same architecture verdict: preserve canonical BUY and the durable mutation coordinator, replace the Market Maker execution layer.

## Non-negotiable mutation contract

`BUY`, `CANCEL`, `MAIL`, `SPLIT`, and `POST` all use the same per-character Mutation Coordinator.

- intent is durably written before the first mutation byte;
- one permit authorizes one mutation send;
- any uncertain send result hard-stops the character;
- there is no automatic retry after an uncertain send;
- a V2 recovery record never authorizes repeating the previous mutation; it only records confirmed effects which still require follow-up recovery.

## V2 phases

`LOGIN -> TARGETS -> BROAD SNAPSHOT -> TARGETED DEPTH -> DECIDE -> ONE MUTATION -> RECONCILE -> NEXT PHASE`

### Targets

- Auctioneer and mailbox candidates are deterministic and sorted.
- Mailbox is not globally required for audit.
- Before the first mail-dependent mutation, V2 obtains a read-only `MAIL_LIST` response from a candidate and binds that responder for the session.
- A fresh mailbox baseline must exist before CANCEL or a CLEAR BUY which will require item recovery.

### I/O deadlines

V2 operations use absolute `Instant` deadlines checked between packets. A socket read timeout aborts the current world session; V2 never tries to continue a possibly desynchronised encrypted stream after a partial read timeout.

### Stateful inventory

V2 maintains state across object updates:

- object type and raw update fields keyed by GUID;
- player inventory-slot GUIDs;
- container slot GUIDs;
- item entry, owner, contained GUID and stack count;
- reverse `item_guid -> physical slot` mapping;
- destroy/out-of-range handling;
- a degraded flag which blocks inventory-dependent mutation.

`SMSG_ITEM_PUSH_RESULT` is only a correlation/cross-check source. It is not item-GUID authority.

### Recovery debt

Confirmed effects which still require follow-up are persisted separately from the coordinator journal:

- `CancelledAwaitingMail`
- `BoughtAwaitingMail`
- `HoldingStack`
- `HoldingUnits`
- `PartiallyPosted`

On restart, if the coordinator has `.pending`, V2 hard-stops. If only recovery debt exists, BUY/CANCEL are disabled and only the recorded recovery path may proceed.

### Market data

- one broad full snapshot per run is advisory and feeds candidate selection/history;
- every mutation uses a fresh targeted exact-item depth query;
- exact returned rows are filtered again by `item_id + signature`;
- CLEAR uses two targeted confirmations, never two full-market scans;
- after every BUY the targeted depth is rebuilt and the policy is re-run.

## Policy V2

The pure policy models:

- exact rational copper/unit prices;
- thin cheap prefix vs a thick support tier;
- explicit/economic/history floors;
- maximum one-step undercut drop;
- cumulative per-key and per-run spend/units/exposure;
- acquired-stock cost basis and AH cut;
- portfolio uplift only as shadow data until history confidence is available.

If the lowest tier is thin but not safely clearable, V2 BLOCKS instead of blindly undercutting the fake floor.

Before history is integrated, live CLEAR must have non-negative acquired-stock economics after AH cut. Portfolio/history credit remains shadow-only.

## Canary ladder

Each rung is separately runnable and stops after one effect:

0. targets + owner list + targeted depth + mailbox probe, read-only
1. mailbox list only
2. inventory tracker observation around a manual item move, read-only
3. MAIL TAKE of a pre-staged cheap item
4. SPLIT a cheap stack
5. POST one isolated unit
6. CANCEL one test auction
7. recover cancelled item from mail and repost
8. one UNDERCUT end-to-end
9. canonical BUY + mail recovery
10. one CLEAR end-to-end with one BUY

A failed rung blocks higher rungs. No rung automatically retries an uncertain mutation.
