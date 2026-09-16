/*
 * WoWStealthCDGuardian_5875_v2_HARD5S_WATCHDOG.c
 * World of Warcraft 1.12.1 build 5875 x86
 *
 * v2 goals:
 *   - force Stealth ranks 1784..1787 cooldown insertion to exactly 5000 ms
 *   - watchdog the central cooldown hook and repair it when another module
 *     restores/replaces the entry point
 *   - when a foreign JMP owns the entry, chain through that hook instead of
 *     blindly discarding it
 *
 * Hook site:
 *   0x006E12C0 - central cooldown-entry insertion routine
 *
 * Original bytes:
 *   55 8B EC 8B 45 14
 *
 * Entry argument layout before the original prologue:
 *   [esp+0x10] = recovery duration
 *   [esp+0x14] = spellId
 *   [esp+0x1C] = category recovery duration
 */
#if !defined(_M_IX86) && !defined(__i386__)
#error This DLL is x86-only.
#endif

typedef unsigned char BYTE;
typedef unsigned long DWORD;
typedef signed long LONG;
typedef unsigned int UINT;
typedef int BOOL;
typedef void* HANDLE;
typedef void* HINSTANCE;
typedef void* HWND;
typedef void* LPVOID;
typedef DWORD UINT_PTR;

#define TRUE 1
#define FALSE 0
#define DLL_PROCESS_ATTACH 1
#define DLL_PROCESS_DETACH 0
#define PAGE_EXECUTE_READWRITE 0x40u

int _fltused = 0x9875;

#define ADDR_COOLDOWN_ADD          0x006E12C0u
#define ADDR_COOLDOWN_ADD_RETURN   0x006E12C6u
#define ADDR_FRAMESCRIPT_EXECUTE   0x00704CD0u

#define SPELL_STEALTH_R1 1784u
#define SPELL_STEALTH_R2 1785u
#define SPELL_STEALTH_R3 1786u
#define SPELL_STEALTH_R4 1787u
#define STEALTH_CD_MS     5000u
#define WATCHDOG_MS         50u
#define LOST_LOG_THROTTLE_MS 2000u

#define WOW_IAT_VIRTUALPROTECT      0x007FF35Cu
#define WOW_IAT_FLUSHICACHE         0x007FF320u
#define WOW_IAT_GETCURRENTPROCESS   0x007FF390u
#define WOW_IAT_GETTICKCOUNT        0x007FF310u
#define WOW_IAT_SETTIMER            0x007FF4F4u
#define WOW_IAT_KILLTIMER           0x007FF4F8u
#define WOW_IAT_CLOSEHANDLE         0x007FF15Cu
#define WOW_IAT_SETFILEPOINTER      0x007FF190u
#define WOW_IAT_CREATEFILEA         0x007FF1D4u
#define WOW_IAT_WRITEFILE           0x007FF2ECu

#define GENERIC_WRITE          0x40000000u
#define FILE_SHARE_READ        0x00000001u
#define FILE_SHARE_WRITE       0x00000002u
#define OPEN_ALWAYS                     4u
#define FILE_ATTRIBUTE_NORMAL  0x00000080u
#define FILE_END                         2u
#define INVALID_HANDLE_VALUE  ((HANDLE)(LONG)-1)

typedef BOOL (__stdcall *VirtualProtect_t)(LPVOID,DWORD,DWORD,DWORD*);
typedef BOOL (__stdcall *FlushInstructionCache_t)(HANDLE,const void*,DWORD);
typedef HANDLE (__stdcall *GetCurrentProcess_t)(void);
typedef DWORD (__stdcall *GetTickCount_t)(void);
typedef void (__stdcall *TimerProc_t)(HWND,UINT,UINT_PTR,DWORD);
typedef UINT_PTR (__stdcall *SetTimer_t)(HWND,UINT_PTR,UINT,TimerProc_t);
typedef BOOL (__stdcall *KillTimer_t)(HWND,UINT_PTR);
typedef HANDLE (__stdcall *CreateFileA_t)(const char*,DWORD,DWORD,LPVOID,DWORD,DWORD,HANDLE);
typedef BOOL (__stdcall *WriteFile_t)(HANDLE,const void*,DWORD,DWORD*,LPVOID);
typedef DWORD (__stdcall *SetFilePointer_t)(HANDLE,LONG,LONG*,DWORD);
typedef BOOL (__stdcall *CloseHandle_t)(HANDLE);

static volatile DWORD g_status=0u; /* 0 off, 1 protected, 2 initial fail, 3 lost/unsafe */
static volatile DWORD g_hookHits=0u;
static volatile DWORD g_lastLoggedHits=0u;
static volatile DWORD g_lastSpell=0u;
static volatile DWORD g_lastOriginalRecovery=0u;
static volatile DWORD g_lastOriginalCategory=0u;
static volatile DWORD g_chatShown=0u;
static volatile DWORD g_hookLost=0u;
static volatile DWORD g_hookRepairs=0u;
static volatile DWORD g_foreignChains=0u;
static volatile DWORD g_lastLostLogTick=0u;
static volatile DWORD g_chainMode=0u; /* 0 original bytes, 1 foreign detour */
static volatile DWORD g_nextTarget=ADDR_COOLDOWN_ADD_RETURN;
static volatile UINT_PTR g_timerId=0u;
static BYTE g_restore[6]={0};
static BYTE g_patch[6]={0};
static const BYTE g_expected[6]={0x55,0x8B,0xEC,0x8B,0x45,0x14};
static const char g_logName[]="WoWStealthCDGuardian_5875_v2_HARD5S_WATCHDOG.log";
static const char g_chatScript[]="if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage('|cff55ff55[StealthCDGuardian v2][AI-SMOKE]|r HARD 5.0s + hook watchdog active') end";

static VirtualProtect_t VP(void){return *(VirtualProtect_t*)WOW_IAT_VIRTUALPROTECT;}
static FlushInstructionCache_t FIC(void){return *(FlushInstructionCache_t*)WOW_IAT_FLUSHICACHE;}
static GetCurrentProcess_t GCP(void){return *(GetCurrentProcess_t*)WOW_IAT_GETCURRENTPROCESS;}
static GetTickCount_t GT(void){return *(GetTickCount_t*)WOW_IAT_GETTICKCOUNT;}
static SetTimer_t ST(void){return *(SetTimer_t*)WOW_IAT_SETTIMER;}
static KillTimer_t KT(void){return *(KillTimer_t*)WOW_IAT_KILLTIMER;}
static CreateFileA_t CF(void){return *(CreateFileA_t*)WOW_IAT_CREATEFILEA;}
static WriteFile_t WF(void){return *(WriteFile_t*)WOW_IAT_WRITEFILE;}
static SetFilePointer_t SFP(void){return *(SetFilePointer_t*)WOW_IAT_SETFILEPOINTER;}
static CloseHandle_t CH(void){return *(CloseHandle_t*)WOW_IAT_CLOSEHANDLE;}

static char* AppStr(char*p,const char*s){while(*s)*p++=*s++;return p;}
static char* AppU32(char*p,DWORD v){char t[16];DWORD n=0u;if(!v){*p++='0';return p;}while(v&&n<15u){t[n++]=(char)('0'+(v%10u));v/=10u;}while(n)*p++=t[--n];return p;}
static char* AppHex32(char*p,DWORD v){static const char h[]="0123456789ABCDEF";int i;for(i=7;i>=0;i--)*p++=h[(v>>(i*4))&0xFu];return p;}

static void LogState(const char*event,DWORD spell,DWORD oldRec,DWORD oldCat,DWORD hits,DWORD extra)
{
    char b[640];char*p=b;DWORD wr=0u;HANDLE h;CreateFileA_t cf=CF();WriteFile_t wf=WF();SetFilePointer_t sfp=SFP();CloseHandle_t ch=CH();GetTickCount_t gt=GT();
    if(!cf||!wf||!sfp||!ch)return;
    p=AppStr(p,"tick=");p=AppU32(p,gt?gt():0u);p=AppStr(p," event=");p=AppStr(p,event);
    p=AppStr(p," spell=");p=AppU32(p,spell);p=AppStr(p," original_recovery_ms=");p=AppU32(p,oldRec);
    p=AppStr(p," original_category_ms=");p=AppU32(p,oldCat);p=AppStr(p," forced_recovery_ms=5000 forced_category_max_ms=5000 hits=");p=AppU32(p,hits);
    p=AppStr(p," repairs=");p=AppU32(p,g_hookRepairs);p=AppStr(p," lost=");p=AppU32(p,g_hookLost);p=AppStr(p," foreign_chains=");p=AppU32(p,g_foreignChains);
    p=AppStr(p," chain_mode=");p=AppU32(p,g_chainMode);p=AppStr(p," next=0x");p=AppHex32(p,g_nextTarget);p=AppStr(p," extra=0x");p=AppHex32(p,extra);
    p=AppStr(p," hook=0x");p=AppHex32(p,ADDR_COOLDOWN_ADD);*p++='\r';*p++='\n';
    h=cf(g_logName,GENERIC_WRITE,FILE_SHARE_READ|FILE_SHARE_WRITE,0,OPEN_ALWAYS,FILE_ATTRIBUTE_NORMAL,0);
    if(h==INVALID_HANDLE_VALUE||!h)return;sfp(h,0,0,FILE_END);wf(h,b,(DWORD)(p-b),&wr,0);ch(h);
}

static void DebugChat(const char*script)
{
    DWORD fn=ADDR_FRAMESCRIPT_EXECUTE;if(!script)return;
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

__declspec(naked) static void CooldownAddHook(void)
{
    __asm {
        mov eax, dword ptr [esp+14h]
        mov edx, eax
        and edx, 0FFFFFFFCh
        cmp edx, 06F8h
        jne not_stealth

        mov dword ptr [g_lastSpell], eax
        mov edx, dword ptr [esp+10h]
        mov dword ptr [g_lastOriginalRecovery], edx
        mov edx, dword ptr [esp+1Ch]
        mov dword ptr [g_lastOriginalCategory], edx
        mov dword ptr [esp+10h], 01388h
        cmp dword ptr [esp+1Ch], 01388h
        jle category_ok
        mov dword ptr [esp+1Ch], 01388h
category_ok:
        inc dword ptr [g_hookHits]
not_stealth:
        cmp dword ptr [g_chainMode], 0
        jne chain_foreign
        push ebp
        mov ebp, esp
        mov eax, dword ptr [ebp+14h]
        mov edx, ADDR_COOLDOWN_ADD_RETURN
        jmp edx
chain_foreign:
        mov edx, dword ptr [g_nextTarget]
        jmp edx
    }
}

static BOOL BytesEqual(const BYTE*a,const BYTE*b,DWORD n){DWORD i;for(i=0u;i<n;i++)if(a[i]!=b[i])return FALSE;return TRUE;}

static void BuildPatch(void)
{
    BYTE*site=(BYTE*)ADDR_COOLDOWN_ADD;LONG rel=(LONG)((BYTE*)CooldownAddHook-(site+5));
    g_patch[0]=0xE9;*(LONG*)&g_patch[1]=rel;g_patch[5]=0x90;
}

static BOOL SiteIsOurs(void){return BytesEqual((BYTE*)ADDR_COOLDOWN_ADD,g_patch,6u);}

static BOOL InstallOverCurrent(DWORD isRepair)
{
    BYTE*site=(BYTE*)ADDR_COOLDOWN_ADD;DWORD i,old=0u,tmp=0u;DWORD mode=0u,next=ADDR_COOLDOWN_ADD_RETURN;LONG rel;
    VirtualProtect_t vp=VP();FlushInstructionCache_t fic=FIC();GetCurrentProcess_t gcp=GCP();
    if(!vp||!fic||!gcp)return FALSE;
    if(SiteIsOurs())return TRUE;

    if(BytesEqual(site,g_expected,6u)){
        mode=0u;next=ADDR_COOLDOWN_ADD_RETURN;
    }else if(site[0]==0xE9){
        rel=*(LONG*)&site[1];next=(DWORD)(site+5+rel);
        if(next==(DWORD)(BYTE*)CooldownAddHook)return FALSE;
        mode=1u;
    }else{
        return FALSE;
    }

    for(i=0u;i<6u;i++)g_restore[i]=site[i];
    g_chainMode=mode;g_nextTarget=next;
    if(mode){++g_foreignChains;}
    if(!vp(site,6u,PAGE_EXECUTE_READWRITE,&old))return FALSE;
    for(i=0u;i<6u;i++)site[i]=g_patch[i];
    vp(site,6u,old,&tmp);fic(gcp(),site,6u);
    if(!SiteIsOurs())return FALSE;
    if(isRepair)++g_hookRepairs;
    return TRUE;
}

static void RemoveHook(void)
{
    BYTE*site=(BYTE*)ADDR_COOLDOWN_ADD;DWORD i,old=0u,tmp=0u;VirtualProtect_t vp=VP();FlushInstructionCache_t fic=FIC();GetCurrentProcess_t gcp=GCP();
    if(!vp||!fic||!gcp||!SiteIsOurs())return;
    if(!vp(site,6u,PAGE_EXECUTE_READWRITE,&old))return;
    for(i=0u;i<6u;i++)site[i]=g_restore[i];
    vp(site,6u,old,&tmp);fic(gcp(),site,6u);
}

static void Watchdog(DWORD now)
{
    BYTE*site=(BYTE*)ADDR_COOLDOWN_ADD;DWORD foreign=0u;
    if(SiteIsOurs()){g_status=1u;return;}
    ++g_hookLost;
    if(site[0]==0xE9){LONG r=*(LONG*)&site[1];foreign=(DWORD)(site+5+r);}
    if(InstallOverCurrent(1u)){
        g_status=1u;LogState("HOOK_REPAIRED",0u,0u,0u,g_hookHits,foreign);return;
    }
    g_status=3u;
    if((DWORD)(now-g_lastLostLogTick)>=LOST_LOG_THROTTLE_MS){g_lastLostLogTick=now;LogState("HOOK_LOST_UNSAFE",0u,0u,0u,g_hookHits,foreign);}
}

static void __stdcall Tick(HWND hwnd,UINT msg,UINT_PTR id,DWORD now)
{
    DWORD hits;(void)hwnd;(void)msg;(void)id;
    Watchdog(now);
    if(!g_chatShown){g_chatShown=1u;DebugChat(g_chatScript);}
    hits=g_hookHits;
    if(hits!=g_lastLoggedHits){g_lastLoggedHits=hits;LogState("STEALTH_CD_FORCED",g_lastSpell,g_lastOriginalRecovery,g_lastOriginalCategory,hits,0u);}
}

__declspec(dllexport) DWORD __stdcall StealthCDGuardian_GetVersion(void){return 0x00020000u;}
__declspec(dllexport) DWORD __stdcall StealthCDGuardian_GetStatus(void){return g_status;}
__declspec(dllexport) DWORD __stdcall StealthCDGuardian_GetHookHits(void){return g_hookHits;}
__declspec(dllexport) DWORD __stdcall StealthCDGuardian_GetHookLost(void){return g_hookLost;}
__declspec(dllexport) DWORD __stdcall StealthCDGuardian_GetHookRepairs(void){return g_hookRepairs;}
__declspec(dllexport) DWORD __stdcall StealthCDGuardian_GetForeignChains(void){return g_foreignChains;}

BOOL __stdcall DllMain(HINSTANCE h,DWORD reason,LPVOID reserved)
{
    SetTimer_t st;KillTimer_t kt;(void)h;(void)reserved;
    if(reason==DLL_PROCESS_ATTACH){
        BuildPatch();
        if(!InstallOverCurrent(0u)){g_status=2u;LogState("HOOK_INSTALL_FAILED",0u,0u,0u,0u,0u);return FALSE;}
        g_status=1u;LogState("LOAD_HARD5S_WATCHDOG",0u,0u,0u,0u,g_nextTarget);
        st=ST();if(st)g_timerId=st(0,0,WATCHDOG_MS,Tick);
    }else if(reason==DLL_PROCESS_DETACH){
        kt=KT();if(kt&&g_timerId)kt(0,g_timerId);g_timerId=0u;RemoveHook();g_status=0u;
    }
    return TRUE;
}
