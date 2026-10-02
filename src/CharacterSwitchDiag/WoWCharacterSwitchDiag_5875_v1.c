/*
 * WoWCharacterSwitchDiag 5875 v10 - session-safe summon switch/reload worker.
 *
 * Coordinator switch preserves the already authenticated account session:
 *   Logout() -> character select -> target slot -> EnterWorld().
 * It never calls ClientServices::Disconnect and never requests AutoLoginBridge
 * relogin, so slave rotation does not depend on the login server.
 *
 * Report #77 disproved ForceLogout as a general timer bypass on this realm:
 * both workers returned from ForceLogout but remained in world until the
 * fail-closed timeout. Vanilla/vMaNGOS instant logout is server-authorized;
 * normal outdoor logout can therefore take the standard ~20 seconds.
 */
#if !defined(_M_IX86) && !defined(__i386__)
#error WoWCharacterSwitchDiag requires x86.
#endif
#include <windows.h>
#include "../common/W112ControlAPI.h"

#define WOW_OBJMGR              0x00B41414u
#define WOW_FRAMESCRIPT_GETTEXT 0x00703BF0u
#define WOW_FRAMESCRIPT_EXECUTE 0x00704CD0u
#define TIMER_MS 50u
#define UI_REFRESH_MS 250u
#define SELECT_SETTLE_MS 350u
#define ENTER_TIMEOUT_MS 30000u
#define SESSION_LOGOUT_TIMEOUT_MS 30000u
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

enum {
    PHASE_IDLE=0, PHASE_WAIT_LOGOUT=1, PHASE_CHAR_SELECT=2, PHASE_ENTERING=3,
    PHASE_COMPLETE=4, PHASE_FAILED=5
};

static volatile DWORD g_phase=PHASE_IDLE,g_targetSlot=0,g_elapsedToGlue=0,g_elapsedTotal=0;
static volatile DWORD g_lastError=0,g_world=0,g_glueVisible=0,g_fast=0;
static volatile DWORD g_reloadInProgress=0;
static UINT_PTR g_timer=0;
static DWORD g_startedAt=0,g_glueAt=0,g_enterIssuedAt=0,g_lastUiRefresh=0,g_lastWorld=0;
static HANDLE g_workerMapHandle=0;
static WorkerMapV1 *g_workerMap=0;
static DWORD g_workerSeenSeq=0,g_workerState=WORKER_INIT,g_workerLastState=0xFFFFFFFFu;
static DWORD g_currentSlot=0,g_combat=0,g_lastCombatProbe=0;
static W112_ControlSettingV1 g_settings[7];
static DWORD g_descReady=0;
int _fltused=0;

static DWORD rd32(DWORD a){return *(volatile DWORD*)a;}
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
    g_startedAt=g_glueAt=g_enterIssuedAt=0;
}
static void ensure_ui(void)
{
    static const char s[]=
      "if not W112CSDFrame and UIParent and type(CreateFrame)=='function' then "
      "local f=CreateFrame('Frame','W112CSDFrame',UIParent);f:SetWidth(440);f:SetHeight(182);f:SetPoint('CENTER',UIParent,'CENTER',0,175);"
      "if f.SetBackdrop then f:SetBackdrop({bgFile='Interface\\\\Tooltips\\\\UI-Tooltip-Background',edgeFile='Interface\\\\Tooltips\\\\UI-Tooltip-Border',tile=true,tileSize=16,edgeSize=16,insets={left=4,right=4,top=4,bottom=4}});f:SetBackdropColor(0,0,0,.88) end;"
      "local t=f:CreateFontString(nil,'OVERLAY','GameFontNormal');t:SetPoint('TOP',f,'TOP',0,-12);t:SetText('Character Switch Diagnostic V10');"
      "local st=f:CreateFontString('W112CSDStatus','OVERLAY','GameFontNormalSmall');st:SetPoint('TOPLEFT',f,'TOPLEFT',12,-36);st:SetWidth(416);st:SetJustifyH('LEFT');st:SetText('idle');"
      "local function B(n,x,y,w,txt,cmd)local b=CreateFrame('Button',n,f,'UIPanelButtonTemplate');b:SetWidth(w);b:SetHeight(24);b:SetPoint('BOTTOMLEFT',f,'BOTTOMLEFT',x,y);b:SetText(txt);b:SetScript('OnClick',function()W112_CSD_CMD=cmd end)end;"
      "B('W112CSDStock',12,42,92,'Stock logout','stock');B('W112CSDSlot1',112,42,92,'Switch slot 1','slot1');B('W112CSDSlot2',212,42,92,'Switch slot 2','slot2');"
      "B('W112CSDFast1',60,12,140,'SESSION slot 1','fast1');B('W112CSDFast2',230,12,140,'SESSION slot 2','fast2');"
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
    p=app(p," err=");p=appu(p,g_lastError);p=app(p,"\\nSESSION=Logout -> Character Select; login server untouched') end");*p=0;execs(b);
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
static void begin_fast(DWORD now,DWORD slot)
{
    const char *v;

    reset_run();g_fast=1;g_targetSlot=slot;g_startedAt=now;g_phase=PHASE_WAIT_LOGOUT;
    log_line("SESSION_LOGOUT_BEGIN",now,slot);

    /* Fail closed and stay on the existing authenticated account session.
       Do not fall back to ClientServices::Disconnect or AutoLoginBridge. */
    execs("W112_CSD_LOGOUT_CAP=(type(Logout)=='function') and '1' or '0';W112_CSD_SESSION_SWITCH='1'");
    v=gettextv("W112_CSD_LOGOUT_CAP");
    if(!v||v[0]!='1'||v[1]){
        execs("W112_CSD_LOGOUT_CAP=nil;W112_CSD_SESSION_SWITCH=nil");
        g_lastError=53;g_phase=PHASE_FAILED;
        log_line("SESSION_LOGOUT_UNAVAILABLE",GetTickCount(),slot);
        return;
    }

    execs("W112_CSD_LOGOUT_CAP=nil;Logout()");
    log_line("SESSION_LOGOUT_REQUESTED",GetTickCount(),slot);
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
    if(eq(c,"stock"))begin_stock(now,0);else if(eq(c,"slot1"))begin_stock(now,1);else if(eq(c,"slot2"))begin_stock(now,2);
    else if(eq(c,"fast1"))begin_fast(now,1);else if(eq(c,"fast2"))begin_fast(now,2);
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
        if(pending || switching)probe_combat(now);
        poll_worker_cmd(now);
        if(g_phase==PHASE_ENTERING && !g_lastWorld){
            g_elapsedTotal=g_startedAt?now-g_startedAt:0;g_phase=PHASE_COMPLETE;g_currentSlot=g_targetSlot;g_workerState=WORKER_READY;
            log_line("WORLD_ENTERED",now,g_elapsedTotal);worker_log_event("COORD_READY",now);
        }
        if(g_phase==PHASE_WAIT_LOGOUT && g_fast && g_startedAt && now-g_startedAt>SESSION_LOGOUT_TIMEOUT_MS){
            execs("W112_CSD_SESSION_SWITCH=nil");
            g_lastError=54;g_phase=PHASE_FAILED;log_line("SESSION_LOGOUT_TIMEOUT",now,rd32(WOW_OBJMGR));
        }
    }else{
        /* Glue probing is needed only for an active switch. At idle this used
         * to call FrameScript every 50ms, including during ReloadUI teardown. */
        if(switching)probe_glue();
        if(g_phase==PHASE_WAIT_LOGOUT && g_glueVisible){
            g_elapsedToGlue=g_startedAt?now-g_startedAt:0;g_glueAt=now;g_phase=PHASE_CHAR_SELECT;
            if(g_targetSlot)select_slot(g_targetSlot);
            log_line(g_fast?"SESSION_CHAR_SELECT":"STOCK_CHAR_SELECT",now,g_elapsedToGlue);
            if(g_fast)execs("W112_CSD_SESSION_SWITCH=nil");
        }else if(g_phase==PHASE_CHAR_SELECT && g_targetSlot && g_glueVisible && now-g_glueAt>=SELECT_SETTLE_MS){
            enter_slot(g_targetSlot);g_enterIssuedAt=now;g_phase=PHASE_ENTERING;log_line("ENTER_SLOT",now,g_targetSlot);
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
    (void)x;if(r==DLL_PROCESS_ATTACH){DisableThreadLibraryCalls(h);reset_run();g_lastWorld=rd32(WOW_OBJMGR)?1:0;g_world=g_lastWorld;init_worker_map();log_line("LOAD_V10_SESSION_SAFE",GetTickCount(),0u);g_timer=SetTimer(NULL,0,TIMER_MS,tick);}
    else if(r==DLL_PROCESS_DETACH){if(g_timer)KillTimer(NULL,g_timer);shutdown_worker_map();}return TRUE;
}
