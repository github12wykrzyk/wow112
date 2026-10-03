/*
 * WoWAHThrottleNative_5875_v9_PRODUCTION_SAFE.c
 * Target: World of Warcraft 1.12.1 build 5875, Windows x86.
 *
 * Production-safe replacement for the experimental AH native throttle/probe.
 *
 * IMPORTANT:
 * - Keeps the legacy runtime DLL filename so the updater overwrites an older
 *   hooking build instead of leaving it active beside the new package.
 * - Installs no ClientServices::Send hook.
 * - Installs no SMSG_AUCTION_LIST_RESULT receive hook.
 * - Creates no timers and executes no Lua/FrameScript callbacks.
 * - Does not patch QueryAuctionItems or any other game memory.
 * - Performs no bid/buy action.
 *
 * The historical v8 source remains in the repository for isolated diagnostic
 * research, but it is no longer the source of the production parallel DLL.
 */
#if !defined(_M_IX86) && !defined(__i386__)
#error Requires WoW 1.12.1 build 5875 x86
#endif

#if defined(_MSC_VER)
#define STDCALL __stdcall
#else
#define STDCALL __attribute__((stdcall))
#endif

typedef unsigned int u32;
typedef int BOOL32;

BOOL32 STDCALL DllMain(void *module, u32 reason, void *reserved)
{
    (void)module;
    (void)reason;
    (void)reserved;
    return 1;
}
