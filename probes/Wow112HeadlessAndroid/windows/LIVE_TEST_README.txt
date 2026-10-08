WoW112 LOCAL LIVE TEST RUNNER V1.3 TELE06B LOGINWATCH (+ V1.4 TELE06B TRACE diagnostics)
====================================================

PURPOSE
- Run the TELE-06B end-to-end summon probe with one command.
- Start CUSTOMER + SLAVE1 + SLAVE2 automatically.
- Wait until all three acceptors are live in their CURRENT sessions.
- READY requires ARMED plus a fresh keepalive PONG after ARMED.
- Start taxi3 / Teletanaris only after 3/3 simultaneous READY.
- Preserve the proven TELE-06A sequential party convergence and Ritual V4 mutation path.
- After Ritual 698 starts, SLAVE1 and SLAVE2 each perform one guarded CMSG_GAMEOBJ_USE on the summoning portal.
- CUSTOMER waits for server SMSG_SUMMON_REQUEST opcode 0x02AB as the completion proof.
- Collect logs, produce VERDICT.txt and LATEST_RESULT.zip.

LOGIN RESILIENCE V1.3
- AUTH TCP connect watchdog: 3000 ms.
- WORLD TCP connect watchdog: 3000 ms.
- AUTH/WORLD login read/write inactivity watchdog before LOGIN_VERIFY_WORLD: 3000 ms.
- No extra reconnect sleep is added after a failed login attempt.
- A stalled login attempt is recycled as soon as the 3 s watchdog expires.
- Transient CONNECTING/ARMED states after summoner launch are tolerated before ROSTER_PASS.
- The runner no longer aborts merely because an acceptor reconnects before ROSTER_PASS.
- A real process exit remains terminal.
- Sequential party state-machine timeouts remain authoritative for party convergence.

TELE06B TRACE V1.4 (observe-only diagnostics)
No behaviour change: same single guarded click per slave, no retry, no serialization.
New log lines (never contain credentials or keys):
  [TELE-06B-PORTAL-OBJECT]    parsed portal object dump (position/fields) when first observed
  [T6B-CLICK-TX]              exact outgoing CMSG_GAMEOBJ_USE bytes + ms timestamp (commit / write done)
  [T6B-RX]                    every spell/channel/summon/chat/notification packet after the click, with ms offsets
  [TELE-06B-PORTAL-EVIDENCE]  per-clicker counters: participant spell, channel start, failure, summon-to-other, portal destroyed
  [TELE-06B-PORTAL-OUTCOME]   20 s after click: classification of what the server did with the click
  [T6B-SUMMARY]               summoner 40 s after cast: spell/channel packets that followed SMSG_SPELL_START
How to read the result (decision table):
  A  Both clickers show participant spell/channel evidence, customer still no 0x02AB
     -> clicks were accepted; inspect summoner failure packets, chat/notification text, summon target.
  B  No transition on clickers, summoner channel still alive
     -> clicks ignored; compare click time vs owner SPELL_GO, portal position/distance, group state.
  C  Summoner shows SPELL_FAILURE / CAST_RESULT / interrupt before the clicks
     -> channel was lost before clickers acted.
  D  SUMMON_REQUEST addressed to a clicker (not the customer)
     -> wrong summon target (selection).
PASS still requires CUSTOMER to receive SMSG_SUMMON_REQUEST 0x02AB (PASS_RITUAL_COMPLETE).
Upload only LATEST_RESULT.zip.

DEFAULT ROLES
CUSTOMER : octowar1    / Smokinpole   -> completion watcher
SUMMONER : taxi3       / Teletanaris  -> Ritual of Summoning
SLAVE1   : octowinter1 / Winterone    -> guarded portal clicker
SLAVE2   : octowinter2 / Wintertwoo   -> guarded portal clicker

HOW TO RUN
1. EXTRACT THE COMPLETE ZIP. Do not run the CMD from inside Windows ZIP preview.
2. Double-click RUN_LIVE_TEST.cmd.
3. First run: enter the common WoW password once.
4. By default you can save it locally encrypted with Windows DPAPI.
5. Later runs become effectively one-click.
6. Do not manually click the summoning portal during this probe.
7. When the test ends, upload only LATEST_RESULT.zip to ChatGPT.

PASS CONTRACT
- PASS_RITUAL_STARTED is only an intermediate checkpoint.
- Each slave must reach PORTAL_USED exactly once.
- CUSTOMER must receive a correctly sized SMSG_SUMMON_REQUEST (0x02AB).
- Only then does the runner return PASS_RITUAL_COMPLETE.

MUTATION SAFETY
- Portal use is guarded at-most-once per slave process.
- The guard is committed before socket I/O.
- There is no automatic re-click after an uncertain socket result.
- Portal identification uses summoning portal entry 36727 or gameobject ritual type 18.
- Login retries do not relax mutation guards.

PASSWORD SAFETY
- Password is never written to test logs, VERDICT.txt or result ZIP.
- Optional saved password is DPAPI-encrypted in .local\wow_password.dpapi.
- .local is intentionally not included in result ZIPs.

RUNNER VERDICTS
PASS_RITUAL_COMPLETE            Both slaves sent one portal use and CUSTOMER received SMSG_SUMMON_REQUEST/0x02AB.
FAIL_SERVER_REJECT              Server returned a Ritual 698 cast failure reason.
FAIL_ROSTER_TIMEOUT             Sequential party engine did not converge on all expected members.
FAIL_READY_TIMEOUT              Initial 3/3 acceptor READY gate was not reached before overall timeout.
FAIL_PORTAL_MUTATION_UNCERTAIN  A portal-use socket result became uncertain after the at-most-once guard committed.
FAIL_PORTAL_TIMEOUT             One or both slaves did not reach PORTAL_USED within 45 seconds after ritual start.
FAIL_COMPLETION_TIMEOUT         Both portal uses were sent but CUSTOMER did not receive SMSG_SUMMON_REQUEST within 45 seconds.
FAIL_ACCEPTOR_EXITED            CUSTOMER or a slave process actually exited.
FAIL_MUTATION_UNCERTAIN         Summoner selection/cast socket outcome was uncertain; no automatic retry.
FAIL_SUMMONER_EXITED            Summoner process exited before the ritual checkpoint.
FAIL_TEST_TIMEOUT               No terminal TELE06B completion verdict before the overall runner timeout.

OUTPUT
results\LIVE_TEST_YYYYMMDD_HHMMSS\  raw logs + STATE_*.txt + RUNNER.log + VERDICT.txt
results\LIVE_TEST_YYYYMMDD_HHMMSS.zip
LATEST_RESULT.zip                    copy of the newest result for easy upload

The runner only terminates processes that it started itself.
