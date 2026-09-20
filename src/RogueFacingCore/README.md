# RogueFacingCore 5875 — experimental source on work

RogueFacingCore is embedded in the canonical PositionalSpoof DLL. Do not load
another positional-hook DLL alongside it. The edited source is a
binary-verified reconstruction, not the original source of the accepted DLL.

Backstab and Ambush acquire a GUID-checked, immutable target XYZ/O snapshot
per attempt. Two priming heartbeats and subsequent intercepted ordinary
movement use the identical candidate pose until success/timeout, avoiding a
mixed-target-orientation packet pair. The core resets on transaction teardown.
Gouge, timing, GCD, WotF and PP logic are not replaced.

This does not implement proven server-failure retry: the stable DLL disables
CAST_FAIL hook. Nor does it guarantee that MovementCore/LongPP will never
own a concurrent movement packet. Check the x86 candidate build, final ZIP
gate, and in-game behavior before accepting or promoting.

## PvP range/facing correction (work candidate)

- Keep shared 8-yard combat floor, 300-yard Pick Pocket/Pick Lock and PvE
  range/timing unchanged. For *player* Backstab/Ambush only, do not start a
  spoof attempt if the rogue's actual horizontal distance exceeds 8 yd;
  the old positional module allowed up to 10 yd. Let the native client
  handle its own range/error feedback in that situation.
- Continue using one pose per heartbeat pair. If the player target turns or
  moves at least 0.2 yd before the cloned cast, recompute its rear pose and
  send a complete new pair once, just before the cast.
- While an already transmitted PvP opener is awaiting the result, refresh
  target XYZ/O in ordinary outgoing movement packets when live geometry
  changes by 0.2 yd or 0.1 rad. Abort the spoof transaction if player,
  target or real <=8 yd range is lost; preserve the native outgoing packet.
- No new hook, no global ESC, no synthetic spell retries, no changes to
  LazyScript, Gouge or PP. Client-range acceptance and server-side behavior
  still require an in-game test; this does not promise guaranteed hits.
