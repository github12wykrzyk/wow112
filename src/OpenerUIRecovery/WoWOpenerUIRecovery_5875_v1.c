/*
 * WoWOpenerUIRecovery_5875_v1.c
 *
 * World of Warcraft 1.12.1 build 5875, Windows x86 only.
 * Diagnostic/recovery companion for stale Backstab/Ambush action-button state.
 *
 * Scope:
 *   - never changes range, facing, movement, packets, GCD or opener timing;
 *   - manual recovery follows the native 5875 SpellStopCasting path (not ESC),
 *     restricted to opener evidence; no broad raw cast-state memory erasure;
 *   - auto-clear is ON in the Parallel candidate; only orphaned opener UI state after
 *     every active/queued cast has ended can be cancelled (250 ms default);
 *   - no automatic cancellation of an active/queued spell, even on timeout,
 *     protecting energy holds and preventing unintended active-cast interrupts;
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
typedef void (__cdecl *StopTargetingFn)(void);
typedef void (__cdecl *StopQueuedSpellFn)(void);
typedef void (__fastcall *StopActiveCastFn)(u32,u32,u32);

#define DLL_PROCESS_DETACH 0u
#define DLL_PROCESS_ATTACH 1u

#define ADDR_OBJMGR_GLOBAL              0x00B41414u
#define CLIENT_PENDING_SPELLCAST        0x00CEAC48u
#define CLIENT_QUEUED_SPELL_STATE       0x00CEAC30u
#define CLIENT_CASTING_SPELL_ID         0x00CECA88u
#define CLIENT_CAST_HANDLE              0x00CECA8Cu
#define CLIENT_CURRENT_ACTION_GUID_LO   0x00CECAB0u
#define CLIENT_CURRENT_ACTION_GUID_HI   0x00CECAB4u
#define CLIENT_PREV_CASTING_SPELL_ID    0x00CECAA8u
#define CLIENT_PREV_ACTION_GUID_LO      0x00CECB20u
#define CLIENT_PREV_ACTION_GUID_HI      0x00CECB24u
#define CLIENT_TARGETING_STATE          0x00CECAC0u
#define CLIENT_CAST_MISC                0x00CECAACu
/* Binary-audited from WoW.exe build 5875 (exact active test EXE):
   Lua SpellStopCasting dispatcher 0x006E6E80 uses 0x006EA080 for a queued
   spell, otherwise 0x006E4940(ECX=0, EDX=1, stack=0x1C) for active casts.
   0x006E4900 is SpellStopTargeting, NOT a general casting cancel. */
#define SPELL_STOP_TARGETING_INTERNAL   0x006E4900u
#define SPELL_STOP_QUEUED_INTERNAL      0x006EA080u
#define SPELL_STOP_CASTING_INTERNAL     0x006E4940u

#define WOW_IAT_GETTICKCOUNT 0x007FF310u
#define WOW_IAT_SETTIMER     0x007FF4F4u
#define WOW_IAT_KILLTIMER    0x007FF4F8u

#define TIMER_PERIOD_MS 20u
#define WORLD_SETTLE_MS 1500u
#define VERSION_1_1 0x00010300u

#define SETTING_CLEAR_NOW      1u
#define SETTING_AUTO_CLEAR     2u
#define SETTING_GRACE_MS       3u
#define SETTING_CLEAR_COUNT    4u
#define SETTING_ACTIVE_SKIPS   5u
#define SETTING_LAST_OPENER    6u

static volatile UINT_PTR32 g_timerId=0u;
static volatile u32 g_cfgAutoClear=1u;
static volatile u32 g_cfgGraceMs=250u;
static volatile u32 g_clearCount=0u;
static volatile u32 g_activeSkips=0u;
static volatile u32 g_lastOpener=0u;
static volatile u32 g_watchStart=0u;
static volatile u32 g_watch=0u;
static volatile u32 g_watchPending=0u,g_watchSpell=0u,g_watchHandle=0u,g_watchQueued=0u;
static volatile u32 g_watchPrevious=0u,g_watchGuidLo=0u,g_watchGuidHi=0u;
static volatile u32 g_watchPrevGuidLo=0u,g_watchPrevGuidHi=0u,g_watchTargeting=0u;
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

/* Native SpellStopCasting in exact 5875 binary dispatches differently for
   queued and active spells. 0x006E4900 only stops targeting; invoking it alone
   did not release the reported yellow-border spell lock. Never synthesize ESC. */
static int clear_stale_ui(int manual){
 u32 ev,sid,prev,pending,handle,targeting,queued,hasGuid,now=tick_now();
 int invoked=0;
 if(!world_stable(now))return 0;
 sid=read_u32(CLIENT_CASTING_SPELL_ID);
 prev=read_u32(CLIENT_PREV_CASTING_SPELL_ID);
 pending=read_u32(CLIENT_PENDING_SPELLCAST);
 handle=read_u32(CLIENT_CAST_HANDLE);
 queued=read_u32(CLIENT_QUEUED_SPELL_STATE);
 targeting=(u32)*(volatile unsigned short*)CLIENT_TARGETING_STATE;
 hasGuid=(u32)action_guid_present();
 ev=isOpener(sid)?sid:(isOpener(prev)?prev:0u);
 if(!ev){if(manual)g_activeSkips++;return 0;}
 if(!pending&&!sid&&!handle&&!queued&&!targeting&&!hasGuid){g_watch=0u;return 0;}
 /* Reject casts of any different spell even when the previous spell was an opener. */
 if(sid && !isOpener(sid)){if(manual)g_activeSkips++;return 0;}
 if((pending||handle||queued) && !isOpener(sid) && !hasGuid && !targeting){
  if(manual)g_activeSkips++;
  return 0;
 }
 /* Auto recovery is strictly cosmetic/idle: never cancel an active cast,
    pending cast, queued spell or energy-gated opener. The manual GUI button
    retains the native SpellStopCasting fallback for explicit user recovery. */
 if(!manual){
  if(pending||sid||handle||queued)return 0;
  if(!g_watch || (u32)(now-g_watchStart)<g_cfgGraceMs)return 0;
 }
 if(queued){
  /* Matches the queued-spell branch in native SpellStopCasting. */
  ((StopQueuedSpellFn)SPELL_STOP_QUEUED_INTERNAL)();
  invoked=1;
 }else if(isOpener(sid)){
  /* Exact 5875 native SpellStopCasting active-spell branch; fastcall cleans
     its single stack argument with RET 4. Native code handles the cast
     handle and cancellation packet, unlike raw memory writes. */
  ((StopActiveCastFn)SPELL_STOP_CASTING_INTERNAL)(0u,1u,0x1Cu);
  invoked=1;
 }else if(targeting){
  ((StopTargetingFn)SPELL_STOP_TARGETING_INTERNAL)();
  invoked=1;
 }else if(hasGuid && !pending && !handle){
  /* Only clear truly idle cosmetic state when no native action exists. */
  write_u32(CLIENT_CURRENT_ACTION_GUID_LO,0u);
  write_u32(CLIENT_CURRENT_ACTION_GUID_HI,0u);
  write_u32(CLIENT_PREV_ACTION_GUID_LO,0u);
  write_u32(CLIENT_PREV_ACTION_GUID_HI,0u);
  invoked=1;
 }
 if(!invoked){if(manual)g_activeSkips++;return 0;}
 g_lastOpener=ev;
 g_clearCount++; /* Counts attempts, not confirmed in-game recovery. */
 g_watch=0u;
 return 1;
}

static void STDCALL TimerProc(HWND32 hwnd,UINT32 msg,UINT_PTR32 id,u32 unused){
 u32 now,pending,sid,handle,queued,prev,alo,ahi,palo,pahi,targeting,age;
 (void)hwnd;(void)msg;(void)id;(void)unused;
 now=tick_now();
 if(!world_stable(now)){g_watch=0u;return;}
 pending=read_u32(CLIENT_PENDING_SPELLCAST);
 sid=read_u32(CLIENT_CASTING_SPELL_ID);
 handle=read_u32(CLIENT_CAST_HANDLE);
 queued=read_u32(CLIENT_QUEUED_SPELL_STATE);
 prev=read_u32(CLIENT_PREV_CASTING_SPELL_ID);
 alo=read_u32(CLIENT_CURRENT_ACTION_GUID_LO);
 ahi=read_u32(CLIENT_CURRENT_ACTION_GUID_HI);
 palo=read_u32(CLIENT_PREV_ACTION_GUID_LO);
 pahi=read_u32(CLIENT_PREV_ACTION_GUID_HI);
 targeting=(u32)*(volatile unsigned short*)CLIENT_TARGETING_STATE;
 if(isOpener(sid))g_lastOpener=sid;
 else if(isOpener(prev))g_lastOpener=prev;
 /* Only monitor an opener and a real client-side action/cast/targeting state. */
 if((!isOpener(sid)&&!isOpener(prev)) ||
    !(pending||sid||handle||queued||alo||ahi||palo||pahi||targeting)){
  g_watch=0u;return;
 }
 /* Do not mistake a progressing legitimate cast for a stalled action. */
 if(!g_watch || pending!=g_watchPending || sid!=g_watchSpell ||
    handle!=g_watchHandle || queued!=g_watchQueued || prev!=g_watchPrevious ||
    alo!=g_watchGuidLo || ahi!=g_watchGuidHi ||
    palo!=g_watchPrevGuidLo || pahi!=g_watchPrevGuidHi ||
    targeting!=g_watchTargeting){
  g_watch=1u;g_watchStart=now;
  g_watchPending=pending;g_watchSpell=sid;g_watchHandle=handle;g_watchQueued=queued;
  g_watchPrevious=prev;g_watchGuidLo=alo;g_watchGuidHi=ahi;
  g_watchPrevGuidLo=palo;g_watchPrevGuidHi=pahi;
  g_watchTargeting=targeting;
  return;
 }
 if(!g_cfgAutoClear)return;
 age=(u32)(now-g_watchStart);
 if(age<g_cfgGraceMs)return;
 /* The timer is an observer until the entire cast/queue pipeline is idle.
    Never interpret a long, unchanged active cast as a stuck yellow border. */
 if(pending||sid||handle||queued)return;
 clear_stale_ui(0);
}

static void init_desc(void){
 W112_ControlSettingV1*s;
 if(g_descReady)return;
 s=&g_settings[0];s->struct_size=sizeof(*s);s->setting_id=SETTING_CLEAR_NOW;s->key="clear_now";s->label="Clear stuck opener";s->type=W112_CTL_BOOL;s->default_value.u32=0u;s->min_value.u32=0u;s->max_value.u32=1u;s->step.u32=1u;s->flags=W112_CTL_LIVE;s->enum_options=0;s->enum_option_count=0u;
 s=&g_settings[1];s->struct_size=sizeof(*s);s->setting_id=SETTING_AUTO_CLEAR;s->key="auto_clear";s->label="Auto clear";s->type=W112_CTL_BOOL;s->default_value.u32=1u;s->min_value.u32=0u;s->max_value.u32=1u;s->step.u32=1u;s->flags=W112_CTL_LIVE;s->enum_options=0;s->enum_option_count=0u;
 s=&g_settings[2];s->struct_size=sizeof(*s);s->setting_id=SETTING_GRACE_MS;s->key="grace_ms";s->label="Auto grace (ms)";s->type=W112_CTL_INT;s->default_value.i32=250;s->min_value.i32=150;s->max_value.i32=1000;s->step.i32=50;s->flags=W112_CTL_LIVE;s->enum_options=0;s->enum_option_count=0u;
 s=&g_settings[3];s->struct_size=sizeof(*s);s->setting_id=SETTING_CLEAR_COUNT;s->key="clear_count";s->label="Cancel attempts";s->type=W112_CTL_INT;s->default_value.i32=0;s->min_value.i32=0;s->max_value.i32=2147483647;s->step.i32=1;s->flags=W112_CTL_READ_ONLY;s->enum_options=0;s->enum_option_count=0u;
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
 if(id==SETTING_GRACE_MS){if(v->i32<150||v->i32>1000)return 0;g_cfgGraceMs=(u32)v->i32;return 1;}
 return 0;
}
static const W112_ControlModuleV1 g_module={
 W112_CONTROL_API_V1,sizeof(W112_ControlModuleV1),"opener_ui_recovery","Opener UI Recovery",VERSION_1_1,6u,g_settings,ctl_get,ctl_set
};
W112_CTL_EXPORT const W112_ControlModuleV1* W112_CTL_STDCALL W112_Control_GetModuleV1(void){init_desc();return &g_module;}

int STDCALL DllMain(void*h,u32 reason,void*r){
 SetTimerFn st;KillTimerFn kt;(void)h;(void)r;
 if(reason==DLL_PROCESS_ATTACH){init_desc();st=(SetTimerFn)iat(WOW_IAT_SETTIMER);if(st)g_timerId=st(0,0,TIMER_PERIOD_MS,TimerProc);}
 else if(reason==DLL_PROCESS_DETACH){kt=(KillTimerFn)iat(WOW_IAT_KILLTIMER);if(g_timerId&&kt)kt(0,g_timerId);g_timerId=0u;}
 return 1;
}
