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
