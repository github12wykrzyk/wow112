/* Parallel-only experimental PvE continuous rear pose.
   WoW 1.12.1 build 5875, Windows x86. Newly written source.
   Only NPC (type 3), hostile reaction 1..3, actual distance <=8yd.
   No hooks, no cast replay, no client GCD edits, no player-target PvP.
   GUI-window messages are dispatched on the game window thread, not the DLL loader thread.
   The client object pose is restored synchronously after each pulse.
   Server acceptance of the synthetic pose is not guaranteed. */
#if !defined(_M_IX86) && !defined(__i386__)
#error PvERear360 requires x86 WoW build 5875
#endif
#include "../common/W112ControlAPI.h"
#if defined(_MSC_VER)
#define STDCALL __stdcall
#define THISCALL __thiscall
#pragma comment(linker, "/EXPORT:W112_Control_GetModuleV1=_W112_Control_GetModuleV1@0")
#pragma comment(linker, "/EXPORT:PVERear360_GetStatus=_PVERear360_GetStatus@0")
#pragma comment(linker, "/EXPORT:PVERear360_GetPulseCount=_PVERear360_GetPulseCount@0")
#pragma comment(linker, "/EXPORT:PVERear360_GameWindowTick=_PVERear360_GameWindowTick@4")
#else
#define STDCALL __attribute__((stdcall))
#define THISCALL __attribute__((thiscall))
#endif
typedef unsigned char u8;
typedef unsigned int u32;
typedef int s32;
typedef void *HWND32;
typedef HWND32 (__fastcall *GetGameWindowFn)(int);
typedef u32 (STDCALL *RearThreadFn)(void*);
__declspec(dllimport) void* STDCALL CreateThread(void*,u32,RearThreadFn,void*,u32,u32*);
__declspec(dllimport) int STDCALL CloseHandle(void*);
__declspec(dllimport) void STDCALL Sleep(u32);
__declspec(dllimport) int STDCALL IsWindow(HWND32);
__declspec(dllimport) u32 STDCALL GetWindowThreadProcessId(HWND32,u32*);
__declspec(dllimport) u32 STDCALL GetCurrentProcessId(void);
__declspec(dllimport) int STDCALL PostMessageA(HWND32,u32,u32,s32);
__declspec(dllimport) u32 STDCALL GetTickCount(void);
typedef s32 (THISCALL *ReactionFn)(u32,u32);
#define OBJMGR 0x00B41414u
#define TARGET_LO 0x00B4E2D8u
#define TARGET_HI 0x00B4E2DCu
#define OBJ_TYPE 0x14u
#define OBJ_LO 0x30u
#define OBJ_HI 0x34u
#define OBJ_NEXT 0x3Cu
#define OBJ_X 0x9B8u
#define OBJ_Y 0x9BCu
#define OBJ_Z 0x9C0u
#define OBJ_O 0x9C4u
#define OM_FIRST 0xACu
#define OM_PLAYER_LO 0xC0u
#define OM_PLAYER_HI 0xC4u
#define GET_OBJECT_BY_GUID 0x00464870u
#define REACTION_FN 0x006061E0u
#define CASTING_SPELL_ID 0x00CECA88u
#define PENDING_CAST 0x00CEAC48u
#define SEND_MOVEMENT_WRAPPER 0x00600A10u
#define FN_GET_GAME_WINDOW 0x00435C30u
#define WM_W112_REAR_TICK 0x00008119u
#define REAR_DISTANCE 1.6f
#define REAL_MAX_RANGE_SQ 64.0f
#define PI_F 3.14159265358979323846f
#define TWO_PI_F 6.28318530717958647692f
#define SETTING_ENABLED 1u
#define SETTING_PERIOD 2u
#define STATUS_IDLE 0u
#define STATUS_ACTIVE 1u
#define STATUS_CAST_PAUSE 2u
#define STATUS_BUILD_MISMATCH 3u
#define STATUS_TIMER_ERROR 4u
#define STATUS_DISABLED 5u
#define STATUS_WAIT_WINDOW 6u
#define STATUS_THREAD_ERROR 7u
int _fltused=0;
static volatile u32 g_enabled=1u;
static volatile u32 g_period=100u;
static volatile u32 g_status=STATUS_IDLE;
static volatile u32 g_count=0u;
static volatile u32 g_timer=0u;
static volatile HWND32 g_timerWindow=0;
static volatile u32 g_stop=0u;
static volatile u32 g_lastTick=0u;
static volatile u32 g_needsRestore=0u;
static W112_ControlSettingV1 g_settings[2];
static volatile u32 g_descriptorsReady=0u;
static u32 read32(u32 a){return *(volatile u32*)a;}
static float readf(u32 a){return *(volatile float*)a;}
static int finitef(float v){union{float f;u32 x;}q;q.f=v;return (q.x&0x7F800000u)!=0x7F800000u;}
static float fcos1(float v){float r;__asm {
 fld v
 fcos
 fstp r
}return r;}
static float fsin1(float v){float r;__asm {
 fld v
 fsin
 fstp r
}return r;}
static float angle(float a){while(a<0.0f)a+=TWO_PI_F;while(a>=TWO_PI_F)a-=TWO_PI_F;return a;}
static int build5875(void){
 static const u8 sig[]={0x55,0x8B,0xEC,0x8B,0x45,0x08,0x8B,0x4D,0x0C,0x8B,0xD0,0x0B,0xD1};
 static const u8 windowSig[]={0x83,0xE9,0x00,0x74,0x15,0x49,0x74,0x0C,0x49,0x74,0x03,0x33,0xC0,0xC3};
 u32 i;for(i=0u;i<(u32)sizeof(sig);++i)if(*(volatile u8*)(GET_OBJECT_BY_GUID+i)!=sig[i])return 0;
 for(i=0u;i<(u32)sizeof(windowSig);++i)if(*(volatile u8*)(FN_GET_GAME_WINDOW+i)!=windowSig[i])return 0;
 return 1;
}
static u32 objectByGuid(u32 lo,u32 hi){
 u32 om=read32(OBJMGR),p,steps=0u;
 if(!om||(!lo&&!hi))return 0u;
 p=read32(om+OM_FIRST);
 while(p&&!(p&1u)&&++steps<=4096u){
  if(read32(p+OBJ_LO)==lo&&read32(p+OBJ_HI)==hi)return p;
  p=read32(p+OBJ_NEXT);
 }
 return 0u;
}
static u32 localPlayer(void){
 u32 om=read32(OBJMGR);
 if(!om)return 0u;
 return objectByGuid(read32(om+OM_PLAYER_LO),read32(om+OM_PLAYER_HI));
}
static u32 selectedTarget(void){return objectByGuid(read32(TARGET_LO),read32(TARGET_HI));}
/* Client native heartbeat wrapper, verified PositionalSpoof 5875 lineage. */
__declspec(naked) void STDCALL nativeHeartbeat(u32 unit){
 __asm{
  mov ecx,[esp+4]
  test ecx,ecx
  je hb_done
  push 0EEh
  mov eax,SEND_MOVEMENT_WRAPPER
  call eax
 hb_done:
  ret 4
 }
}
static void restoreHeartbeat(u32 pl){
 if(!g_needsRestore||!pl)return;
 if(read32(CASTING_SPELL_ID)||read32(PENDING_CAST))return;
 g_needsRestore=0u;
 nativeHeartbeat(pl);
}
static void STDCALL tick(HWND32 hwnd,u32 msg,u32 timer,u32 now){
 u32 pl,tg,lo,hi;
 float px,py,pz,po,tx,ty,tz,to,dx,dy,dz,x,y,z,o,a;
 (void)hwnd;(void)msg;(void)timer;
 if(g_stop||!g_timer||timer!=g_timer||hwnd!=g_timerWindow)return;
 if(!g_enabled){g_status=STATUS_DISABLED;restoreHeartbeat(localPlayer());return;}
 if((u32)(now-g_lastTick)<g_period)return;
 g_lastTick=now;
 pl=localPlayer();tg=selectedTarget();
 if(!pl||!tg||pl==tg||read32(tg+OBJ_TYPE)!=3u){
  g_status=STATUS_IDLE;restoreHeartbeat(pl);return;
 }
 /* Reaction 1-3 is the verified hostile band for build 5875. */
 {s32 reaction=((ReactionFn)REACTION_FN)(pl,tg);
 if(reaction<1||reaction>3){
  g_status=STATUS_IDLE;restoreHeartbeat(pl);return;
 }}
 if(read32(CASTING_SPELL_ID)||read32(PENDING_CAST)){
  g_status=STATUS_CAST_PAUSE;return;
 }
 px=readf(pl+OBJ_X);py=readf(pl+OBJ_Y);pz=readf(pl+OBJ_Z);po=readf(pl+OBJ_O);
 tx=readf(tg+OBJ_X);ty=readf(tg+OBJ_Y);tz=readf(tg+OBJ_Z);to=readf(tg+OBJ_O);
 if(!finitef(px)||!finitef(py)||!finitef(pz)||!finitef(po)||
    !finitef(tx)||!finitef(ty)||!finitef(tz)||!finitef(to)){
  g_status=STATUS_IDLE;restoreHeartbeat(pl);return;
 }
 dx=px-tx;dy=py-ty;dz=pz-tz;
 if(dx*dx+dy*dy>REAL_MAX_RANGE_SQ||dz>2.5f||dz< -2.5f){
  g_status=STATUS_IDLE;restoreHeartbeat(pl);return;
 }
 /* Read target GUID again immediately before writing, reject recycled/switching targets. */
 lo=read32(tg+OBJ_LO);hi=read32(tg+OBJ_HI);
 if(!lo&&!hi)return;
 if(lo!=read32(TARGET_LO)||hi!=read32(TARGET_HI))return;
 a=angle(to+PI_F);
 x=tx+REAR_DISTANCE*fcos1(a);y=ty+REAR_DISTANCE*fsin1(a);z=tz;o=angle(a+PI_F);
 if(!finitef(x)||!finitef(y)||!finitef(z)||!finitef(o))return;
 /* No persistent local movement: two priming heartbeats, then restore
    client XYZ/O. Never send a third real heartbeat in the same cast window. */
 *(float*)(pl+OBJ_X)=x;*(float*)(pl+OBJ_Y)=y;
 *(float*)(pl+OBJ_Z)=z;*(float*)(pl+OBJ_O)=o;
 nativeHeartbeat(pl);nativeHeartbeat(pl);
 *(float*)(pl+OBJ_X)=px;*(float*)(pl+OBJ_Y)=py;
 *(float*)(pl+OBJ_Z)=pz;*(float*)(pl+OBJ_O)=po;
 g_needsRestore=1u;g_status=STATUS_ACTIVE;++g_count;
}
static void prepareDescriptors(void){
 W112_ControlSettingV1*s;
 if(g_descriptorsReady)return;
 s=&g_settings[0];s->struct_size=sizeof(*s);s->setting_id=SETTING_ENABLED;
 s->key="pve_rear_enabled";s->label="PvE 360 rear";s->type=W112_CTL_BOOL;
 s->default_value.u32=1u;s->min_value.u32=0u;s->max_value.u32=1u;s->step.u32=1u;
 s->flags=W112_CTL_LIVE;s->enum_options=0;s->enum_option_count=0u;
 s=&g_settings[1];s->struct_size=sizeof(*s);s->setting_id=SETTING_PERIOD;
 s->key="pve_rear_period_ms";s->label="PvE rear interval (ms)";s->type=W112_CTL_INT;
 s->default_value.i32=100;s->min_value.i32=80;s->max_value.i32=250;s->step.i32=10;
 s->flags=W112_CTL_LIVE;s->enum_options=0;s->enum_option_count=0u;
 g_descriptorsReady=1u;
}
static int W112_CTL_STDCALL getControl(w112_u32 id,W112_ControlValueV1*out){
 if(!out)return 0;
 if(id==SETTING_ENABLED){out->u32=g_enabled;return 1;}
 if(id==SETTING_PERIOD){out->i32=(w112_i32)g_period;return 1;}
 return 0;
}
static int W112_CTL_STDCALL setControl(w112_u32 id,const W112_ControlValueV1*v){
 if(!v)return 0;
 if(id==SETTING_ENABLED){if(v->u32>1u)return 0;g_enabled=v->u32;return 1;}
 if(id==SETTING_PERIOD){if(v->i32<80||v->i32>250||v->i32%10)return 0;g_period=(u32)v->i32;return 1;}
 return 0;
}
static const W112_ControlModuleV1 g_control={
 W112_CONTROL_API_V1,sizeof(W112_ControlModuleV1),"pve_rear360","PvE Rear 360",
 0x00010000u,2u,g_settings,getControl,setControl
};
W112_CTL_EXPORT const W112_ControlModuleV1* W112_CTL_STDCALL W112_Control_GetModuleV1(void){
 prepareDescriptors();return &g_control;
}
__declspec(dllexport) u32 STDCALL PVERear360_GetStatus(void){return g_status;}
__declspec(dllexport) u32 STDCALL PVERear360_GetPulseCount(void){return g_count;}
/* Invoked only by the existing ESP WndProc on the game window's owner thread. */
__declspec(dllexport) u32 STDCALL PVERear360_GameWindowTick(HWND32 game){
 if(g_stop||!game||!IsWindow(game)||g_status==STATUS_BUILD_MISMATCH||
    g_status==STATUS_THREAD_ERROR||game!=((GetGameWindowFn)FN_GET_GAME_WINDOW)(0))return 0u;
 if(!g_timer||g_timerWindow!=game){
  g_timerWindow=game;g_timer=1u;g_lastTick=0u;g_status=STATUS_IDLE;
 }
 tick(game,WM_W112_REAR_TICK,1u,GetTickCount());
 return 1u;
}
/* The worker only posts a private message. The existing parallel ESP game
   WndProc dispatches PVERear360_GameWindowTick on the actual game GUI thread.
   SetTimer(NULL) in DllMain can be silent; SetTimer(hwnd) from a foreign
   worker thread is forbidden by Win32. No timer or new WndProc hook is used. */
static u32 STDCALL rearBootstrap(void*unused){
 (void)unused;
 while(!g_stop){
  HWND32 game=((GetGameWindowFn)FN_GET_GAME_WINDOW)(0);
  u32 pid=0u;
  int usable=game && IsWindow(game) &&
      GetWindowThreadProcessId(game,&pid)!=0u && pid==GetCurrentProcessId();
  if(!usable){
   g_timer=0u;g_timerWindow=0;g_needsRestore=0u;
   g_status=STATUS_WAIT_WINDOW;
  }else{
   if(g_timerWindow && game!=g_timerWindow){
    g_timer=0u;g_timerWindow=0;g_needsRestore=0u;
    g_status=STATUS_WAIT_WINDOW;
   }
   PostMessageA(game,WM_W112_REAR_TICK,0u,0);
  }
  Sleep(50u);
 }
 g_timer=0u;g_timerWindow=0;
 return 0u;
}
int STDCALL DllMain(void*m,u32 reason,void*reserved){
 void*worker;(void)m;(void)reserved;
 if(reason==1u){
  if(!build5875()){g_status=STATUS_BUILD_MISMATCH;return 1;}
  g_stop=0u;g_status=STATUS_WAIT_WINDOW;
  worker=CreateThread(0,0u,rearBootstrap,0,0u,0);
  if(worker)CloseHandle(worker);
  else g_status=STATUS_THREAD_ERROR;
 }else if(reason==0u){
  g_stop=1u;
  g_timer=0u;g_timerWindow=0;g_status=STATUS_DISABLED;
 }
 return 1;
}
