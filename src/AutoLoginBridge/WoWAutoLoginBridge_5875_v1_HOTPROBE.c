/*
 * WoWAutoLoginBridge 5875 v1 + SummonScout HOT LUA wrapper.
 * Experimental PARALLEL feature for build 5875 x86.
 *
 * The canonical AutoLoginBridge source remains unchanged and is included below.
 * This wrapper adds one isolated hot-Lua watcher:
 * - polls Interface\AddOns\SummonScout\SummonScout_PostPaymentOfferHot.lua every 250 ms,
 * - requires the payload bytes to remain unchanged for >=250 ms,
 * - executes a changed payload through the already-proven
 *   FrameScript_Execute 0x00704CD0 primitive,
 * - runs the execution from a Win32 SetTimer callback, matching the
 *   main-thread pattern already used by AutoSummonAssist.
 */
#define DllMain AutoLoginBridge_BaseDllMain
#include "WoWAutoLoginBridge_5875_v1.c"
#undef DllMain

#define HOT_POLL_MS          250u
#define HOT_STABLE_MS        250u
#define HOT_PAYLOAD_CAP      65536u
#define HOT_PATH_CAP         1024u

#define HOT_STATUS_DETACHED       0u
#define HOT_STATUS_WAIT_WORLD     1u
#define HOT_STATUS_WATCHING       2u
#define HOT_STATUS_APPLIED        3u
#define HOT_STATUS_FILE_MISSING   4u
#define HOT_STATUS_READ_FAILED    5u
#define HOT_STATUS_BUILD_MISMATCH 6u
#define HOT_STATUS_EXEC_FAILED    7u
#define HOT_STATUS_TOO_LARGE      8u
#define HOT_STATUS_PATH_FAILED    9u

static UINT_PTR g_hot_timer=0u;
static volatile DWORD g_hot_status=HOT_STATUS_DETACHED;
static volatile DWORD g_hot_generation=0u;
static volatile DWORD g_hot_attempts=0u;
static volatile DWORD g_hot_last_result=0u;
static DWORD g_hot_candidate_hash=0u;
static DWORD g_hot_candidate_size=0u;
static DWORD g_hot_candidate_since=0u;
static DWORD g_hot_last_hash=0u;
static DWORD g_hot_last_size=0u;
static int g_hot_have_candidate=0;
static int g_hot_have_last=0;
static char g_hot_path[HOT_PATH_CAP];
static char g_hot_payload[HOT_PAYLOAD_CAP];

static DWORD hot_hash(const char *data,DWORD size)
{
    DWORD h=2166136261u,i;
    for(i=0u;i<size;i++) {
        h^=(DWORD)(BYTE)data[i];
        h*=16777619u;
    }
    return h?h:1u;
}

static int hot_build_path(void)
{
    DWORD n=GetModuleFileNameA(NULL,g_hot_path,HOT_PATH_CAP);
    DWORD i,used;
    static const char suffix[]="Interface\\AddOns\\SummonScout\\SummonScout_PostPaymentOfferHot.lua";
    if(n==0u || n>=HOT_PATH_CAP) return 0;
    for(i=n;i>0u;i--) {
        if(g_hot_path[i-1u]=='\\' || g_hot_path[i-1u]=='/') {
            g_hot_path[i]=0;
            break;
        }
    }
    if(i==0u) return 0;
    used=i;
    if(!append_text(g_hot_path,HOT_PATH_CAP,&used,suffix)) return 0;
    return 1;
}

static int hot_world_ready(void)
{
    DWORD mgr=*(volatile DWORD*)(DWORD)WOW_OBJMGR;
    return mgr>=0x00010000u && mgr<=0x7FFE0000u && !(mgr&3u);
}

static int hot_read_payload(DWORD *size_out,DWORD *hash_out)
{
    HANDLE h;
    DWORD size,got=0u,hash;
    if(!size_out || !hash_out || !g_hot_path[0]) return -1;

    h=CreateFileA(
        g_hot_path,
        GENERIC_READ,
        FILE_SHARE_READ|FILE_SHARE_WRITE|FILE_SHARE_DELETE,
        NULL,
        OPEN_EXISTING,
        FILE_ATTRIBUTE_NORMAL,
        NULL
    );
    if(h==INVALID_HANDLE_VALUE) return 0;

    size=GetFileSize(h,NULL);
    if(size==INVALID_FILE_SIZE || size==0u) {
        CloseHandle(h);
        return -1;
    }
    if(size>=HOT_PAYLOAD_CAP) {
        CloseHandle(h);
        return -2;
    }
    if(!ReadFile(h,g_hot_payload,size,&got,NULL) || got!=size) {
        CloseHandle(h);
        return -1;
    }
    CloseHandle(h);

    g_hot_payload[size]=0;
    hash=hot_hash(g_hot_payload,size);
    *size_out=size;
    *hash_out=hash;
    return 1;
}

static VOID CALLBACK hot_timer_tick(HWND hwnd,UINT msg,UINT_PTR timerId,DWORD now)
{
    DWORD size=0u,hash=0u;
    int readResult;
    BOOL ok;
    (void)hwnd;
    (void)msg;
    (void)timerId;

    if(!guard_ok()) {
        g_hot_status=HOT_STATUS_BUILD_MISMATCH;
        return;
    }
    if(!hot_world_ready()) {
        g_hot_status=HOT_STATUS_WAIT_WORLD;
        return;
    }

    readResult=hot_read_payload(&size,&hash);
    if(readResult==0) {
        g_hot_status=HOT_STATUS_FILE_MISSING;
        g_hot_have_candidate=0;
        return;
    }
    if(readResult==-2) {
        g_hot_status=HOT_STATUS_TOO_LARGE;
        g_hot_have_candidate=0;
        return;
    }
    if(readResult<0) {
        g_hot_status=HOT_STATUS_READ_FAILED;
        g_hot_have_candidate=0;
        return;
    }

    if(g_hot_have_last && hash==g_hot_last_hash && size==g_hot_last_size) {
        g_hot_status=HOT_STATUS_WATCHING;
        g_hot_have_candidate=0;
        return;
    }

    if(!g_hot_have_candidate ||
       hash!=g_hot_candidate_hash ||
       size!=g_hot_candidate_size) {
        g_hot_candidate_hash=hash;
        g_hot_candidate_size=size;
        g_hot_candidate_since=now;
        g_hot_have_candidate=1;
        g_hot_status=HOT_STATUS_WATCHING;
        return;
    }

    if((DWORD)(now-g_hot_candidate_since)<HOT_STABLE_MS) {
        g_hot_status=HOT_STATUS_WATCHING;
        return;
    }

    ++g_hot_attempts;
    ok=((FrameScriptExecuteFn)(DWORD)FRAMESCRIPT_EXECUTE)(
        g_hot_payload,
        "SummonScout/SummonScout_PostPaymentOfferHot.lua"
    );
    g_hot_last_hash=hash;
    g_hot_last_size=size;
    g_hot_have_last=1;
    g_hot_have_candidate=0;
    g_hot_last_result=ok?1u:0u;
    if(ok) {
        ++g_hot_generation;
        g_hot_status=HOT_STATUS_APPLIED;
    } else {
        g_hot_status=HOT_STATUS_EXEC_FAILED;
    }
}

#if defined(_MSC_VER)
#pragma comment(linker, "/EXPORT:W112_HotLuaProbe_GetGeneration=_W112_HotLuaProbe_GetGeneration@0")
#pragma comment(linker, "/EXPORT:W112_HotLuaProbe_GetStatus=_W112_HotLuaProbe_GetStatus@0")
#pragma comment(linker, "/EXPORT:W112_HotLuaProbe_GetAttempts=_W112_HotLuaProbe_GetAttempts@0")
#pragma comment(linker, "/EXPORT:W112_HotLuaProbe_GetLastResult=_W112_HotLuaProbe_GetLastResult@0")
#endif

__declspec(dllexport) DWORD __stdcall W112_HotLuaProbe_GetGeneration(void)
{
    return g_hot_generation;
}

__declspec(dllexport) DWORD __stdcall W112_HotLuaProbe_GetStatus(void)
{
    return g_hot_status;
}

__declspec(dllexport) DWORD __stdcall W112_HotLuaProbe_GetAttempts(void)
{
    return g_hot_attempts;
}

__declspec(dllexport) DWORD __stdcall W112_HotLuaProbe_GetLastResult(void)
{
    return g_hot_last_result;
}

BOOL WINAPI DllMain(HMODULE module,DWORD reason,LPVOID reserved)
{
    BOOL baseResult;

    if(reason==DLL_PROCESS_ATTACH) {
        g_hot_timer=0u;
        g_hot_status=HOT_STATUS_DETACHED;
        g_hot_generation=0u;
        g_hot_attempts=0u;
        g_hot_last_result=0u;
        g_hot_have_candidate=0;
        g_hot_have_last=0;
        g_hot_path[0]=0;
        g_hot_payload[0]=0;

        baseResult=AutoLoginBridge_BaseDllMain(module,reason,reserved);
        if(!baseResult) return FALSE;
        if(!hot_build_path()) {
            g_hot_status=HOT_STATUS_PATH_FAILED;
            return TRUE;
        }
        g_hot_timer=SetTimer(NULL,0u,HOT_POLL_MS,hot_timer_tick);
        g_hot_status=g_hot_timer?HOT_STATUS_WAIT_WORLD:HOT_STATUS_PATH_FAILED;
        return TRUE;
    }

    if(reason==DLL_PROCESS_DETACH) {
        if(g_hot_timer) KillTimer(NULL,g_hot_timer);
        g_hot_timer=0u;
        g_hot_status=HOT_STATUS_DETACHED;
        wipe(g_hot_payload,HOT_PAYLOAD_CAP);
        wipe(g_hot_path,HOT_PATH_CAP);
        return AutoLoginBridge_BaseDllMain(module,reason,reserved);
    }

    return AutoLoginBridge_BaseDllMain(module,reason,reserved);
}
