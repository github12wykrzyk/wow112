# Terminal AH development moved

As of 2026-10-08, new WoW 1.12 headless/terminal Auction House development lives in:

`github12wykrzyk/112ahterminal` on branch `main`.

This `wow112/dev/windows-ah-canonical` branch is retained as migration provenance/reference for the pinned source commit used by the dedicated repository.

Do not start new terminal-AH feature work here. Do not backport routine `112ahterminal` work into this branch.

If an old implementation detail is needed, treat this repository as read-only historical evidence and move the recovered primitive into `112ahterminal` with explicit provenance and verification.
