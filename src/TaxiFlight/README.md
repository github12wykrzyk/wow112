# TaxiFlightProbe V1 (diagnostic TEST only)

Target: WoW 1.12.1 build 5875, Windows x86. Companion module, not in stable runtime.
No alteration to flight speed, taxi packets, coordinates, player control, MovementCore,
SpeedFloor, or the stable WoW.exe. Instant travel is NOT implemented.

Purpose: capture whether visible flight, observed movement, and actual time until control
returns agree on a live server, before making any gameplay-affecting changes.

How to test:
1. Start game with verified work candidate containing WoWTaxiFlightProbe_5875_v1.dll.
2. At a Flight Master select destination and immediately press Ctrl+Shift+F8.
3. Keep game focused during flight. After arriving and regaining character control,
   press Ctrl+Shift+F9. Repeat for a long and short route if desired.
4. Use updater's report attachment to share .wow112_debug/taxi_probe_*.csv.

CSV: tick_ms,event,player_valid,x100,y100,z100,current_speed_x100,run_speed_x100.
Units for coordinates/speeds are hundredths; time uses wrapping DWORD milliseconds.
MARK_START and MARK_END are user markers, not automatic/verified taxi state; their
tick difference includes human reaction delay. SAMPLE every ~1 second only during
a marked interval; pause if WoW is not foreground. player_valid=0 indicates no valid
object snapshot, not a teleport. Coordinates are client-reported, not server-confirmed.

Hard stop: if initial load crashes, do NOT infer flight mechanics from that crash.
Remove this candidate via updater rollback and inspect crash telemetry. Do not
change run-speed or inject completion/teleport packets based on this probe alone.
