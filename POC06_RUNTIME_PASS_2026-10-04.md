# POC-06 RUNTIME PASS — 2026-10-04

Canonical checkpoint for WoW 1.12 Android headless guarded AH BUY.

## Source / build
- Base branch before freeze: `feature/android-headless-poc06-fastbuild`
- Frozen source commit: `b531e849af9a6aaaab19950535be6a4a345a96b8`
- Runtime artifact workflow run: `37236487991`
- Runtime artifact id: `11316110828`
- Runtime artifact digest: `sha256:3b2d43c47cbbe971d51aec29cae658d17289acce1dccb9894e0aba7609c8ed31`
- Target: `x86_64-linux-android`, Android API 21
- Wire build: 7272; world build: 5875

## Runtime proof
Single exact guarded BUY completed successfully on N'Zoth using Booty Bay AH:
- page: 12 (`listfrom=600`)
- auction_id: 468147
- item_id: 117
- count: 1
- expected_buyout: 21 copper
- max_price: 21 copper
- exact precheck: PASS
- single BUY send: PASS
- server command result: action=2, error=0
- post-buy AH total: 60518 -> 60517
- auction absent after BUY: true
- new matching purchase mail: item=117, stack=1
- reconcile: PASS
- final `GUARDED AH BUY CONTROL PASS mode=guarded-buy`

## Safety invariants to preserve
1. Fresh exact revalidation immediately before mutation.
2. Exact `auction_id + item_id + count + buyout` match.
3. Hard max-price guard.
4. After BUY send, never automatically resend on uncertain result.
5. Explicit server result before treating transaction as confirmed.
6. Reconcile through AH disappearance and/or matching purchase mail.
7. Page-aware scan/revalidation/reconcile must use the same selected page.

This branch is a known-good recovery point. POC-07 work must branch from this checkpoint and must not mutate this checkpoint branch.
