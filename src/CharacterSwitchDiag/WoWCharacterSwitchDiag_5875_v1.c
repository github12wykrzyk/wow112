/*
 * WoWCharacterSwitchDiag 5875 v1
 * Diagnostic-only character switch baseline for WoW 1.12.1 build 5875 x86.
 *
 * Purpose:
 * - measure stock Logout() -> Character Select latency;
 * - optionally pre-arm slot 1 or 2 and re-enter the world automatically;
 * - prove that the same WoW process can traverse World -> Glue -> World;
 * - gather exact timing before any attempt to bypass the 20 s server logout delay.
 *
 * This module does NOT patch logout timers, send crafted packets, disconnect the
 * socket, or hook movement/cast/send paths. UI is created dynamically through
 * FrameScript_Execute; no AddOn and no Win32 WndProc subclass are used.
 */
#if !defined(_M_IX86) && !defined(__i386__)
#error WoWCharacterSwitchDiag requires x86.
#endif

#include "../common/W112ControlAPI.h"

#if defined(_MSC_VER)
#define STDCALL __stdcall
#define FASTCALL __fastcall
#define DLLEXPORT __declspec(dllexport)
#pragma comment(linker, "/EXPORT:W112_Control_GetModuleV1=_W112_Control_GetModuleV1@0")
#else
#define STDCALL __attribute__((stdcall))
#define FASTCALL __attribute__((fastcall))
#define DLLEXPORT __attribute__((dllexport))
#endif

typedef unsigned int u32;
typedef unsigned int ptr32;
typedef void *HWND32;
typedef unsigned int UINT32;
typedef unsigned int UINT_PTR32;
typedef int BOOL32;

typedef void (STDCALL *TimerProc32)(HWND32,UINT32,UINT_PTR32,u32);
typedef UINT_PTR32 (STDCALL *SetTimerFn)(HWND32,UINT_PTR32,UINT32,TimerProc32);
typedef BOOL32 (STDCALL *KillTimerFn)(HWND32,UINT_PTR32);
typedef BOOL32 (FASTCALL *FrameScriptExecuteFn)(const char*,const char*);
typedef const char* (FASTCALL *FrameScriptGetTextFn)(const char*,int,u32);

#define WOW_OBJMGR              0x00B41414u
#define WOW_FRAMESCRIPT_GETTEXT 0x00703BF0u
#define WOW_FRAMESCRIPT_EXECUTE 0x00704CD0u
#define WOW_IAT_SETTIMER        0x007FF4F4u
#define WOW_IAT_KILLTIMER       0x007FF4F8u

#define TIMER_MS 50u
#define UI_REFRESH_MS 250u
#define SELECT_SETTLE_MS 350u
#define ENTER_TIMEOUT_MS 30000u

enum {
    PHASE_IDLE=0u,
    PHASE_WAIT_LOGOUT=1u,
    PHASE_CHAR_SELECT=2u,
    PHASE_ENTERING=3u,
    PHASE_COMPLETE=4u,
    PHASE_FAILED=5u
};

static volatile UINT_PTR32 g_timer=0u;
static volatile u32 g_phase=PHASE_IDLE;
static volatile u32 g_targetSlot=0u;
static volatile u32 g_elapsedToGlue=0u;
static volatile u32 g_elapsedTotal=0u;
static volatile u32 g_lastError=0u;
static volatile u32 g_world=0u;
static volatile u32 g_glueVisible=0u;
static u32 g_startedAt=0u;
static u32 g_glueAt=0u;
static u32 g_enterIssuedAt=0u;
static u32 g_lastUiRefresh=0u;
static u32 g_lastWorld=0u;
static W112_ControlSettingV1 g_settings[6];
static u32 g_descReady=0u;

int _fltused=0;

static u32 read32(u32 addr){ return *(volatile u32*)(ptr32)addr; }

static int streq(const char *a,const char *b)
{
    if(!a||!b) return 0;
    while(*a&&*b){ if(*a++!=*b++) return 0; }
    return *a==0 && *b==0;
}

static char *app_str(char *p,const char *s)
{
    while(s&&*s) *p++=*s++;
    return p;
}

static char *app_u32(char *p,u32 v)
{
    char tmp[16]; int n=0;
    if(v==0u){ *p++='0'; return p; }
    while(v&&n<15){ tmp[n++]=(char)('0'+(v%10u)); v/=10u; }
    while(n>0) *p++=tmp[--n];
    return p;
}

static void exec_script(const char *s)
{
    ((FrameScriptExecuteFn)(ptr32)WOW_FRAMESCRIPT_EXECUTE)(s,"CharacterSwitchDiag");
}

static const char *get_text(const char *name)
{
    return ((FrameScriptGetTextFn)(ptr32)WOW_FRAMESCRIPT_GETTEXT)(name,-1,0u);
}

static void ensure_world_ui(void)
{
    static const char script[]=
        "if not W112CSDFrame and UIParent and type(CreateFrame)=='function' then "
        "local f=CreateFrame('Frame','W112CSDFrame',UIParent);"
        "f:SetWidth(330);f:SetHeight(150);f:SetPoint('CENTER',UIParent,'CENTER',0,170);"
        "if f.SetBackdrop then f:SetBackdrop({bgFile='Interface\\\\Tooltips\\\\UI-Tooltip-Background',edgeFile='Interface\\\\Tooltips\\\\UI-Tooltip-Border',tile=true,tileSize=16,edgeSize=16,insets={left=4,right=4,top=4,bottom=4}});"
        "f:SetBackdropColor(0,0,0,0.85) end;"
        "local t=f:CreateFontString(nil,'OVERLAY','GameFontNormal');t:SetPoint('TOP',f,'TOP',0,-12);t:SetText('Character Switch Diagnostic');"
        "local s=f:CreateFontString('W112CSDStatus','OVERLAY','GameFontNormalSmall');s:SetPoint('TOPLEFT',f,'TOPLEFT',12,-36);s:SetWidth(306);s:SetJustifyH('LEFT');s:SetText('idle');"
        "local function B(n,x,y,txt,cmd) local b=CreateFrame('Button',n,f,'UIPanelButtonTemplate');b:SetWidth(92);b:SetHeight(24);b:SetPoint('BOTTOMLEFT',f,'BOTTOMLEFT',x,y);b:SetText(txt);b:SetScript('OnClick',function() W112_CSD_CMD=cmd end);return b end;"
        "B('W112CSDStock',12,14,'Stock logout','stock');"
        "B('W112CSDSlot1',119,14,'Switch slot 1','slot1');"
        "B('W112CSDSlot2',226,14,'Switch slot 2','slot2');"
        "f:Show();W112_CSD_CMD='';"
        "end";
    exec_script(script);
}

static void update_world_ui(u32 now)
{
    char b[420],*p=b;
    if((u32)(now-g_lastUiRefresh)<UI_REFRESH_MS) return;
    g_lastUiRefresh=now;
    p=app_str(p,"if W112CSDStatus then W112CSDStatus:SetText('phase=");
    p=app_u32(p,g_phase);
    p=app_str(p,"  target=");
    p=app_u32(p,g_targetSlot);
    p=app_str(p,"  world=");
    p=app_u32(p,g_world);
    p=app_str(p,"  glue=");
    p=app_u32(p,g_glueVisible);
    p=app_str(p,"\\nlogout_to_select_ms=");
    p=app_u32(p,g_elapsedToGlue);
    p=app_str(p,"  total_ms=");
    p=app_u32(p,g_elapsedTotal);
    p=app_str(p,"  err=");
    p=app_u32(p,g_lastError);
    p=app_str(p,"') end");
    *p=0;
    exec_script(b);
}

static void reset_run(void)
{
    g_phase=PHASE_IDLE;
    g_targetSlot=0u;
    g_elapsedToGlue=0u;
    g_elapsedTotal=0u;
    g_lastError=0u;
    g_startedAt=0u;
    g_glueAt=0u;
    g_enterIssuedAt=0u;
}

static void begin_logout(u32 now,u32 target)
{
    reset_run();
    g_targetSlot=target;
    g_startedAt=now;
    g_phase=PHASE_WAIT_LOGOUT;
    exec_script("if type(Logout)=='function' then Logout() else W112_CSD_LUAERR='no-Logout' end");
}

static void poll_command(u32 now)
{
    const char *cmd=get_text("W112_CSD_CMD");
    if(!cmd||!cmd[0]) return;
    exec_script("W112_CSD_CMD=''");
    if(streq(cmd,"stock")) begin_logout(now,0u);
    else if(streq(cmd,"slot1")) begin_logout(now,1u);
    else if(streq(cmd,"slot2")) begin_logout(now,2u);
}

static void probe_glue(void)
{
    const char *v;
    exec_script(
        "W112_CSD_GLUE='0';"
        "if CharacterSelectUI and CharacterSelectUI.IsVisible and CharacterSelectUI:IsVisible() "
        "and type(CharacterSelect_SelectCharacter)=='function' and type(CharacterSelect_EnterWorld)=='function' "
        "then W112_CSD_GLUE='1' end");
    v=get_text("W112_CSD_GLUE");
    g_glueVisible=(v&&v[0]=='1'&&v[1]==0)?1u:0u;
}

static void issue_select(u32 slot)
{
    char b[320],*p=b;
    p=app_str(p,
        "W112_CSD_SELECTED='0';if CharacterSelectUI and CharacterSelectUI.IsVisible and CharacterSelectUI:IsVisible() "
        "and type(GetNumCharacters)=='function' and GetNumCharacters()>=");
    p=app_u32(p,slot);
    p=app_str(p," and type(CharacterSelect_SelectCharacter)=='function' then CharacterSelect_SelectCharacter(");
    p=app_u32(p,slot);
    p=app_str(p,",1);W112_CSD_SELECTED='1' end");
    *p=0;
    exec_script(b);
}

static void issue_enter(u32 slot)
{
    char b[260],*p=b;
    p=app_str(p,
        "W112_CSD_ENTERED='0';if CharacterSelect and CharacterSelect.selectedIndex==");
    p=app_u32(p,slot);
    p=app_str(p,
        " and type(CharacterSelect_EnterWorld)=='function' then CharacterSelect_EnterWorld();W112_CSD_ENTERED='1' end");
    *p=0;
    exec_script(b);
}

static void STDCALL tick(HWND32 h,UINT32 m,UINT_PTR32 id,u32 now)
{
    u32 world=read32(WOW_OBJMGR)?1u:0u;
    (void)h;(void)m;(void)id;
    g_world=world;

    if(world){
        g_glueVisible=0u;
        ensure_world_ui();
        poll_command(now);

        if(g_phase==PHASE_ENTERING && !g_lastWorld){
            g_elapsedTotal=g_startedAt?(u32)(now-g_startedAt):0u;
            g_phase=PHASE_COMPLETE;
        }
        update_world_ui(now);
    }else{
        probe_glue();

        if(g_phase==PHASE_WAIT_LOGOUT && g_glueVisible){
            g_elapsedToGlue=g_startedAt?(u32)(now-g_startedAt):0u;
            g_glueAt=now;
            g_phase=PHASE_CHAR_SELECT;
            if(g_targetSlot) issue_select(g_targetSlot);
        }else if(g_phase==PHASE_CHAR_SELECT && g_targetSlot && g_glueVisible){
            if((u32)(now-g_glueAt)>=SELECT_SETTLE_MS){
                issue_enter(g_targetSlot);
                g_enterIssuedAt=now;
                g_phase=PHASE_ENTERING;
            }
        }else if(g_phase==PHASE_ENTERING && g_enterIssuedAt &&
                 (u32)(now-g_enterIssuedAt)>ENTER_TIMEOUT_MS){
            g_lastError=1u;
            g_phase=PHASE_FAILED;
        }
    }

    g_lastWorld=world;
}

static void init_settings(void)
{
    u32 i;
    static const char *keys[6]={"phase","target_slot","in_world","char_select","logout_to_select_ms","total_ms"};
    static const char *labels[6]={"Phase","Target slot","In world","Character select","Logout -> select ms","Total switch ms"};
    if(g_descReady) return;
    for(i=0u;i<6u;i++){
        W112_ControlSettingV1 *s=&g_settings[i];
        s->struct_size=sizeof(*s);s->setting_id=i+1u;s->key=keys[i];s->label=labels[i];
        s->type=(i==2u||i==3u)?W112_CTL_BOOL:W112_CTL_INT;
        s->default_value.u32=0u;s->min_value.u32=0u;s->max_value.u32=2147483647u;s->step.u32=1u;
        s->flags=W112_CTL_READ_ONLY|W112_CTL_LIVE;s->enum_options=0;s->enum_option_count=0u;
    }
    g_settings[2].max_value.u32=1u;g_settings[3].max_value.u32=1u;
    g_descReady=1u;
}

static int W112_CTL_STDCALL get_value(w112_u32 id,W112_ControlValueV1 *v)
{
    if(!v) return 0;
    if(id==1u)v->u32=g_phase;
    else if(id==2u)v->u32=g_targetSlot;
    else if(id==3u)v->u32=g_world;
    else if(id==4u)v->u32=g_glueVisible;
    else if(id==5u)v->u32=g_elapsedToGlue;
    else if(id==6u)v->u32=g_elapsedTotal;
    else return 0;
    return 1;
}

static int W112_CTL_STDCALL set_value(w112_u32 id,const W112_ControlValueV1 *v)
{
    (void)id;(void)v;return 0;
}

static const W112_ControlModuleV1 g_module={
    W112_CONTROL_API_V1,sizeof(W112_ControlModuleV1),
    "characterswitchdiag","Character Switch Diag",0x00010000u,
    6u,g_settings,get_value,set_value
};

DLLEXPORT const W112_ControlModuleV1 * W112_CTL_STDCALL W112_Control_GetModuleV1(void)
{
    init_settings();return &g_module;
}

BOOL32 STDCALL DllMain(void *module,u32 reason,void *reserved)
{
    (void)module;(void)reserved;
    if(reason==1u){
        SetTimerFn setTimer;
        reset_run();g_lastWorld=read32(WOW_OBJMGR)?1u:0u;g_world=g_lastWorld;
        setTimer=(SetTimerFn)(ptr32)read32(WOW_IAT_SETTIMER);
        if(setTimer) g_timer=setTimer(0,0u,TIMER_MS,tick);
    }else if(reason==0u){
        KillTimerFn killTimer=(KillTimerFn)(ptr32)read32(WOW_IAT_KILLTIMER);
        if(killTimer&&g_timer) killTimer(0,g_timer);
        g_timer=0u;
    }
    return 1;
}
