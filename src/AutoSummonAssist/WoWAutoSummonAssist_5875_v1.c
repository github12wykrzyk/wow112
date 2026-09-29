/*
 * WoWAutoSummonAssist 5875 v13 - payer-first gold trade + native reactive AFK recovery.
 * World of Warcraft 1.12.1 build 5875, Windows x86 ONLY.
 *
 * Detection:
 * - canonical Vanilla Summoning Portal entry 36727, OR
 * - GAMEOBJECT_TYPE_ID == 18 (ritual), read from the verified 1.12 update
 *   field layout. The type fallback supports servers that clone the portal
 *   template under a custom entry while preserving ritual semantics.
 *
 * Interaction:
 * - native 5875 GameObject right-click (same primitive as AutoFlag/Gather);
 * - physical 5.5 yd local gate;
 * - up to 8 retries / GUID, 120 ms apart;
 * - retries stop while the local player has native cast/channel state.
 *
 * Diagnostics:
 * - W112_CONTROL_API_V1 exposes scanner heartbeat, candidate entry/type/GUID,
 *   distance, retry counters and the nearest GameObject within 12 yd.
 * - no movement/position spoof, target changes, hooks, packet injection.
 *
 * Background payment:
 * - stock 1.12 TradeFrame is authoritative for an open trade;
 * - compatibility fallback handles a custom-server TRADE popup via BeginTrade();
 * - AcceptTrade() is called only after the paying player has accepted first,
 *   with a positive target-gold offer while this client contributes no money/items;
 * - one local AcceptTrade() call is allowed per payer-accept cycle (no accept spam).
 */
#if !defined(_M_IX86) && !defined(__i386__)
#error WoWAutoSummonAssist requires 32-bit x86.
#endif

#include "../common/W112ControlAPI.h"

#if defined(_MSC_VER)
#define STDCALL __stdcall
#define FASTCALL __fastcall
#define DLLEXPORT __declspec(dllexport)
#pragma comment(linker, "/EXPORT:W112_Control_GetModuleV1=_W112_Control_GetModuleV1@0")
#pragma comment(linker, "/EXPORT:AutoSummonAssist_GetStatus=_AutoSummonAssist_GetStatus@0")
#pragma comment(linker, "/EXPORT:AutoSummonAssist_GetAttempts=_AutoSummonAssist_GetAttempts@0")
#else
#define STDCALL __attribute__((stdcall))
#define FASTCALL __attribute__((fastcall))
#define DLLEXPORT __attribute__((dllexport))
#endif

typedef unsigned char u8;
typedef unsigned int u32;
typedef unsigned long long u64;
typedef u32 ptr32;
typedef void *HWND32;
typedef u32 UINT32;
typedef u32 UINT_PTR32;
typedef int BOOL32;

typedef void (STDCALL *TimerProc32)(HWND32,UINT32,UINT_PTR32,u32);
typedef UINT_PTR32 (STDCALL *SetTimerFn)(HWND32,UINT_PTR32,UINT32,TimerProc32);
typedef BOOL32 (STDCALL *KillTimerFn)(HWND32,UINT_PTR32);
typedef u32 (FASTCALL *GetObjectByGuidFn)(u64);
typedef BOOL32 (FASTCALL *FrameScriptExecuteFn)(const char*,const char*);
typedef const char* (FASTCALL *FrameScriptGetTextFn)(const char*,int,u32);
typedef void (__thiscall *RightClickObjectFn)(void*,int);

#define WOW_OBJMGR                  0x00B41414u
#define WOW_GET_OBJECT_BY_GUID      0x00464870u
#define WOW_ON_RIGHT_CLICK_OBJECT   0x005F8660u
#define WOW_FRAMESCRIPT_GETTEXT     0x00703BF0u
#define WOW_FRAMESCRIPT_EXECUTE     0x00704CD0u
#define WOW_IAT_SETTIMER            0x007FF4F4u
#define WOW_IAT_KILLTIMER           0x007FF4F8u

#define OM_FIRST_OBJECT             0x00ACu
#define OM_LOCAL_GUID_LO            0x00C0u
#define OM_LOCAL_GUID_HI            0x00C4u
#define OBJ_DESCRIPTOR_PTR          0x0008u
#define OBJ_TYPE_ID                 0x0014u
#define OBJ_GUID_LO                 0x0030u
#define OBJ_GUID_HI                 0x0034u
#define OBJ_NEXT                    0x003Cu
#define PLAYER_X                    0x09B8u
#define PLAYER_Y                    0x09BCu
#define PLAYER_Z                    0x09C0u
#define UNIT_CAST_OFFSET            0x0C8Cu
#define UNIT_CHANNEL_INDEX          0x0090u
#define CGPLAYER_INFO_PTR           0x0E68u
#define CGPLAYER_INFO_FLAGS         0x0008u
#define PLAYER_FLAG_AFK             0x02u

#define OBJECT_FIELD_TYPE_INDEX     0x0002u
#define OBJECT_FIELD_ENTRY_INDEX    0x0003u
#define TYPEMASK_GAMEOBJECT         0x00000020u
#define TYPEID_GAMEOBJECT           5u

/* Vanilla 1.12 GameObject update-field indices.
 * OBJECT_END is 6 DWORDs; TYPE_ID is OBJECT_END + 0x3C bytes => index 0x15. */
#define GO_X_INDEX                  0x000Fu
#define GO_Y_INDEX                  0x0010u
#define GO_Z_INDEX                  0x0011u
#define GO_TYPE_ID_INDEX            0x0015u

#define SUMMONING_PORTAL_ENTRY      36727u
#define GAMEOBJECT_TYPE_RITUAL      18u

#define TIMER_MS                    25u
#define WORLD_GRACE_MS              500u
#define RETRY_GAP_MS                120u
#define MAX_ATTEMPTS_PER_GUID       8u
#define INTERACT_RANGE_SQ           (5.50f*5.50f)
#define DEBUG_NEAR_RANGE_SQ         (12.0f*12.0f)
#define ANTI_AFK_POLL_MS            2000u
#define ANTI_AFK_STAND_SETTLE_MS     500u
#define ANTI_AFK_VERIFY_MS           1000u
#define ANTI_AFK_RETRY_MS            3000u
#define ANTI_AFK_DEFER_RECHECK_MS   1000u
#define ANTI_AFK_SLASH_REPAIR_MS    3000u

#define ANTI_AFK_PHASE_IDLE            0u
#define ANTI_AFK_PHASE_STAND_SETTLE    1u
#define ANTI_AFK_PHASE_VERIFY          2u
#define ANTI_AFK_PHASE_RETRY_WAIT      3u
#define TRADE_POLL_MS               100u

#define STATUS_DETACHED             0u
#define STATUS_WAIT_WORLD           1u
#define STATUS_WORLD_GRACE          2u
#define STATUS_ACTIVE               3u
#define STATUS_DISABLED             4u
#define STATUS_BUILD_MISMATCH       5u
#define STATUS_NO_TIMER             6u
#define STATUS_CAST_OR_CHANNEL      7u

#define MATCH_NONE                  0u
#define MATCH_ENTRY                 1u
#define MATCH_RITUAL_TYPE           2u
#define MATCH_ENTRY_AND_TYPE        3u

#define GATE_NONE                   0u
#define GATE_FIRST_NATIVE_CALL      1u
#define GATE_RETRY_NATIVE_CALL      2u
#define GATE_BUSY_AFTER_FIRST       3u
#define GATE_RETRY_GAP              4u
#define GATE_MAX_ATTEMPTS           5u

static volatile UINT_PTR32 g_timer = 0u;
static volatile u32 g_status = STATUS_DETACHED;
static volatile u32 g_enabled = 1u;
static volatile u32 g_heartbeat = 0u;
static volatile u32 g_scanTicks = 0u;
static volatile u32 g_candidatePresent = 0u;
static volatile u32 g_matchSource = MATCH_NONE;
static volatile u32 g_candidateEntry = 0u;
static volatile u32 g_candidateType = 0u;
static volatile u32 g_candidateDistance100 = 0u;
static volatile u32 g_candidateGuidLo = 0u;
static volatile u32 g_candidateGuidHi = 0u;
static volatile u32 g_attemptCount = 0u; /* PRE-CALL count */
static volatile u32 g_postCallCount = 0u; /* native call returned */
static volatile u32 g_gateReason = GATE_NONE;
static volatile u32 g_busyRaw = 0u;
static volatile u32 g_nearbyGoCount = 0u;
static volatile u32 g_nearestEntry = 0u;
static volatile u32 g_nearestType = 0u;
static volatile u32 g_nearestDistance100 = 0u;
static volatile u32 g_antiAfkEnabled = 1u;
static volatile u32 g_antiAfkSecondsLeft = 0u;
static volatile u32 g_antiAfkActions = 0u;
static volatile u32 g_antiAfkChannelDefers = 0u;
static volatile u32 g_antiAfkLastAction = 0u; /* 0 none, 1 stand, 2 Demon Armor, 3 /say fallback */
static volatile u32 g_antiAfkDetected = 0u;
static volatile u32 g_antiAfkRecoveries = 0u;
static volatile u32 g_tradeOpen = 0u;
static volatile u32 g_tradeOfferCopper = 0u;
static volatile u32 g_tradeAcceptAttempts = 0u;
static volatile u32 g_tradeTargetAccepted = 0u;

static u32 g_antiAfkNextAt = 0u;
static u32 g_antiAfkDeferCheckAt = 0u;
static u32 g_antiAfkPhase = ANTI_AFK_PHASE_IDLE;
static u32 g_antiAfkKnownArmor = 0u;
static u32 g_antiAfkSlashInstallAt = 0u;
static volatile u32 g_antiAfkSlashFeedback = 0u;
static volatile u32 g_antiAfkSlashCommands = 0u;
static u32 g_lastTradePoll = 0u;

static u32 g_mgr = 0u, g_lo = 0u, g_hi = 0u, g_readyAt = 0u;
static u32 g_portalLo = 0u, g_portalHi = 0u;
static u32 g_lastClick = 0u, g_portalAttempts = 0u, g_announced = 0u;

static W112_ControlSettingV1 g_settings[31];
static u32 g_descriptorReady = 0u;

int _fltused = 0;

static u32 read32(u32 addr) { return *(volatile u32*)(ptr32)addr; }
static float readFloat(u32 addr) { return *(volatile float*)(ptr32)addr; }
static int ptrOk(u32 p) { return p >= 0x00010000u && p <= 0x7FFE0000u && !(p & 3u); }

static u32 parseDecimalU32(const char *s)
{
    u32 value=0u;
    if(!s) return 0u;
    while(*s>='0' && *s<='9') {
        u32 digit=(u32)(*s-'0');
        if(value>429496729u || (value==429496729u && digit>5u)) return 0xFFFFFFFFu;
        value=value*10u+digit;
        ++s;
    }
    return value;
}

static int finiteCoord(float v)
{
    union { float f; u32 u; } x;
    x.f = v;
    return (x.u & 0x7F800000u) != 0x7F800000u && v > -200000.0f && v < 200000.0f;
}

static int validPos(float x,float y,float z)
{
    return finiteCoord(x) && finiteCoord(y) && finiteCoord(z);
}

static u32 distance100(float d2)
{
    float x;
    u32 i;
    if(!(d2>0.0f)) return 0u;
    x=d2>1.0f?d2:1.0f;
    for(i=0u;i<6u;i++) x=0.5f*(x+d2/x);
    if(x>10000.0f) x=10000.0f;
    return (u32)(x*100.0f+0.5f);
}

static void clearCandidate(void)
{
    g_candidatePresent=0u;
    g_matchSource=MATCH_NONE;
    g_candidateEntry=0u;
    g_candidateType=0u;
    g_candidateDistance100=0u;
    g_candidateGuidLo=0u;
    g_candidateGuidHi=0u;
}

static void resetPortal(void)
{
    g_portalLo=0u;
    g_portalHi=0u;
    g_lastClick=0u;
    g_portalAttempts=0u;
    g_announced=0u;
    g_gateReason=GATE_NONE;
    clearCandidate();
}

static void resetWorld(void)
{
    g_mgr=0u;
    g_lo=0u;
    g_hi=0u;
    g_readyAt=0u;
    g_antiAfkSlashInstallAt=0u;
    g_antiAfkNextAt=0u;
    g_antiAfkDeferCheckAt=0u;
    g_antiAfkPhase=ANTI_AFK_PHASE_IDLE;
    g_antiAfkKnownArmor=0u;
    g_antiAfkDetected=0u;
    g_antiAfkSecondsLeft=0u;
    g_lastTradePoll=0u;
    g_tradeOpen=0u;
    g_tradeOfferCopper=0u;
    g_tradeTargetAccepted=0u;
    resetPortal();
    g_nearbyGoCount=0u;
    g_nearestEntry=0u;
    g_nearestType=0u;
    g_nearestDistance100=0u;
}

static int buildGuard(void)
{
    static const u8 sig[] = {
        0x55,0x8B,0xEC,0x8B,0x45,0x08,0x8B,0x4D,0x0C,0x8B,0xD0,0x0B,0xD1
    };
    u32 i;
    const volatile u8 *p=(const volatile u8*)(ptr32)WOW_GET_OBJECT_BY_GUID;
    for(i=0u;i<(u32)sizeof(sig);i++) if(p[i]!=sig[i]) return 0;
    p=(const volatile u8*)(ptr32)WOW_ON_RIGHT_CLICK_OBJECT;
    if((p[0]==0u && p[1]==0u) || (p[0]==0xCCu && p[1]==0xCCu)) return 0;
    /* FrameScript_Execute/GetText are exact 5875 addresses also used by the
     * proven MovementCore lineage. Do not impose a guessed prologue here. */
    return 1;
}

static void announcePortal(void)
{
    static const char msg[] =
        "if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage("
        "'|cff66ccff[AutoSummon]|r Ritual candidate detected - helping.') end";
    ((FrameScriptExecuteFn)(ptr32)WOW_FRAMESCRIPT_EXECUTE)(msg,"AutoSummonAssist");
}

static u32 localPlayer(u32 now)
{
    u32 mgr=read32(WOW_OBJMGR),lo,hi,obj;
    u64 guid;

    if(!ptrOk(mgr)) {
        resetWorld();
        return 0u;
    }

    lo=read32(mgr+OM_LOCAL_GUID_LO);
    hi=read32(mgr+OM_LOCAL_GUID_HI);
    if((!lo&&!hi) || !ptrOk(read32(mgr+OM_FIRST_OBJECT))) {
        resetWorld();
        return 0u;
    }

    if(mgr!=g_mgr || lo!=g_lo || hi!=g_hi) {
        resetWorld();
        g_mgr=mgr;
        g_lo=lo;
        g_hi=hi;
        g_readyAt=now+WORLD_GRACE_MS;
        return 0u;
    }

    if((int)(now-g_readyAt)<0) return 0u;

    guid=((u64)hi<<32) | (u64)lo;
    obj=((GetObjectByGuidFn)(ptr32)WOW_GET_OBJECT_BY_GUID)(guid);
    if(!ptrOk(obj) ||
       read32(obj+OBJ_GUID_LO)!=lo ||
       read32(obj+OBJ_GUID_HI)!=hi) return 0u;
    if(read32(obj+OBJ_TYPE_ID)!=4u) return 0u;
    return obj;
}

static int playerBusy(u32 player)
{
    u32 desc;
    if(!ptrOk(player)) return 1;
    desc=read32(player+OBJ_DESCRIPTOR_PTR);
    if(ptrOk(desc) && read32(desc+4u*UNIT_CHANNEL_INDEX)!=0u) return 1;
    if(read32(player+UNIT_CAST_OFFSET)!=0u) return 1;
    return 0;
}

/* Reactive Anti-AFK for Vanilla 1.12.1.
 * Poll UnitIsAFK("player") every ~2s. Normal play causes no heartbeat action.
 * On a real AFK flag: wait out any cast/channel, force a deterministic stand,
 * wait 500ms, then (only if AFK persists) cast Demon Armor when known or use
 * one-character SAY as fallback. Verify the flag and retry after 3s if needed.
 * Everything executes in-process on the existing UI timer: no OS input/focus.
 *
 * Vanilla API evidence:
 * - UnitIsAFK / PLAYER_FLAGS_CHANGED: MikeBeloborodov/VanillaWowApi (1.12.1)
 * - DoEmote("STAND") / legacy SitOrStand: pre-2.1 player script API. */
static void antiAfkSetNext(u32 now,u32 delay)
{
    g_antiAfkNextAt=now+delay;
    g_antiAfkSecondsLeft=(delay+999u)/1000u;
}

static void antiAfkResetRuntime(void)
{
    g_antiAfkNextAt=0u;
    g_antiAfkDeferCheckAt=0u;
    g_antiAfkPhase=ANTI_AFK_PHASE_IDLE;
    g_antiAfkKnownArmor=0u;
    g_antiAfkDetected=0u;
    g_antiAfkSecondsLeft=0u;
}

static void antiAfkSetEnabled(u32 enabled)
{
    g_antiAfkEnabled=enabled?1u:0u;
    antiAfkResetRuntime();
}

static int antiAfkCmdIs(const char *s,const char *word)
{
    if(!s||!word) return 0;
    while(*s&&*word&&*s==*word){++s;++word;}
    return *s==0&&*word==0;
}

static void antiAfkInstallSlash(u32 now)
{
    static const char initScript[]=
        "if W112_ANTIAFK_CMD==nil then W112_ANTIAFK_CMD='' end;"
        "SLASH_W112ANTIAFK1='/antiafk';"
        "SlashCmdList['W112ANTIAFK']=function(msg) "
        "local c=string.lower(msg or ''); "
        "if string.gsub then c=string.gsub(c,'^%s*(.-)%s*$','%1') end; "
        "if c=='' then c='status' end; "
        "W112_ANTIAFK_CMD=c "
        "end;"
        "if hash_SlashCmdList then "
        "hash_SlashCmdList['/ANTIAFK']=SlashCmdList['W112ANTIAFK'] "
        "end;"
        "if ChatFrame_ImportAllListsToHash then ChatFrame_ImportAllListsToHash() end";

    if(g_antiAfkSlashInstallAt &&
       (u32)(now-g_antiAfkSlashInstallAt)<ANTI_AFK_SLASH_REPAIR_MS) return;

    ((FrameScriptExecuteFn)(ptr32)WOW_FRAMESCRIPT_EXECUTE)(initScript,"AutoSummonAssist");
    g_antiAfkSlashInstallAt=now;
}

static void antiAfkPollSlash(void)
{
    static const char clearScript[]="W112_ANTIAFK_CMD=''";
    const char *cmd=((FrameScriptGetTextFn)(ptr32)WOW_FRAMESCRIPT_GETTEXT)(
        "W112_ANTIAFK_CMD",-1,0u);
    u32 feedback=0u;

    if(!cmd||!cmd[0]) return;

    if(antiAfkCmdIs(cmd,"on")){
        antiAfkSetEnabled(1u);
        feedback=1u;
    } else if(antiAfkCmdIs(cmd,"off")){
        antiAfkSetEnabled(0u);
        feedback=1u;
    } else if(antiAfkCmdIs(cmd,"toggle")){
        antiAfkSetEnabled(g_antiAfkEnabled?0u:1u);
        feedback=1u;
    } else if(antiAfkCmdIs(cmd,"status")){
        feedback=1u;
    } else {
        feedback=2u;
    }

    ++g_antiAfkSlashCommands;
    g_antiAfkSlashFeedback=feedback;
    ((FrameScriptExecuteFn)(ptr32)WOW_FRAMESCRIPT_EXECUTE)(clearScript,"AutoSummonAssist");
}

static void antiAfkFlushSlashFeedback(void)
{
    static const char onMsg[]=
        "if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage("
        "'|cff55ff55[Anti-AFK]|r ON - reactive AFK watch: stand -> Demon Armor -> /say fallback') end";
    static const char offMsg[]=
        "if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage("
        "'|cffff7777[Anti-AFK]|r OFF') end";
    static const char usageMsg[]=
        "if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage("
        "'|cffffcc00[Anti-AFK]|r /antiafk on | off | toggle | status') end";
    u32 feedback=g_antiAfkSlashFeedback;

    if(!feedback) return;
    g_antiAfkSlashFeedback=0u;
    if(feedback==2u)
        ((FrameScriptExecuteFn)(ptr32)WOW_FRAMESCRIPT_EXECUTE)(usageMsg,"AutoSummonAssist");
    else if(g_antiAfkEnabled)
        ((FrameScriptExecuteFn)(ptr32)WOW_FRAMESCRIPT_EXECUTE)(onMsg,"AutoSummonAssist");
    else
        ((FrameScriptExecuteFn)(ptr32)WOW_FRAMESCRIPT_EXECUTE)(offMsg,"AutoSummonAssist");
}

static int antiAfkQueryAfk(u32 player)
{
    u32 info;
    u8 flags;

    /* Exact Vanilla 1.12 CGPlayer path. The local player object is already
     * validated as TYPEID_PLAYER by localPlayer(); +0xE68 is therefore safe
     * to treat as the CGPlayer-side info pointer. Its byte +0x08 carries
     * PLAYER_FLAGS; bit 0x02 is AFK. This is the same client-side state used
     * for the visible <AFK> marker, and avoids the false-negative Lua
     * UnitIsAFK("player") behavior observed in live testing. */
    if(!ptrOk(player) || read32(player+OBJ_TYPE_ID)!=4u) return 0;
    info=read32(player+CGPLAYER_INFO_PTR);
    if(!ptrOk(info)) return 0;
    flags=*(volatile u8*)(ptr32)(info+CGPLAYER_INFO_FLAGS);
    return (flags&PLAYER_FLAG_AFK)!=0u;
}

static void antiAfkMarkRecovered(u32 now)
{
    if(g_antiAfkDetected) ++g_antiAfkRecoveries;
    g_antiAfkDetected=0u;
    g_antiAfkPhase=ANTI_AFK_PHASE_IDLE;
    g_antiAfkKnownArmor=0u;
    g_antiAfkDeferCheckAt=0u;
    antiAfkSetNext(now,ANTI_AFK_POLL_MS);
}

static void antiAfkStandAndProbeArmor(u32 now)
{
    static const char standScript[]=
        "W112_ANTIAFK_KNOWS_ARMOR='0';"
        "if type(DoEmote)=='function' then DoEmote('STAND') "
        "elseif type(SitOrStand)=='function' then SitOrStand() end;"
        "if type(GetSpellName)=='function' and BOOKTYPE_SPELL then "
        "local i;for i=1,512 do "
        "local n=GetSpellName(i,BOOKTYPE_SPELL);"
        "if not n then break end;"
        "if n=='Demon Armor' then W112_ANTIAFK_KNOWS_ARMOR='1';break end "
        "end end";
    const char *known;

    ((FrameScriptExecuteFn)(ptr32)WOW_FRAMESCRIPT_EXECUTE)(standScript,"AutoSummonAssist");
    known=((FrameScriptGetTextFn)(ptr32)WOW_FRAMESCRIPT_GETTEXT)(
        "W112_ANTIAFK_KNOWS_ARMOR",-1,0u);
    g_antiAfkKnownArmor=(known&&known[0]=='1'&&known[1]==0)?1u:0u;
    g_antiAfkLastAction=1u;
    ++g_antiAfkActions;
    g_antiAfkPhase=ANTI_AFK_PHASE_STAND_SETTLE;
    antiAfkSetNext(now,ANTI_AFK_STAND_SETTLE_MS);
}

static void antiAfkDoActivity(u32 now)
{
    static const char armorScript[]=
        "if type(CastSpellByName)=='function' then CastSpellByName('Demon Armor') end";
    static const char sayScript[]=
        "if type(SendChatMessage)=='function' then SendChatMessage('.','SAY') end";

    if(g_antiAfkKnownArmor){
        ((FrameScriptExecuteFn)(ptr32)WOW_FRAMESCRIPT_EXECUTE)(armorScript,"AutoSummonAssist");
        g_antiAfkLastAction=2u;
    } else {
        ((FrameScriptExecuteFn)(ptr32)WOW_FRAMESCRIPT_EXECUTE)(sayScript,"AutoSummonAssist");
        g_antiAfkLastAction=3u;
    }
    ++g_antiAfkActions;
    g_antiAfkPhase=ANTI_AFK_PHASE_VERIFY;
    antiAfkSetNext(now,ANTI_AFK_VERIFY_MS);
}

static void antiAfkTick(u32 player,u32 now)
{
    int afk;

    if(!g_antiAfkEnabled){
        antiAfkResetRuntime();
        return;
    }

    if(!g_antiAfkNextAt){
        antiAfkSetNext(now,0u);
    } else if((int)(now-g_antiAfkNextAt)<0){
        g_antiAfkSecondsLeft=(u32)(g_antiAfkNextAt-now+999u)/1000u;
        return;
    }

    g_antiAfkSecondsLeft=0u;
    afk=antiAfkQueryAfk(player);

    if(!afk){
        antiAfkMarkRecovered(now);
        return;
    }

    g_antiAfkDetected=1u;

    if(playerBusy(player)){
        if(!g_antiAfkDeferCheckAt||(int)(now-g_antiAfkDeferCheckAt)>=0){
            ++g_antiAfkChannelDefers;
            g_antiAfkDeferCheckAt=now+ANTI_AFK_DEFER_RECHECK_MS;
        }
        antiAfkSetNext(now,ANTI_AFK_DEFER_RECHECK_MS);
        return;
    }

    g_antiAfkDeferCheckAt=0u;

    if(g_antiAfkPhase==ANTI_AFK_PHASE_IDLE ||
       g_antiAfkPhase==ANTI_AFK_PHASE_RETRY_WAIT){
        antiAfkStandAndProbeArmor(now);
        return;
    }

    if(g_antiAfkPhase==ANTI_AFK_PHASE_STAND_SETTLE){
        antiAfkDoActivity(now);
        return;
    }

    if(g_antiAfkPhase==ANTI_AFK_PHASE_VERIFY){
        g_antiAfkPhase=ANTI_AFK_PHASE_RETRY_WAIT;
        antiAfkSetNext(now,ANTI_AFK_RETRY_MS);
        return;
    }

    g_antiAfkPhase=ANTI_AFK_PHASE_IDLE;
    antiAfkSetNext(now,ANTI_AFK_POLL_MS);
}

/* Background trade handling runs on WoW's own UI-thread timer. Vanilla 1.12
 * normally opens TradeFrame directly for an allowed incoming trade, so
 * TradeFrame visibility is the primary signal. The TRADE popup path is retained
 * only as a compatibility fallback for custom servers. */
static void pollAndMaybeAcceptGold(u32 now)
{
    static const char script[] =
        "W112_AUTOGOLD_OPEN='0';"
        "W112_AUTOGOLD_OFFER='0';"
        "W112_AUTOGOLD_TARGET_ACCEPTED='0';"
        "W112_AUTOGOLD_ACCEPTS=W112_AUTOGOLD_ACCEPTS or 0;"
        "local popup=nil;"
        "if type(StaticPopup_Visible)=='function' then popup=StaticPopup_Visible('TRADE') end;"
        "if not popup and type(getglobal)=='function' then "
        "local j;for j=1,4 do local f=getglobal('StaticPopup'..j);"
        "if f and f.which=='TRADE' and f.IsVisible and f:IsVisible() then popup=f;break end end "
        "end;"
        "if popup and type(BeginTrade)=='function' then BeginTrade() end;"
        "local open=(TradeFrame and TradeFrame.IsVisible and TradeFrame:IsVisible());"
        "if open then "
        "W112_AUTOGOLD_OPEN='1';"
        "local targetAccepted=(TradeHighlightRecipient and TradeHighlightRecipient.IsShown and TradeHighlightRecipient:IsShown());"
        "if targetAccepted then W112_AUTOGOLD_TARGET_ACCEPTED='1' end;"
        "if type(GetTargetTradeMoney)=='function' and type(GetPlayerTradeMoney)=='function' and type(AcceptTrade)=='function' and type(GetTradePlayerItemLink)=='function' then "
        "local tm=tonumber(GetTargetTradeMoney()) or 0;"
        "local pm=tonumber(GetPlayerTradeMoney()) or 0;"
        "local own=0;local i;"
        "for i=1,7 do if GetTradePlayerItemLink(i) then own=1;break end end;"
        "if tm>0 and pm==0 and own==0 then "
        "W112_AUTOGOLD_OFFER=tostring(tm);"
        "local t=GetTime();"
        "if W112_AUTOGOLD_LAST~=tm then "
        "W112_AUTOGOLD_LAST=tm;W112_AUTOGOLD_SINCE=t;W112_AUTOGOLD_TARGET_LATCH=nil;"
        "end;"
        "if not targetAccepted then "
        "W112_AUTOGOLD_TARGET_LATCH=nil;"
        "elseif W112_AUTOGOLD_SINCE and t-W112_AUTOGOLD_SINCE>=0.25 and not W112_AUTOGOLD_TARGET_LATCH then "
        "local selfAccepted=(TradeFrame and TradeFrame.acceptState==1);"
        "if not selfAccepted then "
        "AcceptTrade();W112_AUTOGOLD_ACCEPTS=W112_AUTOGOLD_ACCEPTS+1;"
        "end;"
        "W112_AUTOGOLD_TARGET_LATCH=1;"
        "end "
        "else "
        "W112_AUTOGOLD_LAST=nil;W112_AUTOGOLD_SINCE=nil;W112_AUTOGOLD_TARGET_LATCH=nil;"
        "end "
        "end "
        "else "
        "W112_AUTOGOLD_LAST=nil;W112_AUTOGOLD_SINCE=nil;W112_AUTOGOLD_TARGET_LATCH=nil;"
        "end";
    const char *offer;
    const char *accepts;
    const char *open;
    const char *targetAccepted;

    if(g_lastTradePoll && (u32)(now-g_lastTradePoll)<TRADE_POLL_MS) return;
    g_lastTradePoll=now;

    ((FrameScriptExecuteFn)(ptr32)WOW_FRAMESCRIPT_EXECUTE)(script,"AutoSummonAssist");
    offer=((FrameScriptGetTextFn)(ptr32)WOW_FRAMESCRIPT_GETTEXT)("W112_AUTOGOLD_OFFER",-1,0u);
    accepts=((FrameScriptGetTextFn)(ptr32)WOW_FRAMESCRIPT_GETTEXT)("W112_AUTOGOLD_ACCEPTS",-1,0u);
    open=((FrameScriptGetTextFn)(ptr32)WOW_FRAMESCRIPT_GETTEXT)("W112_AUTOGOLD_OPEN",-1,0u);
    targetAccepted=((FrameScriptGetTextFn)(ptr32)WOW_FRAMESCRIPT_GETTEXT)("W112_AUTOGOLD_TARGET_ACCEPTED",-1,0u);
    g_tradeOfferCopper=parseDecimalU32(offer);
    g_tradeAcceptAttempts=parseDecimalU32(accepts);
    g_tradeOpen=(open && open[0]=='1' && open[1]==0) ? 1u:0u;
    g_tradeTargetAccepted=(targetAccepted && targetAccepted[0]=='1' && targetAccepted[1]==0) ? 1u:0u;
}

static void scanAndMaybeClick(u32 player,u32 now)
{
    u32 mgr=g_mgr,obj,i,found=0u,lo=0u,hi=0u;
    u32 foundEntry=0u,foundType=0u,foundSource=MATCH_NONE;
    float px,py,pz,best=INTERACT_RANGE_SQ+0.01f,nearest=DEBUG_NEAR_RANGE_SQ+0.01f;

    ++g_scanTicks;
    clearCandidate();
    g_nearbyGoCount=0u;
    g_nearestEntry=0u;
    g_nearestType=0u;
    g_nearestDistance100=0u;

    if(!ptrOk(mgr)||!ptrOk(player)) return;

    px=readFloat(player+PLAYER_X);
    py=readFloat(player+PLAYER_Y);
    pz=readFloat(player+PLAYER_Z);
    if(!validPos(px,py,pz)) return;

    obj=read32(mgr+OM_FIRST_OBJECT);
    for(i=0u;i<4095u && ptrOk(obj);i++) {
        u32 next=read32(obj+OBJ_NEXT);
        if(read32(obj+OBJ_TYPE_ID)==TYPEID_GAMEOBJECT) {
            u32 desc=read32(obj+OBJ_DESCRIPTOR_PTR);
            if(ptrOk(desc) &&
               (read32(desc+4u*OBJECT_FIELD_TYPE_INDEX)&TYPEMASK_GAMEOBJECT)) {
                u32 entry=read32(desc+4u*OBJECT_FIELD_ENTRY_INDEX);
                u32 goType=read32(desc+4u*GO_TYPE_ID_INDEX);
                float x=readFloat(desc+4u*GO_X_INDEX);
                float y=readFloat(desc+4u*GO_Y_INDEX);
                float z=readFloat(desc+4u*GO_Z_INDEX);

                if(validPos(x,y,z)) {
                    float dx=x-px,dy=y-py,dz=z-pz;
                    float d2=dx*dx+dy*dy+dz*dz;
                    int entryMatch=entry==SUMMONING_PORTAL_ENTRY;
                    int typeMatch=goType==GAMEOBJECT_TYPE_RITUAL;

                    if(d2<=DEBUG_NEAR_RANGE_SQ) {
                        ++g_nearbyGoCount;
                        if(d2<nearest) {
                            nearest=d2;
                            g_nearestEntry=entry;
                            g_nearestType=goType;
                            g_nearestDistance100=distance100(d2);
                        }
                    }

                    if((entryMatch||typeMatch) && d2<=INTERACT_RANGE_SQ && d2<best) {
                        best=d2;
                        found=obj;
                        lo=read32(obj+OBJ_GUID_LO);
                        hi=read32(obj+OBJ_GUID_HI);
                        foundEntry=entry;
                        foundType=goType;
                        foundSource=(entryMatch&&typeMatch)?MATCH_ENTRY_AND_TYPE:
                                    entryMatch?MATCH_ENTRY:MATCH_RITUAL_TYPE;
                    }
                }
            }
        }
        if(!ptrOk(next)||next==obj) break;
        obj=next;
    }

    if(!found || (!lo&&!hi)) {
        if(g_portalLo||g_portalHi) resetPortal();
        return;
    }

    g_candidatePresent=1u;
    g_matchSource=foundSource;
    g_candidateEntry=foundEntry;
    g_candidateType=foundType;
    g_candidateDistance100=distance100(best);
    g_candidateGuidLo=lo;
    g_candidateGuidHi=hi;

    if(lo!=g_portalLo || hi!=g_portalHi) {
        g_portalLo=lo;
        g_portalHi=hi;
        g_lastClick=0u;
        g_portalAttempts=0u;
        g_announced=0u;
    }

    /* Background multibox invariant: this is an in-process WoW object
     * interaction. It never moves the OS cursor, never sends mouse/keyboard
     * input and never requires the game window to be foreground. The FIRST
     * interaction is unconditional once a ritual candidate is in range.
     * Cast/channel state suppresses only later retries. */
    if(g_portalAttempts>=MAX_ATTEMPTS_PER_GUID) {
        g_gateReason=GATE_MAX_ATTEMPTS;
        return;
    }
    if(g_portalAttempts>0u && g_busyRaw) {
        g_gateReason=GATE_BUSY_AFTER_FIRST;
        return;
    }
    if(g_lastClick && (u32)(now-g_lastClick)<RETRY_GAP_MS) {
        g_gateReason=GATE_RETRY_GAP;
        return;
    }

    g_gateReason=(g_portalAttempts==0u)?GATE_FIRST_NATIVE_CALL:GATE_RETRY_NATIVE_CALL;
    g_lastClick=now;
    ++g_portalAttempts;
    ++g_attemptCount; /* PRE-CALL: proves execution reached 0x005F8660. */

    ((RightClickObjectFn)(ptr32)WOW_ON_RIGHT_CLICK_OBJECT)((void*)(ptr32)found,0);

    ++g_postCallCount; /* POST-CALL: proves the internal call returned. */
}

static void STDCALL timerTick(HWND32 h,UINT32 m,UINT_PTR32 id,u32 now)
{
    u32 player;
    int busy;

    (void)h;
    (void)m;
    (void)id;

    ++g_heartbeat;

    if(!buildGuard()) {
        g_status=STATUS_BUILD_MISMATCH;
        return;
    }

    player=localPlayer(now);
    if(!player) {
        g_status=(g_mgr ? STATUS_WORLD_GRACE:STATUS_WAIT_WORLD);
        return;
    }

    /* Re-register periodically so /reload cannot permanently lose the slash
     * binding. Registration and command handling stay inside this WoW process. */
    antiAfkInstallSlash(now);
    antiAfkPollSlash();

    busy=playerBusy(player);
    g_busyRaw=busy ? 1u:0u;

    pollAndMaybeAcceptGold(now);

    /* Anti-AFK is deliberately independent from AutoSummon enable state. */
    antiAfkFlushSlashFeedback();
    antiAfkTick(player,now);

    if(!g_enabled) {
        g_status=STATUS_DISABLED;
        resetPortal();
        return;
    }

    g_status=busy ? STATUS_CAST_OR_CHANNEL:STATUS_ACTIVE;
    scanAndMaybeClick(player,now);
}

static void initSettings(void)
{
    u32 i;
    static const char *keys[31]={
        "enabled","scanner_alive","candidate_present","match_source",
        "candidate_entry","candidate_type","candidate_distance_x100",
        "candidate_guid_lo","candidate_guid_hi","native_pre_calls",
        "current_guid_pre_calls","native_post_returns","scan_ticks",
        "nearby_go_count","nearest_go_entry","nearest_go_type",
        "nearest_go_distance_x100","status","gate_reason","busy_raw",
        "anti_afk_enabled","anti_afk_next_seconds","anti_afk_actions",
        "anti_afk_channel_defers","trade_open","trade_gold_copper","trade_accepts",
        "trade_target_accepted","anti_afk_last_action","anti_afk_detected",
        "anti_afk_recoveries"
    };
    static const char *labels[31]={
        "Enabled","Scanner alive","Ritual candidate","Match source",
        "Candidate entry","Candidate type","Candidate distance x100",
        "Candidate GUID low","Candidate GUID high","Native PRE calls",
        "Current GUID PRE calls","Native POST returns","Scan ticks",
        "Nearby GO <=12yd","Nearest GO entry","Nearest GO type",
        "Nearest GO distance x100","Status","Gate reason","Busy raw",
        "Anti-AFK Demon Armor priority","Anti-AFK next seconds","Anti-AFK actions",
        "Anti-AFK channel defers","Trade window open","Trade gold offered (copper)",
        "Trade accept attempts","Trade payer accepted first","Anti-AFK last action",
        "Anti-AFK detected","Anti-AFK recoveries"
    };

    if(g_descriptorReady) return;

    for(i=0u;i<31u;i++) {
        W112_ControlSettingV1 *s=&g_settings[i];
        int writableBool=(i==0u||i==20u);
        s->struct_size=sizeof(*s);
        s->setting_id=i+1u;
        s->key=keys[i];
        s->label=labels[i];
        s->type=(i<=2u||i==20u||i==24u||i==27u||i==29u) ? W112_CTL_BOOL:W112_CTL_INT;
        s->default_value.u32=(i==0u||i==20u)?1u:0u;
        s->min_value.u32=0u;
        s->max_value.u32=(i<=2u||i==20u||i==24u||i==27u||i==29u)?1u:2147483647u;
        s->step.u32=1u;
        s->flags=writableBool?W112_CTL_LIVE:(W112_CTL_READ_ONLY|W112_CTL_LIVE);
        s->enum_options=0;
        s->enum_option_count=0u;
    }

    g_descriptorReady=1u;
}

static int W112_CTL_STDCALL getValue(w112_u32 id,W112_ControlValueV1 *v)
{
    if(!v) return 0;
    if(id==1u) v->u32=g_enabled?1u:0u;
    else if(id==2u) v->u32=g_heartbeat?1u:0u;
    else if(id==3u) v->u32=g_candidatePresent?1u:0u;
    else if(id==4u) v->u32=g_matchSource;
    else if(id==5u) v->u32=g_candidateEntry;
    else if(id==6u) v->u32=g_candidateType;
    else if(id==7u) v->u32=g_candidateDistance100;
    else if(id==8u) v->u32=g_candidateGuidLo;
    else if(id==9u) v->u32=g_candidateGuidHi;
    else if(id==10u) v->u32=g_attemptCount;
    else if(id==11u) v->u32=g_portalAttempts;
    else if(id==12u) v->u32=g_postCallCount;
    else if(id==13u) v->u32=g_scanTicks;
    else if(id==14u) v->u32=g_nearbyGoCount;
    else if(id==15u) v->u32=g_nearestEntry;
    else if(id==16u) v->u32=g_nearestType;
    else if(id==17u) v->u32=g_nearestDistance100;
    else if(id==18u) v->u32=g_status;
    else if(id==19u) v->u32=g_gateReason;
    else if(id==20u) v->u32=g_busyRaw;
    else if(id==21u) v->u32=g_antiAfkEnabled?1u:0u;
    else if(id==22u) v->u32=g_antiAfkSecondsLeft;
    else if(id==23u) v->u32=g_antiAfkActions;
    else if(id==24u) v->u32=g_antiAfkChannelDefers;
    else if(id==25u) v->u32=g_tradeOpen;
    else if(id==26u) v->u32=g_tradeOfferCopper;
    else if(id==27u) v->u32=g_tradeAcceptAttempts;
    else if(id==28u) v->u32=g_tradeTargetAccepted;
    else if(id==29u) v->u32=g_antiAfkLastAction;
    else if(id==30u) v->u32=g_antiAfkDetected;
    else if(id==31u) v->u32=g_antiAfkRecoveries;
    else return 0;
    return 1;
}

static int W112_CTL_STDCALL setValue(w112_u32 id,const W112_ControlValueV1 *v)
{
    if(!v||v->u32>1u) return 0;
    if(id==1u){
        g_enabled=v->u32;
        if(!g_enabled) resetPortal();
        return 1;
    }
    if(id==21u){
        antiAfkSetEnabled(v->u32);
        return 1;
    }
    return 0;
}

static const W112_ControlModuleV1 g_module={
    W112_CONTROL_API_V1,
    sizeof(W112_ControlModuleV1),
    "autosummonassist",
    "AutoSummon Assist",
    0x000D0000u,
    31u,
    g_settings,
    getValue,
    setValue
};

DLLEXPORT const W112_ControlModuleV1 * W112_CTL_STDCALL W112_Control_GetModuleV1(void)
{
    initSettings();
    return &g_module;
}

DLLEXPORT u32 STDCALL AutoSummonAssist_GetStatus(void)
{
    return g_status;
}

DLLEXPORT u32 STDCALL AutoSummonAssist_GetAttempts(void)
{
    return g_attemptCount;
}

BOOL32 STDCALL DllMain(void *module,u32 reason,void *reserved)
{
    (void)module;
    (void)reserved;

    if(reason==1u) {
        SetTimerFn setTimer;
        resetWorld();
        g_attemptCount=0u;
        g_postCallCount=0u;
        g_gateReason=GATE_NONE;
        g_busyRaw=0u;
        g_heartbeat=0u;
        g_scanTicks=0u;
        g_antiAfkEnabled=1u;
        g_antiAfkNextAt=0u;
        g_antiAfkDeferCheckAt=0u;
        g_antiAfkPhase=ANTI_AFK_PHASE_IDLE;
        g_antiAfkKnownArmor=0u;
        g_antiAfkSecondsLeft=0u;
        g_antiAfkActions=0u;
        g_antiAfkChannelDefers=0u;
        g_antiAfkLastAction=0u;
        g_antiAfkDetected=0u;
        g_antiAfkRecoveries=0u;
        g_antiAfkSlashInstallAt=0u;
        g_antiAfkSlashFeedback=0u;
        g_antiAfkSlashCommands=0u;
        g_lastTradePoll=0u;
        g_tradeOpen=0u;
        g_tradeOfferCopper=0u;
        g_tradeAcceptAttempts=0u;
        g_tradeTargetAccepted=0u;

        if(!buildGuard()) {
            g_status=STATUS_BUILD_MISMATCH;
            return 1;
        }

        setTimer=(SetTimerFn)(ptr32)read32(WOW_IAT_SETTIMER);
        if(!setTimer) {
            g_status=STATUS_NO_TIMER;
            return 1;
        }

        g_timer=setTimer(0,0u,TIMER_MS,timerTick);
        g_status=g_timer ? STATUS_WAIT_WORLD:STATUS_NO_TIMER;
    } else if(reason==0u) {
        KillTimerFn killTimer=(KillTimerFn)(ptr32)read32(WOW_IAT_KILLTIMER);
        if(killTimer && g_timer) killTimer(0,g_timer);
        g_timer=0u;
        resetWorld();
        g_status=STATUS_DETACHED;
    }

    return 1;
}
