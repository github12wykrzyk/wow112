/*
 * WoWAutoPoisons_5875_v1.c
 *
 * Automatic rogue weapon-poison maintenance for World of Warcraft 1.12.1
 * build 5875, Windows x86. This is new project source, not reconstructed code.
 *
 * Design:
 *   - a Win32 timer callback runs on the game/UI thread;
 *   - the build-5875 FrameScript executor is signature-guarded before use;
 *   - world readiness is checked inside guarded Vanilla Lua instead of walking
 *     Object Manager pointers during login/logout/BG transition windows;
 *   - Lua uses only Vanilla-era API to inspect temporary weapon enchants,
 *     locate the highest available rank of the selected poison and apply it;
 *   - before touching inventory slot 16/17, the script verifies that using the
 *     poison actually entered spell-targeting mode, preventing the classic
 *     failure mode where a weapon is accidentally picked up while mounted or
 *     otherwise unable to use the poison;
 *   - combat, movement, occupied cursor and existing spell-targeting states are skipped;
 *   - W112_CONTROL_API_V1 exposes all user-facing configuration live to
 *     WoWControlHub.
 */

#if !defined(_M_IX86) && !defined(__i386__)
#error WoWAutoPoisons is for World of Warcraft 1.12.1 build 5875 x86 only.
#endif

#include "../common/W112ControlAPI.h"

#if defined(_MSC_VER)
#define STDCALL   __stdcall
#define FASTCALL  __fastcall
#define DLLEXPORT __declspec(dllexport)
#pragma comment(linker, "/EXPORT:W112_Control_GetModuleV1=_W112_Control_GetModuleV1@0")
#else
#define STDCALL   __attribute__((stdcall))
#define FASTCALL  __attribute__((fastcall))
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

/*
 * FrameScript_Execute build-5875 entry point. It is guarded by the exact
 * prologue before every bootstrap attempt; mismatch means no Lua call.
 */
#define WOW_FRAMESCRIPT_EXECUTE      0x00704CD0u

/* Hardcoded WoW.exe IAT slots already used by the accepted SpeedFloor lineage. */
#define WOW_IAT_SETTIMER             0x007FF4F4u
#define WOW_IAT_KILLTIMER            0x007FF4F8u

#define TIMER_PERIOD_MS              500u
#define VERSION_1_0                  0x00010000u

#define SETTING_ENABLED              1u
#define SETTING_MAIN_HAND_POISON     2u
#define SETTING_OFF_HAND_POISON      3u
#define SETTING_REFRESH_SECONDS      4u

#define POISON_OFF                   0
#define POISON_INSTANT               1
#define POISON_DEADLY                2
#define POISON_CRIPPLING             3
#define POISON_MIND_NUMBING          4
#define POISON_WOUND                 5

#define REFRESH_MIN_SECONDS          0
#define REFRESH_MAX_SECONDS          600
#define REFRESH_STEP_SECONDS         30
#define REFRESH_DEFAULT_SECONDS      60

#define STATUS_DETACHED              0u
#define STATUS_WAITING_WORLD         1u
#define STATUS_ACTIVE                2u
#define STATUS_FRAMESCRIPT_MISMATCH  3u
#define STATUS_BOOTSTRAP_FAILED      4u
#define STATUS_SETTIMER_MISSING      5u
#define STATUS_SETTIMER_FAILED       6u

typedef void (STDCALL *TimerProc32)(HWND32, UINT32, UINT_PTR32, u32);
typedef UINT_PTR32 (STDCALL *SetTimerFn)(HWND32, UINT_PTR32, UINT32, TimerProc32);
typedef BOOL32 (STDCALL *KillTimerFn)(HWND32, UINT_PTR32);
typedef BOOL32 (FASTCALL *FrameScriptExecuteFn)(const char *script, const char *scriptName);

static volatile u32 g_status = STATUS_DETACHED;
static volatile UINT_PTR32 g_timerId = 0u;
static volatile u32 g_luaReady = 0u;
static volatile u32 g_tickCount = 0u;

/* Defaults are immediately useful but remain fully live-configurable. */
static volatile u32 g_cfgEnabled = 1u;
static volatile s32 g_cfgMainHand = POISON_INSTANT;
static volatile s32 g_cfgOffHand = POISON_DEADLY;
static volatile s32 g_cfgRefreshSeconds = REFRESH_DEFAULT_SECONDS;

static W112_ControlSettingV1 g_controlSettings[4];
static volatile u32 g_controlDescriptorReady = 0u;

static const W112_ControlEnumOptionV1 g_poisonOptions[] = {
    { POISON_OFF,          "Off" },
    { POISON_INSTANT,      "Instant" },
    { POISON_DEADLY,       "Deadly" },
    { POISON_CRIPPLING,    "Crippling" },
    { POISON_MIND_NUMBING, "Mind-numbing" },
    { POISON_WOUND,        "Wound" }
};

static const char kScriptName[] = "W112 AutoPoisons";

/*
 * Vanilla poison item ranks, ordered from low to high. The Lua helper scans
 * each list backwards so the highest rank present in bags wins automatically.
 * The top-level guard is intentionally idempotent: executing this bootstrap
 * every timer tick safely recreates W112AP after Lua-state/world transitions.
 *
 * Vanilla 1.12 has no stock IsPlayerMoving/GetUnitSpeed API. Movement is
 * therefore sampled through GetPlayerMapPosition. If coordinates cannot be
 * made reliable (for example on an unmapped instance map), the guard fails
 * closed and AutoPoisons waits rather than risking an application in motion.
 */
static const char kBootstrapLua[] =
"if type(UnitExists)=='function' and UnitExists('player') and not W112AP then "
"W112AP={last=0,pmh=-1,poh=-1,pen=0,mx=nil,my=nil,moveUntil=0};"
"W112AP.ids={"
"[1]={6947,6949,6950,8926,8927,8928},"
"[2]={2892,2893,8984,8985,20844},"
"[3]={3775,3776},"
"[4]={5237,6951,9186},"
"[5]={10918,10920,10921,10922}};"
"function W112AP_Find(k) "
"local a=W112AP.ids[k];if not a then return end;"
"for r=table.getn(a),1,-1 do local want=a[r];"
"for b=0,4 do for s=1,GetContainerNumSlots(b) do "
"local l=GetContainerItemLink(b,s);"
"if l then local _,_,id=string.find(l,'item:(%d+)');"
"if id and tonumber(id)==want then return b,s end end end end end end;"
"function W112AP_Moving(t) "
"if type(GetPlayerMapPosition)~='function' then W112AP.moveUntil=t+1;return 1 end;"
"local x,y=GetPlayerMapPosition('player');"
"if (not x) or (not y) or (x==0 and y==0) then "
"local shown=(WorldMapFrame and WorldMapFrame.IsVisible and WorldMapFrame:IsVisible());"
"if type(SetMapToCurrentZone)=='function' and not shown then "
"SetMapToCurrentZone();x,y=GetPlayerMapPosition('player');end end;"
"if (not x) or (not y) or (x==0 and y==0) then "
"W112AP.mx=nil;W112AP.my=nil;W112AP.moveUntil=t+1;return 1 end;"
"if not W112AP.mx or not W112AP.my then "
"W112AP.mx=x;W112AP.my=y;W112AP.moveUntil=t+1;return 1 end;"
"local dx=x-W112AP.mx;local dy=y-W112AP.my;W112AP.mx=x;W112AP.my=y;"
"if dx*dx+dy*dy>0.0000000025 then W112AP.moveUntil=t+1;return 1 end;"
"if W112AP.moveUntil and t<W112AP.moveUntil then return 1 end;return 0 end;"
"function W112AP_Apply(slot,k) "
"if CursorHasItem() or SpellIsTargeting() then return -1 end;"
"local b,s=W112AP_Find(k);if not s then return 0 end;"
"UseContainerItem(b,s);"
"if not SpellIsTargeting() then ClearCursor();return -1 end;"
"PickupInventoryItem(slot);"
"if SpellIsTargeting() then SpellStopTargeting();ClearCursor();return -1 end;"
"ReplaceEnchant();ClearCursor();return 1 end;"
"function W112AP_Tick(en,mh,oh,th) "
"if en~=1 then W112AP.pen=0;W112AP.mx=nil;W112AP.my=nil;W112AP.moveUntil=0;return end;"
"if CastingBarFrame and (CastingBarFrame.casting or CastingBarFrame.channeling) then return end;"
"if UnitAffectingCombat('player') then return end;"
"if CursorHasItem() or SpellIsTargeting() then return end;"
"local t=GetTime();if W112AP_Moving(t)==1 then return end;"
"if W112AP.last and t-W112AP.last<4 then return end;"
"local hm,em,cm,ho,eo,co=GetWeaponEnchantInfo();"
"local fm=(W112AP.pmh~=mh) or (W112AP.pen~=1);"
"local fo=(W112AP.poh~=oh) or (W112AP.pen~=1);W112AP.pen=1;"
"if mh==0 then W112AP.pmh=0 elseif GetInventoryItemLink('player',16) and "
"(fm or not hm or (em and em<=th*1000)) then W112AP.pmh=mh;"
"local r=W112AP_Apply(16,mh);if r~=0 then W112AP.last=t;return end "
"else W112AP.pmh=mh end;"
"if oh==0 then W112AP.poh=0 elseif GetInventoryItemLink('player',17) and "
"(fo or not ho or (eo and eo<=th*1000)) then W112AP.poh=oh;"
"local r=W112AP_Apply(17,oh);if r~=0 then W112AP.last=t;return end "
"else W112AP.poh=oh end end end";

int _fltused = 0;

static u32 read_u32(uptr32 address)
{
    return *(volatile u32 *)(uptr32)address;
}

static void *load_iat_fn(uptr32 slot)
{
    return (void *)(uptr32)read_u32(slot);
}

static int framescript_signature_ok(void)
{
    static const u8 sig[] = { 0x56,0x6A,0x00,0x8B,0xF1,0x52,0x56,0xE8 };
    volatile const u8 *p = (volatile const u8 *)(uptr32)WOW_FRAMESCRIPT_EXECUTE;
    u32 i;
    for (i = 0u; i < (u32)sizeof(sig); ++i)
        if (p[i] != sig[i]) return 0;
    return 1;
}

static int execute_lua(const char *script)
{
    FrameScriptExecuteFn fn;
    if (!framescript_signature_ok()) return 0;
    fn = (FrameScriptExecuteFn)(uptr32)WOW_FRAMESCRIPT_EXECUTE;
    return fn(script, kScriptName) ? 1 : 0;
}

static char *append_str(char *p, const char *s)
{
    while (*s) *p++ = *s++;
    return p;
}

static char *append_u32(char *p, u32 v)
{
    char tmp[16];
    u32 n = 0u;
    if (!v) { *p++ = '0'; return p; }
    while (v && n < (u32)sizeof(tmp)) {
        u32 q = v / 10u;
        tmp[n++] = (char)('0' + (v - q * 10u));
        v = q;
    }
    while (n) *p++ = tmp[--n];
    return p;
}

static void build_tick_script(char out[160])
{
    char *p = out;
    p = append_str(p, "if type(UnitExists)=='function' and UnitExists('player') and W112AP_Tick then W112AP_Tick(");
    p = append_u32(p, g_cfgEnabled ? 1u : 0u); *p++ = ',';
    p = append_u32(p, (u32)g_cfgMainHand); *p++ = ',';
    p = append_u32(p, (u32)g_cfgOffHand); *p++ = ',';
    p = append_u32(p, (u32)g_cfgRefreshSeconds); *p++ = ')';
    p = append_str(p, " end");
    *p = 0;
}

static void STDCALL AutoPoisons_TimerProc(HWND32 hwnd, UINT32 msg, UINT_PTR32 timerId, u32 time)
{
    char tickScript[160];
    (void)hwnd; (void)msg; (void)timerId; (void)time;
    ++g_tickCount;

    if (!framescript_signature_ok()) {
        g_status = STATUS_FRAMESCRIPT_MISMATCH;
        g_luaReady = 0u;
        return;
    }

    /* Never walk Object Manager pointers here. World/BG transitions can leave
       plausible-looking stale pointers briefly. The Lua bootstrap/tick guards
       are safe on GlueXML/login screens and are idempotent after Lua resets. */
    if (!execute_lua(kBootstrapLua)) {
        g_status = STATUS_WAITING_WORLD;
        g_luaReady = 0u;
        return;
    }
    g_luaReady = 1u;

    build_tick_script(tickScript);
    if (execute_lua(tickScript))
        g_status = STATUS_ACTIVE;
    else {
        g_status = STATUS_BOOTSTRAP_FAILED;
        g_luaReady = 0u;
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
    s->setting_id = SETTING_MAIN_HAND_POISON;
    s->key = "main_hand_poison";
    s->label = "Main-hand poison";
    s->type = W112_CTL_ENUM;
    s->default_value.i32 = POISON_INSTANT;
    s->min_value.i32 = POISON_OFF;
    s->max_value.i32 = POISON_WOUND;
    s->step.i32 = 1;
    s->flags = W112_CTL_LIVE;
    s->enum_options = g_poisonOptions;
    s->enum_option_count = (w112_u32)(sizeof(g_poisonOptions) / sizeof(g_poisonOptions[0]));

    s = &g_controlSettings[2];
    s->struct_size = (w112_u32)sizeof(W112_ControlSettingV1);
    s->setting_id = SETTING_OFF_HAND_POISON;
    s->key = "off_hand_poison";
    s->label = "Off-hand poison";
    s->type = W112_CTL_ENUM;
    s->default_value.i32 = POISON_DEADLY;
    s->min_value.i32 = POISON_OFF;
    s->max_value.i32 = POISON_WOUND;
    s->step.i32 = 1;
    s->flags = W112_CTL_LIVE;
    s->enum_options = g_poisonOptions;
    s->enum_option_count = (w112_u32)(sizeof(g_poisonOptions) / sizeof(g_poisonOptions[0]));

    s = &g_controlSettings[3];
    s->struct_size = (w112_u32)sizeof(W112_ControlSettingV1);
    s->setting_id = SETTING_REFRESH_SECONDS;
    s->key = "refresh_seconds";
    s->label = "Refresh below (sec)";
    s->type = W112_CTL_INT;
    s->default_value.i32 = REFRESH_DEFAULT_SECONDS;
    s->min_value.i32 = REFRESH_MIN_SECONDS;
    s->max_value.i32 = REFRESH_MAX_SECONDS;
    s->step.i32 = REFRESH_STEP_SECONDS;
    s->flags = W112_CTL_LIVE;
    s->enum_options = 0;
    s->enum_option_count = 0u;

    g_controlDescriptorReady = 1u;
}

static int W112_CTL_STDCALL autopoisons_control_get(w112_u32 settingId, W112_ControlValueV1 *outValue)
{
    if (!outValue) return 0;
    if (settingId == SETTING_ENABLED) {
        outValue->u32 = g_cfgEnabled ? 1u : 0u;
        return 1;
    }
    if (settingId == SETTING_MAIN_HAND_POISON) {
        outValue->i32 = g_cfgMainHand;
        return 1;
    }
    if (settingId == SETTING_OFF_HAND_POISON) {
        outValue->i32 = g_cfgOffHand;
        return 1;
    }
    if (settingId == SETTING_REFRESH_SECONDS) {
        outValue->i32 = g_cfgRefreshSeconds;
        return 1;
    }
    return 0;
}

static int W112_CTL_STDCALL autopoisons_control_set(w112_u32 settingId, const W112_ControlValueV1 *value)
{
    if (!value) return 0;
    if (settingId == SETTING_ENABLED) {
        if (value->u32 > 1u) return 0;
        g_cfgEnabled = value->u32;
        return 1;
    }
    if (settingId == SETTING_MAIN_HAND_POISON) {
        if (value->i32 < POISON_OFF || value->i32 > POISON_WOUND) return 0;
        g_cfgMainHand = value->i32;
        return 1;
    }
    if (settingId == SETTING_OFF_HAND_POISON) {
        if (value->i32 < POISON_OFF || value->i32 > POISON_WOUND) return 0;
        g_cfgOffHand = value->i32;
        return 1;
    }
    if (settingId == SETTING_REFRESH_SECONDS) {
        if (value->i32 < REFRESH_MIN_SECONDS || value->i32 > REFRESH_MAX_SECONDS) return 0;
        g_cfgRefreshSeconds = value->i32;
        return 1;
    }
    return 0;
}

static const W112_ControlModuleV1 g_controlModule = {
    W112_CONTROL_API_V1,
    (w112_u32)sizeof(W112_ControlModuleV1),
    "autopoisons",
    "AutoPoisons",
    VERSION_1_0,
    4u,
    g_controlSettings,
    autopoisons_control_get,
    autopoisons_control_set
};

DLLEXPORT const W112_ControlModuleV1 * W112_CTL_STDCALL W112_Control_GetModuleV1(void)
{
    init_control_descriptor();
    return &g_controlModule;
}

DLLEXPORT u32 STDCALL AutoPoisons_GetVersion(void) { return VERSION_1_0; }
DLLEXPORT u32 STDCALL AutoPoisons_GetStatus(void)  { return g_status; }
DLLEXPORT u32 STDCALL AutoPoisons_GetTickCount(void) { return g_tickCount; }

BOOL32 STDCALL DllMain(void *module, u32 reason, void *reserved)
{
    SetTimerFn setTimer;
    KillTimerFn killTimer;
    (void)module; (void)reserved;

    if (reason == DLL_PROCESS_ATTACH) {
        g_status = STATUS_WAITING_WORLD;
        g_luaReady = 0u;
        setTimer = (SetTimerFn)load_iat_fn(WOW_IAT_SETTIMER);
        if (!setTimer) {
            g_status = STATUS_SETTIMER_MISSING;
            return FALSE32;
        }
        g_timerId = setTimer(0, 0u, TIMER_PERIOD_MS, AutoPoisons_TimerProc);
        if (!g_timerId) {
            g_status = STATUS_SETTIMER_FAILED;
            return FALSE32;
        }
        return TRUE32;
    }

    if (reason == DLL_PROCESS_DETACH) {
        killTimer = (KillTimerFn)load_iat_fn(WOW_IAT_KILLTIMER);
        if (killTimer && g_timerId)
            killTimer(0, g_timerId);
        g_timerId = 0u;
        g_luaReady = 0u;
        g_status = STATUS_DETACHED;
        return TRUE32;
    }
    return TRUE32;
}