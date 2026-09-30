/*
 * WoWCharacterSwitchDiag 5875 v2
 * FAST diagnostic: DisconnectFromServer -> AutoLoginBridge relogin -> slot -> world.
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
#define FAST_TIMEOUT_MS 45000u

typedef BOOL (__fastcall *FrameScriptExecuteFn)(const char*,const char*);
typedef const char* (__fastcall *FrameScriptGetTextFn)(const char*,int,DWORD);
typedef int (__stdcall *BridgeRequestFn)(void);
typedef int (__stdcall *BridgeStateFn)(void);

enum {
    PHASE_IDLE=0, PHASE_WAIT_LOGOUT=1, PHASE_CHAR_SELECT=2, PHASE_ENTERING=3,
    PHASE_COMPLETE=4, PHASE_FAILED=5, PHASE_FAST_DISCONNECT=6,
    PHASE_FAST_RELOGIN=7
};

static volatile DWORD g_phase=PHASE_IDLE,g_targetSlot=0,g_elapsedToGlue=0,g_elapsedTotal=0;
static volatile DWORD g_lastError=0,g_world=0,g_glueVisible=0,g_fast=0;
static UINT_PTR g_timer=0;
static DWORD g_startedAt=0,g_glueAt=0,g_enterIssuedAt=0,g_lastUiRefresh=0,g_lastWorld=0;
static W112_ControlSettingV1 g_settings[7];
static DWORD g_descReady=0;
int _fltused=0;

static DWORD rd32(DWORD a){return *(volatile DWORD*)a;}
static char *app(char*p,const char*s){while(s&&*s)*p++=*s++;return p;}
static char *appu(char*p,DWORD v){char t[16];int n=0;if(!v){*p++='0';return p;}while(v&&n<15){t[n++]=(char)('0'+v%10);v/=10;}while(n)*p++=t[--n];return p;}
static int eq(const char*a,const char*b){if(!a||!b)return 0;while(*a&&*b){if(*a++!=*b++)return 0;}return *a==0&&*b==0;}

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
      "local t=f:CreateFontString(nil,'OVERLAY','GameFontNormal');t:SetPoint('TOP',f,'TOP',0,-12);t:SetText('Character Switch Diagnostic V2');"
      "local st=f:CreateFontString('W112CSDStatus','OVERLAY','GameFontNormalSmall');st:SetPoint('TOPLEFT',f,'TOPLEFT',12,-36);st:SetWidth(416);st:SetJustifyH('LEFT');st:SetText('idle');"
      "local function B(n,x,y,w,txt,cmd)local b=CreateFrame('Button',n,f,'UIPanelButtonTemplate');b:SetWidth(w);b:SetHeight(24);b:SetPoint('BOTTOMLEFT',f,'BOTTOMLEFT',x,y);b:SetText(txt);b:SetScript('OnClick',function()W112_CSD_CMD=cmd end)end;"
      "B('W112CSDStock',12,42,92,'Stock logout','stock');B('W112CSDSlot1',112,42,92,'Switch slot 1','slot1');B('W112CSDSlot2',212,42,92,'Switch slot 2','slot2');"
      "B('W112CSDFast1',60,12,140,'FAST slot 1','fast1');B('W112CSDFast2',230,12,140,'FAST slot 2','fast2');"
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
    p=app(p," err=");p=appu(p,g_lastError);p=app(p,"\\nFAST nie uzywa Logout(); wynik zapisuje CharacterSwitchDiag.log') end");*p=0;execs(b);
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
static int request_relogin(void)
{
    HMODULE h=GetModuleHandleA("WoWAutoLoginBridge_5875_v1.dll");
    BridgeRequestFn fn;if(!h)return 0;fn=(BridgeRequestFn)GetProcAddress(h,"W112_AutoLoginBridge_RequestRelogin");return fn?fn():0;
}
static int bridge_state(void)
{
    HMODULE h=GetModuleHandleA("WoWAutoLoginBridge_5875_v1.dll");
    BridgeStateFn fn;if(!h)return -99;fn=(BridgeStateFn)GetProcAddress(h,"W112_AutoLoginBridge_GetReloginState");return fn?fn():-98;
}
static void begin_stock(DWORD now,DWORD slot)
{
    reset_run();g_targetSlot=slot;g_startedAt=now;g_phase=PHASE_WAIT_LOGOUT;log_line("STOCK_BEGIN",now,slot);
    execs("if type(Logout)=='function' then Logout() end");
}
static void begin_fast(DWORD now,DWORD slot)
{
    const char*v;reset_run();g_fast=1;g_targetSlot=slot;g_startedAt=now;g_phase=PHASE_FAST_DISCONNECT;
    log_line("FAST_BEGIN",now,slot);
    execs("W112_CSD_DISC='0';if type(DisconnectFromServer)=='function' then W112_CSD_DISC='1';DisconnectFromServer() else W112_CSD_DISC='-1' end");
    v=gettextv("W112_CSD_DISC");
    if(!v||v[0]!='1'){g_lastError=10;g_phase=PHASE_FAILED;log_line("FAST_NO_DISCONNECT_API",now,10);}
    else log_line("FAST_DISCONNECT_ISSUED",now,slot);
}
static void poll_cmd(DWORD now)
{
    const char*c=gettextv("W112_CSD_CMD");if(!c||!c[0])return;execs("W112_CSD_CMD=''");
    if(eq(c,"stock"))begin_stock(now,0);else if(eq(c,"slot1"))begin_stock(now,1);else if(eq(c,"slot2"))begin_stock(now,2);
    else if(eq(c,"fast1"))begin_fast(now,1);else if(eq(c,"fast2"))begin_fast(now,2);
}
static VOID CALLBACK tick(HWND h,UINT m,UINT_PTR id,DWORD now)
{
    DWORD world=rd32(WOW_OBJMGR)?1:0;(void)h;(void)m;(void)id;g_world=world;
    if(world){
        g_glueVisible=0;ensure_ui();poll_cmd(now);
        if(g_phase==PHASE_ENTERING && !g_lastWorld){g_elapsedTotal=g_startedAt?now-g_startedAt:0;g_phase=PHASE_COMPLETE;log_line("WORLD_ENTERED",now,g_elapsedTotal);}
        update_ui(now);
    }else{
        probe_glue();
        if(g_phase==PHASE_FAST_DISCONNECT){
            int ok;g_elapsedToGlue=g_startedAt?now-g_startedAt:0;log_line("WORLD_CLEARED",now,g_elapsedToGlue);
            ok=request_relogin();if(!ok){g_lastError=20;g_phase=PHASE_FAILED;log_line("RELOGIN_REQUEST_REJECTED",now,(DWORD)bridge_state());}
            else {g_phase=PHASE_FAST_RELOGIN;log_line("RELOGIN_REQUESTED",now,(DWORD)bridge_state());}
        }else if(g_phase==PHASE_FAST_RELOGIN){
            if(g_glueVisible){g_elapsedToGlue=g_startedAt?now-g_startedAt:0;g_glueAt=now;g_phase=PHASE_CHAR_SELECT;select_slot(g_targetSlot);log_line("CHAR_SELECT_READY",now,g_elapsedToGlue);}
            else if(g_startedAt && now-g_startedAt>FAST_TIMEOUT_MS){g_lastError=21;g_phase=PHASE_FAILED;log_line("FAST_TIMEOUT",now,(DWORD)bridge_state());}
        }else if(g_phase==PHASE_WAIT_LOGOUT && g_glueVisible){
            g_elapsedToGlue=g_startedAt?now-g_startedAt:0;g_glueAt=now;g_phase=PHASE_CHAR_SELECT;if(g_targetSlot)select_slot(g_targetSlot);log_line("STOCK_CHAR_SELECT",now,g_elapsedToGlue);
        }else if(g_phase==PHASE_CHAR_SELECT && g_targetSlot && g_glueVisible && now-g_glueAt>=SELECT_SETTLE_MS){
            enter_slot(g_targetSlot);g_enterIssuedAt=now;g_phase=PHASE_ENTERING;log_line("ENTER_SLOT",now,g_targetSlot);
        }else if(g_phase==PHASE_ENTERING && g_enterIssuedAt && now-g_enterIssuedAt>ENTER_TIMEOUT_MS){
            g_lastError=30;g_phase=PHASE_FAILED;log_line("ENTER_TIMEOUT",now,g_targetSlot);
        }
    }
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
static const W112_ControlModuleV1 mod={W112_CONTROL_API_V1,sizeof(W112_ControlModuleV1),"characterswitchdiag","Character Switch Diag",0x00020000u,7,g_settings,getv,setv};
__declspec(dllexport) const W112_ControlModuleV1* W112_CTL_STDCALL W112_Control_GetModuleV1(void){init_settings();return &mod;}
BOOL WINAPI DllMain(HMODULE h,DWORD r,LPVOID x)
{
    (void)x;if(r==DLL_PROCESS_ATTACH){DisableThreadLibraryCalls(h);reset_run();g_lastWorld=rd32(WOW_OBJMGR)?1:0;g_world=g_lastWorld;log_line("LOAD_V2",GetTickCount(),0);g_timer=SetTimer(NULL,0,TIMER_MS,tick);}
    else if(r==DLL_PROCESS_DETACH&&g_timer)KillTimer(NULL,g_timer);return TRUE;
}
