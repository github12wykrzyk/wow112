/*
 * WoWGroundTargetAssist_5875_v1.c
 *
 * Companion TEST module for World of Warcraft 1.12.1 build 5875, Windows x86.
 * New project source (not reconstructed).
 *
 * Purpose:
 *   - when the stock client enters a pure DEST_LOCATION ground-target state
 *     (SPELLMGR flag_word == 0x0040), bind that location directly to the
 *     currently selected target's world XYZ;
 *   - use the client's native BindLocation routine (0x006E60F0), so normal
 *     SpellCastTargets serialization/range validation remains owned by WoW;
 *   - leave every other targeting mode untouched (unit/item/GO/source/mixed);
 *   - if there is no current target or its object/XYZ cannot be validated,
 *     leave the normal green targeting cursor active.
 *
 * Threading:
 *   - a Win32 SetTimer callback is created from DllMain, matching the accepted
 *     AutoPoisons pattern. The callback therefore executes on the game/UI
 *     thread and never calls BindLocation from a background worker.
 *
 * Control:
 *   - W112_CONTROL_API_V1 exposes a live Enabled toggle in WoWControlHub.
 */

#if !defined(_M_IX86) && !defined(__i386__)
#error WoWGroundTargetAssist is for World of Warcraft 1.12.1 build 5875 x86 only.
#endif

#include "../common/W112ControlAPI.h"

#if defined(_MSC_VER)
#define STDCALL   __stdcall
#define FASTCALL  __fastcall
#define DLLEXPORT __declspec(dllexport)
#pragma comment(linker, "/EXPORT:W112_Control_GetModuleV1=_W112_Control_GetModuleV1@0")
#pragma comment(linker, "/EXPORT:GroundTargetAssist_GetVersion=_GroundTargetAssist_GetVersion@0")
#pragma comment(linker, "/EXPORT:GroundTargetAssist_GetStatus=_GroundTargetAssist_GetStatus@0")
#pragma comment(linker, "/EXPORT:GroundTargetAssist_GetCommitCount=_GroundTargetAssist_GetCommitCount@0")
#else
#define STDCALL   __attribute__((stdcall))
#define FASTCALL  __attribute__((fastcall))
#define DLLEXPORT __attribute__((dllexport))
#endif

typedef unsigned char      u8;
typedef unsigned short     u16;
typedef unsigned int       u32;
typedef unsigned long long u64;
typedef signed int         s32;
typedef u32                uptr32;
typedef int                BOOL32;
typedef void              *HWND32;
typedef u32                UINT32;
typedef u32                UINT_PTR32;

#define TRUE32  1
#define FALSE32 0

#define DLL_PROCESS_DETACH 0u
#define DLL_PROCESS_ATTACH 1u

#define VERSION_1_0 0x00010000u
#define TIMER_PERIOD_MS 10u

#define SETTING_ENABLED 1u

#define STATUS_DETACHED              0u
#define STATUS_WAITING               1u
#define STATUS_ACTIVE                2u
#define STATUS_BUILD_MISMATCH        3u
#define STATUS_SETTIMER_MISSING      4u
#define STATUS_SETTIMER_FAILED       5u
#define STATUS_NO_TARGET             6u
#define STATUS_BAD_TARGET_OBJECT     7u
#define STATUS_BAD_TARGET_POSITION   8u

/* Exact WoW.exe 1.12.1 build 5875 addresses. */
#define WOW_IAT_SETTIMER             0x007FF4F4u
#define WOW_IAT_KILLTIMER            0x007FF4F8u
#define FN_GET_OBJECT_BY_GUID        0x00464870u
#define FN_BIND_LOCATION             0x006E60F0u
#define TARGET_GUID_LO_GLOBAL        0x00B4E2D8u
#define TARGET_GUID_HI_GLOBAL        0x00B4E2DCu
#define SPELL_TARGET_FLAG_WORD       0x00CECAC0u
#define SPELLCAST_SPELL_ID           0x00CEAC58u

#define TARGET_FLAG_DEST_LOCATION    0x0040u

#define OBJ_TYPE                     0x0014u
#define OBJ_X                        0x09B8u
#define OBJ_Y                        0x09BCu
#define OBJ_Z                        0x09C0u

#define TYPE_UNIT                    3u
#define TYPE_PLAYER                  4u

typedef void (STDCALL *TimerProc32)(HWND32, UINT32, UINT_PTR32, u32);
typedef UINT_PTR32 (STDCALL *SetTimerFn)(HWND32, UINT_PTR32, UINT32, TimerProc32);
typedef BOOL32 (STDCALL *KillTimerFn)(HWND32, UINT_PTR32);
typedef u32 (FASTCALL *GetObjectByGuidFn)(u64 guid);
typedef void (FASTCALL *BindLocationFn)(void *pos);

struct Vec3 {
    float x;
    float y;
    float z;
};

static volatile UINT_PTR32 g_timerId = 0u;
static volatile u32 g_status = STATUS_DETACHED;
static volatile u32 g_commitCount = 0u;
static volatile u32 g_tickCount = 0u;
static volatile u32 g_cfgEnabled = 1u;

static W112_ControlSettingV1 g_controlSettings[1];
static volatile u32 g_controlDescriptorReady = 0u;

int _fltused = 0;

static u32 read_u32(uptr32 address)
{
    return *(volatile u32 *)(uptr32)address;
}

static u16 read_u16(uptr32 address)
{
    return *(volatile u16 *)(uptr32)address;
}

static float read_f32(uptr32 address)
{
    return *(volatile float *)(uptr32)address;
}

static void *load_iat_fn(uptr32 slot)
{
    return (void *)(uptr32)read_u32(slot);
}

static int bytes_match(uptr32 address, const u8 *sig, u32 count)
{
    volatile const u8 *p = (volatile const u8 *)(uptr32)address;
    u32 i;
    for (i = 0u; i < count; ++i)
        if (p[i] != sig[i]) return 0;
    return 1;
}

/*
 * This exact prologue is already verified by the active PlayerESP lineage.
 * It is enough to fail closed on a wrong WoW build before this module calls
 * any spell/object primitive.
 */
static int exact_build_guard_ok(void)
{
    static const u8 getObjectSig[] = {
        0x55,0x8B,0xEC,0x8B,0x45,0x08,0x8B,0x4D,0x0C,0x8B,0xD0,0x0B,0xD1
    };
    if (!bytes_match(FN_GET_OBJECT_BY_GUID, getObjectSig, (u32)sizeof(getObjectSig)))
        return 0;

    /* BindLocation must look like code, not an erased/unmapped placeholder.
       The exact-build GetObjectByGuid gate above is the primary build identity. */
    {
        volatile const u8 *p = (volatile const u8 *)(uptr32)FN_BIND_LOCATION;
        if ((p[0] == 0x00u && p[1] == 0x00u) ||
            (p[0] == 0xCCu && p[1] == 0xCCu))
            return 0;
    }
    return 1;
}

static int finite_coord(float v)
{
    union { float f; u32 u; } x;
    x.f = v;
    return (x.u & 0x7F800000u) != 0x7F800000u;
}

static int plausible_coord(float v)
{
    if (!finite_coord(v)) return 0;
    return (v > -200000.0f && v < 200000.0f) ? 1 : 0;
}

static u32 current_target_object(void)
{
    u32 lo = read_u32(TARGET_GUID_LO_GLOBAL);
    u32 hi = read_u32(TARGET_GUID_HI_GLOBAL);
    u64 guid;
    GetObjectByGuidFn fn;

    if (!lo && !hi) return 0u;
    guid = ((u64)hi << 32) | (u64)lo;
    fn = (GetObjectByGuidFn)(uptr32)FN_GET_OBJECT_BY_GUID;
    return fn(guid);
}

static int target_position(struct Vec3 *out)
{
    u32 obj;
    u32 typeId;
    if (!out) return 0;

    obj = current_target_object();
    if (!obj || (obj & 3u) != 0u || obj < 0x00010000u || obj > 0x7FFF0000u) {
        g_status = STATUS_NO_TARGET;
        return 0;
    }

    typeId = read_u32(obj + OBJ_TYPE);
    if (typeId != TYPE_UNIT && typeId != TYPE_PLAYER) {
        g_status = STATUS_BAD_TARGET_OBJECT;
        return 0;
    }

    out->x = read_f32(obj + OBJ_X);
    out->y = read_f32(obj + OBJ_Y);
    out->z = read_f32(obj + OBJ_Z);
    if (!plausible_coord(out->x) || !plausible_coord(out->y) || !plausible_coord(out->z)) {
        g_status = STATUS_BAD_TARGET_POSITION;
        return 0;
    }
    return 1;
}

static void try_commit_ground_target(void)
{
    struct Vec3 pos;
    BindLocationFn bindLocation;

    if (!g_cfgEnabled) {
        g_status = STATUS_WAITING;
        return;
    }

    /* Strict equality is intentional. We only consume a pure destination
       reticle. Pick Lock, poisons, unit targeting and mixed/source targeting
       keep their stock behavior. */
    if (read_u16(SPELL_TARGET_FLAG_WORD) != (u16)TARGET_FLAG_DEST_LOCATION) {
        g_status = STATUS_ACTIVE;
        return;
    }

    /* A valid pending spell/item cast must still own SPELLCAST. */
    if (read_u32(SPELLCAST_SPELL_ID) == 0u) {
        g_status = STATUS_WAITING;
        return;
    }

    if (!target_position(&pos))
        return;

    /* Re-check immediately before the native commit in case another handler
       resolved/cancelled targeting earlier in this UI tick. */
    if (read_u16(SPELL_TARGET_FLAG_WORD) != (u16)TARGET_FLAG_DEST_LOCATION)
        return;

    bindLocation = (BindLocationFn)(uptr32)FN_BIND_LOCATION;
    bindLocation(&pos);
    ++g_commitCount;
    g_status = STATUS_ACTIVE;
}

static void STDCALL GroundTarget_TimerProc(HWND32 hwnd, UINT32 msg, UINT_PTR32 timerId, u32 time)
{
    (void)hwnd; (void)msg; (void)timerId; (void)time;
    ++g_tickCount;

    if (!exact_build_guard_ok()) {
        g_status = STATUS_BUILD_MISMATCH;
        return;
    }

    try_commit_ground_target();
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

    g_controlDescriptorReady = 1u;
}

static int W112_CTL_STDCALL groundtarget_control_get(w112_u32 settingId, W112_ControlValueV1 *outValue)
{
    if (!outValue) return 0;
    if (settingId == SETTING_ENABLED) {
        outValue->u32 = g_cfgEnabled ? 1u : 0u;
        return 1;
    }
    return 0;
}

static int W112_CTL_STDCALL groundtarget_control_set(w112_u32 settingId, const W112_ControlValueV1 *value)
{
    if (!value) return 0;
    if (settingId == SETTING_ENABLED) {
        if (value->u32 > 1u) return 0;
        g_cfgEnabled = value->u32;
        return 1;
    }
    return 0;
}

static const W112_ControlModuleV1 g_controlModule = {
    W112_CONTROL_API_V1,
    (w112_u32)sizeof(W112_ControlModuleV1),
    "groundtargetassist",
    "GroundTarget Assist",
    VERSION_1_0,
    1u,
    g_controlSettings,
    groundtarget_control_get,
    groundtarget_control_set
};

DLLEXPORT const W112_ControlModuleV1 * W112_CTL_STDCALL W112_Control_GetModuleV1(void)
{
    init_control_descriptor();
    return &g_controlModule;
}

DLLEXPORT u32 STDCALL GroundTargetAssist_GetVersion(void)
{
    return VERSION_1_0;
}

DLLEXPORT u32 STDCALL GroundTargetAssist_GetStatus(void)
{
    return g_status;
}

DLLEXPORT u32 STDCALL GroundTargetAssist_GetCommitCount(void)
{
    return g_commitCount;
}

BOOL32 STDCALL DllMain(void *module, u32 reason, void *reserved)
{
    SetTimerFn setTimer;
    KillTimerFn killTimer;
    (void)module; (void)reserved;

    if (reason == DLL_PROCESS_ATTACH) {
        g_status = STATUS_WAITING;
        g_commitCount = 0u;
        g_tickCount = 0u;

        if (!exact_build_guard_ok()) {
            g_status = STATUS_BUILD_MISMATCH;
            return TRUE32; /* load inert rather than destabilize the client */
        }

        setTimer = (SetTimerFn)load_iat_fn(WOW_IAT_SETTIMER);
        if (!setTimer) {
            g_status = STATUS_SETTIMER_MISSING;
            return TRUE32;
        }

        g_timerId = setTimer(0, 0u, TIMER_PERIOD_MS, GroundTarget_TimerProc);
        if (!g_timerId) {
            g_status = STATUS_SETTIMER_FAILED;
            return TRUE32;
        }
        return TRUE32;
    }

    if (reason == DLL_PROCESS_DETACH) {
        killTimer = (KillTimerFn)load_iat_fn(WOW_IAT_KILLTIMER);
        if (killTimer && g_timerId)
            killTimer(0, g_timerId);
        g_timerId = 0u;
        g_status = STATUS_DETACHED;
        return TRUE32;
    }

    return TRUE32;
}
