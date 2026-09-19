/*
 * WoWAutoFlagWSG 5875 v1 - isolated TEST companion module.
 * World of Warcraft 1.12.1 build 5875, Windows x86 ONLY.
 * Original project source, not reconstructed.
 *
 * Scans only visible client-side dropped WSG flag GameObjects:
 * Silverwing 179785, Warsong 179786. Base flags are excluded.
 * Calls the same native right-click GameObject primitive as the current
 * MovementCore AutoGather, but NEVER moves/spoofs the player, changes target,
 * casts spells, or hooks game code. Normal server-side rules still apply.
 *
 * UI-thread SetTimer; world-identity reset/quarantine during BG transitions;
 * WSG detector is diagnostic; exact dropped-flag GO IDs are the hard scope gate;
 * 4.75-yard physical range; per-GUID capped retries and no pointer caching.
 */
#if !defined(_M_IX86) && !defined(__i386__)
#error WoWAutoFlagWSG requires 32-bit x86.
#endif

#include "../common/W112ControlAPI.h"

#if defined(_MSC_VER)
#define STDCALL __stdcall
#define FASTCALL __fastcall
#define DLLEXPORT __declspec(dllexport)
#pragma comment(linker, "/EXPORT:W112_Control_GetModuleV1=_W112_Control_GetModuleV1@0")
#pragma comment(linker, "/EXPORT:AutoFlagWSG_GetStatus=_AutoFlagWSG_GetStatus@0")
#pragma comment(linker, "/EXPORT:AutoFlagWSG_GetAttempts=_AutoFlagWSG_GetAttempts@0")
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
#define WOW_IAT_SETTIMER           0x007FF4F4u
#define WOW_IAT_KILLTIMER          0x007FF4F8u

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
#define SILVERWING_DROPPED          179785u
#define WARSONG_DROPPED             179786u

#define TIMER_MS                    20u
#define ZONE_REFRESH_MS             400u
#define WORLD_GRACE_MS              750u
#define RETRY_GAP_MS                120u
#define MAX_ATTEMPTS_PER_GUID       7u
#define INTERACT_RANGE_SQ           (4.75f*4.75f)
#define STATUS_DETACHED             0u
#define STATUS_WAIT_WORLD           1u
#define STATUS_WORLD_GRACE          2u
#define STATUS_OUTSIDE_WSG          3u
#define STATUS_ACTIVE               4u
#define STATUS_DISABLED             5u
#define STATUS_BUILD_MISMATCH       6u
#define STATUS_NO_TIMER             7u

static volatile UINT_PTR32 g_timer = 0u;
static volatile u32 g_status = STATUS_DETACHED;
static volatile u32 g_enabled = 1u;
static volatile u32 g_wsg = 0u;
static volatile u32 g_attemptCount = 0u;
static volatile u32 g_lastEntry = 0u;
static u32 g_mgr = 0u, g_lo = 0u, g_hi = 0u, g_readyAt = 0u;
static u32 g_lastZoneCheck = 0u;
static u32 g_flagLo = 0u, g_flagHi = 0u, g_lastClick = 0u, g_flagAttempts = 0u;
static W112_ControlSettingV1 g_settings[4];
static u32 g_descriptorReady = 0u;

int _fltused = 0;

static u32 read32(u32 addr) { return *(volatile u32*)(ptr32)addr; }
static float readFloat(u32 addr) { return *(volatile float*)(ptr32)addr; }
static int ptrOk(u32 p) { return p >= 0x00010000u && p <= 0x7FFE0000u && !(p & 3u); }
static int finiteCoord(float v) {
    union { float f; u32 u; } x; x.f=v;
    return (x.u & 0x7F800000u) != 0x7F800000u && v > -200000.0f && v < 200000.0f;
}
static int validPos(float x,float y,float z) {
    return finiteCoord(x) && finiteCoord(y) && finiteCoord(z);
}
static void resetFlag(void) {
    g_flagLo=0u;g_flagHi=0u;g_lastClick=0u;g_flagAttempts=0u;
}
static void resetWorld(void) {
    g_mgr=0u;g_lo=0u;g_hi=0u;g_readyAt=0u;
    g_wsg=0u;g_lastZoneCheck=0u;resetFlag();
}

/* An executable identity check already used by active 5875 ESP lineage.
 * On a nonmatching EXE, stay inert rather than call guessed game routines. */
static int buildGuard(void) {
    static const u8 sig[] = {0x55,0x8B,0xEC,0x8B,0x45,0x08,0x8B,0x4D,0x0C,0x8B,0xD0,0x0B,0xD1};
    u32 i; const volatile u8 *p=(const volatile u8*)(ptr32)WOW_GET_OBJECT_BY_GUID;
    for (i=0u;i<sizeof(sig);i++) if(p[i]!=sig[i])return 0;
    p=(const volatile u8*)(ptr32)WOW_ON_RIGHT_CLICK_OBJECT;
    if ((p[0]==0u && p[1]==0u) || (p[0]==0xCCu && p[1]==0xCCu))return 0;
    return 1;
}

/* Diagnostic WSG detector only: the scanner itself is hard-scoped by the
 * globally unique dropped-flag GameObject entries 179785/179786.  Do not let
 * localized/custom zone text disable the feature.  Prefer the historical
 * English zone name, then use the locale-independent battlefield flag tokens
 * exposed by the 1.12 UI API when available. */
static void checkWsgZone(u32 now) {
    static const char script[] =
        "W112_AUTOFLAG_WSG='0';"
        "if type(UnitExists)=='function' and UnitExists('player') then "
        "local z='';"
        "if type(GetRealZoneText)=='function' then z=GetRealZoneText() or '' "
        "elseif type(GetZoneText)=='function' then z=GetZoneText() or '' end;"
        "if z=='Warsong Gulch' then W112_AUTOFLAG_WSG='1' "
        "elseif type(GetBattlefieldFlagPosition)=='function' then "
        "local x1,y1,t1=GetBattlefieldFlagPosition(1);"
        "local x2,y2,t2=GetBattlefieldFlagPosition(2);"
        "if t1=='AllianceFlag' or t1=='HordeFlag' or "
        "t2=='AllianceFlag' or t2=='HordeFlag' then W112_AUTOFLAG_WSG='1' end "
        "end end";
    const char *result;
    if (g_lastZoneCheck && (u32)(now-g_lastZoneCheck)<ZONE_REFRESH_MS)return;
    g_lastZoneCheck=now;
    ((FrameScriptExecuteFn)(ptr32)WOW_FRAMESCRIPT_EXECUTE)(script,script);
    result=((FrameScriptGetTextFn)(ptr32)WOW_FRAMESCRIPT_GETTEXT)("W112_AUTOFLAG_WSG",-1,0u);
    g_wsg=(result && result[0]=='1' && result[1]==0) ? 1u:0u;
}

/* Resolve fresh player pointer each tick. World/instance identity changes
 * reset the entire state and enforce 750ms quarantine (no stale GO pointers). */
static u32 localPlayer(u32 now) {
    u32 mgr=read32(WOW_OBJMGR),lo,hi,obj;
    u64 guid;
    if(!ptrOk(mgr)) { resetWorld();return 0u; }
    lo=read32(mgr+OM_LOCAL_GUID_LO);hi=read32(mgr+OM_LOCAL_GUID_HI);
    if((!lo&&!hi) || !ptrOk(read32(mgr+OM_FIRST_OBJECT))) {
        resetWorld();return 0u;
    }
    if(mgr!=g_mgr || lo!=g_lo || hi!=g_hi) {
        resetWorld();g_mgr=mgr;g_lo=lo;g_hi=hi;g_readyAt=now+WORLD_GRACE_MS;
        return 0u;
    }
    if((int)(now-g_readyAt)<0)return 0u;
    guid=((u64)hi<<32) | (u64)lo;
    obj=((GetObjectByGuidFn)(ptr32)WOW_GET_OBJECT_BY_GUID)(guid);
    if(!ptrOk(obj) || read32(obj+OBJ_GUID_LO)!=lo || read32(obj+OBJ_GUID_HI)!=hi)
        return 0u;
    if(read32(obj+OBJ_TYPE_ID)!=4u)return 0u;
    return obj;
}

static void scanAndClick(u32 player,u32 now) {
    u32 mgr=g_mgr,obj,i,found=0u,entry=0u,lo=0u,hi=0u;
    float px,py,pz,best=INTERACT_RANGE_SQ+0.01f;
    if(!ptrOk(mgr)||!ptrOk(player))return;
    px=readFloat(player+PLAYER_X);py=readFloat(player+PLAYER_Y);pz=readFloat(player+PLAYER_Z);
    if(!validPos(px,py,pz))return;
    obj=read32(mgr+OM_FIRST_OBJECT);
    for(i=0u;i<4095u && ptrOk(obj);i++) {
        u32 next=read32(obj+OBJ_NEXT);
        if(read32(obj+OBJ_TYPE_ID)==TYPEID_GAMEOBJECT) {
            u32 desc=read32(obj+GO_DESCRIPTOR_PTR);
            if(ptrOk(desc) && (read32(desc+4u*OBJECT_FIELD_TYPE_INDEX)&TYPEMASK_GAMEOBJECT)) {
                u32 id=read32(desc+4u*OBJECT_FIELD_ENTRY_INDEX);
                if(id==SILVERWING_DROPPED || id==WARSONG_DROPPED) {
                    float x=readFloat(desc+4u*GO_X_INDEX);
                    float y=readFloat(desc+4u*GO_Y_INDEX);
                    float z=readFloat(desc+4u*GO_Z_INDEX);
                    if(validPos(x,y,z)) {
                        float dx=x-px,dy=y-py,dz=z-pz,d2=dx*dx+dy*dy+dz*dz;
                        if(d2<=INTERACT_RANGE_SQ && d2<best) {
                            best=d2;found=obj;entry=id;
                            lo=read32(obj+OBJ_GUID_LO);hi=read32(obj+OBJ_GUID_HI);
                        }
                    }
                }
            }
        }
        if(!ptrOk(next)||next==obj)break;
        obj=next;
    }
    if(!found || (!lo&&!hi)) {
        resetFlag();return;
    }
    if(lo!=g_flagLo || hi!=g_flagHi) {
        g_flagLo=lo;g_flagHi=hi;g_lastClick=0u;g_flagAttempts=0u;
    }
    if(g_flagAttempts>=MAX_ATTEMPTS_PER_GUID)return;
    if(g_lastClick && (u32)(now-g_lastClick)<RETRY_GAP_MS)return;
    /* Freshly found GameObject, native click without changing current target.
     * WoW and the server retain LOS, eligibility and drop-repickup checks. */
    ((RightClickObjectFn)(ptr32)WOW_ON_RIGHT_CLICK_OBJECT)((void*)(ptr32)found,0);
    g_lastClick=now;g_lastEntry=entry;g_flagAttempts++;g_attemptCount++;
}

static void STDCALL timerTick(HWND32 h,UINT32 m,UINT_PTR32 id,u32 now) {
    u32 player;
    (void)h;(void)m;(void)id;
    if(!g_enabled){g_status=STATUS_DISABLED;resetFlag();return;}
    if(!buildGuard()){g_status=STATUS_BUILD_MISMATCH;return;}
    player=localPlayer(now);
    if(!player){g_status=(g_mgr ? STATUS_WORLD_GRACE:STATUS_WAIT_WORLD);return;}
    checkWsgZone(now);
    /* WSG text detection is diagnostic only.  The actual interaction gate is
     * the exact dropped-flag entry allowlist inside scanAndClick(). */
    g_status=STATUS_ACTIVE;
    scanAndClick(player,now);
}

static void initSettings(void) {
    u32 i;
    static const char *keys[4]={"enabled","wsg_active","click_attempts","last_flag_entry"};
    static const char *labels[4]={"Enabled","WSG detected (read-only)","Click attempts","Last flag entry"};
    if(g_descriptorReady)return;
    for(i=0u;i<4u;i++) {
        W112_ControlSettingV1 *s=&g_settings[i];
        s->struct_size=sizeof(*s);s->setting_id=i+1u;s->key=keys[i];s->label=labels[i];
        s->type=(i<=1u) ? W112_CTL_BOOL:W112_CTL_INT;
        s->default_value.u32=(i==0u)?1u:0u;s->min_value.u32=0u;
        s->max_value.u32=(i<=1u)?1u:2147483647u;s->step.u32=1u;
        s->flags=(i==0u)?W112_CTL_LIVE:(W112_CTL_READ_ONLY|W112_CTL_LIVE);
        s->enum_options=0;s->enum_option_count=0u;
    }
    g_descriptorReady=1u;
}
static int W112_CTL_STDCALL getValue(w112_u32 id,W112_ControlValueV1 *v) {
    if(!v)return 0;
    if(id==1u)v->u32=g_enabled?1u:0u;
    else if(id==2u)v->u32=g_wsg?1u:0u;
    else if(id==3u)v->u32=g_attemptCount;
    else if(id==4u)v->u32=g_lastEntry;
    else return 0;
    return 1;
}
static int W112_CTL_STDCALL setValue(w112_u32 id,const W112_ControlValueV1 *v) {
    if(id!=1u||!v||v->u32>1u)return 0;
    g_enabled=v->u32;
    if(!g_enabled)resetFlag();
    return 1;
}
static const W112_ControlModuleV1 g_module={
    W112_CONTROL_API_V1,sizeof(W112_ControlModuleV1),"autoflagwsg","WSG AutoFlag",
    0x00010000u,4u,g_settings,getValue,setValue
};
DLLEXPORT const W112_ControlModuleV1 * W112_CTL_STDCALL W112_Control_GetModuleV1(void) {
    initSettings();return &g_module;
}
DLLEXPORT u32 STDCALL AutoFlagWSG_GetStatus(void){return g_status;}
DLLEXPORT u32 STDCALL AutoFlagWSG_GetAttempts(void){return g_attemptCount;}

BOOL32 STDCALL DllMain(void *module,u32 reason,void *reserved) {
    (void)module;(void)reserved;
    if(reason==1u) {
        SetTimerFn setTimer;
        resetWorld();g_attemptCount=0u;g_lastEntry=0u;
        if(!buildGuard()){g_status=STATUS_BUILD_MISMATCH;return 1;}
        setTimer=(SetTimerFn)(ptr32)read32(WOW_IAT_SETTIMER);
        if(!setTimer){g_status=STATUS_NO_TIMER;return 1;}
        g_timer=setTimer(0,0u,TIMER_MS,timerTick);
        g_status=g_timer ? STATUS_WAIT_WORLD:STATUS_NO_TIMER;
    } else if(reason==0u) {
        KillTimerFn killTimer=(KillTimerFn)(ptr32)read32(WOW_IAT_KILLTIMER);
        if(killTimer && g_timer)killTimer(0,g_timer);
        g_timer=0u;resetWorld();g_status=STATUS_DETACHED;
    }
    return 1;
}
