/*
 * WoWOpenerUIRecovery_5875_v1.c
 *
 * World of Warcraft 1.12.1 build 5875, Windows x86 only.
 * Diagnostic/recovery companion for stale Backstab/Ambush action-button state.
 *
 * Scope:
 *   - never changes range, facing, movement, packets, GCD or opener timing;
 *   - manual "Clear stuck opener" only clears stale client action GUID/UI state
 *     when no client spell is pending/casting;
 *   - optional auto-clear is OFF by default and requires Backstab/Ambush evidence,
 *     an idle cast state and a configurable grace period;
 *   - exposes counters and last observed opener through W112_CONTROL_API_V1.
 */
#if !defined(_M_IX86) && !defined(__i386__)
#error WoWOpenerUIRecovery is for World of Warcraft 1.12.1 build 5875 x86 only.
#endif

#include "../common/W112ControlAPI.h"

#if defined(_MSC_VER)
#define STDCALL __stdcall
#pragma comment(linker, "/EXPORT:W112_Control_GetModuleV1=_W112_Control_GetModuleV1@0")
#else
#define STDCALL __attribute__((stdcall))
#endif

typedef unsigned char u8;
typedef unsigned int u32;
typedef int BOOL32;
typedef void *HWND32;
typedef u32 UINT32;
typedef u32 UINT_PTR32;
typedef void (STDCALL *TimerProc32)(HWND32,UINT32,UINT_PTR32,u32);
typedef UINT_PTR32 (STDCALL *SetTimerFn)(HWND32,UINT_PTR32,UINT32,TimerProc32);
typedef BOOL32 (STDCALL *KillTimerFn)(HWND32,UINT_PTR32);
typedef u32 (STDCALL *GetTickCountFn)(void);

#define DLL_PROCESS_DETACH 0u
#define DLL_PROCESS_ATTACH 1u

#define ADDR_OBJMGR_GLOBAL              0x00B41414u
#define CLIENT_PENDING_SPELLCAST        0x00CEAC48u
#define CLIENT_CASTING_SPELL_ID         0x00CECA88u
#define CLIENT_CAST_HANDLE              0x00CECA8Cu
#define CLIENT_CURRENT_ACTION_GUID_LO   0x00CECAB0u
#define CLIENT_CURRENT_ACTION_GUID_HI   0x00CECAB4u
#define CLIENT_PREV_CASTING_SPELL_ID    0x00CECAA8u
#define CLIENT_PREV_ACTION_GUID_LO      0x00CECB20u
#define CLIENT_PREV_ACTION_GUID_HI      0x00CECB24u

#define WOW_IAT_GETTICKCOUNT 0x007FF310u
#define WOW_IAT_SETTIMER     0x007FF4F4u
#define WOW_IAT_KILLTIMER    0x007FF4F8u

#define TIMER_PERIOD_MS 20u
#define WORLD_SETTLE_MS 1500u
#define VERSION_1_0 0x00010000u

#define SETTING_CLEAR_NOW      1u
#define SETTING_AUTO_CLEAR     2u
#define SETTING_GRACE_MS       3u
#define SETTING_CLEAR_COUNT    4u
#define SETTING_ACTIVE_SKIPS   5u
#define SETTING_LAST_OPENER    6u

static volatile UINT_PTR32 g_timerId=0u;
static volatile u32 g_cfgAutoClear=0u;
static volatile u32 g_cfgGraceMs=300u;
static volatile u32 g_clearCount=0u;
static volatile u32 g_activeSkips=0u;
static volatile u32 g_lastOpener=0u;
static volatile u32 g_watchStart=0u;
static volatile u32 g_watch=0u;
static volatile u32 g_worldManager=0u;
static volatile u32 g_worldSince=0u;
static W112_ControlSettingV1 g_settings[6];
static volatile u32 g_descReady=0u;

static u32 read_u32(u32 a){return *(volatile u32*)a;}
static void write_u32(u32 a,u32 v){*(volatile u32*)a=v;}
static void *iat(u32 a){return (void*)read_u32(a);}
static u32 tick_now(void){GetTickCountFn f=(GetTickCountFn)iat(WOW_IAT_GETTICKCOUNT);return f?f():0u;}
/* Avoid observing/clearing stale opener state immediately after a world rebuild.
   Manager identity alone is not a full BG detector; never write unless settled. */
static int world_stable(u32 now){
 u32 mgr=read_u32(ADDR_OBJMGR_GLOBAL);
 if(!mgr){g_worldManager=0u;g_worldSince=0u;g_watch=0u;return 0;}
 if(mgr!=g_worldManager || !g_worldSince){g_worldManager=mgr;g_worldSince=now?now:1u;g_watch=0u;return 0;}
 return (u32)(now-g_worldSince)>=WORLD_SETTLE_MS;
}

static int isBackstab(u32 s){
 return s==53u||s==2589u||s==2590u||s==2591u||s==8721u||s==11279u||s==11280u||s==11281u;
}
static int isAmbush(u32 s){
 return s==8676u||s==8724u||s==8725u||s==11267u||s==11268u||s==11269u;
}
static int isOpener(u32 s){return isBackstab(s)||isAmbush(s);}

static int action_guid_present(void){
 return read_u32(CLIENT_CURRENT_ACTION_GUID_LO)||read_u32(CLIENT_CURRENT_ACTION_GUID_HI)||
        read_u32(CLIENT_PREV_ACTION_GUID_LO)||read_u32(CLIENT_PREV_ACTION_GUID_HI);
}
static int cast_active(void){
 return read_u32(CLIENT_PENDING_SPELLCAST)||read_u32(CLIENT_CASTING_SPELL_ID)||read_u32(CLIENT_CAST_HANDLE);
}
static u32 opener_evidence(void){
 u32 s=read_u32(CLIENT_CASTING_SPELL_ID);
 u32 p=read_u32(CLIENT_PREV_CASTING_SPELL_ID);
 if(isOpener(s))return s;
 if(isOpener(p))return p;
 return 0u;
}

/* Deliberately UI-only: do not clear pending cast, cast handle, targeting,
   packet state, GCD or PositionalSpoof private state. */
static int clear_stale_ui(int manual){
 u32 ev;
 if(!world_stable(tick_now()))return 0;
 if(cast_active()){g_activeSkips++;return 0;}
 if(!action_guid_present()){g_watch=0u;return 0;}
 ev=opener_evidence();
 if(!manual && !ev)return 0;
 if(ev)g_lastOpener=ev;
 write_u32(CLIENT_CURRENT_ACTION_GUID_LO,0u);
 write_u32(CLIENT_CURRENT_ACTION_GUID_HI,0u);
 write_u32(CLIENT_PREV_ACTION_GUID_LO,0u);
 write_u32(CLIENT_PREV_ACTION_GUID_HI,0u);
 if(isOpener(read_u32(CLIENT_PREV_CASTING_SPELL_ID)))write_u32(CLIENT_PREV_CASTING_SPELL_ID,0u);
 g_clearCount++;
 g_watch=0u;
 return 1;
}

static void STDCALL TimerProc(HWND32 hwnd,UINT32 msg,UINT_PTR32 id,u32 unused){
 u32 now,ev;
 (void)hwnd;(void)msg;(void)id;(void)unused;
 now=tick_now();
 if(!world_stable(now)){g_watch=0u;return;}
 ev=opener_evidence();
 if(ev){
  g_lastOpener=ev;
  if(action_guid_present()&&!g_watch){g_watch=1u;g_watchStart=now;}
 }
 if(!action_guid_present()){g_watch=0u;return;}
 if(g_cfgAutoClear&&g_watch&&!cast_active()&&(u32)(now-g_watchStart)>=g_cfgGraceMs)
  clear_stale_ui(0);
}

static void init_desc(void){
 W112_ControlSettingV1*s;
 if(g_descReady)return;
 s=&g_settings[0];s->struct_size=sizeof(*s);s->setting_id=SETTING_CLEAR_NOW;s->key="clear_now";s->label="Clear stuck opener";s->type=W112_CTL_BOOL;s->default_value.u32=0u;s->min_value.u32=0u;s->max_value.u32=1u;s->step.u32=1u;s->flags=W112_CTL_LIVE;s->enum_options=0;s->enum_option_count=0u;
 s=&g_settings[1];s->struct_size=sizeof(*s);s->setting_id=SETTING_AUTO_CLEAR;s->key="auto_clear";s->label="Auto clear";s->type=W112_CTL_BOOL;s->default_value.u32=0u;s->min_value.u32=0u;s->max_value.u32=1u;s->step.u32=1u;s->flags=W112_CTL_LIVE;s->enum_options=0;s->enum_option_count=0u;
 s=&g_settings[2];s->struct_size=sizeof(*s);s->setting_id=SETTING_GRACE_MS;s->key="grace_ms";s->label="Auto grace (ms)";s->type=W112_CTL_INT;s->default_value.i32=300;s->min_value.i32=100;s->max_value.i32=1000;s->step.i32=50;s->flags=W112_CTL_LIVE;s->enum_options=0;s->enum_option_count=0u;
 s=&g_settings[3];s->struct_size=sizeof(*s);s->setting_id=SETTING_CLEAR_COUNT;s->key="clear_count";s->label="UI clears";s->type=W112_CTL_INT;s->default_value.i32=0;s->min_value.i32=0;s->max_value.i32=2147483647;s->step.i32=1;s->flags=W112_CTL_READ_ONLY;s->enum_options=0;s->enum_option_count=0u;
 s=&g_settings[4];s->struct_size=sizeof(*s);s->setting_id=SETTING_ACTIVE_SKIPS;s->key="active_skips";s->label="Active-cast skips";s->type=W112_CTL_INT;s->default_value.i32=0;s->min_value.i32=0;s->max_value.i32=2147483647;s->step.i32=1;s->flags=W112_CTL_READ_ONLY;s->enum_options=0;s->enum_option_count=0u;
 s=&g_settings[5];s->struct_size=sizeof(*s);s->setting_id=SETTING_LAST_OPENER;s->key="last_opener";s->label="Last opener spell ID";s->type=W112_CTL_INT;s->default_value.i32=0;s->min_value.i32=0;s->max_value.i32=20000;s->step.i32=1;s->flags=W112_CTL_READ_ONLY;s->enum_options=0;s->enum_option_count=0u;
 g_descReady=1u;
}
static int W112_CTL_STDCALL ctl_get(w112_u32 id,W112_ControlValueV1*out){
 if(!out)return 0;
 if(id==SETTING_CLEAR_NOW){out->u32=0u;return 1;}
 if(id==SETTING_AUTO_CLEAR){out->u32=g_cfgAutoClear;return 1;}
 if(id==SETTING_GRACE_MS){out->i32=(w112_i32)g_cfgGraceMs;return 1;}
 if(id==SETTING_CLEAR_COUNT){out->i32=(w112_i32)g_clearCount;return 1;}
 if(id==SETTING_ACTIVE_SKIPS){out->i32=(w112_i32)g_activeSkips;return 1;}
 if(id==SETTING_LAST_OPENER){out->i32=(w112_i32)g_lastOpener;return 1;}
 return 0;
}
static int W112_CTL_STDCALL ctl_set(w112_u32 id,const W112_ControlValueV1*v){
 if(!v)return 0;
 if(id==SETTING_CLEAR_NOW){if(v->u32>1u)return 0;if(v->u32)clear_stale_ui(1);return 1;}
 if(id==SETTING_AUTO_CLEAR){if(v->u32>1u)return 0;g_cfgAutoClear=v->u32;g_watch=0u;return 1;}
 if(id==SETTING_GRACE_MS){if(v->i32<100||v->i32>1000)return 0;g_cfgGraceMs=(u32)v->i32;return 1;}
 return 0;
}
static const W112_ControlModuleV1 g_module={
 W112_CONTROL_API_V1,sizeof(W112_ControlModuleV1),"opener_ui_recovery","Opener UI Recovery",VERSION_1_0,6u,g_settings,ctl_get,ctl_set
};
W112_CTL_EXPORT const W112_ControlModuleV1* W112_CTL_STDCALL W112_Control_GetModuleV1(void){init_desc();return &g_module;}

int STDCALL DllMain(void*h,u32 reason,void*r){
 SetTimerFn st;KillTimerFn kt;(void)h;(void)r;
 if(reason==DLL_PROCESS_ATTACH){init_desc();st=(SetTimerFn)iat(WOW_IAT_SETTIMER);if(st)g_timerId=st(0,0,TIMER_PERIOD_MS,TimerProc);}
 else if(reason==DLL_PROCESS_DETACH){kt=(KillTimerFn)iat(WOW_IAT_KILLTIMER);if(g_timerId&&kt)kt(0,g_timerId);g_timerId=0u;}
 return 1;
}
