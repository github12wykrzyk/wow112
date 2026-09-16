/*
  PickPocketSelectiveRange_5875_v10_PP300_PICKLOCK300_9YD
  + LockboxLab mode-isolated experiment for WoW 1.12.1 build 5875 x86.

  Preserved behavior:
    - ordinary shared Combat Range floor = 9 yd;
    - Pick Pocket (921) max client range = 300 yd;
    - Pick Lock (1804) max client range = 300 yd.

  LockboxLab keeps all three experimental paths in ONE DLL, but separates them
  into four runtime modes so one in-game session can identify what actually works:

    F6 cycles 1 -> 2 -> 3 -> 4 -> 1

    MODE 1  INSTANT ONLY / MANUAL
      - client Spell.dbc Pick Lock CastingTimeIndex = 0
      - no automatic bag queue
      - no early UseContainerItem probes
      - manually cast Pick Lock to test the client cast-time patch in isolation

    MODE 2  NORMAL CAST + EARLY PROBES
      - original Pick Lock CastingTimeIndex restored
      - automatic lockbox queue enabled
      - sparse UseContainerItem probes at 0.25/0.50/1/2/3/4/4.6/5.1/5.6 s
      - isolates any early-open/server protocol behavior from the instant patch

    MODE 3  NORMAL AUTO BASELINE
      - original Pick Lock CastingTimeIndex restored
      - automatic lockbox queue enabled
      - no early probes; first open attempt is made after 5.20 s
      - control/baseline for reliable serial processing

    MODE 4  EVERYTHING
      - client CastingTimeIndex = 0
      - automatic queue enabled
      - early-open probes enabled
      - combines all experimental paths

  /lockboxlab toggles the automatic worker in modes 2-4.
  The server remains authoritative.  All mode changes are reversible at runtime;
  DLL unload restores the original Pick Lock CastingTimeIndex.
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
typedef short  (__stdcall *GetAsyncKeyState_t)(int);

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
#define WOW_IAT_VIRTUALPROTECT      0x007FF35Cu
#define WOW_IAT_FLUSHICACHE         0x007FF320u
#define WOW_IAT_GETCURRENTPROCESS   0x007FF390u
#define WOW_IAT_SETTIMER            0x007FF4F4u
#define WOW_IAT_KILLTIMER           0x007FF4F8u
#define WOW_IAT_GETASYNCKEYSTATE    0x007FF644u

#define VK_F6 0x75
#define LAB_MODE_INSTANT_ONLY          1u
#define LAB_MODE_NORMAL_PROBES         2u
#define LAB_MODE_NORMAL_AUTO           3u
#define LAB_MODE_ALL                   4u

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
static volatile DWORD g_labMode = LAB_MODE_INSTANT_ONLY;
static volatile DWORD g_f6WasDown = 0;
static UINT_PTR g_labTimer = 0;

/* Lua 5.0-compatible worker.  Mode 1 intentionally does not scan bags. */
static const char g_lockboxLabScript[] =
"if not WOW112_LockboxLab then "
"WOW112_LockboxLab={enabled=1,mode=1,next=0,busy=nil,b=0,s=0,id=0,start=0,probe=0,lootStart=0,normalOpen=0,"
"ids={[4632]=1,[4633]=1,[4634]=1,[4636]=1,[4637]=1,[4638]=1,[5758]=1,[5759]=1,[5760]=1,"
"[16882]=1,[16883]=1,[16884]=1,[16885]=1},skip={},probes={0.25,0.50,1.00,2.00,3.00,4.00,4.60,5.10,5.60}};"
"local L=WOW112_LockboxLab;"
"SLASH_LOCKBOXLAB1='/lockboxlab';"
"SlashCmdList['LOCKBOXLAB']=function(msg) "
"if msg=='on' then L.enabled=1 elseif msg=='off' then L.enabled=0 else L.enabled=1-L.enabled end;"
"if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage((L.enabled==1 and '|cff55ff55[LockboxLab]|r worker ON' or '|cffffaa00[LockboxLab]|r worker OFF')..' mode='..L.mode) end end;"
"local f=CreateFrame('Frame');L.frame=f;"
"f:SetScript('OnUpdate',function() "
"local n=GetTime();if n<L.next then return end;"
"if L.mode==1 then L.next=n+0.50;return end;"
"if L.enabled~=1 then L.next=n+0.50;return end;"
"if L.busy and GetNumLootItems and GetNumLootItems()>0 then "
"if not L.lootStart or L.lootStart==0 then L.lootStart=n;"
"if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage('|cff66ff66[LockboxLab]|r OPEN mode='..L.mode..' '..string.format('%.2f',n-L.start)..'s probes='..L.probe) end end;"
"local c=GetNumLootItems();local i;for i=1,c do LootSlot(i) end;"
"if GetNumLootItems()==0 or n-L.lootStart>1.50 then CloseLoot();L.busy=nil;L.lootStart=0;L.normalOpen=0;L.next=n+0.40 else L.next=n+0.15 end;return end;"
"if L.busy then "
"local link=GetContainerItemLink(L.b,L.s);if not link then L.busy=nil;L.next=n+0.30;return end;"
"local age=n-L.start;"
"if L.mode==2 or L.mode==4 then local t=L.probes[L.probe+1];"
"if t and age>=t then L.probe=L.probe+1;UseContainerItem(L.b,L.s);L.next=n+0.08;return end "
"elseif L.mode==3 then if L.normalOpen==0 and age>=5.20 then L.normalOpen=1;UseContainerItem(L.b,L.s);L.next=n+0.15;return end end;"
"if age>6.50 then UseContainerItem(L.b,L.s);L.skip[L.id]=n+15.0;"
"if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage('|cffffaa00[LockboxLab]|r TIMEOUT mode='..L.mode..' >6.5s item='..L.id) end;"
"L.busy=nil;L.normalOpen=0;L.next=n+0.50;return end;"
"L.next=n+0.05;return end;"
"if UnitAffectingCombat and UnitAffectingCombat('player') then L.next=n+0.50;return end;"
"local b,s,m,link,a,z,id;for b=0,4 do m=GetContainerNumSlots(b);for s=1,m do link=GetContainerItemLink(b,s);"
"if link then a,z,id=string.find(link,'item:(%d+)');id=tonumber(id);"
"if id and L.ids[id] and (not L.skip[id] or n>=L.skip[id]) then "
"CastSpellByName('Pick Lock');if SpellIsTargeting() then PickupContainerItem(b,s);"
"L.busy=1;L.b=b;L.s=s;L.id=id;L.start=n;L.probe=0;L.lootStart=0;L.normalOpen=0;L.next=n+0.05;"
"if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage('|cff66ccff[LockboxLab]|r START mode='..L.mode..' item='..id..' bag='..b..' slot='..s) end;return end end end end end;"
"L.next=n+0.75 end);"
"if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage('|cff55ff55[LockboxLab]|r READY - F6 cycles modes 1-4; /lockboxlab toggles worker; default mode 1') end "
"end";

static const char g_mode1Script[] =
"if WOW112_LockboxLab then local L=WOW112_LockboxLab;L.mode=1;L.busy=nil;L.probe=0;L.lootStart=0;L.normalOpen=0;L.next=GetTime()+0.20;if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage('|cffffff55[LockboxLab]|r MODE 1: INSTANT ONLY / MANUAL') end end";
static const char g_mode2Script[] =
"if WOW112_LockboxLab then local L=WOW112_LockboxLab;L.mode=2;L.busy=nil;L.probe=0;L.lootStart=0;L.normalOpen=0;L.next=GetTime()+0.20;if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage('|cffffff55[LockboxLab]|r MODE 2: NORMAL CAST + EARLY PROBES') end end";
static const char g_mode3Script[] =
"if WOW112_LockboxLab then local L=WOW112_LockboxLab;L.mode=3;L.busy=nil;L.probe=0;L.lootStart=0;L.normalOpen=0;L.next=GetTime()+0.20;if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage('|cffffff55[LockboxLab]|r MODE 3: NORMAL AUTO BASELINE') end end";
static const char g_mode4Script[] =
"if WOW112_LockboxLab then local L=WOW112_LockboxLab;L.mode=4;L.busy=nil;L.probe=0;L.lootStart=0;L.normalOpen=0;L.next=GetTime()+0.20;if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage('|cffffff55[LockboxLab]|r MODE 4: EVERYTHING') end end";

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

static GetAsyncKeyState_t GetGetAsyncKeyState(void)
{
    return *(GetAsyncKeyState_t*)WOW_IAT_GETASYNCKEYSTATE;
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

static BOOL EnsurePickLockRecord(void)
{
    DWORD rec;
    if (g_pickLockRecord) return TRUE;
    rec = FindSpellRecordById(PICK_LOCK_SPELL_ID);
    if (!rec) return FALSE;
    g_pickLockRecord = rec;
    g_originalPickLockCastTimeIndex = *(DWORD*)(rec + SPELL_CAST_TIME_INDEX_OFF);
    return TRUE;
}

static BOOL SetPickLockInstant(BOOL instant)
{
    DWORD current;
    if (!EnsurePickLockRecord()) return FALSE;
    current = *(DWORD*)(g_pickLockRecord + SPELL_CAST_TIME_INDEX_OFF);

    if (instant) {
        if (current != 0u &&
            !WriteDwordProtected(g_pickLockRecord + SPELL_CAST_TIME_INDEX_OFF, 0u))
            return FALSE;
        g_castTimePatched = 1u;
        return TRUE;
    }

    if (g_originalPickLockCastTimeIndex == 0u)
        return FALSE;
    if (current != g_originalPickLockCastTimeIndex &&
        !WriteDwordProtected(g_pickLockRecord + SPELL_CAST_TIME_INDEX_OFF,
                             g_originalPickLockCastTimeIndex))
        return FALSE;
    g_castTimePatched = 0u;
    return TRUE;
}

static BOOL ModeNeedsInstant(DWORD mode)
{
    return (mode == LAB_MODE_INSTANT_ONLY || mode == LAB_MODE_ALL) ? TRUE : FALSE;
}

static const char* ModeScript(DWORD mode)
{
    if (mode == LAB_MODE_INSTANT_ONLY) return g_mode1Script;
    if (mode == LAB_MODE_NORMAL_PROBES) return g_mode2Script;
    if (mode == LAB_MODE_NORMAL_AUTO) return g_mode3Script;
    return g_mode4Script;
}

static BOOL ApplyLabMode(DWORD mode)
{
    if (mode < LAB_MODE_INSTANT_ONLY || mode > LAB_MODE_ALL) return FALSE;
    if (!SetPickLockInstant(ModeNeedsInstant(mode))) return FALSE;
    g_labMode = mode;
    if (g_scriptInjected) ExecuteFrameScript(ModeScript(mode));
    return TRUE;
}

static void __stdcall LockboxLabTimerProc(HWND hwnd, UINT msg, UINT_PTR id, DWORD tick)
{
    GetAsyncKeyState_t gak;
    DWORD down, next;
    (void)hwnd; (void)msg; (void)id; (void)tick;

    if (!EnsurePickLockRecord()) return;

    if (!g_scriptInjected) {
        if (!ApplyLabMode(LAB_MODE_INSTANT_ONLY)) return;
        ExecuteFrameScript(g_lockboxLabScript);
        g_scriptInjected = 1u;
        ExecuteFrameScript(g_mode1Script);
    }

    gak = GetGetAsyncKeyState();
    if (!gak) return;
    down = (gak(VK_F6) & (short)0x8000) ? 1u : 0u;
    if (down && !g_f6WasDown) {
        next = g_labMode + 1u;
        if (next > LAB_MODE_ALL) next = LAB_MODE_INSTANT_ONLY;
        ApplyLabMode(next);
    }
    g_f6WasDown = down;
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

    g_installed = 1u;

    /* Keep the timer alive: it performs deferred initialization and F6 mode switching. */
    st = GetSetTimer();
    if (st) g_labTimer = st((HWND)0, 0u, 100u, LockboxLabTimerProc);
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

    if (g_pickLockRecord && g_originalPickLockCastTimeIndex != 0u &&
        *(DWORD*)(g_pickLockRecord + SPELL_CAST_TIME_INDEX_OFF) !=
        g_originalPickLockCastTimeIndex) {
        WriteDwordProtected(g_pickLockRecord + SPELL_CAST_TIME_INDEX_OFF,
                            g_originalPickLockCastTimeIndex);
    }
    g_castTimePatched = 0u;
    g_pickLockRecord = 0u;

    if (!g_installed && !g_patchedCalls) return;

    for (i = 0; i < g_patchedCalls; ++i)
        PatchDirectCall(g_callsites[i], WOW_RANGE_RESOLVER);

    WriteExecutableMemory((BYTE*)WOW_COMBAT_RANGE_FLOOR, g_300f, 4);

    g_patchedCalls = 0u;
    g_installed = 0u;
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
           (g_scriptInjected ? 4u : 0u) |
           (g_labMode << 8);
}

__declspec(dllexport) DWORD __stdcall PickPocketSelective_GetLockboxLabMode(void)
{
    return g_labMode;
}

__declspec(dllexport) DWORD __stdcall PickPocketSelective_GetOriginalPickLockCastTimeIndex(void)
{
    return g_originalPickLockCastTimeIndex;
}

__declspec(dllexport) const char* __stdcall PickPocketSelective_GetBuildTag(void)
{
    return "LOCKBOXLAB_MODES4_20260916";
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
