/*
 * WoWNonPvPSpeedFloor_v0_4_ALWAYS_FLOOR7_1_DIAG_RECONSTRUCTED.c
 *
 * Target: World of Warcraft 1.12.1 build 5875, Windows x86.
 *
 * Source origin:
 *   FUNCTIONALLY EQUIVALENT RECONSTRUCTION from the final DLL
 *   WoWNonPvPSpeedFloor_v0_4_ALWAYS_FLOOR7_1_DIAG.dll
 *   SHA256 39478169ac9e37d82ce45daa4fad997ae059c57c271fb14027aa3c1b302854db
 *
 * This is NOT claimed to be the original source. The constants, hardcoded
 * addresses, calling conventions, timer layout, object traversal, stealth
 * scan, speed write/recalc path, exported status interface and diagnostic
 * behaviour below were reconstructed from the final PE32/x86 machine code.
 *
 * Candidate extension: W112_CONTROL_API_V1 settings were added on work. They
 * are not claimed to have existed in the recovered DLL. Their compile-time
 * defaults preserve the active v0.4 runtime behaviour when no ControlHub is
 * loaded.
 */
/* Workflow latency benchmark marker: source-only comment; no runtime semantic change. */

#if !defined(_M_IX86) && !defined(__i386__)
#error This module is for 32-bit x86 only.
#endif

#include "../common/W112ControlAPI.h"

#if defined(_MSC_VER)
#define STDCALL  __stdcall
#define THISCALL __thiscall
#define DLLEXPORT __declspec(dllexport)
#pragma comment(linker, "/EXPORT:W112_Control_GetModuleV1=_W112_Control_GetModuleV1@0")
#else
#define STDCALL  __attribute__((stdcall))
#define THISCALL __attribute__((thiscall))
#define DLLEXPORT __attribute__((dllexport))
#endif

typedef unsigned char  u8;
typedef unsigned short u16;
typedef unsigned int   u32;
typedef signed int     s32;
typedef u32            uptr32;
typedef int            BOOL32;
typedef void          *HANDLE32;
typedef void          *HWND32;
typedef u32            UINT32;
typedef u32            UINT_PTR32;

#define TRUE32  1
#define FALSE32 0

#define DLL_PROCESS_DETACH 0u
#define DLL_PROCESS_ATTACH 1u

#define GENERIC_WRITE32       0x40000000u
#define FILE_SHARE_RW32       0x00000003u
#define OPEN_ALWAYS32         4u
#define FILE_ATTRIBUTE_NORMAL 0x00000080u
#define FILE_END32            2u

#define WOW_OBJECT_MANAGER_PTR 0x00B41414u
#define WOW_SELECTED_GUID_LO   0x00B4E2D8u
#define WOW_SELECTED_GUID_HI   0x00B4E2DCu
#define WOW_PVP_STATE_FN       0x00605FF0u
#define WOW_UNIT_REACTION_FN   0x006061E0u
#define WOW_SPEED_RECALC_FN    0x007C5C20u

/* Hardcoded WoW.exe IAT slots observed in the final DLL. */
#define WOW_IAT_CLOSEHANDLE     0x007FF15Cu
#define WOW_IAT_SETFILEPOINTER  0x007FF190u
#define WOW_IAT_CREATEFILEA     0x007FF1D4u
#define WOW_IAT_WRITEFILE       0x007FF2ECu
#define WOW_IAT_GETTICKCOUNT    0x007FF310u
#define WOW_IAT_SETTIMER        0x007FF4F4u
#define WOW_IAT_KILLTIMER       0x007FF4F8u

/* Object-manager / object offsets observed in the final DLL. */
#define OM_FIRST_OBJECT_OFF     0x00ACu
#define OM_PLAYER_GUID_LO_OFF   0x00C0u
#define OM_PLAYER_GUID_HI_OFF   0x00C4u
#define OBJ_DESCRIPTOR_PTR_OFF  0x0008u
#define OBJ_TYPE_ID_OFF         0x0014u
#define OBJ_GUID_LO_OFF         0x0030u
#define OBJ_GUID_HI_OFF         0x0034u
#define OBJ_NEXT_OFF            0x003Cu
#define TYPEID_PLAYER           4u

/* Active stealth spell-id scan inside the descriptor block. */
#define DESC_STEALTH_FIRST_OFF  0x00BCu
#define DESC_STEALTH_LAST_OFF   0x0178u

/* Player movement fields used by the final v0.4 runtime. */
#define PLAYER_MOVEMENT_RECALC_THIS_OFF 0x09A8u
#define PLAYER_CURRENT_SPEED_OFF        0x0A2Cu
#define PLAYER_RUN_SPEED_OFF            0x0A34u

#define SPEED_FLOOR_BITS 0x40E33333u
#define SPEED_MIN_VALID  0.01f
#define SPEED_FLOOR      7.10f
#define HEALTH_LOG_MS    2000u
#define TIMER_PERIOD_MS  5u
#define MAX_OBJECT_STEPS 0x0FFFu
#define MAX_APPLY_DETAIL_LOGS 192u

#define CONTROL_MIN_SPEED      1.00f
#define CONTROL_MIN_PVP_SPEED  0.00f
#define CONTROL_MAX_SPEED     14.00f
#define CONTROL_SPEED_STEP     0.10f
#define SETTING_ENABLED             1u
#define SETTING_MINIMUM_SPEED       2u
#define SETTING_PVP_MINIMUM_SPEED   3u

#define STATUS_DETACHED            0u
#define STATUS_ACTIVE              1u
#define STATUS_SETTIMER_MISSING    2u
#define STATUS_SETTIMER_FAILED     3u
#define METHOD_SAFE_DIRECT_RECALC_ONLY 4u
#define VERSION_0_4 0x00040000u

#define INVALID_HANDLE32 ((HANDLE32)(uptr32)0xFFFFFFFFu)

typedef void (STDCALL *TimerProc32)(HWND32, UINT32, UINT_PTR32, u32);
typedef UINT_PTR32 (STDCALL *SetTimerFn)(HWND32, UINT_PTR32, UINT32, TimerProc32);
typedef BOOL32 (STDCALL *KillTimerFn)(HWND32, UINT_PTR32);
typedef HANDLE32 (STDCALL *CreateFileAFn)(const char *, u32, u32, void *, u32, u32, HANDLE32);
typedef u32 (STDCALL *SetFilePointerFn)(HANDLE32, s32, s32 *, u32);
typedef BOOL32 (STDCALL *WriteFileFn)(HANDLE32, const void *, u32, u32 *, void *);
typedef BOOL32 (STDCALL *CloseHandleFn)(HANDLE32);
typedef u32 (STDCALL *GetTickCountFn)(void);
typedef u32 (THISCALL *PvpStateFn)(void *player);
typedef s32 (THISCALL *UnitReactionFn)(uptr32 selfObj, uptr32 targetObj);
typedef void (THISCALL *SpeedRecalcFn)(void *movementThis, u32 zero);

static volatile u32 g_prevPvp = 0xFFFFFFFFu;
static volatile u32 g_prevStealth = 0xFFFFFFFFu;
static volatile u32 g_prevTargetHostile = 0xFFFFFFFFu;
static volatile u32 g_status = STATUS_DETACHED;
static volatile u32 g_applyCount = 0u;
static volatile UINT_PTR32 g_timerId = 0u;
static volatile u32 g_applyDetailCount = 0u;
static volatile u32 g_lastHealthTick = 0u;
static volatile u32 g_lastHealthApplyCount = 0u;

/* Runtime config defaults intentionally match the accepted v0.4 behaviour. */
static volatile u32 g_cfgEnabled = 1u;
static volatile u32 g_cfgMinimumSpeedBits = SPEED_FLOOR_BITS;
/* 0.0 preserves the accepted behaviour: hostile-player targeting previously disabled the floor. */
static volatile u32 g_cfgPvpMinimumSpeedBits = 0u;
static W112_ControlSettingV1 g_controlSettings[3];
static volatile u32 g_controlDescriptorReady = 0u;

static const char kLogName[] = "WoWNonPvPSpeedFloor_v0_4_ALWAYS_FLOOR7_1_DIAG.log";
static const char kHex[] = "0123456789ABCDEF";
static const char kEventApply[] = "FLOOR_APPLY";
static const char kEventHealth[] = "SPEED_HEALTH";
static const char kEventPvp[] = "PVP_STATE";
static const char kEventStealth[] = "STEALTH_STATE";
static const char kEventTargetHostile0[] = "TARGET_HOSTILE_PLAYER=0";
static const char kEventTargetHostile1[] = "TARGET_HOSTILE_PLAYER=1";
static const char kEventNeeded[] = "FLOOR_NEEDED";
static const char kEventLoad[] = "LOAD_ALWAYS_FLOOR71_DIAG_V04";

/* MSVC-style x86 floating point links may expect this symbol with /NODEFAULTLIB. */
int _fltused = 0x9875;

static u32 read_u32(uptr32 address)
{
    return *(volatile u32 *)(uptr32)address;
}

static void write_u32(uptr32 address, u32 value)
{
    *(volatile u32 *)(uptr32)address = value;
}

static float read_f32(uptr32 address)
{
    return *(volatile float *)(uptr32)address;
}

static int sane_ptr(uptr32 p)
{
    if (p < 0x00010000u) return 0;
    if (p >= 0x7FFE0000u) return 0;
    if (p & 1u) return 0;
    return 1;
}

static void *load_iat_fn(uptr32 slot)
{
    return (void *)(uptr32)read_u32(slot);
}

static char *append_str(char *out, const char *s)
{
    while (*s) *out++ = *s++;
    return out;
}

static char *append_u32_dec(char *out, u32 value)
{
    char tmp[16];
    u32 n = 0;
    if (value == 0u) {
        *out++ = '0';
        return out;
    }
    while (value != 0u && n < (u32)sizeof(tmp)) {
        u32 q = value / 10u;
        tmp[n++] = (char)('0' + (value - q * 10u));
        value = q;
    }
    while (n != 0u) *out++ = tmp[--n];
    return out;
}

static char *append_hex32(char *out, u32 value)
{
    int shift;
    *out++ = '0';
    *out++ = 'x';
    for (shift = 28; shift >= 0; shift -= 4)
        *out++ = kHex[(value >> shift) & 0xFu];
    return out;
}

static u32 float_bits(float v)
{
    union { float f; u32 u; } x;
    x.f = v;
    return x.u;
}

static float bits_float(u32 v)
{
    union { float f; u32 u; } x;
    x.u = v;
    return x.f;
}

/* Matches the positive-value diagnostic conversion visible in the DLL. */
static u32 float_x100(float v)
{
    if (!(v > 0.0f)) return 0u;
    if (v > 42949600.0f) return 0xFFFFFFFFu;
    return (u32)(v * 100.0f + 0.5f);
}

static void log_event(const char *eventName,
                      u32 pvp,
                      u32 stealth,
                      uptr32 player,
                      float runBefore,
                      float curBefore,
                      float runAfter,
                      float curAfter,
                      u32 applyDelta)
{
    CreateFileAFn createFile = (CreateFileAFn)load_iat_fn(WOW_IAT_CREATEFILEA);
    SetFilePointerFn setFilePointer = (SetFilePointerFn)load_iat_fn(WOW_IAT_SETFILEPOINTER);
    WriteFileFn writeFile = (WriteFileFn)load_iat_fn(WOW_IAT_WRITEFILE);
    CloseHandleFn closeHandle = (CloseHandleFn)load_iat_fn(WOW_IAT_CLOSEHANDLE);
    GetTickCountFn getTickCount = (GetTickCountFn)load_iat_fn(WOW_IAT_GETTICKCOUNT);
    char line[768];
    char *p = line;
    HANDLE32 h;
    u32 written = 0u;
    u32 tick;

    if (!createFile || !setFilePointer || !writeFile || !closeHandle)
        return;

    tick = getTickCount ? getTickCount() : 0u;

    p = append_str(p, "tick=");
    p = append_u32_dec(p, tick);
    p = append_str(p, " event=");
    p = append_str(p, eventName);
    p = append_str(p, " pvp=");
    p = append_u32_dec(p, pvp);
    p = append_str(p, " stealth=");
    p = append_u32_dec(p, stealth);
    p = append_str(p, " player=");
    p = append_hex32(p, player);

    p = append_str(p, " run_before_x100=");
    p = append_u32_dec(p, float_x100(runBefore));
    p = append_str(p, " cur_before_x100=");
    p = append_u32_dec(p, float_x100(curBefore));
    p = append_str(p, " run_after_x100=");
    p = append_u32_dec(p, float_x100(runAfter));
    p = append_str(p, " cur_after_x100=");
    p = append_u32_dec(p, float_x100(curAfter));

    p = append_str(p, " run_before_bits=");
    p = append_hex32(p, float_bits(runBefore));
    p = append_str(p, " cur_before_bits=");
    p = append_hex32(p, float_bits(curBefore));
    p = append_str(p, " run_after_bits=");
    p = append_hex32(p, float_bits(runAfter));
    p = append_str(p, " cur_after_bits=");
    p = append_hex32(p, float_bits(curAfter));

    p = append_str(p, " apply_count=");
    p = append_u32_dec(p, g_applyCount);
    p = append_str(p, " apply_delta=");
    p = append_u32_dec(p, applyDelta);
    p = append_str(p, " floor_runtime=CONTROL_API_V1 pvp_floor=HOSTILE_PLAYER_TARGET method=SAFE_DIRECT_RECALC_ONLY\r\n");

    h = createFile(kLogName,
                   GENERIC_WRITE32,
                   FILE_SHARE_RW32,
                   0,
                   OPEN_ALWAYS32,
                   FILE_ATTRIBUTE_NORMAL,
                   0);
    if (!h || h == INVALID_HANDLE32)
        return;

    setFilePointer(h, 0, 0, FILE_END32);
    writeFile(h, line, (u32)(p - line), &written, 0);
    closeHandle(h);
}

static int is_stealth_spell(u32 id)
{
    if (id >= 0x000006F8u && id <= 0x000006FBu) return 1;
    if (id == 0x00002C3Fu) return 1;
    if (id == 0x00002C41u) return 1;
    return 0;
}

static u32 detect_stealth(uptr32 player)
{
    uptr32 descriptor = read_u32(player + OBJ_DESCRIPTOR_PTR_OFF);
    uptr32 off;
    if (!sane_ptr(descriptor)) return 0u;

    for (off = DESC_STEALTH_FIRST_OFF; off <= DESC_STEALTH_LAST_OFF; off += 4u) {
        if (is_stealth_spell(read_u32(descriptor + off)))
            return 1u;
    }
    return 0u;
}

static uptr32 find_object_by_guid(u32 guidLo, u32 guidHi)
{
    uptr32 mgr = read_u32(WOW_OBJECT_MANAGER_PTR);
    uptr32 obj;
    u32 guard = MAX_OBJECT_STEPS;

    if (!sane_ptr(mgr)) return 0u;
    if ((guidLo | guidHi) == 0u) return 0u;

    obj = read_u32(mgr + OM_FIRST_OBJECT_OFF);
    while (guard-- != 0u) {
        uptr32 next;
        if (!sane_ptr(obj)) return 0u;
        if (read_u32(obj + OBJ_GUID_LO_OFF) == guidLo &&
            read_u32(obj + OBJ_GUID_HI_OFF) == guidHi)
            return obj;

        next = read_u32(obj + OBJ_NEXT_OFF);
        if (next == obj) return 0u;
        obj = next;
    }
    return 0u;
}

static uptr32 find_player_object(void)
{
    uptr32 mgr = read_u32(WOW_OBJECT_MANAGER_PTR);
    u32 guidLo, guidHi;

    if (!sane_ptr(mgr)) return 0u;

    guidLo = read_u32(mgr + OM_PLAYER_GUID_LO_OFF);
    guidHi = read_u32(mgr + OM_PLAYER_GUID_HI_OFF);
    return find_object_by_guid(guidLo, guidHi);
}

static u32 current_target_is_hostile_player(uptr32 player)
{
    u32 guidLo = read_u32(WOW_SELECTED_GUID_LO);
    u32 guidHi = read_u32(WOW_SELECTED_GUID_HI);
    uptr32 target;
    s32 reaction;
    UnitReactionFn fn;

    if ((guidLo | guidHi) == 0u) return 0u;

    target = find_object_by_guid(guidLo, guidHi);
    if (!target) return 0u;
    if (read_u32(target + OBJ_TYPE_ID_OFF) != TYPEID_PLAYER) return 0u;

    fn = (UnitReactionFn)(uptr32)WOW_UNIT_REACTION_FN;
    reaction = fn(player, target);

    /* PlayerESP's verified build-5875 classifier treats reactions 1..3 as enemy/hostile. */
    return (reaction >= 1 && reaction <= 3) ? 1u : 0u;
}

static u32 query_pvp(uptr32 player)
{
    PvpStateFn fn = (PvpStateFn)(uptr32)WOW_PVP_STATE_FN;
    return fn((void *)(uptr32)player) ? 1u : 0u;
}

static void recalc_speed(uptr32 player)
{
    SpeedRecalcFn fn = (SpeedRecalcFn)(uptr32)WOW_SPEED_RECALC_FN;
    fn((void *)(uptr32)(player + PLAYER_MOVEMENT_RECALC_THIS_OFF), 0u);
}

static void STDCALL SpeedFloor_TimerProc(HWND32 hwnd, UINT32 msg, UINT_PTR32 timerId, u32 tickParam)
{
    uptr32 player;
    u32 pvp;
    u32 stealth;
    u32 targetHostile;
    float curBefore;
    float runBefore;
    float curAfter;
    float runAfter;
    float floorValue;
    u32 floorBits;
    GetTickCountFn getTickCount;
    u32 now;
    u32 applyDelta;

    (void)hwnd;
    (void)msg;
    (void)timerId;
    (void)tickParam;

    player = find_player_object();
    if (!player) return;

    pvp = query_pvp(player);
    stealth = detect_stealth(player);
    targetHostile = current_target_is_hostile_player(player);
    curBefore = read_f32(player + PLAYER_CURRENT_SPEED_OFF);
    runBefore = read_f32(player + PLAYER_RUN_SPEED_OFF);
    curAfter = curBefore;
    runAfter = runBefore;
    /* Preserve the existing PvP detector semantics: hostile player target selects the PvP floor. */
    floorBits = targetHostile ? g_cfgPvpMinimumSpeedBits : g_cfgMinimumSpeedBits;
    floorValue = bits_float(floorBits);

    if (g_prevPvp != pvp) {
        g_prevPvp = pvp;
        log_event(kEventPvp, pvp, stealth, player,
                  runBefore, curBefore, runBefore, curBefore, 0u);
    }

    if (g_prevStealth != stealth) {
        g_prevStealth = stealth;
        log_event(kEventStealth, pvp, stealth, player,
                  runBefore, curBefore, runBefore, curBefore, 0u);
    }

    if (g_prevTargetHostile != targetHostile) {
        g_prevTargetHostile = targetHostile;
        log_event(targetHostile ? kEventTargetHostile1 : kEventTargetHostile0,
                  pvp, stealth, player,
                  runBefore, curBefore, runBefore, curBefore, 0u);
    }

    /*
     * Floor only when BOTH the base run field and the currently effective
     * speed are below the configured minimum.  A buff such as Sprint may
     * legitimately raise current speed above the floor while the base run
     * field remains below it; in that case stay completely hands-off so the
     * periodic recalc cannot collapse the buff back toward 7.1.
     */
    if (g_cfgEnabled &&
        floorValue >= SPEED_MIN_VALID &&
        runBefore > SPEED_MIN_VALID && runBefore < floorValue &&
        curBefore < floorValue) {
        log_event(kEventNeeded, pvp, stealth, player,
                  runBefore, curBefore, runBefore, curBefore, 0u);

        write_u32(player + PLAYER_RUN_SPEED_OFF, floorBits);
        recalc_speed(player);

        curAfter = read_f32(player + PLAYER_CURRENT_SPEED_OFF);
        runAfter = read_f32(player + PLAYER_RUN_SPEED_OFF);
        ++g_applyCount;

        if (g_applyDetailCount < MAX_APPLY_DETAIL_LOGS) {
            ++g_applyDetailCount;
            log_event(kEventApply, pvp, stealth, player,
                      runBefore, curBefore, runAfter, curAfter, 1u);
        }
    }

    getTickCount = (GetTickCountFn)load_iat_fn(WOW_IAT_GETTICKCOUNT);
    now = getTickCount ? getTickCount() : 0u;

    if (g_lastHealthTick != 0u && (u32)(now - g_lastHealthTick) < HEALTH_LOG_MS)
        return;

    applyDelta = g_applyCount - g_lastHealthApplyCount;
    g_lastHealthTick = now;
    g_lastHealthApplyCount = g_applyCount;

    /* The final DLL logs the post-action snapshot for SPEED_HEALTH. */
    log_event(kEventHealth, pvp, stealth, player,
              runAfter, curAfter, runAfter, curAfter, applyDelta);
}

static void init_control_descriptor(void)
{
    W112_ControlSettingV1 *s;
    if (g_controlDescriptorReady) return;

    s = &g_controlSettings[0];
    s->struct_size = (w112_u32)sizeof(W112_ControlSettingV1);
    s->setting_id = SETTING_ENABLED;
    s->key = "enabled";
    s->label = "Enabled";
    s->type = W112_CTL_BOOL;
    s->default_value.u32 = 1u;
    s->min_value.u32 = 0u;
    s->max_value.u32 = 1u;
    s->step.u32 = 1u;
    s->flags = W112_CTL_LIVE;
    s->enum_options = 0;
    s->enum_option_count = 0u;

    s = &g_controlSettings[1];
    s->struct_size = (w112_u32)sizeof(W112_ControlSettingV1);
    s->setting_id = SETTING_MINIMUM_SPEED;
    s->key = "minimum_speed";
    s->label = "Minimum Speed";
    s->type = W112_CTL_FLOAT;
    s->default_value.f32 = SPEED_FLOOR;
    s->min_value.f32 = CONTROL_MIN_SPEED;
    s->max_value.f32 = CONTROL_MAX_SPEED;
    s->step.f32 = CONTROL_SPEED_STEP;
    s->flags = W112_CTL_LIVE;
    s->enum_options = 0;
    s->enum_option_count = 0u;

    s = &g_controlSettings[2];
    s->struct_size = (w112_u32)sizeof(W112_ControlSettingV1);
    s->setting_id = SETTING_PVP_MINIMUM_SPEED;
    s->key = "pvp_minimum_speed";
    s->label = "PvP Minimum Speed";
    s->type = W112_CTL_FLOAT;
    s->default_value.f32 = 0.0f;
    s->min_value.f32 = CONTROL_MIN_PVP_SPEED;
    s->max_value.f32 = CONTROL_MAX_SPEED;
    s->step.f32 = CONTROL_SPEED_STEP;
    s->flags = W112_CTL_LIVE;
    s->enum_options = 0;
    s->enum_option_count = 0u;

    g_controlDescriptorReady = 1u;
}

static int W112_CTL_STDCALL speedfloor_control_get(w112_u32 settingId, W112_ControlValueV1 *outValue)
{
    if (!outValue) return 0;
    if (settingId == SETTING_ENABLED) {
        outValue->u32 = g_cfgEnabled ? 1u : 0u;
        return 1;
    }
    if (settingId == SETTING_MINIMUM_SPEED) {
        outValue->f32 = bits_float(g_cfgMinimumSpeedBits);
        return 1;
    }
    if (settingId == SETTING_PVP_MINIMUM_SPEED) {
        outValue->f32 = bits_float(g_cfgPvpMinimumSpeedBits);
        return 1;
    }
    return 0;
}

static int W112_CTL_STDCALL speedfloor_control_set(w112_u32 settingId, const W112_ControlValueV1 *value)
{
    float v;
    if (!value) return 0;

    if (settingId == SETTING_ENABLED) {
        if (value->u32 > 1u) return 0;
        g_cfgEnabled = value->u32;
        return 1;
    }
    if (settingId == SETTING_MINIMUM_SPEED) {
        v = value->f32;
        if (!(v >= CONTROL_MIN_SPEED && v <= CONTROL_MAX_SPEED)) return 0;
        g_cfgMinimumSpeedBits = float_bits(v);
        return 1;
    }
    if (settingId == SETTING_PVP_MINIMUM_SPEED) {
        v = value->f32;
        if (!(v >= CONTROL_MIN_PVP_SPEED && v <= CONTROL_MAX_SPEED)) return 0;
        g_cfgPvpMinimumSpeedBits = float_bits(v);
        return 1;
    }
    return 0;
}

static const W112_ControlModuleV1 g_controlModule = {
    W112_CONTROL_API_V1,
    (w112_u32)sizeof(W112_ControlModuleV1),
    "speedfloor",
    "SpeedFloor",
    VERSION_0_4,
    3u,
    g_controlSettings,
    speedfloor_control_get,
    speedfloor_control_set
};

DLLEXPORT const W112_ControlModuleV1 * W112_CTL_STDCALL W112_Control_GetModuleV1(void)
{
    init_control_descriptor();
    return &g_controlModule;
}

DLLEXPORT u32 STDCALL SpeedFloor_GetVersion(void)
{
    return VERSION_0_4;
}

DLLEXPORT u32 STDCALL SpeedFloor_GetStatus(void)
{
    return g_status;
}

DLLEXPORT u32 STDCALL SpeedFloor_GetApplyCount(void)
{
    return g_applyCount;
}

DLLEXPORT u32 STDCALL SpeedFloor_GetMethod(void)
{
    return METHOD_SAFE_DIRECT_RECALC_ONLY;
}

BOOL32 STDCALL DllMain(void *module, u32 reason, void *reserved)
{
    SetTimerFn setTimer;
    KillTimerFn killTimer;

    (void)module;
    (void)reserved;

    if (reason == DLL_PROCESS_ATTACH) {
        g_status = STATUS_ACTIVE;
        log_event(kEventLoad, 0u, 0u, 0u, 0.0f, 0.0f, 0.0f, 0.0f, 0u);

        setTimer = (SetTimerFn)load_iat_fn(WOW_IAT_SETTIMER);
        if (!setTimer) {
            g_status = STATUS_SETTIMER_MISSING;
            return FALSE32;
        }

        g_timerId = setTimer(0, 0u, TIMER_PERIOD_MS, SpeedFloor_TimerProc);
        if (g_timerId == 0u) {
            g_status = STATUS_SETTIMER_FAILED;
            return FALSE32;
        }
        return TRUE32;
    }

    if (reason == DLL_PROCESS_DETACH) {
        killTimer = (KillTimerFn)load_iat_fn(WOW_IAT_KILLTIMER);
        if (killTimer && g_timerId != 0u)
            killTimer(0, g_timerId);
        g_timerId = 0u;
        g_status = STATUS_DETACHED;
        return TRUE32;
    }

    return TRUE32;
}
