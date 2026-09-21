/* Parallel PvE/PvP rear cast transaction; WoW 1.12.1 build 5875 x86.
   Port the work PositionalSpoof's essential ordering for NPC Backstab/Ambush:
   native cast-site intercept -> immutable cloned CMSG -> double rear heartbeat
   -> immediate cloned cast -> rear-consistent ordinary movement until restore.
   Reuse the existing MovementCore->LongPP movement chain; never replace it.
   Other spells, channels and nonattackable targets pass through untouched.
   One hook owner supports both PvE and PvP; never load work PositionalSpoof on parallel.
   Work original is the reference; this is a targeted new implementation. */
#if !defined(_M_IX86) && !defined(__i386__)
#error PvERear360 requires x86 WoW build 5875
#endif
#include "../common/W112ControlAPI.h"
#if defined(_MSC_VER)
#define STDCALL __stdcall
#define THISCALL __thiscall
#if !defined(PVE_REAR_EMBEDDED)
#pragma comment(linker, "/EXPORT:W112_Control_GetModuleV1=_W112_Control_GetModuleV1@0")
#endif
#pragma comment(linker, "/EXPORT:PVERear360_GetStatus=_PVERear360_GetStatus@0")
#pragma comment(linker, "/EXPORT:PVERear360_GetPulseCount=_PVERear360_GetPulseCount@0")
#pragma comment(linker, "/EXPORT:PVERear360_GameWindowTick=_PVERear360_GameWindowTick@4")
#pragma comment(linker, "/EXPORT:PVERear360_GetCastCount=_PVERear360_GetCastCount@0")
#pragma comment(linker, "/EXPORT:PVERear360_GetBusyDrops=_PVERear360_GetBusyDrops@0")
#pragma comment(linker, "/EXPORT:PVERear360_GetPositionalFailures=_PVERear360_GetPositionalFailures@0")
#pragma comment(linker, "/EXPORT:PVERear360_GetAdaptiveRetries=_PVERear360_GetAdaptiveRetries@0")
#pragma comment(linker, "/EXPORT:PVERear360_GetLastFailReason=_PVERear360_GetLastFailReason@0")
#pragma comment(linker, "/EXPORT:PVERear360_GetAttempts=_PVERear360_GetAttempts@0")
#pragma comment(linker, "/EXPORT:PVERear360_GetServerGo=_PVERear360_GetServerGo@0")
#pragma comment(linker, "/EXPORT:PVERear360_GetAborted=_PVERear360_GetAborted@0")
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
/* NPC-only call; same 5875 CanAttack ABI used by active PlayerESP. */
typedef u8 (THISCALL *CanAttackFn)(u32,u32);
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
#define CAN_ATTACK_FN 0x00606980u
#define CASTING_SPELL_ID 0x00CECA88u
#define PENDING_CAST 0x00CEAC48u
#define SEND_MOVEMENT_WRAPPER 0x00600A10u
#define FN_GET_GAME_WINDOW 0x00435C30u
#define CAST_SEND_SITE 0x006E5872u
#define SPELL_FAIL_SITE 0x006E73ACu
#define SPELL_GO_SITE 0x006E768Bu
#define SPELL_GO_CONTINUE 0x006E7691u
#define GCD_CALL_SITE 0x006E58FBu
#define START_GLOBAL_COOLDOWN 0x006E2DE0u
#define MOVE_SEND_SITE 0x00600ACAu
#define CLIENTSERVICES_SEND 0x005AB630u
#define CMSG_CAST_SPELL 0x0000012Eu
#define PAGE_EXECUTE_READWRITE 0x40u
#define MAX_CAST_PACKET 512u
#define CAST_HOLD_MS 350u
/* Bound an opener transaction even if LazyScript repeats every 100 ms. */
#define CAST_MAX_LEASE_MS 1000u
#define RETRY_MAX_ATTEMPTS 2u
#define RETRY_DELAY_MS 50u
#define REAR_SETTLE_MS 100u
#define PVP_REAR_SETTLE_MS 50u
#define REAR_RESULT_WAIT_MS 850u
#define RETRY_FEEDBACK_WINDOW_MS 1200u
/* While an NPC Backstab/Ambush transaction is unresolved, keep refreshing
   the same server-facing rear pose every 100 ms. This is intentionally
   bounded by the existing lease/result timeout and MovementCore arbitration. */
#define REAR_REFRESH_MS 100u
#define WM_W112_REAR_TICK 0x00008119u
#define REAR_DISTANCE 1.6f
#define REAL_MAX_RANGE_SQ 64.0f
#define PI_F 3.14159265358979323846f
#define TWO_PI_F 6.28318530717958647692f
#define SETTING_ENABLED 1u
#define SETTING_PERIOD 2u
#define SETTING_PVP_ENABLED 3u
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
#define STATUS_FAIL_SITE_CONFLICT 13u
#define STATUS_GO_SITE_CONFLICT 14u
#define WORK_MOVEMENTCORE_DLL "MovementCore_V68_MINING_HARDLOS_COMBAT_AUTOPP_F11_BLACKLIST_HARDLOS3D_REARONLY_RETRY.dll"
int _fltused=0;
static volatile u32 g_enabled=1u;
static volatile u32 g_pvpEnabled=1u;
static volatile u32 g_period=350u;
static volatile u32 g_status=STATUS_IDLE;
static volatile u32 g_count=0u;
static volatile u32 g_timer=0u;
static volatile HWND32 g_timerWindow=0;
static volatile u32 g_stop=0u;
static volatile u32 g_lastTick=0u;
static volatile u32 g_lastRearRefresh=0u;
static volatile u32 g_needsRestore=0u;
static volatile u32 g_castCount=0u,g_castActive=0u,g_castUntil=0u,g_castStarted=0u;
static volatile u32 g_castPlayer=0u,g_castTarget=0u;
static volatile u32 g_rearLease=0u,g_castInstalled=0u,g_moveInstalled=0u,g_gcdInstalled=0u,g_failInstalled=0u;
static volatile u32 g_prevFailTarget=0u,g_goInstalled=0u;
static volatile u32 g_sendPending=0u,g_sendDue=0u,g_resultPending=0u;
static volatile u32 g_deferredGcdValid=0u,g_deferredGcdArg=0u;
static volatile u32 g_attempts=0u,g_serverGo=0u,g_aborted=0u;
/* Keep only the newest NPC opener CMSG: never replay old target/world data. */
static u8 g_savedPacket[MAX_CAST_PACKET];
static u32 g_savedHeader[6],g_savedSpell=0u,g_savedPlayer=0u,g_savedTarget=0u;
static u32 g_savedType=0u,g_savedGuidLo=0u,g_savedGuidHi=0u;
static volatile u32 g_savedValid=0u,g_lastSendTick=0u,g_retryPending=0u,g_retryDue=0u,g_retryAttempt=0u;
static volatile u32 g_positionalFailures=0u,g_adaptiveRetries=0u,g_lastFailReason=0u;
static volatile u32 g_skipNativeGcdCurrent=0u,g_busyDrops=0u;
static volatile u32 g_suppressCast=0u,g_prevMoveTarget=0u;
static float g_rearX,g_rearY,g_rearZ,g_rearO;
static const u8 kCastOriginal[5]={0xE8u,0xB9u,0x5Du,0xECu,0xFFu};
static const u8 kGcdOriginal[5]={0xE8u,0xE0u,0xD4u,0xFFu,0xFFu};
static const u8 kGoOriginal[6]={0x8Bu,0x4Du,0xF0u,0x8Bu,0x55u,0xF4u};
static W112_ControlSettingV1 g_settings[3];
static volatile u32 g_descriptorsReady=0u;
typedef u32 (STDCALL *WorkCoordFlagsFn)(void);
typedef u32 (STDCALL *WorkCoordAcquireFn)(u32);
typedef void (STDCALL *WorkCoordReleaseFn)(void);
/* This game's work MovementCore owns PP/cast/gather/SafeBreak movement hooks.
   Absent module or export means no verified arbitration: do not send rear pulses. */
static int competingMovementBusy(void){
 void* core=GetModuleHandleA(WORK_MOVEMENTCORE_DLL);
 WorkCoordFlagsFn flags;
 if(!core)return 1;
 flags=(WorkCoordFlagsFn)GetProcAddress(core,"MovementCore_CoordFlags");
 return !flags||(flags()&0x0Fu)!=0u; /* exclude our own rear lease */
}
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
static int eligibleRearTarget(u32 type){
 return (type==3u&&g_enabled)||(type==4u&&g_pvpEnabled);
}
static int savedTargetStillValid(u32 tg){
 return tg&&tg==g_savedTarget&&read32(tg+OBJ_TYPE)==g_savedType&&
        read32(tg+OBJ_LO)==g_savedGuidLo&&read32(tg+OBJ_HI)==g_savedGuidHi;
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
 u32 *ds=(u32*)store,size,buf,base,op,off,tg;
 u8 *p;
 float tx,ty,tz,to,a,x,y,z,o;
 if(!g_castActive||!g_rearLease||!store)return;
 /* Never keep sending a stale pose after the NPC moves, turns or the user
    changes target. Preserve every other movement packet unchanged. */
 if(g_castPlayer!=localPlayer()||
    (tg=selectedTarget())==0u||tg!=g_castTarget||
    !savedTargetStillValid(tg)||!eligibleRearTarget(read32(tg+OBJ_TYPE)))return;
 tx=readf(tg+OBJ_X);ty=readf(tg+OBJ_Y);
 tz=readf(tg+OBJ_Z);to=readf(tg+OBJ_O);
 if(!finitef(tx)||!finitef(ty)||!finitef(tz)||!finitef(to))return;
 /* The movement rewriter must retain the selected 180/160/200 degree
    retry candidate; otherwise every retry silently becomes 180 again. */
 a=angle(to+PI_F+(g_retryAttempt==1u?-PI_F/9.0f:
                       g_retryAttempt==2u?PI_F/9.0f:0.0f));
 x=tx+REAR_DISTANCE*fcos1(a);y=ty+REAR_DISTANCE*fsin1(a);
 z=tz;o=angle(a+PI_F);
 if(!finitef(x)||!finitef(y)||!finitef(z)||!finitef(o))return;
 size=ds[4];buf=ds[1];base=ds[2];
 if(!buf||buf<base||size<28u||size>0x10000u)return;
 p=(u8*)(buf-base);op=*(u32*)p;off=4u;
 if(!moveHasGuid(op)&&op!=0xEEu)return;
 if(moveHasGuid(op))off+=8u;
 if(moveHasExtra(op))off+=4u;
 if(size<off+24u)return;
 *(float*)(p+off+8u)=x;*(float*)(p+off+12u)=y;
 *(float*)(p+off+16u)=z;*(float*)(p+off+20u)=o;
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
/* PvE-only bounded rear keepalive. The initial prime and settled-cast paths
   already send paired heartbeats; this fills the gaps between them and while
   the server result is pending. It never starts a transaction on its own. */
static void refreshActiveRear(u32 now){
 u32 pl,tg;
 float px,py,pz,po,tx,ty,tz,to,a,x,y,z,o;
 if(!g_castActive||!g_rearLease||!g_savedValid||g_savedType!=3u)return;
 if(!(g_sendPending||g_resultPending||g_retryPending))return;
 if(g_lastRearRefresh&&(u32)(now-g_lastRearRefresh)<REAR_REFRESH_MS)return;
 pl=localPlayer();tg=selectedTarget();
 if(!pl||!tg||g_savedPlayer!=pl||g_savedTarget!=tg||
    g_castPlayer!=pl||g_castTarget!=tg||!savedTargetStillValid(tg))return;
 if(competingMovementBusy())return;
 if(read32(CASTING_SPELL_ID)&&read32(CASTING_SPELL_ID)!=g_savedSpell)return;
 px=readf(pl+OBJ_X);py=readf(pl+OBJ_Y);pz=readf(pl+OBJ_Z);po=readf(pl+OBJ_O);
 tx=readf(tg+OBJ_X);ty=readf(tg+OBJ_Y);tz=readf(tg+OBJ_Z);to=readf(tg+OBJ_O);
 if(!finitef(px)||!finitef(py)||!finitef(pz)||!finitef(po)||
    !finitef(tx)||!finitef(ty)||!finitef(tz)||!finitef(to))return;
 a=angle(to+PI_F+(g_retryAttempt==1u?-PI_F/9.0f:
                       g_retryAttempt==2u?PI_F/9.0f:0.0f));
 x=tx+REAR_DISTANCE*fcos1(a);y=ty+REAR_DISTANCE*fsin1(a);
 z=tz;o=angle(a+PI_F);
 if(!finitef(x)||!finitef(y)||!finitef(z)||!finitef(o))return;
 g_rearX=x;g_rearY=y;g_rearZ=z;g_rearO=o;
 *(float*)(pl+OBJ_X)=x;*(float*)(pl+OBJ_Y)=y;
 *(float*)(pl+OBJ_Z)=z;*(float*)(pl+OBJ_O)=o;
 nativeHeartbeat(pl);nativeHeartbeat(pl);
 *(float*)(pl+OBJ_X)=px;*(float*)(pl+OBJ_Y)=py;
 *(float*)(pl+OBJ_Z)=pz;*(float*)(pl+OBJ_O)=po;
 g_lastRearRefresh=now;g_needsRestore=1u;++g_count;
}
/* Called at the exact work-verified SendCast callsite. Select only NPC
   Backstab/Ambush. Cast clone, pair of heartbeats and the cast are sent
   synchronously before the original call could send the unprimed position. */
static u32 STDCALL primeCast(u32 spell,u32 store){
 u32 pl,tg,lo,hi,sz,read,base,buf,i,now;
 u32 *original=(u32*)store,copyHeader[6];
 u8 copyPacket[MAX_CAST_PACKET],*src;
 float px,py,pz,po,tx,ty,tz,to,dx,dy,dz,a,x,y,z,o;
 s32 reaction;
 if((!g_enabled&&!g_pvpEnabled)||!g_castInstalled||!g_moveInstalled||g_stop||
    !behindSpell(spell)||!store)return 0u;
 pl=localPlayer();tg=selectedTarget();
 if(!pl||!tg||pl==tg||!eligibleRearTarget(read32(tg+OBJ_TYPE)))return 0u;
 /* Drop old world/target state instead of waiting for a previous opener to expire. */
 if(g_castActive&&(g_castPlayer!=pl||g_castTarget!=tg||
    (g_savedValid&&!savedTargetStillValid(tg)))){
  g_sendPending=0u;g_resultPending=0u;g_retryPending=0u;
  g_savedValid=0u;g_deferredGcdValid=0u;g_castActive=0u;
  g_castPlayer=0u;g_castTarget=0u;g_castUntil=0u;
  releaseRear();restoreHeartbeat(pl);
 }
 ++g_attempts;
 /* Reject repeated input while an existing NPC transaction is pending. */
 if(g_savedValid&&(g_sendPending||g_resultPending||g_retryPending)&&
    g_savedPlayer==pl&&g_savedTarget==tg){
  g_skipNativeGcdCurrent=1u;return 1u;
 }
 /* Do not race an already scheduled server-failure retry with LazyScript. */
 if(g_retryPending&&g_savedValid&&g_savedPlayer==pl&&
    g_savedTarget==tg&&g_savedSpell==spell){
  g_skipNativeGcdCurrent=1u;return 1u;
 }
 /* A previous opener already holds MovementCore's rear lease. Re-prime a
    fresh cast for the SAME NPC instead of sending it at the unprimed real
    position; never steal a lease from PP, gather or an unrelated cast. */
 if(g_castActive){
  /* Do not send a naked native opener while the old rear pose is leased. */
  if(!g_rearLease||g_castPlayer!=pl||g_castTarget!=tg||
     (s32)(GetTickCount()-(g_castStarted+CAST_MAX_LEASE_MS))>=0){
   g_skipNativeGcdCurrent=1u;++g_busyDrops;g_status=STATUS_CAST_PAUSE;return 1u;
  }
 }
 /* Use native attackability for hostile players, including mixed-faction BG. */
 if(read32(tg+OBJ_TYPE)==3u){
  reaction=((ReactionFn)REACTION_FN)(pl,tg);
  if(reaction<1||reaction>4)return 0u;
 }
 if(!((CanAttackFn)CAN_ATTACK_FN)(pl,tg))return 0u;
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
 /* The old code silently forwarded an unprimed Backstab/Ambush whenever
    PP/gather/another owner held movement. Work's position pipeline instead
    drops that stale CMSG and its native GCD so LazyScript may retry after
    ownership clears. Never override the concurrent owner's coordinates. */
 if(!g_castActive && (workMovementBusy()||!acquireRear(spell))){
  g_skipNativeGcdCurrent=1u;++g_busyDrops;g_status=STATUS_PP_PAUSE;
  return 1u;
 }
 for(i=0u;i<sz;++i)copyPacket[i]=src[i];
 for(i=0u;i<6u;++i)copyHeader[i]=original[i];
 /* Immutable retry template; original stack store is invalid after return. */
 for(i=0u;i<sz;++i)g_savedPacket[i]=copyPacket[i];
 for(i=0u;i<6u;++i)g_savedHeader[i]=copyHeader[i];
 g_savedHeader[1]=(u32)g_savedPacket;g_savedHeader[2]=0u;
 g_savedHeader[3]=MAX_CAST_PACKET;
 g_savedPlayer=pl;g_savedTarget=tg;g_savedSpell=spell;
 g_savedType=read32(tg+OBJ_TYPE);g_savedGuidLo=lo;g_savedGuidHi=hi;
 g_savedValid=1u;g_retryAttempt=0u;g_retryPending=0u;
 g_sendPending=1u;g_resultPending=0u;
 g_sendDue=GetTickCount()+(g_savedType==4u?PVP_REAR_SETTLE_MS:REAR_SETTLE_MS);
 g_deferredGcdValid=0u;
 copyHeader[1]=(u32)copyPacket;copyHeader[2]=0u;copyHeader[3]=MAX_CAST_PACKET;
 g_castPlayer=pl;g_castTarget=tg;
 g_rearX=x;g_rearY=y;g_rearZ=z;g_rearO=o;
 if(!g_castActive)g_castStarted=GetTickCount();
 g_castActive=1u;g_castUntil=GetTickCount()+g_period;
 *(float*)(pl+OBJ_X)=x;*(float*)(pl+OBJ_Y)=y;
 *(float*)(pl+OBJ_Z)=z;*(float*)(pl+OBJ_O)=o;
 nativeHeartbeat(pl);nativeHeartbeat(pl);
 *(float*)(pl+OBJ_X)=px;*(float*)(pl+OBJ_Y)=py;
 *(float*)(pl+OBJ_Z)=pz;*(float*)(pl+OBJ_O)=po;
 g_lastRearRefresh=GetTickCount();
 g_needsRestore=1u;g_status=STATUS_ACTIVE;
 ++g_count;
 if(g_savedType==3u){
  /* Work's accepted PvE path sent heartbeat -> cast synchronously from the
     native SendCast hook. The old parallel 100 ms gap let intervening real
     movement/target facing invalidate the server-side rear check. Preserve
     this same-call ordering while keeping the immutable cloned CDataStore.
     PvP retains its existing deferred path. */
  now=GetTickCount();
  g_sendPending=0u;g_resultPending=1u;
  g_lastSendTick=now;g_lastRearRefresh=now;g_castUntil=now+g_period;
  sendStore((u32)copyHeader);
  ++g_castCount;
  g_skipNativeGcdCurrent=0u; /* the original callsite starts GCD normally */
  return 1u; /* original unprimed CMSG is always suppressed */
 }
 g_skipNativeGcdCurrent=1u;
 return 1u; /* PvP retains its existing deferred cloned CMSG and GCD */
}
__declspec(naked) static void castChainHook(void){
 __asm{
  pushfd
  pushad
  mov dword ptr [g_suppressCast],0
  mov dword ptr [g_skipNativeGcdCurrent],0
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
/* Read the server's actual reason, rather than guessing from a 350 ms
   lease. This exact 5875 callsite is already hooked by LongPickPocket;
   preserve its callback chain. Only the documented positional errors can
   schedule one of two strictly bounded NPC-only retries. */
static void STDCALL observeServerFailure(u32 spell,u32 reason){
 u32 now=GetTickCount();
 if(!g_savedValid||!g_failInstalled||
    !behindSpell(spell)||spell!=g_savedSpell||
    g_savedPlayer!=localPlayer()||!savedTargetStillValid(selectedTarget())||
    !eligibleRearTarget(g_savedType)||
    (u32)(now-g_lastSendTick)>RETRY_FEEDBACK_WINDOW_MS)return;
 if(!g_resultPending)return;
 g_resultPending=0u;g_lastFailReason=reason;
 if(reason!=0x33u&&reason!=0x7Cu){
  g_savedValid=0u;g_castUntil=now+50u;return;
 }
 ++g_positionalFailures;
 if(g_retryPending||g_retryAttempt>=RETRY_MAX_ATTEMPTS){
  g_savedValid=0u;g_castUntil=now+50u;return;
 }
 g_retryPending=1u;g_retryDue=now+RETRY_DELAY_MS;
}
__declspec(naked) static void failChainHook(void){
 __asm{
  pushfd
  pushad
  mov eax,[esp+24]
  mov edx,[esp+20]
  and edx,0FFh
  push edx
  push eax
  call observeServerFailure
  popad
  popfd
  mov eax,dword ptr [g_prevFailTarget]
  jmp eax
 }
}
/* Observe native spell-go for this NPC; preserving original six bytes. */
static void STDCALL observeServerGo(u32 spell){
 u32 now=GetTickCount();
 if(!g_savedValid||!g_resultPending||spell!=g_savedSpell||
    g_savedPlayer!=localPlayer()||!savedTargetStillValid(selectedTarget())||
    (u32)(now-g_lastSendTick)>RETRY_FEEDBACK_WINDOW_MS)return;
 ++g_serverGo;
 g_resultPending=0u;g_savedValid=0u;g_retryPending=0u;
 g_castUntil=now+50u;
}
__declspec(naked) static void goChainHook(void){
 __asm{
  pushfd
  pushad
  mov eax,[ebp-4]
  push eax
  call observeServerGo
  popad
  popfd
  mov ecx,[ebp-10h]
  mov edx,[ebp-0Ch]
  mov eax,SPELL_GO_CONTINUE
  jmp eax
 }
}
/* Re-prime only after a confirmed positional failure. Never retry on
   insufficient energy, cooldown, invalid target, range or a competing PP.
   The game-window tick is the only thread allowed to send native heartbeats. */
static void tryPositionalRetry(u32 now){
 u32 pl,tg,i,header[6],sz,idx;
 u8 packet[MAX_CAST_PACKET];
 float px,py,pz,po,tx,ty,tz,to,a,x,y,z,o,dx,dy,dz;
 if(!g_retryPending||(s32)(now-g_retryDue)<0)return;
 pl=localPlayer();tg=selectedTarget();
 if(!g_savedValid||g_savedPlayer!=pl||!savedTargetStillValid(tg)||
    !pl||!tg||!eligibleRearTarget(g_savedType)||
    (u32)(now-g_lastSendTick)>RETRY_FEEDBACK_WINDOW_MS||
    g_retryAttempt>=RETRY_MAX_ATTEMPTS){g_retryPending=0u;return;}
 if(read32(CASTING_SPELL_ID)&&read32(CASTING_SPELL_ID)!=g_savedSpell){
  g_retryPending=0u;return;
 }
 if(!g_castActive){
  if(workMovementBusy()||!acquireRear(g_savedSpell)){
   g_retryDue=now+RETRY_DELAY_MS;return;
  }
 }else if(!g_rearLease||g_castPlayer!=pl||g_castTarget!=tg){
  g_retryPending=0u;return;
 }
 px=readf(pl+OBJ_X);py=readf(pl+OBJ_Y);pz=readf(pl+OBJ_Z);po=readf(pl+OBJ_O);
 tx=readf(tg+OBJ_X);ty=readf(tg+OBJ_Y);tz=readf(tg+OBJ_Z);to=readf(tg+OBJ_O);
 dx=px-tx;dy=py-ty;dz=pz-tz;
 if(!finitef(px)||!finitef(py)||!finitef(pz)||!finitef(po)||
    !finitef(tx)||!finitef(ty)||!finitef(tz)||!finitef(to)||
    dx*dx+dy*dy>REAL_MAX_RANGE_SQ||dz>2.5f||dz< -2.5f){
  g_retryPending=0u;return;
 }
 /* Work PositionalSpoof's first two rear-hemisphere fallback poses:
    160 and 200 degrees relative to the NPC's current facing. */
 idx=g_retryAttempt+1u;
 a=angle(to+PI_F+(idx==1u?-PI_F/9.0f:PI_F/9.0f));
 x=tx+REAR_DISTANCE*fcos1(a);y=ty+REAR_DISTANCE*fsin1(a);
 z=tz;o=angle(a+PI_F);
 if(!finitef(x)||!finitef(y)||!finitef(z)||!finitef(o)){
  g_retryPending=0u;return;
 }
 sz=g_savedHeader[4];
 if(sz<10u||sz>MAX_CAST_PACKET||
    *(u32*)g_savedPacket!=CMSG_CAST_SPELL||
    *(u32*)(g_savedPacket+4u)!=g_savedSpell){
  g_retryPending=0u;return;
 }
 for(i=0u;i<sz;++i)packet[i]=g_savedPacket[i];
 for(i=0u;i<6u;++i)header[i]=g_savedHeader[i];
 header[1]=(u32)packet;header[2]=0u;header[3]=MAX_CAST_PACKET;
 g_castPlayer=pl;g_castTarget=tg;
 g_castStarted=now;
 g_castActive=1u;g_castUntil=now+g_period;
 g_rearX=x;g_rearY=y;g_rearZ=z;g_rearO=o;
 g_retryPending=0u;g_retryAttempt=idx;
 g_sendPending=1u;g_sendDue=now+(g_savedType==4u?PVP_REAR_SETTLE_MS:REAR_SETTLE_MS);
 g_resultPending=0u;
 *(float*)(pl+OBJ_X)=x;*(float*)(pl+OBJ_Y)=y;
 *(float*)(pl+OBJ_Z)=z;*(float*)(pl+OBJ_O)=o;
 nativeHeartbeat(pl);nativeHeartbeat(pl);
 *(float*)(pl+OBJ_X)=px;*(float*)(pl+OBJ_Y)=py;
 *(float*)(pl+OBJ_Z)=pz;*(float*)(pl+OBJ_O)=po;
 g_lastRearRefresh=now;g_needsRestore=1u;
 ++g_adaptiveRetries;++g_count;
 g_status=STATUS_ACTIVE;
}
/* Deferred NPC opener: use a fresh packet, current NPC pose and the same
   rear candidate as all outgoing movement. Executed only on game window
   thread, never from the worker timer thread. */
static void sendSettledCast(u32 now){
 u32 pl=localPlayer(),tg=selectedTarget(),sz,i,header[6];
 u8 packet[MAX_CAST_PACKET];
 float px,py,pz,po,tx,ty,tz,to,dx,dy,dz,a,x,y,z,o;
 if(!g_sendPending||(s32)(now-g_sendDue)<0)return;
 if(!g_enabled||!g_savedValid||!g_rearLease||!g_castActive||
    !pl||!tg||g_savedPlayer!=pl||g_savedTarget!=tg||
    g_castPlayer!=pl||g_castTarget!=tg||!savedTargetStillValid(tg)||
    !eligibleRearTarget(g_savedType)||
    competingMovementBusy()||
    (s32)(now-(g_castStarted+CAST_MAX_LEASE_MS))>=0)goto abort_send;
 sz=g_savedHeader[4];
 if(sz<10u||sz>MAX_CAST_PACKET||*(u32*)g_savedPacket!=CMSG_CAST_SPELL||
    *(u32*)(g_savedPacket+4u)!=g_savedSpell)goto abort_send;
 px=readf(pl+OBJ_X);py=readf(pl+OBJ_Y);pz=readf(pl+OBJ_Z);po=readf(pl+OBJ_O);
 tx=readf(tg+OBJ_X);ty=readf(tg+OBJ_Y);tz=readf(tg+OBJ_Z);to=readf(tg+OBJ_O);
 if(!finitef(px)||!finitef(py)||!finitef(pz)||!finitef(po)||
    !finitef(tx)||!finitef(ty)||!finitef(tz)||!finitef(to))goto abort_send;
 dx=px-tx;dy=py-ty;dz=pz-tz;
 if(dx*dx+dy*dy>REAL_MAX_RANGE_SQ||dz>2.5f||dz< -2.5f)goto abort_send;
 a=angle(to+PI_F+(g_retryAttempt==1u?-PI_F/9.0f:
                        g_retryAttempt==2u?PI_F/9.0f:0.0f));
 x=tx+REAR_DISTANCE*fcos1(a);y=ty+REAR_DISTANCE*fsin1(a);
 z=tz;o=angle(a+PI_F);
 if(!finitef(x)||!finitef(y)||!finitef(z)||!finitef(o))goto abort_send;
 for(i=0u;i<sz;++i)packet[i]=g_savedPacket[i];
 for(i=0u;i<6u;++i)header[i]=g_savedHeader[i];
 header[1]=(u32)packet;header[2]=0u;header[3]=MAX_CAST_PACKET;
 g_rearX=x;g_rearY=y;g_rearZ=z;g_rearO=o;
 *(float*)(pl+OBJ_X)=x;*(float*)(pl+OBJ_Y)=y;
 *(float*)(pl+OBJ_Z)=z;*(float*)(pl+OBJ_O)=o;
 nativeHeartbeat(pl);nativeHeartbeat(pl);
 *(float*)(pl+OBJ_X)=px;*(float*)(pl+OBJ_Y)=py;
 *(float*)(pl+OBJ_Z)=pz;*(float*)(pl+OBJ_O)=po;
 g_sendPending=0u;g_resultPending=1u;
 g_lastSendTick=now;g_lastRearRefresh=now;g_castUntil=now+g_period;
 sendStore((u32)header);
 ++g_castCount;
 if(g_deferredGcdValid){
  u32 arg=g_deferredGcdArg;
  g_deferredGcdValid=0u;
  ((void (__fastcall *)(u32,u32))START_GLOBAL_COOLDOWN)(g_savedSpell,arg);
 }
 return;
abort_send:
 g_sendPending=0u;g_resultPending=0u;g_savedValid=0u;
 g_deferredGcdValid=0u;g_retryPending=0u;
 g_castUntil=now;++g_aborted;
}
/* The original native GCD CALL follows CAST_SEND_SITE. A deferred/busy
   opener must not consume a phantom client GCD while no CMSG was sent. */
__declspec(naked) static void gcdChainHook(void){
 __asm{
  cmp dword ptr [g_skipNativeGcdCurrent],0
  je gcd_original
  cmp dword ptr [g_sendPending],0
  je gcd_skip
  mov dword ptr [g_deferredGcdArg],edx
  mov dword ptr [g_deferredGcdValid],1
 gcd_skip:
  mov dword ptr [g_skipNativeGcdCurrent],0
  ret
 gcd_original:
  mov eax,START_GLOBAL_COOLDOWN
  jmp eax
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
static int patchGoJump(void*fn){
 u32 old=0,ignored=0;
 if(!VirtualProtect((void*)SPELL_GO_SITE,6u,PAGE_EXECUTE_READWRITE,&old))return 0;
 *(volatile u8*)SPELL_GO_SITE=0xE9u;
 *(volatile u32*)(SPELL_GO_SITE+1u)=(u32)fn-(SPELL_GO_SITE+5u);
 *(volatile u8*)(SPELL_GO_SITE+5u)=0x90u;
 FlushInstructionCache(GetCurrentProcess(),(void*)SPELL_GO_SITE,6u);
 VirtualProtect((void*)SPELL_GO_SITE,6u,old,&ignored);
 return 1;
}
static u32 callTarget(u32 site){
 if(*(volatile u8*)site!=0xE8u)return 0u;
 return site+5u+(u32)*(volatile s32*)(site+1u);
}
static int installCastAndMovement(void){
 u32 i,target,failTarget;
 void* core=GetModuleHandleA(WORK_MOVEMENTCORE_DLL);
 typedef u32 (STDCALL *IsCoreReadyFn)(void);
 IsCoreReadyFn ready;
 if(!core){g_status=STATUS_CORE_NOT_READY;return 0;}
 /* clang-cl/MSVC x86 __stdcall exports may be decorated unless the linker
    supplies an undecorated alias. Accept both ABI spellings. */
 ready=(IsCoreReadyFn)GetProcAddress(core,"MovementCore_GetAltPriorityInstalled");
 if(!ready)ready=(IsCoreReadyFn)GetProcAddress(core,"_MovementCore_GetAltPriorityInstalled@0");
 if(!ready||!ready()){g_status=STATUS_CORE_NOT_READY;return 0;}
 for(i=0u;i<5u;++i)if(*(volatile u8*)(CAST_SEND_SITE+i)!=kCastOriginal[i]||
                           *(volatile u8*)(GCD_CALL_SITE+i)!=kGcdOriginal[i]){
  g_status=STATUS_CAST_SITE_CONFLICT;return 0;
 }
 for(i=0u;i<6u;++i)if(*(volatile u8*)(SPELL_GO_SITE+i)!=kGoOriginal[i]){
  g_status=STATUS_GO_SITE_CONFLICT;return 0;
 }
 failTarget=callTarget(SPELL_FAIL_SITE);
 if(!failTarget||failTarget==(u32)failChainHook){
  g_status=STATUS_FAIL_SITE_CONFLICT;return 0;
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
 if(!patchCall(GCD_CALL_SITE,gcdChainHook)){
  patchCall(CAST_SEND_SITE,(void*)CLIENTSERVICES_SEND);
  patchCall(MOVE_SEND_SITE,(void*)g_prevMoveTarget);
  g_castInstalled=0u;g_moveInstalled=0u;
  g_status=STATUS_HOOK_PATCH_FAILED;return 0;
 }
 g_gcdInstalled=1u;
 g_prevFailTarget=failTarget;
 if(!patchCall(SPELL_FAIL_SITE,failChainHook)){
  patchCall(GCD_CALL_SITE,(void*)START_GLOBAL_COOLDOWN);
  patchCall(CAST_SEND_SITE,(void*)CLIENTSERVICES_SEND);
  patchCall(MOVE_SEND_SITE,(void*)g_prevMoveTarget);
  g_castInstalled=0u;g_moveInstalled=0u;g_gcdInstalled=0u;
  g_status=STATUS_HOOK_PATCH_FAILED;return 0;
 }
 g_failInstalled=1u;
 if(!patchGoJump(goChainHook)){
  patchCall(SPELL_FAIL_SITE,(void*)g_prevFailTarget);
  patchCall(GCD_CALL_SITE,(void*)START_GLOBAL_COOLDOWN);
  patchCall(CAST_SEND_SITE,(void*)CLIENTSERVICES_SEND);
  patchCall(MOVE_SEND_SITE,(void*)g_prevMoveTarget);
  g_failInstalled=0u;g_castInstalled=0u;g_moveInstalled=0u;g_gcdInstalled=0u;
  g_status=STATUS_HOOK_PATCH_FAILED;return 0;
 }
 g_goInstalled=1u;
 return 1;
}
static void removeHooks(void){
 u32 i,match=1u,ignored=0u,old=0u;
 g_retryPending=0u;g_savedValid=0u;g_sendPending=0u;g_resultPending=0u;
 g_deferredGcdValid=0u;
 if(g_goInstalled&&*(volatile u8*)SPELL_GO_SITE==0xE9u&&
    SPELL_GO_SITE+5u+(u32)*(volatile s32*)(SPELL_GO_SITE+1u)==(u32)goChainHook&&
    VirtualProtect((void*)SPELL_GO_SITE,6u,PAGE_EXECUTE_READWRITE,&old)){
  for(i=0u;i<6u;++i)*(volatile u8*)(SPELL_GO_SITE+i)=kGoOriginal[i];
  FlushInstructionCache(GetCurrentProcess(),(void*)SPELL_GO_SITE,6u);
  VirtualProtect((void*)SPELL_GO_SITE,6u,old,&ignored);
 }
 g_goInstalled=0u;
 if(g_failInstalled&&callTarget(SPELL_FAIL_SITE)==(u32)failChainHook)
  patchCall(SPELL_FAIL_SITE,(void*)g_prevFailTarget);
 g_failInstalled=0u;
 if(g_gcdInstalled&&callTarget(GCD_CALL_SITE)==(u32)gcdChainHook){
  patchCall(GCD_CALL_SITE,(void*)START_GLOBAL_COOLDOWN);
 }
 g_gcdInstalled=0u;g_skipNativeGcdCurrent=0u;
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
 if(!g_castInstalled||!g_moveInstalled||!g_gcdInstalled||!g_failInstalled||!g_goInstalled){
  if(installCastAndMovement())g_status=STATUS_IDLE;
  /* Preserve the installer's specific reason on failure. */
  return;
 }
 if(g_retryPending)tryPositionalRetry(now);
 if(g_sendPending)sendSettledCast(now);
 refreshActiveRear(now);
 if(g_resultPending&&g_lastSendTick&&
    (u32)(now-g_lastSendTick)>REAR_RESULT_WAIT_MS){
  g_resultPending=0u;g_savedValid=0u;g_castUntil=now;
 }
 if(g_castActive){
  /* An NPC turn is handled by movement rewriting and the next cast re-prime;
     target/world changes and disable retire the lease without stale sends. */
  if(eligibleRearTarget(g_savedType)&&g_castPlayer==localPlayer()&&
     savedTargetStillValid(selectedTarget())&&
     (s32)(now-(g_castStarted+CAST_MAX_LEASE_MS))<0&&
     (g_sendPending||g_retryPending||g_resultPending||
      (s32)(now-g_castUntil)<0))return;
  pl=g_castPlayer;
  g_castActive=0u;g_castPlayer=0u;g_castTarget=0u;g_lastRearRefresh=0u;
  g_sendPending=0u;g_resultPending=0u;g_retryPending=0u;
  g_deferredGcdValid=0u;g_savedValid=0u;
  releaseRear();
  g_status=STATUS_IDLE;
  restoreHeartbeat(pl==localPlayer()?pl:0u);
  return;
 }
 if(!g_enabled&&!g_pvpEnabled){
  g_retryPending=0u;g_savedValid=0u;g_sendPending=0u;g_lastRearRefresh=0u;
  g_resultPending=0u;g_deferredGcdValid=0u;
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
 s=&g_settings[2];s->struct_size=sizeof(*s);s->setting_id=SETTING_PVP_ENABLED;
 s->key="pvp_rear_enabled";s->label="PvP Backstab / Ambush rear";s->type=W112_CTL_BOOL;
 s->default_value.u32=1u;s->min_value.u32=0u;s->max_value.u32=1u;s->step.u32=1u;
 s->flags=W112_CTL_LIVE;s->enum_options=0;s->enum_option_count=0u;
 g_descriptorsReady=1u;
}
static int W112_CTL_STDCALL getControl(w112_u32 id,W112_ControlValueV1*out){
 if(!out)return 0;
 if(id==SETTING_ENABLED){out->u32=g_enabled;return 1;}
 if(id==SETTING_PERIOD){out->i32=(w112_i32)g_period;return 1;}
 if(id==SETTING_PVP_ENABLED){out->u32=g_pvpEnabled;return 1;}
 return 0;
}
static int W112_CTL_STDCALL setControl(w112_u32 id,const W112_ControlValueV1*v){
 if(!v)return 0;
 if(id==SETTING_ENABLED){if(v->u32>1u)return 0;g_enabled=v->u32;return 1;}
 if(id==SETTING_PERIOD){if(v->i32<250||v->i32>650||v->i32%50)return 0;g_period=(u32)v->i32;return 1;}
 if(id==SETTING_PVP_ENABLED){if(v->u32>1u)return 0;g_pvpEnabled=v->u32;return 1;}
 return 0;
}
static const W112_ControlModuleV1 g_control={
 W112_CONTROL_API_V1,sizeof(W112_ControlModuleV1),"pve_rear360","Rear 360 PvE / PvP",
 0x00010001u,3u,g_settings,getControl,setControl
};
W112_CTL_EXPORT const W112_ControlModuleV1* W112_CTL_STDCALL W112_Control_GetModuleV1(void){
 prepareDescriptors();return &g_control;
}
__declspec(dllexport) u32 STDCALL PVERear360_GetStatus(void){return g_status;}
__declspec(dllexport) u32 STDCALL PVERear360_GetPulseCount(void){return g_count;}
__declspec(dllexport) u32 STDCALL PVERear360_GetCastCount(void){return g_castCount;}
__declspec(dllexport) u32 STDCALL PVERear360_GetBusyDrops(void){return g_busyDrops;}
__declspec(dllexport) u32 STDCALL PVERear360_GetPositionalFailures(void){return g_positionalFailures;}
__declspec(dllexport) u32 STDCALL PVERear360_GetAdaptiveRetries(void){return g_adaptiveRetries;}
__declspec(dllexport) u32 STDCALL PVERear360_GetLastFailReason(void){return g_lastFailReason;}
__declspec(dllexport) u32 STDCALL PVERear360_GetAttempts(void){return g_attempts;}
__declspec(dllexport) u32 STDCALL PVERear360_GetServerGo(void){return g_serverGo;}
__declspec(dllexport) u32 STDCALL PVERear360_GetAborted(void){return g_aborted;}
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
