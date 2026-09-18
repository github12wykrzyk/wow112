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
 *
 * V22 WORK candidate (2026-09-18):
 *   - exact accepted AutoLootPP bytes remain untouched;
 *   - automatic PP scheduling moves into MovementCore, whose source/build path
 *     is known-good in the current stack;
 *   - foreign AutoLootPP PP sends only activate the scheduler and are suppressed;
 *   - fresh targets are scanned first, transient failures go to FIFO retry tail;
 *   - only one PP is in flight, preserving deterministic 5875 fail->GUID mapping;
 *   - loot-entry chain supplies the success event without rebuilding AutoLootPP.
 */

#define DllMain W112_MovementCoreV20_DllMain
#define MovementCore_GetVersion W112_MovementCoreV20_GetVersion
#include "WoWMovementCore_5875_v20_AUTOPP_REARONLY_HARDLOS3D_RETRY.c"
#undef MovementCore_GetVersion
#undef DllMain

static volatile DWORD g_altPriorityInstalled=0u;
static volatile DWORD g_altPriorityBlockCurrent=0u;
static volatile DWORD g_altPriorityStarts=0u;
static volatile DWORD g_altPriorityPPBlocks=0u;
static volatile DWORD g_altPriorityDirectPackets=0u;
static volatile DWORD g_altPriorityDirectRestores=0u;
static volatile DWORD g_altPriorityQuietBypasses=0u;
static volatile DWORD g_altPriorityForceDirect=0u;
/* clang-cl's inline-asm parser does not reliably bind an internal naked
 * function when referenced as `offset symbol`. Keep the V20 send-wrapper
 * address in a normal data symbol and jump through that instead. */
static DWORD g_altPriorityBaseSendWrapper=0u;

/* ---------------- V22 fresh-first AutoPP queue ---------------- */
#define PPQ_LOOT_ENTRY              0x005EB900u
#define PPQ_CREATURE_TYPE_FN        0x00605570u
#define PPQ_ATTACKABLE_FN           0x00606980u
#define PPQ_UNIT_AUX_OFF            0x0110u
#define PPQ_AUX_LEVEL_OFF           0x0070u
#define PPQ_SCAN_RANGE_SQ           90000.0f
#define PPQ_SCAN_MS                 75u
#define PPQ_MIN_SEND_GAP_MS         100u
#define PPQ_RESULT_TIMEOUT_MS       450u
#define PPQ_RETRY_DELAY_MS          100u
#define PPQ_MAX_ATTEMPTS            3u
#define PPQ_SEEN_CAP                512u
#define PPQ_RETRY_CAP               128u
#define PPQ_CREATURE_HUMANOID       7
#define PPQ_CREATURE_UNDEAD         6

typedef int (__thiscall *PPQCreatureType_t)(void*);
typedef int (__stdcall *PPQAttackable_t)(void*);

typedef struct PPQSeenSlot {
    DWORD lo,hi,obj,attempts;
    BYTE state,queued,pad0,pad1;
} PPQSeenSlot;

typedef struct PPQRetryItem {
    DWORD lo,hi,due;
} PPQRetryItem;

static PPQSeenSlot g_ppqSeen[PPQ_SEEN_CAP];
static PPQRetryItem g_ppqRetry[PPQ_RETRY_CAP];
static volatile DWORD g_ppqSupported=0u,g_ppqActive=0u,g_ppqInjecting=0u,g_ppqBlockCurrent=0u;
static volatile DWORD g_ppqInFlight=0u,g_ppqInFlightLo=0u,g_ppqInFlightHi=0u,g_ppqInFlightTick=0u;
static volatile DWORD g_ppqNextScan=0u,g_ppqLastSend=0u,g_ppqNextLootTarget=0u,g_ppqLootHookOk=0u;
static volatile DWORD g_ppqRetryHead=0u,g_ppqRetryTail=0u,g_ppqRetryCount=0u,g_ppqSeenCursor=0u;
static volatile DWORD g_ppqFreshSent=0u,g_ppqRetryQueued=0u,g_ppqRetrySent=0u,g_ppqRetryDropped=0u;
static volatile DWORD g_ppqForeignBlocked=0u,g_ppqSuccess=0u,g_ppqTimeouts=0u,g_ppqGenericFails=0u;

static DWORD PPQHash(DWORD lo,DWORD hi){DWORD h=lo*2654435761u;h^=hi*2246822519u;h^=h>>16;return h&(PPQ_SEEN_CAP-1u);}

static PPQSeenSlot* PPQSeenFind(DWORD lo,DWORD hi)
{
    DWORD i,h=PPQHash(lo,hi);
    for(i=0u;i<PPQ_SEEN_CAP;i++){
        PPQSeenSlot*s=&g_ppqSeen[(h+i)&(PPQ_SEEN_CAP-1u)];
        if(s->state==0u)return (PPQSeenSlot*)0;
        if(s->state==1u&&s->lo==lo&&s->hi==hi)return s;
    }
    return (PPQSeenSlot*)0;
}

static PPQSeenSlot* PPQSeenGet(DWORD lo,DWORD hi)
{
    DWORD i,h=PPQHash(lo,hi),firstT=0xFFFFFFFFu;
    for(i=0u;i<PPQ_SEEN_CAP;i++){
        DWORD k=(h+i)&(PPQ_SEEN_CAP-1u);PPQSeenSlot*s=&g_ppqSeen[k];
        if(s->state==1u&&s->lo==lo&&s->hi==hi)return s;
        if(s->state==2u&&firstT==0xFFFFFFFFu)firstT=k;
        if(s->state==0u){
            if(firstT!=0xFFFFFFFFu)s=&g_ppqSeen[firstT];
            s->lo=lo;s->hi=hi;s->obj=0u;s->attempts=0u;s->queued=0u;s->state=1u;return s;
        }
    }
    {
        PPQSeenSlot*s=&g_ppqSeen[g_ppqSeenCursor++&(PPQ_SEEN_CAP-1u)];
        s->lo=lo;s->hi=hi;s->obj=0u;s->attempts=0u;s->queued=0u;s->state=1u;return s;
    }
}

static void PPQSeenClear(PPQSeenSlot*s)
{
    if(!s)return;
    s->state=2u;s->queued=0u;s->lo=s->hi=s->obj=s->attempts=0u;
}

static DWORD PPQUnitLevel(BYTE*o)
{
    BYTE*a;if(!Ptr(o))return 0u;a=*(BYTE**)(o+PPQ_UNIT_AUX_OFF);return Ptr(a)?*(DWORD*)(a+PPQ_AUX_LEVEL_OFF):0u;
}

static float PPQDist2(BYTE*a,BYTE*b)
{
    float dx,dy,dz;if(!Ptr(a)||!Ptr(b))return PPQ_SCAN_RANGE_SQ+1.0f;
    dx=*(float*)(a+OFF_UNIT_X)-*(float*)(b+OFF_UNIT_X);
    dy=*(float*)(a+OFF_UNIT_Y)-*(float*)(b+OFF_UNIT_Y);
    dz=*(float*)(a+OFF_UNIT_Z)-*(float*)(b+OFF_UNIT_Z);
    return dx*dx+dy*dy+dz*dz;
}

static DWORD PPQEligible(BYTE*p,BYTE*o,DWORD now,float*outD2)
{
    DWORD*d,mask,lo,hi,lvl,plvl;int ct;float d2;
    (void)now;
    if(!Ptr(p)||!Ptr(o))return 0u;
    d=*(DWORD**)(o+OFF_OBJ_DESCRIPTOR_PTR);if(!Ptr(d))return 0u;
    mask=d[OBJECT_FIELD_TYPE_INDEX];
    if(!(mask&TYPEMASK_UNIT)||(mask&TYPEMASK_PLAYER)||d[UNIT_FIELD_HEALTH_INDEX]==0u)return 0u;
    lo=*(DWORD*)(o+OFF_OBJ_GUID_LOW);hi=*(DWORD*)(o+OFF_OBJ_GUID_HIGH);if((lo|hi)==0u||PPBlackFind(lo,hi)||PPQSeenFind(lo,hi))return 0u;
    ct=((PPQCreatureType_t)PPQ_CREATURE_TYPE_FN)((void*)o);
    if(ct!=PPQ_CREATURE_HUMANOID&&ct!=PPQ_CREATURE_UNDEAD)return 0u;
    if(!((PPQAttackable_t)PPQ_ATTACKABLE_FN)((void*)o))return 0u;
    plvl=PPQUnitLevel(p);lvl=PPQUnitLevel(o);if(lvl>=plvl+3u)return 0u;
    d2=PPQDist2(p,o);if(d2>PPQ_SCAN_RANGE_SQ)return 0u;
    if(outD2)*outD2=d2;return 1u;
}

static BYTE* PPQFindFresh(BYTE*p,DWORD now,DWORD*olo,DWORD*ohi,float*outD2)
{
    BYTE*m,*o,*best=0;DWORD i=0u;float bestD=PPQ_SCAN_RANGE_SQ+1.0f;
    if(olo)*olo=0u;if(ohi)*ohi=0u;if(outD2)*outD2=0.0f;
    m=*(BYTE**)ADDR_OBJMGR_GLOBAL;if(!Ptr(m)||!Ptr(p))return 0;
    o=*(BYTE**)(m+OFF_OM_FIRST_OBJECT);
    while(i++<4095u&&Ptr(o)){
        BYTE*n=*(BYTE**)(o+OFF_OBJ_NEXT);float d2=0.0f;
        if(PPQEligible(p,o,now,&d2)&&d2<bestD){best=o;bestD=d2;}
        if(n==o)break;o=n;
    }
    if(best){
        if(olo)*olo=*(DWORD*)(best+OFF_OBJ_GUID_LOW);
        if(ohi)*ohi=*(DWORD*)(best+OFF_OBJ_GUID_HIGH);
        if(outD2)*outD2=bestD;
    }
    return best;
}

static DWORD PPQPackGuid(BYTE*dst,DWORD lo,DWORD hi)
{
    BYTE b[8],mask=0u;DWORD i,n=1u;
    b[0]=(BYTE)lo;b[1]=(BYTE)(lo>>8);b[2]=(BYTE)(lo>>16);b[3]=(BYTE)(lo>>24);
    b[4]=(BYTE)hi;b[5]=(BYTE)(hi>>8);b[6]=(BYTE)(hi>>16);b[7]=(BYTE)(hi>>24);
    for(i=0u;i<8u;i++)if(b[i])mask|=(BYTE)(1u<<i);
    dst[0]=mask;for(i=0u;i<8u;i++)if(b[i])dst[n++]=b[i];return n;
}

static DWORD PPQRetryContains(DWORD lo,DWORD hi)
{
    DWORD i;for(i=0u;i<g_ppqRetryCount;i++){DWORD k=(g_ppqRetryHead+i)%PPQ_RETRY_CAP;if(g_ppqRetry[k].lo==lo&&g_ppqRetry[k].hi==hi)return 1u;}return 0u;
}

static void PPQRetryEnqueue(DWORD lo,DWORD hi,DWORD due)
{
    PPQSeenSlot*s=PPQSeenFind(lo,hi);
    if(!s||s->attempts>=PPQ_MAX_ATTEMPTS||s->queued||PPQRetryContains(lo,hi))return;
    if(g_ppqRetryCount>=PPQ_RETRY_CAP){++g_ppqRetryDropped;return;}
    g_ppqRetry[g_ppqRetryTail].lo=lo;g_ppqRetry[g_ppqRetryTail].hi=hi;g_ppqRetry[g_ppqRetryTail].due=due;
    g_ppqRetryTail=(g_ppqRetryTail+1u)%PPQ_RETRY_CAP;++g_ppqRetryCount;s->queued=1u;++g_ppqRetryQueued;
}

static DWORD PPQRetryPop(DWORD now,DWORD*olo,DWORD*ohi)
{
    DWORD n=g_ppqRetryCount,i;if(olo)*olo=0u;if(ohi)*ohi=0u;
    for(i=0u;i<n;i++){
        PPQRetryItem it=g_ppqRetry[g_ppqRetryHead];PPQSeenSlot*s;
        g_ppqRetryHead=(g_ppqRetryHead+1u)%PPQ_RETRY_CAP;--g_ppqRetryCount;
        s=PPQSeenFind(it.lo,it.hi);if(s)s->queued=0u;
        if((LONG)(now-it.due)>=0){if(olo)*olo=it.lo;if(ohi)*ohi=it.hi;return 1u;}
        if(g_ppqRetryCount<PPQ_RETRY_CAP){
            g_ppqRetry[g_ppqRetryTail]=it;g_ppqRetryTail=(g_ppqRetryTail+1u)%PPQ_RETRY_CAP;++g_ppqRetryCount;if(s)s->queued=1u;
        }
    }
    return 0u;
}

static void PPQPruneSeen(void)
{
    DWORD i;
    for(i=0u;i<PPQ_SEEN_CAP;i++)if(g_ppqSeen[i].state==1u){
        BYTE*o=ObjByGuid(g_ppqSeen[i].lo,g_ppqSeen[i].hi);DWORD*d=Ptr(o)?*(DWORD**)(o+OFF_OBJ_DESCRIPTOR_PTR):0;
        if(!Ptr(o)||!Ptr(d)||d[UNIT_FIELD_HEALTH_INDEX]==0u){PPSweepRemove(g_ppqSeen[i].lo,g_ppqSeen[i].hi);PPQSeenClear(&g_ppqSeen[i]);}
    }
}

static void PPQAccept(DWORD lo,DWORD hi,DWORD now)
{
    PPQSeenSlot*s=PPQSeenGet(lo,hi);BYTE*o=ObjByGuid(lo,hi);
    if(s){s->obj=(DWORD)o;if(s->attempts<0xFFFFFFFFu)++s->attempts;}
    g_ppqInFlight=1u;g_ppqInFlightLo=lo;g_ppqInFlightHi=hi;g_ppqInFlightTick=now;g_ppqLastSend=now;
}

static void PPQFinish(DWORD retry,DWORD now)
{
    DWORD lo=g_ppqInFlightLo,hi=g_ppqInFlightHi;
    if(!g_ppqInFlight)return;
    g_ppqInFlight=0u;g_ppqInFlightLo=g_ppqInFlightHi=g_ppqInFlightTick=0u;
    g_ppFailPendingAuto=0u;g_ppFailPendingSawActive=0u;PPHardRetryCancel();
    if(retry)PPQRetryEnqueue(lo,hi,now+PPQ_RETRY_DELAY_MS);
}

static void PPQProcessResults(DWORD now)
{
    DWORD ev=g_ppFailLogEvent;
    if(!g_ppqInFlight)return;
    if(ev&&g_ppFailLogLo==g_ppqInFlightLo&&g_ppFailLogHi==g_ppqInFlightHi){
        if(ev==3u){PPQFinish(1u,now);return;}
        if(ev==1u||ev==2u||ev==4u){PPQFinish(0u,now);return;}
    }
    if(!g_ppFailPendingAuto){
        ++g_ppqGenericFails;PPQFinish(1u,now);return;
    }
    if((DWORD)(now-g_ppqInFlightTick)>=PPQ_RESULT_TIMEOUT_MS){
        ++g_ppqTimeouts;PPQFinish(1u,now);
    }
}

static void __cdecl PPQ_OnLootEntry(void)
{
    DWORD now=GT()?GT()():0u;
    if(!g_ppqInFlight)return;
    ++g_ppqSuccess;PPQFinish(0u,now);
}

__declspec(naked) static void PPQ_LootWrapper(void)
{
    __asm {
        pushfd
        pushad
        call PPQ_OnLootEntry
        popad
        popfd
        mov eax,dword ptr [g_ppqNextLootTarget]
        jmp eax
    }
}

static DWORD PPQInstallLootHook(void)
{
    DWORD next;
    if(!g_ppChainOk||!g_ppFailHookOk)return 0u;
    next=DJump(PPQ_LOOT_ENTRY);if(!next||next==(DWORD)(LPVOID)&PPQ_LootWrapper)return 0u;
    g_ppqNextLootTarget=next;
    if(!PJump(PPQ_LOOT_ENTRY,(DWORD)(LPVOID)&PPQ_LootWrapper)){g_ppqNextLootTarget=0u;return 0u;}
    g_ppqLootHookOk=1u;g_ppqSupported=1u;return 1u;
}

static void PPQRemoveLootHook(void)
{
    if(g_ppqLootHookOk&&DJump(PPQ_LOOT_ENTRY)==(DWORD)(LPVOID)&PPQ_LootWrapper&&g_ppqNextLootTarget)PJump(PPQ_LOOT_ENTRY,g_ppqNextLootTarget);
    g_ppqLootHookOk=0u;g_ppqSupported=0u;g_ppqNextLootTarget=0u;g_ppqActive=0u;g_ppqInFlight=0u;
}

static void __cdecl PPQ_PreSend(DataStore5875*packet,DWORD returnAddr)
{
    BYTE*raw;DWORD op,spell,isDll;
    g_ppqBlockCurrent=0u;
    if(!g_ppqSupported||!packet||packet->size<8u||packet->size>MAX_PACKET_SIZE)return;
    raw=PacketRawBase(packet);if(!raw)return;op=*(DWORD*)raw;if(op!=0x12Eu)return;spell=*(DWORD*)(raw+4u);if(spell!=SPELL_PICK_POCKET)return;
    if(g_ppqInjecting)return;
    isDll=(returnAddr>=0x01000000u&&returnAddr<=0x7FFDFFFFu)?1u:0u;
    if(isDll){g_ppqActive=1u;g_ppqBlockCurrent=1u;++g_ppqForeignBlocked;}
}

static DWORD PPQSend(DWORD lo,DWORD hi,DWORD now,DWORD retry)
{
    BYTE raw[64];DataStore5875 p;DWORD n=0u;
    *(DWORD*)(raw+n)=0x012Eu;n+=4u;*(DWORD*)(raw+n)=SPELL_PICK_POCKET;n+=4u;*(WORD*)(raw+n)=0x0002u;n+=2u;n+=PPQPackGuid(raw+n,lo,hi);
    p.vtable=ADDR_DATASTORE_VTABLE;p.dataPtr=raw;p.backOffset=0u;p.capacity=64u;p.size=n;p.unk14=0u;
    g_ppqInjecting=1u;DirectClientSend(&p);g_ppqInjecting=0u;
    if(g_ppFailPendingAuto&&g_ppFailPendingLo==lo&&g_ppFailPendingHi==hi){
        PPQAccept(lo,hi,now);if(retry)++g_ppqRetrySent;else ++g_ppqFreshSent;return 1u;
    }
    return 0u;
}

static void PPQDispatch(DWORD now)
{
    BYTE*p,*o;DWORD lo=0u,hi=0u;float d2=0.0f;PPQSeenSlot*s;
    if(!g_ppqSupported||!g_ppqActive||!g_autoPPEnabled||g_ppqInFlight||g_ppFailPendingAuto)return;
    if(g_mode!=MODE_OFF||LongPPActive()||LongPPInjecting()||(*(DWORD*)ADDR_CASTING_SPELLID)==SPELL_PICK_POCKET)return;
    if(g_ppqLastSend&&(DWORD)(now-g_ppqLastSend)<PPQ_MIN_SEND_GAP_MS)return;
    if((LONG)(now-g_ppqNextScan)<0)return;g_ppqNextScan=now+PPQ_SCAN_MS;
    p=LocalPlayer();if(!Ptr(p)||!GatherHasStealth(p)||CurrentTargetIsPlayer()||MiningPriorityOwnsPP(now)||GatherLootOpen())return;
    PPQPruneSeen();
    o=PPQFindFresh(p,now,&lo,&hi,&d2);
    if(o){PPQSend(lo,hi,now,0u);return;}
    if(PPQRetryPop(now,&lo,&hi)){
        o=ObjByGuid(lo,hi);s=PPQSeenFind(lo,hi);
        if(!Ptr(o)||!s||s->attempts>=PPQ_MAX_ATTEMPTS)return;
        if(!PPQSend(lo,hi,now,1u))PPQRetryEnqueue(lo,hi,now+PPQ_RETRY_DELAY_MS);
    }
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
    if(g_mode!=MODE_LOCAL_STRONG||!packet||packet->size<8u||packet->size>MAX_PACKET_SIZE)return;
    raw=PacketRawBase(packet);if(!raw)return;
    op=*(DWORD*)raw;if(op!=0x12Eu)return;
    spell=*(DWORD*)(raw+4u);if(spell!=SPELL_PICK_POCKET)return;
    /* Manual LALT is an explicit user action and owns movement until it ends.
       Block both automatic and manual PP starts so a new LongPP transaction
       cannot repeatedly pause/starve the reset. Existing PP is allowed to
       finish and is handled by the timer below. */
    g_altPriorityBlockCurrent=1u;
    g_ppQuietUntil=0u;
    ++g_altPriorityPPBlocks;
}

static void __cdecl AltPriority_PreSend(DataStore5875*packet,DWORD returnAddr)
{
    PPQ_PreSend(packet,returnAddr);
    AltPriority_CheckPickPocket(packet);
}

__declspec(naked) static void AltPriority_SendWrapper(void)
{
    __asm {
        pushfd
        pushad
        push dword ptr [esp+36]
        push ecx
        call AltPriority_PreSend
        add  esp,8
        popad
        popfd
        cmp  dword ptr [g_ppqBlockCurrent],0
        jne  alt_pp_blocked
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
        pushfd
        pushad
        push ecx
        call NoFall_ProcessMovementPacket
        add  esp,4
        popad
        popfd

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

static void __stdcall AltPriority_TimerProc(HWND w,UINT m,UINT_PTR id,DWORD tm)
{
    DWORD now,dur,gap,k7,k8,k9,kAlt,k10,k11,k12,paused;BYTE*p;
    (void)w;(void)m;(void)id;(void)tm;
    if(!GT()||!GK())return;
    now=GT()();
    PPQProcessResults(now);
    PPBlacklistTick(now);
    FlushPendingPPLog();
    k7=(GK()(VK_F7)&(short)0x8000)?1u:0u;
    k8=(GK()(VK_F8)&(short)0x8000)?1u:0u;
    k9=(GK()(VK_F9)&(short)0x8000)?1u:0u;
    kAlt=(GK()(VK_LMENU)&(short)0x8000)?1u:0u;
    k10=(GK()(VK_F10)&(short)0x8000)?1u:0u;
    k11=(GK()(VK_F11)&(short)0x8000)?1u:0u;
    k12=(GK()(VK_F12)&(short)0x8000)?1u:0u;

    if(k7&&!g_key7){AltPriority_Stop(TRUE);if(g_gatherActive||g_gatherLootWait)GatherStop(LocalPlayer(),now,"F7_ABORT",1u,0u);}
    if(k8&&!g_key8)Start(MODE_LEGACY_FAST,now);
    if(k9&&!g_gatherKey9){g_gatherEnabled=g_gatherEnabled?0u:1u;GatherFileLog(g_gatherEnabled?"TOGGLE_ON":"TOGGLE_OFF",now,0u,0u,0u,0.0f,0u,0u);DebugChat(g_gatherEnabled?g_chatOn:g_chatOff);}
    if(kAlt&&!g_keyAlt)AltPriority_Start(now);
    if(k10&&!g_key10)Start(MODE_PURSUIT,now);
    if(k11&&!g_key11){g_autoPPEnabled=g_autoPPEnabled?0u:1u;DebugChat(g_autoPPEnabled?g_chatPPOn:g_chatPPOff);GatherFileLog(g_autoPPEnabled?"AUTOPP_TOGGLE_ON":"AUTOPP_TOGGLE_OFF",now,0u,0u,0u,0.0f,0u,0u);}
    if(k12&&!g_autoOpenKey12){g_autoOpenEnabled=g_autoOpenEnabled?0u:1u;DebugChat(g_autoOpenEnabled?g_chatOpenOn:g_chatOpenOff);GatherFileLog(g_autoOpenEnabled?"AUTOOPEN_TOGGLE_ON":"AUTOOPEN_TOGGLE_OFF",now,0u,0u,0u,0.0f,0u,0u);if(!g_autoOpenEnabled&&g_gatherActive&&g_gatherKind==3u)GatherStop(LocalPlayer(),now,"AUTOOPEN_DISABLED_ABORT",1u,0u);}
    g_key7=k7;g_key8=k8;g_gatherKey9=k9;g_keyAlt=kAlt;g_key10=k10;g_key11=k11;g_autoOpenKey12=k12;

    p=LocalPlayer();
    if(p){
        if(!g_gatherReadyChat){g_gatherReadyChat=1u;DebugChat(g_ppChainOk?g_chatReady:g_chatChainBad);if(g_ppChainOk){DebugChat(g_autoPPEnabled?g_chatPPOn:g_chatPPOff);DebugChat(g_autoOpenEnabled?g_chatOpenOn:g_chatOpenOff);}}
        GatherTick(p,now);
        PPQDispatch(now);
    }else if(g_gatherActive||g_gatherLootWait){
        g_gatherActive=0u;g_gatherLootWait=0u;g_gatherLootWaitUntil=0u;g_gatherLootStart=0u;
        g_gatherLootSeenOpen=0u;g_gatherLootOpenLogged=0u;g_gatherSawCast=0u;g_gatherCastSeenLogged=0u;
        g_gatherStealthPending=0u;g_gatherSpoof=0u;
        GatherFileLog("WORLD_LOST_ABORT",now,g_gatherEntry,g_gatherTargetLo,g_gatherTargetHi,g_gatherDistSq,g_gatherAttempts,0u);
    }
    if(g_mode==MODE_OFF)return;

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
    PPQInstallLootHook();
    g_altPriorityInstalled=1u;
    GatherFileLog("ALT_PRIORITY_READY",GT()?GT()():0u,0u,0u,0u,0.0f,0u,0x00000015u);
    GatherFileLog(g_ppqSupported?"AUTOPP_QUEUE_READY":"AUTOPP_QUEUE_DISABLED",GT()?GT()():0u,0u,0u,0u,0.0f,0u,g_ppqNextLootTarget);
    return TRUE;
}

static void AltPriority_Remove(void)
{
    PPQRemoveLootHook();
    if(g_timerId&&KT())KT()((HWND)0,(UINT_PTR)g_timerId);
    g_timerId=0u;
    if(g_ppChainOk&&DJump(ADDR_CLIENT_SEND)==(DWORD)(LPVOID)&AltPriority_SendWrapper&&g_altPriorityBaseSendWrapper)PJump(ADDR_CLIENT_SEND,g_altPriorityBaseSendWrapper);
    if(DCall(ADDR_MOVE_SEND_CALL)==(DWORD)(LPVOID)&AltPriority_MoveWrapper)PCall(ADDR_MOVE_SEND_CALL,(DWORD)(LPVOID)&MovementCore_MoveWrapper);
    g_altPriorityInstalled=0u;
    g_altPriorityBaseSendWrapper=0u;
}

__declspec(dllexport) DWORD __stdcall MovementCore_GetVersion(void){return 0x00120200u;}
__declspec(dllexport) DWORD __stdcall AutoPPQueue_GetSupported(void){return g_ppqSupported;}
__declspec(dllexport) DWORD __stdcall AutoPPQueue_GetActive(void){return g_ppqActive;}
__declspec(dllexport) DWORD __stdcall AutoPPQueue_GetInFlight(void){return g_ppqInFlight;}
__declspec(dllexport) DWORD __stdcall AutoPPQueue_GetFreshSent(void){return g_ppqFreshSent;}
__declspec(dllexport) DWORD __stdcall AutoPPQueue_GetRetryQueued(void){return g_ppqRetryQueued;}
__declspec(dllexport) DWORD __stdcall AutoPPQueue_GetRetrySent(void){return g_ppqRetrySent;}
__declspec(dllexport) DWORD __stdcall AutoPPQueue_GetRetryDepth(void){return g_ppqRetryCount;}
__declspec(dllexport) DWORD __stdcall AutoPPQueue_GetForeignBlocked(void){return g_ppqForeignBlocked;}
__declspec(dllexport) DWORD __stdcall AutoPPQueue_GetSuccess(void){return g_ppqSuccess;}
__declspec(dllexport) DWORD __stdcall AutoPPQueue_GetTimeouts(void){return g_ppqTimeouts;}
__declspec(dllexport) DWORD __stdcall MovementCore_GetAltPriorityInstalled(void){return g_altPriorityInstalled;}
__declspec(dllexport) DWORD __stdcall MovementCore_GetAltPriorityStarts(void){return g_altPriorityStarts;}
__declspec(dllexport) DWORD __stdcall MovementCore_GetAltPriorityPPBlocks(void){return g_altPriorityPPBlocks;}
__declspec(dllexport) DWORD __stdcall MovementCore_GetAltPriorityDirectPackets(void){return g_altPriorityDirectPackets;}
__declspec(dllexport) DWORD __stdcall MovementCore_GetAltPriorityDirectRestores(void){return g_altPriorityDirectRestores;}
__declspec(dllexport) DWORD __stdcall MovementCore_GetAltPriorityQuietBypasses(void){return g_altPriorityQuietBypasses;}

BOOL __stdcall DllMain(HINSTANCE h,DWORD r,LPVOID x)
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
        return W112_MovementCoreV20_DllMain(h,r,x);
    }
    return TRUE;
}