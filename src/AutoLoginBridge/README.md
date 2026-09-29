# AutoLoginBridge 5875

Process-scoped native auto-login bridge for WoW 1.12.1 build 5875 x86.

The updater keeps passwords encrypted in its existing Windows DPAPI vault. A Multibox launch passes the account name plus the **still-encrypted DPAPI blob** through the child process environment. The DLL clears both environment variables immediately after reading them, waits for the normal Glue login screen, decrypts the password locally, calls the verified native login routine, and scrubs plaintext memory.

No keyboard input, TAB sequencing, foreground-window switching or fixed login-screen delay is used.

Exact current PARALLEL evidence: candidate commit `5328812bebb5bdfdd0d554ed95c4e243ae918c7c`, EXE SHA256 `c841336b297e10df597da6a0b5ded4a66efae22f17c3d64d0a88438d39e4bc06`. Binary inspection confirms the native Glue login entry at `0x0046AFB0` and readiness globals `0x00B41DFC`, `0x00B41E04`, `0x00B41DA0`.

External corroboration used only as reverse-engineering evidence: ClassicAPI commit `71805db62f1e8a154477033dc1f50960c535af8b` (GPL-3.0-or-later). This module is independently implemented.
