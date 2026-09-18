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
 * V24 WORK candidate: manual PP / LongPP / loot hook surfaces remain identical
 * to ec336. The first AutoLootPP packet is allowed through the proven path and
 * seeds the queue; only later legacy retries are suppressed. Mining priority
 * is automation-only and can never block manual Pick Pocket.
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

__declspec(dllexport) DWORD __stdcall MovementCore_GetVersion(void){return 0x00120400u;}
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