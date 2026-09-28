# SummonScout

WoW 1.12.1 / build 5875 addon for the `parallel` experiment.

Behavior:
- listens only to the configured custom channel (default: `World`);
- detects summon requests such as `need summon`, `lf summ`, `wtb summon`, `summ pls`, terse `sum`/ `summ`;
- rejects obvious summon-sale/service advertisements;
- automatically queues `InviteByName()` calls;
- deduplicates the same player for 120 seconds;
- never depends on LazyScript.

Commands:
- `/ssi on`, `/ssi off`, `/ssi status`
- `/ssi channel World`
- `/ssi debug on|off`
- `/ssi test <chat text>`

The first gameplay test should verify the real private-server World channel name exposed as CHAT_MSG_CHANNEL arg9 and whether automated InviteByName is accepted by that server/client combination.
