/*
 * WoWMovementCore_5875_v20_AUTOPP_REARONLY_HARDLOS3D_RETRY_CONTROLHUB.c
 * World of Warcraft 1.12.1 build 5875 x86.
 *
 * Thin W112_CONTROL_API_V1 provider layer around the canonical MovementCore v20
 * implementation. The provider reads/writes the exact runtime variables already
 * owned by MovementCore hotkeys; it does not duplicate feature state or logic.
 */
#if !defined(_M_IX86) && !defined(__i386__)
#error This DLL is x86-only.
#endif

#include "../common/W112ControlAPI.h"
#include "WoWMovementCore_5875_v20_AUTOPP_REARONLY_HARDLOS3D_RETRY_V69_BASE.c"

#define MOVEMENTCORE_CONTROL_VERSION 0x00140001u
#define MC_CTL_AUTO_PICK_POCKET      1u
#define MC_CTL_AUTO_OPEN_LOCKPICK    2u
#define MC_CTL_AUTO_GATHER           3u

static W112_ControlSettingV1 g_movementControlSettings[3];
static volatile DWORD g_movementControlDescriptorReady = 0u;

static void init_movement_control_descriptor(void)
{
    W112_ControlSettingV1 *s;
    if (g_movementControlDescriptorReady) return;

    s = &g_movementControlSettings[0];
    s->struct_size = (w112_u32)sizeof(W112_ControlSettingV1);
    s->setting_id = MC_CTL_AUTO_PICK_POCKET;
    s->key = "auto_pick_pocket";
    s->label = "Auto Pick Pocket";
    s->type = W112_CTL_BOOL;
    s->default_value.u32 = 1u;
    s->min_value.u32 = 0u;
    s->max_value.u32 = 1u;
    s->step.u32 = 1u;
    s->flags = W112_CTL_LIVE;
    s->enum_options = 0;
    s->enum_option_count = 0u;

    s = &g_movementControlSettings[1];
    s->struct_size = (w112_u32)sizeof(W112_ControlSettingV1);
    s->setting_id = MC_CTL_AUTO_OPEN_LOCKPICK;
    s->key = "auto_open_lockpick";
    s->label = "Auto Open / Lockpick";
    s->type = W112_CTL_BOOL;
    s->default_value.u32 = 1u;
    s->min_value.u32 = 0u;
    s->max_value.u32 = 1u;
    s->step.u32 = 1u;
    s->flags = W112_CTL_LIVE;
    s->enum_options = 0;
    s->enum_option_count = 0u;

    s = &g_movementControlSettings[2];
    s->struct_size = (w112_u32)sizeof(W112_ControlSettingV1);
    s->setting_id = MC_CTL_AUTO_GATHER;
    s->key = "auto_gather";
    s->label = "Auto Gather";
    s->type = W112_CTL_BOOL;
    s->default_value.u32 = 1u;
    s->min_value.u32 = 0u;
    s->max_value.u32 = 1u;
    s->step.u32 = 1u;
    s->flags = W112_CTL_LIVE;
    s->enum_options = 0;
    s->enum_option_count = 0u;

    g_movementControlDescriptorReady = 1u;
}

static int W112_CTL_STDCALL movement_control_get(w112_u32 settingId, W112_ControlValueV1 *outValue)
{
    if (!outValue) return 0;

    if (settingId == MC_CTL_AUTO_PICK_POCKET) {
        outValue->u32 = g_autoPPEnabled ? 1u : 0u;
        return 1;
    }
    if (settingId == MC_CTL_AUTO_OPEN_LOCKPICK) {
        outValue->u32 = g_autoOpenEnabled ? 1u : 0u;
        return 1;
    }
    if (settingId == MC_CTL_AUTO_GATHER) {
        outValue->u32 = g_gatherEnabled ? 1u : 0u;
        return 1;
    }
    return 0;
}

static int W112_CTL_STDCALL movement_control_set(w112_u32 settingId, const W112_ControlValueV1 *value)
{
    if (!value || value->u32 > 1u) return 0;

    if (settingId == MC_CTL_AUTO_PICK_POCKET) {
        g_autoPPEnabled = value->u32;
        return 1;
    }
    if (settingId == MC_CTL_AUTO_OPEN_LOCKPICK) {
        g_autoOpenEnabled = value->u32;
        return 1;
    }
    if (settingId == MC_CTL_AUTO_GATHER) {
        g_gatherEnabled = value->u32;
        return 1;
    }
    return 0;
}

static const W112_ControlModuleV1 g_movementControlModule = {
    W112_CONTROL_API_V1,
    (w112_u32)sizeof(W112_ControlModuleV1),
    "movementcore",
    "MovementCore",
    MOVEMENTCORE_CONTROL_VERSION,
    3u,
    g_movementControlSettings,
    movement_control_get,
    movement_control_set
};

#if defined(_MSC_VER)
#pragma comment(linker, "/EXPORT:W112_Control_GetModuleV1=_W112_Control_GetModuleV1@0")
#endif

W112_CTL_EXPORT const W112_ControlModuleV1 * W112_CTL_STDCALL W112_Control_GetModuleV1(void)
{
    init_movement_control_descriptor();
    return &g_movementControlModule;
}
