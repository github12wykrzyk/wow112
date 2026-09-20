/* Parallel-only PvE rear cast transaction; WoW 1.12.1 build 5875 x86.
   Port the work PositionalSpoof's essential ordering for NPC Backstab/Ambush:
   native cast-site intercept -> immutable cloned CMSG -> double rear heartbeat
   -> immediate cloned cast -> rear-consistent ordinary movement until restore.
   Reuse the existing MovementCore->LongPP movement chain; never replace it.
   Other spells, player targets, channels and PvP pass through untouched.
   Work original is the reference; this is a targeted new implementation. */
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
#pragma comment(linker, "/EXPORT:PVERear360_GetCastCount=_PVERear360_GetCastCount@0")
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
__declspec(dllimport) void* STDCALL GetModuleHandleA(const char*);
__declspec(dllimport) void* STDCALL GetProcAddress(void*,const char*);
__declspec(dllimport) int STDCALL IsWindow(HWND32);
__declspec(dllimport) u32 STDCALL GetWindowThreadProcessId(HWND32,u32*);
__declspec(dllimport) u32 STDCALL GetCurrentProcessId(void);
__declspec(dllimport) int STDCALL PostMessageA(HWND32,u32,u32,s32);
__declspec(dllimport) u32 STDCALL GetTickCount(void);
__declspec(dllimport) int STDCALL VirtualProtect(void*,u32,u32,u32*);
__declspec(dllimport) int STDCALL FlushInstructionCache(void*,const void*,u32);
__declspec(dllimport) void* STDCALL GetCurrentProcess(void);
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
#define CAST_SEND_SITE 0x006E5872u
#define MOVE_SEND_SITE 0x00600ACAu
#define CLIENTSERVICES_SEND 0x005AB630u
#define CMSG_CAST_SPELL 0x0000012Eu
#define PAGE_EXECUTE_READWRITE 0x40u
#define MAX_CAST_PACKET 512u
#define CAST_HOLD_MS 350u
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
#define STATUS_PP_PAUSE 8u
#define STATUS_CORE_NOT_READY 9u
#define STATUS_CAST_SITE_CONFLICT 10u
#define STATUS_MOVEMENT_SITE_CONFLICT 11u
#define STATUS_HOOK_PATCH_FAILED 12u
#define WORK_MOVEMENTCORE_DLL "MovementCore_V68_MINING_HARDLOS_COMBAT_AUTOPP_F11_BLACKLIST_HARDLOS3D_REARONLY_RETRY.dll"
int _fltused=0;
static volatile u32 g_enabled=1u;
static volatile u32 g_period=350u;
static volatile u32 g_status=STATUS_IDLE;
static volatile u32 g_count=0u;
static volatile u32 g_timer=0u;
static volatile HWND32 g_timerWindow=0;
static volatile u32 g_stop=0u;
static volatile u32 g_lastTick=0u;
static volatile u32 g_needsRestore=0u;
static volatile u32 g_castCount=0u,g_castActive=0u,g_castUntil=0u;
static volatile u32 g_castPlayer=0u,g_castTarget=0u;
static volatile u32 g_rearLease=0u,g_castInstalled=0u,g_moveInstalled=0u;
static volatile u32 g_suppressCast=0u,g_prevMoveTarget=0u;
static float g_rearX,g_rearY,g_rearZ,g_rearO;
static const u8 kCastOriginal[5]={0xE8u,0xB9u,0x5Du,0xECu,0xFFu};
static W112_ControlSettingV1 g_settings[2];
static volatile u32 g_descriptorsReady=0u;
typedef u32 (STDCALL *WorkCoordFlagsFn)(void);
typedef u32 (STDCALL *WorkCoordAcquireFn)(u32);
typedef void (STDCALL *WorkCoordReleaseFn)(void);
/* This game's work MovementCore owns PP/cast/gather/SafeBreak movement hooks.
   Absent module or export means no verified arbitration: do not send rear pulses. */
static int workMovementBusy(void){
 void* core=GetModuleHandleA(WORK_MOVEMENTCORE_DLL);
 WorkCoordFlagsFn flags;
 if(!core)return 1;
 flags=(WorkCoordFlagsFn)GetProcAddress(core,"MovementCore_CoordFlags");
 if(!flags)return 1;
 return (flags()&0x1Fu)!=0u;
}
static int acquireRear(u32 spell){
 void* core=GetModuleHandleA(WORK_MOVEMENTCORE_DLL);
 WorkCoordAcquireFn acquire;
 if(!core||g_rearLease)return 0;
 acquire=(WorkCoordAcquireFn)GetProcAddress(core,"MovementCore_CoordAcquireRear");
 if(!acquire||!acquire(spell))return 0;
 g_rearLease=1u;return 1;
}
static void releaseRear(void){
 void* core=GetModuleHandleA(WORK_MOVEMENTCORE_DLL);
 WorkCoordReleaseFn release;
 if(!g_rearLease)return;
 g_rearLease=0u;
 if(!core)return;
 release=(WorkCoordReleaseFn)GetProcAddress(core,"MovementCore_CoordReleaseRear");
 if(release)release();
}
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
/* CDataStore 5875 layout/clone is shared with work's positional pipeline.
   A heartbeat can mutate client send state: never re-use the original cast
   packet/header after priming; transmit a fresh, immediate copy. */
__declspec(naked) static void STDCALL sendStore(u32 store){
 __asm{
  mov ecx,[esp+4]
  test ecx,ecx
  je ss_done
  mov eax,CLIENTSERVICES_SEND
  call eax
 ss_done:
  ret 4
 }
}
static void restoreHeartbeat(u32 pl){
 if(!g_needsRestore||!pl||g_castActive)return;
 if(read32(CASTING_SPELL_ID)||read32(PENDING_CAST)||workMovementBusy())return;
 g_needsRestore=0u;
 nativeHeartbeat(pl);
}
static int behindSpell(u32 spell){
 return spell==53u||spell==2589u||spell==2590u||spell==2591u||
  spell==8721u||spell==11279u||spell==11280u||spell==11281u||
  spell==8676u||spell==8724u||spell==8725u||
  spell==11267u||spell==11268u||spell==11269u;
}
static int moveHasGuid(u32 op){
 return op==0xE9u||op==0xEBu||op==0xC7u||op==0xE3u||op==0xE5u||
 op==0xE7u||op==0x2DBu||op==0x2DDu||op==0x2DFu||
 op==0xF6u||op==0x2CFu||op==0x2D0u||op==0xF0u||op==0x2D1u;
}
static int moveHasExtra(u32 op){
 return op==0xE9u||op==0xEBu||op==0xC7u||op==0xE3u||op==0xE5u||
 op==0xE7u||op==0x2DBu||op==0x2DDu||op==0x2DFu||
 op==0xF6u||op==0x2CFu||op==0x2D0u||op==0xF0u;
}
/* Our wrapper is installed on the existing native callsite after MovementCore.
   Preserve its old target/LongPP chain and change only ordinary XYZ/O while
   an NPC opener is actually in flight. No new movement format/opcodes. */
static void STDCALL rewriteMovement(u32 store){
 u32 *ds=(u32*)store,size,buf,base,op,off;
 u8 *p;
 if(!g_castActive||!g_rearLease||!store)return;
 size=ds[4];buf=ds[1];base=ds[2];
 if(!buf||buf<base||size<28u||size>0x10000u)return;
 p=(u8*)(buf-base);op=*(u32*)p;off=4u;
 if(!moveHasGuid(op)&&op!=0xEEu)return;
 if(moveHasGuid(op))off+=8u;
 if(moveHasExtra(op))off+=4u;
 if(size<off+24u)return;
 *(float*)(p+off+8u)=g_rearX;*(float*)(p+off+12u)=g_rearY;
 *(float*)(p+off+16u)=g_rearZ;*(float*)(p+off+20u)=g_rearO;
}
__declspec(naked) static void moveChainHook(void){
 __asm{
  pushfd
  pushad
  push ecx
  call rewriteMovement
  popad
  popfd
  mov eax,dword ptr [g_prevMoveTarget]
  call eax
  ret
 }
}
/* Called at the exact work-verified SendCast callsite. Select only NPC
   Backstab/Ambush. Cast clone, pair of heartbeats and the cast are sent
   synchronously before the original call could send the unprimed position. */
static u32 STDCALL primeCast(u32 spell,u32 store){
 u32 pl,tg,lo,hi,sz,read,base,buf,i;
 u32 *original=(u32*)store,copyHeader[6];
 u8 copyPacket[MAX_CAST_PACKET],*src;
 float px,py,pz,po,tx,ty,tz,to,dx,dy,dz,a,x,y,z,o;
 s32 reaction;
 if(!g_enabled||!g_castInstalled||!g_moveInstalled||g_stop||g_castActive||
    !behindSpell(spell)||!store||workMovementBusy())return 0u;
 pl=localPlayer();tg=selectedTarget();
 if(!pl||!tg||pl==tg||read32(tg+OBJ_TYPE)!=3u)return 0u;
 reaction=((ReactionFn)REACTION_FN)(pl,tg);
 if(reaction<1||reaction>3)return 0u;
 if(read32(CASTING_SPELL_ID) && read32(CASTING_SPELL_ID)!=spell)return 0u;
 sz=original[4];read=original[5];base=original[2];buf=original[1];
 if(!buf||buf<base||sz<10u||sz>MAX_CAST_PACKET||read>sz)return 0u;
 src=(u8*)(buf-base);
 if(*(u32*)src!=CMSG_CAST_SPELL||*(u32*)(src+4u)!=spell)return 0u;
 px=readf(pl+OBJ_X);py=readf(pl+OBJ_Y);pz=readf(pl+OBJ_Z);po=readf(pl+OBJ_O);
 tx=readf(tg+OBJ_X);ty=readf(tg+OBJ_Y);tz=readf(tg+OBJ_Z);to=readf(tg+OBJ_O);
 if(!finitef(px)||!finitef(py)||!finitef(pz)||!finitef(po)||
    !finitef(tx)||!finitef(ty)||!finitef(tz)||!finitef(to))return 0u;
 dx=px-tx;dy=py-ty;dz=pz-tz;
 if(dx*dx+dy*dy>REAL_MAX_RANGE_SQ||dz>2.5f||dz< -2.5f)return 0u;
 lo=read32(tg+OBJ_LO);hi=read32(tg+OBJ_HI);
 if((!lo&&!hi)||lo!=read32(TARGET_LO)||hi!=read32(TARGET_HI))return 0u;
 a=angle(to+PI_F);
 x=tx+REAR_DISTANCE*fcos1(a);y=ty+REAR_DISTANCE*fsin1(a);z=tz;o=angle(a+PI_F);
 if(!finitef(x)||!finitef(y)||!finitef(z)||!finitef(o))return 0u;
 if(!acquireRear(spell))return 0u;
 for(i=0u;i<sz;++i)copyPacket[i]=src[i];
 for(i=0u;i<6u;++i)copyHeader[i]=original[i];
 copyHeader[1]=(u32)copyPacket;copyHeader[2]=0u;copyHeader[3]=MAX_CAST_PACKET;
 g_castPlayer=pl;g_castTarget=tg;
 g_rearX=x;g_rearY=y;g_rearZ=z;g_rearO=o;
 g_castActive=1u;g_castUntil=GetTickCount()+g_period;
 *(float*)(pl+OBJ_X)=x;*(float*)(pl+OBJ_Y)=y;
 *(float*)(pl+OBJ_Z)=z;*(float*)(pl+OBJ_O)=o;
 nativeHeartbeat(pl);nativeHeartbeat(pl);
 *(float*)(pl+OBJ_X)=px;*(float*)(pl+OBJ_Y)=py;
 *(float*)(pl+OBJ_Z)=pz;*(float*)(pl+OBJ_O)=po;
 sendStore((u32)copyHeader);
 g_needsRestore=1u;g_status=STATUS_ACTIVE;
 ++g_count;++g_castCount;
 return 1u; /* suppress the now-stale original CDataStore send */
}
__declspec(naked) static void castChainHook(void){
 __asm{
  pushfd
  pushad
  mov dword ptr [g_suppressCast],0
  mov eax,[ebp-8]
  test eax,eax
  je rear_queue_done
  mov eax,[eax+10h]
  mov edx,[esp+24]
  push edx
  push eax
  call primeCast
  mov dword ptr [g_suppressCast],eax
 rear_queue_done:
  popad
  popfd
  cmp dword ptr [g_suppressCast],0
  jne rear_cast_done
  mov eax,CLIENTSERVICES_SEND
  call eax
 rear_cast_done:
  ret
 }
}
static int patchCall(u32 site,void* fn){
 u32 old=0,ignored=0;
 if(!VirtualProtect((void*)site,5u,PAGE_EXECUTE_READWRITE,&old))return 0;
 *(volatile u8*)site=0xE8u;
 *(volatile u32*)(site+1u)=(u32)fn-(site+5u);
 FlushInstructionCache(GetCurrentProcess(),(void*)site,5u);
 VirtualProtect((void*)site,5u,old,&ignored);
 return 1;
}
static u32 callTarget(u32 site){
 if(*(volatile u8*)site!=0xE8u)return 0u;
 return site+5u+(u32)*(volatile s32*)(site+1u);
}
static int installCastAndMovement(void){
 u32 i,target;
 void* core=GetModuleHandleA(WORK_MOVEMENTCORE_DLL);
 typedef u32 (STDCALL *IsCoreReadyFn)(void);
 IsCoreReadyFn ready;
 if(!core){g_status=STATUS_CORE_NOT_READY;return 0;}
 /* clang-cl/MSVC x86 __stdcall exports may be decorated unless the linker
    supplies an undecorated alias. Accept both ABI spellings. */
 ready=(IsCoreReadyFn)GetProcAddress(core,"MovementCore_GetAltPriorityInstalled");
 if(!ready)ready=(IsCoreReadyFn)GetProcAddress(core,"_MovementCore_GetAltPriorityInstalled@0");
 if(!ready||!ready()){g_status=STATUS_CORE_NOT_READY;return 0;}
 for(i=0u;i<5u;++i)if(*(volatile u8*)(CAST_SEND_SITE+i)!=kCastOriginal[i]){
  g_status=STATUS_CAST_SITE_CONFLICT;return 0;
 }
 target=callTarget(MOVE_SEND_SITE);
 if(!target||target==(u32)moveChainHook){
  g_status=STATUS_MOVEMENT_SITE_CONFLICT;return 0;
 }
 g_prevMoveTarget=target;
 if(!patchCall(MOVE_SEND_SITE,moveChainHook)){
  g_status=STATUS_HOOK_PATCH_FAILED;return 0;
 }
 g_moveInstalled=1u;
 if(!patchCall(CAST_SEND_SITE,castChainHook)){
  patchCall(MOVE_SEND_SITE,(void*)g_prevMoveTarget);
  g_moveInstalled=0u;g_status=STATUS_HOOK_PATCH_FAILED;return 0;
 }
 g_castInstalled=1u;
 return 1;
}
static void removeHooks(void){
 u32 i,match=1u,ignored=0u,old=0u;
 if(g_castInstalled){
  for(i=0u;i<5u;++i)if(*(volatile u8*)(CAST_SEND_SITE+i)!=
   (i==0u?0xE8u:(u8)(((u32)castChainHook-(CAST_SEND_SITE+5u))>>(8u*(i-1u)))))match=0u;
  if(match&&VirtualProtect((void*)CAST_SEND_SITE,5u,PAGE_EXECUTE_READWRITE,&old)){
   for(i=0u;i<5u;++i)*(volatile u8*)(CAST_SEND_SITE+i)=kCastOriginal[i];
   FlushInstructionCache(GetCurrentProcess(),(void*)CAST_SEND_SITE,5u);
   VirtualProtect((void*)CAST_SEND_SITE,5u,old,&ignored);
  }
 }
 g_castInstalled=0u;
 if(g_moveInstalled&&callTarget(MOVE_SEND_SITE)==(u32)moveChainHook)
  patchCall(MOVE_SEND_SITE,(void*)g_prevMoveTarget);
 g_moveInstalled=0u;
}
static void STDCALL tick(HWND32 hwnd,u32 msg,u32 timer,u32 now){
 u32 pl;
 (void)hwnd;(void)msg;(void)timer;
 if(g_stop)return;
 if(!g_castInstalled||!g_moveInstalled){
  if(installCastAndMovement())g_status=STATUS_IDLE;
  /* Preserve the installer's specific reason on failure. */
  return;
 }
 if(g_castActive){
  if((s32)(now-g_castUntil)<0)return;
  pl=g_castPlayer;
  g_castActive=0u;g_castPlayer=0u;g_castTarget=0u;
  releaseRear();
  g_status=STATUS_IDLE;
  restoreHeartbeat(pl==localPlayer()?pl:0u);
  return;
 }
 if(!g_enabled){
  g_status=STATUS_DISABLED;restoreHeartbeat(localPlayer());return;
 }
 restoreHeartbeat(localPlayer());
}
static void prepareDescriptors(void){
 W112_ControlSettingV1*s;
 if(g_descriptorsReady)return;
 s=&g_settings[0];s->struct_size=sizeof(*s);s->setting_id=SETTING_ENABLED;
 s->key="pve_rear_enabled";s->label="PvE 360 rear";s->type=W112_CTL_BOOL;
 s->default_value.u32=1u;s->min_value.u32=0u;s->max_value.u32=1u;s->step.u32=1u;
 s->flags=W112_CTL_LIVE;s->enum_options=0;s->enum_option_count=0u;
 s=&g_settings[1];s->struct_size=sizeof(*s);s->setting_id=SETTING_PERIOD;
 s->key="pve_rear_period_ms";s->label="PvE rear hold (ms)";s->type=W112_CTL_INT;
 s->default_value.i32=350;s->min_value.i32=250;s->max_value.i32=650;s->step.i32=50;
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
 if(id==SETTING_PERIOD){if(v->i32<250||v->i32>650||v->i32%50)return 0;g_period=(u32)v->i32;return 1;}
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
__declspec(dllexport) u32 STDCALL PVERear360_GetCastCount(void){return g_castCount;}
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
  g_stop=1u;removeHooks();releaseRear();g_castActive=0u;
  g_timer=0u;g_timerWindow=0;g_status=STATUS_DISABLED;
 }
 return 1;
}
