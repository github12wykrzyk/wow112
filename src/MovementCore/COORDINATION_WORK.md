# Work-only movement arbitration / WoW 1.12.1 build 5875 x86

MovementCore exposes CoordFlags (0x01 cast/channel, 0x02 active LongPP,
0x04 SafeBreak, 0x08 gathering, 0x10 rear transaction), CoordAcquireRear
and CoordReleaseRear. Six-second stale-lease expiry; no new hook or DLL.
PositionalSpoof lazily resolves these exports, yields idle PvP rear packets
while a peer owns movement, and leases a short opener transaction. Existing
clearState releases the lease. MovementCore blocks new PP and SafeBreak
starts during an owned rear opener, before reaching the downstream LongPP
send/movement hooks. Existing PP internals, packet formats and hook order
are unchanged. If MovementCore is absent, PositionalSpoof preserves prior
behavior. The integration remains experimental until launch, manual/auto PP,
rear openers, poisons, crafting/channeling, AB cap and BG transitions are
tested in game.
