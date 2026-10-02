/*
 * WoWCharacterSwitchDiag 5875 v12 - direct world reconnect + Glue char-list recovery.
 *
 * Coordinator FAST switch is both instant-oriented and login-server independent:
 *   world Disconnect -> preserve LoginData/session key -> ConnectToSelectedServer
 *   -> Character Select -> target slot -> EnterWorld.
 *
 * It does NOT send the normal delayed Logout request and does NOT invoke
 * AutoLoginBridge relogin/SRP. The existing 40-byte world session key stays in
 * NetClient LoginData and is reused by the normal 5875 CMSG_AUTH_SESSION path.
 *
 * Report #78 proved the transport half works: both workers disconnect instantly,
 * the 40-byte session key survives and ConnectToSelectedServer starts, but Glue
 * never enters Character Select by itself. V12 explicitly restores the Glue
 * char-select screen and requests a fresh character list after world reconnect.
 *
 * Fail closed: exact-build byte guards, NetClient state checks and an internal
 * session-key fingerprint must all match. There is no auth-server fallback.
 */
#if !defined(_M_IX86) && !defined(__i386__)
#error WoWCharacterSwitchDiag requires x86.
#endif
#include <windows.h>
#include "../common/W112ControlAPI.h"

#define WOW_OBJMGR              0x00B41414u
#define WOW_FRAMESCRIPT_GETTEXT 0x00703BF0u
#define WOW_FRAMESCRIPT_EXECUTE 0x00704CD0u
#define WOW_CLIENTSERVICES_GET  0x005AB490u
#define WOW_CLIENTSERVICES_DISC 0x005AB1A0u
#define WOW_CONNECT_SELECTED    0x005AB800u
#define WOW_NET_CONNECT         0x00537820u
#define NET_STATE_OFFSET        0x00000070u
#define SESSION_KEY_OFFSET      0x00000048u
#define SESSION_KEY_SIZE        40u
#define NET_STATE_INITIALIZED   2u
#define NET_STATE_CONNECTED     6u
#define TIMER_MS 50u
#define UI_REFRESH_MS 250u
#define SELECT_SETTLE_MS 350u
#define ENTER_TIMEOUT_MS 30000u
#define FAST_DISCONNECT_TIMEOUT_MS 7000u
#define FAST_RECONNECT_TIMEOUT_MS 35000u
#define FAST_AUTH_SETTLE_MS 1200u
#define FAST_CHARLIST_RETRY_MS 2000u
#define FAST_CHARLIST_MAX_ATTEMPTS 8u
#define FAST_CONNECT_RETRY_MS 1000u
#define FAST_CONNECT_MAX_ATTEMPTS 3u
#define COMBAT_POLL_MS 250u
#define WORKER_MAGIC 0x53323157u
#define WORKER_VERSION 2u
#define WORKER_COMMAND_RELOAD 0xFFFFFFFEu

enum {
    WORKER_INIT=0, WORKER_IDLE=1, WORKER_COMBAT_BLOCKED=2, WORKER_SWITCHING=3,
    WORKER_READY=4, WORKER_FAILED=5, WORKER_BUSY=6, WORKER_WAIT_WORLD=7,
    WORKER_OFFLINE=8
};

typedef struct WorkerMapV1 {
    DWORD magic;
    DWORD version;
    DWORD pid;
    volatile DWORD heartbeat_tick;
    volatile DWORD command_seq;
    volatile DWORD command_slot;
    volatile DWORD ack_seq;
    volatile DWORD state;
    volatile DWORD phase;
    volatile DWORD target_slot;
    volatile DWORD in_world;
    volatile DWORD combat;
    volatile DWORD error;
    volatile DWORD elapsed_ms;
    volatile DWORD current_slot;
    volatile DWORD last_event_tick;
} WorkerMapV1;

typedef BOOL (__fastcall *FrameScriptExecuteFn)(const char*,const char*);
typedef const char* (__fastcall *FrameScriptGetTextFn)(const char*,int,DWORD);
typedef void* (__cdecl *GetClientServicesFn)(void);
typedef int (__thiscall *ClientServicesDisconnectFn)(void*);
typedef void (__cdecl *ConnectToSelectedServerFn)(void);

enum {
    PHASE_IDLE=0, PHASE_WAIT_LOGOUT=1, PHASE_CHAR_SELECT=2, PHASE_ENTERING=3,
    PHASE_COMPLETE=4, PHASE_FAILED=5, PHASE_FAST_DISCONNECT=6,
    PHASE_FAST_RECONNECT=7
};

static volatile DWORD g_phase=PHASE_IDLE,g_targetSlot=0,g_elapsedToGlue=0,g_elapsedTotal=0;
static volatile DWORD g_lastError=0,g_world=0,g_glueVisible=0,g_fast=0;
static volatile DWORD g_reloadInProgress=0;
static UINT_PTR g_timer=0;
static DWORD g_startedAt=0,g_glueAt=0,g_enterIssuedAt=0,g_lastUiRefresh=0,g_lastWorld=0;
static DWORD g_fastConnection=0,g_sessionHash1=0,g_sessionHash2=0,g_fastConnectAt=0;
static DWORD g_fastConnectedAt=0,g_charListKickAt=0,g_fastLastNetState=0xFFFFFFFFu;
static DWORD g_charListAttempts=0,g_fastConnectAttempts=0;
static HANDLE g_workerMapHandle=0;
static WorkerMapV1 *g_workerMap=0;
static DWORD g_workerSeenSeq=0,g_workerState=WORKER_INIT,g_workerLastState=0xFFFFFFFFu;
static DWORD g_currentSlot=0,g_combat=0,g_lastCombatProbe=0;
static W112_ControlSettingV1 g_settings[7];
static DWORD g_descReady=0;
int _fltused=0;

static DWORD rd32(DWORD a){return *(volatile DWORD*)a;}
static int ptr_ok(DWORD p){return p>=0x00010000u&&p<=0x7FFE0000u&&!(p&3u);}
static int bytes_equal(DWORD addr,const BYTE*sig,DWORD n){DWORD i;const BYTE*p=(const BYTE*)addr;if(!p||!sig||!n)return 0;for(i=0;i<n;i++)if(p[i]!=sig[i])return 0;return 1;}
static DWORD key_hash1(const BYTE*p){DWORD i,h=2166136261u;for(i=0;i<SESSION_KEY_SIZE;i++){h^=p[i];h*=16777619u;}return h?h:1u;}
static DWORD key_hash2(const BYTE*p){DWORD i,h=5381u;for(i=0;i<SESSION_KEY_SIZE;i++)h=((h<<5)+h)^(DWORD)p[i];return h?h:1u;}
static int key_nonzero(const BYTE*p){DWORD i;for(i=0;i<SESSION_KEY_SIZE;i++)if(p[i])return 1;return 0;}
static char *app(char*p,const char*s){while(s&&*s)*p++=*s++;return p;}
static char *appu(char*p,DWORD v){char t[16];int n=0;if(!v){*p++='0';return p;}while(v&&n<15){t[n++]=(char)('0'+v%10);v/=10;}while(n)*p++=t[--n];return p;}
static int eq(const char*a,const char*b){if(!a||!b)return 0;while(*a&&*b){if(*a++!=*b++)return 0;}return *a==0&&*b==0;}

static void worker_log_event(const char*event,DWORD now)
{
    HANDLE h;DWORD wr=0,pid=GetCurrentProcessId();char name[96],b[512],*p=name,*q=b;
    p=app(p,"SummonWorker_");p=appu(p,pid);p=app(p,".log");*p=0;
    q=app(q,event);q=app(q," tick=");q=appu(q,now);
    q=app(q," request_id=");q=appu(q,g_workerMap?g_workerMap->command_seq:0);
    q=app(q," ack=");q=appu(q,g_workerMap?g_workerMap->ack_seq:0);
    q=app(q," slot=");q=appu(q,g_workerMap?g_workerMap->command_slot:0);
    q=app(q," state=");q=appu(q,g_workerState);
    q=app(q," phase=");q=appu(q,g_phase);
    q=app(q," world=");q=appu(q,g_world);
    q=app(q," combat=");q=appu(q,g_combat);
    q=app(q," err=");q=appu(q,g_lastError);
    q=app(q," elapsed_ms=");q=appu(q,g_startedAt?now-g_startedAt:g_elapsedTotal);
    q=app(q,"\r\n");*q=0;
    h=CreateFileA(name,GENERIC_WRITE,FILE_SHARE_READ|FILE_SHARE_WRITE,NULL,OPEN_ALWAYS,FILE_ATTRIBUTE_NORMAL,NULL);
    if(h==INVALID_HANDLE_VALUE)return;
    SetFilePointer(h,0,NULL,FILE_END);WriteFile(h,b,(DWORD)(q-b),&wr,NULL);CloseHandle(h);
}

static void init_worker_map(void)
{
    char name[96],*p=name;DWORD pid=GetCurrentProcessId();
    p=app(p,"Local\\WoW112_SummonWorker_");p=appu(p,pid);*p=0;
    g_workerMapHandle=CreateFileMappingA(INVALID_HANDLE_VALUE,NULL,PAGE_READWRITE,0,sizeof(WorkerMapV1),name);
    if(!g_workerMapHandle)return;
    g_workerMap=(WorkerMapV1*)MapViewOfFile(g_workerMapHandle,FILE_MAP_ALL_ACCESS,0,0,sizeof(WorkerMapV1));
    if(!g_workerMap){CloseHandle(g_workerMapHandle);g_workerMapHandle=0;return;}
    g_workerMap->magic=WORKER_MAGIC;g_workerMap->version=WORKER_VERSION;g_workerMap->pid=pid;
    g_workerMap->heartbeat_tick=0;g_workerMap->command_seq=0;g_workerMap->command_slot=0;g_workerMap->ack_seq=0;
    g_workerMap->state=WORKER_INIT;g_workerMap->phase=PHASE_IDLE;g_workerMap->target_slot=0;g_workerMap->in_world=g_world;
    g_workerMap->combat=0;g_workerMap->error=0;g_workerMap->elapsed_ms=0;g_workerMap->current_slot=0;
    g_workerMap->last_event_tick=GetTickCount();
    worker_log_event("WORKER_MAP_READY",GetTickCount());
}

static void shutdown_worker_map(void)
{
    if(g_workerMap){
        g_workerState=WORKER_OFFLINE;g_workerMap->state=WORKER_OFFLINE;
        g_workerMap->heartbeat_tick=GetTickCount();g_workerMap->last_event_tick=g_workerMap->heartbeat_tick;
        worker_log_event("WORKER_OFFLINE",g_workerMap->heartbeat_tick);
        UnmapViewOfFile(g_workerMap);g_workerMap=0;
    }
    if(g_workerMapHandle){CloseHandle(g_workerMapHandle);g_workerMapHandle=0;}
}

static void log_line(const char*event,DWORD now,DWORD value)
{
    HANDLE h; DWORD wr=0; char b[256],*p=b;
    p=app(p,event);p=app(p," tick=");p=appu(p,now);p=app(p," value=");p=appu(p,value);p=app(p,"\r\n");*p=0;
    h=CreateFileA("CharacterSwitchDiag.log",GENERIC_WRITE,FILE_SHARE_READ|FILE_SHARE_WRITE,NULL,OPEN_ALWAYS,FILE_ATTRIBUTE_NORMAL,NULL);
    if(h==INVALID_HANDLE_VALUE)return;
    SetFilePointer(h,0,NULL,FILE_END);WriteFile(h,b,(DWORD)(p-b),&wr,NULL);CloseHandle(h);
}
static void execs(const char*s){((FrameScriptExecuteFn)(DWORD)WOW_FRAMESCRIPT_EXECUTE)(s,"CharacterSwitchDiag");}
static const char* gettextv(const char*n){return ((FrameScriptGetTextFn)(DWORD)WOW_FRAMESCRIPT_GETTEXT)(n,-1,0);}

static void reset_run(void)
{
    g_phase=PHASE_IDLE;g_targetSlot=0;g_elapsedToGlue=0;g_elapsedTotal=0;g_lastError=0;g_fast=0;
    g_startedAt=g_glueAt=g_enterIssuedAt=0;g_fastConnection=0;g_sessionHash1=0;g_sessionHash2=0;g_fastConnectAt=0;
    g_fastConnectedAt=g_charListKickAt=0;g_fastLastNetState=0xFFFFFFFFu;g_charListAttempts=0;g_fastConnectAttempts=0;
}
static void ensure_ui(void)
{
    static const char s[]=
      "if not W112CSDFrame and UIParent and type(CreateFrame)=='function' then "
      "local f=CreateFrame('Frame','W112CSDFrame',UIParent);f:SetWidth(440);f:SetHeight(182);f:SetPoint('CENTER',UIParent,'CENTER',0,175);"
      "if f.SetBackdrop then f:SetBackdrop({bgFile='Interface\\\\Tooltips\\\\UI-Tooltip-Background',edgeFile='Interface\\\\Tooltips\\\\UI-Tooltip-Border',tile=true,tileSize=16,edgeSize=16,insets={left=4,right=4,top=4,bottom=4}});f:SetBackdropColor(0,0,0,.88) end;"
      "local t=f:CreateFontString(nil,'OVERLAY','GameFontNormal');t:SetPoint('TOP',f,'TOP',0,-12);t:SetText('Character Switch Diagnostic V12');"
      "local st=f:CreateFontString('W112CSDStatus','OVERLAY','GameFontNormalSmall');st:SetPoint('TOPLEFT',f,'TOPLEFT',12,-36);st:SetWidth(416);st:SetJustifyH('LEFT');st:SetText('idle');"
      "local function B(n,x,y,w,txt,cmd)local b=CreateFrame('Button',n,f,'UIPanelButtonTemplate');b:SetWidth(w);b:SetHeight(24);b:SetPoint('BOTTOMLEFT',f,'BOTTOMLEFT',x,y);b:SetText(txt);b:SetScript('OnClick',function()W112_CSD_CMD=cmd end)end;"
      "B('W112CSDStock',12,42,92,'Stock logout','stock');B('W112CSDSlot1',112,42,92,'FAST slot 1','slot1');B('W112CSDSlot2',212,42,92,'FAST slot 2','slot2');"
      "B('W112CSDFast1',60,12,140,'Direct slot 1','fast1');B('W112CSDFast2',230,12,140,'Direct slot 2','fast2');"
      "f:Show();W112_CSD_CMD='' end";
    execs(s);
}
static void update_ui(DWORD now)
{
    char b[460],*p=b;if(now-g_lastUiRefresh<UI_REFRESH_MS)return;g_lastUiRefresh=now;
    p=app(p,"if W112CSDStatus then W112CSDStatus:SetText('phase=");p=appu(p,g_phase);
    p=app(p," target=");p=appu(p,g_targetSlot);p=app(p," fast=");p=appu(p,g_fast);
    p=app(p," world=");p=appu(p,g_world);p=app(p," glue=");p=appu(p,g_glueVisible);
    p=app(p,"\\nworld_to_select_ms=");p=appu(p,g_elapsedToGlue);p=app(p," total_ms=");p=appu(p,g_elapsedTotal);
    p=app(p," err=");p=appu(p,g_lastError);p=app(p,"\\nFAST=world reconnect with preserved session key; no login server') end");*p=0;execs(b);
}
static void probe_glue(void)
{
    const char*v;execs("W112_CSD_GLUE='0';if CharacterSelectUI and CharacterSelectUI.IsVisible and CharacterSelectUI:IsVisible() and type(CharacterSelect_SelectCharacter)=='function' and type(CharacterSelect_EnterWorld)=='function' then W112_CSD_GLUE='1' end");
    v=gettextv("W112_CSD_GLUE");g_glueVisible=(v&&v[0]=='1'&&!v[1])?1:0;
}
static void select_slot(DWORD slot)
{
    char b[330],*p=b;p=app(p,"if CharacterSelectUI and CharacterSelectUI:IsVisible() and type(GetNumCharacters)=='function' and GetNumCharacters()>=");
    p=appu(p,slot);p=app(p," then CharacterSelect_SelectCharacter(");p=appu(p,slot);p=app(p,",1) end");*p=0;execs(b);
}
static void enter_slot(DWORD slot)
{
    char b[260],*p=b;p=app(p,"if CharacterSelect and CharacterSelect.selectedIndex==");p=appu(p,slot);
    p=app(p," and type(CharacterSelect_EnterWorld)=='function' then CharacterSelect_EnterWorld() end");*p=0;execs(b);
}

static int target_slot_available(DWORD slot)
{
    const char*v;char b[300],*p=b;
    p=app(p,"W112_CSD_SLOT_AVAILABLE='0';if type(GetNumCharacters)=='function' and GetNumCharacters()>=");
    p=appu(p,slot);p=app(p," then W112_CSD_SLOT_AVAILABLE='1' end");*p=0;execs(b);
    v=gettextv("W112_CSD_SLOT_AVAILABLE");
    if(v&&v[0]=='1'&&!v[1]){execs("W112_CSD_SLOT_AVAILABLE=nil");return 1;}
    execs("W112_CSD_SLOT_AVAILABLE=nil");return 0;
}
static int target_slot_selected(DWORD slot)
{
    const char*v;char b[300],*p=b;
    p=app(p,"W112_CSD_SLOT_SELECTED='0';if CharacterSelect and CharacterSelect.selectedIndex==");
    p=appu(p,slot);p=app(p," then W112_CSD_SLOT_SELECTED='1' end");*p=0;execs(b);
    v=gettextv("W112_CSD_SLOT_SELECTED");
    if(v&&v[0]=='1'&&!v[1]){execs("W112_CSD_SLOT_SELECTED=nil");return 1;}
    execs("W112_CSD_SLOT_SELECTED=nil");return 0;
}
static int request_charlist_update(DWORD now)
{
    const char*v;
    execs("W112_CSD_CHARLIST_CAP='0';if type(SetCurrentScreen)=='function' and type(GetCharacterListUpdate)=='function' then W112_CSD_CHARLIST_CAP='1';SetCurrentScreen('charselect');GetCharacterListUpdate() end");
    v=gettextv("W112_CSD_CHARLIST_CAP");
    if(v&&v[0]=='1'&&!v[1]){
        g_charListAttempts++;g_charListKickAt=now;
        log_line("DIRECT_CHARLIST_REQUEST",now,g_charListAttempts);
        execs("W112_CSD_CHARLIST_CAP=nil");
        return 1;
    }
    g_charListAttempts++;g_charListKickAt=now;
    log_line("DIRECT_CHARLIST_API_WAIT",now,g_charListAttempts);
    execs("W112_CSD_CHARLIST_CAP=nil");
    return 0;
}
static void probe_combat(DWORD now)
{
    const char*v;
    if(!g_world){g_combat=0;return;}
    if(g_lastCombatProbe&&now-g_lastCombatProbe<COMBAT_POLL_MS)return;
    g_lastCombatProbe=now;
    execs("W112_CSD_COMBAT='0';if type(UnitAffectingCombat)=='function' and UnitAffectingCombat('player') then W112_CSD_COMBAT='1' end");
    v=gettextv("W112_CSD_COMBAT");g_combat=(v&&v[0]=='1'&&!v[1])?1:0;
}
static void publish_worker(DWORD now)
{
    DWORD state;
    if(!g_workerMap)return;
    state=g_workerState;
    if(g_phase==PHASE_FAILED)state=WORKER_FAILED;
    else if(g_phase==PHASE_COMPLETE&&g_world)state=WORKER_READY;
    else if(g_phase!=PHASE_IDLE&&g_phase!=PHASE_COMPLETE&&g_phase!=PHASE_FAILED)state=WORKER_SWITCHING;
    else if(g_workerMap->command_seq!=g_workerSeenSeq){
        if(!g_world)state=WORKER_WAIT_WORLD;
        else if(g_combat)state=WORKER_COMBAT_BLOCKED;
        else state=WORKER_BUSY;
    }else if(g_phase==PHASE_IDLE&&g_world)state=WORKER_IDLE;
    g_workerState=state;
    g_workerMap->heartbeat_tick=now;g_workerMap->state=state;g_workerMap->phase=g_phase;
    g_workerMap->target_slot=g_targetSlot;g_workerMap->in_world=g_world;g_workerMap->combat=g_combat;
    g_workerMap->error=g_lastError;g_workerMap->elapsed_ms=g_startedAt?now-g_startedAt:g_elapsedTotal;
    g_workerMap->current_slot=g_currentSlot;
    if(g_workerLastState!=state){
        g_workerMap->last_event_tick=now;g_workerLastState=state;worker_log_event("WORKER_STATE",now);
    }
}
static void begin_stock(DWORD now,DWORD slot)
{
    reset_run();g_targetSlot=slot;g_startedAt=now;g_phase=PHASE_WAIT_LOGOUT;log_line("STOCK_BEGIN",now,slot);
    execs("if type(Logout)=='function' then Logout() end");
}
static int direct_reconnect_guard(void)
{
    static const BYTE getterSig[]={0xA1,0x28,0x81,0xC2,0x00,0xC3};
    static const BYTE discSig[]={
        0x56,0x8B,0xF1,0xE8,0x68,0xC7,0xF8,0xFF,
        0xC7,0x86,0x00,0x1B,0x00,0x00,0x00,0x00,0x00,0x00
    };
    static const BYTE connectSelectedSig[]={
        0xA0,0x34,0x81,0xC2,0x00,0x84,0xC0,0x75,0x1A,
        0xE8,0xE2,0xFE,0xFF,0xFF,0x84,0xC0,0x75,0x11
    };
    static const BYTE netConnectSig[]={
        0x55,0x8B,0xEC,0x81,0xEC,0x00,0x04,0x00,0x00,
        0x56,0x8B,0xF1,0x8B,0x46,0x70,0x83,0xF8,0x02
    };
    return bytes_equal(WOW_CLIENTSERVICES_GET,getterSig,sizeof(getterSig)) &&
           bytes_equal(WOW_CLIENTSERVICES_DISC,discSig,sizeof(discSig)) &&
           bytes_equal(WOW_CONNECT_SELECTED,connectSelectedSig,sizeof(connectSelectedSig)) &&
           bytes_equal(WOW_NET_CONNECT,netConnectSig,sizeof(netConnectSig));
}
static int fast_connection_state(void)
{
    if(!ptr_ok(g_fastConnection))return -1;
    return (int)rd32(g_fastConnection+NET_STATE_OFFSET);
}
static int fast_session_key_matches(void)
{
    const BYTE*key;
    if(!ptr_ok(g_fastConnection))return 0;
    key=(const BYTE*)(g_fastConnection+SESSION_KEY_OFFSET);
    if(!key_nonzero(key))return 0;
    return key_hash1(key)==g_sessionHash1 && key_hash2(key)==g_sessionHash2;
}
static void fast_fail(DWORD now,DWORD error,const char*event)
{
    if(g_world)execs("W112_CSD_SESSION_SWITCH=nil");
    g_lastError=error;g_phase=PHASE_FAILED;log_line(event,now,(DWORD)fast_connection_state());
}

static int fast_connect_selected(DWORD now)
{
    ConnectToSelectedServerFn connectFn;
    if(g_fastConnectAttempts>=FAST_CONNECT_MAX_ATTEMPTS)return 0;
    if(!fast_session_key_matches()){
        fast_fail(now,64,"DIRECT_SESSION_KEY_CHANGED");
        return 0;
    }
    g_fastConnectAttempts++;
    g_fastConnectAt=now;g_fastConnectedAt=0;g_charListKickAt=0;g_charListAttempts=0;
    log_line("DIRECT_CONNECT_ATTEMPT",now,g_fastConnectAttempts);
    connectFn=(ConnectToSelectedServerFn)(DWORD)WOW_CONNECT_SELECTED;
    log_line("DIRECT_CONNECT_SELECTED_CALL",now,WOW_CONNECT_SELECTED);
    connectFn();
    log_line("DIRECT_CONNECT_SELECTED_RETURN",GetTickCount(),(DWORD)fast_connection_state());
    return 1;
}
static void begin_fast(DWORD now,DWORD slot)
{
    GetClientServicesFn getServices;
    ClientServicesDisconnectFn disconnectFn;
    void*connection;
    const BYTE*key;
    DWORD state;

    reset_run();g_fast=1;g_targetSlot=slot;g_startedAt=now;g_phase=PHASE_FAST_DISCONNECT;
    log_line("DIRECT_RECONNECT_BEGIN",now,slot);

    if(!direct_reconnect_guard()){
        g_lastError=60;g_phase=PHASE_FAILED;log_line("DIRECT_GUARD_FAIL",now,WOW_CONNECT_SELECTED);return;
    }

    getServices=(GetClientServicesFn)(DWORD)WOW_CLIENTSERVICES_GET;
    connection=getServices();
    if(!ptr_ok((DWORD)connection)){
        g_lastError=61;g_phase=PHASE_FAILED;log_line("DIRECT_CONNECTION_NULL",now,(DWORD)connection);return;
    }

    state=rd32((DWORD)connection+NET_STATE_OFFSET);
    if(state!=NET_STATE_CONNECTED){
        g_lastError=62;g_phase=PHASE_FAILED;log_line("DIRECT_BAD_NET_STATE",now,state);return;
    }

    key=(const BYTE*)((DWORD)connection+SESSION_KEY_OFFSET);
    if(!key_nonzero(key)){
        g_lastError=63;g_phase=PHASE_FAILED;log_line("DIRECT_SESSION_KEY_EMPTY",now,0);return;
    }

    g_fastConnection=(DWORD)connection;
    g_sessionHash1=key_hash1(key);g_sessionHash2=key_hash2(key);
    execs("W112_CSD_SESSION_SWITCH='1'");
    log_line("DIRECT_SESSION_KEY_CAPTURED",now,1);

    disconnectFn=(ClientServicesDisconnectFn)(DWORD)WOW_CLIENTSERVICES_DISC;
    log_line("DIRECT_WORLD_DISCONNECT_CALL",now,WOW_CLIENTSERVICES_DISC);
    disconnectFn(connection);
    log_line("DIRECT_WORLD_DISCONNECT_RETURN",GetTickCount(),(DWORD)fast_connection_state());
}
static void worker_command_fail(DWORD now,DWORD seq,DWORD error,const char*event)
{
    g_workerSeenSeq=seq;g_lastError=error;g_phase=PHASE_FAILED;g_workerState=WORKER_FAILED;
    if(g_workerMap){g_workerMap->ack_seq=seq;g_workerMap->state=WORKER_FAILED;g_workerMap->error=error;g_workerMap->last_event_tick=now;}
    worker_log_event(event,now);
}
static void begin_reload_ui(DWORD now,DWORD seq)
{
    const char*v;
    reset_run();g_workerSeenSeq=seq;g_workerState=WORKER_BUSY;
    if(g_workerMap){g_workerMap->state=WORKER_BUSY;g_workerMap->error=0;g_workerMap->last_event_tick=now;}
    worker_log_event("COORD_RELOAD_BEGIN",now);

    execs("W112_CSD_RELOAD_CAP=(type(ReloadUI)=='function') and '1' or '0'");
    v=gettextv("W112_CSD_RELOAD_CAP");
    if(!v||v[0]!='1'||v[1]){
        execs("W112_CSD_RELOAD_CAP=nil");
        worker_command_fail(GetTickCount(),seq,43,"COORD_RELOAD_UNAVAILABLE");
        return;
    }

    /*
     * FrameScript_Execute runs on WoW's window thread. ACK is deliberately
     * written only after ReloadUI() returns, so the updater never kills on a
     * merely queued reload request. A timeout remains fail-closed upstream.
     */
    /* ReloadUI may pump window messages while the Lua/UI state is being torn
     * down. Block nested timer ticks from re-entering FrameScript during that
     * interval; ACK remains post-return and therefore fail-closed. */
    g_reloadInProgress=1;
    execs("W112_CSD_RELOAD_CAP=nil;ReloadUI()");
    g_reloadInProgress=0;
    now=GetTickCount();
    if(g_workerMap){g_workerMap->ack_seq=seq;g_workerMap->last_event_tick=now;}
    g_workerState=WORKER_IDLE;
    worker_log_event("COORD_RELOAD_DONE",now);
}
static void poll_worker_cmd(DWORD now)
{
    DWORD seq,slot;
    if(!g_workerMap)return;
    seq=g_workerMap->command_seq;if(!seq||seq==g_workerSeenSeq)return;
    slot=g_workerMap->command_slot;

    if(slot==WORKER_COMMAND_RELOAD){
        if(g_phase!=PHASE_IDLE&&g_phase!=PHASE_COMPLETE&&g_phase!=PHASE_FAILED){
            worker_command_fail(now,seq,44,"COORD_RELOAD_BUSY");return;
        }
        if(!g_world){
            worker_command_fail(now,seq,42,"COORD_RELOAD_NOT_IN_WORLD");return;
        }
        begin_reload_ui(now,seq);
        return;
    }

    if(g_phase!=PHASE_IDLE&&g_phase!=PHASE_COMPLETE&&g_phase!=PHASE_FAILED){
        g_workerState=WORKER_BUSY;return;
    }
    if(!g_world){g_workerState=WORKER_WAIT_WORLD;return;}
    if(g_combat){
        if(g_workerState!=WORKER_COMBAT_BLOCKED)worker_log_event("COORD_COMBAT_BLOCK",now);
        g_workerState=WORKER_COMBAT_BLOCKED;return;
    }
    if(slot==0){
        g_workerSeenSeq=seq;g_workerMap->ack_seq=seq;reset_run();g_workerState=WORKER_IDLE;
        worker_log_event("COORD_CANCEL",now);return;
    }
    if(slot>10u){
        g_workerSeenSeq=seq;g_workerMap->ack_seq=seq;g_lastError=41;g_phase=PHASE_FAILED;g_workerState=WORKER_FAILED;
        worker_log_event("COORD_BAD_SLOT",now);return;
    }
    g_workerSeenSeq=seq;g_workerMap->ack_seq=seq;
    if(g_currentSlot==slot){
        reset_run();g_targetSlot=slot;g_phase=PHASE_COMPLETE;g_workerState=WORKER_READY;
        worker_log_event("COORD_ALREADY_READY",now);return;
    }
    g_workerState=WORKER_SWITCHING;worker_log_event("COORD_SWITCH_BEGIN",now);
    begin_fast(now,slot);
    if(g_phase==PHASE_FAILED)g_workerState=WORKER_FAILED;
}
static void poll_cmd(DWORD now)
{
    const char*c=gettextv("W112_CSD_CMD");if(!c||!c[0])return;execs("W112_CSD_CMD=''");
    if(eq(c,"stock"))begin_stock(now,0);
    else if(eq(c,"slot1")||eq(c,"fast1"))begin_fast(now,1);
    else if(eq(c,"slot2")||eq(c,"fast2"))begin_fast(now,2);
}
static int worker_command_pending(void)
{
    return g_workerMap && g_workerMap->command_seq && g_workerMap->command_seq!=g_workerSeenSeq;
}
static int switch_phase_active(void)
{
    return g_phase!=PHASE_IDLE && g_phase!=PHASE_COMPLETE && g_phase!=PHASE_FAILED;
}
static VOID CALLBACK tick(HWND h,UINT m,UINT_PTR id,DWORD now)
{
    DWORD world=rd32(WOW_OBJMGR)?1:0;
    int pending=worker_command_pending();
    int switching=switch_phase_active();
    (void)h;(void)m;(void)id;g_world=world;

    /* Report #70: an idle 50ms worker must not enter FrameScript while a
     * manual /reload destroys and rebuilds the Lua/UI state. The worker map
     * heartbeat remains native-only. */
    if(g_reloadInProgress){
        publish_worker(now);
        g_lastWorld=world;
        return;
    }

    if(world){
        g_glueVisible=0;
        if((pending || switching) && g_phase!=PHASE_FAST_DISCONNECT && g_phase!=PHASE_FAST_RECONNECT)probe_combat(now);
        poll_worker_cmd(now);
        if(g_phase==PHASE_ENTERING && !g_lastWorld){
            g_elapsedTotal=g_startedAt?now-g_startedAt:0;g_phase=PHASE_COMPLETE;g_currentSlot=g_targetSlot;g_workerState=WORKER_READY;
            execs("W112_CSD_SESSION_SWITCH=nil");
            log_line("WORLD_ENTERED",now,g_elapsedTotal);worker_log_event("COORD_READY",now);
        }
        if(g_phase==PHASE_FAST_DISCONNECT && g_startedAt && now-g_startedAt>FAST_DISCONNECT_TIMEOUT_MS){
            fast_fail(now,65,"DIRECT_DISCONNECT_TIMEOUT");
        }
    }else{
        /* Glue probing is needed only for an active switch. At idle this used
         * to call FrameScript every 50ms, including during ReloadUI teardown. */
        if(switching && g_phase!=PHASE_FAST_DISCONNECT)probe_glue();
        if(g_phase==PHASE_FAST_DISCONNECT){
            int state=fast_connection_state();
            if(state==NET_STATE_INITIALIZED){
                if(!fast_session_key_matches()){
                    fast_fail(now,64,"DIRECT_SESSION_KEY_CHANGED");
                }else{
                    log_line("DIRECT_SESSION_KEY_PRESERVED",now,1);
                    g_phase=PHASE_FAST_RECONNECT;
                    if(!fast_connect_selected(now)&&g_phase!=PHASE_FAILED)
                        fast_fail(now,70,"DIRECT_CONNECT_RETRY_EXHAUSTED");
                }
            }else if(state<0){
                fast_fail(now,66,"DIRECT_CONNECTION_LOST");
            }else if(g_startedAt && now-g_startedAt>FAST_DISCONNECT_TIMEOUT_MS){
                fast_fail(now,65,"DIRECT_NET_INIT_TIMEOUT");
            }
        }else if(g_phase==PHASE_FAST_RECONNECT){
            int state=fast_connection_state();
            if((DWORD)state!=g_fastLastNetState){
                g_fastLastNetState=(DWORD)state;
                log_line("DIRECT_NET_STATE",now,(DWORD)state);
            }

            probe_glue();

            if(state==NET_STATE_CONNECTED){
                if(!g_fastConnectedAt){
                    g_fastConnectedAt=now;
                    log_line("DIRECT_WORLD_CONNECTED",now,g_fastConnectAttempts);
                }

                if(now-g_fastConnectedAt>=FAST_AUTH_SETTLE_MS &&
                   (!g_charListKickAt || now-g_charListKickAt>=FAST_CHARLIST_RETRY_MS) &&
                   g_charListAttempts<FAST_CHARLIST_MAX_ATTEMPTS){
                    request_charlist_update(now);
                }

                probe_glue();
                if(g_glueVisible && target_slot_available(g_targetSlot)){
                    g_elapsedToGlue=g_startedAt?now-g_startedAt:0;g_glueAt=now;g_phase=PHASE_CHAR_SELECT;
                    select_slot(g_targetSlot);log_line("DIRECT_CHAR_SELECT",now,g_elapsedToGlue);
                    execs("W112_CSD_SESSION_SWITCH=nil");
                }
            }else if(state==NET_STATE_INITIALIZED && g_fastConnectAt &&
                     now-g_fastConnectAt>=FAST_CONNECT_RETRY_MS){
                if(!fast_connect_selected(now)&&g_phase!=PHASE_FAILED)
                    fast_fail(now,70,"DIRECT_CONNECT_RETRY_EXHAUSTED");
            }else if(state<0){
                fast_fail(now,66,"DIRECT_CONNECTION_LOST");
            }

            if(g_phase==PHASE_FAST_RECONNECT && g_startedAt &&
               now-g_startedAt>FAST_RECONNECT_TIMEOUT_MS){
                if(g_charListAttempts>=FAST_CHARLIST_MAX_ATTEMPTS)
                    fast_fail(now,69,"DIRECT_CHARLIST_TIMEOUT");
                else
                    fast_fail(now,67,"DIRECT_RECONNECT_TIMEOUT");
            }
        }else if(g_phase==PHASE_WAIT_LOGOUT && g_glueVisible){
            g_elapsedToGlue=g_startedAt?now-g_startedAt:0;g_glueAt=now;g_phase=PHASE_CHAR_SELECT;
            if(g_targetSlot)select_slot(g_targetSlot);
            log_line("STOCK_CHAR_SELECT",now,g_elapsedToGlue);
        }else if(g_phase==PHASE_CHAR_SELECT && g_targetSlot && g_glueVisible && now-g_glueAt>=SELECT_SETTLE_MS){
            if(target_slot_selected(g_targetSlot)){
                enter_slot(g_targetSlot);g_enterIssuedAt=now;g_phase=PHASE_ENTERING;log_line("ENTER_SLOT",now,g_targetSlot);
            }else{
                select_slot(g_targetSlot);g_glueAt=now;log_line("DIRECT_SLOT_SELECT_RETRY",now,g_targetSlot);
            }
        }else if(g_phase==PHASE_ENTERING && g_enterIssuedAt && now-g_enterIssuedAt>ENTER_TIMEOUT_MS){
            g_lastError=30;g_phase=PHASE_FAILED;log_line("ENTER_TIMEOUT",now,g_targetSlot);
        }
    }
    if(!world)g_combat=0;
    publish_worker(now);
    g_lastWorld=world;
}
static void init_settings(void)
{
    DWORD i;static const char*keys[7]={"phase","target_slot","fast_mode","in_world","char_select","world_to_select_ms","total_ms"};
    static const char*labels[7]={"Phase","Target slot","Fast mode","In world","Character select","World -> select ms","Total switch ms"};
    if(g_descReady)return;for(i=0;i<7;i++){W112_ControlSettingV1*s=&g_settings[i];s->struct_size=sizeof(*s);s->setting_id=i+1;s->key=keys[i];s->label=labels[i];
    s->type=(i==2||i==3||i==4)?W112_CTL_BOOL:W112_CTL_INT;s->default_value.u32=0;s->min_value.u32=0;s->max_value.u32=2147483647u;s->step.u32=1;s->flags=W112_CTL_READ_ONLY|W112_CTL_LIVE;s->enum_options=0;s->enum_option_count=0;}
    g_settings[2].max_value.u32=g_settings[3].max_value.u32=g_settings[4].max_value.u32=1;g_descReady=1;
}
static int W112_CTL_STDCALL getv(w112_u32 id,W112_ControlValueV1*v)
{
    if(!v)return 0;if(id==1)v->u32=g_phase;else if(id==2)v->u32=g_targetSlot;else if(id==3)v->u32=g_fast;else if(id==4)v->u32=g_world;
    else if(id==5)v->u32=g_glueVisible;else if(id==6)v->u32=g_elapsedToGlue;else if(id==7)v->u32=g_elapsedTotal;else return 0;return 1;
}
static int W112_CTL_STDCALL setv(w112_u32 id,const W112_ControlValueV1*v){(void)id;(void)v;return 0;}
static const W112_ControlModuleV1 mod={W112_CONTROL_API_V1,sizeof(W112_ControlModuleV1),"characterswitchdiag","Summon Switch Worker",0x00030000u,7,g_settings,getv,setv};
__declspec(dllexport) const W112_ControlModuleV1* W112_CTL_STDCALL W112_Control_GetModuleV1(void){init_settings();return &mod;}
BOOL WINAPI DllMain(HMODULE h,DWORD r,LPVOID x)
{
    (void)x;if(r==DLL_PROCESS_ATTACH){DisableThreadLibraryCalls(h);reset_run();g_lastWorld=rd32(WOW_OBJMGR)?1:0;g_world=g_lastWorld;init_worker_map();log_line("LOAD_V12_DIRECT_CHARLIST_RECOVERY",GetTickCount(),WOW_CONNECT_SELECTED);g_timer=SetTimer(NULL,0,TIMER_MS,tick);}
    else if(r==DLL_PROCESS_DETACH){if(g_timer)KillTimer(NULL,g_timer);shutdown_worker_map();}return TRUE;
}
