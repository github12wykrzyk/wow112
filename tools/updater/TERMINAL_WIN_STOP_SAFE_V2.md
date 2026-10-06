# TERMINAL WIN stop-safe v2

STOP is cooperative first: the updater writes a per-account stop tombstone, the native worker closes its world socket and exits, and taskkill is used only as a fallback. START clears the tombstone immediately before launching the next worker.
