/* Auto WotF - parallel-only companion, WoW 1.12.1 build 5875 Windows x86.
   Focused port of work PositionalSpoof v0.36's aura/mechanic recognition,
   CDataStore spell send and bounded retry watchdog. No game code hooks,
   movement writes, target changes or cast/GCD state mutations.
   Source provenance: new independent implementation from work's reconstructed
   WotFRetry5 lineage; this is NOT a byte-identical copy of the work DLL. */
#if !defined(_M_IX86) && !defined(__i386__)
#error AutoWotF requires WoW 5875 Windows x86
#endif
typedef unsigned char u8;
typedef unsigned short u16;
typedef unsigned int u32;
typedef int s32;
typedef void* ptr;
#define STDCALL __stdcall
#define OBJECT_MANAGER_PTR 0x00B41414u
#define OM_FIRST 0xACu
#define OM_PLAYER_LO 0xC0u
#define OM_PLAYER_HI 0xC4u
#define OBJ_DESCRIPTORS 0x08u
#define OBJ_GUID_LO 0x30u
#define OBJ_GUID_HI 0x34u
#define OBJ_NEXT 0x3Cu
#define UNIT_FIELD_AURA_INDEX 0x2Fu
#define UNIT_FIELD_AURA_COUNT 48u
#define SPELL_RECORDS_BY_ID 0x00C0D788u
#define SPELL_MAX_ID 0x00C0D78Cu
#define SPELL_MECHANIC_OFF 0x14u
#define SPELL_EFFECT_MECHANIC0_OFF 0x13Cu
#define WOTF_SPELL 7744u
#define CMSG_CAST_SPELL 0x12Eu
#define CDATASTORE_VTABLE 0x007FF9E4u
#define CLIENTSERVICES_SEND 0x005AB630u
#define MAX_ATTEMPTS 5u
#define RETRY_MS 180u
#define TICK_MS 30u
#define DLL_PROCESS_ATTACH 1u
#define DLL_PROCESS_DETACH 0u
typedef void (STDCALL *TIMERPROC)(ptr,u32,u32,u32);
__declspec(dllimport) u32 STDCALL SetTimer(ptr,u32,u32,TIMERPROC);
__declspec(dllimport) s32 STDCALL KillTimer(ptr,u32);
__declspec(dllimport) u32 STDCALL GetTickCount(void);
__declspec(dllimport) void* STDCALL GetModuleHandleA(const char*);
#if defined(_MSC_VER)
#pragma comment(linker, "/EXPORT:AutoWotF_GetStatus=_AutoWotF_GetStatus@0")
#pragma comment(linker, "/EXPORT:AutoWotF_GetAttempts=_AutoWotF_GetAttempts@0")
#pragma comment(linker, "/EXPORT:AutoWotF_GetTriggers=_AutoWotF_GetTriggers@0")
#endif

/* Timer callback is serviced by the host game's normal UI message loop,
   like the existing work implementation; never send from a worker thread. */
static volatile u32 g_timer;
static volatile u32 g_enabled=1u;
static volatile u32 g_status; /* 0=waiting, 1=ready, 2=CC active, 3=timer failure */
static volatile u32 g_totalTriggers;
static volatile u32 g_totalAttempts;
static u32 g_lastPlayerLo,g_lastPlayerHi,g_lastAura;
static u32 g_attempts,g_retryAt;
static int g_ccActive;
static u32 g_store[6];
static u8 g_packet[16];

static u32 getPlayer(void){
 u32 om=*(volatile u32*)OBJECT_MANAGER_PTR,first,lo,hi,ob,n=0;
 if(!om)return 0;
 lo=*(volatile u32*)(om+OM_PLAYER_LO);hi=*(volatile u32*)(om+OM_PLAYER_HI);
 if(!lo&&!hi)return 0;
 first=*(volatile u32*)(om+OM_FIRST);ob=first;
 while(ob && !(ob&1u) && n++<4096u){
  if(*(volatile u32*)(ob+OBJ_GUID_LO)==lo && *(volatile u32*)(ob+OBJ_GUID_HI)==hi)return ob;
  ob=*(volatile u32*)(ob+OBJ_NEXT);
 }
 return 0;
}
static int isWotfMechanic(u32 m){return m==1u||m==5u||m==10u;} /* charm/fear/sleep */
static int hasWotfMechanic(u32 spell){
 u32 maxid,table,record,mech,i;
 if(!spell)return 0;
 maxid=*(volatile u32*)SPELL_MAX_ID;
 if(spell>maxid)return 0;
 table=*(volatile u32*)SPELL_RECORDS_BY_ID;
 if(!table)return 0;
 record=*(volatile u32*)(table+spell*4u);
 if(!record)return 0;
 mech=*(volatile u32*)(record+SPELL_MECHANIC_OFF);
 if(isWotfMechanic(mech))return 1;
 for(i=0;i<3;i++){
  mech=*(volatile u32*)(record+SPELL_EFFECT_MECHANIC0_OFF+i*4u);
  if(isWotfMechanic(mech))return 1;
 }
 return 0;
}
static u32 getCcAura(u32 pl){
 u32 d,i,spell;
 if(!pl)return 0;
 d=*(volatile u32*)(pl+OBJ_DESCRIPTORS);
 if(!d)return 0;
 for(i=0;i<UNIT_FIELD_AURA_COUNT;i++){
  spell=*(volatile u32*)(d+(UNIT_FIELD_AURA_INDEX+i)*4u);
  if(hasWotfMechanic(spell))return spell;
 }
 return 0;
}
/* Direct native ClientServices::Send wrapper, exact x86 thiscall ABI and
   packet layout recovered on work. Does not intercept any cast hook. */
__declspec(naked) void STDCALL sendStore(u32 store){
 __asm {
  mov ecx,[esp+4]
  test ecx,ecx
  je short done
  mov eax,CLIENTSERVICES_SEND
  call eax
 done:
  ret 4
 }
}
static void resetCc(u32 lo,u32 hi){
 g_lastPlayerLo=lo;g_lastPlayerHi=hi;
 g_lastAura=0;g_attempts=0;g_retryAt=0;g_ccActive=0;
 g_status=g_timer?1u:0u;
}
static void sendWotf(u32 now){
 /* This store is synchronous, and its ownership remains in this module. */
 *(u32*)(g_packet+0)=CMSG_CAST_SPELL;
 *(u32*)(g_packet+4)=WOTF_SPELL;
 *(u16*)(g_packet+8)=0;
 g_store[0]=CDATASTORE_VTABLE;
 g_store[1]=(u32)g_packet;
 g_store[2]=0;
 g_store[3]=(u32)sizeof(g_packet);
 g_store[4]=10u;
 g_store[5]=0;
 ++g_attempts;++g_totalAttempts;
 g_retryAt=now+RETRY_MS;
 sendStore((u32)g_store);
}
static void tick(u32 now){
 u32 pl,lo,hi,aura;
 if(!g_enabled){resetCc(0,0);return;}
 /* A live object-manager/player pointer is required on every tick. */
 pl=getPlayer();
 if(!pl){resetCc(0,0);return;}
 lo=*(volatile u32*)(pl+OBJ_GUID_LO);hi=*(volatile u32*)(pl+OBJ_GUID_HI);
 if(lo!=g_lastPlayerLo||hi!=g_lastPlayerHi)resetCc(lo,hi);
 aura=getCcAura(pl);
 if(!aura){if(g_ccActive)resetCc(lo,hi);return;}
 if(!g_ccActive){
  g_ccActive=1;g_lastAura=aura;g_attempts=0;g_status=2u;
  ++g_totalTriggers;sendWotf(now);return;
 }
 /* Changed CC source during the same continuous CC period is one bounded
    transaction, not a new five-attempt burst. */
 g_lastAura=aura;
 if(g_attempts<MAX_ATTEMPTS && (s32)(now-g_retryAt)>=0)sendWotf(now);
}
static void STDCALL TimerCallback(ptr hwnd,u32 msg,u32 id,u32 now){
 (void)hwnd;(void)msg;(void)id;
 if(g_timer)tick(now);
}
__declspec(dllexport) u32 STDCALL AutoWotF_GetStatus(void){return g_status;}
__declspec(dllexport) u32 STDCALL AutoWotF_GetAttempts(void){return g_totalAttempts;}
__declspec(dllexport) u32 STDCALL AutoWotF_GetTriggers(void){return g_totalTriggers;}
int STDCALL DllMain(ptr module,u32 reason,ptr reserved){
 (void)module;(void)reserved;
 if(reason==DLL_PROCESS_ATTACH){
  /* Do not start a timer for a different process image. */
  if(!GetModuleHandleA("WoW.exe") && !(*(volatile u16*)0x00400000u==0x5A4Du))return 1;
  g_timer=SetTimer(0,0,TICK_MS,TimerCallback);
  g_status=g_timer?1u:3u;
 }else if(reason==DLL_PROCESS_DETACH){
  if(g_timer){KillTimer(0,g_timer);g_timer=0;}
  resetCc(0,0);
 }
 return 1;
}
