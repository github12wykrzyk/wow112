/*
 * WoWAutoLoginBridge 5875 v1 + SummonScout HOT LUA wrapper.
 * Experimental PARALLEL feature for build 5875 x86.
 *
 * The canonical AutoLoginBridge source remains unchanged and is included below.
 * This wrapper adds two isolated helpers:
 * - hot-Lua watcher with a visible in-game ack after each successful apply,
 * - resilient AutoLogin retry after transient login-server disconnects.
 *
 * The retry path arms only after the normal native AutoLogin has fired once.
 * It never changes the handoff-only CharacterSwitch startup behavior. When the
 * client returns to an idle login screen without reaching the world (or after
 * losing an established world session), it retries the same DPAPI-backed
 * profile. A per-process jitter prevents synchronized multibox retry bursts.
 */
#define DllMain AutoLoginBridge_BaseDllMain
#include "WoWAutoLoginBridge_5875_v1.c"
#undef DllMain

#define HOT_POLL_MS          250u
#define HOT_STABLE_MS        250u
#define HOT_PAYLOAD_CAP      262144u
#define HOT_PATH_CAP         1024u
#define HOT_FILE_COUNT       3u

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

#define RETRY_POLL_MS         250u
#define RETRY_FALLBACK_MS     8000u
#define RETRY_DELAY_MIN_MS    2500u
#define RETRY_DELAY_SPAN_MS   2000u

static const char *g_hot_suffixes[HOT_FILE_COUNT]={
    "Interface\\AddOns\\SummonScout\\SummonScout_PostPaymentOfferHot.lua",
    "Interface\\AddOns\\SummonScout\\SummonScout_WhisperConfirmSpam.lua",
    "Interface\\AddOns\\SummonScout\\SummonScout.lua"
};
static const char *g_hot_source_names[HOT_FILE_COUNT]={
    "SummonScout/SummonScout_PostPaymentOfferHot.lua",
    "SummonScout/SummonScout_WhisperConfirmSpam.lua",
    "SummonScout/SummonScout.lua"
};
static const char *g_hot_ack_scripts[HOT_FILE_COUNT]={
    "W112_HOT_ACK_COUNT=(tonumber(W112_HOT_ACK_COUNT) or 0)+1;local f=DEFAULT_CHAT_FRAME or ChatFrame1;if f and f.AddMessage then f:AddMessage('|cff40ff40[W112 HOT]|r OK #'..tostring(W112_HOT_ACK_COUNT)..' - postpay/AH host') end",
    "W112_HOT_ACK_COUNT=(tonumber(W112_HOT_ACK_COUNT) or 0)+1;local f=DEFAULT_CHAT_FRAME or ChatFrame1;if f and f.AddMessage then f:AddMessage('|cff40ff40[W112 HOT]|r OK #'..tostring(W112_HOT_ACK_COUNT)..' - whisper host') end",
    "W112_HOT_ACK_COUNT=(tonumber(W112_HOT_ACK_COUNT) or 0)+1;local f=DEFAULT_CHAT_FRAME or ChatFrame1;if f and f.AddMessage then f:AddMessage('|cff40ff40[W112 HOT]|r OK #'..tostring(W112_HOT_ACK_COUNT)..' - SummonScout core') end"
};

static UINT_PTR g_hot_timer=0u;
static volatile DWORD g_hot_status=HOT_STATUS_DETACHED;
static volatile DWORD g_hot_generation=0u;
static volatile DWORD g_hot_attempts=0u;
static volatile DWORD g_hot_last_result=0u;
static DWORD g_hot_candidate_hash[HOT_FILE_COUNT];
static DWORD g_hot_candidate_size[HOT_FILE_COUNT];
static DWORD g_hot_candidate_since[HOT_FILE_COUNT];
static DWORD g_hot_last_hash[HOT_FILE_COUNT];
static DWORD g_hot_last_size[HOT_FILE_COUNT];
static int g_hot_have_candidate[HOT_FILE_COUNT];
static int g_hot_have_last[HOT_FILE_COUNT];
static char g_hot_paths[HOT_FILE_COUNT][HOT_PATH_CAP];
static char g_hot_payload[HOT_PAYLOAD_CAP];

static UINT_PTR g_retry_timer=0u;
static volatile DWORD g_retry_attempts=0u;
static int g_retry_armed=0;
static int g_retry_saw_busy=0;
static int g_retry_had_world=0;
static DWORD g_retry_last_attempt=0u;
static DWORD g_retry_next_at=0u;

static DWORD hot_hash(const char *data,DWORD size)
{
    DWORD h=2166136261u,i;
    for(i=0u;i<size;i++) {
        h^=(DWORD)(BYTE)data[i];
        h*=16777619u;
    }
    return h?h:1u;
}

static int hot_build_path(DWORD index)
{
    DWORD n=GetModuleFileNameA(NULL,g_hot_paths[index],HOT_PATH_CAP);
    DWORD i,used;
    const char *suffix=g_hot_suffixes[index];
    if(index>=HOT_FILE_COUNT || n==0u || n>=HOT_PATH_CAP) return 0;
    for(i=n;i>0u;i--) {
        if(g_hot_paths[index][i-1u]=='\\' || g_hot_paths[index][i-1u]=='/') {
            g_hot_paths[index][i]=0;
            break;
        }
    }
    if(i==0u) return 0;
    used=i;
    if(!append_text(g_hot_paths[index],HOT_PATH_CAP,&used,suffix)) return 0;
    return 1;
}

static int hot_build_paths(void)
{
    DWORD i;
    for(i=0u;i<HOT_FILE_COUNT;i++) {
        if(!hot_build_path(i)) return 0;
    }
    return 1;
}

static int hot_world_ready(void)
{
    DWORD mgr=*(volatile DWORD*)(DWORD)WOW_OBJMGR;
    return mgr>=0x00010000u && mgr<=0x7FFE0000u && !(mgr&3u);
}

static DWORD retry_delay_ms(void)
{
    DWORD mix=g_pid ^ GetTickCount() ^ (g_retry_attempts*1103515245u);
    return RETRY_DELAY_MIN_MS + (mix % RETRY_DELAY_SPAN_MS);
}

static VOID retry_reset_glue_state(void)
{
    static const char resetScript[]=
        "if GlueDialog and GlueDialog.Hide then GlueDialog:Hide() end;"
        "W112_AUTOCHAR_FIRST_SELECTED=nil;W112_AUTOCHAR_FIRST_DONE=nil";
    ((FrameScriptExecuteFn)(DWORD)FRAMESCRIPT_EXECUTE)(resetScript,"WoW112AutoLoginRetryReset");
}

static VOID retry_autochar_tick(void)
{
    static const char autoCharScript[]=
        "if CharacterSelectUI and CharacterSelectUI.IsVisible and CharacterSelectUI:IsVisible() "
        "and CharacterSelect and type(GetNumCharacters)=='function' and GetNumCharacters()>0 "
        "and type(CharacterSelect_SelectCharacter)=='function' "
        "and type(CharacterSelect_EnterWorld)=='function' then "
        "if not W112_AUTOCHAR_FIRST_SELECTED then "
        "CharacterSelect_SelectCharacter(1,1);W112_AUTOCHAR_FIRST_SELECTED=true "
        "elseif not W112_AUTOCHAR_FIRST_DONE and CharacterSelect.selectedIndex==1 then "
        "W112_AUTOCHAR_FIRST_DONE=true;CharacterSelect_EnterWorld() end end";
    ((FrameScriptExecuteFn)(DWORD)FRAMESCRIPT_EXECUTE)(autoCharScript,"WoW112AutoLoginRetryAutoChar");
}

static VOID CALLBACK retry_timer_tick(HWND hwnd,UINT msg,UINT_PTR timerId,DWORD now)
{
    int ready;
    (void)hwnd;
    (void)msg;
    (void)timerId;

    if(!guard_ok() || !g_profile_loaded) return;

    /* A handoff-only profile never sets g_done through WM_AUTOLOGIN, so this
       arms only ordinary Multibox AutoLogin sessions after their first attempt. */
    if(!g_retry_armed) {
        if(g_done==1) {
            g_retry_armed=1;
            g_retry_last_attempt=now;
            g_retry_next_at=0u;
            g_retry_saw_busy=0;
            g_retry_had_world=0;
        }
        return;
    }

    if(hot_world_ready()) {
        g_retry_had_world=1;
        g_retry_saw_busy=0;
        g_retry_next_at=0u;
        return;
    }

    /* Do not race the explicit CharacterSwitch relogin request while it owns
       the native login primitive. Once that request is complete, normal retry
       protection can take over again if the server rejects it. */
    if(g_relogin_state==1 || g_relogin_state==2) return;

    if(g_done<0) return;

    if(g_autochar && g_done==1)
        retry_autochar_tick();

    ready=glue_ready();
    if(!ready) {
        g_retry_saw_busy=1;
        g_retry_next_at=0u;
        return;
    }

    if(g_retry_next_at==0u) {
        if(g_retry_had_world || g_retry_saw_busy) {
            g_retry_next_at=now+retry_delay_ms();
        } else if((DWORD)(now-g_retry_last_attempt)>=RETRY_FALLBACK_MS) {
            /* Some immediate "Unable to connect" paths do not expose a useful
               busy transition. Fall back to a bounded timed retry. */
            g_retry_next_at=now+retry_delay_ms();
        }
    }

    if(g_retry_next_at!=0u && (LONG)(now-g_retry_next_at)>=0) {
        retry_reset_glue_state();
        ++g_retry_attempts;
        g_done=native_login()?1:-2;
        g_retry_last_attempt=now;
        g_retry_next_at=0u;
        g_retry_saw_busy=0;
        g_retry_had_world=0;
    }
}

static int hot_read_payload(DWORD index,DWORD *size_out,DWORD *hash_out)
{
    HANDLE h;
    DWORD size,got=0u,hash;
    if(index>=HOT_FILE_COUNT || !size_out || !hash_out || !g_hot_paths[index][0]) return -1;

    h=CreateFileA(
        g_hot_paths[index],
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

static DWORD hot_tick_file(DWORD index,DWORD now)
{
    DWORD size=0u,hash=0u;
    int readResult;
    BOOL ok;

    readResult=hot_read_payload(index,&size,&hash);
    if(readResult==0) {
        g_hot_have_candidate[index]=0;
        return HOT_STATUS_FILE_MISSING;
    }
    if(readResult==-2) {
        g_hot_have_candidate[index]=0;
        return HOT_STATUS_TOO_LARGE;
    }
    if(readResult<0) {
        g_hot_have_candidate[index]=0;
        return HOT_STATUS_READ_FAILED;
    }

    /* Cold seed: files already loaded by the TOC establish the baseline only.
       The watcher executes Lua only after a real on-disk change from this hash. */
    if(!g_hot_have_last[index]) {
        g_hot_last_hash[index]=hash;
        g_hot_last_size[index]=size;
        g_hot_have_last[index]=1;
        g_hot_have_candidate[index]=0;
        return HOT_STATUS_WATCHING;
    }

    if(hash==g_hot_last_hash[index] &&
       size==g_hot_last_size[index]) {
        g_hot_have_candidate[index]=0;
        return HOT_STATUS_WATCHING;
    }

    if(!g_hot_have_candidate[index] ||
       hash!=g_hot_candidate_hash[index] ||
       size!=g_hot_candidate_size[index]) {
        g_hot_candidate_hash[index]=hash;
        g_hot_candidate_size[index]=size;
        g_hot_candidate_since[index]=now;
        g_hot_have_candidate[index]=1;
        return HOT_STATUS_WATCHING;
    }

    if((DWORD)(now-g_hot_candidate_since[index])<HOT_STABLE_MS)
        return HOT_STATUS_WATCHING;

    ++g_hot_attempts;
    ok=((FrameScriptExecuteFn)(DWORD)FRAMESCRIPT_EXECUTE)(
        g_hot_payload,
        g_hot_source_names[index]
    );
    g_hot_last_hash[index]=hash;
    g_hot_last_size[index]=size;
    g_hot_have_last[index]=1;
    g_hot_have_candidate[index]=0;
    g_hot_last_result=ok?1u:0u;
    if(ok) {
        ++g_hot_generation;
        ((FrameScriptExecuteFn)(DWORD)FRAMESCRIPT_EXECUTE)(
            g_hot_ack_scripts[index],
            "WoW112HotApplyAck"
        );
        return HOT_STATUS_APPLIED;
    }
    return HOT_STATUS_EXEC_FAILED;
}

static VOID CALLBACK hot_timer_tick(HWND hwnd,UINT msg,UINT_PTR timerId,DWORD now)
{
    DWORD i,status,aggregate=HOT_STATUS_WATCHING;
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

    for(i=0u;i<HOT_FILE_COUNT;i++) {
        status=hot_tick_file(i,now);
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
    DWORD i;

    if(reason==DLL_PROCESS_ATTACH) {
        g_hot_timer=0u;
        g_hot_status=HOT_STATUS_DETACHED;
        g_hot_generation=0u;
        g_hot_attempts=0u;
        g_hot_last_result=0u;
        g_hot_payload[0]=0;
        for(i=0u;i<HOT_FILE_COUNT;i++) {
            g_hot_candidate_hash[i]=0u;
            g_hot_candidate_size[i]=0u;
            g_hot_candidate_since[i]=0u;
            g_hot_last_hash[i]=0u;
            g_hot_last_size[i]=0u;
            g_hot_have_candidate[i]=0;
            g_hot_have_last[i]=0;
            g_hot_paths[i][0]=0;
        }

        g_retry_timer=0u;
        g_retry_attempts=0u;
        g_retry_armed=0;
        g_retry_saw_busy=0;
        g_retry_had_world=0;
        g_retry_last_attempt=0u;
        g_retry_next_at=0u;

        baseResult=AutoLoginBridge_BaseDllMain(module,reason,reserved);
        if(!baseResult) return FALSE;
        if(!hot_build_paths()) {
            g_hot_status=HOT_STATUS_PATH_FAILED;
        } else {
            g_hot_timer=SetTimer(NULL,0u,HOT_POLL_MS,hot_timer_tick);
            g_hot_status=g_hot_timer?HOT_STATUS_WAIT_WORLD:HOT_STATUS_PATH_FAILED;
        }
        g_retry_timer=SetTimer(NULL,0u,RETRY_POLL_MS,retry_timer_tick);
        return TRUE;
    }

    if(reason==DLL_PROCESS_DETACH) {
        if(g_retry_timer) KillTimer(NULL,g_retry_timer);
        g_retry_timer=0u;
        if(g_hot_timer) KillTimer(NULL,g_hot_timer);
        g_hot_timer=0u;
        g_hot_status=HOT_STATUS_DETACHED;
        wipe(g_hot_payload,HOT_PAYLOAD_CAP);
        for(i=0u;i<HOT_FILE_COUNT;i++)
            wipe(g_hot_paths[i],HOT_PATH_CAP);
        return AutoLoginBridge_BaseDllMain(module,reason,reserved);
    }

    return AutoLoginBridge_BaseDllMain(module,reason,reserved);
}
