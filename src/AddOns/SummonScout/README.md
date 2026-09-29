# SummonScout 1.15

WoW 1.12.1 / build 5875 addon for the `parallel` experiment.

## Flow

World chat -> summon-request detection -> destination recognition -> service-place filter -> **immediate first `InviteByName()`** -> persistent demand log; later/cooldown matches use the queue.

The addon remains independent from LazyScript.

## Persistent demand logging

Every detected summon request on the configured World channel is logged **before** the current service-location filter. This means a BRD warlock still learns how many people asked for Tanaris, SM, unknown places, etc.

SavedVariables persist:
- total detected requests,
- counts per recognized destination,
- UNKNOWN count,
- ambiguous plain-DM count,
- last 200 request messages with sender + classification.

Identical normalized text from the same sender is counted at most once per 60 seconds so repeated spam does not dominate demand statistics.

Useful commands:
- `/ssi stats` -> total + UNKNOWN/DM + top 10 destinations
- `/ssi recent 20` -> latest requests
- `/ssi unknown 20` -> latest unrecognized requests; use these to improve the alias dictionary
- `/ssi clearstats confirm` -> clears the persistent demand data
- `/ssi log on|off` -> controls logging

## Passive observer mode

`/ssi invite off` disables automatic invites but keeps request logging active while SummonScout itself is ON. Use `/ssi invite on` to restore invites.

`/ssi off` still disables the whole addon, including logging.

## Destination filter

Set the place currently being served:
- `/ssi serve brd`
- `/ssi serve sm`
- `/ssi serve dme`
- `/ssi serve org`
- `/ssi serve all`

When a specific place is selected, summon requests for another or unknown destination are not invited, but are still logged.

Plain `DM` remains deliberately ambiguous (Deadmines vs Dire Maul). Explicit `VC`, `Deadmines`, `DME`, `DMN`, `DMW`, or `Dire Maul` are recognized.

## Commands

- `/ssi on`, `/ssi off`, `/ssi status`
- `/ssi invite on|off`
- `/ssi log on|off`
- `/ssi stats`
- `/ssi recent [n]`
- `/ssi unknown [n]`
- `/ssi clearstats confirm`
- `/ssi serve <place|all>`
- `/ssi places`
- `/ssi channel World`
- `/ssi debug on|off`
- `/ssi test <chat text>`


## 1.3 notes

- `/ssi observe` enables the scanner/logger while keeping automatic invites OFF.
- World-channel matching accepts both the Vanilla base-name argument and visible full channel names such as `5. World`.
- `hydraxian`, `hydraxian waterlords`, and `hydrax` are classified as `Hydraxian Waterlords`.
- Example: `WTB hydraxian summon` is a summon request and should increment the persistent request total even in observe mode.


## 1.4 World advertisement scheduler

SummonScout can periodically advertise a configurable message on its configured channel (World by default).

Commands:
- `/ssi spammsg <text>` - save the advertisement text
- `/ssi spamsec <30-3600>` - set interval in seconds
- `/ssi spam on` / `/ssi spam off` - enable/disable periodic posting
- `/ssi spamnow` - send once immediately

Defaults: scheduler OFF, interval 120 seconds, empty message. Enabling spam requires a non-empty message.

The sender's own World messages are excluded from summon-demand statistics and auto-invite matching, so an advertisement containing the word "summon" does not pollute `/ssi stats`.

Example:
`/ssi spammsg WTS summons Hydraxian - whisper me`
`/ssi spamsec 120`
`/ssi spam on`


## 1.5 Hydraxian/Azshara aliases

The following World-chat destination terms resolve to the same canonical service location: **Hydraxian Waterlords (Azshara)**:

- `azshara`
- `hydraxian waterlords`
- `hydraxian waterlods` (common typo)
- `hydraxian`
- `hydraxis`
- `hydrax`

This means messages such as `WTB summon azshara`, `need summ hydraxis`, and `summ hydraxian waterlords` are grouped under one demand bucket.


## 1.6 immediate first invite

The first eligible summon request after an idle period now calls `InviteByName()` directly inside the `CHAT_MSG_CHANNEL` event handler.

It no longer waits for the next `OnUpdate` frame. The existing 0.8 s spacing remains only for subsequent requests: if another request arrives while the invite cooldown is active or the queue is non-empty, it is queued and processed normally.

Demand logging is intentionally performed after the latency-critical invite path, so persistent statistics do not delay the first invite.


## 1.7 competitive response

Optional competitive-response mode watches the configured World channel for another player's summon advertisement to the location currently served by SummonScout.

An offer must contain a summon token plus a seller signal such as `WTS`, `selling`, `service`, `available`, `pst` / `whisper me`, or a gold price. Buyer language such as `WTB`, `need`, `LF`, `want`, or `looking` prevents seller classification. The destination must be recognized and match `/ssi serve`; the player's own messages are ignored.

The response reuses the existing `/ssi spammsg` text. Only one response may be pending at a time. Default delay is pseudo-random 4-8 seconds and default cooldown is 60 seconds. A successful counter postpones the regular spam scheduler by its full interval, avoiding back-to-back advertisements.

Commands:
- `/ssi counter on|off`
- `/ssi counterdelay <min> <max>` - 1..60 seconds
- `/ssi countercool <seconds>` - 15..3600 seconds
- `/ssi countertest <message>` - classify a sample without sending anything

Counter mode defaults OFF and is independent of regular `/ssi spam on|off`; only a non-empty `spammsg` is required.


## 1.8 counter detection fixes

Competitive response now defaults to `counterscope all`: any clearly identified competing summon seller on World can schedule the configured advert, even when that seller advertises a different destination. Use `/ssi counterscope same` to restore destination-matching behavior.

Seller detection now also recognizes:
- `WTS -- HYJAL SUMMON -- 4g`
- long menu-style ads such as `Cels Summons: Moonglade, ... Winterspring`
- `summoning portals ...` wording
- seller ads containing polite text such as `please ...` without misclassifying them as buyers

`Mount Hyjal` / `Hyjal` is also a recognized destination for diagnostics and same-scope matching.

New command:
- `/ssi counterscope all|same` (default: `all`)


## 1.9 classic GUI, master reporting and payment ledger

The exact buyer wording `LF summon to Hydraxians` is now recognized as **Hydraxian Waterlords (Azshara)**; the plural `hydraxians` and singular `hydraxian waterlord` aliases are included.

Open the new Vanilla-style control panel with `/ssi gui` or `/ssi options`. The panel provides classic framed sections and checkboxes for automation, service/advert settings, competitive response, master reporting, and live operation status.

Master reporting sends whispers to a configured master character:
- `[SSI INVITE] <player> -> <destination>`
- `[SSI PAID] <player> -> <amount> | total <revenue>`

Commands:
- `/ssi master <character>`
- `/ssi master on|off`
- `/ssi reporttest`
- `/ssi gui`

Payment accounting observes Vanilla trade state and stores positive incoming payments in `SummonScoutDB.paymentLog` (last 100 entries), `revenueCopper`, and `paymentCount`. The payer is resolved from the active trade partner, with the latest recent invite as a fallback. Invite and payment reports can be enabled independently in the GUI.


## 1.10 future-proof location roots

Location matching now supports optional safe token roots in addition to exact aliases.

Hydraxian no longer enumerates variants such as `hydraxis`, `hydraxians`, `hydraxian waterlods`, etc. Its canonical configuration is now:
- exact aliases: `azshara`, `hydraxian waterlords`
- safe token root: `hydrax`

Any normalized word beginning with `hydrax` resolves to the same destination, so `hydrax`, `hydraxis`, `hydraxian`, `hydraxians`, and future inflections/near-spellings sharing that stable root work automatically.

Root matching is token-based rather than arbitrary substring matching, and roots shorter than 5 characters are rejected. This avoids unsafe global partial matching for short aliases such as `org`, `sm`, `wc`, `dm`, etc. Other destinations can opt into the same mechanism later by adding a verified `roots={...}` entry.


## 1.11 whisper intake + party auto-summon + payment chat controls

New automation toggles are available in `/ssi gui` and as slash commands:

- `Whisper smart auto invite` / `/ssi whisperinvite on|off`: direct whispers are classified by summon intent. Clear requests such as `inv`, `need summon`, `LF summ`, `WTB summon`, or destination + summon intent are invited immediately. Generic chat is ignored, seller ads are ignored, and an explicitly different destination is rejected when this character serves a specific location.
- `Auto summon new party member` / `/ssi partysummon on|off`: after the initial roster snapshot, a newly joined party member is queued for `Ritual of Summoning`. The worker defers while casting/channeling or in combat, retries up to three times, and does not resummon members that were already in the party.
- `Whisper summon destination` / `/ssi summonwhisper on|off`: whenever `Ritual of Summoning` actually starts, the summon target receives an English whisper: `Summoning you to <destination>.` The configured service label is used; if serving ALL, the current zone is used.
- `Show received gold in chat` / `/ssi paymentchat on|off`: successful positive incoming trade payments print locally as `SummonScout: received gold from <player>: <amount>`. Existing master payment reporting and persistent revenue accounting remain unchanged.

The new-party detector uses a roster diff rather than blindly summoning everyone on login/reload, so existing multibox helpers are treated as the baseline rather than new customers.


## 1.12 field fixes: 123 whisper, payment sessions, party cast, advert dedupe

- Exact direct whisper `123` is now treated as a summon/invite request.
- Direct-whisper auto-invites have a dedicated 10 second cooldown per player. This is intentionally separate from the longer World-chat duplicate suppression.
- Trade accounting is session-gated. Duplicate `TRADE_CLOSED` events are ignored, repeated `TRADE_SHOW` no longer overwrites the pre-trade wallet snapshot, and an accepted `GetTargetTradeMoney()` offer is preferred as the per-trade payment amount. This prevents the character's whole wallet balance being logged as a payment.
- Existing bad payment history is not silently rewritten. Use `/ssi clearpayments confirm` once if the previous buggy build polluted the saved revenue total.
- Party auto-summon now uses a two-stage target/cast sequence: target the actual party unit, wait 200 ms for the target state to settle, cast `Ritual of Summoning`, and use `SpellTargetUnit` when the spell opens targeting mode. Failed/interrupted casts are re-queued up to the existing retry limit.
- Identical automatic World advertisements are hard-deduplicated for 10 seconds, preventing counter/periodic paths from producing a double post.


## 1.13 correction: 10s cooldown belongs to cast whispers

The 10 second cooldown is applied to **outgoing summon-status whispers**, not to incoming whisper auto-invites.

- `123` remains a smart whisper auto-invite trigger and follows the normal invite duplicate/queue rules.
- `Summoning you to <destination>.` is rate-limited **per recipient**. The same player cannot receive that cast-related whisper more than once within 10 seconds, even if other players are summoned between attempts.
- Default cast-whisper cooldown: 10 seconds.
- Optional command: `/ssi summonwhispercd <1-120>`.


## 1.14 GUI cleanup and live wallet

- Checkbox controls are compacted to 20x20 with smaller labels so adjacent rows no longer overlap at low resolutions.
- The summon-status whisper cooldown is editable directly in the GUI beside `Whisper summon destination`.
- `Live operation` now separates `Received total` (the SummonScout payment ledger) from `Current gold` (live `GetMoney()` wallet balance).
- `Reset total` clears the saved payment ledger only. It does not change the character's actual gold.
- `Current gold` is display-only and is never used as the amount of a received payment.


## 1.15 Vanilla GUI focus fix + ritual cast hardening

- Removed the unsupported Vanilla 1.12 EditBox `:HasFocus()` call that caused the GUI error at runtime. Edit focus is now tracked with `OnEditFocusGained` / `OnEditFocusLost`.
- Auto-summon now resolves both `partyN` and `raidN` units and listens to both party and raid roster changes.
- `Ritual of Summoning` is cast through the actual spellbook slot when available, with `CastSpellByName` retained only as a fallback. This avoids the observed case where the target changed correctly but the spell request never started.
- If the spell opens targeting mode, the resolved party/raid unit is explicitly passed to `SpellTargetUnit`.
