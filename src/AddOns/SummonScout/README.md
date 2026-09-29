# SummonScout 1.3

WoW 1.12.1 / build 5875 addon for the `parallel` experiment.

## Flow

World chat -> summon-request detection -> **persistent demand log** -> destination recognition -> service-place filter -> optional queued `InviteByName()`.

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
