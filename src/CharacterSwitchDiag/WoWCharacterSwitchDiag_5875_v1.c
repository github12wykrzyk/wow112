/*
 * WoWCharacterSwitchDiag 5875 - disabled safety stub.
 *
 * Character/session switching is intentionally disabled on parallel while the
 * login/realm path is considered too fragile for automatic summon workers.
 * This DLL keeps the expected module/export surface so candidate packaging and
 * updater cleanup remain deterministic, but it creates no worker map, installs
 * no timer and cannot issue logout, disconnect, reconnect, character-select or
 * EnterWorld actions.
 */
#if !defined(_M_IX86) && !defined(__i386__)
#error WoWCharacterSwitchDiag requires x86.
#endif

#include <windows.h>
#include "../common/W112ControlAPI.h"

static W112_ControlSettingV1 g_settings[1];
static DWORD g_descReady=0;

static void init_settings(void)
{
    W112_ControlSettingV1 *s;
    if(g_descReady)return;
    s=&g_settings[0];
    s->struct_size=sizeof(*s);
    s->setting_id=1u;
    s->key="disabled";
    s->label="Character switching disabled";
    s->type=W112_CTL_BOOL;
    s->default_value.u32=1u;
    s->min_value.u32=1u;
    s->max_value.u32=1u;
    s->step.u32=1u;
    s->flags=W112_CTL_READ_ONLY|W112_CTL_LIVE;
    s->enum_options=0;
    s->enum_option_count=0u;
    g_descReady=1u;
}

static int W112_CTL_STDCALL getv(w112_u32 id,W112_ControlValueV1 *v)
{
    if(!v||id!=1u)return 0;
    v->u32=1u;
    return 1;
}

static int W112_CTL_STDCALL setv(w112_u32 id,const W112_ControlValueV1 *v)
{
    (void)id;(void)v;
    return 0;
}

static const W112_ControlModuleV1 g_module={
    W112_CONTROL_API_V1,
    sizeof(W112_ControlModuleV1),
    "characterswitchdiag",
    "Summon Switch Worker (DISABLED)",
    0x000F0000u,
    1u,
    g_settings,
    getv,
    setv
};

__declspec(dllexport) const W112_ControlModuleV1* W112_CTL_STDCALL W112_Control_GetModuleV1(void)
{
    init_settings();
    return &g_module;
}

BOOL WINAPI DllMain(HMODULE module,DWORD reason,LPVOID reserved)
{
    (void)reserved;
    if(reason==DLL_PROCESS_ATTACH)DisableThreadLibraryCalls(module);
    return TRUE;
}
