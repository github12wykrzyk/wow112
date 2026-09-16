/*
  PickPocketSelectiveRange_5875_v10_PP300_PICKLOCK300_9YD
  + AutoJunkbox macro driver for WoW 1.12.1 build 5875 x86.

  Preserved behavior:
    - ordinary shared Combat Range floor = 9 yd;
    - Pick Pocket (921) max client range = 300 yd;
    - Pick Lock (1804) max client range = 300 yd.

  AutoJunkbox behavior:
    - reproduces the user's known-working Vanilla macro semantics;
    - runs only while a LocalPlayer exists, is out of combat, and has remained
      physically stationary for a short settle window;
    - refuses to dispatch while rogue Stealth/Vanish aura is active;
    - does not run while the client reports another spell cast or an open loot
      window;
    - no SlashCmdList/bootstrap dependency, so loading on the login screen is safe;
    - if no item link contains "Junkbox", the macro is a no-op.

  The auto driver intentionally does not alter Pick Lock cast time or attempt
  protocol/early-open tricks.  Server cast timing remains authoritative.
*/

#if !defined(_M_IX86) && !defined(__i386__)
#error This DLL is x86-only.
#endif

typedef unsigned char BYTE;
typedef unsigned long DWORD;
typedef long LONG;
typedef int BOOL;
typedef void* HANDLE;
typedef void* HINSTANCE;
typedef void* LPVOID;
typedef void* HWND;
typedef unsigned int UINT;
typedef DWORD UINT_PTR;

typedef BOOL   (__stdcall *VirtualProtect_t)(LPVOID, DWORD, DWORD, DWORD*);
typedef BOOL   (__stdcall *FlushInstructionCache_t)(HANDLE, const void*, DWORD);
typedef HANDLE (__stdcall *GetCurrentProcess_t)(void);
typedef void   (__stdcall *TimerProc_t)(HWND, UINT, UINT_PTR, DWORD);
typedef UINT_PTR (__stdcall *SetTimer_t)(HWND, UINT_PTR, UINT, TimerProc_t);
typedef BOOL   (__stdcall *KillTimer_t)(HWND, UINT_PTR);

#define TRUE 1
#define FALSE 0
#define DLL_PROCESS_DETACH 0
#define DLL_PROCESS_ATTACH 1
#define PAGE_EXECUTE_READWRITE 0x40u

/* Range path already verified for this active module lineage. */
#define WOW_RANGE_RESOLVER       0x006E3480u
#define WOW_COMBAT_RANGE_FLOOR   0x00801624u
#define WOW_SPELL_INDEX_MAX      0x00C0D78Cu
#define WOW_SPELL_INDEX_TABLE    0x00C0D788u
#define WOW_FRAMESCRIPT_EXECUTE  0x00704CD0u

#define PICK_POCKET_SPELL_ID       921u
#define PICK_LOCK_SPELL_ID        1804u

/* Verified build-5875 LocalPlayer/object fields shared with MovementCore. */
#define WOW_OBJECT_MANAGER_PTR     0x00B41414u
#define OM_FIRST_OBJECT_OFF        0x00ACu
#define OM_PLAYER_GUID_LO_OFF      0x00C0u
#define OM_PLAYER_GUID_HI_OFF      0x00C4u
#define OBJ_DESCRIPTOR_PTR_OFF     0x0008u
#define OBJ_GUID_LO_OFF            0x0030u
#define OBJ_GUID_HI_OFF            0x0034u
#define OBJ_NEXT_OFF               0x003Cu
#define OBJ_X_OFF                  0x09B8u
#define OBJ_Y_OFF                  0x09BCu
#define OBJ_Z_OFF                  0x09C0u
#define UNIT_FIELD_FLAGS_INDEX     0x002Eu
#define UNIT_FIELD_AURA_INDEX      0x002Fu
#define UNIT_FIELD_AURA_SLOTS      48u
#define UNIT_FLAG_IN_COMBAT        0x00080000u

/* Rogue stealth aura family verified in the active MovementCore lineage. */
#define SPELL_STEALTH_R1           1784u
#define SPELL_STEALTH_R2           1785u
#define SPELL_STEALTH_R3           1786u
#define SPELL_STEALTH_R4           1787u
#define SPELL_VANISH_STEALTH_R1   11327u
#define SPELL_VANISH_STEALTH_R2   11329u

/* Current canonical MovementCore uses these globals for arbitration. */
#define WOW_CASTING_SPELLID        0x00CECA88u
#define WOW_IS_LOOTING_STATE       0x00B71B48u

/* WoW.exe IAT entries verified for this 5875 executable lineage. */
#define WOW_IAT_VIRTUALPROTECT      0x007FF35Cu
#define WOW_IAT_FLUSHICACHE         0x007FF320u
#define WOW_IAT_GETCURRENTPROCESS   0x007FF390u
#define WOW_IAT_SETTIMER            0x007FF4F4u
#define WOW_IAT_KILLTIMER           0x007FF4F8u

#define AUTO_TIMER_MS                 100u
#define STATIONARY_SETTLE_MS          650u
#define MACRO_RETRY_GAP_MS            750u
#define STATIONARY_EPSILON            0.03f

/* Required by MSVC CRT-less x86 when floating-point operations are emitted. */
int _fltused = 0x9875;

static const DWORD g_callsites[] = {
    0x004825CAu,
    0x00482870u,
    0x004E587Bu,
    0x0052E9DDu,
    0x005F0638u,
    0x005F3328u,
    0x006113B4u,
    0x006E47D5u,
    0x006E543Fu,
    0x006E67D1u,
    0x006E68B0u
};
#define CALLSITE_COUNT ((DWORD)(sizeof(g_callsites) / sizeof(g_callsites[0])))

static const BYTE g_300f[4] = { 0x00, 0x00, 0x96, 0x43 };
static const BYTE g_9f[4]   = { 0x00, 0x00, 0x10, 0x41 };

static volatile DWORD g_installed = 0u;
static volatile DWORD g_pickPocketHits = 0u;
static volatile DWORD g_pickLockHits = 0u;
static volatile DWORD g_lastSpellId = 0u;
static volatile DWORD g_patchedCalls = 0u;
static volatile DWORD g_macroDispatches = 0u;
static volatile DWORD g_stationary = 0u;
static volatile DWORD g_lastMacroTick = 0u;
static volatile DWORD g_stationarySince = 0u;
static volatile DWORD g_havePosition = 0u;
static float g_lastX = 0.0f;
static float g_lastY = 0.0f;
static float g_lastZ = 0.0f;
static UINT_PTR g_autoTimer = 0u;

/* Exact working macro sequence supplied by the user, wrapped only in API guards. */
static const char g_junkboxMacroScript[] =
"if GetContainerNumSlots and GetContainerItemLink and CastSpellByName and PickupContainerItem and ClearCursor and string and string.find then "
"for b=0,4 do for s=1,GetContainerNumSlots(b) do l=GetContainerItemLink(b,s) if l~=nil then "
"if string.find(l,'Junkbox') then CastSpellByName('Pick Lock') PickupContainerItem(b,s) ClearCursor() end "
"end end end end";

static VirtualProtect_t GetVirtualProtect(void)
{
    return *(VirtualProtect_t*)WOW_IAT_VIRTUALPROTECT;
}

static FlushInstructionCache_t GetFlushInstructionCache(void)
{
    return *(FlushInstructionCache_t*)WOW_IAT_FLUSHICACHE;
}

static GetCurrentProcess_t GetGetCurrentProcess(void)
{
    return *(GetCurrentProcess_t*)WOW_IAT_GETCURRENTPROCESS;
}

static SetTimer_t GetSetTimer(void)
{
    return *(SetTimer_t*)WOW_IAT_SETTIMER;
}

static KillTimer_t GetKillTimer(void)
{
    return *(KillTimer_t*)WOW_IAT_KILLTIMER;
}

static BOOL Ptr(const void* p)
{
    DWORD v = (DWORD)p;
    return v >= 0x10000u && v <= 0x7FFDFFFFu && !(v & 1u);
}

static float AbsF(float v)
{
    return v < 0.0f ? -v : v;
}

static BOOL MemoryEquals(const BYTE* a, const BYTE* b, DWORD n)
{
    DWORD i;
    for (i = 0; i < n; ++i) {
        if (a[i] != b[i]) return FALSE;
    }
    return TRUE;
}

static BOOL WriteExecutableMemory(BYTE* dst, const BYTE* src, DWORD n)
{
    DWORD oldProtect = 0u, tmpProtect = 0u, i;
    VirtualProtect_t vp = GetVirtualProtect();
    FlushInstructionCache_t fic = GetFlushInstructionCache();
    GetCurrentProcess_t gcp = GetGetCurrentProcess();

    if (!vp || !fic || !gcp) return FALSE;
    if (!vp(dst, n, PAGE_EXECUTE_READWRITE, &oldProtect)) return FALSE;

    for (i = 0u; i < n; ++i) dst[i] = src[i];
    fic(gcp(), dst, n);
    vp(dst, n, oldProtect, &tmpProtect);
    return TRUE;
}

static DWORD DecodeDirectCallTarget(DWORD site)
{
    LONG rel;
    if (*(BYTE*)site != 0xE8u) return 0u;
    rel = *(LONG*)(site + 1u);
    return (DWORD)(site + 5u + rel);
}

static BOOL PatchDirectCall(DWORD site, DWORD target)
{
    BYTE patch[5];
    LONG rel = (LONG)(target - (site + 5u));

    patch[0] = 0xE8u;
    patch[1] = (BYTE)(rel & 0xFF);
    patch[2] = (BYTE)((rel >> 8) & 0xFF);
    patch[3] = (BYTE)((rel >> 16) & 0xFF);
    patch[4] = (BYTE)((rel >> 24) & 0xFF);
    return WriteExecutableMemory((BYTE*)site, patch, 5u);
}

static void ExecuteFrameScript(const char* script)
{
    DWORD fn = WOW_FRAMESCRIPT_EXECUTE;
    if (!script) return;
    __asm {
        push ebx
        mov ecx, script
        mov edx, script
        xor eax, eax
        mov ebx, fn
        call ebx
        pop ebx
    }
}

static BYTE* LocalPlayer(void)
{
    BYTE* manager = *(BYTE**)WOW_OBJECT_MANAGER_PTR;
    BYTE* object;
    DWORD lo, hi, i;

    if (!Ptr(manager)) return 0;
    lo = *(DWORD*)(manager + OM_PLAYER_GUID_LO_OFF);
    hi = *(DWORD*)(manager + OM_PLAYER_GUID_HI_OFF);
    if ((lo | hi) == 0u) return 0;

    object = *(BYTE**)(manager + OM_FIRST_OBJECT_OFF);
    for (i = 0u; i < 4095u && Ptr(object); ++i) {
        BYTE* next;
        if (*(DWORD*)(object + OBJ_GUID_LO_OFF) == lo &&
            *(DWORD*)(object + OBJ_GUID_HI_OFF) == hi)
            return object;
        next = *(BYTE**)(object + OBJ_NEXT_OFF);
        if (next == object) break;
        object = next;
    }
    return 0;
}

static BOOL PlayerInCombat(BYTE* player)
{
    DWORD* descriptors;
    if (!Ptr(player)) return FALSE;
    descriptors = *(DWORD**)(player + OBJ_DESCRIPTOR_PTR_OFF);
    if (!Ptr(descriptors)) return FALSE;
    return (descriptors[UNIT_FIELD_FLAGS_INDEX] & UNIT_FLAG_IN_COMBAT) ? TRUE : FALSE;
}

static BOOL IsStealthSpell(DWORD spellId)
{
    return spellId == SPELL_STEALTH_R1 ||
           spellId == SPELL_STEALTH_R2 ||
           spellId == SPELL_STEALTH_R3 ||
           spellId == SPELL_STEALTH_R4 ||
           spellId == SPELL_VANISH_STEALTH_R1 ||
           spellId == SPELL_VANISH_STEALTH_R2;
}

static BOOL PlayerHasStealth(BYTE* player)
{
    DWORD* descriptors;
    DWORD i, spellId;

    if (!Ptr(player)) return FALSE;
    descriptors = *(DWORD**)(player + OBJ_DESCRIPTOR_PTR_OFF);
    if (!Ptr(descriptors)) return FALSE;

    for (i = 0u; i < UNIT_FIELD_AURA_SLOTS; ++i) {
        spellId = descriptors[UNIT_FIELD_AURA_INDEX + i];
        if (spellId && IsStealthSpell(spellId)) return TRUE;
    }
    return FALSE;
}

static void ResetStationaryState(void)
{
    g_havePosition = 0u;
    g_stationarySince = 0u;
    g_stationary = 0u;
}

static BOOL PlayerStationary(BYTE* player, DWORD tick)
{
    float x, y, z;

    if (!Ptr(player)) {
        ResetStationaryState();
        return FALSE;
    }

    x = *(float*)(player + OBJ_X_OFF);
    y = *(float*)(player + OBJ_Y_OFF);
    z = *(float*)(player + OBJ_Z_OFF);

    if (!g_havePosition) {
        g_lastX = x;
        g_lastY = y;
        g_lastZ = z;
        g_havePosition = 1u;
        g_stationarySince = tick;
        g_stationary = 0u;
        return FALSE;
    }

    if (AbsF(x - g_lastX) > STATIONARY_EPSILON ||
        AbsF(y - g_lastY) > STATIONARY_EPSILON ||
        AbsF(z - g_lastZ) > STATIONARY_EPSILON) {
        g_lastX = x;
        g_lastY = y;
        g_lastZ = z;
        g_stationarySince = tick;
        g_stationary = 0u;
        return FALSE;
    }

    if ((DWORD)(tick - g_stationarySince) < STATIONARY_SETTLE_MS) {
        g_stationary = 0u;
        return FALSE;
    }

    g_stationary = 1u;
    return TRUE;
}

static void __stdcall AutoJunkboxTimerProc(HWND hwnd, UINT msg, UINT_PTR id, DWORD tick)
{
    BYTE* player;
    (void)hwnd;
    (void)msg;
    (void)id;

    player = LocalPlayer();
    if (!player) {
        ResetStationaryState();
        return;
    }

    /* Never break rogue stealth for a bag lockbox.  Reset the settle state so
       leaving stealth requires a fresh stationary window before automation. */
    if (PlayerHasStealth(player)) {
        ResetStationaryState();
        return;
    }

    if (!PlayerStationary(player, tick)) return;
    if (PlayerInCombat(player)) return;
    if (*(DWORD*)WOW_CASTING_SPELLID != 0u) return;
    if (*(DWORD*)WOW_IS_LOOTING_STATE != 0u) return;
    if (g_lastMacroTick != 0u &&
        (DWORD)(tick - g_lastMacroTick) < MACRO_RETRY_GAP_MS)
        return;

    ExecuteFrameScript(g_junkboxMacroScript);
    g_lastMacroTick = tick;
    ++g_macroDispatches;
}

/*
  Wrapper for 006E3480.

  Incoming state is identical to the original function:
      ECX = caster/object
      EDX = internal spell index
      [ESP+4]  = float* minRange
      [ESP+8]  = float* maxRange
      [ESP+12] = target/context
*/
__declspec(naked) static void RangeResolverWrapper(void)
{
    __asm {
        push ebp
        mov  ebp, esp
        sub  esp, 0x0C

        mov  dword ptr [ebp-4], edx
        mov  dword ptr [ebp-8], ecx

        push dword ptr [ebp+16]
        push dword ptr [ebp+12]
        push dword ptr [ebp+8]
        mov  ecx, dword ptr [ebp-8]
        mov  edx, dword ptr [ebp-4]
        mov  eax, WOW_RANGE_RESOLVER
        call eax
        mov  dword ptr [ebp-12], eax

        mov  edx, dword ptr [ebp-4]
        test edx, edx
        jl   wrapper_done

        mov  eax, WOW_SPELL_INDEX_MAX
        cmp  edx, dword ptr [eax]
        jg   wrapper_done

        mov  eax, WOW_SPELL_INDEX_TABLE
        mov  eax, dword ptr [eax]
        test eax, eax
        jz   wrapper_done
        mov  eax, dword ptr [eax+edx*4]
        test eax, eax
        jz   wrapper_done

        mov  ecx, dword ptr [eax]
        mov  dword ptr [g_lastSpellId], ecx
        cmp  ecx, PICK_POCKET_SPELL_ID
        je   wrapper_pickpocket
        cmp  ecx, PICK_LOCK_SPELL_ID
        je   wrapper_picklock
        jmp  wrapper_done

    wrapper_pickpocket:
        mov  eax, dword ptr [ebp+12]
        test eax, eax
        jz   wrapper_done
        mov  dword ptr [eax], 0x43960000
        inc  dword ptr [g_pickPocketHits]
        jmp  wrapper_done

    wrapper_picklock:
        mov  eax, dword ptr [ebp+12]
        test eax, eax
        jz   wrapper_done
        mov  dword ptr [eax], 0x43960000
        inc  dword ptr [g_pickLockHits]

    wrapper_done:
        mov  eax, dword ptr [ebp-12]
        mov  esp, ebp
        pop  ebp
        ret  0x0C
    }
}

static BOOL ValidateTargetBuild(void)
{
    DWORD i;
    if (!MemoryEquals((const BYTE*)WOW_COMBAT_RANGE_FLOOR, g_300f, 4u))
        return FALSE;

    for (i = 0u; i < CALLSITE_COUNT; ++i) {
        if (DecodeDirectCallTarget(g_callsites[i]) != WOW_RANGE_RESOLVER)
            return FALSE;
    }
    return TRUE;
}

static BOOL InstallHook(void)
{
    DWORD i;
    DWORD wrapper = (DWORD)(LPVOID)&RangeResolverWrapper;
    SetTimer_t st;

    if (!ValidateTargetBuild()) return FALSE;
    if (!WriteExecutableMemory((BYTE*)WOW_COMBAT_RANGE_FLOOR, g_9f, 4u))
        return FALSE;

    for (i = 0u; i < CALLSITE_COUNT; ++i) {
        if (!PatchDirectCall(g_callsites[i], wrapper)) {
            DWORD j;
            for (j = 0u; j < i; ++j)
                PatchDirectCall(g_callsites[j], WOW_RANGE_RESOLVER);
            WriteExecutableMemory((BYTE*)WOW_COMBAT_RANGE_FLOOR, g_300f, 4u);
            return FALSE;
        }
        g_patchedCalls = i + 1u;
    }

    st = GetSetTimer();
    if (!st) {
        for (i = 0u; i < g_patchedCalls; ++i)
            PatchDirectCall(g_callsites[i], WOW_RANGE_RESOLVER);
        g_patchedCalls = 0u;
        WriteExecutableMemory((BYTE*)WOW_COMBAT_RANGE_FLOOR, g_300f, 4u);
        return FALSE;
    }

    g_autoTimer = st((HWND)0, 0u, AUTO_TIMER_MS, AutoJunkboxTimerProc);
    if (!g_autoTimer) {
        for (i = 0u; i < g_patchedCalls; ++i)
            PatchDirectCall(g_callsites[i], WOW_RANGE_RESOLVER);
        g_patchedCalls = 0u;
        WriteExecutableMemory((BYTE*)WOW_COMBAT_RANGE_FLOOR, g_300f, 4u);
        return FALSE;
    }

    g_installed = 1u;
    return TRUE;
}

static void RemoveHook(void)
{
    DWORD i;
    KillTimer_t kt;

    if (g_autoTimer) {
        kt = GetKillTimer();
        if (kt) kt((HWND)0, g_autoTimer);
        g_autoTimer = 0u;
    }

    if (!g_installed && !g_patchedCalls) return;

    for (i = 0u; i < g_patchedCalls; ++i)
        PatchDirectCall(g_callsites[i], WOW_RANGE_RESOLVER);

    WriteExecutableMemory((BYTE*)WOW_COMBAT_RANGE_FLOOR, g_300f, 4u);
    g_patchedCalls = 0u;
    g_installed = 0u;
    ResetStationaryState();
}

__declspec(dllexport) DWORD __stdcall PickPocketSelective_GetStatus(void)
{
    return g_installed;
}

__declspec(dllexport) DWORD __stdcall PickPocketSelective_GetHitCount(void)
{
    return g_pickPocketHits;
}

__declspec(dllexport) DWORD __stdcall PickPocketSelective_GetLastSpellId(void)
{
    return g_lastSpellId;
}

__declspec(dllexport) DWORD __stdcall PickPocketSelective_GetPickLockHitCount(void)
{
    return g_pickLockHits;
}

/* Compatibility exports retained from the previous LockboxLab candidate. */
__declspec(dllexport) DWORD __stdcall PickPocketSelective_GetLockboxLabStatus(void)
{
    return (g_installed ? 1u : 0u) |
           (g_stationary ? 2u : 0u) |
           (5u << 8);
}

__declspec(dllexport) DWORD __stdcall PickPocketSelective_GetLockboxLabMode(void)
{
    return 5u;
}

__declspec(dllexport) DWORD __stdcall PickPocketSelective_GetOriginalPickLockCastTimeIndex(void)
{
    return 0u;
}

__declspec(dllexport) DWORD __stdcall PickPocketSelective_GetAutoJunkboxDispatchCount(void)
{
    return g_macroDispatches;
}

__declspec(dllexport) const char* __stdcall PickPocketSelective_GetBuildTag(void)
{
    return "AUTOJUNKBOX_MACRO_STATIONARY_STEALTHSAFE_V2_20260916";
}

BOOL __stdcall DllMain(HINSTANCE hinst, DWORD reason, LPVOID reserved)
{
    (void)hinst;
    (void)reserved;

    if (reason == DLL_PROCESS_ATTACH) {
        if (!InstallHook()) return FALSE;
    } else if (reason == DLL_PROCESS_DETACH) {
        RemoveHook();
    }
    return TRUE;
}
