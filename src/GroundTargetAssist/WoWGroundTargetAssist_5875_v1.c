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
 *   - optionally predict a moving target's future XY from a short rolling
 *     history of actual object positions; this works with strafing/backpedal
 *     instead of assuming movement follows facing;
 *   - use the client's native BindLocation routine (0x006E60F0), so normal
 *     SpellCastTargets serialization/range validation remains owned by WoW;
 *   - leave every other targeting mode untouched (unit/item/GO/source/mixed);
 *   - if there is no current target or its object/XYZ cannot be validated,
 *     leave the normal green targeting cursor active.
 *
 * Prediction:
 *   - sample the current target every 50 ms on the UI thread;
 *   - estimate horizontal velocity from roughly 120-400 ms of history;
 *   - compare it with a recent ~100 ms vector to reduce lead on hard turns;
 *   - suppress lead when movement becomes stale or a sample implies an
 *     implausible teleport/speed spike;
 *   - clamp the final predicted displacement to a configurable maximum.
 *
 * Threading:
 *   - a Win32 SetTimer callback is created from DllMain, matching the accepted
 *     AutoPoisons pattern. The callback therefore executes on the game/UI
 *     thread and never calls BindLocation from a background worker.
 *
 * Control:
 *   - W112_CONTROL_API_V1 exposes Enabled, Prediction, Lead ms and Max lead yd
 *     live to WoWControlHub.
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
#pragma comment(linker, "/EXPORT:GroundTargetAssist_GetPredictionCount=_GroundTargetAssist_GetPredictionCount@0")
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

#define VERSION_1_1 0x00010100u
#define TIMER_PERIOD_MS 10u

#define SETTING_ENABLED           1u
#define SETTING_PREDICTION        2u
#define SETTING_LEAD_MS           3u
#define SETTING_MAX_LEAD_YD       4u

#define LEAD_MIN_MS               0
#define LEAD_MAX_MS               1500
#define LEAD_STEP_MS              50
#define LEAD_DEFAULT_MS           900
#define MAX_LEAD_MIN_YD           0.0f
#define MAX_LEAD_MAX_YD           15.0f
#define MAX_LEAD_STEP_YD          0.5f
#define MAX_LEAD_DEFAULT_YD       10.0f

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
#define OBJMGR_GLOBAL                0x00B41414u
#define TARGET_GUID_LO_GLOBAL        0x00B4E2D8u
#define TARGET_GUID_HI_GLOBAL        0x00B4E2DCu
#define SPELL_TARGET_FLAG_WORD       0x00CECAC0u
#define SPELLCAST_SPELL_ID           0x00CEAC58u

#define TARGET_FLAG_DEST_LOCATION    0x0040u

#define OBJ_TYPE                     0x0014u
#define OBJ_GUID_LO                  0x0030u
#define OBJ_GUID_HI                  0x0034u
#define OBJ_X                        0x09B8u
#define OBJ_Y                        0x09BCu
#define OBJ_Z                        0x09C0u

#define TYPE_UNIT                    3u
#define TYPE_PLAYER                  4u

#define MOTION_SAMPLE_INTERVAL_MS    50u
#define MOTION_HISTORY_CAP           8u
#define MOTION_MIN_SPAN_MS           120u
#define MOTION_MAX_SPAN_MS           500u
#define MOTION_RECENT_MIN_MS         80u
#define MOTION_RECENT_MAX_MS         220u
#define MOTION_STALE_MS              300u
#define MOTION_MOVE_EPS2             0.0025f
#define MOTION_MIN_SPEED2            0.16f
#define MOTION_MAX_SPEED             22.0f
#define MOTION_MAX_SPEED2            (MOTION_MAX_SPEED * MOTION_MAX_SPEED)

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

struct TargetSnapshot {
    u32 guidLo;
    u32 guidHi;
    u32 object;
    u32 typeId;
    struct Vec3 pos;
};

struct MotionSample {
    u32 timeMs;
    struct Vec3 pos;
};

static volatile UINT_PTR32 g_timerId = 0u;
static volatile u32 g_status = STATUS_DETACHED;
static volatile u32 g_commitCount = 0u;
static volatile u32 g_predictionCount = 0u;
static volatile u32 g_tickCount = 0u;

static volatile u32 g_cfgEnabled = 1u;
static volatile u32 g_cfgPrediction = 1u;
static volatile s32 g_cfgLeadMs = LEAD_DEFAULT_MS;
static volatile float g_cfgMaxLeadYd = MAX_LEAD_DEFAULT_YD;

static struct MotionSample g_motion[MOTION_HISTORY_CAP];
static u32 g_motionCount = 0u;
static u32 g_motionGuidLo = 0u;
static u32 g_motionGuidHi = 0u;
static u32 g_lastSampleTime = 0u;
static u32 g_lastMotionTime = 0u;
static u32 g_haveObserved = 0u;
static struct Vec3 g_lastObserved;

static W112_ControlSettingV1 g_controlSettings[4];
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

static float abs_f32(float v)
{
    return v < 0.0f ? -v : v;
}

/* Cheap 2D length approximation, adequate for lead-distance limiting and
   deliberately CRT-free. Error is small relative to the configurable AoE lead. */
static float approx_len2d(float x, float y)
{
    float ax = abs_f32(x);
    float ay = abs_f32(y);
    float hi, lo;
    if (ax >= ay) { hi = ax; lo = ay; }
    else { hi = ay; lo = ax; }
    return hi + lo * 0.375f;
}

static void clear_motion_history(void)
{
    g_motionCount = 0u;
    g_motionGuidLo = 0u;
    g_motionGuidHi = 0u;
    g_lastSampleTime = 0u;
    g_lastMotionTime = 0u;
    g_haveObserved = 0u;
    g_lastObserved.x = g_lastObserved.y = g_lastObserved.z = 0.0f;
}

static void reset_motion_history(u32 guidLo, u32 guidHi)
{
    clear_motion_history();
    g_motionGuidLo = guidLo;
    g_motionGuidHi = guidHi;
}

static int current_target_snapshot(struct TargetSnapshot *out)
{
    u32 lo, hi, mgr, obj, typeId, objLo, objHi;
    u64 guid;
    GetObjectByGuidFn fn;

    if (!out) return 0;

    mgr = read_u32(OBJMGR_GLOBAL);
    if (!mgr || (mgr & 3u) != 0u || mgr < 0x00010000u || mgr > 0x7FFF0000u)
        return 0;

    lo = read_u32(TARGET_GUID_LO_GLOBAL);
    hi = read_u32(TARGET_GUID_HI_GLOBAL);
    if (!lo && !hi) return 0;

    guid = ((u64)hi << 32) | (u64)lo;
    fn = (GetObjectByGuidFn)(uptr32)FN_GET_OBJECT_BY_GUID;
    obj = fn(guid);
    if (!obj || (obj & 3u) != 0u || obj < 0x00010000u || obj > 0x7FFE0000u)
        return 0;

    typeId = read_u32(obj + OBJ_TYPE);
    if (typeId != TYPE_UNIT && typeId != TYPE_PLAYER)
        return 0;

    objLo = read_u32(obj + OBJ_GUID_LO);
    objHi = read_u32(obj + OBJ_GUID_HI);
    if (objLo != lo || objHi != hi)
        return 0;

    out->guidLo = lo;
    out->guidHi = hi;
    out->object = obj;
    out->typeId = typeId;
    out->pos.x = read_f32(obj + OBJ_X);
    out->pos.y = read_f32(obj + OBJ_Y);
    out->pos.z = read_f32(obj + OBJ_Z);

    if (!plausible_coord(out->pos.x) ||
        !plausible_coord(out->pos.y) ||
        !plausible_coord(out->pos.z))
        return 0;

    return 1;
}

static void push_motion_sample(u32 now, const struct Vec3 *pos)
{
    u32 i;
    if (!pos) return;

    if (g_motionCount != 0u &&
        (u32)(now - g_lastSampleTime) < MOTION_SAMPLE_INTERVAL_MS)
        return;

    if (g_motionCount < MOTION_HISTORY_CAP) {
        g_motion[g_motionCount].timeMs = now;
        g_motion[g_motionCount].pos = *pos;
        ++g_motionCount;
    } else {
        for (i = 1u; i < MOTION_HISTORY_CAP; ++i)
            g_motion[i - 1u] = g_motion[i];
        g_motion[MOTION_HISTORY_CAP - 1u].timeMs = now;
        g_motion[MOTION_HISTORY_CAP - 1u].pos = *pos;
    }
    g_lastSampleTime = now;
}

static void update_motion_history(const struct TargetSnapshot *snap, u32 now)
{
    float dx, dy;
    if (!snap) {
        clear_motion_history();
        return;
    }

    if (snap->guidLo != g_motionGuidLo || snap->guidHi != g_motionGuidHi)
        reset_motion_history(snap->guidLo, snap->guidHi);

    if (!g_haveObserved) {
        g_lastObserved = snap->pos;
        g_haveObserved = 1u;
    } else {
        dx = snap->pos.x - g_lastObserved.x;
        dy = snap->pos.y - g_lastObserved.y;
        if (dx * dx + dy * dy >= MOTION_MOVE_EPS2) {
            g_lastObserved = snap->pos;
            g_lastMotionTime = now;
        }
    }

    push_motion_sample(now, &snap->pos);
}

/*
 * Predict only XY. The current unit Z is retained because ground-target casts
 * should stay anchored to the current terrain/object height instead of leading
 * a jump into mid-air.
 */
static int predict_target_position(u32 now, const struct TargetSnapshot *snap, struct Vec3 *out)
{
    const struct MotionSample *oldest;
    const struct MotionSample *recent = 0;
    float vxLong, vyLong, vxRecent, vyRecent, vx, vy;
    float longSpeed2, recentSpeed2, dot, leadScale;
    float leadSec, dx, dy, maxLead, len, scale;
    u32 span, recentSpan, i;

    if (!snap || !out) return 0;
    *out = snap->pos;

    if (!g_cfgPrediction || g_cfgLeadMs <= 0 || g_cfgMaxLeadYd <= 0.0f)
        return 0;
    if (g_motionCount < 3u)
        return 0;
    if (snap->guidLo != g_motionGuidLo || snap->guidHi != g_motionGuidHi)
        return 0;
    if (!g_lastMotionTime || (u32)(now - g_lastMotionTime) > MOTION_STALE_MS)
        return 0;

    oldest = &g_motion[0];
    span = (u32)(now - oldest->timeMs);
    if (span < MOTION_MIN_SPAN_MS || span > MOTION_MAX_SPAN_MS)
        return 0;

    vxLong = (snap->pos.x - oldest->pos.x) * (1000.0f / (float)span);
    vyLong = (snap->pos.y - oldest->pos.y) * (1000.0f / (float)span);
    longSpeed2 = vxLong * vxLong + vyLong * vyLong;
    if (longSpeed2 < MOTION_MIN_SPEED2 || longSpeed2 > MOTION_MAX_SPEED2)
        return 0;

    /* Find the newest history point that still gives ~100 ms of recent motion.
       This reacts to a turn sooner than the stable long-window estimate. */
    for (i = g_motionCount; i > 0u; --i) {
        u32 age = (u32)(now - g_motion[i - 1u].timeMs);
        if (age >= MOTION_RECENT_MIN_MS && age <= MOTION_RECENT_MAX_MS) {
            recent = &g_motion[i - 1u];
            break;
        }
    }

    vx = vxLong;
    vy = vyLong;
    leadScale = 1.0f;

    if (recent) {
        recentSpan = (u32)(now - recent->timeMs);
        if (recentSpan != 0u) {
            vxRecent = (snap->pos.x - recent->pos.x) * (1000.0f / (float)recentSpan);
            vyRecent = (snap->pos.y - recent->pos.y) * (1000.0f / (float)recentSpan);
            recentSpeed2 = vxRecent * vxRecent + vyRecent * vyRecent;

            if (recentSpeed2 < MOTION_MIN_SPEED2) {
                /* Likely braking/stopping: keep direction but lead cautiously. */
                leadScale = 0.25f;
            } else if (recentSpeed2 <= MOTION_MAX_SPEED2) {
                dot = vxLong * vxRecent + vyLong * vyRecent;
                if (dot <= 0.0f) {
                    /* Reversal: trust the recent vector but heavily reduce lead. */
                    vx = vxRecent;
                    vy = vyRecent;
                    leadScale = 0.25f;
                } else if ((dot * dot * 2.0f) <
                           (longSpeed2 * recentSpeed2)) {
                    /* Roughly >45 degree turn. */
                    vx = vxLong * 0.40f + vxRecent * 0.60f;
                    vy = vyLong * 0.40f + vyRecent * 0.60f;
                    leadScale = 0.50f;
                } else {
                    /* Stable direction: bias toward recent movement without
                       letting one short network update dominate. */
                    vx = vxLong * 0.65f + vxRecent * 0.35f;
                    vy = vyLong * 0.65f + vyRecent * 0.35f;
                }
            }
        }
    }

    if (vx * vx + vy * vy > MOTION_MAX_SPEED2)
        return 0;

    leadSec = ((float)g_cfgLeadMs * 0.001f) * leadScale;
    dx = vx * leadSec;
    dy = vy * leadSec;

    maxLead = g_cfgMaxLeadYd;
    len = approx_len2d(dx, dy);
    if (len > maxLead && len > 0.001f) {
        scale = maxLead / len;
        dx *= scale;
        dy *= scale;
    }

    if (dx * dx + dy * dy < 0.0001f)
        return 0;

    out->x = snap->pos.x + dx;
    out->y = snap->pos.y + dy;
    out->z = snap->pos.z;
    return 1;
}

static void try_commit_ground_target(u32 now, const struct TargetSnapshot *snap)
{
    struct Vec3 pos;
    BindLocationFn bindLocation;
    int predicted;

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

    if (!snap) {
        g_status = STATUS_NO_TARGET;
        return;
    }

    pos = snap->pos;
    predicted = predict_target_position(now, snap, &pos);

    /* Re-check immediately before the native commit in case another handler
       resolved/cancelled targeting earlier in this UI tick. */
    if (read_u16(SPELL_TARGET_FLAG_WORD) != (u16)TARGET_FLAG_DEST_LOCATION)
        return;

    bindLocation = (BindLocationFn)(uptr32)FN_BIND_LOCATION;
    bindLocation(&pos);
    ++g_commitCount;
    if (predicted) ++g_predictionCount;
    g_status = STATUS_ACTIVE;
}

static void STDCALL GroundTarget_TimerProc(HWND32 hwnd, UINT32 msg, UINT_PTR32 timerId, u32 time)
{
    struct TargetSnapshot snap;
    int haveTarget;
    (void)hwnd; (void)msg; (void)timerId;
    ++g_tickCount;

    if (!exact_build_guard_ok()) {
        g_status = STATUS_BUILD_MISMATCH;
        clear_motion_history();
        return;
    }

    /* Sample continuously, not only after the reticle appears, so a dynamite
       use has a ready velocity estimate on its very first targeting tick. */
    haveTarget = current_target_snapshot(&snap);
    if (haveTarget)
        update_motion_history(&snap, time);
    else
        clear_motion_history();

    try_commit_ground_target(time, haveTarget ? &snap : 0);
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
    s->setting_id = SETTING_PREDICTION;
    s->key = "prediction";
    s->label = "Prediction";
    s->type = W112_CTL_BOOL;
    s->default_value.u32 = 1u;
    s->min_value.u32 = 0u;
    s->max_value.u32 = 1u;
    s->step.u32 = 1u;
    s->flags = W112_CTL_LIVE;
    s->enum_options = 0;
    s->enum_option_count = 0u;

    s = &g_controlSettings[2];
    s->struct_size = (w112_u32)sizeof(W112_ControlSettingV1);
    s->setting_id = SETTING_LEAD_MS;
    s->key = "lead_ms";
    s->label = "Lead (ms)";
    s->type = W112_CTL_INT;
    s->default_value.i32 = LEAD_DEFAULT_MS;
    s->min_value.i32 = LEAD_MIN_MS;
    s->max_value.i32 = LEAD_MAX_MS;
    s->step.i32 = LEAD_STEP_MS;
    s->flags = W112_CTL_LIVE;
    s->enum_options = 0;
    s->enum_option_count = 0u;

    s = &g_controlSettings[3];
    s->struct_size = (w112_u32)sizeof(W112_ControlSettingV1);
    s->setting_id = SETTING_MAX_LEAD_YD;
    s->key = "max_lead_yd";
    s->label = "Max lead (yd)";
    s->type = W112_CTL_FLOAT;
    s->default_value.f32 = MAX_LEAD_DEFAULT_YD;
    s->min_value.f32 = MAX_LEAD_MIN_YD;
    s->max_value.f32 = MAX_LEAD_MAX_YD;
    s->step.f32 = MAX_LEAD_STEP_YD;
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
    if (settingId == SETTING_PREDICTION) {
        outValue->u32 = g_cfgPrediction ? 1u : 0u;
        return 1;
    }
    if (settingId == SETTING_LEAD_MS) {
        outValue->i32 = g_cfgLeadMs;
        return 1;
    }
    if (settingId == SETTING_MAX_LEAD_YD) {
        outValue->f32 = g_cfgMaxLeadYd;
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
    if (settingId == SETTING_PREDICTION) {
        if (value->u32 > 1u) return 0;
        g_cfgPrediction = value->u32;
        return 1;
    }
    if (settingId == SETTING_LEAD_MS) {
        if (value->i32 < LEAD_MIN_MS || value->i32 > LEAD_MAX_MS) return 0;
        g_cfgLeadMs = value->i32;
        return 1;
    }
    if (settingId == SETTING_MAX_LEAD_YD) {
        if (value->f32 < MAX_LEAD_MIN_YD || value->f32 > MAX_LEAD_MAX_YD) return 0;
        g_cfgMaxLeadYd = value->f32;
        return 1;
    }
    return 0;
}

static const W112_ControlModuleV1 g_controlModule = {
    W112_CONTROL_API_V1,
    (w112_u32)sizeof(W112_ControlModuleV1),
    "groundtargetassist",
    "GroundTarget Assist",
    VERSION_1_1,
    4u,
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
    return VERSION_1_1;
}

DLLEXPORT u32 STDCALL GroundTargetAssist_GetStatus(void)
{
    return g_status;
}

DLLEXPORT u32 STDCALL GroundTargetAssist_GetCommitCount(void)
{
    return g_commitCount;
}

DLLEXPORT u32 STDCALL GroundTargetAssist_GetPredictionCount(void)
{
    return g_predictionCount;
}

BOOL32 STDCALL DllMain(void *module, u32 reason, void *reserved)
{
    SetTimerFn setTimer;
    KillTimerFn killTimer;
    (void)module; (void)reserved;

    if (reason == DLL_PROCESS_ATTACH) {
        g_status = STATUS_WAITING;
        g_commitCount = 0u;
        g_predictionCount = 0u;
        g_tickCount = 0u;
        clear_motion_history();

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
        clear_motion_history();
        g_status = STATUS_DETACHED;
        return TRUE32;
    }

    return TRUE32;
}
