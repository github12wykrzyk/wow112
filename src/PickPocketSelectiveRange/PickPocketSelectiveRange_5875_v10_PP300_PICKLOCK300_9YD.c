/*
  PickPocketSelectiveRange_5875_v10_PP300_PICKLOCK300_9YD
  + LockboxLab combined experiment for WoW 1.12.1 build 5875 x86.

  Preserved behavior:
    - ordinary shared Combat Range floor = 9 yd;
    - Pick Pocket (921) max client range = 300 yd;
    - Pick Lock (1804) max client range = 300 yd.

  LockboxLab experiment (single DLL, three paths at once):
    A) client-side Pick Lock cast-time experiment:
       patch Spell.dbc record 1804 CastingTimeIndex (field 18, +0x48) to 0;
    B) early-open protocol/client-path probes:
       after targeting a bag lockbox, issue sparse UseContainerItem probes at
       0.25/0.50/1/2/3/4/4.6/5.1/5.6 s; if the server accepts an early open,
       the loot window timing is printed in chat;
    C) automatic lockbox queue:
       a small injected Vanilla Lua frame scans bags 0..4 for common Vanilla
       lockbox/junkbox item IDs, Pick Locks them one-by-one, opens/loots them,
       then advances to the next box.

  The server remains authoritative.  The client cast-time patch and early-open
  probes are deliberately experimental; the normal ~5 s server path remains a
  fallback.  /lockboxlab toggles the automatic queue at runtime.
*/

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
#define PAGE_EXECUTE_READWRITE 0x40

#define WOW_RANGE_RESOLVER       0x006E3480u
#define WOW_COMBAT_RANGE_FLOOR   0x00801624u
#define WOW_SPELL_INDEX_MAX      0x00C0D78Cu
#define WOW_SPELL_INDEX_TABLE    0x00C0D788u
#define WOW_FRAMESCRIPT_EXECUTE  0x00704CD0u

#define SPELL_CAST_TIME_INDEX_OFF 0x48u /* Spell.dbc field 18 */
#define PICK_POCKET_SPELL_ID       921u
#define PICK_LOCK_SPELL_ID        1804u

/* WoW.exe IAT entries verified for this 5875 executable lineage. */
#define WOW_IAT_VIRTUALPROTECT     0x007FF35Cu
#define WOW_IAT_FLUSHICACHE        0x007FF320u
#define WOW_IAT_GETCURRENTPROCESS  0x007FF390u
#define WOW_IAT_SETTIMER           0x007FF4F4u
#define WOW_IAT_KILLTIMER          0x007FF4F8u

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
static volatile DWORD g_pickLockHits = 0;
static volatile DWORD g_lastSpellId = 0;
static volatile DWORD g_patchedCalls = 0;
static volatile DWORD g_pickLockRecord = 0;
static volatile DWORD g_originalPickLockCastTimeIndex = 0;
static volatile DWORD g_castTimePatched = 0;
static volatile DWORD g_scriptInjected = 0;
static UINT_PTR g_labTimer = 0;

/*
  Lua 5.0-compatible bag worker.  The known IDs cover the normal Vanilla
  junkboxes obtained from Pick Pocket plus the common dropped lockboxes.
  Sparse early UseContainerItem() calls are the protocol-path experiment.
*/
static const char g_lockboxLabScript[] =
"if not WOW112_LockboxLab then "
"WOW112_LockboxLab={enabled=1,next=0,busy=nil,b=0,s=0,id=0,start=0,probe=0,lootStart=0,"
"ids={[4632]=1,[4633]=1,[4634]=1,[4636]=1,[4637]=1,[4638]=1,[5758]=1,[5759]=1,[5760]=1,"
"[16882]=1,[16883]=1,[16884]=1,[16885]=1},skip={},probes={0.25,0.50,1.00,2.00,3.00,4.00,4.60,5.10,5.60}};"
"local L=WOW112_LockboxLab;"
"SLASH_LOCKBOXLAB1='/lockboxlab';"
"SlashCmdList['LOCKBOXLAB']=function(msg) L.enabled=1-L.enabled; "
"if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage(L.enabled==1 and '|cff55ff55[LockboxLab]|r ON' or '|cffffaa00[LockboxLab]|r OFF') end end;"
"local f=CreateFrame('Frame');L.frame=f;"
"f:SetScript('OnUpdate',function() "
"local n=GetTime(); if n<L.next then return end;"
"if L.enabled~=1 then L.next=n+0.50;return end;"
"if L.busy and GetNumLootItems and GetNumLootItems()>0 then "
"if not L.lootStart or L.lootStart==0 then L.lootStart=n; "
"if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage('|cff66ff66[LockboxLab]|r OPEN '..string.format('%.2f',n-L.start)..'s probes='..L.probe) end end;"
"local c=GetNumLootItems();local i;for i=1,c do LootSlot(i) end;"
"if GetNumLootItems()==0 or n-L.lootStart>1.50 then CloseLoot();L.busy=nil;L.lootStart=0;L.next=n+0.40 else L.next=n+0.15 end;return end;"
"if L.busy then "
"local link=GetContainerItemLink(L.b,L.s);if not link then L.busy=nil;L.next=n+0.30;return end;"
"local age=n-L.start;local t=L.probes[L.probe+1];"
"if t and age>=t then L.probe=L.probe+1;UseContainerItem(L.b,L.s);L.next=n+0.08;return end;"
"if age>6.40 then UseContainerItem(L.b,L.s);L.skip[L.id]=n+15.0;"
"if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage('|cffffaa00[LockboxLab]|r timeout >6.4s item='..L.id) end;"
"L.busy=nil;L.next=n+0.50;return end;L.next=n+0.05;return end;"
"if UnitAffectingCombat and UnitAffectingCombat('player') then L.next=n+0.50;return end;"
"local b,s,m,link,a,z,id;for b=0,4 do m=GetContainerNumSlots(b);for s=1,m do link=GetContainerItemLink(b,s);"
"if link then a,z,id=string.find(link,'item:(%d+)');id=tonumber(id);"
"if id and L.ids[id] and (not L.skip[id] or n>=L.skip[id]) then "
"CastSpellByName('Pick Lock');if SpellIsTargeting() then PickupContainerItem(b,s);L.busy=1;L.b=b;L.s=s;L.id=id;L.start=n;L.probe=0;L.lootStart=0;L.next=n+0.05;"
"if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage('|cff66ccff[LockboxLab]|r START item='..id..' bag='..b..' slot='..s) end;return end end end end end;"
"L.next=n+0.75 end);"
"if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage('|cff55ff55[LockboxLab]|r READY: auto queue + early-open probes; /lockboxlab toggle') end "
"end";

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

static BOOL WriteDwordProtected(DWORD address, DWORD value)
{
    BYTE b[4];
    b[0] = (BYTE)(value & 0xFFu);
    b[1] = (BYTE)((value >> 8) & 0xFFu);
    b[2] = (BYTE)((value >> 16) & 0xFFu);
    b[3] = (BYTE)((value >> 24) & 0xFFu);
    return WriteExecutableMemory((BYTE*)address, b, 4u);
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

static DWORD FindSpellRecordById(DWORD spellId)
{
    DWORD maxIndex, i, table, rec;
    table = *(DWORD*)WOW_SPELL_INDEX_TABLE;
    if (!table) return 0;
    maxIndex = *(DWORD*)WOW_SPELL_INDEX_MAX;
    if (maxIndex == 0u || maxIndex > 100000u) return 0;
    for (i = 0; i <= maxIndex; ++i) {
        rec = *(DWORD*)(table + i * 4u);
        if (rec && *(DWORD*)rec == spellId) return rec;
    }
    return 0;
}

static void TryInstallPickLockCastTimeExperiment(void)
{
    DWORD rec, oldIndex;
    if (g_castTimePatched) return;
    rec = FindSpellRecordById(PICK_LOCK_SPELL_ID);
    if (!rec) return;
    oldIndex = *(DWORD*)(rec + SPELL_CAST_TIME_INDEX_OFF);
    g_pickLockRecord = rec;
    g_originalPickLockCastTimeIndex = oldIndex;
    if (oldIndex == 0u) {
        g_castTimePatched = 1u;
        return;
    }
    if (WriteDwordProtected(rec + SPELL_CAST_TIME_INDEX_OFF, 0u))
        g_castTimePatched = 1u;
}

static void __stdcall LockboxLabTimerProc(HWND hwnd, UINT msg, UINT_PTR id, DWORD tick)
{
    (void)hwnd; (void)msg; (void)id; (void)tick;
    TryInstallPickLockCastTimeExperiment();
    if (g_castTimePatched && !g_scriptInjected) {
        ExecuteFrameScript(g_lockboxLabScript);
        g_scriptInjected = 1u;
    }
    if (g_castTimePatched && g_scriptInjected && g_labTimer) {
        KillTimer_t kt = GetKillTimer();
        if (kt) kt((HWND)0, g_labTimer);
        g_labTimer = 0;
    }
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
    SetTimer_t st;

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

    /* Defer Spell.dbc + FrameScript work until client data/UI are initialized. */
    st = GetSetTimer();
    if (st) g_labTimer = st((HWND)0, 0u, 500u, LockboxLabTimerProc);
    return TRUE;
}

static void RemoveHook(void)
{
    DWORD i;
    KillTimer_t kt;

    if (g_labTimer) {
        kt = GetKillTimer();
        if (kt) kt((HWND)0, g_labTimer);
        g_labTimer = 0;
    }

    if (g_castTimePatched && g_pickLockRecord &&
        *(DWORD*)(g_pickLockRecord + SPELL_CAST_TIME_INDEX_OFF) == 0u &&
        g_originalPickLockCastTimeIndex != 0u) {
        WriteDwordProtected(g_pickLockRecord + SPELL_CAST_TIME_INDEX_OFF,
                            g_originalPickLockCastTimeIndex);
    }
    g_castTimePatched = 0;
    g_pickLockRecord = 0;

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

__declspec(dllexport) DWORD __stdcall PickPocketSelective_GetLockboxLabStatus(void)
{
    return (g_installed ? 1u : 0u) |
           (g_castTimePatched ? 2u : 0u) |
           (g_scriptInjected ? 4u : 0u);
}

__declspec(dllexport) DWORD __stdcall PickPocketSelective_GetOriginalPickLockCastTimeIndex(void)
{
    return g_originalPickLockCastTimeIndex;
}

__declspec(dllexport) const char* __stdcall PickPocketSelective_GetBuildTag(void)
{
    return "LOCKBOXLAB_ALL3_20260916";
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
