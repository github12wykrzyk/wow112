# SummonScout 1.1

WoW 1.12.1 / build 5875 addon for the `parallel` experiment.

## Flow

World chat -> summon-request detection -> destination recognition -> service-place filter -> queued `InviteByName()`.

The addon remains independent from LazyScript.

## Destination filter

Default after upgrade is `ALL` to preserve existing behavior. Set the place currently being served:

- `/ssi serve brd`
- `/ssi serve sm`
- `/ssi serve dme`
- `/ssi serve org`
- `/ssi serve all` restores the old unrestricted invite behavior.
- `/ssi places` prints the supported groups.

When a specific place is selected, summon requests with another or unknown destination are ignored. Debug mode explains why.

Plain `DM` is deliberately treated as ambiguous (Deadmines vs Dire Maul) and is not auto-invited. Explicit `VC`, `Deadmines`, `DME`, `DMN`, `DMW`, or `Dire Maul` are recognized.

## Commands

- `/ssi on`, `/ssi off`, `/ssi status`
- `/ssi serve <place|all>`
- `/ssi places`
- `/ssi channel World`
- `/ssi debug on|off`
- `/ssi test <chat text>`

Examples with `/ssi serve brd`:

- `need summon brd` -> INVITE
- `summ to blackrock depths pls` -> INVITE
- `summ sm` -> IGNORE
- `need summon` -> IGNORE (unknown destination)
- `summ dm` -> IGNORE (ambiguous destination)
