/*
  WoWStealthCDGuardian_5875_v2_HARD5S_WATCHDOG

  RECONSTRUCTED FROM THE FINAL V2 DLL.
  Target: World of Warcraft 1.12.1 build 5875, x86.

  Reference DLL SHA-256:
    2bc2f9be3bca94bd0fc77e2c7c0f4fbfa3669cc03787f2cba4214f0acb2e567e

  Recovered behavior:
    - hooks WoW 1.12.1 function 0x006E12C0;
    - recognizes Stealth spell IDs 1784..1787 using (id & ~3) == 1784;
    - forces recovery time to 5000 ms;
    - caps category recovery time at 5000 ms;
    - preserves/chains a pre-existing foreign E9 hook;
    - 50 ms SetTimer watchdog detects a lost hook and repairs it when safe;
    - never overwrites an unknown/unsafe prologue during repair;
    - logs load/forced/repair/lost/install-failure events;
    - restores the bytes that preceded this hook on clean DLL unload, but only
      when the hook site still belongs to this DLL.

  This is a reconstruction, not the original authoring file. Names/comments
  absent from the binary are descriptive. Addresses, constants, control-flow
  decisions and external behavior below come from the final runtime binary.
*/

typedef unsigned char BYTE;
typedef unsigned short WORD;
typedef unsigned int UINT;
typedef unsigned long DWORD;
typedef long LONG;
typedef int BOOL;
typedef void* HANDLE;
typedef void* HWND;
typedef void* HINSTANCE;
typedef void* LPVOID;
typedef unsigned long UINT_PTR;

typedef BOOL (__stdcall *VirtualProtect_t)(LPVOID, DWORD, DWORD, DWORD*);
typedef BOOL (__stdcall *FlushInstructionCache_t)(HANDLE, const void*, DWORD);
typedef HANDLE (__stdcall *GetCurrentProcess_t)(void);
typedef DWORD (__stdcall *GetTickCount_t)(void);
typedef HANDLE (__stdcall *CreateFileA_t)(const char*, DWORD, DWORD, LPVOID, DWORD, DWORD, HANDLE);
typedef DWORD (__stdcall *SetFilePointer_t)(HANDLE, LONG, LONG*, DWORD);
typedef BOOL (__stdcall *WriteFile_t)(HANDLE, const void*, DWORD, DWORD*, LPVOID);
typedef BOOL (__stdcall *CloseHandle_t)(HANDLE);
typedef void (__stdcall *TimerProc_t)(HWND, UINT, UINT_PTR, DWORD);
typedef UINT_PTR (__stdcall *SetTimer_t)(HWND, UINT_PTR, UINT, TimerProc_t);
typedef BOOL (__stdcall *KillTimer_t)(HWND, UINT_PTR);

#define TRUE 1
#define FALSE 0
#define DLL_PROCESS_DETACH 0
#define DLL_PROCESS_ATTACH 1

#define PAGE_EXECUTE_READWRITE 0x40u
#define GENERIC_WRITE          0x40000000u
#define FILE_SHARE_READ        0x00000001u
#define FILE_SHARE_WRITE       0x00000002u
#define OPEN_ALWAYS            4u
#define FILE_ATTRIBUTE_NORMAL  0x80u
#define FILE_END               2u
#define INVALID_HANDLE_VALUE   ((HANDLE)(LONG)-1)

#define WOW_HOOK_SITE           0x006E12C0u
#define WOW_ORIGINAL_CONTINUE   0x006E12C6u
#define WOW_FRAMESCRIPT_EXECUTE 0x00704CD0u

/* WoW.exe IAT slots in the exact 5875 executable. */
#define WOW_IAT_CLOSEHANDLE             0x007FF15Cu
#define WOW_IAT_SETFILEPOINTER          0x007FF190u
#define WOW_IAT_CREATEFILEA             0x007FF1D4u
#define WOW_IAT_WRITEFILE               0x007FF2ECu
#define WOW_IAT_GETTICKCOUNT            0x007FF310u
#define WOW_IAT_FLUSHINSTRUCTIONCACHE   0x007FF320u
#define WOW_IAT_VIRTUALPROTECT          0x007FF35Cu
#define WOW_IAT_GETCURRENTPROCESS       0x007FF390u
#define WOW_IAT_SETTIMER                0x007FF4F4u
#define WOW_IAT_KILLTIMER               0x007FF4F8u

#define STEALTH_ID_BASE 1784u
#define HARD_RECOVERY_MS 5000u
#define WATCHDOG_MS 50u
#define LOST_LOG_THROTTLE_MS 2000u

#define STATUS_UNLOADED       0u
#define STATUS_HEALTHY        1u
#define STATUS_INSTALL_FAILED 2u
#define STATUS_HOOK_LOST      3u

static const BYTE kOriginal5875Prologue[6] = { 0x55, 0x8B, 0xEC, 0x8B, 0x45, 0x14 };
static const char kLogFile[] = "WoWStealthCDGuardian_5875_v2_HARD5S_WATCHDOG.log";
static const char kChatMessage[] =
    "if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage('|cff55ff55[StealthCDGuardian v2]|r HARD 5.0s + hook watchdog active') end";
static const char kHex[] = "0123456789ABCDEF";

/* Runtime state, corresponding to the final DLL's data block. */
static volatile DWORD g_nextTarget = WOW_ORIGINAL_CONTINUE;
static volatile DWORD g_status = STATUS_UNLOADED;
static volatile DWORD g_hookHits = 0;
static volatile DWORD g_hookLost = 0;
static volatile DWORD g_hookRepairs = 0;
static volatile DWORD g_foreignChains = 0;
static volatile UINT_PTR g_timerId = 0;
static BYTE g_hookBytes[6];
static volatile DWORD g_lastSpellId = 0;
static volatile DWORD g_lastOriginalRecovery = 0;
static volatile DWORD g_lastOriginalCategory = 0;
static volatile DWORD g_chainMode = 0; /* 0 = original prologue, 1 = foreign JMP */
static BYTE g_savedBytes[6];
static volatile DWORD g_chatAnnounced = 0;
static volatile DWORD g_lastLoggedHits = 0;
static volatile DWORD g_lastLostLogTick = 0;

static VirtualProtect_t GetVirtualProtect(void) { return *(VirtualProtect_t*)WOW_IAT_VIRTUALPROTECT; }
static FlushInstructionCache_t GetFlushInstructionCache(void) { return *(FlushInstructionCache_t*)WOW_IAT_FLUSHINSTRUCTIONCACHE; }
static GetCurrentProcess_t GetGetCurrentProcess(void) { return *(GetCurrentProcess_t*)WOW_IAT_GETCURRENTPROCESS; }
static GetTickCount_t GetGetTickCount(void) { return *(GetTickCount_t*)WOW_IAT_GETTICKCOUNT; }
static SetTimer_t GetSetTimer(void) { return *(SetTimer_t*)WOW_IAT_SETTIMER; }
static KillTimer_t GetKillTimer(void) { return *(KillTimer_t*)WOW_IAT_KILLTIMER; }

static BOOL BytesEqual6(const BYTE* a, const BYTE* b)
{
    DWORD i;
    for (i = 0; i < 6u; ++i) if (a[i] != b[i]) return FALSE;
    return TRUE;
}

static void Copy6(BYTE* dst, const BYTE* src)
{
    DWORD i;
    for (i = 0; i < 6u; ++i) dst[i] = src[i];
}

static char* AppendText(char* p, const char* s)
{
    while (*s) *p++ = *s++;
    return p;
}

static char* AppendU32(char* p, DWORD v)
{
    char tmp[16];
    DWORD n = 0, i;
    if (!v) { *p++ = '0'; return p; }
    while (v && n < sizeof(tmp)) {
        tmp[n++] = (char)('0' + (v % 10u));
        v /= 10u;
    }
    for (i = 0; i < n; ++i) *p++ = tmp[n - 1u - i];
    return p;
}

static char* AppendHex32(char* p, DWORD v)
{
    int shift;
    for (shift = 28; shift >= 0; shift -= 4)
        *p++ = kHex[(v >> shift) & 0xFu];
    return p;
}

/*
  Calling convention recovered from callsites:
    ECX = event string
    EDX = spell id
    stack = originalRecovery, originalCategory, hitCount, extra
*/
static void __fastcall LogEvent(const char* eventName, DWORD spellId,
                                DWORD originalRecovery, DWORD originalCategory,
                                DWORD hitCount, DWORD extra)
{
    CreateFileA_t createFile = *(CreateFileA_t*)WOW_IAT_CREATEFILEA;
    WriteFile_t writeFile = *(WriteFile_t*)WOW_IAT_WRITEFILE;
    CloseHandle_t closeHandle = *(CloseHandle_t*)WOW_IAT_CLOSEHANDLE;
    SetFilePointer_t setFilePointer = *(SetFilePointer_t*)WOW_IAT_SETFILEPOINTER;
    GetTickCount_t getTickCount = GetGetTickCount();
    char line[640];
    char* p = line;
    HANDLE h;
    DWORD written = 0;

    if (!createFile || !writeFile || !closeHandle || !setFilePointer) return;

    p = AppendText(p, "tick=");
    p = AppendU32(p, getTickCount ? getTickCount() : 0u);
    p = AppendText(p, " event=");
    p = AppendText(p, eventName ? eventName : "");
    p = AppendText(p, " spell=");
    p = AppendU32(p, spellId);
    p = AppendText(p, " original_recovery_ms=");
    p = AppendU32(p, originalRecovery);
    p = AppendText(p, " original_category_ms=");
    p = AppendU32(p, originalCategory);
    p = AppendText(p, " forced_recovery_ms=5000 forced_category_max_ms=5000 hits=");
    p = AppendU32(p, hitCount);
    p = AppendText(p, " repairs=");
    p = AppendU32(p, g_hookRepairs);
    p = AppendText(p, " lost=");
    p = AppendU32(p, g_hookLost);
    p = AppendText(p, " foreign_chains=");
    p = AppendU32(p, g_foreignChains);
    p = AppendText(p, " chain_mode=");
    p = AppendU32(p, g_chainMode);
    p = AppendText(p, " next=0x");
    p = AppendHex32(p, g_nextTarget);
    p = AppendText(p, " extra=0x");
    p = AppendHex32(p, extra);
    p = AppendText(p, " hook=0x006E12C0\r\n");

    h = createFile(kLogFile, GENERIC_WRITE,
                   FILE_SHARE_READ | FILE_SHARE_WRITE, 0,
                   OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, 0);
    if (!h || h == INVALID_HANDLE_VALUE) return;
    setFilePointer(h, 0, 0, FILE_END);
    writeFile(h, line, (DWORD)(p - line), &written, 0);
    closeHandle(h);
}

/* Forward declaration: the JMP patch points directly here. */
__declspec(naked) static void CooldownHook(void);

static void BuildHookBytes(void)
{
    LONG rel = (LONG)((DWORD)(LPVOID)&CooldownHook - (WOW_HOOK_SITE + 5u));
    g_hookBytes[0] = 0xE9;
    *(LONG*)&g_hookBytes[1] = rel;
    g_hookBytes[5] = 0x90;
}

/*
  Install or repair our six-byte JMP.
  repair != 0 increments g_hookRepairs only after a verified successful write.
*/
static BOOL InstallHook(BOOL repair)
{
    VirtualProtect_t vp = GetVirtualProtect();
    FlushInstructionCache_t fic = GetFlushInstructionCache();
    GetCurrentProcess_t gcp = GetGetCurrentProcess();
    BYTE* site = (BYTE*)WOW_HOOK_SITE;
    DWORD oldProtect = 0, tmpProtect = 0;
    DWORD chainMode;
    DWORD nextTarget;
    BOOL foreign = FALSE;
    LONG rel;

    if (!vp || !fic || !gcp) return FALSE;
    if (BytesEqual6(site, g_hookBytes)) return TRUE;

    if (site[0] == 0xE9) {
        rel = *(LONG*)(site + 1);
        nextTarget = WOW_HOOK_SITE + 5u + rel;
        if (nextTarget == (DWORD)(LPVOID)&CooldownHook) return FALSE;
        chainMode = 1u;
        foreign = TRUE;
    } else {
        if (!BytesEqual6(site, kOriginal5875Prologue)) return FALSE;
        nextTarget = WOW_ORIGINAL_CONTINUE;
        chainMode = 0u;
    }

    Copy6(g_savedBytes, site);
    g_chainMode = chainMode;
    g_nextTarget = nextTarget;
    if (foreign) ++g_foreignChains;

    if (!vp(site, 6u, PAGE_EXECUTE_READWRITE, &oldProtect)) return FALSE;
    Copy6(site, g_hookBytes);
    vp(site, 6u, oldProtect, &tmpProtect);
    fic(gcp(), site, 6u);

    if (!BytesEqual6(site, g_hookBytes)) return FALSE;
    if (repair) ++g_hookRepairs;
    return TRUE;
}

static void RestoreHookIfOwned(void)
{
    VirtualProtect_t vp = GetVirtualProtect();
    FlushInstructionCache_t fic = GetFlushInstructionCache();
    GetCurrentProcess_t gcp = GetGetCurrentProcess();
    BYTE* site = (BYTE*)WOW_HOOK_SITE;
    DWORD oldProtect = 0, tmpProtect = 0;

    if (!vp || !fic || !gcp) return;
    /* Do not clobber a hook that replaced us after load. */
    if (!BytesEqual6(site, g_hookBytes)) return;
    if (!vp(site, 6u, PAGE_EXECUTE_READWRITE, &oldProtect)) return;
    Copy6(site, g_savedBytes);
    vp(site, 6u, oldProtect, &tmpProtect);
    fic(gcp(), site, 6u);
}

static void ExecuteChatMessage(void)
{
    const char* s = kChatMessage;
    __asm {
        mov ecx, s
        mov edx, s
        xor eax, eax
        mov ebx, WOW_FRAMESCRIPT_EXECUTE
        call ebx
    }
}

static void __stdcall WatchdogTimerProc(HWND hwnd, UINT msg, UINT_PTR timerId, DWORD now)
{
    BYTE* site = (BYTE*)WOW_HOOK_SITE;
    DWORD observedForeignTarget = 0;
    (void)hwnd; (void)msg; (void)timerId;

    if (BytesEqual6(site, g_hookBytes)) {
        g_status = STATUS_HEALTHY;
    } else {
        ++g_hookLost;
        if (site[0] == 0xE9)
            observedForeignTarget = WOW_HOOK_SITE + 5u + *(LONG*)(site + 1);

        if (InstallHook(TRUE)) {
            g_status = STATUS_HEALTHY;
            LogEvent("HOOK_REPAIRED", 0u, 0u, 0u, g_hookHits, observedForeignTarget);
        } else {
            g_status = STATUS_HOOK_LOST;
            if ((DWORD)(now - g_lastLostLogTick) >= LOST_LOG_THROTTLE_MS) {
                g_lastLostLogTick = now;
                LogEvent("HOOK_LOST_UNSAFE", 0u, 0u, 0u, g_hookHits, observedForeignTarget);
            }
        }
    }

    if (!g_chatAnnounced) {
        g_chatAnnounced = 1u;
        ExecuteChatMessage();
    }

    if (g_hookHits != g_lastLoggedHits) {
        g_lastLoggedHits = g_hookHits;
        LogEvent("STEALTH_CD_FORCED", g_lastSpellId,
                 g_lastOriginalRecovery, g_lastOriginalCategory,
                 g_hookHits, 0u);
    }
}

/*
  Exact recovered hook semantics. The pre-prologue spell ID lives at [ESP+14].
  Stealth ranks 1784..1787 are contiguous, so masking the low two bits maps all
  four to 1784. Recovery is arg [ESP+10], category recovery is [ESP+1C].
*/
__declspec(naked) static void CooldownHook(void)
{
    __asm {
        mov eax, dword ptr [esp+0x14]
        mov edx, eax
        and edx, 0xFFFFFFFC
        cmp edx, STEALTH_ID_BASE
        jne hook_chain

        mov dword ptr [g_lastSpellId], eax
        mov edx, dword ptr [esp+0x10]
        mov dword ptr [g_lastOriginalRecovery], edx
        mov edx, dword ptr [esp+0x1C]
        mov dword ptr [g_lastOriginalCategory], edx

        mov dword ptr [esp+0x10], HARD_RECOVERY_MS
        cmp dword ptr [esp+0x1C], HARD_RECOVERY_MS
        jle category_ok
        mov dword ptr [esp+0x1C], HARD_RECOVERY_MS
    category_ok:
        inc dword ptr [g_hookHits]

    hook_chain:
        cmp dword ptr [g_chainMode], 0
        jne chain_foreign

        /* Reproduce the six original bytes: 55 8B EC 8B 45 14. */
        push ebp
        mov ebp, esp
        mov eax, dword ptr [ebp+0x14]
        mov edx, WOW_ORIGINAL_CONTINUE
        jmp edx

    chain_foreign:
        mov edx, dword ptr [g_nextTarget]
        jmp edx
    }
}

__declspec(dllexport) DWORD __stdcall StealthCDGuardian_GetVersion(void) { return 0x00020000u; }
__declspec(dllexport) DWORD __stdcall StealthCDGuardian_GetStatus(void) { return g_status; }
__declspec(dllexport) DWORD __stdcall StealthCDGuardian_GetHookHits(void) { return g_hookHits; }
__declspec(dllexport) DWORD __stdcall StealthCDGuardian_GetHookLost(void) { return g_hookLost; }
__declspec(dllexport) DWORD __stdcall StealthCDGuardian_GetHookRepairs(void) { return g_hookRepairs; }
__declspec(dllexport) DWORD __stdcall StealthCDGuardian_GetForeignChains(void) { return g_foreignChains; }

BOOL __stdcall DllMain(HINSTANCE hinst, DWORD reason, LPVOID reserved)
{
    (void)hinst; (void)reserved;

    if (reason == DLL_PROCESS_ATTACH) {
        SetTimer_t setTimer;
        BuildHookBytes();
        if (!InstallHook(FALSE)) {
            g_status = STATUS_INSTALL_FAILED;
            LogEvent("HOOK_INSTALL_FAILED", 0u, 0u, 0u, 0u, 0u);
            return FALSE;
        }

        g_status = STATUS_HEALTHY;
        LogEvent("LOAD_HARD5S_WATCHDOG", 0u, 0u, 0u, 0u, g_nextTarget);

        setTimer = GetSetTimer();
        if (setTimer)
            g_timerId = setTimer((HWND)0, 0u, WATCHDOG_MS, WatchdogTimerProc);
    } else if (reason == DLL_PROCESS_DETACH) {
        KillTimer_t killTimer = GetKillTimer();
        if (killTimer && g_timerId)
            killTimer((HWND)0, g_timerId);
        g_timerId = 0;
        RestoreHookIfOwned();
        g_status = STATUS_UNLOADED;
    }

    return TRUE;
}
