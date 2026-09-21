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
/* PvERear360 resolves this explicit undecorated x86 Win32 ABI export. */
#pragma comment(linker, "/EXPORT:MovementCore_GetAltPriorityInstalled=_MovementCore_GetAltPriorityInstalled@0")
#pragma comment(linker, "/EXPORT:MovementCore_GetRearPriorityPackets=_MovementCore_GetRearPriorityPackets@0")
#pragma comment(linker, "/EXPORT:MovementCore_UserIsTyping=_MovementCore_UserIsTyping@0")
#endif

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
 * A captured 0xC CTM state from LMB is empirical data, NOT a STOP/WALK enum;
 * require the same state for E and fail closed if the key path differs.
 * Require the same state and a stationary player across the settle interval;
 * never pulse when the state changes or the player walks.
 * Combat itself is allowed; fail closed on invalid cursor, casting, native
 * movement or another movement-owner lease.
 */
#define W112_TELE_CLICK_INFO_PTR 0x00B4B2BCu
#define W112_TELE_REFRESH_FN     0x00481F00u
#define W112_TELE_HIT_TYPE_OFF  0x350u
#define W112_TELE_HIT_POS_OFF   0x360u
#define W112_TELE_KEY_E         0x45u /* E, press edge only */
#define W112_TELE_F6            0x75u
#define W112_TELE_MIN_D2        0.25f /* ignore same-point clicks */
#define W112_TELE_CTM_ACTION    0x00C4D888u
#define W112_TELE_CTM_OBSERVED  12u /* empirically seen after LMB terrain hit */
#define W112_TELE_SETTLE_MS     250u
#define W112_TELE_TIMEOUT_MS    700u
#define W112_TELE_MAX_DRIFT_D2  0.04f
#define W112_TELE_OBJ_STABLE_D2  0.25f /* same cursor-hit XYZ within 0.5yd */
typedef struct W112_TELE_MBI {
    DWORD base,allocation_base,allocation_protect,region_size,state,protect,type;
} W112_TELE_MBI;
__declspec(dllimport) DWORD __stdcall VirtualQuery(const void*,void*,DWORD);
typedef void (__fastcall *W112_TeleRefreshFn)(void*);
static volatile DWORD g_stepEnabled=0u,g_stepKey6=0u,g_teleKeyWasDown=0u;
static DWORD g_teleWaitSince=0u,g_teleWaitLast=0u;
static DWORD g_telePending=0u,g_telePendingHitType=0u;
static float g_teleDestX=0.0f,g_teleDestY=0.0f,g_teleDestZ=0.0f;
static float g_teleStartX=0.0f,g_teleStartY=0.0f,g_teleStartZ=0.0f;
static const char g_stepOnChat[]="if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage('|cff55ff55[Tele E]|r ON: CTM ON; aim GROUND/OBJECT + press E; object XYZ experimental; F7 abort') end";
static const char g_stepOffChat[]="if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage('|cffffaa00[Tele E]|r OFF') end";
static const char g_teleSentChat[]="if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage('|cff55ff55[Tele E]|r one pulse sent; SERVER acceptance NOT confirmed') end";
static const char g_teleStopChat[]="if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage('|cffffff55[Tele E]|r point captured; waiting for stationary player (CTM unchanged)') end";
static const char g_teleObjectChat[]="if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage('|cffffff55[Tele E]|r OBJECT hit: XYZ not validated as ground; experimental pulse only after stable recheck') end";
static const char g_teleObjectAbortChat[]="if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage('|cffffaa00[Tele E]|r OBJECT hit changed/lost or XYZ invalid; no pulse') end";
static const char g_teleAbortChat[]="if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage('|cffffaa00[Tele E]|r ABORT: native walking/position drift/CTM state; no pulse') end";
static const char g_teleUnsupportedChat[]="if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage('|cffffaa00[Tele E]|r ABORT: CTM state memory unreadable; no pulse') end";
static void W112_TeleReportUnknownAction(DWORD action)
{
    char script[190];char*q=script;
    q=AppStr(q,"if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage('[Tele E] ABORT: unknown CTM state=0x");
    q=AppHex32(q,action);
    q=AppStr(q," (CTM 0xC observed with LMB); no pulse') end");*q=0;
    DebugChat(script);
}
static const char g_teleTooCloseChat[]="if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage('|cffffaa00[Tele E]|r aim at a different point (minimum 0.5 units away)') end";
/* Every E press gets one stage-specific report; never claim an
 * accepted teleport merely because the client sent a movement heartbeat. */
static const char g_teleBlockedChat[]="if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage('|cffffaa00[Tele E]|r blocked: cast/another movement module') end";
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
    if(!g_stepEnabled||!g_loginGuardReady||!Ptr(p)||
       (MovementCore_CoordFlags()&0x3Fu)||g_abCapGuardActive||
       LongPPActive()||LongPPInjecting()||
       *(volatile DWORD*)ADDR_CASTING_SPELLID||
       g_gatherActive||g_gatherLootWait)return 0u;
    return 1u;
}
static void W112_KeyTeleTick(BYTE *p,DWORD now)
{
    DWORD pressed=(GK()(W112_TELE_KEY_E)&(short)0x8000)?1u:0u;
    DWORD trigger=pressed&&!g_teleKeyWasDown;
    DWORD info,hitType,hitBefore,action;
    float px,py,pz,x,y,z,dx,dy,dz;
    g_teleKeyWasDown=pressed;
    if(!g_stepEnabled){g_telePending=0u;g_stepActive=0u;return;}
    if(g_telePending){
        /* A second E press aborts rather than applying a stale destination. */
        if(trigger){g_telePending=0u;g_stepActive=0u;DebugChat(g_teleAbortChat);return;}
        if(!W112_TeleAvailable(p)||
           !W112_TeleRangeValid(W112_TELE_CTM_ACTION,4u,0u)||
           (DWORD)(now-g_teleWaitSince)>W112_TELE_TIMEOUT_MS){
            g_telePending=0u;g_stepActive=0u;DebugChat(g_teleAbortChat);return;
        }
        action=*(volatile DWORD*)W112_TELE_CTM_ACTION;
        /* 0xC is observed with this LMB path, but is NOT treated as a
         * universal stop or walk enum. Any transition fails closed. */
        if(action!=W112_TELE_CTM_OBSERVED){
            g_telePending=0u;g_stepActive=0u;
            W112_TeleReportUnknownAction(action);return;
        }
        px=*(float*)(p+OFF_UNIT_X);py=*(float*)(p+OFF_UNIT_Y);
        pz=*(float*)(p+OFF_UNIT_Z);
        dx=px-g_teleStartX;dy=py-g_teleStartY;dz=pz-g_teleStartZ;
        if(!W112_Q_PosValid(px,py,pz)||dx*dx+dy*dy+dz*dz>W112_TELE_MAX_DRIFT_D2){
            g_telePending=0u;g_stepActive=0u;DebugChat(g_teleAbortChat);return;
        }
        /* Local movement flags are an additional safeguard against issuing
         * a pulse while the client is walking despite a stable position. */
        {DWORD *flags=MoveFlags(p);
         if(!flags||(*flags&0x3Fu)!=0u){
            g_telePending=0u;g_stepActive=0u;DebugChat(g_teleAbortChat);return;
         }
        }
        if((DWORD)(now-g_teleWaitLast)<W112_TELE_SETTLE_MS)return;
        /* Unlike a terrain hit, type-2 XYZ has unverified provenance.
         * Refresh after the stationary interval, require the cursor to still
         * be over an object, with a valid point near the original sample. */
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
        DebugChat(g_teleSentChat);
        return;
    }
    if(!trigger)return;
    if(W112_Q_ChatHasFocus()){DebugChat(g_teleChatFocusChat);return;}
    if(!W112_TeleAvailable(p)){DebugChat(g_teleBlockedChat);return;}
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
    /* No artificial horizontal range or vertical offset limit: retain only
     * finite-world-coordinate validation, type-1 terrain hit, ownership and
     * stationary-player guards. Native collision/server acceptance NOT proven
     * for long jumps, steep slopes, cross-continent or non-navigable terrain. */
    dx=x-px;dy=y-py;
    if(dx*dx+dy*dy<W112_TELE_MIN_D2){DebugChat(g_teleTooCloseChat);return;}
    /* 0xC was observed with LMB terrain hits; E must independently provide
     * the same passive CTM state and a type-1 cursor raycast.
     * Neither 0xC nor the old 0/3/4 values prove that native CTM is stopped.
     * Only the passive E + stable-state + stationary-player path may pulse.
     * Never issue native STOP=3 based on an unverified enum. */
    if(!W112_TeleRangeValid(W112_TELE_CTM_ACTION,4u,0u)){
        DebugChat(g_teleUnsupportedChat);return;
    }
    action=*(volatile DWORD*)W112_TELE_CTM_ACTION;
    if(action!=W112_TELE_CTM_OBSERVED){
        W112_TeleReportUnknownAction(action);return;
    }
    {DWORD *flags=MoveFlags(p);
     if(!flags||(*flags&0x3Fu)!=0u){
        DebugChat(g_teleAbortChat);return;
     }
    }
    g_teleDestX=x;g_teleDestY=y;g_teleDestZ=z;
    g_teleStartX=px;g_teleStartY=py;g_teleStartZ=pz;
    g_telePendingHitType=hitType;
    g_telePending=1u;g_stepActive=1u;g_teleWaitSince=now;g_teleWaitLast=now;
    DebugChat(g_teleStopChat);
}

static void __stdcall AltPriority_TimerProc(HWND w,UINT m,UINT_PTR id,DWORD tm)
{
    DWORD now,dur,gap,k7,k8,k9,kAlt,k10,k11,k12,paused;BYTE*p;
    (void)w;(void)m;(void)id;(void)tm;
    if(!GT()||!GK())return;
    now=GT()();
    p=LocalPlayer();
    W112_LoginGuardTick(p,now);
    if(!g_loginGuardReady){g_altPriorityPendingUntil=0u;g_stepActive=0u;g_telePending=0u;return;}
    PPBlacklistTick(now);
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
    if(p){
        if(!g_gatherReadyChat){g_gatherReadyChat=1u;DebugChat(g_ppChainOk?g_chatReady:g_chatChainBad);if(g_ppChainOk){DebugChat(g_autoPPEnabled?g_chatPPOn:g_chatPPOff);DebugChat(g_autoOpenEnabled?g_chatOpenOn:g_chatOpenOff);}}
        if(!CoordRearOwned()&&(!g_abCapGuardActive||g_gatherActive||g_gatherLootWait))
            GatherTick(p,now);
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
    if(g_mode==MODE_OFF||g_abCapGuardActive)return;

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
static W112_ControlSettingV1 g_controlSettings[7u+14u+5u];

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

    g_controlDescriptorReady=1u;
}

static int W112_CTL_STDCALL movement_control_get(w112_u32 id,W112_ControlValueV1*out)
{
    if(!out)return 0;
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
    return 0;
}

static int W112_CTL_STDCALL movement_control_set(w112_u32 id,const W112_ControlValueV1*value)
{
    DWORD now;
    BYTE*p;
    if(!value||value->u32>1u)return 0;
    now=GT()?GT()():0u;
    p=LocalPlayer();

    if(id==1u){
        g_gatherEnabled=value->u32;
        if(!g_gatherEnabled&&(g_gatherActive||g_gatherLootWait))GatherStop(p,now,"GUI_GATHER_DISABLED",1u,0u);
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
    "movementcore","MovementCore",0x00120000u,26u,g_controlSettings,
    movement_control_get,movement_control_set
};

W112_CTL_EXPORT const W112_ControlModuleV1 * W112_CTL_STDCALL W112_Control_GetModuleV1(void)
{
    init_control_descriptor();
    return &g_controlModule;
}

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
        return TRUE;
    }
    if(r==DLL_PROCESS_DETACH){
        AltPriority_Remove();
        g_coordRearUntil=0u;g_stepActive=0u;g_stepEnabled=0u;
        return W112_MovementCoreV20_DllMain(h,r,x);
    }
    return TRUE;
}