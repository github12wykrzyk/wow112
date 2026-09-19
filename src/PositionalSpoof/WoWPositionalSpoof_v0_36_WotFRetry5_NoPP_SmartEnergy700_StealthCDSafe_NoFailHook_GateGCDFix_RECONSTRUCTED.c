/* WoW 1.12.1 build 5875 - reconstructed source for final binary:
   WoWPositionalSpoof_v0_36_WotFRetry5_NoPP_SmartEnergy700_StealthCDSafe_NoFailHook_GateGCDFix.dll

   RECONSTRUCTION STATUS:
     - exact v0.36 NoPP SmartEnergy700 SmoothStealth GateGCDFix ancestor source
     - WotFRetry5 and final StealthCDSafe/NoFailHook changes recovered from byte diffs
       between preserved runtime DLLs
     - original runtime log strings are intentionally retained because the final DLL
       was binary-patched and still contains the old SmoothStealth strings
     - this is a source-level representation of final behavior, not claimed to be an
       original final .c file (the final DLL lineage is binary-patched)

   Base lineage: v0.36 NoPP SmartEnergy700 SmoothStealth GateGCDFix.
   Work-candidate extension: W112_CONTROL_API_V1 adds live PvE/PvP opener
   energy-gate controls. This control extension is not part of the recovered
   accepted runtime DLL lineage.
   Client-only / DLL+EXE experiment.

   Strategy:
     positional cast -> candidate spoof double-heartbeat -> cast immediately
     -> if authoritative positional failure arrives, move to the next candidate
        around the target and resend the same cloned CMSG_CAST_SPELL immediately
     -> up to eight angular candidates, prioritized around the predicted valid half-plane
     -> Ambush uses the same behind-target adaptive bypass as Backstab
     -> autonomous Pick Pocket is disabled in this DLL; it is handled by the external AutoLootPP module
     -> Stealth speed override uses the exact native CMovement::SetRunSpeed path, so an
        already-held movement command refreshes its live current-speed cache without a key re-press
     -> suppressed/held opener no longer runs the original 0x6E58FB StartGlobalCooldown call;
        the client GCD is deferred until the cloned opener packet is actually transmitted
     -> the player/target context is frozen before ENERGY_GATE starts, fixing the old
        immediate ENERGY_GATE_CANCEL invalid_state loop caused by g_target still being zero
     -> the skipped native StartGlobalCooldown EDX argument is captured at 0x6E58FB and
        replayed exactly on deferred release instead of forcing the wrong GCD slot
     -> stealthed Backstab/Ambush is held until a runtime-configurable PvE/PvP
        pre-tick window (default 700 ms) before the next predicted energy tick
     -> ordinary outgoing movement packets remain enabled, but X/Y/Z/O are rewritten
        to the currently active candidate until success/final failure
     -> real server position restored only after SPELL_GO/final failure/timeout.

   This avoids depending on a single stale target orientation snapshot and avoids
   client-side Sleep/blocking.

   Exact client build expected:
   SHA-256 97ea82ab7a82ed88bc5a155ab9bbf7e0bcdb5b9f892a47c6f8edabe1496bfc75

   Log: WoWPositionalSpoof_v0_36_NoPP_SmartEnergy700_SmoothStealth_GateGCDFix.log
*/

#include "../common/W112ControlAPI.h"

#if defined(_MSC_VER)
#pragma comment(linker, "/EXPORT:W112_Control_GetModuleV1=_W112_Control_GetModuleV1@0")
#endif

typedef unsigned char BYTE;
typedef unsigned short WORD;
typedef unsigned long DWORD;
typedef long LONG;
typedef void *PVOID;
typedef unsigned long ULONG;
typedef void *HANDLE;
int _fltused=0;

#define TRUE 1
#define DLL_PROCESS_ATTACH 1
#define DLL_PROCESS_DETACH 0
#define PAGE_EXECUTE_READWRITE 0x40
#define FILE_APPEND_DATA 0x4UL
#define FILE_SHARE_READ 0x1UL
#define FILE_SHARE_WRITE 0x2UL
#define OPEN_ALWAYS 4UL
#define FILE_ATTRIBUTE_NORMAL 0x80UL
#define INVALID_HANDLE_VALUE ((HANDLE)(LONG)-1)
#define STDCALL __stdcall
#define CDECL __cdecl
#define THISCALL __thiscall
#define FASTCALL __fastcall

/* build 5875 addresses */
#define CAST_SEND_SITE          0x006E5872UL
#define GCD_CALL_SITE           0x006E58FBUL
#define START_GLOBAL_COOLDOWN   0x006E2DE0UL
#define CAST_FAIL_SITE          0x006E73ACUL
#define SPELL_GO_SITE           0x006E768BUL
#define MOVEMENT_SEND_SITE      0x00600ACAUL
#define SPELL_GO_CONTINUE       0x006E7691UL
#define CLIENTSERVICES_SEND     0x005AB630UL
#define SEND_MOVEMENT_WRAPPER   0x00600A10UL
#define OBJECT_MANAGER_PTR      0x00B41414UL
#define TARGET_GUID_PTR         0x00B4E2D8UL
#define MOUSEOVER_GUID_PTR      0x00B4E2C8UL
#define MSG_MOVE_HEARTBEAT      0x000000EEUL

#define OBJ_TYPE                0x14UL
#define OBJ_GUID_LO             0x30UL
#define OBJ_GUID_HI             0x34UL
#define OBJ_NEXT                0x3CUL
#define OBJ_DESCRIPTORS         0x08UL
#define UNIT_FIELD_AURA_INDEX   0x2FUL
#define UNIT_FIELD_AURA_COUNT   48UL
#define UNIT_X                  0x9B8UL
#define UNIT_Y                  0x9BCUL
#define UNIT_Z                  0x9C0UL
#define UNIT_O                  0x9C4UL
#define UNIT_MOVEMENT           0x9A8UL
#define UNIT_RUN_SPEED          0xA34UL
#define UNIT_CURRENT_SPEED      0xA2CUL
#define CMOVEMENT_SET_RUN_SPEED 0x007C7030UL
#define OM_FIRST                0xACUL
#define OM_LOCAL_GUID_LO        0xC0UL
#define OM_LOCAL_GUID_HI        0xC4UL

#define SPOOF_DISTANCE          2.0f
#define MAX_TARGET_DIST2        100.0f
#define MAX_CANDIDATES          8UL
#define RESULT_TIMEOUT_MS       350UL
#define RESULT_RESTORE_MS       1UL
#define PP_RESULT_TIMEOUT_MS     180UL
#define PP_OPENER_DELAY_MS     100UL
#define PP_AUTO_SCAN_MS          25UL
#define PP_AUTO_TIMEOUT_MS      450UL
#define PP_AUTO_RANGE2           20.25f
#define PP_LOOT_CONFIRM_MS       250UL
#define PP_RETRY_DELAY_MS        120UL
#define PP_MAX_ATTEMPTS          3UL
#define PP_RETRY_COOLDOWN_MS     750UL
#define CMSG_CAST_SPELL       0x12EUL
#define TARGET_FLAG_UNIT        0x02U
#define CDATASTORE_VTABLE  0x007FF9E4UL
#define MAX_PACKET              512UL
#define PICK_POCKET_SPELL       921UL
#define WILL_OF_THE_FORSAKEN_SPELL 7744UL
#define SPELL_RECORDS_BY_ID       0x00C0D788UL
#define SPELL_MAX_ID              0x00C0D78CUL
#define SPELL_MECHANIC_OFF        0x14UL
#define SPELL_EFFECT_MECHANIC0_OFF 0x13CUL
#define MECHANIC_CHARM            1UL
#define MECHANIC_FEAR             5UL
#define MECHANIC_SLEEP            10UL
#define WOTF_RETRY_DELAY_MS        60UL /* WotFRetry5 binary patch: 0x5A -> 0x3C */
#define WOTF_MAX_ATTEMPTS          5UL  /* WotFRetry5 binary patch: 3 -> 5 */
#define PP_TRACK_SLOTS          1024UL
#define STEALTH_SPEED_TIMER_MS   5UL
#define NORMAL_RUN_SPEED        7.0f
#define CGLootInfo_HAS_LOOT      0x004C2A70UL
#define PLAYER_FIELD_COINAGE_INDEX 0x498UL
#define UNIT_FIELD_POWER4_INDEX     0x1AUL
#define ENERGY_TICK_MS                     2000UL
#define ENERGY_GATE_DEFAULT_WINDOW_MS        700UL
#define ENERGY_GATE_MIN_WINDOW_MS            100UL
#define ENERGY_GATE_MAX_WINDOW_MS           1500UL
#define ENERGY_GATE_WINDOW_STEP_MS            50UL
#define CLIENT_PENDING_SPELLCAST  0x00CEAC48UL
#define CLIENT_CASTING_SPELL_ID   0x00CECA88UL
#define CLIENT_CAST_HANDLE        0x00CECA8CUL
#define CLIENT_TARGETING_STATE     0x00CECAC0UL
#define CLIENT_CURRENT_ACTION_GUID_LO 0x00CECAB0UL
#define CLIENT_CURRENT_ACTION_GUID_HI 0x00CECAB4UL
#define CLIENT_PREV_CASTING_SPELL_ID  0x00CECAA8UL
#define CLIENT_PREV_ACTION_GUID_LO    0x00CECB20UL
#define CLIENT_PREV_ACTION_GUID_HI    0x00CECB24UL
#define CLIENT_CAST_MISC              0x00CECAACUL
#define SPELL_STOP_TARGETING_INTERNAL 0x006E4900UL
#define ENERGY_GATE_MAX_HOLD_MS      1900UL

#define SETTING_PVE_GATE_ENABLED       1u
#define SETTING_PVE_WINDOW_MS          2u
#define SETTING_PVP_GATE_ENABLED       3u
#define SETTING_PVP_WINDOW_MS          4u
#define OPENER_TIMING_CONTROL_VERSION  0x00010000u

#define PHASE_IDLE              0
#define PHASE_WAIT_RESULT       1
#define PHASE_RESTORE           2
#define PHASE_WAIT_PP            3
#define PHASE_PP_DELAY           4
#define PHASE_ENERGY_GATE        5

typedef LONG (STDCALL *PFN_NtProtectVirtualMemory)(HANDLE,PVOID*,ULONG*,ULONG,ULONG*);
typedef HANDLE (STDCALL *PFN_CreateFileA)(const char*,DWORD,DWORD,PVOID,DWORD,DWORD,HANDLE);
typedef BOOL (STDCALL *PFN_WriteFile)(HANDLE,const void*,DWORD,DWORD*,PVOID);
typedef BOOL (STDCALL *PFN_CloseHandle)(HANDLE);
typedef void (STDCALL *PFN_TIMERPROC)(PVOID,DWORD,DWORD,DWORD);
typedef DWORD (STDCALL *PFN_SetTimer)(PVOID,DWORD,DWORD,PFN_TIMERPROC);
typedef BOOL (STDCALL *PFN_KillTimer)(PVOID,DWORD);
typedef int (CDECL *PFN_CGLootInfo_HasLoot)(void);
typedef void (CDECL *PFN_SpellStopTargetingInternal)(void);
typedef int (THISCALL *PFN_CMovementSetRunSpeed)(void*,float);
typedef void (FASTCALL *PFN_StartGlobalCooldown)(DWORD,DWORD);

static PFN_NtProtectVirtualMemory pProtect;
static PFN_CreateFileA pCreate;
static PFN_WriteFile pWrite;
static PFN_CloseHandle pClose;
static PFN_SetTimer pSetTimer;
static PFN_KillTimer pKillTimer;
static HANDLE g_logHandle;
static int installed;

static DWORD g_player;
static DWORD g_spoofSpell;
static DWORD g_timer;
static int g_phase;
static int g_castPending;
static int g_suppressCurrent;
static int g_insideOriginalQueue;
static int g_skipNativeGcdCurrent;
static int g_deferredClientGcd;
static DWORD g_deferredClientGcdArg;
static DWORD g_deferredUiClear; /* 0=none, 1=pp_join, 2=pp_wait, 3=energy_hold */
static int g_allowMovementSend;
static DWORD g_rewrittenMoveCount;
static DWORD g_target;
static DWORD g_candidate;
static DWORD g_cloneTemplate[6];
static DWORD g_sendStoreHdr[6];
static BYTE g_packetTemplate[MAX_PACKET];
static BYTE g_sendPacket[MAX_PACKET];
static DWORD g_ppGuidLo[PP_TRACK_SLOTS];
static DWORD g_ppGuidHi[PP_TRACK_SLOTS];
static DWORD g_ppObject[PP_TRACK_SLOTS];
static DWORD g_ppNext;
static DWORD g_ppPendingTarget;
static DWORD g_ppPendingSource; /* 1=selected target, 2=mouseover */
static int g_ppAutoPending;
static DWORD g_ppPendingSinceTick;
static DWORD g_lastTimerTick;
static DWORD g_energyGateStartTick;
static DWORD g_energyGateReleaseDelay;
static DWORD g_energyGateTickSerialAtStart;
static DWORD g_energyGateWindowMsForCast;
static int g_energyGateEnabledForCast;
static int g_energyGatePvpForCast;
static DWORD g_ppLastScanTick;
static int g_ppAwaitLoot;
static DWORD g_ppLootSinceTick;
static DWORD g_ppMoneyBefore;
static DWORD g_ppAttemptTarget;
static DWORD g_ppAttemptCount;
static DWORD g_ppRetryAfterTick;
static DWORD g_speedTimer;
static DWORD g_speedAura;
static DWORD g_speedReapplyCount;
static int g_speedWasStealthed;
static int g_speedPenaltyLogged;
static DWORD g_energyPrev;
static int g_energyPrevValid;
static DWORD g_energyLastTick;
static DWORD g_energyTickSerial;
static int g_energySynced;
static int g_energyGatePassed;
static volatile DWORD g_cfgPveGateEnabled=1UL;
static volatile DWORD g_cfgPveWindowMs=ENERGY_GATE_DEFAULT_WINDOW_MS;
static volatile DWORD g_cfgPvpGateEnabled=1UL;
static volatile DWORD g_cfgPvpWindowMs=ENERGY_GATE_DEFAULT_WINDOW_MS;
static W112_ControlSettingV1 g_controlSettings[4];
static volatile DWORD g_controlDescriptorReady;
static int g_wotfCcActive;
static DWORD g_wotfAura;
static DWORD g_wotfMechanic;
static DWORD g_wotfLastSendTick;
static DWORD g_wotfRetryTick;
static DWORD g_wotfAttempts;
static int g_wotfRetryPending;
static DWORD g_wotfStoreHdr[6];
static BYTE g_wotfPacket[16];

static const char logName[]="WoWPositionalSpoof_v0_36_NoPP_SmartEnergy700_SmoothStealth_GateGCDFix.log";
static const char nProtect[]="NtProtectVirtualMemory";
static const char nCreate[]="CreateFileA";
static const char nWrite[]="WriteFile";
static const char nClose[]="CloseHandle";
static const char nSetTimer[]="SetTimer";
static const char nKillTimer[]="KillTimer";

static const BYTE sendOrig[5]={0xE8,0xB9,0x5D,0xEC,0xFF};
static const BYTE gcdCallOrig[5]={0xE8,0xE0,0xD4,0xFF,0xFF};
static const BYTE failOrig[5]={0xE8,0x4F,0xA6,0xFF,0xFF};
static const BYTE goOrig[6]={0x8B,0x4D,0xF0,0x8B,0x55,0xF4};
static const BYTE moveSendOrig[5]={0xE8,0x61,0xAB,0xFA,0xFF};

static int eqs(const char*a,const char*b){while(*a&&*b){if(*a!=*b)return 0;++a;++b;}return *a==*b;}
static int eqb(const BYTE*a,const BYTE*b,DWORD n){DWORD i;for(i=0;i<n;++i)if(a[i]!=b[i])return 0;return 1;}
static void cp(BYTE*d,const BYTE*s,DWORD n){DWORD i;for(i=0;i<n;++i)d[i]=s[i];}

static void *findexp(BYTE *base,const char*w){
 DWORD pe,er,es,nn,fr,nr,orv,i; BYTE*nt,*op,*ex; DWORD*names,*funcs; WORD*ords;
 if(!base||*(WORD*)base!=0x5A4D)return 0; pe=*(DWORD*)(base+0x3c); nt=base+pe;
 if(*(DWORD*)nt!=0x4550)return 0; op=nt+24; if(*(WORD*)op!=0x10b)return 0;
 er=*(DWORD*)(op+0x60); es=*(DWORD*)(op+0x64); if(!er)return 0; ex=base+er;
 nn=*(DWORD*)(ex+0x18); fr=*(DWORD*)(ex+0x1c); nr=*(DWORD*)(ex+0x20); orv=*(DWORD*)(ex+0x24);
 funcs=(DWORD*)(base+fr); names=(DWORD*)(base+nr); ords=(WORD*)(base+orv);
 for(i=0;i<nn;++i){const char*n=(const char*)(base+names[i]); if(eqs(n,w)){DWORD r=funcs[ords[i]]; if(r>=er&&r<er+es)return 0; return base+r;}}
 return 0;
}
static BYTE *peb(void){BYTE*p; __asm {
 mov eax, fs:[0x30]
 mov p, eax
 } return p;}
static void *findall(const char*w){BYTE*p=peb(),*ldr,*head,*cur;unsigned g=0;if(!p)return 0;ldr=*(BYTE**)(p+0xc);if(!ldr)return 0;head=ldr+0x14;cur=*(BYTE**)head;while(cur&&cur!=head&&g++<128){BYTE*e=cur-8,*b=*(BYTE**)(e+0x18);void*x=findexp(b,w);if(x)return x;cur=*(BYTE**)cur;}return 0;}

static void openlog(void){if(g_logHandle||!pCreate)return;g_logHandle=pCreate(logName,FILE_APPEND_DATA,FILE_SHARE_READ|FILE_SHARE_WRITE,0,OPEN_ALWAYS,FILE_ATTRIBUTE_NORMAL,0);if(g_logHandle==INVALID_HANDLE_VALUE)g_logHandle=0;}
static void closelog(void){if(g_logHandle&&pClose){pClose(g_logHandle);g_logHandle=0;}}
static void lograw(const char*s,DWORD n){DWORD wr=0;if(!g_logHandle)openlog();if(!g_logHandle||!pWrite)return;pWrite(g_logHandle,s,n,&wr,0);}
static char *ap(char*p,const char*s){while(*s)*p++=*s++;return p;}
static char *dec(char*p,DWORD v){char t[16];int n=0;if(!v){*p++='0';return p;}while(v){t[n++]=(char)('0'+v%10);v/=10;}while(n)*p++=t[--n];return p;}
static char hx(unsigned v){return (char)(v<10?'0'+v:'A'+v-10);}
static char *hex8(char*p,BYTE v){*p++=hx(v>>4);*p++=hx(v&15);return p;}
static char *hex32(char*p,DWORD v){int i;for(i=7;i>=0;--i)*p++=hx((v>>(i*4))&15);return p;}
static void logs(const char*s){DWORD n=0;while(s[n])++n;lograw(s,n);}
static DWORD fbits(float f){union {float f; DWORD d;}u;u.f=f;return u.d;}

static void logSpellText(const char*tag,DWORD spell){char b[128],*p=b;p=ap(p,tag);p=ap(p," spell=");p=dec(p,spell);p=ap(p,"\r\n");lograw(b,(DWORD)(p-b));}
static void logDelayText(const char*tag,DWORD spell,DWORD ms){char b[160],*p=b;p=ap(p,tag);p=ap(p," spell=");p=dec(p,spell);p=ap(p," delay_ms=");p=dec(p,ms);p=ap(p,"\r\n");lograw(b,(DWORD)(p-b));}
static void logCountText(const char*tag,DWORD spell,DWORD count){char b[160],*p=b;p=ap(p,tag);p=ap(p," spell=");p=dec(p,spell);p=ap(p," count=");p=dec(p,count);p=ap(p,"\r\n");lograw(b,(DWORD)(p-b));}

static int isBackstab(DWORD s){return s==53||s==2589||s==2590||s==2591||s==8721||s==11279||s==11280||s==11281;}
static int isAmbush(DWORD s){return s==8676||s==8724||s==8725||s==11267||s==11268||s==11269;}
static int isBehindSpell(DWORD s){return isBackstab(s)||isAmbush(s);}
static int isGouge(DWORD s){return s==1776||s==1777||s==8629||s==11285||s==11286;}
static int isStealthAura(DWORD s){return s==1784||s==1785||s==1786||s==1787;}
static int isWotfMechanic(DWORD m){return m==MECHANIC_CHARM||m==MECHANIC_FEAR||m==MECHANIC_SLEEP;}
static DWORD getSpellRec(DWORD spell){
 DWORD table,maxid;if(!spell)return 0;maxid=*(DWORD*)SPELL_MAX_ID;if(spell>maxid)return 0;table=*(DWORD*)SPELL_RECORDS_BY_ID;if(!table)return 0;return *(DWORD*)(table+spell*4UL);
}
static int spellHasWotfMechanic(DWORD spell,DWORD *outMech){
 DWORD r,m,i;if(outMech)*outMech=0;r=getSpellRec(spell);if(!r)return 0;
 m=*(DWORD*)(r+SPELL_MECHANIC_OFF);if(isWotfMechanic(m)){if(outMech)*outMech=m;return 1;}
 for(i=0;i<3;i++){m=*(DWORD*)(r+SPELL_EFFECT_MECHANIC0_OFF+i*4UL);if(isWotfMechanic(m)){if(outMech)*outMech=m;return 1;}}
 return 0;
}
static DWORD findWotfCcAura(DWORD pl,DWORD *outMech){
 DWORD d,i,s,m;if(outMech)*outMech=0;if(!pl)return 0;d=*(DWORD*)(pl+OBJ_DESCRIPTORS);if(!d)return 0;
 for(i=0;i<UNIT_FIELD_AURA_COUNT;i++){s=*(DWORD*)(d+(UNIT_FIELD_AURA_INDEX+i)*4UL);if(s&&spellHasWotfMechanic(s,&m)){if(outMech)*outMech=m;return s;}}
 return 0;
}
static DWORD getPlayer(void);
static DWORD playerEnergy(DWORD pl){DWORD d;if(!pl)return 0;d=*(DWORD*)(pl+OBJ_DESCRIPTORS);if(!d)return 0;return *(DWORD*)(d+UNIT_FIELD_POWER4_INDEX*4UL);}
static void trackEnergyTick(DWORD tick){
 DWORD pl,e,delta,elapsed;pl=getPlayer();if(!pl){g_energyPrevValid=0;return;}e=playerEnergy(pl);if(e>1000){g_energyPrevValid=0;return;}
 if(g_energyPrevValid&&e>g_energyPrev){
   delta=e-g_energyPrev;
   if(delta<=20){
     if(!g_energySynced){g_energyLastTick=tick;g_energyTickSerial++;g_energySynced=1;logs("ENERGY_TICK_SYNC\r\n");}
     else {elapsed=(DWORD)(tick-g_energyLastTick);if(elapsed>=1200UL){g_energyLastTick=tick;g_energyTickSerial++;logs("ENERGY_TICK\r\n");}}
   }
 }
 g_energyPrev=e;g_energyPrevValid=1;
}
static DWORD energyTimeToNext(DWORD tick){DWORD elapsed,mod;if(!g_energySynced)return 0xFFFFFFFFUL;elapsed=(DWORD)(tick-g_energyLastTick);mod=elapsed%ENERGY_TICK_MS;return mod?ENERGY_TICK_MS-mod:ENERGY_TICK_MS;}
static void logEnergyGate(const char*tag,DWORD energy,DWORD left){char b[180],*p=b;p=ap(p,tag);p=ap(p," energy=");p=dec(p,energy);p=ap(p," next_ms=");p=dec(p,left);p=ap(p,"\r\n");lograw(b,(DWORD)(p-b));}
static void selectEnergyGateConfig(DWORD targetType){
 char b[180],*p=b;
 g_energyGatePvpForCast=(targetType==4UL)?1:0;
 if(g_energyGatePvpForCast){g_energyGateEnabledForCast=g_cfgPvpGateEnabled?1:0;g_energyGateWindowMsForCast=g_cfgPvpWindowMs;}
 else {g_energyGateEnabledForCast=g_cfgPveGateEnabled?1:0;g_energyGateWindowMsForCast=g_cfgPveWindowMs;}
 p=ap(p,"ENERGY_GATE_CONFIG mode=");p=ap(p,g_energyGatePvpForCast?"PVP":"PVE");
 p=ap(p," enabled=");p=dec(p,(DWORD)(g_energyGateEnabledForCast?1:0));
 p=ap(p," window_ms=");p=dec(p,g_energyGateWindowMsForCast);p=ap(p,"\r\n");lograw(b,(DWORD)(p-b));
}
static float fcos1(float x){float r;__asm {
 fld x
 fcos
 fstp r
 }return r;}
static float fsin1(float x){float r;__asm {
 fld x
 fsin
 fstp r
 }return r;}

static DWORD findObject(DWORD lo,DWORD hi){
 DWORD om=*(DWORD*)OBJECT_MANAGER_PTR,p,n=0;
 if(!om)return 0;p=*(DWORD*)(om+OM_FIRST);
 while(p && !(p&1) && n++<4096){if(*(DWORD*)(p+OBJ_GUID_LO)==lo && *(DWORD*)(p+OBJ_GUID_HI)==hi)return p;p=*(DWORD*)(p+OBJ_NEXT);}return 0;
}
static DWORD getPlayer(void){DWORD om=*(DWORD*)OBJECT_MANAGER_PTR;if(!om)return 0;return findObject(*(DWORD*)(om+OM_LOCAL_GUID_LO),*(DWORD*)(om+OM_LOCAL_GUID_HI));}
static DWORD getTarget(void){return findObject(*(DWORD*)TARGET_GUID_PTR,*(DWORD*)(TARGET_GUID_PTR+4));}
static DWORD getMouseover(void){return findObject(*(DWORD*)MOUSEOVER_GUID_PTR,*(DWORD*)(MOUSEOVER_GUID_PTR+4));}

static DWORD playerStealthAura(DWORD pl){
 DWORD desc,i,spell;
 if(!pl)return 0;desc=*(DWORD*)(pl+OBJ_DESCRIPTORS);if(!desc)return 0;
 for(i=0;i<UNIT_FIELD_AURA_COUNT;++i){spell=*(DWORD*)(desc+(UNIT_FIELD_AURA_INDEX+i)*4);if(isStealthAura(spell))return spell;}
 return 0;
}
static int playerIsStealthed(DWORD pl){return playerStealthAura(pl)!=0;}

static void logStealthSpeedEnter(DWORD aura,float raw){
 char b[220],*p=b;DWORD pct=0;if(raw>0.0f)pct=(DWORD)((raw*100.0f/NORMAL_RUN_SPEED)+0.5f);
 p=ap(p,"STEALTH_SPEED_PENALTY aura=");p=dec(p,aura);p=ap(p," raw=0x");p=hex32(p,fbits(raw));p=ap(p," normal=0x");p=hex32(p,fbits(NORMAL_RUN_SPEED));p=ap(p," pct=");p=dec(p,pct);p=ap(p,"\r\n");lograw(b,(DWORD)(p-b));
}
static void logStealthAuraEnter(DWORD aura,float raw){char b[180],*p=b;p=ap(p,"STEALTH_AURA_ENTER aura=");p=dec(p,aura);p=ap(p," initial_raw=0x");p=hex32(p,fbits(raw));p=ap(p,"\r\n");lograw(b,(DWORD)(p-b));}
static void logStealthSpeedExit(void){char b[150],*p=b;p=ap(p,"STEALTH_SPEED_EXIT native_sets=");p=dec(p,g_speedReapplyCount);p=ap(p,"\r\n");lograw(b,(DWORD)(p-b));}
static int setNativeRunSpeed(DWORD pl,float speed){
 PFN_CMovementSetRunSpeed f=(PFN_CMovementSetRunSpeed)CMOVEMENT_SET_RUN_SPEED;
 if(!pl||!f)return 0;
 return f((void*)(pl+UNIT_MOVEMENT),speed);
}
static void logStealthNativeSet(float raw0,float cache0,float raw1,float cache1,int changed){
 char b[260],*p=b;p=ap(p,"STEALTH_SPEED_NATIVE_SET raw_before=0x");p=hex32(p,fbits(raw0));p=ap(p," current_before=0x");p=hex32(p,fbits(cache0));p=ap(p," raw_after=0x");p=hex32(p,fbits(raw1));p=ap(p," current_after=0x");p=hex32(p,fbits(cache1));p=ap(p," changed=");p=dec(p,(DWORD)(changed?1:0));p=ap(p,"\r\n");lograw(b,(DWORD)(p-b));
}
static void applyStealthSpeed(void){
 DWORD pl=getPlayer(),aura;float cur,cache0,raw1,cache1;int changed;
 if(!pl){g_speedWasStealthed=0;g_speedAura=0;g_speedReapplyCount=0;g_speedPenaltyLogged=0;return;}
 aura=playerStealthAura(pl);
 if(!aura){if(g_speedWasStealthed)logStealthSpeedExit();g_speedWasStealthed=0;g_speedAura=0;g_speedReapplyCount=0;g_speedPenaltyLogged=0;return;}
 cur=*(float*)(pl+UNIT_RUN_SPEED);
 if(!g_speedWasStealthed||g_speedAura!=aura){g_speedWasStealthed=1;g_speedAura=aura;g_speedReapplyCount=0;g_speedPenaltyLogged=0;logStealthAuraEnter(aura,cur);}
 /* Exact 5875 native CMovement::SetRunSpeed (0x7C7030) updates +0x8C AND
    refreshes the live current-speed cache at CMovement+0x84 via 0x7C5C20.
    A raw unit+0xA34 write changed only the speed field, so an already-running
    movement command could keep using the old cached Stealth speed until a new key edge. */
 if(cur>0.1f&&cur<NORMAL_RUN_SPEED){
   if(!g_speedPenaltyLogged){logStealthSpeedEnter(aura,cur);g_speedPenaltyLogged=1;}
   cache0=*(float*)(pl+UNIT_CURRENT_SPEED);
   changed=setNativeRunSpeed(pl,NORMAL_RUN_SPEED);
   raw1=*(float*)(pl+UNIT_RUN_SPEED);cache1=*(float*)(pl+UNIT_CURRENT_SPEED);
   ++g_speedReapplyCount;
   if(g_speedReapplyCount<=8)logStealthNativeSet(cur,cache0,raw1,cache1,changed);
 }
}

static int ppWasTried(DWORD tg){
 DWORD lo,hi,i;if(!tg)return 1;lo=*(DWORD*)(tg+OBJ_GUID_LO);hi=*(DWORD*)(tg+OBJ_GUID_HI);
 for(i=0;i<PP_TRACK_SLOTS;++i)if(g_ppObject[i]==tg&&g_ppGuidLo[i]==lo&&g_ppGuidHi[i]==hi)return 1;
 return 0;
}
static void ppMarkTried(DWORD tg){
 DWORD i;if(!tg)return;i=g_ppNext++%PP_TRACK_SLOTS;g_ppObject[i]=tg;g_ppGuidLo[i]=*(DWORD*)(tg+OBJ_GUID_LO);g_ppGuidHi[i]=*(DWORD*)(tg+OBJ_GUID_HI);
}
static DWORD playerMoney(DWORD pl){
 DWORD desc;if(!pl)return 0;desc=*(DWORD*)(pl+OBJ_DESCRIPTORS);if(!desc)return 0;return *(DWORD*)(desc+PLAYER_FIELD_COINAGE_INDEX*4);
}
static int ppInRange(DWORD pl,DWORD tg){
 float dx,dy;if(!pl||!tg)return 0;dx=*(float*)(pl+UNIT_X)-*(float*)(tg+UNIT_X);dy=*(float*)(pl+UNIT_Y)-*(float*)(tg+UNIT_Y);return dx*dx+dy*dy<=PP_AUTO_RANGE2;
}
static int clientHasLoot(void){PFN_CGLootInfo_HasLoot f=(PFN_CGLootInfo_HasLoot)CGLootInfo_HAS_LOOT;return f?f():0;}
static void ppResetAttempts(DWORD tg){if(g_ppAttemptTarget!=tg){g_ppAttemptTarget=tg;g_ppAttemptCount=0;}}

__declspec(naked) void STDCALL sendHeartbeatRaw(DWORD unit){
 __asm {
   mov ecx,[esp+4]
   test ecx,ecx
   je short hb_done
   push MSG_MOVE_HEARTBEAT
   mov eax,SEND_MOVEMENT_WRAPPER
   call eax
 hb_done:
   ret 4
 }
}
static void sendHeartbeat(DWORD unit){
 g_allowMovementSend=1;
 sendHeartbeatRaw(unit);
 g_allowMovementSend=0;
}
__declspec(naked) void STDCALL sendStore(DWORD store){
 __asm {
   mov ecx,[esp+4]
   test ecx,ecx
   je short ss_done
   mov eax,CLIENTSERVICES_SEND
   call eax
 ss_done:
   ret 4
 }
}

static void logWotfTrigger(const char*tag,DWORD aura,DWORD mechanic,DWORD attempt){
 char b[220],*p=b;p=ap(p,tag);p=ap(p," aura=");p=dec(p,aura);p=ap(p," mechanic=");p=dec(p,mechanic);p=ap(p," attempt=");p=dec(p,attempt);p=ap(p,"\r\n");lograw(b,(DWORD)(p-b));
}
static void sendAutoWotf(DWORD aura,DWORD mechanic,DWORD tick){
 DWORD size=10;
 *(DWORD*)(g_wotfPacket+0)=CMSG_CAST_SPELL;
 *(DWORD*)(g_wotfPacket+4)=WILL_OF_THE_FORSAKEN_SPELL;
 *(unsigned short*)(g_wotfPacket+8)=0;
 g_wotfStoreHdr[0]=CDATASTORE_VTABLE;g_wotfStoreHdr[1]=(DWORD)g_wotfPacket;g_wotfStoreHdr[2]=0;
 g_wotfStoreHdr[3]=(DWORD)sizeof(g_wotfPacket);g_wotfStoreHdr[4]=size;g_wotfStoreHdr[5]=0;
 ++g_wotfAttempts;g_wotfLastSendTick=tick;g_wotfAura=aura;g_wotfMechanic=mechanic;g_wotfRetryPending=0;
 logWotfTrigger("AUTO_WOTF_SEND",aura,mechanic,g_wotfAttempts);
 sendStore((DWORD)g_wotfStoreHdr);
}
static void autoWotfTick(DWORD tick){
 DWORD pl,aura,mechanic=0;pl=getPlayer();if(!pl){g_wotfCcActive=0;g_wotfRetryPending=0;g_wotfAttempts=0;return;}
 aura=findWotfCcAura(pl,&mechanic);
 if(!aura){
   if(g_wotfCcActive)logs("AUTO_WOTF_CC_CLEAR\r\n");
   g_wotfCcActive=0;g_wotfAura=0;g_wotfMechanic=0;g_wotfAttempts=0;g_wotfRetryPending=0;g_wotfRetryTick=0;return;
 }
 if(!g_wotfCcActive){g_wotfCcActive=1;g_wotfAttempts=0;g_wotfRetryPending=0;g_wotfAura=aura;g_wotfMechanic=mechanic;logWotfTrigger("AUTO_WOTF_CC_DETECTED",aura,mechanic,0);sendAutoWotf(aura,mechanic,tick);return;}
 if(g_wotfRetryPending&&g_wotfAttempts<WOTF_MAX_ATTEMPTS&&(LONG)(tick-g_wotfRetryTick)>=0){sendAutoWotf(aura,mechanic,tick);}
}

static void logSpoof(DWORD spell,DWORD player,DWORD target,float x,float y,float z,float o,float px,float py,float pz,float po,float sx,float sy,float sz,float so){
 char b[420],*p=b;p=ap(p,"SPOOF_PRE");p=ap(p," spell=");p=dec(p,spell);
 p=ap(p," player=0x");p=hex32(p,player);p=ap(p," target=0x");p=hex32(p,target);
 p=ap(p," tx=0x");p=hex32(p,fbits(x));p=ap(p," ty=0x");p=hex32(p,fbits(y));p=ap(p," tz=0x");p=hex32(p,fbits(z));p=ap(p," to=0x");p=hex32(p,fbits(o));
 p=ap(p," px=0x");p=hex32(p,fbits(px));p=ap(p," py=0x");p=hex32(p,fbits(py));p=ap(p," pz=0x");p=hex32(p,fbits(pz));p=ap(p," po=0x");p=hex32(p,fbits(po));
 p=ap(p," sx=0x");p=hex32(p,fbits(sx));p=ap(p," sy=0x");p=hex32(p,fbits(sy));p=ap(p," sz=0x");p=hex32(p,fbits(sz));p=ap(p," so=0x");p=hex32(p,fbits(so));p=ap(p,"\r\n");lograw(b,(DWORD)(p-b));
}

/* Preserve an immutable template of the temporary stack CDataStore.
   ClientServices::Send may advance/mutate CDataStore header fields, so every actual
   transmission must use a fresh working header and a fresh packet buffer. */
static int cloneStore(DWORD store){
 DWORD *s=(DWORD*)store,size,read,base,buf;BYTE *src;
 if(!s)return 0;size=s[4];read=s[5];base=s[2];buf=s[1];
 if(!buf||!size||size>MAX_PACKET||read>size||buf<base)return 0;
 src=(BYTE*)(buf-base);cp(g_packetTemplate,src,size);
 g_cloneTemplate[0]=s[0];g_cloneTemplate[1]=(DWORD)g_packetTemplate;g_cloneTemplate[2]=0;
 g_cloneTemplate[3]=MAX_PACKET;g_cloneTemplate[4]=size;g_cloneTemplate[5]=read;
 return 1;
}

static void logStoreState(const char*tag,DWORD candidate,DWORD *s){
 char b[260],*p=b;
 p=ap(p,tag);p=ap(p," candidate=");p=dec(p,candidate);
 p=ap(p," h0=0x");p=hex32(p,s[0]);p=ap(p," buf=0x");p=hex32(p,s[1]);
 p=ap(p," base=0x");p=hex32(p,s[2]);p=ap(p," cap=");p=dec(p,s[3]);
 p=ap(p," size=");p=dec(p,s[4]);p=ap(p," read=");p=dec(p,s[5]);
 p=ap(p,"\r\n");lograw(b,(DWORD)(p-b));
}

static void startDeferredClientGcd(void){
 DWORD spell,arg;
 if(!g_deferredClientGcd)return;
 spell=g_spoofSpell;arg=g_deferredClientGcdArg;g_deferredClientGcd=0;g_deferredClientGcdArg=0;
 if(!spell)return;
 ((PFN_StartGlobalCooldown)START_GLOBAL_COOLDOWN)(spell,arg);
 {char b[180],*p=b;p=ap(p,"CLIENT_GCD_DEFERRED_START spell=");p=dec(p,spell);p=ap(p," arg=");p=dec(p,arg);p=ap(p,"\r\n");lograw(b,(DWORD)(p-b));}
}

static void sendClonedCast(void){
 DWORD i,size=g_cloneTemplate[4];
 if(!size||size>MAX_PACKET)return;
 cp(g_sendPacket,g_packetTemplate,size);
 for(i=0;i<6;++i)g_sendStoreHdr[i]=g_cloneTemplate[i];
 g_sendStoreHdr[1]=(DWORD)g_sendPacket;
 g_sendStoreHdr[2]=0;
 g_sendStoreHdr[3]=MAX_PACKET;
 logStoreState("SEND_BEFORE",g_candidate,g_sendStoreHdr);
 sendStore((DWORD)g_sendStoreHdr);
 /* If the clone was transmitted synchronously from the original user press, let the
    native 0x6E58FB call run normally. If this is a later release from ENERGY_GATE,
    that original call was skipped, so start the client GCD now instead. */
 if(g_insideOriginalQueue)g_skipNativeGcdCurrent=0;
 else startDeferredClientGcd();
 logStoreState("SEND_AFTER",g_candidate,g_sendStoreHdr);
}

static int sendPickPocketTargetEx(DWORD tg,const char *tag,DWORD source){
 DWORD lo,hi,size,i,pos,pl;BYTE guid[8],mask=0;
 if(!tg)return 0;
 pl=getPlayer();ppResetAttempts(tg);++g_ppAttemptCount;g_ppMoneyBefore=playerMoney(pl);g_ppAwaitLoot=0;
 lo=*(DWORD*)(tg+OBJ_GUID_LO);hi=*(DWORD*)(tg+OBJ_GUID_HI);
 guid[0]=(BYTE)(lo);guid[1]=(BYTE)(lo>>8);guid[2]=(BYTE)(lo>>16);guid[3]=(BYTE)(lo>>24);
 guid[4]=(BYTE)(hi);guid[5]=(BYTE)(hi>>8);guid[6]=(BYTE)(hi>>16);guid[7]=(BYTE)(hi>>24);
 /* WoW 1.12 SpellCastTargets::Write: uint16 targetMask + packed GUID. */
 *(DWORD*)(g_sendPacket+0)=CMSG_CAST_SPELL;
 *(DWORD*)(g_sendPacket+4)=PICK_POCKET_SPELL;
 *(unsigned short*)(g_sendPacket+8)=(unsigned short)TARGET_FLAG_UNIT;
 pos=11;
 for(i=0;i<8;i++)if(guid[i])mask|=(BYTE)(1U<<i);
 g_sendPacket[10]=mask;
 for(i=0;i<8;i++)if(guid[i])g_sendPacket[pos++]=guid[i];
 size=pos;
 {char b[160],*p=b;p=ap(p,"AUTO_PP_PACKET size=");p=dec(p,size);p=ap(p," mask=0x");p=hex8(p,mask);p=ap(p," guid_lo=0x");p=hex32(p,lo);p=ap(p," guid_hi=0x");p=hex32(p,hi);p=ap(p,"\r\n");lograw(b,(DWORD)(p-b));}
 g_sendStoreHdr[0]=CDATASTORE_VTABLE;
 g_sendStoreHdr[1]=(DWORD)g_sendPacket;
 g_sendStoreHdr[2]=0;
 g_sendStoreHdr[3]=MAX_PACKET;
 g_sendStoreHdr[4]=size;
 g_sendStoreHdr[5]=0;
 logSpellText(tag,PICK_POCKET_SPELL);
 sendStore((DWORD)g_sendStoreHdr);
 g_ppAutoPending=1;g_ppPendingTarget=tg;g_ppPendingSource=source;g_ppPendingSinceTick=g_lastTimerTick;
 {char b[128],*p=b;p=ap(p,"AUTO_PP_SOURCE source=");p=ap(p,source==2?"mouseover":"target");p=ap(p,"\r\n");lograw(b,(DWORD)(p-b));}
 return 1;
}
static int sendPickPocketTarget(DWORD tg,const char *tag){return sendPickPocketTargetEx(tg,tag,1);}

static void armPickPocketTimeout(void);
static void armPickPocketOpener(void);
static void clearPickPocketPending(void){g_ppAutoPending=0;g_ppPendingTarget=0;g_ppPendingSource=0;g_ppPendingSinceTick=0;g_ppAwaitLoot=0;g_ppLootSinceTick=0;}

static void logPPConfirm(const char*tag,DWORD moneyNow){
 char b[200],*p=b;p=ap(p,tag);p=ap(p," attempts=");p=dec(p,g_ppAttemptCount);p=ap(p," money_before=");p=dec(p,g_ppMoneyBefore);p=ap(p," money_now=");p=dec(p,moneyNow);p=ap(p,"\r\n");lograw(b,(DWORD)(p-b));
}

static void autoPickPocketTick(DWORD tick){
 DWORD pl,tg,type,moneyNow;int openerWaiting,hasLoot;
 g_lastTimerTick=tick;
 if(g_ppAutoPending){
   if(g_ppAwaitLoot){
     openerWaiting=(g_phase==PHASE_WAIT_PP&&g_castPending);pl=getPlayer();tg=g_ppPendingTarget;moneyNow=playerMoney(pl);hasLoot=clientHasLoot();
     if(hasLoot||moneyNow>g_ppMoneyBefore){
       logPPConfirm(hasLoot?"AUTO_PP_LOOT_CONFIRMED":"AUTO_PP_MONEY_CONFIRMED",moneyNow);
       if(tg){ppMarkTried(tg);logs("AUTO_PP_MARK confirmed\r\n");}
       clearPickPocketPending();g_ppAttemptTarget=0;g_ppAttemptCount=0;
       if(openerWaiting)armPickPocketOpener();
       return;
     }
     if((DWORD)(tick-g_ppLootSinceTick)>=PP_LOOT_CONFIRM_MS){
       if(g_ppAttemptCount<PP_MAX_ATTEMPTS&&pl&&tg&&((g_ppPendingSource==2&&getMouseover()==tg)||(g_ppPendingSource!=2&&getTarget()==tg))&&playerIsStealthed(pl)&&ppInRange(pl,tg)){
         DWORD src=g_ppPendingSource;
         logs("AUTO_PP_RETRY no_loot_confirmation\r\n");
         sendPickPocketTargetEx(tg,"AUTO_PP_RETRY_SEND",src);
         if(openerWaiting)armPickPocketTimeout();
         return;
       }
       logs("AUTO_PP_GIVEUP no_loot_confirmation\r\n");
       clearPickPocketPending();g_ppRetryAfterTick=tick+PP_RETRY_COOLDOWN_MS;g_ppAttemptCount=0;g_ppAttemptTarget=0;
       if(openerWaiting)armPickPocketOpener();
       return;
     }
     return;
   }
   if(g_phase==PHASE_WAIT_PP)return;
   if((DWORD)(tick-g_ppPendingSinceTick)>=PP_AUTO_TIMEOUT_MS){logs("AUTO_PP_IDLE_TIMEOUT\r\n");clearPickPocketPending();}
   return;
 }
 if((DWORD)(tick-g_ppLastScanTick)<PP_AUTO_SCAN_MS)return;g_ppLastScanTick=tick;
 if(g_ppRetryAfterTick&&(LONG)(tick-g_ppRetryAfterTick)<0)return;if(g_ppRetryAfterTick)g_ppRetryAfterTick=0;
 if(g_phase!=PHASE_IDLE)return;
 pl=getPlayer();if(!pl)return;
 if(!playerIsStealthed(pl))return;
 /* Mouseover has priority. 0xB4E2C8/CC is the full 64-bit mouseover GUID in build 5875. */
 tg=getMouseover();
 if(tg){
   type=*(DWORD*)(tg+OBJ_TYPE);
   if((type==3||type==4)&&!ppWasTried(tg)&&ppInRange(pl,tg)){
     sendPickPocketTargetEx(tg,"AUTO_PP_MOUSEOVER_SEND",2);return;
   }
 }
 /* Preserve v0.19 behavior when there is no eligible mouseover unit. */
 tg=getTarget();if(!tg)return;
 type=*(DWORD*)(tg+OBJ_TYPE);if(type!=3&&type!=4)return;
 if(ppWasTried(tg))return;
 if(!ppInRange(pl,tg))return;
 sendPickPocketTargetEx(tg,"AUTO_PP_IDLE_SEND",1);
}


#define PI_F       3.14159265358979323846f
#define HALF_PI_F  1.57079632679489661923f
#define TWO_PI_F   6.28318530717958647692f

static float normAngle(float a){while(a<0.0f)a+=TWO_PI_F;while(a>=TWO_PI_F)a-=TWO_PI_F;return a;}

/* Candidate ordering deliberately starts with the normal client prediction.  If that
   fails with an authoritative positional result, subsequent candidates cover the
   opposite and perpendicular sides of the target. */
static float candidateAngle(DWORD spell,DWORD idx,float targetO){
 float a,q=PI_F*0.25f;
 /* Order is intentionally biased toward the expected valid half-plane first.
    For Backstab we probe 180, 135, 225, 90, 270, 45, 315, 0 degrees
    relative to the target orientation.  Gouge mirrors this around the front. */
 if(isBehindSpell(spell)){
   if(idx==0)a=targetO+PI_F;
   else if(idx==1)a=targetO+PI_F-q;
   else if(idx==2)a=targetO+PI_F+q;
   else if(idx==3)a=targetO+HALF_PI_F;
   else if(idx==4)a=targetO+PI_F+HALF_PI_F;
   else if(idx==5)a=targetO+q;
   else if(idx==6)a=targetO-q;
   else a=targetO;
 }else{
   if(idx==0)a=targetO;
   else if(idx==1)a=targetO+q;
   else if(idx==2)a=targetO-q;
   else if(idx==3)a=targetO+HALF_PI_F;
   else if(idx==4)a=targetO-HALF_PI_F;
   else if(idx==5)a=targetO+PI_F-q;
   else if(idx==6)a=targetO+PI_F+q;
   else a=targetO+PI_F;
 }
 return normAngle(a);
}

static int calcCurrentCandidate(float *sx,float *sy,float *sz,float *so,float *txo,float *tyo,float *tzo,float *too){
 DWORD tg,type;float tx,ty,tz,to,a;
 tg=getTarget();if(!tg||tg!=g_target)return 0;
 type=*(DWORD*)(tg+OBJ_TYPE);if(type!=3&&type!=4)return 0;
 tx=*(float*)(tg+UNIT_X);ty=*(float*)(tg+UNIT_Y);tz=*(float*)(tg+UNIT_Z);to=*(float*)(tg+UNIT_O);
 a=candidateAngle(g_spoofSpell,g_candidate,to);
 *sx=tx+SPOOF_DISTANCE*fcos1(a);*sy=ty+SPOOF_DISTANCE*fsin1(a);*sz=tz;*so=normAngle(a+PI_F);
 if(txo)*txo=tx;if(tyo)*tyo=ty;if(tzo)*tzo=tz;if(too)*too=to;
 return 1;
}

static void logCandidate(const char*tag,DWORD spell,DWORD idx,float sx,float sy,float sz,float so){
 char b[260],*p=b;p=ap(p,tag);p=ap(p," spell=");p=dec(p,spell);p=ap(p," candidate=");p=dec(p,idx);
 p=ap(p," sx=0x");p=hex32(p,fbits(sx));p=ap(p," sy=0x");p=hex32(p,fbits(sy));p=ap(p," sz=0x");p=hex32(p,fbits(sz));p=ap(p," so=0x");p=hex32(p,fbits(so));p=ap(p,"\r\n");lograw(b,(DWORD)(p-b));
}

static int sendCurrentCandidate(const char *tag){
 DWORD pl,tg,type;float px,py,pz,po,tx,ty,tz,to,sx,sy,sz,so;
 pl=getPlayer();tg=getTarget();if(!pl||!tg){logs("SPOOF_SKIP no_player_or_target\r\n");return 0;}
 type=*(DWORD*)(tg+OBJ_TYPE);if(type!=3&&type!=4){logs("SPOOF_SKIP target_not_unit\r\n");return 0;}
 if(g_target && tg!=g_target){logs("SPOOF_ABORT target_changed\r\n");return 0;}
 px=*(float*)(pl+UNIT_X);py=*(float*)(pl+UNIT_Y);pz=*(float*)(pl+UNIT_Z);po=*(float*)(pl+UNIT_O);
 tx=*(float*)(tg+UNIT_X);ty=*(float*)(tg+UNIT_Y);tz=*(float*)(tg+UNIT_Z);to=*(float*)(tg+UNIT_O);
 if((px-tx)*(px-tx)+(py-ty)*(py-ty)>MAX_TARGET_DIST2){logs("SPOOF_SKIP target_too_far\r\n");return 0;}
 if(!g_target){g_player=pl;g_target=tg;}
 if(!calcCurrentCandidate(&sx,&sy,&sz,&so,0,0,0,0))return 0;
 if(g_candidate==0)logSpoof(g_spoofSpell,pl,tg,tx,ty,tz,to,px,py,pz,po,sx,sy,sz,so);
 else logCandidate(tag,g_spoofSpell,g_candidate,sx,sy,sz,so);
 *(float*)(pl+UNIT_X)=sx;*(float*)(pl+UNIT_Y)=sy;*(float*)(pl+UNIT_Z)=sz;*(float*)(pl+UNIT_O)=so;
 sendHeartbeat(pl);
 sendHeartbeat(pl);
 *(float*)(pl+UNIT_X)=px;*(float*)(pl+UNIT_Y)=py;*(float*)(pl+UNIT_Z)=pz;*(float*)(pl+UNIT_O)=po;
 return 1;
}

static void beginQueuedPositionalCast(void);
static void clearClientPendingCast(const char *tag){
 DWORD p=*(DWORD*)CLIENT_PENDING_SPELLCAST;
 DWORD sid=*(DWORD*)CLIENT_CASTING_SPELL_ID;
 DWORD h=*(DWORD*)CLIENT_CAST_HANDLE;
 DWORD alo=*(DWORD*)CLIENT_CURRENT_ACTION_GUID_LO;
 DWORD ahi=*(DWORD*)CLIENT_CURRENT_ACTION_GUID_HI;
 DWORD psid=*(DWORD*)CLIENT_PREV_CASTING_SPELL_ID;
 DWORD palo=*(DWORD*)CLIENT_PREV_ACTION_GUID_LO;
 DWORD pahi=*(DWORD*)CLIENT_PREV_ACTION_GUID_HI;
 unsigned short targeting=*(unsigned short*)CLIENT_TARGETING_STATE;
 if(targeting){
  ((PFN_SpellStopTargetingInternal)SPELL_STOP_TARGETING_INTERNAL)();
  logs("CLIENT_TARGETING_STOP\r\n");
 }
 *(DWORD*)CLIENT_PENDING_SPELLCAST=0;
 *(DWORD*)CLIENT_CASTING_SPELL_ID=0;
 *(DWORD*)CLIENT_CAST_HANDLE=0;
 *(DWORD*)CLIENT_CURRENT_ACTION_GUID_LO=0;
 *(DWORD*)CLIENT_CURRENT_ACTION_GUID_HI=0;
 *(DWORD*)CLIENT_PREV_CASTING_SPELL_ID=0;
 *(DWORD*)CLIENT_PREV_ACTION_GUID_LO=0;
 *(DWORD*)CLIENT_PREV_ACTION_GUID_HI=0;
 *(DWORD*)CLIENT_CAST_MISC=0;
 if(p||sid||h||alo||ahi||psid||palo||pahi||targeting){char b[360],*q=b;q=ap(q,tag);q=ap(q," pending=0x");q=hex32(q,p);q=ap(q," casting=0x");q=hex32(q,sid);q=ap(q," handle=0x");q=hex32(q,h);q=ap(q," action_guid=");q=hex32(q,ahi);q=ap(q,":");q=hex32(q,alo);q=ap(q," prev_guid=");q=hex32(q,pahi);q=ap(q,":");q=hex32(q,palo);q=ap(q," targeting=0x");q=hex32(q,(DWORD)targeting);q=ap(q,"\r\n");lograw(b,(DWORD)(q-b));}
}
static void deferClientUiClear(DWORD reason){g_deferredUiClear=reason;}
static void runDeferredClientUiClear(void){
 DWORD reason=g_deferredUiClear,alo,ahi,palo,pahi;unsigned short targeting;
 if(!reason)return;
 g_deferredUiClear=0;
 /* Never touch client cast-state after the cloned opener has actually been sent. */
 if(g_phase==PHASE_WAIT_RESULT||g_phase==PHASE_RESTORE){logs("CLIENT_UI_CLEAR_SKIP active_cast\r\n");return;}
 alo=*(DWORD*)CLIENT_CURRENT_ACTION_GUID_LO;ahi=*(DWORD*)CLIENT_CURRENT_ACTION_GUID_HI;
 palo=*(DWORD*)CLIENT_PREV_ACTION_GUID_LO;pahi=*(DWORD*)CLIENT_PREV_ACTION_GUID_HI;
 targeting=*(unsigned short*)CLIENT_TARGETING_STATE;
 if(targeting){((PFN_SpellStopTargetingInternal)SPELL_STOP_TARGETING_INTERNAL)();logs("CLIENT_UI_TARGETING_STOP\r\n");}
 *(DWORD*)CLIENT_CURRENT_ACTION_GUID_LO=0;*(DWORD*)CLIENT_CURRENT_ACTION_GUID_HI=0;
 *(DWORD*)CLIENT_PREV_ACTION_GUID_LO=0;*(DWORD*)CLIENT_PREV_ACTION_GUID_HI=0;
 if(alo||ahi||palo||pahi||targeting){
  char b[300],*q=b;q=ap(q,reason==1?"CLIENT_UI_CLEAR_DEFERRED_PP_JOIN":reason==2?"CLIENT_UI_CLEAR_DEFERRED_PP_WAIT":"CLIENT_UI_CLEAR_DEFERRED_HOLD");
  q=ap(q," action_guid=");q=hex32(q,ahi);q=ap(q,":");q=hex32(q,alo);q=ap(q," prev_guid=");q=hex32(q,pahi);q=ap(q,":");q=hex32(q,palo);q=ap(q," targeting=0x");q=hex32(q,(DWORD)targeting);q=ap(q,"\r\n");lograw(b,(DWORD)(q-b));
 }
}
static void clearState(void){g_phase=PHASE_IDLE;g_castPending=0;g_player=0;g_target=0;g_spoofSpell=0;g_rewrittenMoveCount=0;g_candidate=0;g_energyGatePassed=0;g_energyGateStartTick=0;g_energyGateReleaseDelay=0;g_energyGateTickSerialAtStart=0;g_energyGateWindowMsForCast=ENERGY_GATE_DEFAULT_WINDOW_MS;g_energyGateEnabledForCast=1;g_energyGatePvpForCast=0;g_deferredClientGcd=0;g_deferredClientGcdArg=0;}
static void cancelTimer(void){if(g_timer&&pKillTimer)pKillTimer(0,g_timer);g_timer=0;}
static void restoreServerPosition(const char*tag){DWORD spell=g_spoofSpell,count=g_rewrittenMoveCount;if(g_player)sendHeartbeat(g_player);logSpellText(tag,spell);if(count)logCountText("MOVE_REWRITTEN",spell,count);clearState();}

void STDCALL SpeedTimerProc(PVOID hwnd,DWORD msg,DWORD id,DWORD tick){
 (void)hwnd;(void)msg;(void)id;g_lastTimerTick=tick;runDeferredClientUiClear();trackEnergyTick(tick);/* StealthCDSafe binary patch: applyStealthSpeed() CALL NOPed */autoWotfTick(tick);
 if(g_phase==PHASE_ENERGY_GATE&&g_castPending){
  DWORD pl=getPlayer(),tg=getTarget(),left,held;
  if(!pl){logs("ENERGY_GATE_CANCEL no_player\r\n");clearClientPendingCast("CLIENT_PENDING_CLEAR_CANCEL");clearState();return;}
  if(!tg){logs("ENERGY_GATE_CANCEL no_target\r\n");clearClientPendingCast("CLIENT_PENDING_CLEAR_CANCEL");clearState();return;}
  if(tg!=g_target){logs("ENERGY_GATE_CANCEL target_changed\r\n");clearClientPendingCast("CLIENT_PENDING_CLEAR_CANCEL");clearState();return;}
  if(!playerIsStealthed(pl)){logs("ENERGY_GATE_CANCEL stealth_lost\r\n");clearClientPendingCast("CLIENT_PENDING_CLEAR_CANCEL");clearState();return;}
  held=(DWORD)(tick-g_energyGateStartTick);
  left=energyTimeToNext(tick);
  if(g_energyTickSerial!=g_energyGateTickSerialAtStart){
   g_energyGatePassed=1;clearClientPendingCast("CLIENT_PENDING_CLEAR_RELEASE");logEnergyGate("ENERGY_GATE_RELEASE_TICK",playerEnergy(pl),left);logSpellText("OPENER_PIPELINE_RELEASE",g_spoofSpell);beginQueuedPositionalCast();return;
  }
  if(held>=g_energyGateReleaseDelay){
   g_energyGatePassed=1;clearClientPendingCast("CLIENT_PENDING_CLEAR_RELEASE");logEnergyGate("ENERGY_GATE_RELEASE_WINDOW",playerEnergy(pl),left);logSpellText("OPENER_PIPELINE_RELEASE",g_spoofSpell);beginQueuedPositionalCast();return;
  }
  if(held>=ENERGY_GATE_MAX_HOLD_MS){
   g_energyGatePassed=1;clearClientPendingCast("CLIENT_PENDING_CLEAR_RELEASE");logEnergyGate("ENERGY_GATE_RELEASE_MAX_HOLD",playerEnergy(pl),left);logSpellText("OPENER_PIPELINE_RELEASE",g_spoofSpell);beginQueuedPositionalCast();return;
  }
 }
}
static void startSpeedTimer(void){if(!g_speedTimer&&pSetTimer)g_speedTimer=pSetTimer(0,0,STEALTH_SPEED_TIMER_MS,SpeedTimerProc);if(!g_speedTimer)logs("ERROR stealth-speed timer unavailable\r\n");}
static void stopSpeedTimer(void){if(g_speedTimer&&pKillTimer)pKillTimer(0,g_speedTimer);g_speedTimer=0;}

void STDCALL StateTimerProc(PVOID hwnd,DWORD msg,DWORD id,DWORD tick){
 (void)hwnd;(void)msg;(void)id;(void)tick;cancelTimer();
 if(g_phase==PHASE_WAIT_PP){logs("AUTO_PP_TIMEOUT\r\n");clearPickPocketPending();g_phase=PHASE_PP_DELAY;beginQueuedPositionalCast();return;}
 if(g_phase==PHASE_PP_DELAY){beginQueuedPositionalCast();return;}
 if(g_phase==PHASE_ENERGY_GATE){return;}
 if(g_phase==PHASE_WAIT_RESULT){restoreServerPosition("SPOOF_RESTORE_TIMEOUT");return;}
 if(g_phase==PHASE_RESTORE){restoreServerPosition("SPOOF_RESTORE_RESULT");return;}
 clearState();
}

static void armTimeout(void){DWORD t;cancelTimer();t=pSetTimer?pSetTimer(0,0,RESULT_TIMEOUT_MS,StateTimerProc):0;if(t){g_timer=t;return;}restoreServerPosition("RESTORE no_timeout_timer");}
static void armPickPocketTimeout(void){DWORD t;cancelTimer();t=pSetTimer?pSetTimer(0,0,PP_RESULT_TIMEOUT_MS,StateTimerProc):0;if(t){g_timer=t;return;}g_phase=PHASE_PP_DELAY;beginQueuedPositionalCast();}
static void armPickPocketOpener(void){DWORD t;cancelTimer();g_phase=PHASE_PP_DELAY;t=pSetTimer?pSetTimer(0,0,PP_OPENER_DELAY_MS,StateTimerProc):0;if(t){g_timer=t;return;}beginQueuedPositionalCast();}
static void armResultRestore(void){DWORD t;cancelTimer();g_phase=PHASE_RESTORE;t=pSetTimer?pSetTimer(0,0,RESULT_RESTORE_MS,StateTimerProc):0;if(t){g_timer=t;return;}restoreServerPosition("SPOOF_RESTORE_RESULT_FALLBACK");}

static void beginQueuedPositionalCast(void){
 DWORD pl,left,e;
 if(!g_castPending||!g_spoofSpell)return;
 pl=getPlayer();
 if(!g_energyGatePassed&&isBehindSpell(g_spoofSpell)&&pl&&playerIsStealthed(pl)){
   if(!g_energyGateEnabledForCast){
     g_energyGatePassed=1;logs(g_energyGatePvpForCast?"ENERGY_GATE_BYPASS PVP_DISABLED\r\n":"ENERGY_GATE_BYPASS PVE_DISABLED\r\n");
   }else{
     e=playerEnergy(pl);left=energyTimeToNext(g_lastTimerTick);
     if(left==0xFFFFFFFFUL){logs("ENERGY_GATE_UNSYNCED allow\r\n");g_energyGatePassed=1;}
     else if(left>g_energyGateWindowMsForCast){g_phase=PHASE_ENERGY_GATE;g_energyGateStartTick=g_lastTimerTick;g_energyGateReleaseDelay=left-g_energyGateWindowMsForCast;g_energyGateTickSerialAtStart=g_energyTickSerial;g_deferredClientGcd=1;clearClientPendingCast("CLIENT_PENDING_CLEAR_HOLD");deferClientUiClear(3);logEnergyGate("ENERGY_GATE_HOLD",e,left);return;}
     else {g_energyGatePassed=1;logEnergyGate("ENERGY_GATE_PASS",e,left);}
   }
 }
 g_candidate=0;g_rewrittenMoveCount=0;g_phase=PHASE_WAIT_RESULT;
 if(!sendCurrentCandidate("SPOOF_CANDIDATE")){clearState();return;}
 sendClonedCast();
 logSpellText("CAST_ATTEMPT_0",g_spoofSpell);
 armTimeout();
}

static void sendAttemptNow(const char *tag){
 if(!g_castPending||g_phase==PHASE_IDLE)return;
 if(!sendCurrentCandidate(tag)){restoreServerPosition("RESTORE candidate_abort");return;}
 sendClonedCast();
 g_phase=PHASE_WAIT_RESULT;
 logCountText("CAST_ATTEMPT",g_spoofSpell,g_candidate);
 armTimeout();
}

void STDCALL QueuePositionalCast(DWORD spell,DWORD store){
 DWORD pl,tg,type;
 g_suppressCurrent=0;g_skipNativeGcdCurrent=0;g_insideOriginalQueue=0;
 if(!isBehindSpell(spell)&&!isGouge(spell))return;
 if(g_phase!=PHASE_IDLE){g_suppressCurrent=1;g_skipNativeGcdCurrent=1;logSpellText("CAST_DROP active",spell);return;}
 pl=getPlayer();tg=getTarget();
 /* Freeze the cast context BEFORE ENERGY_GATE can become active.  In v0.33-v0.35
    g_target was first assigned by sendCurrentCandidate(), but HOLD happens before that
    function is called.  The 5 ms gate timer therefore compared a real target against
    g_target==0 and cancelled every held opener almost immediately. */
 if(!pl||!tg){logs("CAST_QUEUE_BYPASS no_player_or_target\r\n");return;}
 type=*(DWORD*)(tg+OBJ_TYPE);
 if(type!=3&&type!=4){logs("CAST_QUEUE_BYPASS target_not_unit\r\n");return;}
 if(!cloneStore(store)){logs("CAST_QUEUE_FAIL clone\r\n");return;}
 /* From this point the original CMSG is intentionally suppressed. Keep the native GCD
    only if we manage to transmit our cloned cast synchronously during this same call. */
 g_skipNativeGcdCurrent=1;
 g_player=pl;g_target=tg;selectEnergyGateConfig(type);
 g_spoofSpell=spell;g_candidate=0;g_castPending=1;g_rewrittenMoveCount=0;g_energyGatePassed=0;g_deferredClientGcdArg=0; /* smart gate: per-target PvE/PvP pre-tick window, frozen context, release on observed tick, 1900ms safety cap */
 logSpellText(isAmbush(spell)?"OPENER_PIPELINE_AMBUSH":"OPENER_PIPELINE_BACKSTAB",spell);
 g_insideOriginalQueue=1;
 beginQueuedPositionalCast();
 g_insideOriginalQueue=0;
 g_suppressCurrent=1;
}

static int movementHasGuid(DWORD op){
 return op==0xE9||op==0xEB||op==0xC7||op==0xE3||op==0xE5||op==0xE7||
        op==0x2DB||op==0x2DD||op==0x2DF||op==0xF6||op==0x2CF||op==0x2D0||
        op==0xF0||op==0x2D1;
}
static int movementHasExtra(DWORD op){
 return op==0xE9||op==0xEB||op==0xC7||op==0xE3||op==0xE5||op==0xE7||
        op==0x2DB||op==0x2DD||op==0x2DF||op==0xF6||op==0x2CF||op==0x2D0||op==0xF0;
}

/* Keep ordinary movement traffic alive, but make it agree with whichever adaptive
   candidate is currently being tested. */
static int rewriteMovementStore(DWORD store){
 DWORD *ds=(DWORD*)store,size,base,buf,op,off;BYTE *p;float sx,sy,sz,so;
 if(!ds||g_phase!=PHASE_WAIT_RESULT||g_allowMovementSend||!g_target||!g_spoofSpell)return 0;
 size=ds[4];base=ds[2];buf=ds[1];if(!buf||!size||buf<base)return 0;p=(BYTE*)(buf-base);if(size<28)return 0;
 op=*(DWORD*)p;off=4;if(movementHasGuid(op))off+=8;if(movementHasExtra(op))off+=4;if(size<off+24)return 0;
 if(!calcCurrentCandidate(&sx,&sy,&sz,&so,0,0,0,0))return 0;
 *(float*)(p+off+8)=sx;*(float*)(p+off+12)=sy;*(float*)(p+off+16)=sz;*(float*)(p+off+20)=so;++g_rewrittenMoveCount;return 1;
}
void STDCALL PrepareMovementSend(DWORD store){/* StealthCDSafe binary patch: applyStealthSpeed() CALL NOPed */rewriteMovementStore(store);}

static int isPositionalFailure(DWORD spell,DWORD reason){
 if(isBehindSpell(spell))return reason==0x33||reason==0x7C;
 if(isGouge(spell))return reason==0x36||reason==0x7B||reason==0x7C;
 return 0;
}

void STDCALL LogServerFail(DWORD spell,DWORD reason){
 char b[120],*p=b;DWORD oldcand;
 p=ap(p,"SERVER_FAIL spell=");p=dec(p,spell);p=ap(p," reason=0x");p=hex8(p,(BYTE)reason);p=ap(p," candidate=");p=dec(p,g_candidate);p=ap(p,"\r\n");lograw(b,(DWORD)(p-b));
 if(spell==WILL_OF_THE_FORSAKEN_SPELL&&g_wotfCcActive){
   p=b;p=ap(p,"AUTO_WOTF_FAIL reason=0x");p=hex8(p,(BYTE)reason);p=ap(p,"\r\n");lograw(b,(DWORD)(p-b));
   if(g_wotfAttempts<WOTF_MAX_ATTEMPTS){g_wotfRetryPending=1;g_wotfRetryTick=g_lastTimerTick+WOTF_RETRY_DELAY_MS;logs("AUTO_WOTF_RETRY_SCHEDULED\r\n");} /* WotFRetry5: retry any failure reason */
   else g_wotfRetryPending=0;
   return;
 }
 if(spell==PICK_POCKET_SPELL&&g_ppAutoPending){
   int openerWaiting=(g_phase==PHASE_WAIT_PP&&g_castPending);
   if(openerWaiting)cancelTimer();
   p=b;p=ap(p,"AUTO_PP_FAIL reason=0x");p=hex8(p,(BYTE)reason);p=ap(p,"\r\n");lograw(b,(DWORD)(p-b));
   /* TARGET_NO_POCKETS is definitive for this mob. Transient failures stay retryable. */
   if(reason==0x72 && g_ppPendingTarget){ppMarkTried(g_ppPendingTarget);logs("AUTO_PP_MARK definitive_fail\r\n");}
   clearPickPocketPending();
   if(openerWaiting){armPickPocketOpener();}
   return;
 }
 if(spell!=g_spoofSpell||g_phase!=PHASE_WAIT_RESULT)return;
 cancelTimer();
 if(isPositionalFailure(spell,reason) && g_candidate+1<MAX_CANDIDATES){
   oldcand=g_candidate;++g_candidate;
   logCountText("ADAPT_RETRY_FROM",spell,oldcand);
   g_phase=PHASE_WAIT_RESULT;
   sendAttemptNow("SPOOF_RETRY");
   return;
 }
 armResultRestore();
}
void STDCALL LogSpellGo(DWORD spell){
 if(spell==WILL_OF_THE_FORSAKEN_SPELL){g_wotfRetryPending=0;logs("AUTO_WOTF_GO spell=7744\r\n");return;}
 if(spell==PICK_POCKET_SPELL&&g_ppAutoPending){
   int openerWaiting=(g_phase==PHASE_WAIT_PP&&g_castPending);
   logs("AUTO_PP_GO spell=921\r\n");
   if(openerWaiting)cancelTimer();
   g_ppAwaitLoot=1;g_ppLootSinceTick=g_lastTimerTick;g_ppPendingSinceTick=g_lastTimerTick;
   logs("AUTO_PP_WAIT_LOOT\r\n");
   return;
 }
 if(isStealthAura(spell)){logs("STEALTH_SPEED_PRIME_NATIVE spell_go\r\n");/* StealthCDSafe binary patch: applyStealthSpeed() CALL NOPed */}
 if((isBehindSpell(spell)||isGouge(spell))&&spell==g_spoofSpell&&g_phase==PHASE_WAIT_RESULT){logCountText("SPELL_GO",spell,g_candidate);armResultRestore();}
}

/* Replacement for CALL ClientServices::Send at 0x6E5872. */
__declspec(naked) void CastSendHook(void){
 __asm {
   pushfd
   pushad
   mov dword ptr [g_suppressCurrent],0
   mov eax,[ebp-8]
   test eax,eax
   je short queue_done
   mov eax,[eax+0x10]
   mov edx,[esp+24]
   push edx
   push eax
   call QueuePositionalCast
 queue_done:
   popad
   popfd
   cmp dword ptr [g_suppressCurrent],0
   jne short suppress_send
   mov eax,CLIENTSERVICES_SEND
   call eax
 suppress_send:
   ret
 }
}

/* Replacement for the single StartGlobalCooldown CALL at 0x6E58FB inside SendCast.
   If the original CMSG was suppressed and no cloned cast was sent yet (energy HOLD / active DROP),
   skip this stale client-side GCD. The held cast starts it later from sendClonedCast(). */
__declspec(naked) void StartGlobalCooldownCallHook(void){
 __asm {
   cmp dword ptr [g_skipNativeGcdCurrent],0
   je short run_native_gcd
   /* EDX is computed by the native SendCast path immediately before 0x6E58FB.
      Preserve it so a deferred opener starts exactly the same client GCD bucket. */
   mov dword ptr [g_deferredClientGcdArg],edx
   mov dword ptr [g_skipNativeGcdCurrent],0
   ret
 run_native_gcd:
   mov eax,START_GLOBAL_COOLDOWN
   jmp eax
 }
}

__declspec(naked) void MovementSendHook(void){
 __asm {
   pushfd
   pushad
   mov eax,[esp+24]
   push eax
   call PrepareMovementSend
   popad
   popfd
   mov eax,CLIENTSERVICES_SEND
   call eax
   ret
 }
}

__declspec(naked) void ServerFailHook(void){
 __asm {
   pushfd
   pushad
   movzx eax,dl
   push eax
   push ecx
   call LogServerFail
   popad
   popfd
   mov eax,0x006E1A00
   jmp eax
 }
}

__declspec(naked) void SpellGoHook(void){
 __asm {
   pushfd
   pushad
   mov eax,[ebp-4]
   push eax
   call LogSpellGo
   popad
   popfd
   mov ecx,[ebp-0x10]
   mov edx,[ebp-0x0C]
   mov eax,SPELL_GO_CONTINUE
   jmp eax
 }
}

static void initOpenerTimingControlDescriptor(void){
 W112_ControlSettingV1*s;
 if(g_controlDescriptorReady)return;
 s=&g_controlSettings[0];
 s->struct_size=(w112_u32)sizeof(W112_ControlSettingV1);s->setting_id=SETTING_PVE_GATE_ENABLED;
 s->key="pve_energy_gate";s->label="PvE energy gate";s->type=W112_CTL_BOOL;
 s->default_value.u32=1u;s->min_value.u32=0u;s->max_value.u32=1u;s->step.u32=1u;s->flags=W112_CTL_LIVE;s->enum_options=0;s->enum_option_count=0u;
 s=&g_controlSettings[1];
 s->struct_size=(w112_u32)sizeof(W112_ControlSettingV1);s->setting_id=SETTING_PVE_WINDOW_MS;
 s->key="pve_pre_tick_ms";s->label="PvE pre-tick (ms)";s->type=W112_CTL_INT;
 s->default_value.i32=(w112_i32)ENERGY_GATE_DEFAULT_WINDOW_MS;s->min_value.i32=(w112_i32)ENERGY_GATE_MIN_WINDOW_MS;s->max_value.i32=(w112_i32)ENERGY_GATE_MAX_WINDOW_MS;s->step.i32=(w112_i32)ENERGY_GATE_WINDOW_STEP_MS;s->flags=W112_CTL_LIVE;s->enum_options=0;s->enum_option_count=0u;
 s=&g_controlSettings[2];
 s->struct_size=(w112_u32)sizeof(W112_ControlSettingV1);s->setting_id=SETTING_PVP_GATE_ENABLED;
 s->key="pvp_energy_gate";s->label="PvP energy gate";s->type=W112_CTL_BOOL;
 s->default_value.u32=1u;s->min_value.u32=0u;s->max_value.u32=1u;s->step.u32=1u;s->flags=W112_CTL_LIVE;s->enum_options=0;s->enum_option_count=0u;
 s=&g_controlSettings[3];
 s->struct_size=(w112_u32)sizeof(W112_ControlSettingV1);s->setting_id=SETTING_PVP_WINDOW_MS;
 s->key="pvp_pre_tick_ms";s->label="PvP pre-tick (ms)";s->type=W112_CTL_INT;
 s->default_value.i32=(w112_i32)ENERGY_GATE_DEFAULT_WINDOW_MS;s->min_value.i32=(w112_i32)ENERGY_GATE_MIN_WINDOW_MS;s->max_value.i32=(w112_i32)ENERGY_GATE_MAX_WINDOW_MS;s->step.i32=(w112_i32)ENERGY_GATE_WINDOW_STEP_MS;s->flags=W112_CTL_LIVE;s->enum_options=0;s->enum_option_count=0u;
 g_controlDescriptorReady=1UL;
}
static int W112_CTL_STDCALL openerTimingControlGet(w112_u32 id,W112_ControlValueV1*out){
 if(!out)return 0;
 if(id==SETTING_PVE_GATE_ENABLED){out->u32=g_cfgPveGateEnabled?1u:0u;return 1;}
 if(id==SETTING_PVE_WINDOW_MS){out->i32=(w112_i32)g_cfgPveWindowMs;return 1;}
 if(id==SETTING_PVP_GATE_ENABLED){out->u32=g_cfgPvpGateEnabled?1u:0u;return 1;}
 if(id==SETTING_PVP_WINDOW_MS){out->i32=(w112_i32)g_cfgPvpWindowMs;return 1;}
 return 0;
}
static int W112_CTL_STDCALL openerTimingControlSet(w112_u32 id,const W112_ControlValueV1*v){
 if(!v)return 0;
 if(id==SETTING_PVE_GATE_ENABLED){if(v->u32>1u)return 0;g_cfgPveGateEnabled=(DWORD)v->u32;return 1;}
 if(id==SETTING_PVP_GATE_ENABLED){if(v->u32>1u)return 0;g_cfgPvpGateEnabled=(DWORD)v->u32;return 1;}
 if(id==SETTING_PVE_WINDOW_MS){if(v->i32<(w112_i32)ENERGY_GATE_MIN_WINDOW_MS||v->i32>(w112_i32)ENERGY_GATE_MAX_WINDOW_MS)return 0;g_cfgPveWindowMs=(DWORD)v->i32;return 1;}
 if(id==SETTING_PVP_WINDOW_MS){if(v->i32<(w112_i32)ENERGY_GATE_MIN_WINDOW_MS||v->i32>(w112_i32)ENERGY_GATE_MAX_WINDOW_MS)return 0;g_cfgPvpWindowMs=(DWORD)v->i32;return 1;}
 return 0;
}
static const W112_ControlModuleV1 g_openerTimingControlModule={
 W112_CONTROL_API_V1,(w112_u32)sizeof(W112_ControlModuleV1),"opener_timing","Opener Timing",OPENER_TIMING_CONTROL_VERSION,4u,g_controlSettings,openerTimingControlGet,openerTimingControlSet
};
W112_CTL_EXPORT const W112_ControlModuleV1* W112_CTL_STDCALL W112_Control_GetModuleV1(void){initOpenerTimingControlDescriptor();return &g_openerTimingControlModule;}
static BOOL prot(DWORD site,ULONG np,ULONG*op){PVOID b=(PVOID)(site&0xfffff000UL);ULONG sz=0x1000;return pProtect&&pProtect((HANDLE)(LONG)-1,&b,&sz,np,op)>=0;}
static void unprot(DWORD site,ULONG op){PVOID b=(PVOID)(site&0xfffff000UL);ULONG sz=0x1000,x=0;pProtect((HANDLE)(LONG)-1,&b,&sz,op,&x);}
static void callpatch(DWORD site,void*fn){BYTE*p=(BYTE*)site;p[0]=0xE8;*(DWORD*)(p+1)=(DWORD)fn-(site+5);}
static void jmppatch6(DWORD site,void*fn){BYTE*p=(BYTE*)site;p[0]=0xE9;*(DWORD*)(p+1)=(DWORD)fn-(site+5);p[5]=0x90;}

static BOOL install(void){ULONG op;
 if(!eqb((BYTE*)CAST_SEND_SITE,sendOrig,5)){logs("ERROR send signature\r\n");return 0;}
 if(!eqb((BYTE*)GCD_CALL_SITE,gcdCallOrig,5)){logs("ERROR gcd-call signature\r\n");return 0;}
 if(!eqb((BYTE*)CAST_FAIL_SITE,failOrig,5)){logs("ERROR fail signature\r\n");return 0;}
 if(!eqb((BYTE*)SPELL_GO_SITE,goOrig,6)){logs("ERROR go signature\r\n");return 0;}
 if(!eqb((BYTE*)MOVEMENT_SEND_SITE,moveSendOrig,5)){logs("ERROR movement-send signature\r\n");return 0;}
 if(!prot(CAST_SEND_SITE,PAGE_EXECUTE_READWRITE,&op)){logs("ERROR protect send\r\n");return 0;}callpatch(CAST_SEND_SITE,CastSendHook);unprot(CAST_SEND_SITE,op);
 if(!prot(GCD_CALL_SITE,PAGE_EXECUTE_READWRITE,&op)){logs("ERROR protect gcd-call\r\n");return 0;}callpatch(GCD_CALL_SITE,StartGlobalCooldownCallHook);unprot(GCD_CALL_SITE,op);
 /* NoFailHook binary patch: installer jumps over the CAST_FAIL_SITE hook-install block. Signature validation above and legacy restore path below remain, matching the final patched DLL. */
 if(!prot(SPELL_GO_SITE,PAGE_EXECUTE_READWRITE,&op)){logs("ERROR protect go\r\n");return 0;}jmppatch6(SPELL_GO_SITE,SpellGoHook);unprot(SPELL_GO_SITE,op);
 if(!prot(MOVEMENT_SEND_SITE,PAGE_EXECUTE_READWRITE,&op)){logs("ERROR protect movement-send\r\n");return 0;}callpatch(MOVEMENT_SEND_SITE,MovementSendHook);unprot(MOVEMENT_SEND_SITE,op);
 installed=1;logs("PATCH_OK WoWPositionalSpoof v0.36 NoPP SmartEnergy700 SmoothStealth GateGCDFix auto_wotf=1 adaptive_candidates=8 double_heartbeat=1 ambush=1 auto_pickpocket=0 pp_external_module=1 stealth_speed_100pct=1 speed_apply=native_CMovement_SetRunSpeed_0x7C7030 current_speed_cache=0xA2C speed_timer_ms=5 energy_gate=1 energy_gate_window_ms=control_api_pve_pvp_default_700 energy_gate_max_hold_ms=1900 energy_gate_frozen_target=1 energy_gate_release_on_tick=1 opener_hold=1 suppressed_native_gcd_skip=1 deferred_gcd_on_actual_send=1 deferred_gcd_exact_edx=1 gate_context_frozen_before_hold=1 candidate_order=back_half_first fresh_cdatastore_per_send=1 immediate_positional_cast=0 movement_rewrite=1 timeout=350 current_action_guid_clear=1 deferred_ui_only_clear=1 no_deferred_cast_clear=1\r\n");return 1;
}
static void restore(void){ULONG op;if(!installed)return;
 if(prot(CAST_SEND_SITE,PAGE_EXECUTE_READWRITE,&op)){cp((BYTE*)CAST_SEND_SITE,sendOrig,5);unprot(CAST_SEND_SITE,op);}
 if(prot(GCD_CALL_SITE,PAGE_EXECUTE_READWRITE,&op)){cp((BYTE*)GCD_CALL_SITE,gcdCallOrig,5);unprot(GCD_CALL_SITE,op);}
 if(prot(CAST_FAIL_SITE,PAGE_EXECUTE_READWRITE,&op)){cp((BYTE*)CAST_FAIL_SITE,failOrig,5);unprot(CAST_FAIL_SITE,op);}
 if(prot(SPELL_GO_SITE,PAGE_EXECUTE_READWRITE,&op)){cp((BYTE*)SPELL_GO_SITE,goOrig,6);unprot(SPELL_GO_SITE,op);}
 if(prot(MOVEMENT_SEND_SITE,PAGE_EXECUTE_READWRITE,&op)){cp((BYTE*)MOVEMENT_SEND_SITE,moveSendOrig,5);unprot(MOVEMENT_SEND_SITE,op);}
 installed=0;
}

int STDCALL DllMain(void*h,DWORD reason,void*r){(void)h;(void)r;
 if(reason==DLL_PROCESS_ATTACH){
   pProtect=(PFN_NtProtectVirtualMemory)findall(nProtect);pCreate=(PFN_CreateFileA)findall(nCreate);pWrite=(PFN_WriteFile)findall(nWrite);pClose=(PFN_CloseHandle)findall(nClose);pSetTimer=(PFN_SetTimer)findall(nSetTimer);pKillTimer=(PFN_KillTimer)findall(nKillTimer);
   openlog();logs("LOAD WoWPositionalSpoof v0.36 NoPP SmartEnergy700 SmoothStealth GateGCDFix\r\n");if(!pSetTimer||!pKillTimer)logs("ERROR USER32 timer exports unavailable\r\n");if(pProtect){install();startSpeedTimer();}
 }else if(reason==DLL_PROCESS_DETACH){cancelTimer();stopSpeedTimer();restore();closelog();} return TRUE;
}
