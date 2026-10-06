WoW112 LOCAL LIVE TEST RUNNER V1.2 TELE06B
==========================================

PURPOSE
- Run the TELE-06B end-to-end summon probe with one command.
- Start CUSTOMER + SLAVE1 + SLAVE2 automatically.
- Wait until all three acceptors are live in their CURRENT sessions.
- READY requires ARMED ONCE plus a fresh keepalive PONG after ARMED.
- A reconnect invalidates READY automatically.
- Start taxi3 / Teletanaris only after 3/3 simultaneous READY.
- Keep the proven TELE-06A sequential party convergence and Ritual V4 wire path unchanged.
- After Ritual 698 starts, SLAVE1 and SLAVE2 each perform one guarded CMSG_GAMEOBJ_USE on the summoning portal.
- CUSTOMER waits for server SMSG_SUMMON_REQUEST opcode 0x02AB as the completion proof.
- Collect logs, produce VERDICT.txt and LATEST_RESULT.zip.

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
   The saved secret works only for the same Windows user profile on the same machine context.
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

PASSWORD SAFETY
- Password is never written to test logs, VERDICT.txt or result ZIP.
- Optional saved password is DPAPI-encrypted in .local\wow_password.dpapi.
- .local is intentionally not included in result ZIPs.

RUNNER VERDICTS
PASS_RITUAL_COMPLETE                Both slaves sent one portal use and CUSTOMER received SMSG_SUMMON_REQUEST/0x02AB.
FAIL_SERVER_REJECT                  Server returned a Ritual 698 cast failure reason.
FAIL_ROSTER_TIMEOUT                 Summoner did not observe all expected group members.
FAIL_ACCEPTOR_LOST_DURING_HANDSHAKE An acceptor lost current-session readiness before ROSTER PASS.
FAIL_READY_TIMEOUT                  3/3 live acceptors were not simultaneously ready.
FAIL_PORTAL_MUTATION_UNCERTAIN      A portal-use socket result became uncertain after the at-most-once guard committed.
FAIL_PORTAL_TIMEOUT                 One or both slaves did not reach PORTAL_USED within 45 seconds after ritual start.
FAIL_COMPLETION_TIMEOUT             Both portal uses were sent but CUSTOMER did not receive SMSG_SUMMON_REQUEST within 45 seconds.
FAIL_ACCEPTOR_EXITED                CUSTOMER or a slave exited during the TELE06B completion phase.
FAIL_MUTATION_UNCERTAIN             Summoner selection/cast socket outcome was uncertain; no automatic retry.
FAIL_SUMMONER_EXITED                Summoner process exited before the ritual checkpoint.
FAIL_TEST_TIMEOUT                   No terminal TELE06B completion verdict before the overall runner timeout.

OUTPUT
results\LIVE_TEST_YYYYMMDD_HHMMSS\  raw logs + STATE_*.txt + RUNNER.log + VERDICT.txt
results\LIVE_TEST_YYYYMMDD_HHMMSS.zip
LATEST_RESULT.zip                    copy of the newest result for easy upload

The runner only terminates processes that it started itself.
