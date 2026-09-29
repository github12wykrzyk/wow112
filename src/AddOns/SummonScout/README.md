# SummonScout 1.8

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
