$ErrorActionPreference = 'Stop'

$readme = 'probes/Wow112HeadlessAndroid/windows/LIVE_TEST_README.txt'
@'
WoW112 LOCAL LIVE TEST RUNNER V1.5 TELE06B RANGE-SAFE
=====================================================

PURPOSE
-------
Run the proven TELE-06B terminal-only summon flow with one command while failing
closed on the two conditions exposed by the live A/B tests: clicker range and
near-immediate portal use.

ROLES
-----
CUSTOMER : octowar1    / Smokinpole  -> waits for server SMSG_SUMMON_REQUEST 0x02AB
SUMMONER : taxi3       / Teletanaris -> builds party and casts Ritual of Summoning 698
SLAVE1   : octowinter1 / Winterone   -> guarded portal clicker, 150 ms settle
SLAVE2   : octowinter2 / Wintertwoo  -> guarded portal clicker, 300 ms settle

WHAT V1.5 PROVES / DOES NOT PROVE
---------------------------------
The V1.4 baseline completed a real terminal-only summon: CUSTOMER received
SMSG_SUMMON_REQUEST 0x02AB after both clickers used the ritual portal.

The live A/B geometry was:
  FAIL: SLAVE1 6.651 yd, SLAVE2 6.697 yd from portal -> no server ritual response.
  PASS: SLAVE1 0.195 yd, SLAVE2 0.263 yd from portal -> summon completed.

V1.5 therefore performs a server-coordinate 3D range check BEFORE committing the
one-shot mutation guard and BEFORE sending CMSG_GAMEOBJ_USE.

Default max click distance: 5.8 yd.
  - in range: click may proceed after the role-specific settle delay.
  - out of range: FAIL_PORTAL_OUT_OF_RANGE; NO click is sent; guard is NOT consumed.
  - coordinate unavailable: FAIL_PORTAL_RANGE_UNKNOWN; NO click is sent; guard is NOT consumed.

V1.5 does NOT move a clicker into range. Automatic movement/positioning is a
separate next layer. Keep Winterone and Wintertwoo near the expected portal area.

IMPORTANT STATE SEMANTICS
-------------------------
PORTAL_USE_SENT means only that CMSG_GAMEOBJ_USE was written successfully to the
socket. It is NOT server acceptance and is NOT terminal success.

The only terminal success criterion remains:
  CUSTOMER receives server SMSG_SUMMON_REQUEST opcode 0x02AB
and the runner has observed PORTAL_USE_SENT from both clickers.

No automatic portal re-click is performed. If a socket result is uncertain after
the mutation guard is committed, the runtime fails closed instead of retrying.

ONE-COMMAND TEST
----------------
1. Extract the COMPLETE ZIP to a normal folder. Do not run from Windows ZIP preview.
2. Ensure the four test accounts are not simultaneously logged into normal WoW clients.
3. Double-click RUN_LIVE_TEST.cmd.
4. Enter the common WoW password when requested.
5. Saving it is optional; if saved, Windows DPAPI stores it under .local for the
   current Windows user. .local is excluded from result ZIPs.
6. Do NOT manually click the summoning portal during the run.
7. When the runner finishes, upload LATEST_RESULT.zip for analysis.

CONTROL FLOW
------------
1. CUSTOMER + SLAVE1 + SLAVE2 start first.
2. READY requires ARMED plus a fresh keepalive PONG in the current session.
3. Runner requires 3/3 simultaneous READY stability before starting SUMMONER.
4. SUMMONER converges the party sequentially and casts Ritual 698 at Smokinpole.
5. Each clicker detects the ritual GameObject (entry 36727 or GO type 18).
6. Local XYZ comes from SMSG_LOGIN_VERIFY_WORLD; portal XYZ comes from server
   CreateObject movement data.
7. Range gate executes before the mutation guard. Default threshold is 5.8 yd.
8. SLAVE1 waits 150 ms; SLAVE2 waits 300 ms, then each can send one guarded
   CMSG_GAMEOBJ_USE 0x00B1.
9. CUSTOMER waits for SMSG_SUMMON_REQUEST 0x02AB.
10. Runner writes VERDICT.txt and packs LATEST_RESULT.zip.

LOGIN RESILIENCE
----------------
AUTH TCP connect watchdog: 3000 ms
WORLD TCP connect watchdog: 3000 ms
Login I/O inactivity watchdog before LOGIN_VERIFY_WORLD: 3000 ms
Reconnect delay: 0 ms after watchdog/network failure
Reconnect limit: 60 attempts
Transient CONNECTING/ARMED states are tolerated before roster convergence.
An actual child-process exit remains terminal unless a more specific state was
published first (for example FAIL_PORTAL_OUT_OF_RANGE).

TRACE DIAGNOSTICS RETAINED FROM V1.4
------------------------------------
[T6B-RX]                     relevant spell/channel/summon/chat packets with ms timing
[T6B-CLICK-TX]               exact outgoing CMSG_GAMEOBJ_USE bytes and timestamps
[TELE-06B-PORTAL-OBJECT]     first parsed ritual portal object
[TELE-06B-PORTAL-EVIDENCE]   per-click server evidence counters
[TELE-06B-PORTAL-OUTCOME]    conservative post-click classification
[T6B-SUMMARY]                summoner post-cast trace summary
[TELE-06B-RANGE]             local/portal coordinates, distance gate, settle delay

TERMINAL RESULTS
----------------
PASS_RITUAL_COMPLETE          CUSTOMER received SMSG_SUMMON_REQUEST 0x02AB after both sends.
FAIL_PORTAL_OUT_OF_RANGE      Clicker was beyond configured safe distance; no click sent.
FAIL_PORTAL_RANGE_UNKNOWN     Required server coordinate snapshot unavailable; no click sent.
FAIL_PORTAL_MUTATION_UNCERTAIN Guard committed but socket write outcome uncertain; no retry.
FAIL_PORTAL_TIMEOUT           One or both clickers did not reach PORTAL_USE_SENT in time.
FAIL_COMPLETION_TIMEOUT       Both sends occurred but CUSTOMER did not receive 0x02AB in time.
FAIL_SERVER_REJECT            Server rejected Ritual 698.
FAIL_ROSTER_TIMEOUT           Full expected party roster was not observed.
FAIL_ACCEPTOR_EXITED          Acceptor process exited without a more specific terminal state.
FAIL_SUMMONER_EXITED          Summoner process exited before ritual outcome.
FAIL_TEST_TIMEOUT             Overall test deadline expired.

CONFIGURATION USED BY THE BUNDLED RUNNER
-----------------------------------------
WOW112_TELE06B_MAX_RANGE=5.8
SLAVE1 WOW112_TELE06B_CLICK_SETTLE_MS=150
SLAVE2 WOW112_TELE06B_CLICK_SETTLE_MS=300

These are runner defaults for this validation build. The runtime also accepts the
environment variables directly for controlled diagnostics.

SECURITY / RESULT ARTIFACTS
---------------------------
The password is not written to logs or LATEST_RESULT.zip. If local DPAPI storage
is enabled, .local/wow_password.dpapi stays outside the result bundle.

After the run, LATEST_RESULT.zip is the only file normally needed for diagnosis.
'@ | Set-Content -Path $readme -Encoding ASCII

$check = Get-Content $readme -Raw
foreach ($needle in @(
    'V1.5 TELE06B RANGE-SAFE',
    'PORTAL_USE_SENT',
    'FAIL_PORTAL_OUT_OF_RANGE',
    'FAIL_PORTAL_RANGE_UNKNOWN',
    'WOW112_TELE06B_MAX_RANGE=5.8',
    'SMSG_SUMMON_REQUEST opcode 0x02AB',
    'does NOT move a clicker into range'
)) {
    if (-not $check.Contains($needle)) { throw "V1.5 README marker missing: $needle" }
}
if ($check.Contains('Each slave must reach PORTAL_USED')) { throw 'stale V1.4 PORTAL_USED wording survived' }

Write-Host 'TELE06B V1.5 README PATCH PASS'
