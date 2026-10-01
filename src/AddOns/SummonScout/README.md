# SummonScout 1.34

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


## 1.16 audit hardening

- Ritual queue completion now follows the full cast lifecycle: START marks the cast as started, STOP completes the queue, and FAILED/INTERRUPTED retries. The customer is no longer forgotten merely because the 5-second Ritual began.
- Auto-summon active state is installed before the spell request, avoiding a synchronous START race.
- A started Ritual gets an 8-second completion watchdog; a request that never produces START is retried after the short request watchdog.
- Trade fallback accounting requires either a remembered incoming offer or an accepted trade, preventing unrelated wallet gains during a cancelled trade from being counted as summon payment.
- Suppressed duplicate World adverts are distinguished from actual sends, so debug output no longer claims `counter sent` when dedupe blocked the message.


## 1.17 stale-install, cast diagnostics and counter dedupe

- Version is visible on load, in status, GUI title, and via `/ssi version`.
- Automatic World-ad dedupe uses both runtime state and shared `SummonScoutDB` state with a 15-second lock.
- Counter scheduling also respects the last regular World advert for the full counter cooldown, preventing periodic-spam + counter double posts.
- Auto-summon prefers Vanilla `CastSpellByName("Ritual of Summoning")`; spellbook `CastSpell` remains fallback.
- `UI_ERROR_MESSAGE` and `CHAT_MSG_SPELL_FAILED_LOCALPLAYER` are captured immediately after auto-summon attempts and printed as `summon rejected -> ...`.
- `/ssi summoncheck` reports spellbook presence, cast API availability, Soul Shards, queued target, resolved party/raid unit, current target, combat state and last summon error.
- Updater `Aktualizuj i uruchom` no longer silently skips file updates when WoW is already open; the normal close-game/update flow is used instead.


## 1.18 use the proven LazyScript cast path

The previous build proved roster detection and targeting, but `CastSpellByName` could silently return without generating `SPELLCAST_START` on this 5875 client. SummonScout now mirrors the casting primitive already used successfully by the repository's LazyScript implementation:

`GetSpellName(index, "spell")` -> resolve Ritual of Summoning -> `CastSpell(index, "spell")`.

`CastSpellByName` is now fallback only when the spellbook path is unavailable.

Diagnostics were also corrected for Vanilla:
- Soul Shards are counted by scanning bags for item 6265 instead of using unavailable `GetItemCount`.
- `/ssi summoncheck` resolves `groupUnit` from the current target when the summon queue has already been exhausted.
- final retry failure includes group unit, spellbook slot, shard count and last client error.


## 1.19 atomic summon target/cast + scope fix

Two field issues were fixed:

- The retry failure path called `countSoulShards()` before that local function existed in lexical scope, producing the runtime `attempt to call global 'countSoulShards' (a nil value)` error. The helper now lives before the summon state machine.
- Auto-summon no longer owns the player's target for a 200 ms target phase. That split created a race: if the player or another addon changed target before the next frame, SummonScout would retarget the party member again and could loop without ever casting.

The summon attempt now mirrors the proven LazyScript pattern in one atomic pass:

`TargetUnit(groupUnit) -> CastSpell(spellbookIndex, "spell") -> SpellTargetUnit if needed -> TargetLastTarget/ClearTarget`.

The user's previous target is restored immediately after issuing the Ritual, so SSI should no longer keep snapping the target back to the summoned party member.


## 1.20 deliberately simple target + cast

Auto-summon was reduced to the direct Vanilla equivalent of:

`/target <new group member>`
`/cast Ritual of Summoning`

Implementation:
- resolve the new member name;
- `TargetByName(name, true)` (or `TargetUnit(unit)` fallback);
- resolve `Ritual of Summoning` in the spellbook;
- `CastSpell(index, "spell")`.

There is no immediate `TargetLastTarget()`, `ClearTarget()`, or extra `SpellTargetUnit()` after the cast request. The 1.19 target restore was a likely race: the client could see the target changed back before it committed the Ritual request. SSI now changes target once and leaves it on the summoned player while the cast starts.


## 1.21 native summon bridge + bare plus invite

- A direct whisper containing only `+` is an explicit smart auto-invite trigger, just like `123`.
- Automatic party/raid summon no longer casts directly from SummonScout Lua. The addon publishes the queued player name through `W112_AUTOSUMMON_REQUEST`.
- `WoWAutoSummonAssist_5875_v1.dll` consumes that request on its native WoW UI-thread timer and executes target + `Ritual of Summoning` through the same FrameScript execution path already used by native modules in this repository.
- `/ssi summoncheck` shows native bridge request/ack/count diagnostics.


## 1.22 summon player blacklist

Automatic party/raid summoning skips exact character names `Hydraone` and `Hydratwo` (case-insensitive). They may still remain in the group and use the rest of SummonScout normally; only automatic summon queueing is suppressed.


## 1.23 direct-whisper invite priority

Natural direct-whisper requests such as `hey, still summoning? i'd take one` are treated as explicit summon demand.

Direct whisper auto-invite no longer inherits the long 120-second World-chat duplicate window. A valid whisper gets an immediate invite even if that player was seen/invited from World recently. Only a 2-second same-sender guard remains to suppress duplicate chat events.


## 1.24 master lifecycle reporting

Master reporting can now follow the full summon transaction, not only invite attempts and payments.

With `Report joins / summon state` enabled, the configured master receives:
- `[SSI JOIN] <player> -> <destination>` when a genuinely new, non-blacklisted party/raid member is detected;
- `[SSI SUMMON START] <player> -> <destination>` when Ritual of Summoning actually starts (once per queued customer, not once per retry);
- `[SSI SUMMON OK] <player> -> <destination>` on confirmed `SPELLCAST_STOP`;
- `[SSI SUMMON FAIL] ...` on final retry exhaustion, bridge publication failure, or if the customer leaves the group before casting.

The new lifecycle reporting switch defaults ON, remains gated by the global `Report to master character` switch, and is available in GUI or with `/ssi masterevents on|off`.


## 1.25 ChatThrottleLib-safe master reports

Master whispers are sanitized before `SendChatMessage`. Literal `|` characters are removed/replaced because WoW chat treats them as escape introducers and ChatThrottleLib can raise `invalid escape code in main message`.

Payment reports now use:
`[SSI PAID] <player> -> <amount> - total <received total>`

The same protection applies centrally to all INVITE/JOIN/SUMMON/PAID/TEST master messages, including future error text. Newlines are flattened and outgoing SSI master reports are capped at 240 characters.


## 1.26 summon queue reliability

Two reliability fixes protect auto-summon from unrelated chat/reporting failures:

- A new party/raid member is queued for summon **before** the optional JOIN report is whispered to the master. Master reporting can therefore never block the actual summon path.
- `reportMaster()` is isolated with `pcall`; a ChatThrottleLib or SendChatMessage error is treated as a reporting failure instead of aborting the roster event handler.

Roster detection also has a 750 ms reconciliation poll in addition to `PARTY_MEMBERS_CHANGED` / `RAID_ROSTER_UPDATE`. If this client/server misses a roster event, a genuinely new member is still detected and queued on the next poll.


## 1.27 trusted payment ledger

Payment accounting now uses the **actual post-trade wallet increase** as the only authoritative amount.

`TRADE_CLOSED` no longer records `GetTargetTradeMoney()` immediately. The trade session is snapshotted and, for up to 2 seconds, SummonScout waits for `GetMoney()` to reflect the completed transaction. A positive wallet delta is recorded; no positive delta means no payment entry.

This eliminates the earlier failure mode where an incorrect trade API value or stale wallet state could inflate revenue.

Because older builds are known to have polluted the saved total, the first 1.27 load performs a one-time ledger migration:
- old `paymentLog/revenueCopper/paymentCount` are preserved under `legacyPaymentLog/legacyRevenueCopper/legacyPaymentCount`;
- the active trusted ledger starts from zero;
- future totals are accumulated only from confirmed wallet gains.

The GUI label is now `Received total (trusted)` to distinguish this clean ledger from historical data.


## 1.28 repeated-summon deadlock recovery

This release removes two gates that could leave the summon queue permanently stuck after one successful Ritual:
- the Lua `CastingBarFrame` busy gate is no longer authoritative;
- `UnitIsConnected(unit)` no longer blocks a roster-confirmed customer forever.

The native AutoSummonAssist bridge is the execution authority. SummonScout queues by character name and retries if the actual cast is rejected.

Additional recovery:
- raid names are read through `GetRaidRosterInfo` when raid unit tokens lag;
- system join messages provide a second immediate queue path;
- a 20-second per-customer watchdog drops a pathological head-of-line entry so later customers cannot be blocked indefinitely.


## 1.29 tolerant 123 whisper code

The direct-whisper invite code `123` is now recognized as a whole token inside short messages, not only as the entire message.

Examples that now trigger smart auto-invite:
- `123`
- `123 pls`
- `pls 123`
- `123 please`

This keeps the code explicit while tolerating normal player politeness/punctuation.


## 1.30 native bridge independence

The native summon-cast bridge no longer depends on the AutoSummonAssist portal-scanner Enabled toggle. SummonScout's own `Auto summon new party member` setting is the authority for whether requests are published.

The DLL now resolves `Ritual of Summoning` through the spellbook and uses `CastSpell(index, "spell")` first, with `CastSpellByName` only as fallback. `/ssi summoncheck` also shows `nativeStatus` so bridge dispatch can be distinguished from an actual spell lookup/cast failure.


## 1.31 manual invite -> summon reconciliation

Manual invites are now an explicit auto-summon input.

When the client prints `You have invited <player> to join your group.`, SummonScout remembers that player for up to 90 seconds. As soon as the player is actually visible in party/raid, SSI queues the summon even if the normal roster-diff or join-message path was missed.

This covers:
- manual `/invite <name>` / `/i <name>`;
- right-click/manual UI invites;
- addon-generated invites (deduped by the existing summon queue).

The pending marker is cleared when the player joins, expires, or Auto summon new party member is turned off. `/ssi summoncheck` now exposes `manualPending`.


## 1.32 sequenced summon transaction

Party auto-summon now uses one request-sequenced transaction shared by SummonScout and AutoSummonAssist.

- every summon attempt gets a monotonically increasing request sequence;
- the DLL reports queued / blocked-busy / target-failed / spell-slot / cast-issued / cast-started / no-start stages;
- cast start is confirmed by either the Ritual SPELLCAST_START event or the DLL observing build-5875 cast/channel state after issuing the spell;
- cast start no longer depends on the current target still being the summoned player;
- active-transaction UI errors use a refreshed request timestamp;
- the queue watchdog runs even while combat or another cast/channel blocks the request;
- join/invite system messages are accepted with or without a final period;
- /ssi summoncheck exposes request, ACK and started sequence IDs plus native target/slot/status.

This replaces the previous optimistic ACK, which only proved that the bridge called CastSpell and did not prove that Ritual actually started.


## 1.33 Vanilla Lua 32-upvalue loader fix

WoW 1.12's Lua compiler limits a function to 32 upvalues. The monolithic OnEvent closure had grown past that limit after the 1.32 summon transaction work, so the addon could fail to load with `too many upvalues (limit=32)`.

World-channel processing is now isolated in `handleChannelMessage()`. The OnEvent closure keeps only one reference for that whole path instead of capturing all channel parser/invite/counter/logging helpers. Runtime behavior of World detection is unchanged; the split restores Vanilla 1.12 loader compatibility and leaves headroom for future event changes.


## 1.34 natural direct summon questions

Direct whispers containing a clear summon question are treated as strong buyer intent.

Examples:
- `can I get summon?`
- `can I get a summon?`
- `could I get summon?`
- `summon pls`
- `summon please`

These still respect the global `Whisper smart auto invite` toggle and destination filtering when a different explicit location is named.


## 1.42 exact `here` whisper invite

- A direct whisper whose normalized text is exactly `here` is now treated as an explicit smart auto-invite request, alongside `123` and `+`.
- The match is deliberately exact. Phrases that merely contain the word, such as `I am here already`, do not become invite triggers.
- Existing service selection, duplicate protection, party checks and auto-summon flow are unchanged.


## 1.43 recruitment / own-summon false-positive guard

World-chat recruitment posts are no longer interpreted as summon demand merely because they contain both a broad request word and `summon`.

The classifier now recognizes **recruitment + own summon capability**:
- recruitment lead such as `LF`, `LFM`, `looking for`, `need` / `needed`;
- a class/role or group activity signal such as `mage`, `priest`, `tank`, `healer`, `dps`, `farm`, `run`, `group`;
- plus an own-capability phrase such as `can summon`, `have a summon`, `got summon`.

Example now ignored:
`LF Mage for Dustwallow Dragonkin farm ... Can summon. Need ~4k DPS`

Explicit summon requests are protected from this exclusion, including:
`LF summon`, `need summon`, `who can summon me`, `can you summon`, and `summon me`.

`/ssi test <message>` reports `NOT A SUMMON REQUEST [recruitment + own summon]` for the new exclusion path.


## 1.44 exact `sure` whisper invite

- A direct whisper whose normalized text is exactly `sure` is now treated as an explicit smart auto-invite request, alongside `here`, `123` and `+`.
- The trigger is deliberately exact so ordinary longer conversation containing `sure` does not cause an invite.
- Existing service filtering, duplicate protection and post-invite auto-summon behavior are unchanged.


## 1.45 multi-location competition + persistent invite blacklist

Competitive detection:
- Azshara and azsh map to the existing Hydraxian Waterlords (Azshara) service.
- Competitive same scope now scans all recognized locations in one seller advert instead of only the first match.
- An advert containing both Hyjal and Azshara can trigger the Hyjal summoner and the Hydraxian summoner independently.
- Short multi-destination formats such as Hyjal + Azshara summon are recognized even without WTS, price, or service.
- Buyer intent and the LFM ... can summon recruitment guard remain higher priority.
- /ssi countertest <message> prints all detected destinations and the service match.

Persistent auto-invite blacklist:
- /ssi blacklist add <name>
- /ssi blacklist del <name>
- /ssi blacklist list
- GUI: Invite blacklist field with Add/Remove buttons and a live summary.
- Stored in SummonScoutDB and survives /reload and restart.
- Enforced on immediate World invite, queued World invite, whisper invite and queue execution.
- Addon-driven auto-summon also respects the user blacklist.


## 1.47 payment-intent whisper + direct summon mode

- Positive direct-whisper payment offers with an explicit gold amount are strong auto-invite intent, e.g. `I can pay 3g`, `I'll pay 3g`, `I will pay 3g`.
- Negative forms such as `can't pay`, `cannot pay`, `won't pay`, and `not paying` are excluded.
- Payment intent overrides the generic gold-price seller heuristic in direct whispers.
- Native Ritual requests are temporarily direct for all destinations. Hyjal/Hydraxian do not wait for updater slave/account-switch coordinator READY/FAIL.


## 1.49 `i need one` smart invite correction

- Corrected the previous screenshot interpretation: the requested whisper phrase is `i need one`, not `ready when you are`.
- `i need one` is now a high-confidence direct-whisper auto-invite cue.
- The mistakenly added `ready when you are` / `ready whenever you are` cues were removed before gameplay validation.
- Generic `need` by itself is not promoted to an exact high-confidence response cue; existing summon/location/payment evidence still applies normally.


## 1.50 login logout-cancel / stand recovery

Summoner login now has a short fail-safe recovery window:
- `PLAYER_LOGIN` arms the guard; the first `PLAYER_ENTERING_WORLD` starts it.
- For 8 seconds the addon retries `CancelLogout()` once per second.
- It also issues deterministic `DoEmote("STAND")` on the first, third and fifth recovery passes so a character left sitting by an inherited logout sequence is stood up.
- The guard runs only for the initial world entry after login/UI reload; normal later zone transitions do not re-arm it.
- `SummonScoutDB.loginRecoveryEnabled` defaults to true.

Exact-build API evidence: the recovered Vanilla 1.12.1 build-5875 FrameScript registration tables list `CancelLogout`, `SitOrStand`, and `DoEmote` as in-world functions:
https://github.com/brues-code/ClassicAPI/blob/master/docs/BlizzardScriptAPI.md

Updater note: current `CloseGameProcesses` already uses immediate `process.Kill()` and explicitly avoids `WM_CLOSE` because the latter can start WoW's normal logout countdown. This login guard is therefore a defensive recovery for residual/inherited logout state rather than a replacement for the updater close path.


## 1.51 event-driven startup logout cancellation

The 1.50 timer-only guard was not sufficient in the observed reconnect case: the client could remain in the logout countdown despite repeated `CancelLogout()`, while repeated `DoEmote("STAND")` only produced visible spam.

1.51 changes the recovery path to follow the actual Vanilla 1.12 logout UI lifecycle:
- registers `PLAYER_CAMPING` and cancels immediately from the event that starts the stock 20-second CAMP countdown,
- watches the real `CAMP` StaticPopup and hides it; Blizzard's own 1.12.1 `CAMP` `OnHide` calls `CancelLogout()` again,
- waits for the authoritative `LOGOUT_CANCEL` event/ACK and stops recovery as soon as it arrives,
- uses one `Jump()` and, only after repeated failure, one zero-duration `MoveForwardStart()/MoveForwardStop()` pulse as an independent movement-side escape,
- removes the repeated `DoEmote("STAND")` path, so recovery no longer spams stand emotes,
- recovery is limited to the first 12 seconds after initial world entry and does not interfere with ordinary later manual logout.


## 1.52 broader direct-whisper auto-invite phrasing

Smart auto-invite now accepts additional natural short replies that ask for one summon without repeating the word "summon", including:
- `need one`, `want one`
- `can/could I get one`
- `can/could I have one`
- `one pls/plz/please`
- `I'd like one`
- `I'll grab one`

These remain direct-whisper cues; they do not broaden World-channel request parsing or seller/competition detection.


## 1.53 idle-logout recovery without message storm

The repeated yellow `IDLE_MESSAGE` was caused by the 1.51 recovery loop cancelling CAMP every 250 ms while the underlying AFK/idle condition remained active. 1.53 removes that loop.

The new startup recovery:
- reacts to the exact Vanilla `IDLE_MESSAGE` (with a text fallback),
- performs at most one recovery action per login,
- temporarily enables the stock `autoClearAFK` CVar,
- sends the stock empty AFK toggle used by `/afk` to clear the already-active AFK state,
- performs one `Jump()` movement pulse,
- cancels/hides CAMP once and waits for `LOGOUT_CANCEL`,
- restores the user's previous `autoClearAFK` value,
- only treats an already-open CAMP popup as inherited during the first two seconds after entering the world,
- no longer registers or repeatedly reacts to `PLAYER_CAMPING`, so a normal manual logout is not intercepted.

Evidence used for this correction:
- Vanilla 1.12.1 FrameXML defines `IDLE_MESSAGE`, `autoClearAFK`, the `/afk` handler as `SendChatMessage(msg, "AFK")`, and CAMP `OnHide -> CancelLogout()`.
- vMaNGOS chat handling toggles AFK when an empty AFK chat packet is received, matching the stock `/afk` path.


## 1.54 WoW 1.12 Lua upvalue-limit fix

The 1.53 package could pass repository/build/package CI but fail while loading in the actual 1.12.1 client with:
`SummonScout.lua:3049: too many upvalues (limit=32)`.

Root cause: the large anonymous `OnEvent` closure directly referenced more than the Lua 5.0 closure upvalue budget after the idle-recovery helpers were added. Because addon files are packaged as source, the existing CI did not compile them with the client's Lua limit.

1.54 preserves the same event behavior but routes local helper calls through one `EventAPI` table captured by the callback. This reduces the callback from dozens of independent helper upvalues to a small fixed set.

A new `tools/verify_summonscout_lua_upvalues.py` gate is also part of Parallel feature preflight. It checks the `OnEvent` and `OnUpdate` callback budgets with headroom, so this client-load failure is caught before integration.


## Parser keyword research — 2026-10-01

Public Classic/Classic-era summon tooling and player discussions were compared before extending the parser:

- Leatrix Plus Classic documents `inv` as the default whisper auto-invite keyword:
  https://eu.forums.blizzard.com/en/wow/t/auto-invite/142271
- RaidSummon documents `123`, `summon`, `sum` and `port` as summon-list keywords:
  https://www.curseforge.com/wow/addons/raidsummon
- Syndicate Summoner (Classic 1.13.x) documents `123`, `1`, `inv`, `summon plz`, `summon`, `sum`, `summ`:
  https://www.curseforge.com/wow/addons/syndicate_summoner
- Brum's Summon Helper documents default `123`, `sum...` and `port...` patterns:
  https://www.curseforge.com/wow/addons/brums-summon-helper
- Current player discussions also show `123`, `sum` / `summ`, and direct "can you summon?" usage:
  https://www.reddit.com/r/classicwow/comments/l9i187/theres_at_least_3_people_every_raid_day/
  https://www.reddit.com/r/classicwow/comments/1he4kt9/why_are_mages_so_stingy_because_this_is_how_you/

SummonScout 1.57 therefore adds the missing established short code `1` (exact, plus short polite forms such as `1 pls`) and `portal` as a direct-whisper transport cue. Existing support already covers `123`, `inv`, `summon`, `sum`, `summ`, `port`, and the realm-observed `taxi` phrase. Broad weak tokens such as `tp` or `ride` were not added because the research did not establish them strongly enough to justify the false-positive risk.
