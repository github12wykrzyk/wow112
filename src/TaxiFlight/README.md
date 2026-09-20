# TaxiFlightProbe V3 (hotkey reliability, telemetry + opt-in early ACK)

Target: WoW 1.12.1 build 5875, Windows x86. Companion module, not in stable runtime.
Only on Numpad 2 (Num Lock ON), once per marked flight, the module asks the native
client to send CMSG_MOVE_SPLINE_DONE early for its CURRENT movement state and
CURRENT spline ID. It NEVER changes coordinates, movement speed, path, client
flight state, MovementCore, SpeedFloor or the stable WoW.exe.
Whether the server accepts this message (or ignores it) is UNKNOWN. It is NOT
a proven instant teleport. Do not use the experimental hotkey where server
rules prohibit client modifications or movement manipulation.

Purpose: capture whether visible flight, observed movement, and actual time until control
returns agree on a live server, before making any gameplay-affecting changes.

How to test:
1. Start game with verified work candidate containing WoWTaxiFlightProbe_5875_v1.dll.
2. Switch Num Lock ON. At a Flight Master select destination and press Numpad 1.
3. Keep game focused during flight. After at least 2 seconds press Numpad 2
   once to attempt instant travel. After arriving and regaining character control,
   press Numpad 3. Repeat for a long and short route if desired.
4. Use updater's report attachment to share .wow112_debug/taxi_probe_*.csv.

CSV: tick_ms,event,player_valid,x100,y100,z100,current_speed_x100,run_speed_x100.
Units for coordinates/speeds are hundredths; time uses wrapping DWORD milliseconds.
EARLY_ACK_CLIENT_SEND_OK_NOT_SERVER_ACK proves only that the client send helper
returned success. It does not establish acceptance by the server or a completed
flight. EARLY_ACK_ABORT_* events explain why the hotkey declined to act.
MARK_START and MARK_END are user markers, not automatic/verified taxi state; their
tick difference includes human reaction delay. SAMPLE every ~1 second only during
a marked interval; pause if WoW is not foreground. player_valid=0 indicates no valid
object snapshot, not a teleport. Coordinates are client-reported, not server-confirmed.

Hard stop: if initial load crashes, do NOT infer flight mechanics from that crash.
Remove this candidate via updater rollback and inspect crash telemetry. Do not
change run-speed or inject completion/teleport packets based on this probe alone.

## Hotkey diagnostics (work candidate only)

- Polling uses 15 ms and detects independent key-down edges of Numpad 1
  (start), Numpad 2 (one instant attempt), Numpad 3 (end). Num Lock must be ON.
  No Ctrl or Shift is required; keys on the number row are not substitutes.
  Each detected key has its own NUMPADn_KEY_DETECTED event, even when rejected
  because the flight is not marked or the minimum 2 seconds have not elapsed.
- A non-activating small Windows toast and an audible system beep confirm
  START, END and the attempted instant hotkey. This is a Win32 window, not
  a WoW-rendered UI element: exclusive fullscreen may hide it, and muted
  system audio may hide the beep.
- TaxiFlight writes both taxi_probe_*.csv and taxi_probe_*.jsonl. The existing
  updater can already attach the JSONL to its 3-most-recent diagnostics; the
  updated updater additionally includes the two newest CSV traces explicitly.
- PROBE_READY means the DLL worker initialized; MARK_START / MARK_END means
  the full combination registered. EARLY_ACK_SCHEDULED means only that the
  Win32 timer was scheduled. EARLY_ACK_BEFORE_SEND means the native callback
  was reached. EARLY_ACK_CLIENT_SEND_OK_NOT_SERVER_ACK does NOT prove travel
  was accepted by the server. EARLY_ACK_TIMER_TIMEOUT indicates the callback
  did not run in time. If any abort or timeout occurs, report the exact event.
- Once a flight is marked, wait at least 2 seconds before trying
  Numpad 2. This remains experimental; stop at once if movement,
  client control or connection behaves unexpectedly.
