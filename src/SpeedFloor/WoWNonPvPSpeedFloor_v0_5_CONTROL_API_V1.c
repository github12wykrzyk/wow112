/*
 * WoWNonPvPSpeedFloor_v0_5_CONTROL_API_V1.c
 *
 * Candidate continuation of the active reconstructed SpeedFloor lineage.
 * Target: World of Warcraft 1.12.1 build 5875, Windows x86.
 *
 * The stable v0.4 gameplay path is intentionally preserved:
 *   - 5 ms timer
 *   - 7.10 compile-time default floor
 *   - floor disabled only while the selected target is a hostile player
 *   - direct run-speed write followed by the verified 0x007C5C20 recalc
 *
 * V1 adds only an explicit W112_CONTROL_API_V1 surface. WoWControlHub is
 * optional: this DLL has no import or hard dependency on the hub.
 */

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
typedef unsigned int   u32;
typedef signed int     s32;
typedef u32            uptr32;
typedef int            BOOL32;
typedef void          *HWND32;
typedef u32            UINT32;
typedef u32            UINT_PTR32;

#define TRUE32  1
#define FALSE32 0
#define DLL_PROCESS_DETACH 0u
#define DLL_PROCESS_ATTACH 1u

#define WOW_OBJECT_MANAGER_PTR 0x00B41414u
#define WOW_SELECTED_GUID_LO   0x00B4E2D8u
#define WOW_SELECTED_GUID_HI   0x00B4E2DCu
#define WOW_UNIT_REACTION_FN   0x006061E0u
#define WOW_SPEED_RECALC_FN    0x007C5C20u

/* Verified WoW.exe IAT slots inherited from the active v0.4 lineage. */
#define WOW_IAT_SETTIMER  0x007FF4F4u
#define WOW_IAT_KILLTIMER 0x007FF4F8u

#define OM_FIRST_OBJECT_OFF     0x00ACu
#define OM_PLAYER_GUID_LO_OFF   0x00C0u
#define OM_PLAYER_GUID_HI_OFF   0x00C4u
#define OBJ_TYPE_ID_OFF         0x0014u
#define OBJ_GUID_LO_OFF         0x0030u
#define OBJ_GUID_HI_OFF         0x0034u
#define OBJ_NEXT_OFF            0x003Cu
#define TYPEID_PLAYER           4u

#define PLAYER_MOVEMENT_RECALC_THIS_OFF 0x09A8u
#define PLAYER_CURRENT_SPEED_OFF        0x0A2Cu
#define PLAYER_RUN_SPEED_OFF            0x0A34u

#define SPEED_MIN_VALID       0.01f
#define DEFAULT_SPEED_FLOOR   7.10f
#define CONTROL_MIN_SPEED     1.00f
#define CONTROL_MAX_SPEED    14.00f
#define CONTROL_SPEED_STEP    0.10f
#define TIMER_PERIOD_MS       5u
#define MAX_OBJECT_STEPS      0x0FFFu

#define STATUS_DETACHED         0u
#define STATUS_ACTIVE           1u
#define STATUS_SETTIMER_MISSING 2u
#define STATUS_SETTIMER_FAILED  3u
#define METHOD_SAFE_DIRECT_RECALC_ONLY 4u
#define VERSION_0_4 0x00040000u

#define SETTING_ENABLED             1u
#define SETTING_MINIMUM_SPEED       2u
#define SETTING_DISABLE_ON_HOSTILE  3u

typedef void (STDCALL *TimerProc32)(HWND32, UINT32, UINT_PTR32, u32);
typedef UINT_PTR32 (STDCALL *SetTimerFn)(HWND32, UINT_PTR32, UINT32, TimerProc32);
typedef BOOL32 (STDCALL *KillTimerFn)(HWND32, UINT_PTR32);
typedef s32 (THISCALL *UnitReactionFn)(uptr32 selfObj, uptr32 targetObj);
typedef void (THISCALL *SpeedRecalcFn)(void *movementThis, u32 zero);

static volatile u32 g_status = STATUS_DETACHED;
static volatile u32 g_applyCount = 0u;
static volatile UINT_PTR32 g_timerId = 0u;

/* Runtime settings. Their initial values exactly match the pre-ControlHub behavior. */
static volatile u32 g_cfgEnabled = 1u;
static volatile u32 g_cfgMinimumSpeedBits = 0x40E33333u; /* 7.10f */
static volatile u32 g_cfgDisableOnHostilePlayer = 1u;

static W112_ControlSettingV1 g_controlSettings[3];
static volatile u32 g_controlDescriptorReady = 0u;

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

static u32 float_bits(float value)
{
    union { float f; u32 u; } x;
    x.f = value;
    return x.u;
}

static float bits_float(u32 value)
{
    union { float f; u32 u; } x;
    x.u = value;
    return x.f;
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
    return (reaction >= 1 && reaction <= 3) ? 1u : 0u;
}

static void recalc_speed(uptr32 player)
{
    SpeedRecalcFn fn = (SpeedRecalcFn)(uptr32)WOW_SPEED_RECALC_FN;
    fn((void *)(uptr32)(player + PLAYER_MOVEMENT_RECALC_THIS_OFF), 0u);
}

static void STDCALL SpeedFloor_TimerProc(HWND32 hwnd, UINT32 msg, UINT_PTR32 timerId, u32 tickParam)
{
    uptr32 player;
    float runBefore;
    float floorValue;
    u32 enabled;
    u32 disableOnHostile;

    (void)hwnd;
    (void)msg;
    (void)timerId;
    (void)tickParam;

    enabled = g_cfgEnabled;
    if (!enabled) return;

    player = find_player_object();
    if (!player) return;

    disableOnHostile = g_cfgDisableOnHostilePlayer;
    if (disableOnHostile && current_target_is_hostile_player(player))
        return;

    runBefore = read_f32(player + PLAYER_RUN_SPEED_OFF);
    floorValue = bits_float(g_cfgMinimumSpeedBits);

    if (runBefore > SPEED_MIN_VALID && runBefore < floorValue) {
        write_u32(player + PLAYER_RUN_SPEED_OFF, float_bits(floorValue));
        recalc_speed(player);
        ++g_applyCount;
    }
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
    s->default_value.f32 = DEFAULT_SPEED_FLOOR;
    s->min_value.f32 = CONTROL_MIN_SPEED;
    s->max_value.f32 = CONTROL_MAX_SPEED;
    s->step.f32 = CONTROL_SPEED_STEP;
    s->flags = W112_CTL_LIVE;
    s->enum_options = 0;
    s->enum_option_count = 0u;

    s = &g_controlSettings[2];
    s->struct_size = (w112_u32)sizeof(W112_ControlSettingV1);
    s->setting_id = SETTING_DISABLE_ON_HOSTILE;
    s->key = "disable_on_hostile_player";
    s->label = "Disable on hostile player";
    s->type = W112_CTL_BOOL;
    s->default_value.u32 = 1u;
    s->min_value.u32 = 0u;
    s->max_value.u32 = 1u;
    s->step.u32 = 1u;
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
    if (settingId == SETTING_DISABLE_ON_HOSTILE) {
        outValue->u32 = g_cfgDisableOnHostilePlayer ? 1u : 0u;
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
    if (settingId == SETTING_DISABLE_ON_HOSTILE) {
        if (value->u32 > 1u) return 0;
        g_cfgDisableOnHostilePlayer = value->u32;
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
