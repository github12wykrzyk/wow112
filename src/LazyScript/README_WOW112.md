# LazyScript — source import for wow112

## Scope

This component is an isolated editable **Lua addon source import** for World of Warcraft 1.12.1 build 5875 (Windows x86). It does not change the active DLL or EXE stack, updater, `runtime/current.json`, or stable baseline. It has not been integrated into an installable candidate or verified in game.

## Provenance and integrity

- User-supplied archive: `LazyScript-for-twow-eh-main.zip` (93 files; root directory removed).
- Exact imported upstream Git tree SHA-1: `965dd3389cce2b2395feaaccddcc3ec7ebf79774`.
- Matching public upstream repository: https://github.com/pfmiles/LazyScript-for-twow-eh/tree/e417ba44bbe4e8db5f9927eb2fb369b6ddd4c097 (tree SHA matches uploaded archive).
- Files under `upstream/` preserve the archive's content and relative paths, including the binary `img/corner.tga`. Only this README was added alongside the unmodified source.

## Working layout

- `upstream/Addons/LazyScript/` — base addon.
- `upstream/Addons/LazyRogue/` — Rogue-specific parser and addon code.
- `upstream/Addons/LazyDruid/`, `LazyHunter/`, `LazyMage/`, `LazyPaladin/`, `LazyPriest/`, `LazyShaman/`, `LazyWarlock/`, and `LazyWarrior/` — other class modules.
- `upstream/Scripts/` — example rotation scripts.

For new work, use this exact source lineage on `work` and keep changes localized. Do not silently replace it with a different upstream version or newer WoW client API. Preserve the original code in Git history for rollback. The imported addon is **not automatically included in the WoW runtime test ZIP**.

## Compatibility caveat

The supplied upstream README explicitly states that the addon did not work with SuperWoW as of 2025-04-30. No in-game compatibility or interoperability with this project's DLLs has been confirmed; test any future modified addon separately before packaging or promotion to `main`.
