/*
 * WoWAutoSummonAssist 5875 v1 - isolated TEST companion module.
 * World of Warcraft 1.12.1 build 5875, Windows x86 ONLY.
 * Original project source, not reconstructed.
 *
 * Scope is deliberately narrow: spell 698 (Ritual of Summoning) creates
 * Summoning Portal GameObject entry 36727 in Vanilla. This module scans only
 * that exact client-visible GameObject and performs the same native right-click
 * primitive already verified by the current AutoGather/AutoFlag lineages.
 * It also automates background payment collection. Stock 1.12 normally begins
 * an allowed incoming trade without a reliable TRADE popup/event, so payment
 * detection keys off the live TradeFrame and calls AcceptTrade() once the other
 * player's gold offer is stable while this client offers neither money nor items.
 * The popup path remains only as a compatibility fallback for custom servers.
 *
 * Exact-client research note: reverse-engineering work targeting Vanilla 1.12
 * documents BeginTrade/AcceptTrade and notes the TRADE popup is not normally
 * signalled in stock 1.12:
 * https://github.com/samwhosung/benilla/blob/f000aa01282eac35a99370c680250d50adc67970/crates/benilla-ui/src/script/trade.rs
 *
 * Safety model:
 * - no movement or position spoofing;
 * - no target changes, hooks, casts or packets;
 * - helper must be alive, grouped, out of combat and not already casting;
 * - physical 4.75 yd range gate inside the documented 5 yd portal radius;
 * - one native right-click per observed portal GUID (no click spam);
 * - UI-thread SetTimer, world-transition quarantine, no cached object pointer.
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
#pragma comment(linker, "/EXPORT:AutoSummonAssist_GetTradeAccepts=_AutoSummonAssist_GetTradeAccepts@0")
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
typedef void (STDCALL *FrameScriptExecuteFn)(const char*,const char*);
typedef const char* (FASTCALL *FrameScriptGetTextFn)(const char*,int,u32);
typedef void (__thiscall *RightClickObjectFn)(void*,int);

#define WOW_OBJMGR                  0x00B41414u
#define WOW_GET_OBJECT_BY_GUID      0x00464870u
#define WOW_ON_RIGHT_CLICK_OBJECT   0x005F8660u
#define WOW_FRAMESCRIPT_EXECUTE     0x00704CD0u
#define WOW_FRAMESCRIPT_GETTEXT     0x00703BF0u
#define WOW_CASTING_SPELLID         0x00CECA88u
#define WOW_IAT_SETTIMER            0x007FF4F4u
#define WOW_IAT_KILLTIMER           0x007FF4F8u

#define OM_FIRST_OBJECT             0x00ACu
#define OM_LOCAL_GUID_LO            0x00C0u
#define OM_LOCAL_GUID_HI            0x00C4u
#define GO_DESCRIPTOR_PTR           0x0008u
#define OBJ_TYPE_ID                 0x0014u
#define OBJ_GUID_LO                 0x0030u
#define OBJ_GUID_HI                 0x0034u
#define OBJ_NEXT                    0x003Cu
#define PLAYER_X                    0x09B8u
#define PLAYER_Y                    0x09BCu
#define PLAYER_Z                    0x09C0u
#define OBJECT_FIELD_TYPE_INDEX     0x0002u
#define OBJECT_FIELD_ENTRY_INDEX    0x0003u
#define TYPEMASK_GAMEOBJECT         0x00000020u
#define TYPEID_GAMEOBJECT           5u
#define GO_X_INDEX                  0x000Fu
#define GO_Y_INDEX                  0x0010u
#define GO_Z_INDEX                  0x0011u
#define SUMMONING_PORTAL_ENTRY      36727u

#define TIMER_MS                    25u
#define ELIGIBILITY_REFRESH_MS      200u
#define WORLD_GRACE_MS              500u
#define INTERACT_RANGE_SQ           (4.75f*4.75f)
#define CLICKED_CACHE_CAP           16u
#define TRADE_POLL_MS               100u
#define ANTIAFK_POLL_MS             1000u

#define STATUS_DETACHED             0u
#define STATUS_WAIT_WORLD           1u
#define STATUS_WORLD_GRACE          2u
#define STATUS_ACTIVE               3u
#define STATUS_DISABLED             4u
#define STATUS_BUILD_MISMATCH       5u
#define STATUS_NO_TIMER             6u
#define STATUS_NOT_ELIGIBLE         7u
#define STATUS_CASTING              8u

struct ClickedGuid {
    u32 lo;
    u32 hi;
};

static volatile UINT_PTR32 g_timer = 0u;
static volatile u32 g_status = STATUS_DETACHED;
static volatile u32 g_enabled = 1u;
static volatile u32 g_eligible = 0u;
static volatile u32 g_portalInRange = 0u;
static volatile u32 g_attemptCount = 0u;
static volatile u32 g_lastPortalEntry = 0u;
static volatile u32 g_tradeOfferCopper = 0u;
static volatile u32 g_tradeAcceptAttempts = 0u;
static volatile u32 g_tradeOpen = 0u;
static volatile u32 g_antiAfkSayCount = 0u;

static u32 g_mgr = 0u, g_lo = 0u, g_hi = 0u, g_readyAt = 0u;
static u32 g_lastEligibilityCheck = 0u;
static u32 g_lastTradePoll = 0u;
static u32 g_lastAntiAfkPoll = 0u;
static struct ClickedGuid g_clicked[CLICKED_CACHE_CAP];
static u32 g_clickedCount = 0u;
static u32 g_clickedNext = 0u;

static W112_ControlSettingV1 g_settings[8];
static u32 g_descriptorReady = 0u;

int _fltused = 0;

static u32 read32(u32 addr) { return *(volatile u32*)(ptr32)addr; }
static float readFloat(u32 addr) { return *(volatile float*)(ptr32)addr; }
static int ptrOk(u32 p) { return p >= 0x00010000u && p <= 0x7FFE0000u && !(p & 3u); }

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

static void clearClicked(void)
{
    u32 i;
    for(i=0u;i<CLICKED_CACHE_CAP;i++) {
        g_clicked[i].lo=0u;
        g_clicked[i].hi=0u;
    }
    g_clickedCount=0u;
    g_clickedNext=0u;
}

static void resetWorld(void)
{
    g_mgr=0u;
    g_lo=0u;
    g_hi=0u;
    g_readyAt=0u;
    g_lastEligibilityCheck=0u;
    g_lastTradePoll=0u;
    g_lastAntiAfkPoll=0u;
    g_eligible=0u;
    g_portalInRange=0u;
    g_tradeOfferCopper=0u;
    g_tradeOpen=0u;
    clearClicked();
}

/* Same exact-build identity gate used by current 5875 companion modules. */
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
    return 1;
}

static int wasClicked(u32 lo,u32 hi)
{
    u32 i;
    for(i=0u;i<g_clickedCount;i++) {
        if(g_clicked[i].lo==lo && g_clicked[i].hi==hi) return 1;
    }
    return 0;
}

static void rememberClicked(u32 lo,u32 hi)
{
    u32 slot;
    if(!lo && !hi) return;
    if(wasClicked(lo,hi)) return;
    if(g_clickedCount<CLICKED_CACHE_CAP) {
        slot=g_clickedCount++;
    } else {
        slot=g_clickedNext;
        g_clickedNext=(g_clickedNext+1u)%CLICKED_CACHE_CAP;
    }
    g_clicked[slot].lo=lo;
    g_clicked[slot].hi=hi;
}

/* Server eligibility still remains authoritative. This cheap client-side gate
 * avoids clicking while dead, solo, in combat, or already casting/channeling. */
static void refreshEligibility(u32 now)
{
    static const char script[] =
        "W112_AUTOSUMMON_OK='0';"
        "if type(UnitExists)=='function' and UnitExists('player') then "
        "local dead=(type(UnitIsDeadOrGhost)=='function' and UnitIsDeadOrGhost('player'));"
        "local combat=(type(UnitAffectingCombat)=='function' and UnitAffectingCombat('player'));"
        "local party=(type(GetNumPartyMembers)=='function' and GetNumPartyMembers()>0);"
        "local raid=(type(GetNumRaidMembers)=='function' and GetNumRaidMembers()>0);"
        "if not dead and not combat and (party or raid) then W112_AUTOSUMMON_OK='1' end "
        "end";
    const char *result;

    if(g_lastEligibilityCheck &&
       (u32)(now-g_lastEligibilityCheck)<ELIGIBILITY_REFRESH_MS) return;

    g_lastEligibilityCheck=now;
    ((FrameScriptExecuteFn)(ptr32)WOW_FRAMESCRIPT_EXECUTE)(script,script);
    result=((FrameScriptGetTextFn)(ptr32)WOW_FRAMESCRIPT_GETTEXT)("W112_AUTOSUMMON_OK",-1,0u);
    g_eligible=(result && result[0]=='1' && result[1]==0) ? 1u:0u;
}

/* Resolve a fresh local-player pointer every tick and quarantine world changes. */
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


/* Background trade handling runs entirely on WoW's UI thread. Stock 1.12 opens
 * TradeFrame directly for allowed incoming trades; popup probing is fallback only.
 * Accept only a stable positive gold offer while our side contributes no money/items.
 * TradeFrame.acceptState prevents needless repeated accepts; a 500 ms retry guard
 * still covers a rejected/cleared accept state without flooding the client. */
static void pollAndMaybeAcceptGold(u32 now)
{
    static const char script[] =
        "W112_AUTOGOLD_OPEN='0';"
        "W112_AUTOGOLD_OFFER='0';"
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
        "if type(GetTargetTradeMoney)=='function' and type(GetPlayerTradeMoney)=='function' and type(AcceptTrade)=='function' and type(GetTradePlayerItemLink)=='function' then "
        "local tm=tonumber(GetTargetTradeMoney()) or 0;"
        "local pm=tonumber(GetPlayerTradeMoney()) or 0;"
        "local own=0;local i;"
        "for i=1,7 do if GetTradePlayerItemLink(i) then own=1;break end end;"
        "if tm>0 and pm==0 and own==0 then "
        "W112_AUTOGOLD_OFFER=tostring(tm);"
        "local t=GetTime();"
        "if W112_AUTOGOLD_LAST~=tm then "
        "W112_AUTOGOLD_LAST=tm;W112_AUTOGOLD_SINCE=t;W112_AUTOGOLD_LASTACCEPT=0;"
        "else "
        "local accepted=(TradeFrame and TradeFrame.acceptState==1);"
        "if W112_AUTOGOLD_SINCE and t-W112_AUTOGOLD_SINCE>=0.25 and not accepted and "
        "(not W112_AUTOGOLD_LASTACCEPT or t-W112_AUTOGOLD_LASTACCEPT>=0.50) then "
        "AcceptTrade();W112_AUTOGOLD_LASTACCEPT=t;W112_AUTOGOLD_ACCEPTS=W112_AUTOGOLD_ACCEPTS+1;"
        "end "
        "end "
        "else "
        "W112_AUTOGOLD_LAST=nil;W112_AUTOGOLD_SINCE=nil;W112_AUTOGOLD_LASTACCEPT=0;"
        "end "
        "end "
        "else "
        "W112_AUTOGOLD_LAST=nil;W112_AUTOGOLD_SINCE=nil;W112_AUTOGOLD_LASTACCEPT=0;"
        "end";
    const char *offer;
    const char *accepts;
    const char *open;

    if(g_lastTradePoll && (u32)(now-g_lastTradePoll)<TRADE_POLL_MS) return;
    g_lastTradePoll=now;

    ((FrameScriptExecuteFn)(ptr32)WOW_FRAMESCRIPT_EXECUTE)(script,script);
    offer=((FrameScriptGetTextFn)(ptr32)WOW_FRAMESCRIPT_GETTEXT)("W112_AUTOGOLD_OFFER",-1,0u);
    accepts=((FrameScriptGetTextFn)(ptr32)WOW_FRAMESCRIPT_GETTEXT)("W112_AUTOGOLD_ACCEPTS",-1,0u);
    open=((FrameScriptGetTextFn)(ptr32)WOW_FRAMESCRIPT_GETTEXT)("W112_AUTOGOLD_OPEN",-1,0u);
    g_tradeOfferCopper=parseDecimalU32(offer);
    g_tradeAcceptAttempts=parseDecimalU32(accepts);
    g_tradeOpen=(open && open[0]=='1' && open[1]==0) ? 1u:0u;
}

/* Always-on while this module is Enabled. One harmless SAY character is emitted
 * every 120..360 seconds. timerTick only calls this while no cast/channel is active,
 * so it cannot interfere with summon channeling. */
static void pollAntiAfk(u32 now)
{
    static const char script[] =
        "W112_ANTIAFK_COUNT=W112_ANTIAFK_COUNT or 0;"
        "local t=GetTime();"
        "if not W112_ANTIAFK_NEXT then "
        "local d=180;if type(math)=='table' and type(math.random)=='function' then d=math.random(120,360) end;"
        "W112_ANTIAFK_NEXT=t+d;"
        "end;"
        "if t>=W112_ANTIAFK_NEXT then "
        "local dead=(type(UnitIsDeadOrGhost)=='function' and UnitIsDeadOrGhost('player'));"
        "if not dead and type(SendChatMessage)=='function' then "
        "SendChatMessage('.','SAY');W112_ANTIAFK_COUNT=W112_ANTIAFK_COUNT+1;"
        "end;"
        "local d=180;if type(math)=='table' and type(math.random)=='function' then d=math.random(120,360) end;"
        "W112_ANTIAFK_NEXT=t+d;"
        "end";
    const char *count;

    if(g_lastAntiAfkPoll && (u32)(now-g_lastAntiAfkPoll)<ANTIAFK_POLL_MS) return;
    g_lastAntiAfkPoll=now;
    ((FrameScriptExecuteFn)(ptr32)WOW_FRAMESCRIPT_EXECUTE)(script,script);
    count=((FrameScriptGetTextFn)(ptr32)WOW_FRAMESCRIPT_GETTEXT)("W112_ANTIAFK_COUNT",-1,0u);
    g_antiAfkSayCount=parseDecimalU32(count);
}

static void scanAndMaybeClick(u32 player,int allowClick)
{
    u32 mgr=g_mgr,obj,i,found=0u,lo=0u,hi=0u;
    float px,py,pz,best=INTERACT_RANGE_SQ+0.01f;

    g_portalInRange=0u;
    if(!ptrOk(mgr)||!ptrOk(player)) return;

    px=readFloat(player+PLAYER_X);
    py=readFloat(player+PLAYER_Y);
    pz=readFloat(player+PLAYER_Z);
    if(!validPos(px,py,pz)) return;

    obj=read32(mgr+OM_FIRST_OBJECT);
    for(i=0u;i<4095u && ptrOk(obj);i++) {
        u32 next=read32(obj+OBJ_NEXT);
        if(read32(obj+OBJ_TYPE_ID)==TYPEID_GAMEOBJECT) {
            u32 desc=read32(obj+GO_DESCRIPTOR_PTR);
            if(ptrOk(desc) &&
               (read32(desc+4u*OBJECT_FIELD_TYPE_INDEX)&TYPEMASK_GAMEOBJECT)) {
                u32 entry=read32(desc+4u*OBJECT_FIELD_ENTRY_INDEX);
                if(entry==SUMMONING_PORTAL_ENTRY) {
                    float x=readFloat(desc+4u*GO_X_INDEX);
                    float y=readFloat(desc+4u*GO_Y_INDEX);
                    float z=readFloat(desc+4u*GO_Z_INDEX);
                    if(validPos(x,y,z)) {
                        float dx=x-px,dy=y-py,dz=z-pz;
                        float d2=dx*dx+dy*dy+dz*dz;
                        if(d2<=INTERACT_RANGE_SQ && d2<best) {
                            u32 candidateLo=read32(obj+OBJ_GUID_LO);
                            u32 candidateHi=read32(obj+OBJ_GUID_HI);
                            if(!wasClicked(candidateLo,candidateHi)) {
                                best=d2;
                                found=obj;
                                lo=candidateLo;
                                hi=candidateHi;
                            } else {
                                g_portalInRange=1u;
                            }
                        }
                    }
                }
            }
        }
        if(!ptrOk(next)||next==obj) break;
        obj=next;
    }

    if(!found || (!lo&&!hi)) return;
    g_portalInRange=1u;
    if(!allowClick) return;

    ((RightClickObjectFn)(ptr32)WOW_ON_RIGHT_CLICK_OBJECT)((void*)(ptr32)found,0);
    rememberClicked(lo,hi);
    g_lastPortalEntry=SUMMONING_PORTAL_ENTRY;
    ++g_attemptCount;
}

static void STDCALL timerTick(HWND32 h,UINT32 m,UINT_PTR32 id,u32 now)
{
    u32 player;
    int allowClick;

    (void)h;
    (void)m;
    (void)id;

    if(!g_enabled) {
        g_status=STATUS_DISABLED;
        g_portalInRange=0u;
        return;
    }

    if(!buildGuard()) {
        g_status=STATUS_BUILD_MISMATCH;
        return;
    }

    player=localPlayer(now);
    if(!player) {
        g_status=(g_mgr ? STATUS_WORLD_GRACE:STATUS_WAIT_WORLD);
        return;
    }

    pollAndMaybeAcceptGold(now);
    if(read32(WOW_CASTING_SPELLID)==0u) pollAntiAfk(now);
    refreshEligibility(now);
    allowClick=1;

    if(!g_eligible) {
        g_status=STATUS_NOT_ELIGIBLE;
        allowClick=0;
    } else if(read32(WOW_CASTING_SPELLID)!=0u) {
        g_status=STATUS_CASTING;
        allowClick=0;
    } else {
        g_status=STATUS_ACTIVE;
    }

    scanAndMaybeClick(player,allowClick);
}

static void initSettings(void)
{
    u32 i;
    static const char *keys[8]={
        "enabled","eligible","portal_in_range","click_attempts","trade_gold_copper","trade_accepts",
        "trade_open","anti_afk_say_count"
    };
    static const char *labels[8]={
        "Enabled","Eligible (read-only)","Portal in range (read-only)","Click attempts",
        "Trade gold offered (copper)","Trade accept attempts","Trade window open (read-only)",
        "Anti-AFK SAY messages"
    };

    if(g_descriptorReady) return;

    for(i=0u;i<8u;i++) {
        W112_ControlSettingV1 *s=&g_settings[i];
        s->struct_size=sizeof(*s);
        s->setting_id=i+1u;
        s->key=keys[i];
        s->label=labels[i];
        s->type=(i<=2u || i==6u) ? W112_CTL_BOOL:W112_CTL_INT;
        s->default_value.u32=(i==0u)?1u:0u;
        s->min_value.u32=0u;
        s->max_value.u32=(i<=2u || i==6u)?1u:2147483647u;
        s->step.u32=1u;
        s->flags=(i==0u)?W112_CTL_LIVE:(W112_CTL_READ_ONLY|W112_CTL_LIVE);
        s->enum_options=0;
        s->enum_option_count=0u;
    }

    g_descriptorReady=1u;
}

static int W112_CTL_STDCALL getValue(w112_u32 id,W112_ControlValueV1 *v)
{
    if(!v) return 0;
    if(id==1u) v->u32=g_enabled?1u:0u;
    else if(id==2u) v->u32=g_eligible?1u:0u;
    else if(id==3u) v->u32=g_portalInRange?1u:0u;
    else if(id==4u) v->u32=g_attemptCount;
    else if(id==5u) v->u32=g_tradeOfferCopper;
    else if(id==6u) v->u32=g_tradeAcceptAttempts;
    else if(id==7u) v->u32=g_tradeOpen;
    else if(id==8u) v->u32=g_antiAfkSayCount;
    else return 0;
    return 1;
}

static int W112_CTL_STDCALL setValue(w112_u32 id,const W112_ControlValueV1 *v)
{
    if(id!=1u||!v||v->u32>1u) return 0;
    g_enabled=v->u32;
    if(!g_enabled) g_portalInRange=0u;
    return 1;
}

static const W112_ControlModuleV1 g_module={
    W112_CONTROL_API_V1,
    sizeof(W112_ControlModuleV1),
    "autosummonassist",
    "AutoSummon Assist",
    0x00010200u,
    8u,
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

DLLEXPORT u32 STDCALL AutoSummonAssist_GetTradeAccepts(void)
{
    return g_tradeAcceptAttempts;
}

BOOL32 STDCALL DllMain(void *module,u32 reason,void *reserved)
{
    (void)module;
    (void)reserved;

    if(reason==1u) {
        SetTimerFn setTimer;
        resetWorld();
        g_enabled=1u;
        g_attemptCount=0u;
        g_lastPortalEntry=0u;
        g_tradeOfferCopper=0u;
        g_tradeAcceptAttempts=0u;
        g_tradeOpen=0u;
        g_antiAfkSayCount=0u;

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
