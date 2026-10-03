# AuxEconomyShadow — AH consolidation staging area

This directory is the side-by-side staging implementation for consolidating the current Auction House stack.

## Safety boundary

This code is intentionally **not** part of the active `parallel` addon roots and is not part of `runtime/parallel_economy.json`.
It must not replace, patch, wrap, or call the live AH transaction path while the consolidation is being built.

Baseline captured for this experiment:

- base branch: `parallel`
- base commit: `3c48d8a740af2621310c79b7e4e2efeb01a8c4a7`
- active AH at that point remains `aux-addon` + `AuxVmangos` + `AuxFastBridge` + `AHThrottleTest` + the active AH native companion declared by `runtime/parallel_candidate.json`.

The user's working AH must remain uninterrupted until an explicit cutover candidate is independently built, verified and tested.

## Target ownership

The target architecture keeps upstream `aux-addon` external and pinned, while moving all project-owned AH behavior behind one owner with explicit internal modules:

1. Coordinator — one state machine for scan/pause/verify/transaction/resume.
2. AuxAdapter — the only boundary to upstream AUX.
3. Strategies — vendor, disenchant, flip and stack/bid evaluation.
4. TransactionGuard — the only future owner allowed to submit economic actions.
5. AutoSell — repricing/cancel/mail/repost lifecycle.
6. Ledger/UI — reporting and user controls only.

## Iteration 1

The first iteration is deliberately non-functional and read-only:

- define shared record/candidate contracts;
- define the coordinator state model;
- define an inert AUX adapter surface;
- add a repository verifier that proves this shadow module is not shipped and contains no AH action primitives.

No existing AH source, TOC, manifest, loader order, ECONOMY overlay or native module is modified by this iteration.

## Migration rule

Future code moves into this directory in small behavior-preserving slices. A slice is not eligible for integration/cutover merely because it compiles or parses. It must first have equivalent diagnostics/evidence against the currently working AH path. Production cutover happens only after the complete replacement passes the normal feature preflight, exact parallel candidate gates and an explicit in-game acceptance point.
