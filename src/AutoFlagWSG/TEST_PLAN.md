# AutoFlagWSG 5875 — TEST candidate acceptance

Scope: World of Warcraft 1.12.1 build 5875, Windows x86, Warsong Gulch only.
This file records the functional smoke tests for the companion DLL built by
`tools/build_autoflagwsg_candidate.py` in `build_work_candidate.yml`.

## Required CI gates
- Build the isolated companion as PE32 x86 with a nonzero entry point.
- Verify one EXE and all DLLs in ZIP root and exact `dlls.txt` correspondence.
- Require final `verify_candidate_package.py --finalize` verdict `FINAL_PACKAGE: PASS`.
- Do not promote an untested candidate to `main`.

## Manual acceptance in game
1. On `work`, enable `WSG AutoFlag / Enabled` in ControlHub (Insert). On `parallel`, open Insert > ESP and confirm `WSG AUTO FLAG` is enabled; see Insert > STATUS for `WSG AutoFlag` diagnostics.
2. Stand within 4.75 yd of a flag carrier who drops the flag; verify native
   click without changing the player's selected target or moving the player.
3. Test enemy-flag pickup and friendly-flag return separately. Server eligibility,
   line of sight and post-drop delay remain authoritative.
4. Confirm no flag interactions at either base or outside WSG.
5. Verify the module stays inert during BG loading/exit transitions and after
   disabling the GUI toggle. On `parallel`, verify checkbox OFF prevents new clicks.
6. Confirm `Click attempts` increments on a drop and no crash occurs when
   multiple dropped flags or nearby GameObjects are present.

This candidate is not considered accepted stable until the user verifies it in game.
