/*
 * MovementCore V21 candidate overlay: deterministic manual LALT SafeBreak.
 * Target: World of Warcraft 1.12.1 build 5875, Windows x86.
 *
 * The V20 source below remains the exact functional base. This overlay only
 * replaces the three arbitration surfaces that made manual LALT intermittent:
 *   1) movement callsite: synthetic LALT packets bypass downstream movement
 *      rewriters (LongPickPocket / PositionalSpoof) and go straight through
 *      ClientServices::Send;
 *   2) ClientServices::Send: new Pick Pocket casts are rejected while manual
 *      LALT SafeBreak owns movement, preventing AutoPP from starving the reset;
 *   3) timer: an already-active Pick Pocket may finish, but its 1200 ms quiet
 *      tail is ignored for LALT. SafeBreak lifetime is paused only for the
 *      genuinely active PP transaction and resumes immediately afterwards.
 *
 * Ordinary NoFall, AutoGather, AutoOpen, AutoPP, F8/F10 SafeBreak modes and
 * all V20 diagnostics are preserved unchanged outside MODE_LOCAL_STRONG.
 */

#define W112_PP_FIXED_POINT 1
#define W112_PP_DETECTION_GUARD 1
#define W112_PP_ALWAYS_BEHIND 1
#define W112_PP_SELECTOR_BLACKLIST_BRIDGE 1
#define DllMain W112_MovementCoreV20_DllMain
#define MovementCore_GetVersion W112_MovementCoreV20_GetVersion
#include "WoWMovementCore_5875_v20_AUTOPP_REARONLY_HARDLOS3D_RETRY.c"
#undef MovementCore_GetVersion
#undef DllMain

#include "../common/W112ControlAPI.h"
#if defined(_MSC_VER)
#pragma comment(linker, "/EXPORT:W112_Control_GetModuleV1=_W112_Control_GetModuleV1@0")
#pragma comment(linker, "/EXPORT:MovementCore_CoordFlags=_MovementCore_CoordFlags@0")
#pragma comment(linker, "/EXPORT:MovementCore_CoordAcquireRear=_MovementCore_CoordAcquireRear@4")
#pragma comment(linker, "/EXPORT:MovementCore_CoordReleaseRear=_MovementCore_CoordReleaseRear@0")
#pragma comment(linker, "/EXPORT:MovementCore_CoordAcquireBlink=_MovementCore_CoordAcquireBlink@4")
/* PvERear360 resolves this explicit undecorated x86 Win32 ABI export. */
#pragma comment(linker, "/EXPORT:MovementCore_GetAltPriorityInstalled=_MovementCore_GetAltPriorityInstalled@0")
#pragma comment(linker, "/EXPORT:MovementCore_GetRearPriorityPackets=_MovementCore_GetRearPriorityPackets@0")
#pragma comment(linker, "/EXPORT:MovementCore_UserIsTyping=_MovementCore_UserIsTyping@0")
#pragma comment(linker, "/EXPORT:MovementCore_PPSelectorBridgeReady=_MovementCore_PPSelectorBridgeReady@0")
#pragma comment(linker, "/EXPORT:MovementCore_PPSelectorSkipped=_MovementCore_PPSelectorSkipped@0")
#pragma comment(linker, "/EXPORT:MovementCore_PPSelectorReleased=_MovementCore_PPSelectorReleased@0")
#pragma comment(linker, "/EXPORT:MovementCore_PPRearLiveRefreshes=_MovementCore_PPRearLiveRefreshes@0")
#endif


/* Parallel TEST: filter only AutoLootPP's original CanAttack selector call.
   The intact v0.14 DLL has callsite RVA 0x4F80: push ecx; push ebx;
   mov eax,0x00606980; call eax.  Native 5875 ABI is ECX=self/player,
   [ESP+4]=candidate unit, RET 4. Unblocked calls tail-jump to native.
   No global WoW.exe CanAttack hook, no reconstructed AutoLootPP recompile. */
__declspec(dllimport) HINSTANCE __stdcall GetModuleHandleA(const char *);
static const char g_ppSelectorDllName[] =
  "WoWAutoLootPP_v0_14_PP300YD_HU_ATTACKABLE_LEVELGATE3_NOSKIP_SELECTORCHECK.dll";
static BYTE *g_ppSelectorBase=0;
static volatile DWORD g_ppSelectorInstalled=0u,g_ppSelectorSkipped=0u,g_ppSelectorReleased=0u;
#define PPSEL_CALL_RVA 0x4F80u
#define PPSEL_IMM_RVA 0x4F83u
#define PPSEL_FLAG_RVA 0xEAD8u
#define PPSEL_LO_RVA 0xEADCu
#define PPSEL_HI_RVA 0xEAE0u
static const BYTE g_ppSelectorSignature[] = {
  0x51u,0x53u,0xB8u,0x80u,0x69u,0x60u,0x00u,
  0xFFu,0xD0u,0x59u,0x84u,0xC0u,0x0Fu,0x84u
};
static DWORD W112_PPGuard_Allow(DWORD lo,DWORD hi,DWORD now);
static DWORD __cdecl W112_PPSelector_ShouldSkip(BYTE*unit)
{
  DWORD lo,hi;
  if(!g_ppSelectorInstalled||!Ptr(unit))return 0u;
  lo=*(DWORD*)(unit+OFF_OBJ_GUID_LOW);
  hi=*(DWORD*)(unit+OFF_OBJ_GUID_HIGH);
  if(W112_PPGuard_Allow(lo,hi,GT()?GT()():0u)&&!PPBlackFind(lo,hi))return 0u;
  ++g_ppSelectorSkipped;
  return 1u;
}
/* Preserve registers and original native ECX + single stack argument. */
__declspec(naked) static void W112_PPSelector_AttackableThunk(void)
{
  __asm {
    pushfd
    pushad
    push dword ptr [esp+40]
    call W112_PPSelector_ShouldSkip
    add esp,4
    mov dword ptr [esp+28],eax
    popad
    popfd
    test eax,eax
    jne pp_selector_deny
    mov eax,0x00606980
    jmp eax
pp_selector_deny:
    xor eax,eax
    ret 4
  }
}
static BOOL W112_PPSelector_Install(void)
{
  BYTE*base,*site;
  DWORD i,dest,orig=0x00606980u;
  if(g_ppSelectorInstalled)return TRUE;
  if(!g_ppFailHookOk||!g_ppChainOk)return FALSE;
  base=(BYTE*)GetModuleHandleA(g_ppSelectorDllName);
  if(!Ptr(base)||!Ptr(base+PPSEL_HI_RVA))return FALSE;
  site=base+PPSEL_CALL_RVA;
  for(i=0u;i<sizeof(g_ppSelectorSignature);i++)
    if(site[i]!=g_ppSelectorSignature[i])return FALSE;
  /* Exact original v0.14 with the verified 100 -> 20ms PP-only patch. */
  if(base[0x201Bu]!=0x83u||base[0x201Cu]!=0xF8u||
     base[0x201Du]!=0x14u||base[0x201Eu]!=0x72u)return FALSE;
  /* The tracked-active flag and GUID accessors must match relocated slots. */
  if(base[0x1461u]!=0x80u||base[0x1462u]!=0x3Du||
     *(DWORD*)(base+0x1463u)!=(DWORD)(base+PPSEL_FLAG_RVA)||
     base[0x1467u]!=0x01u||
     base[0x19DBu]!=0x8Bu||base[0x19DCu]!=0x15u||
     *(DWORD*)(base+0x19DDu)!=(DWORD)(base+PPSEL_HI_RVA)||
     base[0x19E1u]!=0x8Bu||base[0x19E2u]!=0x0Du||
     *(DWORD*)(base+0x19E3u)!=(DWORD)(base+PPSEL_LO_RVA))
    return FALSE;
  if(*(DWORD*)(base+PPSEL_IMM_RVA)!=orig)return FALSE;
  dest=(DWORD)(LPVOID)&W112_PPSelector_AttackableThunk;
  if(!Ptr((void*)dest)||!WMem(base+PPSEL_IMM_RVA,(BYTE*)&dest,4u))
    return FALSE;
  if(*(DWORD*)(base+PPSEL_IMM_RVA)!=dest){
    WMem(base+PPSEL_IMM_RVA,(BYTE*)&orig,4u);return FALSE;
  }
  g_ppSelectorBase=base;
  g_ppSelectorInstalled=1u;
  return TRUE;
}
static void W112_PPSelector_ReleaseTracked(DWORD lo,DWORD hi)
{
  BYTE*base=g_ppSelectorBase;
  if(!g_ppSelectorInstalled||!base||(lo|hi)==0u)return;
  if(*(volatile DWORD*)(base+PPSEL_LO_RVA)!=lo||
     *(volatile DWORD*)(base+PPSEL_HI_RVA)!=hi)return;
  if(*(volatile BYTE*)(base+PPSEL_FLAG_RVA)!=1u)return;
  *(volatile BYTE*)(base+PPSEL_FLAG_RVA)=0u;
  ++g_ppSelectorReleased;
}
static void W112_PPSelector_Remove(void)
{
  BYTE*base=g_ppSelectorBase;
  DWORD orig=0x00606980u;
  if(g_ppSelectorInstalled&&base&&
     (BYTE*)GetModuleHandleA(g_ppSelectorDllName)==base&&
     *(DWORD*)(base+PPSEL_IMM_RVA)==
        (DWORD)(LPVOID)&W112_PPSelector_AttackableThunk)
    WMem(base+PPSEL_IMM_RVA,(BYTE*)&orig,4u);
  g_ppSelectorInstalled=0u;g_ppSelectorBase=0;
}
__declspec(dllexport) DWORD __stdcall MovementCore_PPSelectorBridgeReady(void)
{return g_ppSelectorInstalled?1u:0u;}
__declspec(dllexport) DWORD __stdcall MovementCore_PPSelectorSkipped(void)
{return g_ppSelectorSkipped;}
__declspec(dllexport) DWORD __stdcall MovementCore_PPSelectorReleased(void)
{return g_ppSelectorReleased;}


/* Minimal bounded flight recorder for a fixed rear point per PP attempt.
   Hot hooks only enqueue records; disk writes happen on the existing timer
   after LongPP has stopped, never inside ClientServices::Send. The updater
   includes the bounded tail of this separate log in its GitHub report. */
#define PP_FIXED_RING 64u
#define PP_FIXED_MAX_BYTES 262144u
typedef struct PPFixedRecord {
    DWORD ev,reason,lo,hi,variant,tick,stealth,combat;
    LONG sx,sy,sz,so,tx,ty,tz,rx,ry,rz;
} PPFixedRecord;
static PPFixedRecord g_ppFixedRecords[PP_FIXED_RING];
static volatile DWORD g_ppFixedWrite=0u,g_ppFixedRead=0u,g_ppFixedDropped=0u;
static const char g_ppFixedLogName[]="PPFixedPoint_debug.log";
static void PPFixed_Queue(DWORD event,DWORD reason,DWORD lo,DWORD hi,DWORD variant,float rawX,float rawY,float rawZ)
{
    DWORD pos=g_ppFixedWrite;PPFixedRecord*q;BYTE*p=LocalPlayer();
    if(pos-g_ppFixedRead>=PP_FIXED_RING){++g_ppFixedDropped;return;}
    q=&g_ppFixedRecords[pos%PP_FIXED_RING];
    q->ev=event;q->reason=reason;q->lo=lo;q->hi=hi;q->variant=variant;
    q->tick=GT()?GT()():0u;
    q->stealth=p?GatherHasStealth(p):0u;q->combat=p?Combat(p):0u;
    q->sx=(LONG)(g_ppHardX*10.0f);q->sy=(LONG)(g_ppHardY*10.0f);
    q->sz=(LONG)(g_ppHardZ*10.0f);q->so=(LONG)(g_ppHardO*100.0f);
    q->tx=(LONG)(g_ppFixedTargetX*10.0f);
    q->ty=(LONG)(g_ppFixedTargetY*10.0f);
    q->tz=(LONG)(g_ppFixedTargetZ*10.0f);
    q->rx=(LONG)(rawX*10.0f);q->ry=(LONG)(rawY*10.0f);
    q->rz=(LONG)(rawZ*10.0f);
    g_ppFixedWrite=pos+1u;
}
static void PPFixed_Flush(void)
{
    DWORD n=0u,wrote=0u,sz=0u;HANDLE fd;
    CreateFileA_t cf=CF();WriteFile_t wf=WF();SetFilePointer_t sfp=SFP();
    GetFileSize_t gfs=GFS();SetEndOfFile_t seof=SEOF();CloseHandle_t ch=CH();
    if(!cf||!wf||!sfp||!ch||LongPPActive()||LongPPInjecting())return;
    if(g_ppFixedRead==g_ppFixedWrite)return;
    fd=cf(g_ppFixedLogName,GENERIC_WRITE,FILE_SHARE_READ|FILE_SHARE_WRITE,
          0,OPEN_ALWAYS,FILE_ATTRIBUTE_NORMAL,0);
    if(fd==INVALID_HANDLE_VALUE||!fd)return;
    if(gfs&&seof){
        sz=gfs(fd,0);
        if(sz!=0xFFFFFFFFu&&sz>PP_FIXED_MAX_BYTES){
            sfp(fd,0,0,FILE_BEGIN);seof(fd);
        }
    }
    sfp(fd,0,0,FILE_END);
    while(g_ppFixedRead!=g_ppFixedWrite&&n++<8u){
        const PPFixedRecord*q=&g_ppFixedRecords[g_ppFixedRead%PP_FIXED_RING];
        char line[320],*p=line;
        p=AppStr(p,"pp_fixed_v1 tick=");p=AppU32(p,q->tick);
        p=AppStr(p," event=");p=AppU32(p,q->ev);
        p=AppStr(p," reason=");p=AppU32(p,q->reason);
        p=AppStr(p," guid=");p=AppHex32(p,q->hi);p=AppHex32(p,q->lo);
        p=AppStr(p," variant=");p=AppU32(p,q->variant);
        p=AppStr(p," stealth=");p=AppU32(p,q->stealth);
        p=AppStr(p," combat=");p=AppU32(p,q->combat);
        p=AppStr(p," fixed_xyz10=");p=AppS32(p,q->sx);*p++=',';
        p=AppS32(p,q->sy);*p++=',';p=AppS32(p,q->sz);
        p=AppStr(p," facing100=");p=AppS32(p,q->so);
        p=AppStr(p," target_xyz10=");p=AppS32(p,q->tx);*p++=',';
        p=AppS32(p,q->ty);*p++=',';p=AppS32(p,q->tz);
        p=AppStr(p," original_xyz10=");p=AppS32(p,q->rx);*p++=',';
        p=AppS32(p,q->ry);*p++=',';p=AppS32(p,q->rz);
        p=AppStr(p," dropped=");p=AppU32(p,g_ppFixedDropped);
        *p++='\r';*p++='\n';
        if(!wf(fd,line,(DWORD)(p-line),&wrote,0)||wrote!=(DWORD)(p-line))break;
        ++g_ppFixedRead;
    }
    ch(fd);
}

/* W112_PLANE_TEST: only outgoing packet Z is modified, never client XYZ. */
static volatile DWORD g_planeEnabled=0u,g_planeDepth=12u,g_planePackets=0u;
static volatile LONG g_planeTxZ10=0;
static volatile DWORD g_planeDirectCurrent=0u,g_planeLastApplied=0u;
static DWORD __cdecl Plane_TryDirectMovement(DataStore5875 *packet);
static const char g_planeOnChat[]="if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage('|cff55ff55[Plane TEST]|r ON: outgoing Z lowered; server acceptance UNKNOWN') end";
static const char g_planeOffChat[]="if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage('|cffffaa00[Plane TEST]|r OFF: restoring normal movement') end";
static const char g_planeCombatChat[]="if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage('|cffffaa00[Plane TEST]|r OFF: combat detected') end";
static volatile DWORD g_altPriorityInstalled=0u;
static volatile DWORD g_altPriorityBlockCurrent=0u;
static volatile DWORD g_altPriorityStarts=0u;
static volatile DWORD g_altPriorityPPBlocks=0u;
static volatile DWORD g_altPriorityDirectPackets=0u;
static volatile DWORD g_altPriorityDirectRestores=0u;
static volatile DWORD g_altPriorityQuietBypasses=0u;
static volatile DWORD g_altPriorityForceDirect=0u;
static volatile DWORD g_stepMoveInjecting=0u;
static volatile DWORD g_stepActive=0u;

/* Preserve a manual LALT edge while PvERear owns its short rear lease or a
 * cast/channel guard is active. Never steal an active pose or cast. */
static volatile DWORD g_altPriorityPendingUntil=0u;
/* clang-cl's inline-asm parser does not reliably bind an internal naked
 * function when referenced as `offset symbol`. Keep the V20 send-wrapper
 * address in a normal data symbol and jump through that instead. */
static DWORD g_altPriorityBaseSendWrapper=0u;
/* Login/world transition guard: forward native movement, never apply synthetic
 * XYZ or NoFall edits until the 5875 local player settles in a world. */
#define W112_LOGIN_SETTLE_MS 3000u
static volatile DWORD g_loginGuardReady=0u,g_loginGuardSince=0u;

/* Only automatic PP is paused after stealth loss or combat entry.  The
   normal corpse-loot pipeline and manual Pick Pocket are not affected. */
#define W112_PP_GUARD_COOLDOWN_MS 15000u
static volatile DWORD g_ppGuardReady=0u,g_ppGuardReadySince=0u;
static volatile DWORD g_ppGuardHoldLo=0u,g_ppGuardHoldHi=0u,g_ppGuardHoldUntil=0u;
static volatile DWORD g_ppGuardCatches=0u,g_ppGuardPulseFixes=0u;
static DWORD W112_PPGuard_Safe(BYTE*p)
{
    return g_loginGuardReady&&g_autoPPEnabled&&Ptr(p)&&
           GatherHasStealth(p)&&!Combat(p)&&!g_planeEnabled;
}
static DWORD W112_PPGuard_Allow(DWORD lo,DWORD hi,DWORD now)
{
    if(!g_ppGuardReady||!W112_PPGuard_Safe(LocalPlayer()))return 0u;
    if((lo|hi)&&lo==g_ppGuardHoldLo&&hi==g_ppGuardHoldHi&&
       (LONG)(now-g_ppGuardHoldUntil)<0)return 0u;
    return 1u;
}
static void W112_PPGuard_Tick(BYTE*p,DWORD now)
{
    if(!W112_PPGuard_Safe(p)){
        if(g_ppGuardReady&&g_ppFailPendingAuto&&
           (g_ppFailPendingLo|g_ppFailPendingHi)){
            g_ppGuardHoldLo=g_ppFailPendingLo;
            g_ppGuardHoldHi=g_ppFailPendingHi;
            g_ppGuardHoldUntil=now+W112_PP_GUARD_COOLDOWN_MS;
            W112_PPSelector_ReleaseTracked(g_ppGuardHoldLo,g_ppGuardHoldHi);
            PPFixed_Queue(4u,0u,g_ppGuardHoldLo,g_ppGuardHoldHi,g_ppFailPendingVariant,0.0f,0.0f,0.0f);
            PPHardRetryCancel();
            ++g_ppGuardCatches;
        }
        g_ppGuardReady=0u;g_ppGuardReadySince=0u;return;
    }
    if(!g_ppGuardReadySince)g_ppGuardReadySince=now;
    if((DWORD)(now-g_ppGuardReadySince)>=350u)g_ppGuardReady=1u;
}


static volatile DWORD g_loginGuardMgr=0u,g_loginGuardPlayer=0u;
static volatile DWORD g_loginGuardGuidLo=0u,g_loginGuardGuidHi=0u;
/* Universal cast/channel movement guard; legacy AB diagnostic exports remain. */
static volatile DWORD g_abCapGuardActive=0u,g_abCapGuardLastSeen=0u;
static volatile DWORD g_abCapGuardBlockedPP=0u,g_abCapGuardBlockedMove=0u;
static volatile DWORD g_abCapBlockMovementCurrent=0u;
/* Single existing movement-hook owner. Publish a short-lived rear transaction
   for PositionalSpoof without a new DLL, detour, worker or packet format. */
#define COORD_CAST 0x01u
#define COORD_PP 0x02u
#define COORD_SAFE 0x04u
#define COORD_GATHER 0x08u
#define COORD_REAR 0x10u
#define COORD_MANUAL_PENDING 0x20u
#define COORD_STEP_MOVE 0x40u
static volatile DWORD g_coordRearUntil=0u;
static void W112_CancelTeleForBlink(void); /* defined with E pending state below */
/* A short rear lease gates only competing synthetic movement transformations. */
static volatile DWORD g_rearPriorityMoveCurrent=0u,g_rearPriorityDirectPackets=0u;
static DWORD CoordRearOwned(void){
 DWORD now;
 if(!g_coordRearUntil)return 0u;
 now=GT()?GT()():0u;
 if(!now||(LONG)(now-g_coordRearUntil)>=0){
  g_coordRearUntil=0u;return 0u;
 }
 return 1u;
}
__declspec(dllexport) DWORD __stdcall MovementCore_CoordFlags(void){
 DWORD flags=0u;
 if(g_abCapGuardActive)flags|=COORD_CAST;
 if(LongPPActive()||LongPPInjecting()||
    (*(volatile DWORD*)ADDR_CASTING_SPELLID)==SPELL_PICK_POCKET)flags|=COORD_PP;
 if(g_mode!=MODE_OFF)flags|=COORD_SAFE;
 if(g_gatherActive||g_gatherLootWait)flags|=COORD_GATHER;
 if(CoordRearOwned())flags|=COORD_REAR;
 if(g_altPriorityPendingUntil)flags|=COORD_MANUAL_PENDING;
 if(g_stepMoveInjecting||g_stepActive)flags|=COORD_STEP_MOVE;
 return flags;
}
__declspec(dllexport) DWORD __stdcall MovementCore_CoordAcquireRear(DWORD spell){
 DWORD sid;
 if(!g_loginGuardReady||(MovementCore_CoordFlags()&0x7Fu))return 0u;
 sid=*(volatile DWORD*)ADDR_CASTING_SPELLID;
 if(sid&&sid!=spell)return 0u;
 if(!GT())return 0u;
 g_coordRearUntil=GT()()+6000u;return 1u;
}
/* Dedicated physical Blink lease. SafeBreak is PAUSED by the timer while the
 * lease is owned; queued LALT stays queued. E's pending destination is canceled.
 * Active cast/PP/gather and an already-owned rear pose cannot be preempted.
 * Never relax general CoordAcquireRear used by other rear experiments. */
__declspec(dllexport) DWORD __stdcall MovementCore_CoordAcquireBlink(DWORD spell){
 DWORD flags=MovementCore_CoordFlags(),sid;
 if(!g_loginGuardReady||!GT()||g_stepMoveInjecting||
    (flags&(COORD_CAST|COORD_PP|COORD_GATHER|COORD_REAR)))return 0u;
 sid=*(volatile DWORD*)ADDR_CASTING_SPELLID;
 if(sid&&sid!=spell)return 0u;
 W112_CancelTeleForBlink();
 g_coordRearUntil=GT()()+6000u;return 1u;
}
__declspec(dllexport) void __stdcall MovementCore_CoordReleaseRear(void){
 g_coordRearUntil=0u;
}


static void __cdecl W112_AB_CheckMovement(void)
{
    g_abCapBlockMovementCurrent=0u;
    /* Suppress all outgoing movement while casting/channeling, including
       packets rewritten by downstream movement hooks. Outside a cast, leave
       the original movement hook chain unchanged. */
    if(!g_abCapGuardActive)return;
    g_abCapBlockMovementCurrent=1u;
    ++g_abCapGuardBlockedMove;
}

static void __cdecl RearPriority_CheckMovement(void)
{
    g_rearPriorityMoveCurrent=CoordRearOwned() && !g_abCapGuardActive ? 1u:0u;
}

static void __cdecl RearPriority_DirectMovement(DataStore5875* packet)
{
    if(!packet)return;
    /* Bypass only downstream movement rewriters, not ClientServices::Send.
       PP/cast guards on the ClientServices hook remain in place. */
    DirectClientSend(packet);
    ++g_rearPriorityDirectPackets;
}

static void __cdecl AltPriority_DirectPacket(DataStore5875* packet)
{
    if(!packet)return;
    DirectClientSend(packet);
    ++g_altPriorityDirectPackets;
}

static void __cdecl AltPriority_CheckPickPocket(DataStore5875* packet)
{
    BYTE*raw;DWORD op,spell;
    g_altPriorityBlockCurrent=0u;
    if(!packet||packet->size<8u||packet->size>MAX_PACKET_SIZE)return;
    raw=PacketRawBase(packet);if(!raw)return;
    op=*(DWORD*)raw;
    /* Cover direct heartbeats that bypass the movement callsite. */
    if(g_abCapGuardActive && op==MSG_MOVE_HEARTBEAT){
        g_altPriorityBlockCurrent=1u;
        ++g_abCapGuardBlockedMove;
        return;
    }
    /* LongPP may emit its first position heartbeat directly from SendMovementPulse.
       Use the already-selected rear coordinates before that heartbeat is sent. */
    if(op==MSG_MOVE_HEARTBEAT&&packet->size>=0x1Cu&&g_ppFailPendingAuto&&
       g_ppHardArmed&&g_ppChainOk&&LongPPActive()&&
       Ptr((void*)g_longPPGuidLoPtr)&&Ptr((void*)g_longPPGuidHiPtr)&&
       *(DWORD*)g_longPPGuidLoPtr==g_ppHardLo&&
       *(DWORD*)g_longPPGuidHiPtr==g_ppHardHi){
        PPHardApplySpoof();
        if(!g_ppFixedFirstSeen){
            PPFixed_Queue(2u,0u,g_ppHardLo,g_ppHardHi,g_ppFailPendingVariant,
                          *(float*)(raw+0x0Cu),*(float*)(raw+0x10u),*(float*)(raw+0x14u));
            g_ppFixedFirstSeen=1u;
        }
        *(float*)(raw+0x0Cu)=g_ppHardX;
        *(float*)(raw+0x10u)=g_ppHardY;
        *(float*)(raw+0x14u)=g_ppHardZ;
        *(float*)(raw+0x18u)=g_ppHardO;
        ++g_ppGuardPulseFixes;
        return;
    }
    if(op!=0x12Eu)return;
    spell=*(DWORD*)(raw+4u);if(spell!=SPELL_PICK_POCKET)return;
    if(!g_loginGuardReady){g_altPriorityBlockCurrent=1u;return;}
    if(CoordRearOwned()){
        g_altPriorityBlockCurrent=1u;
        ++g_altPriorityPPBlocks;
        return;
    }
    if(g_abCapGuardActive){
        g_altPriorityBlockCurrent=1u;
        ++g_abCapGuardBlockedPP;
        return;
    }
    if(g_mode!=MODE_LOCAL_STRONG)return;
    /* Manual LALT is an explicit user action and owns movement until it ends.
       Block both automatic and manual PP starts so a new LongPP transaction
       cannot repeatedly pause/starve the reset. Existing PP is allowed to
       finish and is handled by the timer below. */
    g_altPriorityBlockCurrent=1u;
    g_ppQuietUntil=0u;
    ++g_altPriorityPPBlocks;
}

__declspec(naked) static void AltPriority_SendWrapper(void)
{
    __asm {
        pushfd
        pushad
        push ecx
        call AltPriority_CheckPickPocket
        add  esp,4
        popad
        popfd
        cmp  dword ptr [g_altPriorityBlockCurrent],0
        jne  alt_pp_blocked
        mov  eax,dword ptr [g_altPriorityBaseSendWrapper]
        jmp  eax
alt_pp_blocked:
        xor  eax,eax
        ret
    }
}

/* V21 movement ownership rule:
 * - every ordinary packet keeps the exact V20 chain;
 * - only MovementCore's own MODE_LOCAL_STRONG synthetic packet (and its final
 *   real-position restore) bypasses downstream movement hooks.
 * This prevents Gather / LongPP / PositionalSpoof from replacing LALT XYZ. */
__declspec(naked) static void AltPriority_MoveWrapper(void)
{
    __asm {
        /* Preserve native/LongPP forwarding, bypass MovementCore's NoFall,
         * gather rewriting and SafeBreak decisions until world readiness. */
        cmp dword ptr [g_loginGuardReady],0
        je  alt_login_passthrough
        /* Explicit Tele E one-shot takes precedence over cast/rear packet
         * suppressors and all downstream movement rewrites. Ordinary cast
         * and movement packets still use the existing ownership chain. */
        cmp dword ptr [g_stepMoveInjecting],0
        jne alt_direct_packet
        /* Protected casts and channels take priority over a stale rear lease. */
        cmp dword ptr [g_abCapGuardActive],0
        jne alt_rear_guarded
        pushfd
        pushad
        call RearPriority_CheckMovement
        popad
        popfd
        cmp dword ptr [g_rearPriorityMoveCurrent],0
        jne alt_rear_direct
alt_rear_guarded:
        pushfd
        pushad
        call W112_AB_CheckMovement
        popad
        popfd
        cmp dword ptr [g_abCapBlockMovementCurrent],0
        jne alt_suppress_packet
        pushfd
        pushad
        push ecx
        call NoFall_ProcessMovementPacket
        add  esp,4
        popad
        popfd

        cmp  dword ptr [g_stepMoveInjecting],0
        jne  alt_direct_packet
        cmp  dword ptr [g_altPriorityForceDirect],0
        jne  alt_direct_packet
        cmp  dword ptr [g_injecting],0
        je   alt_normal_chain
        cmp  dword ptr [g_mode],2
        je   alt_direct_packet

alt_normal_chain:
        pushfd
        pushad
        push ecx
        call Gather_ProcessMovementPacket
        add  esp,4
        popad
        popfd

        cmp  dword ptr [g_injecting],0
        jne  alt_forward_packet
        pushfd
        pushad
        call MoveIntercept
        popad
        popfd
        cmp  dword ptr [g_forwardCurrent],0
        je   alt_suppress_packet

alt_forward_packet:
        pushfd
        pushad
        call PPHardApplySpoof
        popad
        popfd
        pushfd
        pushad
        push ecx
        call Plane_TryDirectMovement
        add esp,4
        mov dword ptr [g_planeDirectCurrent],eax
        popad
        popfd
        cmp dword ptr [g_planeDirectCurrent],0
        jne alt_direct_packet
        mov  eax,dword ptr [g_nextMoveTarget]
        call eax
        ret

alt_login_passthrough:
        mov  eax,dword ptr [g_nextMoveTarget]
        call eax
        ret

alt_rear_direct:
         pushfd
         pushad
         push ecx
         call RearPriority_DirectMovement
         add  esp,4
         popad
         popfd
         ret

 alt_direct_packet:
        pushfd
        pushad
        push ecx
        call AltPriority_DirectPacket
        add  esp,4
        popad
        popfd
        ret

alt_suppress_packet:
        xor  eax,eax
        ret
    }
}

static void AltPriority_Stop(BOOL sendReal)
{
    BYTE*p=LocalPlayer();DWORD wasAlt=(g_mode==MODE_LOCAL_STRONG)?1u:0u;
    g_mode=MODE_OFF;g_started=0u;g_lastInject=0u;g_safeBreakPauseTick=0u;
    g_seenCombat=0u;g_clearTick=0u;g_worldLost=0u;g_worldReadySince=0u;
    if(sendReal&&p&&!g_injecting){
        if(wasAlt){
            g_altPriorityForceDirect=1u;
            SendReal(p);
            g_altPriorityForceDirect=0u;
            ++g_altPriorityDirectRestores;
        }else SendReal(p);
    }
}

static void AltPriority_Start(DWORD now)
{
    BYTE*p=LocalPlayer();
    g_stepActive=0u;
    if(!p)return;
    /* Abort any gather ownership before LALT starts. GatherStop clears spoof
       state before its optional real heartbeat, so the first LALT injection
       begins from a clean gather state. */
    if(g_gatherActive||g_gatherLootWait)GatherStop(p,now,"ALT_PRIORITY_GATHER_ABORT",1u,0u);
    g_miningPriorityValidUntil=0u;
    g_miningPriorityEntry=g_miningPriorityLo=g_miningPriorityHi=0u;
    g_miningPriorityD2=0.0f;
    g_ppQuietUntil=0u;
    Start(MODE_LOCAL_STRONG,now);
    if(g_mode==MODE_LOCAL_STRONG){
        ++g_altPriorityStarts;
        GatherFileLog("ALT_PRIORITY_START",now,0u,0u,0u,0.0f,g_altPriorityStarts,0u);
    }
}

/*
 * Q lowest-HP enemy-player target, build 5875. The existing MovementCore UI
 * timer owns the key edge: no new hooks, threads, worker scans or ESP rebuilds.
 * Distances are true XYZ, tiered 0-10/10-20/20-40 yd; within a tier rank by
 * current HP percentage, then by squared distance and GUID.
 * Native CanAttack/TargetGuid signatures match the proven 5875 ESP lineage.
 */
#define W112_Q_KEY                         0x51u
#define W112_Q_TYPEID_PLAYER               4u
#define W112_Q_TYPE_ID_OFF                 0x0014u
#define W112_Q_HEALTH_DESC_OFF             0x0058u
#define W112_Q_MAX_HEALTH_DESC_OFF         0x0070u
#define W112_Q_CAN_ATTACK_FN               0x00606980u
#define W112_Q_TARGET_GUID_FN              0x00489A40u
#define W112_Q_FRAME_GET_TEXT_FN           0x00703BF0u
static DWORD g_qWasDown=0u,g_qMgr=0u,g_qSelf=0u,g_qReadySince=0u;
static DWORD g_qSelections=0u,g_qNoTargets=0u;
typedef BYTE (__thiscall *W112_Q_CanAttackFn)(DWORD,DWORD);
typedef void (__fastcall *W112_Q_TargetGuidFn)(unsigned long long*);
typedef const char* (__fastcall *W112_Q_FrameGetTextFn)(const char*,int,DWORD);

static BOOL W112_Q_PosValid(float x,float y,float z)
{
    return x==x && y==y && z==z &&
           x>-100000.0f && x<100000.0f &&
           y>-100000.0f && y<100000.0f &&
           z>-100000.0f && z<100000.0f;
}
static BOOL W112_Q_NativeSignaturesValid(void)
{
    static const BYTE attack[]={0x55,0x8B,0xEC,0x56,0x8B,0x75,0x08,0x8B,0x46,0x08,0x57,0x8B,0xF9};
    static const BYTE target[]={0x56,0x8B,0xF1,0x8B,0x46,0x04,0x8B,0x0E};
    DWORD i;
    for(i=0u;i<sizeof(attack);++i)
        if(((const volatile BYTE*)W112_Q_CAN_ATTACK_FN)[i]!=attack[i])return FALSE;
    for(i=0u;i<sizeof(target);++i)
        if(((const volatile BYTE*)W112_Q_TARGET_GUID_FN)[i]!=target[i])return FALSE;
    return TRUE;
}
static BOOL W112_Q_ChatHasFocus(void)
{
    const char *state;
    /* This is a non-destructive query; if Lua is unavailable, do not retarget. */
    DebugChat("W112_Q_EDITING=(ChatFrameEditBox and ChatFrameEditBox:IsVisible()) and '1' or '0'");
    state=((W112_Q_FrameGetTextFn)W112_Q_FRAME_GET_TEXT_FN)("W112_Q_EDITING",-1,0u);
    return !state || state[0]!='0' || state[1]!=0;
}
static void W112_Q_Select(BYTE *self)
{
    BYTE *mgr,*obj,*bestObj=0;
    DWORD i,lo,hi,bestLo=0u,bestHi=0u,bestBand=3u;
    float px,py,pz,bestPct=2.0f,bestD2=1600.0f;
    if(!Ptr(self) || !W112_Q_NativeSignaturesValid() || W112_Q_ChatHasFocus())return;
    mgr=*(BYTE**)ADDR_OBJMGR_GLOBAL;
    if(!Ptr(mgr))return;
    px=*(float*)(self+OFF_UNIT_X);
    py=*(float*)(self+OFF_UNIT_Y);
    pz=*(float*)(self+OFF_UNIT_Z);
    if(!W112_Q_PosValid(px,py,pz))return;
    obj=*(BYTE**)(mgr+OFF_OM_FIRST_OBJECT);
    for(i=0u;i<4095u && Ptr(obj);++i) {
        BYTE *next=*(BYTE**)(obj+OFF_OBJ_NEXT);
        if(obj!=self && *(DWORD*)(obj+W112_Q_TYPE_ID_OFF)==W112_Q_TYPEID_PLAYER) {
            DWORD *desc=*(DWORD**)(obj+OFF_OBJ_DESCRIPTOR_PTR);
            if(Ptr(desc)) {
                DWORD hp=*(DWORD*)((BYTE*)desc+W112_Q_HEALTH_DESC_OFF);
                DWORD maxHp=*(DWORD*)((BYTE*)desc+W112_Q_MAX_HEALTH_DESC_OFF);
                if(hp>0u && maxHp>0u && hp<=maxHp) {
                    float x=*(float*)(obj+OFF_UNIT_X),y=*(float*)(obj+OFF_UNIT_Y),z=*(float*)(obj+OFF_UNIT_Z);
                    if(W112_Q_PosValid(x,y,z)) {
                        float dx=x-px,dy=y-py,dz=z-pz,d2=dx*dx+dy*dy+dz*dz;
                        if(d2<=1600.0f && d2>=0.0f) {
                            DWORD band=(d2<=100.0f)?0u:(d2<=400.0f)?1u:2u;
                            float pct=(float)hp/(float)maxHp;
                            lo=*(DWORD*)(obj+OFF_OBJ_GUID_LOW);
                            hi=*(DWORD*)(obj+OFF_OBJ_GUID_HIGH);
                            if((lo|hi) &&
                               (band<bestBand ||
                                (band==bestBand && (pct<bestPct ||
                                 (pct==bestPct && (d2<bestD2 ||
                                  (d2==bestD2 && (hi<bestHi || (hi==bestHi && lo<bestLo)))))))) &&
                               ((W112_Q_CanAttackFn)W112_Q_CAN_ATTACK_FN)((DWORD)self,(DWORD)obj)) {
                                bestObj=obj;bestBand=band;bestPct=pct;bestD2=d2;
                                bestLo=lo;bestHi=hi;
                            }
                        }
                    }
                }
            }
        }
        if(!Ptr(next) || next==obj || next==mgr)break;
        obj=next;
    }
    if(bestObj) {
        unsigned long long guid=((unsigned long long)bestHi<<32)|(unsigned long long)bestLo;
        ((W112_Q_TargetGuidFn)W112_Q_TARGET_GUID_FN)(&guid);
        ++g_qSelections;
    } else ++g_qNoTargets;
}
static void W112_Q_Tick(BYTE *self,DWORD now,DWORD pressed)
{
    BYTE *mgr=*(BYTE**)ADDR_OBJMGR_GLOBAL;
    if(!Ptr(self) || !Ptr(mgr)) {
        g_qMgr=0u;g_qSelf=0u;g_qReadySince=0u;
    } else if((DWORD)mgr!=g_qMgr || (DWORD)self!=g_qSelf) {
        g_qMgr=(DWORD)mgr;g_qSelf=(DWORD)self;g_qReadySince=now;
    } else if(pressed && !g_qWasDown &&
              (DWORD)(now-g_qReadySince)>=750u) {
        W112_Q_Select(self);
    }
    g_qWasDown=pressed;
}

/* Observe the vanilla casting bar in every zone, including item casts
   and channels. Only the existing UI timer invokes FrameScript. */
static DWORD W112_AB_CapCastVisible(void)
{
    static const char script[]=
        "W112_CAST_GUARD='0';"
        "if CastingBarFrame and (CastingBarFrame.casting or "
        "CastingBarFrame.channeling) then W112_CAST_GUARD='1' end";
    const char *s;
    DebugChat(script);
    s=((W112_Q_FrameGetTextFn)W112_Q_FRAME_GET_TEXT_FN)("W112_CAST_GUARD",-1,0u);
    return (s&&s[0]=='1'&&s[1]==0)?1u:0u;
}

/* A disappearing/replaced player invalidates every synthetic transaction.
 * Do not send a restoration heartbeat while a world is being replaced. */
static void W112_LoginGuardTick(BYTE*p,DWORD now)
{
    BYTE*m=*(BYTE**)ADDR_OBJMGR_GLOBAL;
    DWORD lo=0u,hi=0u;
    if(Ptr(m)){
        lo=*(DWORD*)(m+OFF_OM_LOCAL_GUID_LOW);
        hi=*(DWORD*)(m+OFF_OM_LOCAL_GUID_HIGH);
    }
    if(!Ptr(p)||!Ptr(m)||!(lo|hi)||
       !ValidWorldPos(*(float*)(p+OFF_UNIT_X),*(float*)(p+OFF_UNIT_Y),*(float*)(p+OFF_UNIT_Z))){
        if(g_loginGuardReady||g_loginGuardSince){
            if(g_gatherActive||g_gatherLootWait||g_gatherSpoof)GatherClearForPPFast(now,0u);
            g_mode=MODE_OFF;g_lastInject=0u;g_coordRearUntil=0u;
            g_abCapGuardActive=0u;
        }
        g_loginGuardReady=0u;g_loginGuardSince=0u;
        g_loginGuardMgr=g_loginGuardPlayer=0u;
        g_loginGuardGuidLo=g_loginGuardGuidHi=0u;
        return;
    }
    if(g_loginGuardMgr!=(DWORD)m||g_loginGuardPlayer!=(DWORD)p||
       g_loginGuardGuidLo!=lo||g_loginGuardGuidHi!=hi){
        if(g_loginGuardReady||g_loginGuardSince){
            if(g_gatherActive||g_gatherLootWait||g_gatherSpoof)GatherClearForPPFast(now,0u);
            g_mode=MODE_OFF;g_lastInject=0u;g_coordRearUntil=0u;
            g_abCapGuardActive=0u;
        }
        g_loginGuardReady=0u;g_loginGuardSince=now;
        g_loginGuardMgr=(DWORD)m;g_loginGuardPlayer=(DWORD)p;
        g_loginGuardGuidLo=lo;g_loginGuardGuidHi=hi;
        return;
    }
    if(!g_loginGuardReady&&(DWORD)(now-g_loginGuardSince)>=W112_LOGIN_SETTLE_MS)
        g_loginGuardReady=1u;
}

/*
 * EXPERIMENTAL TELE-ON-CLICK, build 5875 x86, defaults OFF.
 * Press E while aiming at terrain with F6 enabled and native CTM ON.
 * E only samples the cursor raycast and does not issue a ground-click command;
 * a type-1 terrain hit on E is experimental until confirmed in game.
 * Exact 5875 native ray picker: click-info pointer 0xB4B2BC, refresh 0x481F00,
 * hit type at +0x350 (1 = terrain, 2 = unit/object), world XYZ at +0x360
 * is validated for terrain, but EXPERIMENTAL for object hits. Do not silently
 * treat object XYZ as a verified safe ground landing point.
 * The patched project EXE has not yet been in-game validated for this path.
 * E is an explicit one-shot even during native walking, CTM transitions,
 * player position drift, casts or competing movement ownership. The pending
 * object hit is still refreshed for target stability before the pulse.
 * Retain world readiness, finite XYZ and cursor memory validation; a sent
 * heartbeat is not evidence that the server accepted the destination.
 */
#define W112_TELE_CLICK_INFO_PTR 0x00B4B2BCu
#define W112_TELE_REFRESH_FN     0x00481F00u
#define W112_TELE_HIT_TYPE_OFF  0x350u
#define W112_TELE_HIT_POS_OFF   0x360u
#define W112_TELE_KEY_E         0x45u /* E, press edge only */
#define W112_TELE_F6            0x75u
#define W112_TELE_MIN_D2        0.25f /* ignore same-point clicks */
#define W112_TELE_SETTLE_MS     250u
#define W112_TELE_TIMEOUT_MS    700u
#define W112_TELE_OBJ_STABLE_D2  0.25f /* same cursor-hit XYZ within 0.5yd */
typedef struct W112_TELE_MBI {
    DWORD base,allocation_base,allocation_protect,region_size,state,protect,type;
} W112_TELE_MBI;
__declspec(dllimport) DWORD __stdcall VirtualQuery(const void*,void*,DWORD);
typedef void (__fastcall *W112_TeleRefreshFn)(void*);
static volatile DWORD g_stepEnabled=0u,g_stepKey6=0u,g_teleKeyWasDown=0u;
static DWORD g_teleWaitSince=0u,g_teleWaitLast=0u;
static DWORD g_telePending=0u,g_telePendingHitType=0u,g_telePendingFromMap=0u;
static void W112_CancelTeleForBlink(void){
 g_telePending=0u;g_stepActive=0u;
}
static float g_teleDestX=0.0f,g_teleDestY=0.0f,g_teleDestZ=0.0f;
static const char g_stepOnChat[]="if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage('|cff55ff55[Tele E]|r ON: aim GROUND/OBJECT + press E (walking/CTM allowed); object XYZ experimental; F7 abort') end";
static const char g_stepOffChat[]="if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage('|cffffaa00[Tele E]|r OFF') end";
static const char g_teleSentChat[]="if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage('|cff55ff55[Tele E]|r one pulse sent; SERVER acceptance NOT confirmed') end";
static const char g_mapSentChat[]="if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage('|cff55ff55[Tele map]|r pulse sent; destination Z not terrain-checked; SERVER acceptance NOT confirmed') end";
static const char g_teleStopChat[]="if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage('|cffffff55[Tele E]|r point captured; preparing one pulse (walking/CTM allowed)') end";
static const char g_teleObjectChat[]="if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage('|cffffff55[Tele E]|r OBJECT hit: XYZ not validated as ground; experimental pulse only after stable recheck') end";
static const char g_teleObjectAbortChat[]="if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage('|cffffaa00[Tele E]|r OBJECT hit changed/lost or XYZ invalid; no pulse') end";
static const char g_teleAbortChat[]="if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage('|cffffaa00[Tele E]|r ABORT: second E / world unavailable / timeout / invalid XYZ; no pulse') end";
static const char g_teleTooCloseChat[]="if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage('|cffffaa00[Tele E]|r aim at a different point (minimum 0.5 units away)') end";
/* Every E press gets one stage-specific report; never claim an
 * accepted teleport merely because the client sent a movement heartbeat. */
static const char g_teleBlockedChat[]="if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage('|cffffaa00[Tele E]|r unavailable: teleport disabled or world not ready') end";
static const char g_teleChatFocusChat[]="if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage('|cffffaa00[Tele E]|r blocked: chat edit box') end";
static const char g_teleMemoryChat[]="if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage('|cffff5555[Tele E]|r cursor raycast memory unavailable') end";
/* A non-terrain hit may mean no intersection (0), world hit (1) or object (2);
 * report raw pre/post values before changing offsets or treating it as ground. */
static void W112_TeleReportHit(DWORD before,DWORD after)
{
    char script[220];char*q=script;
    q=AppStr(q,"if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage('[Tele E] ray hit before=");
    q=AppU32(q,before);q=AppStr(q," after=");q=AppU32(q,after);
    q=AppStr(q," (0=none, 1=terrain, 2=object)') end");*q=0;
    DebugChat(script);
}
static const char g_teleBadPosChat[]="if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage('|cffff5555[Tele E]|r invalid hit/player XYZ') end";

static DWORD W112_TeleRangeValid(DWORD addr,DWORD size,DWORD executable);
/* Type 2 identifies a unit/object, but +0x360 is only independently
 * documented for terrain. Enable type-2 as a user-requested experiment,
 * never claim its XYZ to be a verified ground or collision-safe position.
 * Recheck type and XYZ after settling to reject stale/changing hits. */
/* Diagnostic mode: absolute client player XYZ and cursor XYZ are sampled
 * in the SAME UI tick. Consecutive-click deltas tell a moving player/camera
 * apart from a changing ground/object point. Type 2 is NOT trusted as terrain.
 * Preview only until cursor-field provenance is confirmed for patched EXE. */
#define W112_TELE_DIAG_ONLY 0u
static DWORD g_telePrevSampleValid=0u;
static float g_telePrevHitX=0.0f,g_telePrevHitY=0.0f,g_telePrevHitZ=0.0f;
static float g_telePrevPlayerX=0.0f,g_telePrevPlayerY=0.0f,g_telePrevPlayerZ=0.0f;
static void W112_TeleReportPoint(DWORD info,BYTE *player,DWORD hitType)
{
    float x,y,z,px,py,pz;char script[260];char*q=script;
    if(!player||!W112_TeleRangeValid(info+W112_TELE_HIT_POS_OFF,12u,0u))return;
    x=*(volatile float*)(info+W112_TELE_HIT_POS_OFF);
    y=*(volatile float*)(info+W112_TELE_HIT_POS_OFF+4u);
    z=*(volatile float*)(info+W112_TELE_HIT_POS_OFF+8u);
    px=*(float*)(player+OFF_UNIT_X);
    py=*(float*)(player+OFF_UNIT_Y);
    pz=*(float*)(player+OFF_UNIT_Z);
    if(!W112_Q_PosValid(x,y,z)||!W112_Q_PosValid(px,py,pz)){
        DebugChat(g_teleBadPosChat);g_telePrevSampleValid=0u;return;
    }
    q=AppStr(q,"if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage('[TeleDiag] type=");
    q=AppU32(q,hitType);
    q=AppStr(q," click10=");
    q=AppS32(q,(LONG)(x*10.0f));*q++=',';
    q=AppS32(q,(LONG)(y*10.0f));*q++=',';
    q=AppS32(q,(LONG)(z*10.0f));
    q=AppStr(q," player10=");
    q=AppS32(q,(LONG)(px*10.0f));*q++=',';
    q=AppS32(q,(LONG)(py*10.0f));*q++=',';
    q=AppS32(q,(LONG)(pz*10.0f));
    q=AppStr(q,"') end");*q=0;DebugChat(script);
    if(g_telePrevSampleValid){
        q=script;
        q=AppStr(q,"if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage('[TeleDiag] since previous click dHit10=");
        q=AppS32(q,(LONG)((x-g_telePrevHitX)*10.0f));*q++=',';
        q=AppS32(q,(LONG)((y-g_telePrevHitY)*10.0f));*q++=',';
        q=AppS32(q,(LONG)((z-g_telePrevHitZ)*10.0f));
        q=AppStr(q," dPlayer10=");
        q=AppS32(q,(LONG)((px-g_telePrevPlayerX)*10.0f));*q++=',';
        q=AppS32(q,(LONG)((py-g_telePrevPlayerY)*10.0f));*q++=',';
        q=AppS32(q,(LONG)((pz-g_telePrevPlayerZ)*10.0f));
        q=AppStr(q,"') end");*q=0;DebugChat(script);
    }
    g_telePrevHitX=x;g_telePrevHitY=y;g_telePrevHitZ=z;
    g_telePrevPlayerX=px;g_telePrevPlayerY=py;g_telePrevPlayerZ=pz;
    g_telePrevSampleValid=1u;
}

static DWORD W112_TeleRangeValid(DWORD addr,DWORD size,DWORD executable)
{
    W112_TELE_MBI mbi;DWORD end,protect;
    if(!addr||!size||addr+size<addr||
       VirtualQuery((const void*)addr,&mbi,sizeof(mbi))!=sizeof(mbi))return 0u;
    end=mbi.base+mbi.region_size;protect=mbi.protect&0xFFu;
    if(end<mbi.base||addr<mbi.base||addr+size>end||
       mbi.state!=0x1000u||(mbi.protect&0x100u))return 0u;
    if(executable)return protect==0x10u||protect==0x20u||
                         protect==0x40u||protect==0x80u;
    return protect==0x02u||protect==0x04u||protect==0x08u||
           protect==0x20u||protect==0x40u||protect==0x80u;
}
static DWORD W112_TeleAvailable(BYTE *p)
{
    /* E is an explicit one-shot: do not reject it solely because a cast,
     * AutoPP, gather, SafeBreak or rear module currently owns movement.
     * Prevent re-entry during the pulse; retain the world/player checks. */
    if(!g_stepEnabled||!g_loginGuardReady||!Ptr(p)||
       g_stepMoveInjecting)return 0u;
    return 1u;
}

/* Map open is checked at the E edge AND before dispatch of an earlier
 * terrain raycast. A visible map never forwards E to terrain under the UI.
 * E over the map canvas submits the SAME validated map request as left click.
 * This Lua UI query is synchronous on the existing UI timer. */
#define W112_MAP_GETTEXT_FN 0x00703BF0u
typedef const char* (__fastcall *W112_MapGetTextFn)(const char*,int,DWORD);
static const char g_teleMapVisibleScript[]=
 "W112_MAP_TELE_E_MAP_OPEN=(WorldMapFrame and WorldMapFrame:IsShown()) and '1' or '0'";
static const char g_teleMapECaptureScript[]=
 "if WorldMapFrame and WorldMapFrame:IsShown() then "
 "if WorldMapButton and WorldMapButton:IsVisible() then "
 "local scale=WorldMapButton:GetEffectiveScale();"
 "local w=WorldMapButton:GetWidth();local h=WorldMapButton:GetHeight();"
 "if scale and scale>0 and w and w>0 and h and h>0 then "
 "local x,y=GetCursorPosition();"
 "local mx=(x/scale-WorldMapButton:GetLeft())/w;"
 "local my=(WorldMapButton:GetTop()-y/scale)/h;"
 "if mx>=0 and mx<=1 and my>=0 and my<=1 then "
 "W112_MAP_TELE_SEQ=(W112_MAP_TELE_SEQ or 0)+1;"
 "W112_MAP_TELE_REQUEST=tostring(W112_MAP_TELE_SEQ)..':'..tostring(math.floor(mx*1000000+0.5))..':'..tostring(math.floor(my*1000000+0.5));"
 "else if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage('[Tele map] E: point inside map canvas') end end "
 "end end end";
static DWORD W112_TeleMapShown(void)
{
 const char*raw;W112_MapGetTextFn getText=(W112_MapGetTextFn)W112_MAP_GETTEXT_FN;
 if(!W112_TeleRangeValid(W112_MAP_GETTEXT_FN,8u,1u))return 1u;/* fail closed */
 DebugChat(g_teleMapVisibleScript);
 raw=getText("W112_MAP_TELE_E_MAP_OPEN",-1,0u);
 return !raw||raw[0]!='0'||raw[1]!=0;/* unknown != proof map closed */
}

static void W112_KeyTeleTick(BYTE *p,DWORD now)
{
    DWORD pressed=(GK()(W112_TELE_KEY_E)&(short)0x8000)?1u:0u;
    DWORD trigger=pressed&&!g_teleKeyWasDown;
    DWORD info,hitType,hitBefore;
    float px,py,pz,x,y,z,dx,dy,dz;
    g_teleKeyWasDown=pressed;
    if(!g_stepEnabled){g_telePending=0u;g_stepActive=0u;return;}
    if(g_telePending){
        /* A second E press aborts rather than applying a stale destination. */
        if(trigger){g_telePending=0u;g_stepActive=0u;DebugChat(g_teleAbortChat);return;}
        if(!W112_TeleAvailable(p)||
           (DWORD)(now-g_teleWaitSince)>W112_TELE_TIMEOUT_MS){
            g_telePending=0u;g_stepActive=0u;DebugChat(g_teleAbortChat);return;
        }
        /* Native walking, CTM state and player drift do not block a user E.
         * Still reject invalid player coordinates before sending a pulse. */
        px=*(float*)(p+OFF_UNIT_X);py=*(float*)(p+OFF_UNIT_Y);
        pz=*(float*)(p+OFF_UNIT_Z);
        if(!W112_Q_PosValid(px,py,pz)){
            g_telePending=0u;g_stepActive=0u;DebugChat(g_teleAbortChat);return;
        }
        if((DWORD)(now-g_teleWaitLast)<W112_TELE_SETTLE_MS)return;
        if(!g_telePendingFromMap&&W112_TeleMapShown()){
            g_telePending=0u;g_stepActive=0u;DebugChat(g_teleAbortChat);return;
        }
        /* Unlike a terrain hit, type-2 XYZ has unverified provenance.
         * Refresh after the short settle interval and require a stable object
         * cursor point; player movement does not cancel the pending pulse. */
        if(g_telePendingHitType==2u){
            if(!W112_TeleRangeValid(W112_TELE_CLICK_INFO_PTR,4u,0u)||
               !W112_TeleRangeValid(W112_TELE_REFRESH_FN,16u,1u)){
                g_telePending=0u;g_stepActive=0u;DebugChat(g_teleObjectAbortChat);return;
            }
            info=*(volatile DWORD*)W112_TELE_CLICK_INFO_PTR;
            if(!Ptr((void*)info)||
               !W112_TeleRangeValid(info,W112_TELE_HIT_POS_OFF+12u,0u)){
                g_telePending=0u;g_stepActive=0u;DebugChat(g_teleObjectAbortChat);return;
            }
            ((W112_TeleRefreshFn)W112_TELE_REFRESH_FN)((void*)info);
            hitType=*(volatile DWORD*)(info+W112_TELE_HIT_TYPE_OFF);
            if(hitType!=2u){
                g_telePending=0u;g_stepActive=0u;DebugChat(g_teleObjectAbortChat);return;
            }
            x=*(volatile float*)(info+W112_TELE_HIT_POS_OFF);
            y=*(volatile float*)(info+W112_TELE_HIT_POS_OFF+4u);
            z=*(volatile float*)(info+W112_TELE_HIT_POS_OFF+8u);
            dx=x-g_teleDestX;dy=y-g_teleDestY;dz=z-g_teleDestZ;
            if(!W112_Q_PosValid(x,y,z)||
               dx*dx+dy*dy+dz*dz>W112_TELE_OBJ_STABLE_D2){
                g_telePending=0u;g_stepActive=0u;DebugChat(g_teleObjectAbortChat);return;
            }
        }
        /* One pulse; never chase server corrections or touch CTM action. */
        g_telePending=0u;
        g_stepMoveInjecting=1u;
        *(float*)(p+OFF_UNIT_X)=g_teleDestX;
        *(float*)(p+OFF_UNIT_Y)=g_teleDestY;
        *(float*)(p+OFF_UNIT_Z)=g_teleDestZ;
        ((SendMove_t)ADDR_SEND_MOVE)(p,MSG_MOVE_HEARTBEAT);
        g_stepMoveInjecting=0u;
        g_stepActive=0u;
        DebugChat(g_telePendingFromMap?g_mapSentChat:g_teleSentChat);
        g_telePendingFromMap=0u;
        return;
    }
    if(!trigger)return;
    if(W112_Q_ChatHasFocus()){DebugChat(g_teleChatFocusChat);return;}
    if(!W112_TeleAvailable(p)){DebugChat(g_teleBlockedChat);return;}
    if(W112_TeleMapShown()){
        DebugChat(g_teleMapECaptureScript); /* never fall through to terrain */
        return;
    }
    if(!W112_TeleRangeValid(W112_TELE_CLICK_INFO_PTR,4u,0u)||
       !W112_TeleRangeValid(W112_TELE_REFRESH_FN,16u,1u)){
        DebugChat(g_teleMemoryChat);return;
    }
    info=*(volatile DWORD*)W112_TELE_CLICK_INFO_PTR;
    if(!Ptr((void*)info)||!W112_TeleRangeValid(info,W112_TELE_HIT_POS_OFF+12u,0u)){
        DebugChat(g_teleMemoryChat);return;
    }
    hitBefore=*(volatile DWORD*)(info+W112_TELE_HIT_TYPE_OFF);
    ((W112_TeleRefreshFn)W112_TELE_REFRESH_FN)((void*)info);
    hitType=*(volatile DWORD*)(info+W112_TELE_HIT_TYPE_OFF);
    if(hitType!=1u&&hitType!=2u){
        W112_TeleReportHit(hitBefore,hitType);
        g_telePrevSampleValid=0u;
        return;
    }
    if(hitType==2u){
        W112_TeleReportPoint(info,p,hitType);
        DebugChat(g_teleObjectChat);
    }
    if(W112_TELE_DIAG_ONLY){W112_TeleReportPoint(info,p,hitType);return;}
    x=*(volatile float*)(info+W112_TELE_HIT_POS_OFF);
    y=*(volatile float*)(info+W112_TELE_HIT_POS_OFF+4u);
    z=*(volatile float*)(info+W112_TELE_HIT_POS_OFF+8u);
    px=*(float*)(p+OFF_UNIT_X);py=*(float*)(p+OFF_UNIT_Y);pz=*(float*)(p+OFF_UNIT_Z);
    if(!W112_Q_PosValid(x,y,z)||!W112_Q_PosValid(px,py,pz)){
        DebugChat(g_teleBadPosChat);return;
    }
    /* No artificial horizontal range or vertical offset limit: retain finite
     * world-coordinate validation and a real cursor hit. Native collision/server
     * acceptance is NOT proven for long jumps or non-navigable terrain. */
    dx=x-px;dy=y-py;
    if(dx*dx+dy*dy<W112_TELE_MIN_D2){DebugChat(g_teleTooCloseChat);return;}
    /* Explicit E is independent of native CTM state and walking flags.
     * Do not issue unverified native CTM STOP commands. */
    g_teleDestX=x;g_teleDestY=y;g_teleDestZ=z;
    g_telePendingHitType=hitType;
    g_telePending=1u;g_stepActive=1u;g_teleWaitSince=now;g_teleWaitLast=now;
    DebugChat(g_teleStopChat);
}


/*
 * Parallel TEST / map-to-world Tele Click bridge for WoW 5875 x86.
 * WorldMapButton Lua captures normalized map coordinates into one string;
 * the existing FrameScript_GetText bridge reads that string on the UI timer.
 * WorldMapArea.dbc record and view addresses are candidates documented for
 * build 5875 by ClassicAPI (brues-code/ClassicAPI src/map/Area.cpp,
 * src/Offsets.h, GPL-3.0); no third-party source is copied. All pointer
 * chains and map/continent identities are validated before attempting a
 * single existing Tele E movement pulse. This code does NOT know remote
 * terrain Z: it explicitly keeps the player's present Z, and does not assert
 * a safe landing, world load or server acceptance.
 */
#define W112_MAP_VIEW_CONTINENT 0x0084506Cu
#define W112_MAP_VIEW_ZONE      0x00845070u
#define W112_MAP_DEFAULT_ROW    0x00845074u
#define W112_MAP_VIEW_DATA      0x00B6E668u
#define W112_MAP_VIEW_STRIDE    0x10024u
#define W112_MAP_AREA_RECORDS   0x00C0D5BCu
#define W112_MAP_AREA_COUNT     0x00C0D5C0u
#define W112_MAP_LOADED_ID      0x00B4E378u
static DWORD g_mapInstallLast=0u,g_mapSeqSeen=0u;
static const char g_mapInstallScript[]=
 "if WorldMapButton and WorldMapFrame and not W112_MAP_TELE_HOOKED then "
 "local cb=CreateFrame('CheckButton','W112MapTeleToggle',WorldMapFrame,'UICheckButtonTemplate');"
 "cb:SetWidth(24);cb:SetHeight(24);"
 "cb:SetPoint('TOPLEFT',WorldMapFrame,'TOPLEFT',38,-26);"
 "local label=WorldMapFrame:CreateFontString(nil,'OVERLAY','GameFontNormalSmall');"
 "label:SetPoint('LEFT',cb,'RIGHT',2,0);label:SetText('Tele map: click / E (F6)');"
 "if W112_MAP_TELE_ON==nil then W112_MAP_TELE_ON=0 end;" 
 "if W112_MAP_TELE_SEQ==nil then W112_MAP_TELE_SEQ=0 end;" 
 "if W112_MAP_TELE_REQUEST==nil then W112_MAP_TELE_REQUEST='' end;"
 "cb:SetScript('OnClick',function() "
 "W112_MAP_TELE_ON=this:GetChecked() and 1 or 0;"
 "if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage('[Tele map] '..(W112_MAP_TELE_ON==1 and 'ON' or 'OFF')) end end);"
 "local old=WorldMapButton:GetScript('OnClick');"
 "WorldMapButton:SetScript('OnClick',function() "
 "if W112_MAP_TELE_ON~=1 or arg1~='LeftButton' then if old then old() end return end;"
 "if W112_MAP_TELE_BRIDGE_ON~=1 then "
 "if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage('[Tele map] enable F6 first') end return end;"
 "local scale=WorldMapButton:GetEffectiveScale();"
 "if not scale or scale<=0 then return end;"
 "local w=WorldMapButton:GetWidth();local h=WorldMapButton:GetHeight();"
 "if not w or not h or w<=0 or h<=0 then return end;"
 "local x,y=GetCursorPosition();"
 "local mx=(x/scale-WorldMapButton:GetLeft())/w;"
 "local my=(WorldMapButton:GetTop()-y/scale)/h;"
 "if mx>=0 and mx<=1 and my>=0 and my<=1 then "
 "W112_MAP_TELE_SEQ=W112_MAP_TELE_SEQ+1;"
 "W112_MAP_TELE_REQUEST=tostring(W112_MAP_TELE_SEQ)..':'..tostring(math.floor(mx*1000000+0.5))..':'..tostring(math.floor(my*1000000+0.5));"
 "end end);W112_MAP_TELE_HOOKED='1';"
 "end";
static const char g_mapCapturedChat[]="if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage('|cffffff55[Tele map]|r XY selected; Z = your CURRENT height (terrain height UNKNOWN), experimental pulse queued; F7 abort') end";
static const char g_mapBadViewChat[]="if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage('|cffffaa00[Tele map]|r unsupported world/continent or map data unavailable; no pulse') end";
static const char g_mapBadPointChat[]="if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage('|cffffaa00[Tele map]|r invalid map coordinates; no pulse') end";
static DWORD W112_MapParseUnsigned(const char**at,DWORD*out)
{
 const char*p=*at;DWORD n=0u,v=0u;
 while(*p>='0'&&*p<='9'){
  DWORD digit=(DWORD)(*p-'0');
  if(++n>10u||v>429496729u||(v==429496729u&&digit>5u))return 0u;
  v=v*10u+digit;++p;
 }
 if(!n)return 0u;
 *out=v;*at=p;return 1u;
}
static DWORD W112_MapReadRequest(const char*raw,DWORD*seq,DWORD*mx,DWORD*my)
{
 const char*p=raw;
 if(!p||!W112_MapParseUnsigned(&p,seq)||*p++!=':'||
    !W112_MapParseUnsigned(&p,mx)||*p++!=':'||
    !W112_MapParseUnsigned(&p,my)||*p||!*seq||
    *mx>1000000u||*my>1000000u)return 0u;
 return 1u;
}
static DWORD W112_MapWorldXY(DWORD mx,DWORD my,float*wx,float*wy)
{
 DWORD cont,zone,data,entry,zoneRows,row,base,records,rec,mapId,count;
 float left,right,top,bottom,x,y;
 if(!W112_TeleRangeValid(W112_MAP_VIEW_CONTINENT,12u,0u)||
    !W112_TeleRangeValid(W112_MAP_VIEW_DATA,4u,0u)||
    !W112_TeleRangeValid(W112_MAP_AREA_RECORDS,8u,0u)||
    !W112_TeleRangeValid(W112_MAP_LOADED_ID,4u,0u))return 0u;
 cont=*(volatile DWORD*)W112_MAP_VIEW_CONTINENT;
 zone=*(volatile DWORD*)W112_MAP_VIEW_ZONE;
 if(cont==0xFFFFFFFFu||cont>8u)return 0u; /* world map is ambiguous */
 data=*(volatile DWORD*)W112_MAP_VIEW_DATA;
 if(!data||cont> (0xFFFFFFFFu-W112_MAP_VIEW_STRIDE)/W112_MAP_VIEW_STRIDE)return 0u;
 entry=data+cont*W112_MAP_VIEW_STRIDE;
 if(entry<data||!W112_TeleRangeValid(entry+4u,0x10u,0u))return 0u;
 if(zone==0xFFFFFFFFu)row=*(volatile DWORD*)(entry+4u);
 else {
  if(zone>255u)return 0u;
  zoneRows=*(volatile DWORD*)(entry+0x10u);
  if(!zoneRows||!W112_TeleRangeValid(zoneRows+zone*4u,4u,0u))return 0u;
  row=*(volatile DWORD*)(zoneRows+zone*4u);
 }
 count=*(volatile DWORD*)W112_MAP_AREA_COUNT;
 records=*(volatile DWORD*)W112_MAP_AREA_RECORDS;
 if(!row||row>count||count>2048u||!records||
    !W112_TeleRangeValid(records+row*4u,4u,0u))return 0u;
 rec=*(volatile DWORD*)(records+row*4u);
 if(!rec||!W112_TeleRangeValid(rec,0x20u,0u))return 0u;
 mapId=*(volatile DWORD*)(rec+4u);
 if(mapId!=*(volatile DWORD*)W112_MAP_LOADED_ID)return 0u;
 left=*(volatile float*)(rec+0x10u);right=*(volatile float*)(rec+0x14u);
 top=*(volatile float*)(rec+0x18u);bottom=*(volatile float*)(rec+0x1Cu);
 if(!W112_Q_PosValid(top,left,0.0f)||!W112_Q_PosValid(bottom,right,0.0f)||
    !(left>right)||!(top>bottom))return 0u;
 x=top-((float)my/1000000.0f)*(top-bottom);
 y=left-((float)mx/1000000.0f)*(left-right);
 if(!W112_Q_PosValid(x,y,0.0f))return 0u;
 *wx=x;*wy=y;return 1u;
}
static void W112_MapTeleTick(BYTE*p,DWORD now)
{
 const char*raw;DWORD seq,mx,my;float x,y,px,py,pz,dx,dy;
 W112_MapGetTextFn getText=(W112_MapGetTextFn)W112_MAP_GETTEXT_FN;
 if(!g_stepEnabled||!g_loginGuardReady||!Ptr(p))return;
 if((DWORD)(now-g_mapInstallLast)>=1000u){
  g_mapInstallLast=now;
  if(!W112_TeleRangeValid(W112_MAP_GETTEXT_FN,8u,1u))return;
  raw=getText("W112_MAP_TELE_HOOKED",-1,0u);
  if(!raw||raw[0]!='1'||raw[1]!=0)DebugChat(g_mapInstallScript);
 }
 if(!W112_TeleRangeValid(W112_MAP_GETTEXT_FN,8u,1u))return;
 raw=getText("W112_MAP_TELE_REQUEST",-1,0u);
 if(!W112_MapReadRequest(raw,&seq,&mx,&my)||seq==g_mapSeqSeen)return;
 g_mapSeqSeen=seq; /* consume before testing to avoid repeated pulses */
 if(g_telePending||g_stepMoveInjecting)return;
 if(!W112_TeleAvailable(p))return;
 if(!W112_MapWorldXY(mx,my,&x,&y)){DebugChat(g_mapBadViewChat);return;}
 px=*(float*)(p+OFF_UNIT_X);py=*(float*)(p+OFF_UNIT_Y);
 pz=*(float*)(p+OFF_UNIT_Z);
 if(!W112_Q_PosValid(px,py,pz)||!W112_Q_PosValid(x,y,pz)){
  DebugChat(g_mapBadPointChat);return;
 }
 dx=x-px;dy=y-py;
 if(dx*dx+dy*dy<W112_TELE_MIN_D2){
  DebugChat(g_teleTooCloseChat);return;
 }
 g_teleDestX=x;g_teleDestY=y;g_teleDestZ=pz;
 g_telePendingHitType=1u;g_telePendingFromMap=1u;
 g_telePending=1u;g_stepActive=1u;
 g_teleWaitSince=now;g_teleWaitLast=now;
 DebugChat(g_mapCapturedChat);
}

/* AutoOpen alone yields to combat, movement and ANY cast/channel.
   Movement flags belong to the existing verified 5875 player moveinfo;
   the first six bits cover directional movement/turning and 0xE000
   covers the jump/fall family. Missing moveinfo fails closed. */
static DWORD W112_AutoOpenBusy(BYTE*p)
{
    DWORD*flags;
    if(!Ptr(p)||Combat(p))return 1u;
    flags=MoveFlags(p);
    if(!flags||(*flags&0x0000E03Fu))return 1u;
    if(g_abCapGuardActive||(*(volatile DWORD*)ADDR_CASTING_SPELLID))return 1u;
    return 0u;
}

/* Native 5875 outbound movement callsite. Diagnostic Z is the SENT value,
 * not a measured or server-acknowledged position. */
static DWORD __cdecl Plane_TryDirectMovement(DataStore5875 *packet)
{
    BYTE *player,*raw;
    DWORD *moveFlags;
    float x,y,z,localX,localY,localZ,newZ;
    if(!g_planeEnabled||!g_loginGuardReady||!packet||
       packet->size<0x20u||packet->size>MAX_PACKET_SIZE)return 0u;
    if(g_injecting||g_stepMoveInjecting||g_stepActive||g_telePending||
       g_mode!=MODE_OFF||g_gatherActive||g_gatherLootWait||g_gatherSpoof||
       LongPPActive()||LongPPInjecting()||g_ppResetInProgress||
       g_abCapGuardActive||CoordRearOwned()||
       *(volatile DWORD*)ADDR_CASTING_SPELLID)return 0u;
    player=LocalPlayer();
    if(!Ptr(player)||Combat(player))return 0u;
    moveFlags=MoveFlags(player);
    if(!moveFlags||(*moveFlags&
       (MOVEFLAG_ONTRANSPORT|MOVEFLAG_SWIMMING|MOVEFLAG_FLYING|0x0000E000u)))
       return 0u;
    raw=PacketRawBase(packet);
    if(!raw)return 0u;
    x=*(float*)(raw+0x0Cu);y=*(float*)(raw+0x10u);z=*(float*)(raw+0x14u);
    localX=*(float*)(player+OFF_UNIT_X);
    localY=*(float*)(player+OFF_UNIT_Y);
    localZ=*(float*)(player+OFF_UNIT_Z);
    if(!ValidWorldPos(x,y,z)||!ValidWorldPos(localX,localY,localZ)||
       AbsF(x-localX)>1.5f||AbsF(y-localY)>1.5f||
       AbsF(z-localZ)>1.5f)return 0u;
    newZ=z-(float)g_planeDepth;
    if(!ValidWorldPos(x,y,newZ))return 0u;
    *(float*)(raw+0x14u)=newZ;
    g_planeTxZ10=(LONG)(newZ*10.0f);
    ++g_planePackets;
    g_planeLastApplied=1u;
    return 1u;
}
static void Plane_Disable(BYTE *player,DWORD combat)
{
    DWORD restore=g_planeLastApplied;
    g_planeEnabled=0u;g_planeLastApplied=0u;
    if(restore&&g_loginGuardReady&&Ptr(player)&&!LongPPActive()&&
       !LongPPInjecting()&&!g_injecting&&!g_gatherActive&&
       !g_gatherLootWait&&!g_stepMoveInjecting&&!g_abCapGuardActive)
        SendReal(player);
    DebugChat(combat?g_planeCombatChat:g_planeOffChat);
}

static void __stdcall AltPriority_TimerProc(HWND w,UINT m,UINT_PTR id,DWORD tm)
{
    DWORD now,dur,gap,k7,k8,k9,kAlt,k10,k11,k12,paused;BYTE*p;
    (void)w;(void)m;(void)id;(void)tm;
    if(!GT()||!GK())return;
    now=GT()();
    p=LocalPlayer();
    W112_LoginGuardTick(p,now);
    if(!g_loginGuardReady){
        g_planeEnabled=0u;g_planeLastApplied=0u;
        g_altPriorityPendingUntil=0u;g_stepActive=0u;g_telePending=0u;return;
    }
    if(g_planeEnabled&&p&&Combat(p))Plane_Disable(p,1u);
    W112_PPGuard_Tick(p,now);
    CombatVeinObserve(p,now);
    PPBlacklistTick(now);
    PPFixed_Flush();
    FlushPendingPPLog();
    k7=(GK()(VK_F7)&(short)0x8000)?1u:0u;
    k8=(GK()(VK_F8)&(short)0x8000)?1u:0u;
    k9=(GK()(VK_F9)&(short)0x8000)?1u:0u;
    kAlt=(GK()(VK_LMENU)&(short)0x8000)?1u:0u;
    k10=(GK()(VK_F10)&(short)0x8000)?1u:0u;
    k11=(GK()(VK_F11)&(short)0x8000)?1u:0u;
    k12=(GK()(VK_F12)&(short)0x8000)?1u:0u;
    {DWORD f6=(GK()(W112_TELE_F6)&(short)0x8000)?1u:0u;
     if(f6&&!g_stepKey6&&!W112_Q_ChatHasFocus()){
        g_stepEnabled=g_stepEnabled?0u:1u;
        g_stepActive=0u;
        g_telePending=0u;
        g_telePrevSampleValid=0u;
        g_teleKeyWasDown=(GK()(W112_TELE_KEY_E)&(short)0x8000)?1u:0u;
        DebugChat(g_stepEnabled?g_stepOnChat:g_stepOffChat);
        DebugChat(g_stepEnabled?"W112_MAP_TELE_BRIDGE_ON=1":"W112_MAP_TELE_BRIDGE_ON=0");
     }
     g_stepKey6=f6;
    }

    if(k7&&!g_key7){g_stepActive=0u;g_telePending=0u;g_altPriorityPendingUntil=0u;AltPriority_Stop(TRUE);if(g_gatherActive||g_gatherLootWait)GatherStop(LocalPlayer(),now,"F7_ABORT",1u,0u);}
    if(k8&&!g_key8&&!CoordRearOwned())Start(MODE_LEGACY_FAST,now);
    if(k9&&!g_gatherKey9){g_gatherEnabled=g_gatherEnabled?0u:1u;GatherFileLog(g_gatherEnabled?"TOGGLE_ON":"TOGGLE_OFF",now,0u,0u,0u,0.0f,0u,0u);DebugChat(g_gatherEnabled?g_chatOn:g_chatOff);}
    /* A key edge used to be discarded while PvERear had the rear lease.
       Queue this explicit manual request, even for a short ALT tap. */
    if(kAlt&&!g_keyAlt&&!(k7&&!g_key7))g_altPriorityPendingUntil=now+7000u;
    if(k10&&!g_key10&&!CoordRearOwned())Start(MODE_PURSUIT,now);
    if(k11&&!g_key11){g_autoPPEnabled=g_autoPPEnabled?0u:1u;DebugChat(g_autoPPEnabled?g_chatPPOn:g_chatPPOff);GatherFileLog(g_autoPPEnabled?"AUTOPP_TOGGLE_ON":"AUTOPP_TOGGLE_OFF",now,0u,0u,0u,0.0f,0u,0u);}
    if(k12&&!g_autoOpenKey12){g_autoOpenEnabled=g_autoOpenEnabled?0u:1u;DebugChat(g_autoOpenEnabled?g_chatOpenOn:g_chatOpenOff);GatherFileLog(g_autoOpenEnabled?"AUTOOPEN_TOGGLE_ON":"AUTOOPEN_TOGGLE_OFF",now,0u,0u,0u,0.0f,0u,0u);if(!g_autoOpenEnabled&&g_gatherActive&&g_gatherKind==3u)GatherStop(LocalPlayer(),now,"AUTOOPEN_DISABLED_ABORT",1u,0u);}
    g_key7=k7;g_key8=k8;g_gatherKey9=k9;g_keyAlt=kAlt;g_key10=k10;g_key11=k11;g_autoOpenKey12=k12;

    if(p && W112_AB_CapCastVisible()){
        g_abCapGuardActive=1u;
        g_abCapGuardLastSeen=now;
        /* An already-running SafeBreak must not resume with a packet burst. */
        if(g_mode!=MODE_OFF){g_mode=MODE_OFF;g_lastInject=0u;g_started=0u;}
        /* Do not interrupt an existing gather cast or emit a real-position
           restoration heartbeat during an unrelated cast. */
        if(g_gatherActive||g_gatherLootWait){
            DWORD castId=*(DWORD*)ADDR_CASTING_SPELLID;
            if(!castId||!GatherCastMatches(g_gatherKind,castId))
                GatherStop(p,now,"CAST_GUARD_FOREIGN_GATHER_ABORT",0u,0u);
        }
    }else if(!p || !g_abCapGuardLastSeen || (DWORD)(now-g_abCapGuardLastSeen)>=200u){
        g_abCapGuardActive=0u;
        if(!p)g_abCapGuardLastSeen=0u;
    }
    W112_Q_Tick(p,now,(GK()(W112_Q_KEY)&(short)0x8000)?1u:0u);
    W112_KeyTeleTick(p,now);
    W112_MapTeleTick(p,now);
    /* Hold competing periodic movement writers only while the E destination
     * is settling; do not cancel their casts or persistently disable them. */
    if(g_telePending&&g_mode!=MODE_OFF&&!g_safeBreakPauseTick)
        g_safeBreakPauseTick=now;
    if(p){
        if(!g_gatherReadyChat){g_gatherReadyChat=1u;DebugChat(g_ppChainOk?g_chatReady:g_chatChainBad);if(g_ppChainOk){DebugChat(g_autoPPEnabled?g_chatPPOn:g_chatPPOff);DebugChat(g_autoOpenEnabled?g_chatOpenOn:g_chatOpenOff);}}
        TrackChestNativeTick(p);
        TrackChestTick(p,now);
        if(!g_planeEnabled&&!g_telePending&&!CoordRearOwned()&&
           (!g_abCapGuardActive||g_gatherActive||g_gatherLootWait)){
            DWORD autoOpenWasEnabled=g_autoOpenEnabled;
            if(autoOpenWasEnabled&&W112_AutoOpenBusy(p)){
                /* Cancel a pending AutoOpen click/retry, then exclude AutoOpen
                   from this scan; Mining/Herbalism continue unchanged. */
                if((g_gatherActive||g_gatherLootWait)&&g_gatherKind==3u)
                    GatherStop(p,now,"AUTOOPEN_BUSY_ABORT",0u,0u);
                g_autoOpenEnabled=0u;
                GatherTick(p,now);
                g_autoOpenEnabled=autoOpenWasEnabled;
            }else GatherTick(p,now);
        }
    }else if(g_gatherActive||g_gatherLootWait){
        g_gatherActive=0u;g_gatherLootWait=0u;g_gatherLootWaitUntil=0u;g_gatherLootStart=0u;
        g_gatherLootSeenOpen=0u;g_gatherLootOpenLogged=0u;g_gatherSawCast=0u;g_gatherCastSeenLogged=0u;
        g_gatherStealthPending=0u;g_gatherSpoof=0u;
        GatherFileLog("WORLD_LOST_ABORT",now,g_gatherEntry,g_gatherTargetLo,g_gatherTargetHi,g_gatherDistSq,g_gatherAttempts,0u);
    }
    /* The rear lease ends in PvERear's own timer. Start only after it clears;
       otherwise its movement hook could rewrite the SafeBreak XYZ. Keep the
       same cast/channel guard and abort stale requests on world loss. */
    if(g_altPriorityPendingUntil){
        if(!p||(LONG)(now-g_altPriorityPendingUntil)>=0)g_altPriorityPendingUntil=0u;
        else if(!g_abCapGuardActive&&!CoordRearOwned()){
            g_altPriorityPendingUntil=0u;
            AltPriority_Start(now);
        }
    }
    if(g_mode==MODE_OFF||g_abCapGuardActive||g_telePending)return;
    /* A physical Blink has the existing rear lease: do not inject an
     * independent SafeBreak XYZ into the same movement transaction. Preserve
     * the SafeBreak time budget and resume it after the Blink releases. */
    if(CoordRearOwned()){
        if(!g_safeBreakPauseTick)g_safeBreakPauseTick=now;
        return;
    }

    if(g_mode==MODE_LOCAL_STRONG){
        /* An already-started PP owns its current transaction. Pause only for
           that real ownership window; ignore the synthetic 1200 ms quiet tail.
           New PP starts are blocked by AltPriority_SendWrapper. */
        if(LongPPActive()||LongPPInjecting()||(*(DWORD*)ADDR_CASTING_SPELLID)==SPELL_PICK_POCKET){
            if(!g_safeBreakPauseTick)g_safeBreakPauseTick=now;
            ++g_ppSafeBreakYields;
            return;
        }
        if((LONG)(g_ppQuietUntil-now)>0){g_ppQuietUntil=0u;++g_altPriorityQuietBypasses;}
    }else if(LongPPActive()||LongPPInjecting()||(*(DWORD*)ADDR_CASTING_SPELLID)==SPELL_PICK_POCKET||((LONG)(g_ppQuietUntil-now)>0)){
        if(!g_safeBreakPauseTick)g_safeBreakPauseTick=now;
        ++g_ppSafeBreakYields;
        return;
    }

    if(g_safeBreakPauseTick){
        paused=(DWORD)(now-g_safeBreakPauseTick);
        g_started+=paused;
        g_safeBreakPauseMs+=paused;
        g_safeBreakPauseTick=0u;
        g_lastInject=0u;
        ++g_safeBreakResumes;
    }

    p=LocalPlayer();
    if(!p){g_worldLost=1u;g_worldReadySince=0u;++g_worldGuardHits;return;}
    if(g_worldLost){
        if(!g_worldReadySince){g_worldReadySince=now;++g_worldGuardHits;return;}
        if((DWORD)(now-g_worldReadySince)<WORLD_REACQUIRE_MS){++g_worldGuardHits;return;}
        AltPriority_Stop(FALSE);
        return;
    }

    dur=(g_mode==MODE_LEGACY_FAST)?LEGACY_FAST_MS:(g_mode==MODE_LOCAL_STRONG)?LOCAL_STRONG_MS:(g_mode==MODE_PURSUIT)?PURSUIT_MS:INSTANCE_MS;
    gap=(g_mode==MODE_LEGACY_FAST)?LEGACY_FAST_GAP_MS:(g_mode==MODE_LOCAL_STRONG)?LOCAL_STRONG_GAP_MS:(g_mode==MODE_PURSUIT)?PURSUIT_GAP_MS:INSTANCE_GAP_MS;
    if(g_seenCombat){
        if(!Combat(p)){
            if(!g_clearTick)g_clearTick=now;
            else if((DWORD)(now-g_clearTick)>=CLEAR_SETTLE_MS){AltPriority_Stop(TRUE);return;}
        }else g_clearTick=0u;
    }
    if((DWORD)(now-g_started)>=dur){AltPriority_Stop(TRUE);return;}
    if(!g_lastInject||(DWORD)(now-g_lastInject)>=gap){g_lastInject=now;Inject(p);}
}

static BOOL AltPriority_Install(void)
{
    DWORD oldMove=DCall(ADDR_MOVE_SEND_CALL),oldSend=DJump(ADDR_CLIENT_SEND);
    g_altPriorityBaseSendWrapper=(DWORD)(LPVOID)&PPArbiter_SendWrapper;
    if(!g_altPriorityBaseSendWrapper||!g_installed||oldMove!=(DWORD)(LPVOID)&MovementCore_MoveWrapper)return FALSE;
    if(!PCall(ADDR_MOVE_SEND_CALL,(DWORD)(LPVOID)&AltPriority_MoveWrapper))return FALSE;
    if(g_ppChainOk){
        if(oldSend!=g_altPriorityBaseSendWrapper||!PJump(ADDR_CLIENT_SEND,(DWORD)(LPVOID)&AltPriority_SendWrapper)){
            PCall(ADDR_MOVE_SEND_CALL,(DWORD)(LPVOID)&MovementCore_MoveWrapper);
            return FALSE;
        }
    }
    if(g_timerId&&KT())KT()((HWND)0,(UINT_PTR)g_timerId);
    g_timerId=0u;
    if(ST())g_timerId=(DWORD)ST()((HWND)0,(UINT_PTR)0,TIMER_MS,AltPriority_TimerProc);
    if(!g_timerId){
        if(g_ppChainOk&&DJump(ADDR_CLIENT_SEND)==(DWORD)(LPVOID)&AltPriority_SendWrapper)PJump(ADDR_CLIENT_SEND,g_altPriorityBaseSendWrapper);
        if(DCall(ADDR_MOVE_SEND_CALL)==(DWORD)(LPVOID)&AltPriority_MoveWrapper)PCall(ADDR_MOVE_SEND_CALL,(DWORD)(LPVOID)&MovementCore_MoveWrapper);
        if(ST())g_timerId=(DWORD)ST()((HWND)0,(UINT_PTR)0,TIMER_MS,TimerProc);
        return FALSE;
    }
    g_altPriorityInstalled=1u;
    GatherFileLog("ALT_PRIORITY_READY",GT()?GT()():0u,0u,0u,0u,0.0f,0u,0x00000015u);
    return TRUE;
}

static void AltPriority_Remove(void)
{
    if(g_timerId&&KT())KT()((HWND)0,(UINT_PTR)g_timerId);
    g_timerId=0u;
    if(g_ppChainOk&&DJump(ADDR_CLIENT_SEND)==(DWORD)(LPVOID)&AltPriority_SendWrapper&&g_altPriorityBaseSendWrapper)PJump(ADDR_CLIENT_SEND,g_altPriorityBaseSendWrapper);
    if(DCall(ADDR_MOVE_SEND_CALL)==(DWORD)(LPVOID)&AltPriority_MoveWrapper)PCall(ADDR_MOVE_SEND_CALL,(DWORD)(LPVOID)&MovementCore_MoveWrapper);
    g_altPriorityInstalled=0u;
    g_altPriorityBaseSendWrapper=0u;
}

static const W112_ControlEnumOptionV1 g_modeOptions[]={
    {MODE_OFF,"Off"},
    {MODE_LEGACY_FAST,"F8 Fast"},
    {MODE_LOCAL_STRONG,"ALT Strong"},
    {MODE_PURSUIT,"F10 Pursuit"},
    {MODE_INSTANCE_UNREACHABLE,"Instance"}
};
/* GUI checkbox ON means ignore the entire mining-node family. */
static const struct {const char*key;const char*label;} g_miningBlacklistControls[]={
    {"skip_copper","Skip Copper Vein"},
    {"skip_tin","Skip Tin Vein"},
    {"skip_silver","Skip Silver Vein"},
    {"skip_iron","Skip Iron Deposit"},
    {"skip_gold","Skip Gold Vein"},
    {"skip_mithril","Skip Mithril Deposit"},
    {"skip_truesilver","Skip Truesilver"},
    {"skip_small_thorium","Skip Small Thorium"},
    {"skip_rich_thorium","Skip Rich Thorium"},
    {"skip_dark_iron","Skip Dark Iron"},
    {"skip_bloodstone","Skip Bloodstone"},
    {"skip_incendicite","Skip Incendicite"},
    {"skip_indurium","Skip Indurium"},
    {"skip_hakkari_thorium","Skip Hakkari Thorium"}
};
/* Keep the vein selections when the global blacklist is paused. The V20
 * scanner and Mining-first PP arbitration read only the effective mask. */
static volatile DWORD g_miningBlacklistEnabled=1u;
static volatile DWORD g_miningBlacklistSavedMask=0u;
/* One provider owns Gather/Herb/AutoOpen/AutoChest; no competing hook DLL. */
static W112_ControlSettingV1 g_controlSettings[50u];

static void W112_MiningBlacklistApply(BYTE*p,DWORD now)
{
    g_miningBlacklistMask=g_miningBlacklistEnabled?g_miningBlacklistSavedMask:0u;
    g_miningPriorityValidUntil=0u;
    g_miningPriorityEntry=g_miningPriorityLo=g_miningPriorityHi=0u;
    g_miningPriorityD2=0.0f;
    g_miningPriorityNextScan=0u;
    g_gatherNextScan=0u;
    if(g_gatherActive&&g_gatherKind==2u&&
       (MiningBlacklistBit(g_gatherEntry)&g_miningBlacklistMask))
        GatherStop(p,now,"GUI_MINING_BLACKLIST",1u,0u);
}
static volatile DWORD g_controlDescriptorReady=0u;

static void init_control_descriptor(void)
{
    W112_ControlSettingV1*s;
    DWORD i;
    if(g_controlDescriptorReady)return;

    s=&g_controlSettings[0];
    s->struct_size=(w112_u32)sizeof(W112_ControlSettingV1);s->setting_id=1u;s->key="auto_gather";s->label="AutoGather (F9)";
    s->type=W112_CTL_BOOL;s->default_value.u32=1u;s->min_value.u32=0u;s->max_value.u32=1u;s->step.u32=1u;s->flags=W112_CTL_LIVE;s->enum_options=0;s->enum_option_count=0u;

    s=&g_controlSettings[1];
    s->struct_size=(w112_u32)sizeof(W112_ControlSettingV1);s->setting_id=2u;s->key="auto_pp";s->label="Auto PickPocket (F11)";
    s->type=W112_CTL_BOOL;s->default_value.u32=1u;s->min_value.u32=0u;s->max_value.u32=1u;s->step.u32=1u;s->flags=W112_CTL_LIVE;s->enum_options=0;s->enum_option_count=0u;

    s=&g_controlSettings[2];
    s->struct_size=(w112_u32)sizeof(W112_ControlSettingV1);s->setting_id=3u;s->key="auto_open";s->label="AutoOpen (F12)";
    s->type=W112_CTL_BOOL;s->default_value.u32=1u;s->min_value.u32=0u;s->max_value.u32=1u;s->step.u32=1u;s->flags=W112_CTL_LIVE;s->enum_options=0;s->enum_option_count=0u;

    s=&g_controlSettings[3];
    s->struct_size=(w112_u32)sizeof(W112_ControlSettingV1);s->setting_id=4u;s->key="mode";s->label="SafeBreak mode";
    s->type=W112_CTL_ENUM;s->default_value.i32=MODE_OFF;s->min_value.i32=MODE_OFF;s->max_value.i32=MODE_INSTANCE_UNREACHABLE;s->step.i32=1;s->flags=W112_CTL_READ_ONLY|W112_CTL_LIVE;s->enum_options=g_modeOptions;s->enum_option_count=(w112_u32)(sizeof(g_modeOptions)/sizeof(g_modeOptions[0]));

    s=&g_controlSettings[4];
    s->struct_size=(w112_u32)sizeof(W112_ControlSettingV1);s->setting_id=5u;s->key="gather_active";s->label="Gather active";
    s->type=W112_CTL_BOOL;s->default_value.u32=0u;s->min_value.u32=0u;s->max_value.u32=1u;s->step.u32=1u;s->flags=W112_CTL_READ_ONLY|W112_CTL_LIVE;s->enum_options=0;s->enum_option_count=0u;

    s=&g_controlSettings[5];
    s->struct_size=(w112_u32)sizeof(W112_ControlSettingV1);s->setting_id=6u;s->key="alt_starts";s->label="ALT starts";
    s->type=W112_CTL_INT;s->default_value.i32=0;s->min_value.i32=0;s->max_value.i32=2147483647;s->step.i32=1;s->flags=W112_CTL_READ_ONLY|W112_CTL_LIVE;s->enum_options=0;s->enum_option_count=0u;

    s=&g_controlSettings[6];
    s->struct_size=(w112_u32)sizeof(W112_ControlSettingV1);s->setting_id=7u;s->key="alt_pp_blocks";s->label="ALT PP blocks";
    s->type=W112_CTL_INT;s->default_value.i32=0;s->min_value.i32=0;s->max_value.i32=2147483647;s->step.i32=1;s->flags=W112_CTL_READ_ONLY|W112_CTL_LIVE;s->enum_options=0;s->enum_option_count=0u;

    for(i=0u;i<14u;i++){
        s=&g_controlSettings[7u+i];
        s->struct_size=(w112_u32)sizeof(W112_ControlSettingV1);s->setting_id=8u+i;
        s->key=g_miningBlacklistControls[i].key;s->label=g_miningBlacklistControls[i].label;
        s->type=W112_CTL_BOOL;s->default_value.u32=0u;s->min_value.u32=0u;s->max_value.u32=1u;s->step.u32=1u;
        s->flags=W112_CTL_LIVE;s->enum_options=0;s->enum_option_count=0u;
    }

    s=&g_controlSettings[21u];
    s->struct_size=(w112_u32)sizeof(W112_ControlSettingV1);s->setting_id=22u;
    s->key="mining_early_restore";s->label="Mining: real XYZ during cast (TEST)";
    s->type=W112_CTL_BOOL;s->default_value.u32=0u;s->min_value.u32=0u;s->max_value.u32=1u;s->step.u32=1u;s->flags=W112_CTL_LIVE;s->enum_options=0;s->enum_option_count=0u;
    s=&g_controlSettings[22u];
    s->struct_size=(w112_u32)sizeof(W112_ControlSettingV1);s->setting_id=23u;
    s->key="mining_early_releases";s->label="Mining early releases";
    s->type=W112_CTL_INT;s->default_value.i32=0;s->min_value.i32=0;s->max_value.i32=2147483647;s->step.i32=1;s->flags=W112_CTL_READ_ONLY|W112_CTL_LIVE;s->enum_options=0;s->enum_option_count=0u;
    s=&g_controlSettings[23u];
    s->struct_size=(w112_u32)sizeof(W112_ControlSettingV1);s->setting_id=24u;
    s->key="mining_early_interrupts";s->label="Mining early interrupts";
    s->type=W112_CTL_INT;s->default_value.i32=0;s->min_value.i32=0;s->max_value.i32=2147483647;s->step.i32=1;s->flags=W112_CTL_READ_ONLY|W112_CTL_LIVE;s->enum_options=0;s->enum_option_count=0u;

    s=&g_controlSettings[24u];
    s->struct_size=(w112_u32)sizeof(W112_ControlSettingV1);s->setting_id=25u;
    s->key="mining_below_node";s->label="Mining below ore - Z 4yd (TEST)";
    s->type=W112_CTL_BOOL;s->default_value.u32=0u;s->min_value.u32=0u;s->max_value.u32=1u;s->step.u32=1u;s->flags=W112_CTL_LIVE;s->enum_options=0;s->enum_option_count=0u;

    s=&g_controlSettings[25u];
    s->struct_size=(w112_u32)sizeof(W112_ControlSettingV1);s->setting_id=26u;
    s->key="vein_blacklist_enabled";s->label="Vein Blacklist ON/OFF";
    s->type=W112_CTL_BOOL;s->default_value.u32=1u;s->min_value.u32=0u;s->max_value.u32=1u;s->step.u32=1u;
    s->flags=W112_CTL_LIVE;s->enum_options=0;s->enum_option_count=0u;

    s=&g_controlSettings[26u];
    s->struct_size=(w112_u32)sizeof(W112_ControlSettingV1);s->setting_id=27u;
    s->key="combat_vein_blacklist";s->label="Auto blacklist veins after combat onset";
    s->type=W112_CTL_BOOL;s->default_value.u32=1u;s->min_value.u32=0u;s->max_value.u32=1u;s->step.u32=1u;
    s->flags=W112_CTL_LIVE;s->enum_options=0;s->enum_option_count=0u;
    s=&g_controlSettings[27u];
    s->struct_size=(w112_u32)sizeof(W112_ControlSettingV1);s->setting_id=28u;
    s->key="combat_vein_count";s->label="Combat vein blacklist (session count)";
    s->type=W112_CTL_INT;s->default_value.i32=0;s->min_value.i32=0;s->max_value.i32=COMBAT_VEIN_MAX;s->step.i32=1;
    s->flags=W112_CTL_READ_ONLY|W112_CTL_LIVE;s->enum_options=0;s->enum_option_count=0u;
    {
        static const char* keys[8]={
            "auto_chest","chest_battered","chest_solid","chest_large_battered",
            "chest_large_solid","chest_iron_bound","chest_mithril_bound",
            "chest_auto_loot"
        };
        static const char* labels[8]={
            "AutoChest (independent)","Chest: Battered/Tattered",
            "Chest: Solid","Chest: Large Battered","Chest: Large Solid",
            "Chest: Iron Bound","Chest: Mithril Bound","Chest: Auto loot"
        };
        for(i=0u;i<8u;++i){
            s=&g_controlSettings[28u+i];
            s->struct_size=(w112_u32)sizeof(W112_ControlSettingV1);
            s->setting_id=29u+i;s->key=keys[i];s->label=labels[i];
            s->type=W112_CTL_BOOL;s->default_value.u32=i==0u?0u:1u;
            s->min_value.u32=0u;s->max_value.u32=1u;s->step.u32=1u;
            s->flags=W112_CTL_LIVE;s->enum_options=0;s->enum_option_count=0u;
        }
    }
    {
        static const char* keys[4]={"chest_scan_seen","chest_scan_eligible","chest_scan_entry","chest_current_step"};
        static const char* labels[4]={"Chest: loaded candidates","Chest: eligible candidates","Chest: last entry","Chest: current Z step"};
        for(i=0u;i<4u;++i){
            s=&g_controlSettings[36u+i];s->struct_size=(w112_u32)sizeof(W112_ControlSettingV1);
            s->setting_id=37u+i;s->key=keys[i];s->label=labels[i];s->type=W112_CTL_INT;
            s->default_value.i32=0;s->min_value.i32=0;s->max_value.i32=2147483647;
            s->step.i32=1;s->flags=W112_CTL_READ_ONLY|W112_CTL_LIVE;
            s->enum_options=0;s->enum_option_count=0u;
        }
    }
    {
        static const char* keys[2]={"chest_scan_reason","chest_pos_source"};
        static const char* labels[2]={"Chest: scan reason","Chest: position source"};
        for(i=0u;i<2u;++i){
            s=&g_controlSettings[40u+i];s->struct_size=(w112_u32)sizeof(W112_ControlSettingV1);
            s->setting_id=41u+i;s->key=keys[i];s->label=labels[i];s->type=W112_CTL_INT;
            s->default_value.i32=0;s->min_value.i32=0;s->max_value.i32=2147483647;
            s->step.i32=1;s->flags=W112_CTL_READ_ONLY|W112_CTL_LIVE;
            s->enum_options=0;s->enum_option_count=0u;
        }
    }
    /* Separate from AutoChest: tracking never enables the opener. */
    s=&g_controlSettings[42u];s->struct_size=(w112_u32)sizeof(W112_ControlSettingV1);
    s->setting_id=43u;s->key="track_chests";s->label="Track Chests (minimap)";
    s->type=W112_CTL_BOOL;s->default_value.u32=0u;s->min_value.u32=0u;
    s->max_value.u32=1u;s->step.u32=1u;s->flags=W112_CTL_LIVE;
    s->enum_options=0;s->enum_option_count=0u;
    s=&g_controlSettings[43u];s->struct_size=(w112_u32)sizeof(W112_ControlSettingV1);
    s->setting_id=44u;s->key="track_chests_count";s->label="Track Chests: visible dots";
    s->type=W112_CTL_INT;s->default_value.i32=0;s->min_value.i32=0;
    s->max_value.i32=TRACK_CHEST_MAX_DOTS;s->step.i32=1;
    s->flags=W112_CTL_READ_ONLY|W112_CTL_LIVE;
    s->enum_options=0;s->enum_option_count=0u;
    s=&g_controlSettings[44u];s->struct_size=(w112_u32)sizeof(W112_ControlSettingV1);
    s->setting_id=45u;s->key="plane_enabled";s->label="Teleport to Plane (TEST)";
    s->type=W112_CTL_BOOL;s->default_value.u32=0u;s->min_value.u32=0u;
    s->max_value.u32=1u;s->step.u32=1u;s->flags=W112_CTL_LIVE;
    s->enum_options=0;s->enum_option_count=0u;
    s=&g_controlSettings[45u];s->struct_size=(w112_u32)sizeof(W112_ControlSettingV1);
    s->setting_id=46u;s->key="plane_depth";s->label="Plane: outgoing Z depth (yd)";
    s->type=W112_CTL_INT;s->default_value.i32=12;s->min_value.i32=4;
    s->max_value.i32=40;s->step.i32=1;s->flags=W112_CTL_LIVE;
    s->enum_options=0;s->enum_option_count=0u;
    s=&g_controlSettings[46u];s->struct_size=(w112_u32)sizeof(W112_ControlSettingV1);
    s->setting_id=47u;s->key="plane_packets";s->label="Plane: rewritten packets";
    s->type=W112_CTL_INT;s->default_value.i32=0;s->min_value.i32=0;
    s->max_value.i32=2147483647;s->step.i32=1;
    s->flags=W112_CTL_READ_ONLY|W112_CTL_LIVE;
    s->enum_options=0;s->enum_option_count=0u;
    s=&g_controlSettings[47u];s->struct_size=(w112_u32)sizeof(W112_ControlSettingV1);
    s->setting_id=48u;s->key="plane_tx_z10";s->label="Plane: last SENT Z x10 (not server ACK)";
    s->type=W112_CTL_INT;s->default_value.i32=0;s->min_value.i32=-200000;
    s->max_value.i32=200000;s->step.i32=1;
    s->flags=W112_CTL_READ_ONLY|W112_CTL_LIVE;
    s->enum_options=0;s->enum_option_count=0u;
    /* 5875 native resource-track field override; OFF uses existing Lua dots.
     * This is an explicit opt-in probe, not a claim of server-side aura. */
    s=&g_controlSettings[48u];s->struct_size=(w112_u32)sizeof(W112_ControlSettingV1);
    s->setting_id=49u;s->key="track_chests_native";s->label="Track Chests: native 5875 (TEST)";
    s->type=W112_CTL_BOOL;s->default_value.u32=0u;s->min_value.u32=0u;
    s->max_value.u32=1u;s->step.u32=1u;s->flags=W112_CTL_LIVE;
    s->enum_options=0;s->enum_option_count=0u;
    s=&g_controlSettings[49u];s->struct_size=(w112_u32)sizeof(W112_ControlSettingV1);
    s->setting_id=50u;s->key="track_native_mask";s->label="Track Chests: current client resource mask";
    s->type=W112_CTL_INT;s->default_value.i32=0;s->min_value.i32=0;
    s->max_value.i32=2147483647;s->step.i32=1;
    s->flags=W112_CTL_READ_ONLY|W112_CTL_LIVE;
    s->enum_options=0;s->enum_option_count=0u;
    g_controlDescriptorReady=1u;
}

static int W112_CTL_STDCALL movement_control_get(w112_u32 id,W112_ControlValueV1*out)
{
    if(!out)return 0;
    if(id==45u){out->u32=g_planeEnabled?1u:0u;return 1;}
    if(id==46u){out->i32=(w112_i32)g_planeDepth;return 1;}
    if(id==47u){out->i32=(w112_i32)g_planePackets;return 1;}
    if(id==48u){out->i32=(w112_i32)g_planeTxZ10;return 1;}
    if(id==1u){out->u32=g_gatherEnabled?1u:0u;return 1;}
    if(id==2u){out->u32=g_autoPPEnabled?1u:0u;return 1;}
    if(id==3u){out->u32=g_autoOpenEnabled?1u:0u;return 1;}
    if(id==4u){out->i32=(w112_i32)g_mode;return 1;}
    if(id==5u){out->u32=(g_gatherActive||g_gatherLootWait)?1u:0u;return 1;}
    if(id==6u){out->i32=(w112_i32)g_altPriorityStarts;return 1;}
    if(id==7u){out->i32=(w112_i32)g_altPriorityPPBlocks;return 1;}
    if(id>=8u&&id<22u){out->u32=(g_miningBlacklistSavedMask&(1u<<(id-8u)))?1u:0u;return 1;}
    if(id==22u){out->u32=g_miningEarlyRestoreEnabled?1u:0u;return 1;}
    if(id==23u){out->i32=(w112_i32)g_miningEarlyRestoreCount;return 1;}
    if(id==24u){out->i32=(w112_i32)g_miningEarlyCancelCount;return 1;}
    if(id==25u){out->u32=g_miningBelowNodeEnabled?1u:0u;return 1;}
    if(id==26u){out->u32=g_miningBlacklistEnabled?1u:0u;return 1;}
    if(id==27u){out->u32=g_combatVeinEnabled?1u:0u;return 1;}
    if(id==28u){out->i32=(w112_i32)g_combatVeinCount;return 1;}
    if(id==49u){out->u32=g_trackChestNativeMode?1u:0u;return 1;}
    if(id==50u){out->i32=(w112_i32)g_trackNativeMask;return 1;}
    if(id==43u){out->u32=g_trackChestsEnabled?1u:0u;return 1;}
    if(id==44u){out->i32=(w112_i32)g_trackChestCount;return 1;}
    if(id==29u){out->u32=g_chestEnabled?1u:0u;return 1;}
    if(id>=30u&&id<=35u){out->u32=(g_chestGroupsMask&(1u<<(id-30u)))?1u:0u;return 1;}
    if(id==36u){out->u32=g_chestAutoLoot?1u:0u;return 1;}
    if(id==37u){out->i32=(w112_i32)g_chestScanSeen;return 1;}
    if(id==38u){out->i32=(w112_i32)g_chestScanEligible;return 1;}
    if(id==39u){out->i32=(w112_i32)g_chestScanLastEntry;return 1;}
    if(id==40u){out->i32=(w112_i32)((g_gatherActive&&g_gatherKind==4u)?g_chestStep:0u);return 1;}
    if(id==41u){out->i32=(w112_i32)((g_gatherActive&&g_gatherKind==4u)?8u:g_chestScanReason);return 1;}
    if(id==42u){out->i32=(w112_i32)g_chestScanPosSrc;return 1;}
    return 0;
}

static int W112_CTL_STDCALL movement_control_set(w112_u32 id,const W112_ControlValueV1*value)
{
    DWORD now;
    BYTE*p;
    if(!value||value->u32>1u)return 0;
    now=GT()?GT()():0u;
    p=LocalPlayer();

    if(id==49u){g_trackChestNativeMode=value->u32;g_trackChestNext=0u;return 1;}
    if(id==43u){
        if(value->u32>1u)return 0;
        g_trackChestsEnabled=value->u32;
        g_trackChestNext=0u;
        return 1;
    }
    if(id==29u){
        /* Explicit OFF->ON is the user-controlled reset of aggro-unsafe GOs. */
        if(value->u32&&!g_chestEnabled)g_chestAggroLo=g_chestAggroHi=0u;
        g_chestEnabled=value->u32;
        if(!g_chestEnabled&&g_gatherActive&&g_gatherKind==4u)
            GatherStop(p,now,"GUI_AUTOCHEST_DISABLED",1u,0u);
        g_gatherNextScan=0u;return 1;
    }
    if(id>=30u&&id<=35u){
        DWORD bit=1u<<(id-30u);
        if(value->u32)g_chestGroupsMask|=bit;
        else g_chestGroupsMask&=~bit;
        if(g_gatherActive&&g_gatherKind==4u&&!(g_chestGroupsMask&ChestGroupBit(g_gatherEntry)))
            GatherStop(p,now,"GUI_AUTOCHEST_TYPE_DISABLED",1u,0u);
        g_gatherNextScan=0u;g_trackChestNext=0u;return 1;
    }
    if(id==36u){g_chestAutoLoot=value->u32;return 1;}
    if(id==45u){
        if(value->u32){
            if(!g_loginGuardReady||!Ptr(p)||Combat(p))return 0;
            if(!g_planeEnabled){
                if(g_gatherActive||g_gatherLootWait)
                    GatherStop(p,now,"PLANE_TEST_GATHER_ABORT",1u,0u);
                g_planeEnabled=1u;g_planeLastApplied=0u;
                DebugChat(g_planeOnChat);
            }
        }else if(g_planeEnabled)Plane_Disable(p,0u);
        return 1;
    }
    if(id==46u){
        if(value->i32<4||value->i32>40)return 0;
        g_planeDepth=(DWORD)value->i32;return 1;
    }
    if(id==1u){
        g_gatherEnabled=value->u32;
        if(!g_gatherEnabled&&(g_gatherActive||g_gatherLootWait))GatherStop(p,now,"GUI_GATHER_DISABLED",1u,0u);
        return 1;
    }
    if(id==27u){
        g_combatVeinEnabled=value->u32;
        if(!g_combatVeinEnabled)g_combatWatch=0u;
        g_miningPriorityValidUntil=0u;g_miningPriorityNextScan=0u;g_gatherNextScan=0u;
        return 1;
    }
    if(id==26u){
        g_miningBlacklistEnabled=value->u32;
        W112_MiningBlacklistApply(p,now);
        return 1;
    }
    if(id==2u){g_autoPPEnabled=value->u32;return 1;}
    if(id==3u){
        g_autoOpenEnabled=value->u32;
        if(!g_autoOpenEnabled&&g_gatherActive&&g_gatherKind==3u)GatherStop(p,now,"GUI_AUTOOPEN_DISABLED",1u,0u);
        return 1;
    }
    if(id==25u){
        /* Do not change the spoof endpoint mid-transaction: the following
         * node begins with the new setting; the current node completes at
         * the already chosen position. */
        g_miningBelowNodeEnabled=value->u32;
        if(value->u32)g_miningEarlyRestoreEnabled=0u;
        return 1;
    }
    if(id==22u){
        g_miningEarlyRestoreEnabled=value->u32;
        if(value->u32)g_miningBelowNodeEnabled=0u;
        if(!value->u32&&g_miningEarlyRestored&&Ptr(p)){
            g_miningEarlyRestored=0u;g_miningEarlyRestoreAt=0u;
            g_gatherSpoof=1u;GatherSendFake(p,now);
            GatherFileLog("MINING_EARLY_GUI_DISABLED",now,g_gatherEntry,g_gatherTargetLo,g_gatherTargetHi,g_gatherDistSq,g_gatherAttempts,0u);
        }
        return 1;
    }
    if(id>=8u&&id<22u){
        DWORD bit=1u<<(id-8u);
        if(value->u32)g_miningBlacklistSavedMask|=bit;
        else g_miningBlacklistSavedMask&=~bit;
        W112_MiningBlacklistApply(p,now);
        return 1;
    }
    return 0;
}

static const W112_ControlModuleV1 g_controlModule={
    W112_CONTROL_API_V1,(w112_u32)sizeof(W112_ControlModuleV1),
    "movementcore","MovementCore",0x00120000u,50u,g_controlSettings,
    movement_control_get,movement_control_set
};

W112_CTL_EXPORT const W112_ControlModuleV1 * W112_CTL_STDCALL W112_Control_GetModuleV1(void)
{
    init_control_descriptor();
    return &g_controlModule;
}

/* Diagnostic only: counts real target XYZ/O changes followed while LongPP is
   active. A nonzero count does not prove server-side acceptance of the spoof. */
__declspec(dllexport) DWORD __stdcall MovementCore_PPRearLiveRefreshes(void)
{return g_ppRearLiveRefresh;}
__declspec(dllexport) DWORD __stdcall MovementCore_GetVersion(void){return 0x00120000u;}
__declspec(dllexport) DWORD __stdcall MovementCore_GetAltPriorityInstalled(void){return g_altPriorityInstalled;}
__declspec(dllexport) DWORD __stdcall MovementCore_GetRearPriorityPackets(void){return g_rearPriorityDirectPackets;}
__declspec(dllexport) DWORD __stdcall MovementCore_GetLoginGuardReady(void){return g_loginGuardReady;}
/* Fail-closed auto-rear input guard, shared with the existing Q/chat query. */
__declspec(dllexport) DWORD __stdcall MovementCore_UserIsTyping(void){return W112_Q_ChatHasFocus()?1u:0u;}
__declspec(dllexport) DWORD __stdcall MovementCore_GetAltPriorityStarts(void){return g_altPriorityStarts;}
__declspec(dllexport) DWORD __stdcall MovementCore_GetAltPriorityPPBlocks(void){return g_altPriorityPPBlocks;}
__declspec(dllexport) DWORD __stdcall MovementCore_GetAltPriorityDirectPackets(void){return g_altPriorityDirectPackets;}
__declspec(dllexport) DWORD __stdcall MovementCore_GetAltPriorityDirectRestores(void){return g_altPriorityDirectRestores;}
__declspec(dllexport) DWORD __stdcall MovementCore_GetAltPriorityQuietBypasses(void){return g_altPriorityQuietBypasses;}
__declspec(dllexport) DWORD __stdcall MovementCore_ABCapGuardActive(void){return g_abCapGuardActive;}
__declspec(dllexport) DWORD __stdcall MovementCore_ABCapBlockedPP(void){return g_abCapGuardBlockedPP;}
__declspec(dllexport) DWORD __stdcall MovementCore_ABCapBlockedMove(void){return g_abCapGuardBlockedMove;}

#ifndef W112_V21_ENTRY
#define W112_V21_ENTRY DllMain
#endif
BOOL __stdcall W112_V21_ENTRY(HINSTANCE h,DWORD r,LPVOID x)
{
    if(r==DLL_PROCESS_ATTACH){
        if(!W112_MovementCoreV20_DllMain(h,r,x))return FALSE;
        if(!AltPriority_Install()){
            W112_MovementCoreV20_DllMain(h,DLL_PROCESS_DETACH,x);
            return FALSE;
        }
        if(W112_PPSelector_Install())
            GatherFileLog("AUTOPP_SELECTOR_BLACKLIST_BRIDGE_READY",
                          GT()?GT()():0u,0u,0u,0u,0.0f,0u,20u);
        else GatherFileLog("AUTOPP_SELECTOR_BRIDGE_UNAVAILABLE",
                           GT()?GT()():0u,0u,0u,0u,0.0f,0u,0u);
        return TRUE;
    }
    if(r==DLL_PROCESS_DETACH){
        W112_PPSelector_Remove();
        AltPriority_Remove();
        g_coordRearUntil=0u;g_stepActive=0u;g_stepEnabled=0u;
        g_planeEnabled=0u;g_planeLastApplied=0u;
        return W112_MovementCoreV20_DllMain(h,r,x);
    }
    return TRUE;
}