/*
  PickPocketSelectiveRange_5875_v10_PP300_PICKLOCK300_9YD

  RECONSTRUCTED FROM THE FINAL V10 DLL.
  Target: World of Warcraft 1.12.1 build 5875, x86.

  Reconstruction evidence:
    - reference DLL SHA-256:
      efea7ea55788abf8bf7b6302c5576590b386d3cb29f78639e596e3984fd6c7ba
    - final DLL disassembly and PE data tables
    - verified historical v8 source used as lineage/reference

  Functional behavior recovered from v10 binary:
    - shared Combat Range floor is changed from 300.0f to 9.0f;
    - Pick Pocket (Spell ID 921 / 0x399) gets maxRange 300.0f;
    - Pick Lock   (Spell ID 1804 / 0x70C) gets maxRange 300.0f;
    - all other spells use the ordinary 9 yd client-side floor;
    - all 11 direct calls to the 5875 range resolver are redirected through
      the wrapper and restored on unload;
    - status, last spell ID and separate Pick Pocket / Pick Lock hit counters
      are exported.

  This is a source reconstruction, not the original authoring file. Local
  variable names/comments that were not present in the binary are descriptive.
*/

typedef unsigned char BYTE;
typedef unsigned long DWORD;
typedef long LONG;
typedef int BOOL;
typedef void* HANDLE;
typedef void* HINSTANCE;
typedef void* LPVOID;

typedef BOOL   (__stdcall *VirtualProtect_t)(LPVOID, DWORD, DWORD, DWORD*);
typedef BOOL   (__stdcall *FlushInstructionCache_t)(HANDLE, const void*, DWORD);
typedef HANDLE (__stdcall *GetCurrentProcess_t)(void);

#define TRUE 1
#define FALSE 0
#define DLL_PROCESS_DETACH 0
#define DLL_PROCESS_ATTACH 1
#define PAGE_EXECUTE_READWRITE 0x40

#define WOW_RANGE_RESOLVER      0x006E3480u
#define WOW_COMBAT_RANGE_FLOOR  0x00801624u
#define WOW_SPELL_INDEX_MAX     0x00C0D78Cu
#define WOW_SPELL_INDEX_TABLE   0x00C0D788u

#define PICK_POCKET_SPELL_ID    921u
#define PICK_LOCK_SPELL_ID      1804u

/* WoW.exe IAT entries for this exact 5875 executable. */
#define WOW_IAT_VIRTUALPROTECT     0x007FF35Cu
#define WOW_IAT_FLUSHICACHE        0x007FF320u
#define WOW_IAT_GETCURRENTPROCESS  0x007FF390u

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

static volatile DWORD g_installed = 0;
static volatile DWORD g_pickPocketHits = 0;
static volatile DWORD g_lastSpellId = 0;
static volatile DWORD g_pickLockHits = 0;
static volatile DWORD g_patchedCalls = 0;

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
    DWORD oldProtect = 0, tmpProtect = 0, i;
    VirtualProtect_t vp = GetVirtualProtect();
    FlushInstructionCache_t fic = GetFlushInstructionCache();
    GetCurrentProcess_t gcp = GetGetCurrentProcess();

    if (!vp || !fic || !gcp) return FALSE;
    if (!vp(dst, n, PAGE_EXECUTE_READWRITE, &oldProtect)) return FALSE;

    for (i = 0; i < n; ++i) dst[i] = src[i];
    fic(gcp(), dst, n);
    vp(dst, n, oldProtect, &tmpProtect);
    return TRUE;
}

static DWORD DecodeDirectCallTarget(DWORD site)
{
    LONG rel;
    if (*(BYTE*)site != 0xE8) return 0;
    rel = *(LONG*)(site + 1u);
    return (DWORD)(site + 5u + rel);
}

static BOOL PatchDirectCall(DWORD site, DWORD target)
{
    BYTE patch[5];
    LONG rel = (LONG)(target - (site + 5u));

    patch[0] = 0xE8;
    patch[1] = (BYTE)(rel & 0xFF);
    patch[2] = (BYTE)((rel >> 8) & 0xFF);
    patch[3] = (BYTE)((rel >> 16) & 0xFF);
    patch[4] = (BYTE)((rel >> 24) & 0xFF);
    return WriteExecutableMemory((BYTE*)site, patch, 5);
}

/*
  Wrapper for 006E3480.

  Incoming state:
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
        je   pick_pocket
        cmp  ecx, PICK_LOCK_SPELL_ID
        je   pick_lock
        jmp  wrapper_done

    pick_pocket:
        mov  eax, dword ptr [ebp+12]
        test eax, eax
        jz   wrapper_done
        mov  dword ptr [eax], 0x43960000
        inc  dword ptr [g_pickPocketHits]
        jmp  wrapper_done

    pick_lock:
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

    if (!MemoryEquals((const BYTE*)WOW_COMBAT_RANGE_FLOOR, g_300f, 4))
        return FALSE;

    for (i = 0; i < CALLSITE_COUNT; ++i) {
        if (DecodeDirectCallTarget(g_callsites[i]) != WOW_RANGE_RESOLVER)
            return FALSE;
    }
    return TRUE;
}

static BOOL InstallHook(void)
{
    DWORD i;
    DWORD wrapper = (DWORD)(LPVOID)&RangeResolverWrapper;

    if (!ValidateTargetBuild()) return FALSE;

    if (!WriteExecutableMemory((BYTE*)WOW_COMBAT_RANGE_FLOOR, g_9f, 4))
        return FALSE;

    for (i = 0; i < CALLSITE_COUNT; ++i) {
        if (!PatchDirectCall(g_callsites[i], wrapper)) {
            DWORD j;
            for (j = 0; j < i; ++j)
                PatchDirectCall(g_callsites[j], WOW_RANGE_RESOLVER);
            WriteExecutableMemory((BYTE*)WOW_COMBAT_RANGE_FLOOR, g_300f, 4);
            return FALSE;
        }
        g_patchedCalls = i + 1u;
    }

    g_installed = 1;
    return TRUE;
}

static void RemoveHook(void)
{
    DWORD i;
    if (!g_installed && !g_patchedCalls) return;

    for (i = 0; i < g_patchedCalls; ++i)
        PatchDirectCall(g_callsites[i], WOW_RANGE_RESOLVER);

    WriteExecutableMemory((BYTE*)WOW_COMBAT_RANGE_FLOOR, g_300f, 4);

    g_patchedCalls = 0;
    g_installed = 0;
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
