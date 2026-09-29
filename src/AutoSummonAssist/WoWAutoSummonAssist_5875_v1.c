/*
 * WoWAutoSummonAssist 5875 v2 - isolated TEST companion module.
 * World of Warcraft 1.12.1 build 5875, Windows x86 ONLY.
 *
 * Exact scope: Ritual of Summoning spell 698 creates Summoning Portal
 * GameObject entry 36727 in Vanilla. The module scans only that entry and
 * invokes the same verified native GameObject right-click primitive used by
 * the existing AutoFlag/AutoGather lineages.
 *
 * v2 reliability changes:
 * - no Lua party/combat eligibility gate; the server remains authoritative;
 * - retry the same portal up to 8 times at 120 ms intervals;
 * - stop retries immediately when the local player starts a cast/channel;
 * - one chat diagnostic per newly observed portal GUID;
 * - no movement/position spoofing, target changes, hooks, casts or packets.
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
typedef void (STDCALL *FrameScriptExecuteFn)(const char*,const char*);
typedef void (__thiscall *RightClickObjectFn)(void*,int);

#define WOW_OBJMGR                  0x00B41414u
#define WOW_GET_OBJECT_BY_GUID      0x00464870u
#define WOW_ON_RIGHT_CLICK_OBJECT   0x005F8660u
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
#define OBJECT_FIELD_TYPE_INDEX     0x0002u
#define OBJECT_FIELD_ENTRY_INDEX    0x0003u
#define TYPEMASK_GAMEOBJECT         0x00000020u
#define TYPEID_GAMEOBJECT           5u
#define GO_X_INDEX                  0x000Fu
#define GO_Y_INDEX                  0x0010u
#define GO_Z_INDEX                  0x0011u
#define SUMMONING_PORTAL_ENTRY      36727u

#define TIMER_MS                    25u
#define WORLD_GRACE_MS              500u
#define RETRY_GAP_MS                120u
#define MAX_ATTEMPTS_PER_GUID       8u
#define INTERACT_RANGE_SQ           (5.50f*5.50f)

#define STATUS_DETACHED             0u
#define STATUS_WAIT_WORLD           1u
#define STATUS_WORLD_GRACE          2u
#define STATUS_ACTIVE               3u
#define STATUS_DISABLED             4u
#define STATUS_BUILD_MISMATCH       5u
#define STATUS_NO_TIMER             6u
#define STATUS_CAST_OR_CHANNEL      7u

static volatile UINT_PTR32 g_timer = 0u;
static volatile u32 g_status = STATUS_DETACHED;
static volatile u32 g_enabled = 1u;
static volatile u32 g_portalInRange = 0u;
static volatile u32 g_attemptCount = 0u;
static volatile u32 g_lastPortalEntry = 0u;

static u32 g_mgr = 0u, g_lo = 0u, g_hi = 0u, g_readyAt = 0u;
static u32 g_portalLo = 0u, g_portalHi = 0u;
static u32 g_lastClick = 0u, g_portalAttempts = 0u, g_announced = 0u;

static W112_ControlSettingV1 g_settings[4];
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

static void resetPortal(void)
{
    g_portalLo=0u;
    g_portalHi=0u;
    g_lastClick=0u;
    g_portalAttempts=0u;
    g_announced=0u;
    g_portalInRange=0u;
}

static void resetWorld(void)
{
    g_mgr=0u;
    g_lo=0u;
    g_hi=0u;
    g_readyAt=0u;
    resetPortal();
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
    return 1;
}

static void announcePortal(void)
{
    static const char msg[] =
        "if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage("
        "'|cff66ccff[AutoSummon]|r Summoning Portal 36727 wykryty - pomagam.') end";
    ((FrameScriptExecuteFn)(ptr32)WOW_FRAMESCRIPT_EXECUTE)(msg,msg);
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

static void scanAndMaybeClick(u32 player,u32 now,int allowClick)
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
            u32 desc=read32(obj+OBJ_DESCRIPTOR_PTR);
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
                            best=d2;
                            found=obj;
                            lo=read32(obj+OBJ_GUID_LO);
                            hi=read32(obj+OBJ_GUID_HI);
                        }
                    }
                }
            }
        }
        if(!ptrOk(next)||next==obj) break;
        obj=next;
    }

    if(!found || (!lo&&!hi)) {
        resetPortal();
        return;
    }

    g_portalInRange=1u;
    if(lo!=g_portalLo || hi!=g_portalHi) {
        g_portalLo=lo;
        g_portalHi=hi;
        g_lastClick=0u;
        g_portalAttempts=0u;
        g_announced=0u;
    }

    if(!g_announced) {
        announcePortal();
        g_announced=1u;
    }

    if(!allowClick) return;
    if(g_portalAttempts>=MAX_ATTEMPTS_PER_GUID) return;
    if(g_lastClick && (u32)(now-g_lastClick)<RETRY_GAP_MS) return;

    ((RightClickObjectFn)(ptr32)WOW_ON_RIGHT_CLICK_OBJECT)((void*)(ptr32)found,0);
    g_lastClick=now;
    g_lastPortalEntry=SUMMONING_PORTAL_ENTRY;
    ++g_portalAttempts;
    ++g_attemptCount;
}

static void STDCALL timerTick(HWND32 h,UINT32 m,UINT_PTR32 id,u32 now)
{
    u32 player;
    int busy;

    (void)h;
    (void)m;
    (void)id;

    if(!g_enabled) {
        g_status=STATUS_DISABLED;
        resetPortal();
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

    busy=playerBusy(player);
    g_status=busy ? STATUS_CAST_OR_CHANNEL:STATUS_ACTIVE;
    scanAndMaybeClick(player,now,!busy);
}

static void initSettings(void)
{
    u32 i;
    static const char *keys[4]={
        "enabled","portal_in_range","click_attempts","last_portal_entry"
    };
    static const char *labels[4]={
        "Enabled","Portal in range (read-only)","Click attempts","Last portal entry"
    };

    if(g_descriptorReady) return;

    for(i=0u;i<4u;i++) {
        W112_ControlSettingV1 *s=&g_settings[i];
        s->struct_size=sizeof(*s);
        s->setting_id=i+1u;
        s->key=keys[i];
        s->label=labels[i];
        s->type=(i<=1u) ? W112_CTL_BOOL:W112_CTL_INT;
        s->default_value.u32=(i==0u)?1u:0u;
        s->min_value.u32=0u;
        s->max_value.u32=(i<=1u)?1u:2147483647u;
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
    else if(id==2u) v->u32=g_portalInRange?1u:0u;
    else if(id==3u) v->u32=g_attemptCount;
    else if(id==4u) v->u32=g_lastPortalEntry;
    else return 0;
    return 1;
}

static int W112_CTL_STDCALL setValue(w112_u32 id,const W112_ControlValueV1 *v)
{
    if(id!=1u||!v||v->u32>1u) return 0;
    g_enabled=v->u32;
    if(!g_enabled) resetPortal();
    return 1;
}

static const W112_ControlModuleV1 g_module={
    W112_CONTROL_API_V1,
    sizeof(W112_ControlModuleV1),
    "autosummonassist",
    "AutoSummon Assist",
    0x00020000u,
    4u,
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
        g_lastPortalEntry=0u;

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
