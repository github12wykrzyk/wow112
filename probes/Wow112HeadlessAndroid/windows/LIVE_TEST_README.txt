WoW112 LOCAL LIVE TEST RUNNER V1
================================

PURPOSE
- Run the current TELE-06A live probe with one command.
- Start CUSTOMER + SLAVE1 + SLAVE2 automatically.
- Wait until all three acceptors are live in their CURRENT sessions.
- READY requires ARMED ONCE plus a fresh keepalive PONG after ARMED.
- A reconnect invalidates READY automatically.
- Start taxi3 / Teletanaris only after 3/3 simultaneous READY.
- Collect logs, produce VERDICT.txt and LATEST_RESULT.zip.

DEFAULT ROLES
CUSTOMER : octowar1    / Smokinpole
SUMMONER : taxi3       / Teletanaris
SLAVE1   : octowinter1 / Winterone
SLAVE2   : octowinter2 / Wintertwoo

HOW TO RUN
1. EXTRACT THE COMPLETE ZIP. Do not run the CMD from inside Windows ZIP preview.
2. Double-click RUN_LIVE_TEST.cmd.
3. First run: enter the common WoW password once.
4. By default you can save it locally encrypted with Windows DPAPI.
   The saved secret works only for the same Windows user profile on the same machine context.
5. Later runs become effectively one-click.
6. When the test ends, upload only LATEST_RESULT.zip to ChatGPT.

PASSWORD SAFETY
- Password is never written to test logs, VERDICT.txt or result ZIP.
- Optional saved password is DPAPI-encrypted in .local\wow_password.dpapi.
- .local is intentionally not included in result ZIPs.

RUNNER VERDICTS
PASS_RITUAL_STARTED                 Ritual 698 reached SPELL_START or SPELL_GO.
FAIL_SERVER_REJECT                 Server returned a cast failure reason.
FAIL_ROSTER_TIMEOUT                Summoner did not observe all expected group members.
FAIL_ACCEPTOR_LOST_DURING_HANDSHAKE An acceptor lost current-session readiness before ROSTER PASS.
FAIL_READY_TIMEOUT                 3/3 live acceptors were not simultaneously ready.
FAIL_MUTATION_UNCERTAIN            Socket outcome after selection/cast was uncertain; no automatic retry.
FAIL_SUMMONER_EXITED               Summoner process exited before a ritual result.
FAIL_TEST_TIMEOUT                  No terminal ritual result before runner timeout.

OUTPUT
results\LIVE_TEST_YYYYMMDD_HHMMSS\  raw logs + RUNNER.log + VERDICT.txt
results\LIVE_TEST_YYYYMMDD_HHMMSS.zip
LATEST_RESULT.zip                    copy of the newest result for easy upload

The runner only terminates processes that it started itself.
