/*
 * WoWMarketWorker_5875_v1.c
 *
 * First milestone for a background Booty Bay AH/mail worker.
 * No movement/teleport/position spoof. The character must physically stand
 * within normal interaction range of both the auctioneer and mailbox.
 *
 * It consumes read-only learned service GUIDs from RemoteServiceProbe, pauses
 * AUX only at a safe query boundary, switches AH -> mailbox -> AH with native
 * object right-click, and verifies that AUX starts scanning again.
 *
 * Commands:
 *   /mw status
 *   /mw on       - keep AH as the worker's home service
 *   /mw off
 *   /mw cycle    - one AH -> MAIL (2.5s hold) -> AH test
 *
 * Calibration: open AH and mailbox normally once in this process so RSP learns
 * the exact live-realm object GUIDs. Future versions may persist worker binding.
 */

#include <windows.h>

#if !defined(_M_IX86) && !defined(__i386__)
#error WoWMarketWorker requires WoW 1.12.1 build 5875 x86
#endif

typedef unsigned char u8;
typedef unsigned int u32;
typedef unsigned long long u64;
typedef int BOOL32;

typedef BOOL32 (__fastcall *FrameScriptExecuteFn)(const char*,const char*);
typedef const char* (__fastcall *FrameScriptGetTextFn)(const char*,int,u32);
typedef u32 (__fastcall *GetObjectByGuidFn)(u64);
typedef void (__thiscall *RightClickObjectFn)(void*,int);
typedef u32 (__stdcall *RspGetGuidFn)(u32,u32*,u32*,u32*,u32*);

#define ADDR_FRAME_EXECUTE      0x00704CD0u
#define ADDR_FRAME_GETTEXT      0x00703BF0u
#define ADDR_GET_OBJECT_GUID    0x00464870u
#define ADDR_RIGHT_CLICK_OBJECT 0x005F8660u
#define OBJMGR_GLOBAL           0x00B41414u
#define OM_LOCAL_GUID_LO        0x000000C0u
#define OM_LOCAL_GUID_HI        0x000000C4u
#define OBJ_TYPE_OFF            0x00000014u

#define SERVICE_MAIL 2u
#define SERVICE_AH   3u
#define TYPE_UNIT    3u
#define TYPE_GO      5u

#define TIMER_MS             50u
#define LUA_RETRY_MS        750u
#define OPEN_RETRY_MS       700u
#define OPEN_TIMEOUT_MS    6000u
#define PAUSE_TIMEOUT_MS  10000u
#define MAIL_HOLD_MS        2500u
#define AUX_RESUME_MS      12000u
#define HOME_RETRY_MS       1800u

#define ST_IDLE          0u
#define ST_WAIT_PAUSE    1u
#define ST_CLOSE_AH      2u
#define ST_OPEN_MAIL     3u
#define ST_HOLD_MAIL     4u
#define ST_CLOSE_MAIL    5u
#define ST_OPEN_AH       6u
#define ST_WAIT_AUX      7u
#define ST_RECOVER_AH    8u

static UINT_PTR g_timer=0;
static u32 g_installed=0u,g_luaReady=0u,g_lastLuaTry=0u,g_lastCmdSeq=0u;
static u32 g_enabled=0u,g_state=ST_IDLE,g_stateAt=0u,g_lastActionAt=0u,g_cycleSeq=0u;
static u32 g_ahLo=0u,g_ahHi=0u,g_mailLo=0u,g_mailHi=0u;
static u32 g_ahLearned=0u,g_mailLearned=0u,g_ahLoaded=0u,g_mailLoaded=0u;
static u32 g_ahType=0u,g_mailType=0u,g_pauseRequested=0u,g_releaseIssued=0u;
static u32 g_auxCyclesBefore=0u,g_failures=0u,g_successes=0u;
static char g_lastFailure[160];
static char g_logPath[MAX_PATH];

static int ptr_ok(u32 p){return p>=0x00010000u&&p<=0x7FFE0000u;}
static u32 rd32(u32 a){return *(volatile u32*)(u32)a;}
static u32 parse_u32(const char*s){u32 v=0u;if(!s)return 0u;while(*s>='0'&&*s<='9'){v=v*10u+(u32)(*s-'0');++s;}return v;}
static void str_copy(char*d,u32 cap,const char*s){u32 i=0u;if(!d||!cap)return;if(!s)s="";while(i+1u<cap&&s[i]){d[i]=s[i];++i;}d[i]=0;}
static void lua_exec(const char*s,const char*tag){((FrameScriptExecuteFn)(u32)ADDR_FRAME_EXECUTE)(s,tag);}
static const char* lua_get(const char*n){return ((FrameScriptGetTextFn)(u32)ADDR_FRAME_GETTEXT)(n,-1,0u);}

static int prepare_log(void){
    char exe[MAX_PATH];DWORD n;int i;
    if(g_logPath[0])return 1;
    n=GetModuleFileNameA(NULL,exe,MAX_PATH);if(!n||n>=MAX_PATH)return 0;
    i=(int)n-1;while(i>=0&&exe[i]!='\\'&&exe[i]!='/')--i;if(i<1)return 0;
    exe[i]=0;if((u32)lstrlenA(exe)+40u>=MAX_PATH)return 0;
    lstrcatA(exe,"\\.wow112_debug");CreateDirectoryA(exe,NULL);
    wsprintfA(g_logPath,"%s\\market_worker_%lu_%lu.jsonl",exe,GetCurrentProcessId(),GetTickCount());
    return 1;
}
static void log_event(const char*ev,const char*detail){
    HANDLE f;DWORD wrote=0u;char line[900],safe[420];u32 i=0u,j=0u;
    if(!prepare_log())return;if(!detail)detail="";
    while(detail[i]&&j+2u<sizeof(safe)){
        char c=detail[i++];if(c=='"'||c=='\\')safe[j++]='\\';
        if(c=='\r'||c=='\n'||c=='\t')c=' ';
        safe[j++]=c;
    }
    safe[j]=0;
    wsprintfA(line,
      "{\"tick\":%lu,\"pid\":%lu,\"event\":\"%s\",\"state\":%lu,\"enabled\":%lu,"
      "\"ah_learned\":%lu,\"mail_learned\":%lu,\"ah_loaded\":%lu,\"mail_loaded\":%lu,"
      "\"cycles_ok\":%lu,\"failures\":%lu,\"detail\":\"%s\"}\r\n",
      GetTickCount(),GetCurrentProcessId(),ev?ev:"",g_state,g_enabled,g_ahLearned,g_mailLearned,
      g_ahLoaded,g_mailLoaded,g_successes,g_failures,safe);
    f=CreateFileA(g_logPath,FILE_APPEND_DATA,FILE_SHARE_READ|FILE_SHARE_WRITE,NULL,OPEN_ALWAYS,FILE_ATTRIBUTE_NORMAL,NULL);
    if(f==INVALID_HANDLE_VALUE)return;WriteFile(f,line,(DWORD)lstrlenA(line),&wrote,NULL);CloseHandle(f);
}
static void chat(const char*msg){
    char esc[420],script[620];u32 i=0u,j=0u;if(!msg)msg="";
    while(msg[i]&&j+2u<sizeof(esc)){char c=msg[i++];if(c=='\\'||c=='\'')esc[j++]='\\';esc[j++]=c;}esc[j]=0;
    wsprintfA(script,"if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage('|cff66ff99[MarketWorker]|r %s') end",esc);
    lua_exec(script,"MarketWorkerChat");
}
static u32 local_player(void){
    u32 mgr=rd32(OBJMGR_GLOBAL),lo,hi;if(!ptr_ok(mgr))return 0u;
    lo=rd32(mgr+OM_LOCAL_GUID_LO);hi=rd32(mgr+OM_LOCAL_GUID_HI);if(!lo&&!hi)return 0u;
    return ((GetObjectByGuidFn)(u32)ADDR_GET_OBJECT_GUID)(((u64)hi<<32)|(u64)lo);
}
static u32 find_object(u32 lo,u32 hi){
    if(!lo&&!hi)return 0u;
    return ((GetObjectByGuidFn)(u32)ADDR_GET_OBJECT_GUID)(((u64)hi<<32)|(u64)lo);
}
static int sig_ok(u32 a,const u8*b,u32 n){u32 i;const volatile u8*p=(const volatile u8*)(u32)a;for(i=0u;i<n;i++)if(p[i]!=b[i])return 0;return 1;}
static int build_guard(void){
    static const u8 scriptSig[]={0x56,0x6A,0x00,0x8B,0xF1,0x52,0x56,0xE8};
    static const u8 objSig[]={0x55,0x8B,0xEC,0x8B,0x45,0x08,0x8B,0x4D,0x0C,0x8B,0xD0,0x0B,0xD1};
    const volatile u8*r=(const volatile u8*)(u32)ADDR_RIGHT_CLICK_OBJECT;
    if(!sig_ok(ADDR_FRAME_EXECUTE,scriptSig,sizeof(scriptSig)))return 0;
    if(!sig_ok(ADDR_GET_OBJECT_GUID,objSig,sizeof(objSig)))return 0;
    if((r[0]==0u&&r[1]==0u)||(r[0]==0xCCu&&r[1]==0xCCu))return 0;
    return 1;
}
static int install_lua(void){
    static const char script[]=
      "if not W112_MW_LUA_READY then "
      "W112_MW_CMDSEQ=0;W112_MW_CMD='';W112_MW_LAST_ERROR='';"
      "local f=CreateFrame('Frame');f:RegisterEvent('UI_ERROR_MESSAGE');"
      "f:SetScript('OnEvent',function() W112_MW_LAST_ERROR=tostring(arg1 or '') end);"
      "SLASH_W112MARKETWORKER1='/mw';SlashCmdList['W112MARKETWORKER']=function(msg) "
      "W112_MW_CMDSEQ=W112_MW_CMDSEQ+1;W112_MW_CMD=string.lower(msg or 'status');end;"
      "W112_MW_LUA_READY=1;"
      "if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage('|cff66ff99[MarketWorker]|r ready: open AH + mailbox once for calibration; /mw status') end "
      "end";
    lua_exec(script,"MarketWorkerInit");
    return parse_u32(lua_get("W112_MW_LUA_READY"))?1:0;
}
static void refresh_context(void){
    static const char s[]=
      "W112_MW_AH_VISIBLE=(AuctionFrame and AuctionFrame:IsVisible()) and 1 or 0;"
      "W112_MW_MAIL_VISIBLE=(MailFrame and MailFrame:IsVisible()) and 1 or 0;"
      "W112_MW_AUX_BUSY=(AUXFAST_IsBusy and AUXFAST_IsBusy()) and 1 or 0;"
      "local st=AUXFAST_ServiceWorkerStatus and AUXFAST_ServiceWorkerStatus() or nil;"
      "W112_MW_AUX_PAUSED=(st and st.paused) and 1 or 0;"
      "W112_MW_AUX_PENDING=(st and st.pending) and 1 or 0;"
      "W112_MW_AUX_CYCLES=(AVM and AVM.auxLoop and tonumber(AVM.auxLoop.cycles)) or 0;"
      "W112_MW_AUX_LOOP=(AVM_DB and AVM_DB.auxLoopEnabled) and 1 or 0";
    lua_exec(s,"MarketWorkerContext");
}
static u32 ah_visible(void){return parse_u32(lua_get("W112_MW_AH_VISIBLE"))?1u:0u;}
static u32 mail_visible(void){return parse_u32(lua_get("W112_MW_MAIL_VISIBLE"))?1u:0u;}
static u32 aux_busy(void){return parse_u32(lua_get("W112_MW_AUX_BUSY"))?1u:0u;}
static u32 aux_paused(void){return parse_u32(lua_get("W112_MW_AUX_PAUSED"))?1u:0u;}
static u32 aux_cycles(void){return parse_u32(lua_get("W112_MW_AUX_CYCLES"));}

static RspGetGuidFn rsp_provider(void){
    HMODULE m=GetModuleHandleA("WoWRemoteServiceProbe_5875_v1.dll");
    RspGetGuidFn f;
    if(!m)return 0;
    f=(RspGetGuidFn)GetProcAddress(m,"W112_RSP_GetLearnedGuid");
    /* Compatibility fallback for an older x86 stdcall-decorated pilot DLL. */
    if(!f)f=(RspGetGuidFn)GetProcAddress(m,"_W112_RSP_GetLearnedGuid@20");
    return f;
}
static void refresh_services(void){
    RspGetGuidFn f=rsp_provider();u32 lo=0u,hi=0u,t=0u,d=0u,obj;
    g_ahLearned=g_mailLearned=0u;g_ahLoaded=g_mailLoaded=0u;g_ahType=g_mailType=0u;
    if(!f)return;
    if(f(SERVICE_AH,&lo,&hi,&t,&d)&&t==TYPE_UNIT){
        g_ahLearned=1u;g_ahLo=lo;g_ahHi=hi;g_ahType=t;obj=find_object(lo,hi);
        if(ptr_ok(obj)&&rd32(obj+OBJ_TYPE_OFF)==TYPE_UNIT)g_ahLoaded=1u;
    }
    lo=hi=t=d=0u;
    if(f(SERVICE_MAIL,&lo,&hi,&t,&d)&&t==TYPE_GO){
        g_mailLearned=1u;g_mailLo=lo;g_mailHi=hi;g_mailType=t;obj=find_object(lo,hi);
        if(ptr_ok(obj)&&rd32(obj+OBJ_TYPE_OFF)==TYPE_GO)g_mailLoaded=1u;
    }
}
static int click_service(u32 service,u32 now){
    u32 lo,hi,obj,type;
    if((u32)(now-g_lastActionAt)<OPEN_RETRY_MS)return 0;
    if(service==SERVICE_AH){lo=g_ahLo;hi=g_ahHi;type=TYPE_UNIT;}
    else {lo=g_mailLo;hi=g_mailHi;type=TYPE_GO;}
    obj=find_object(lo,hi);
    if(!ptr_ok(obj)||rd32(obj+OBJ_TYPE_OFF)!=type)return 0;
    g_lastActionAt=now;
    ((RightClickObjectFn)(u32)ADDR_RIGHT_CLICK_OBJECT)((void*)(u32)obj,0);
    log_event(service==SERVICE_AH?"click_ah":"click_mail","native object right-click");
    return 1;
}
static void request_aux_pause(void){
    static const char s[]=
      "local ok,why=false,'bridge-missing';"
      "if AUXFAST_ServiceWorkerPause then ok,why=AUXFAST_ServiceWorkerPause() end;"
      "W112_MW_PAUSE_OK=ok and 1 or 0;W112_MW_PAUSE_REASON=tostring(why or '')";
    lua_exec(s,"MarketWorkerPause");
    g_pauseRequested=1u;
}
static void release_aux(void){
    static const char s[]=
      "W112_MW_RELEASE_OK=(AUXFAST_ServiceWorkerRelease and AUXFAST_ServiceWorkerRelease()) and 1 or 0";
    lua_exec(s,"MarketWorkerRelease");
    g_releaseIssued=1u;
}
static void close_ah(void){
    lua_exec("if CloseAuctionHouse then CloseAuctionHouse() elseif AuctionFrame then HideUIPanel(AuctionFrame) end","MarketWorkerCloseAH");
}
static void close_mail(void){
    lua_exec("if CloseMail then CloseMail() elseif MailFrame then HideUIPanel(MailFrame) end","MarketWorkerCloseMail");
}
static void set_state(u32 st,u32 now,const char*why){
    g_state=st;g_stateAt=now;g_lastActionAt=0u;
    log_event("state",why?why:"");
}
static void fail_cycle(const char*why,u32 now){
    str_copy(g_lastFailure,sizeof(g_lastFailure),why);++g_failures;
    log_event("cycle_fail",why);chat(why);set_state(ST_RECOVER_AH,now,why);
}
static void start_cycle(u32 now){
    if(g_state!=ST_IDLE){chat("cycle blocked: worker busy");return;}
    refresh_services();refresh_context();
    if(!g_ahLearned||!g_mailLearned){chat("cycle blocked: open AH and mailbox normally once so RSP can learn both GUIDs");return;}
    if(!g_ahLoaded||!g_mailLoaded){chat("cycle blocked: AH or mailbox object is not loaded at worker position");return;}
    ++g_cycleSeq;g_pauseRequested=0u;g_releaseIssued=0u;g_auxCyclesBefore=aux_cycles();g_lastFailure[0]=0;
    set_state(ST_WAIT_PAUSE,now,"cycle start -> wait safe AUX pause");
    request_aux_pause();
}
static void status_chat(void){
    char m[520];
    wsprintfA(m,"enabled=%lu state=%lu AH learned/loaded=%lu/%lu MAIL=%lu/%lu auxBusy=%lu paused=%lu cycles=%lu ok=%lu fail=%lu",
      g_enabled,g_state,g_ahLearned,g_ahLoaded,g_mailLearned,g_mailLoaded,aux_busy(),aux_paused(),aux_cycles(),g_successes,g_failures);
    chat(m);
}
static int cmd_eq(const char*a,const char*b){if(!a||!b)return 0;while(*a&&*b){char x=*a++,y=*b++;if(x>='A'&&x<='Z')x=(char)(x+32);if(y>='A'&&y<='Z')y=(char)(y+32);if(x!=y)return 0;}return *a==0&&*b==0;}
static void handle_command(u32 now){
    u32 seq=parse_u32(lua_get("W112_MW_CMDSEQ"));const char*cmd;
    if(!seq||seq==g_lastCmdSeq)return;g_lastCmdSeq=seq;cmd=lua_get("W112_MW_CMD");
    if(cmd_eq(cmd,"status")||!cmd||!cmd[0]){status_chat();return;}
    if(cmd_eq(cmd,"on")){g_enabled=1u;chat("ON: home service = AH");log_event("enabled","on");return;}
    if(cmd_eq(cmd,"off")){g_enabled=0u;chat("OFF");log_event("enabled","off");return;}
    if(cmd_eq(cmd,"cycle")){start_cycle(now);return;}
    chat("commands: /mw status | on | off | cycle");
}
static void recover_tick(u32 now){
    refresh_context();refresh_services();
    if(mail_visible()){if((u32)(now-g_lastActionAt)>=500u){close_mail();g_lastActionAt=now;}return;}
    if(ah_visible()){
        if(!g_releaseIssued)release_aux();
        set_state(ST_IDLE,now,"recovered AH home");
        return;
    }
    if(g_ahLearned&&g_ahLoaded)click_service(SERVICE_AH,now);
    if((u32)(now-g_stateAt)>OPEN_TIMEOUT_MS+4000u){
        if(!g_releaseIssued)release_aux();
        g_state=ST_IDLE;g_stateAt=now;log_event("recovery_timeout","AH not restored");
    }
}
static void cycle_tick(u32 now){
    refresh_context();refresh_services();
    if(g_state==ST_WAIT_PAUSE){
        if(aux_paused()||(!aux_busy()&&parse_u32(lua_get("W112_MW_PAUSE_OK")))){
            set_state(ST_CLOSE_AH,now,"AUX paused");
            return;
        }
        if((u32)(now-g_stateAt)>PAUSE_TIMEOUT_MS){fail_cycle("cycle FAIL: AUX did not reach safe pause boundary",now);return;}
        if((u32)(now-g_lastActionAt)>1000u){request_aux_pause();g_lastActionAt=now;}
        return;
    }
    if(g_state==ST_CLOSE_AH){
        if(!ah_visible()){set_state(ST_OPEN_MAIL,now,"AH closed -> open mailbox");return;}
        if((u32)(now-g_lastActionAt)>500u){close_ah();g_lastActionAt=now;}
        if((u32)(now-g_stateAt)>3000u){fail_cycle("cycle FAIL: AH would not close",now);return;}
        return;
    }
    if(g_state==ST_OPEN_MAIL){
        if(mail_visible()){set_state(ST_HOLD_MAIL,now,"MAIL_SHOW confirmed");return;}
        click_service(SERVICE_MAIL,now);
        if((u32)(now-g_stateAt)>OPEN_TIMEOUT_MS){fail_cycle("cycle FAIL: mailbox did not open",now);return;}
        return;
    }
    if(g_state==ST_HOLD_MAIL){
        if(!mail_visible()){fail_cycle("cycle FAIL: mailbox closed unexpectedly",now);return;}
        if((u32)(now-g_stateAt)>=MAIL_HOLD_MS){set_state(ST_CLOSE_MAIL,now,"mail hold complete");return;}
        return;
    }
    if(g_state==ST_CLOSE_MAIL){
        if(!mail_visible()){set_state(ST_OPEN_AH,now,"mail closed -> restore AH");return;}
        if((u32)(now-g_lastActionAt)>500u){close_mail();g_lastActionAt=now;}
        if((u32)(now-g_stateAt)>3000u){fail_cycle("cycle FAIL: mailbox would not close",now);return;}
        return;
    }
    if(g_state==ST_OPEN_AH){
        if(ah_visible()){
            release_aux();set_state(ST_WAIT_AUX,now,"AH restored -> release AUX");
            return;
        }
        click_service(SERVICE_AH,now);
        if((u32)(now-g_stateAt)>OPEN_TIMEOUT_MS){fail_cycle("cycle FAIL: auctioneer did not reopen AH",now);return;}
        return;
    }
    if(g_state==ST_WAIT_AUX){
        if(!ah_visible()){fail_cycle("cycle FAIL: AH closed during AUX resume",now);return;}
        if(aux_busy()||aux_cycles()>g_auxCyclesBefore){
            ++g_successes;log_event("cycle_success","AH -> MAIL -> AH and AUX active");
            chat("cycle PASS: AH -> MAIL -> AH, AUX resumed");
            set_state(ST_IDLE,now,"cycle complete");
            return;
        }
        if((u32)(now-g_stateAt)>AUX_RESUME_MS){
            fail_cycle("cycle FAIL: AH restored but AUX did not resume scanning",now);return;
        }
        return;
    }
}
static void home_tick(u32 now){
    if(!g_enabled||g_state!=ST_IDLE)return;
    refresh_context();refresh_services();
    if(mail_visible()){if((u32)(now-g_lastActionAt)>=1000u){close_mail();g_lastActionAt=now;}return;}
    if(!ah_visible()&&g_ahLearned&&g_ahLoaded&&
       (u32)(now-g_lastActionAt)>=HOME_RETRY_MS)click_service(SERVICE_AH,now);
}
static void poll(u32 now){
    if(g_luaReady&&!parse_u32(lua_get("W112_MW_LUA_READY"))){g_luaReady=0u;g_lastCmdSeq=0u;}
    if(!g_luaReady){
        if(!ptr_ok(local_player()))return;
        if((u32)(now-g_lastLuaTry)<LUA_RETRY_MS)return;g_lastLuaTry=now;
        g_luaReady=install_lua()?1u:0u;if(g_luaReady)log_event("lua_ready","slash/context installed");
        return;
    }
    refresh_services();refresh_context();handle_command(now);
    if(g_state==ST_RECOVER_AH){recover_tick(now);return;}
    if(g_state!=ST_IDLE){cycle_tick(now);return;}
    home_tick(now);
}
static VOID CALLBACK timer_proc(HWND h,UINT m,UINT_PTR id,DWORD t){(void)h;(void)m;(void)id;(void)t;if(g_installed)poll(GetTickCount());}

static int install(void){
    if(!prepare_log()||!build_guard()){log_event("install_fail","build guard failed");return 0;}
    g_timer=SetTimer(NULL,0,TIMER_MS,timer_proc);if(!g_timer){log_event("install_fail","SetTimer failed");return 0;}
    g_installed=1u;log_event("installed","no hooks; RSP read-only provider + native service right-click");
    return 1;
}
static void uninstall(int terminating){
    g_installed=0u;if(terminating){g_timer=0;return;}if(g_timer){KillTimer(NULL,g_timer);g_timer=0;}
    if(g_luaReady)lua_exec("if AUXFAST_ServiceWorkerRelease then AUXFAST_ServiceWorkerRelease() end","MarketWorkerUnload");
    log_event("unload","service pause released");
}
BOOL WINAPI DllMain(HINSTANCE h,DWORD reason,LPVOID reserved){
    (void)h;if(reason==DLL_PROCESS_ATTACH){DisableThreadLibraryCalls(h);(void)install();}
    else if(reason==DLL_PROCESS_DETACH)uninstall(reserved!=NULL);return TRUE;
}
