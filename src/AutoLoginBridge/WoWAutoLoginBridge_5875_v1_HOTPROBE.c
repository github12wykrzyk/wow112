/*
 * WoWAutoLoginBridge 5875 v1 + SummonScout FULL HOT LUA wrapper.
 * PARALLEL feature for WoW 1.12.1 build 5875 x86.
 *
 * The canonical AutoLoginBridge source remains unchanged and is included below.
 * This wrapper watches every active SummonScout logic file that is safe to
 * replace live.  Each file is debounced for 250 ms and executed through the
 * already-proven FrameScript_Execute 0x00704CD0 primitive from a Win32 timer
 * callback on the client UI/message thread.
 *
 * The first observed bytes are seeded as the cold-load baseline and are NOT
 * executed again.  Only later content changes are executed.  This prevents
 * duplicate startup side effects while still allowing updates made at the
 * login/character screens to be applied once the world is ready.
 */
#define DllMain AutoLoginBridge_BaseDllMain
#include "WoWAutoLoginBridge_5875_v1.c"
#undef DllMain

#define HOT_POLL_MS          250u
#define HOT_STABLE_MS        250u
#define HOT_PAYLOAD_CAP      262144u
#define HOT_PATH_CAP         1024u
#define HOT_WATCH_COUNT      3u

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

typedef struct HotWatch {
    const char *suffix;
    const char *chunk;
    char path[HOT_PATH_CAP];
    DWORD candidate_hash;
    DWORD candidate_size;
    DWORD candidate_since;
    DWORD last_hash;
    DWORD last_size;
    DWORD generation;
    DWORD attempts;
    DWORD last_result;
    DWORD status;
    int have_candidate;
    int have_last;
} HotWatch;

static HotWatch g_hot_watch[HOT_WATCH_COUNT]={
    {"Interface\\AddOns\\SummonScout\\SummonScout.lua","SummonScout/SummonScout.lua"},
    {"Interface\\AddOns\\SummonScout\\SummonScout_WhisperConfirmSpam.lua","SummonScout/SummonScout_WhisperConfirmSpam.lua"},
    {"Interface\\AddOns\\SummonScout\\SummonScout_PostPaymentOfferHot.lua","SummonScout/SummonScout_PostPaymentOfferHot.lua"}
};

static UINT_PTR g_hot_timer=0u;
static volatile DWORD g_hot_status=HOT_STATUS_DETACHED;
static volatile DWORD g_hot_generation=0u;
static volatile DWORD g_hot_attempts=0u;
static volatile DWORD g_hot_last_result=0u;
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

static void hot_reset_watch(HotWatch *w)
{
    if(!w) return;
    w->path[0]=0;
    w->candidate_hash=0u;
    w->candidate_size=0u;
    w->candidate_since=0u;
    w->last_hash=0u;
    w->last_size=0u;
    w->generation=0u;
    w->attempts=0u;
    w->last_result=0u;
    w->status=HOT_STATUS_DETACHED;
    w->have_candidate=0;
    w->have_last=0;
}

static int hot_build_path(HotWatch *w)
{
    DWORD n,i,used;
    if(!w || !w->suffix) return 0;
    n=GetModuleFileNameA(NULL,w->path,HOT_PATH_CAP);
    if(n==0u || n>=HOT_PATH_CAP) return 0;
    for(i=n;i>0u;i--) {
        if(w->path[i-1u]=='\\' || w->path[i-1u]=='/') {
            w->path[i]=0;
            break;
        }
    }
    if(i==0u) return 0;
    used=i;
    if(!append_text(w->path,HOT_PATH_CAP,&used,w->suffix)) return 0;
    return 1;
}

static int hot_build_paths(void)
{
    DWORD i;
    for(i=0u;i<HOT_WATCH_COUNT;i++) {
        hot_reset_watch(&g_hot_watch[i]);
        if(!hot_build_path(&g_hot_watch[i])) return 0;
    }
    return 1;
}

static int hot_world_ready(void)
{
    DWORD mgr=*(volatile DWORD*)(DWORD)WOW_OBJMGR;
    return mgr>=0x00010000u && mgr<=0x7FFE0000u && !(mgr&3u);
}

static int hot_read_payload(HotWatch *w,DWORD *size_out,DWORD *hash_out)
{
    HANDLE h;
    DWORD size,got=0u,hash;
    if(!w || !size_out || !hash_out || !w->path[0]) return -1;

    h=CreateFileA(
        w->path,
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

static DWORD hot_tick_watch(HotWatch *w,DWORD now,int worldReady)
{
    DWORD size=0u,hash=0u;
    int readResult;
    BOOL ok;

    readResult=hot_read_payload(w,&size,&hash);
    if(readResult==0) {
        w->status=HOT_STATUS_FILE_MISSING;
        w->have_candidate=0;
        return w->status;
    }
    if(readResult==-2) {
        w->status=HOT_STATUS_TOO_LARGE;
        w->have_candidate=0;
        return w->status;
    }
    if(readResult<0) {
        w->status=HOT_STATUS_READ_FAILED;
        w->have_candidate=0;
        return w->status;
    }

    /* Seed the cold-load bytes without executing them a second time. */
    if(!w->have_last) {
        w->last_hash=hash;
        w->last_size=size;
        w->have_last=1;
        w->have_candidate=0;
        w->status=worldReady?HOT_STATUS_WATCHING:HOT_STATUS_WAIT_WORLD;
        return w->status;
    }

    if(hash==w->last_hash && size==w->last_size) {
        w->status=worldReady?HOT_STATUS_WATCHING:HOT_STATUS_WAIT_WORLD;
        w->have_candidate=0;
        return w->status;
    }

    if(!w->have_candidate ||
       hash!=w->candidate_hash ||
       size!=w->candidate_size) {
        w->candidate_hash=hash;
        w->candidate_size=size;
        w->candidate_since=now;
        w->have_candidate=1;
        w->status=worldReady?HOT_STATUS_WATCHING:HOT_STATUS_WAIT_WORLD;
        return w->status;
    }

    if((DWORD)(now-w->candidate_since)<HOT_STABLE_MS) {
        w->status=worldReady?HOT_STATUS_WATCHING:HOT_STATUS_WAIT_WORLD;
        return w->status;
    }

    /* Keep the changed candidate armed until entering the world. */
    if(!worldReady) {
        w->status=HOT_STATUS_WAIT_WORLD;
        return w->status;
    }

    ++w->attempts;
    ++g_hot_attempts;
    ok=((FrameScriptExecuteFn)(DWORD)FRAMESCRIPT_EXECUTE)(g_hot_payload,w->chunk);
    w->last_result=ok?1u:0u;
    g_hot_last_result=w->last_result;
    if(ok) {
        w->last_hash=hash;
        w->last_size=size;
        w->have_last=1;
        w->have_candidate=0;
        ++w->generation;
        ++g_hot_generation;
        w->status=HOT_STATUS_APPLIED;
    } else {
        /* Do not accept failed bytes; a corrected file may be retried. */
        w->have_candidate=0;
        w->status=HOT_STATUS_EXEC_FAILED;
    }
    return w->status;
}

static VOID CALLBACK hot_timer_tick(HWND hwnd,UINT msg,UINT_PTR timerId,DWORD now)
{
    DWORD i,status,aggregate;
    int worldReady;
    (void)hwnd;
    (void)msg;
    (void)timerId;

    if(!guard_ok()) {
        g_hot_status=HOT_STATUS_BUILD_MISMATCH;
        return;
    }

    worldReady=hot_world_ready();
    aggregate=worldReady?HOT_STATUS_WATCHING:HOT_STATUS_WAIT_WORLD;
    for(i=0u;i<HOT_WATCH_COUNT;i++) {
        status=hot_tick_watch(&g_hot_watch[i],now,worldReady);
        if(status==HOT_STATUS_APPLIED) {
            aggregate=HOT_STATUS_APPLIED;
        } else if(status>=HOT_STATUS_FILE_MISSING && aggregate!=HOT_STATUS_APPLIED) {
            aggregate=status;
        }
    }
    g_hot_status=aggregate;
}

#if defined(_MSC_VER)
#pragma comment(linker, "/EXPORT:W112_HotLuaProbe_GetGeneration=_W112_HotLuaProbe_GetGeneration@0")
#pragma comment(linker, "/EXPORT:W112_HotLuaProbe_GetStatus=_W112_HotLuaProbe_GetStatus@0")
#pragma comment(linker, "/EXPORT:W112_HotLuaProbe_GetAttempts=_W112_HotLuaProbe_GetAttempts@0")
#pragma comment(linker, "/EXPORT:W112_HotLuaProbe_GetLastResult=_W112_HotLuaProbe_GetLastResult@0")
#pragma comment(linker, "/EXPORT:W112_HotLuaProbe_GetWatchCount=_W112_HotLuaProbe_GetWatchCount@0")
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

__declspec(dllexport) DWORD __stdcall W112_HotLuaProbe_GetWatchCount(void)
{
    return HOT_WATCH_COUNT;
}

BOOL WINAPI DllMain(HMODULE module,DWORD reason,LPVOID reserved)
{
    BOOL baseResult;
    DWORD i;

    if(reason==DLL_PROCESS_ATTACH) {
        g_hot_timer=0u;
        g_hot_status=HOT_STATUS_DETACHED;
        g_hot_generation=0u;
        g_hot_attempts=0u;
        g_hot_last_result=0u;
        g_hot_payload[0]=0;

        baseResult=AutoLoginBridge_BaseDllMain(module,reason,reserved);
        if(!baseResult) return FALSE;
        if(!hot_build_paths()) {
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
        for(i=0u;i<HOT_WATCH_COUNT;i++) {
            wipe(g_hot_watch[i].path,HOT_PATH_CAP);
            g_hot_watch[i].status=HOT_STATUS_DETACHED;
        }
        return AutoLoginBridge_BaseDllMain(module,reason,reserved);
    }

    return AutoLoginBridge_BaseDllMain(module,reason,reserved);
}
