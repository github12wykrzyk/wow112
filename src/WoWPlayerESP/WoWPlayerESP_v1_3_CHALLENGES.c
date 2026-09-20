/* PlayerESP work wrapper: retain BG scoreboard team bridge, world-transition
 * quarantine, WndProc chain safety and F8 SafeBreak ownership. The Turtle
 * challenge lookup/name decoration has been removed. Target: WoW 5875 x86.
 */

/* The included base periodically confirms that the cached local player
   still belongs to the live Object Manager (also when BG transitions recycle
   the same manager address), invalidates stale world caches and repaints
   layered labels. The base now uses the guarded BG scoreboard bridge
   instead of race to classify cross-faction BG teams and purges former enemy
   labels when a player is friendly. Keep this wrapper marked as the active
   build input for build_changed_active. */
#define DllMain W112_PlayerESP_Base_DllMain
#include "WoWPlayerESP_v1_2_range_sweep.c"
#undef DllMain

#include "../common/W112ControlAPI.h"

#define WM_W112_ESP_BG_SCORE (0x8000u + 0x0113u)
#define BG_SCORE_POLL_FRAMES 30u /* ~1s at 33ms/render frame */
#define CHALLENGE_WORLD_STABLE_POLLS 15u /* 15 x 100 ms = 1.5 s quarantine after world/BG rebuild */

#define FN_FRAMESCRIPT_EXECUTE 0x00704CD0u
#define FN_FRAMESCRIPT_GETTEXT 0x00703BF0u

__declspec(dllimport) BOOL WINAPI PostMessageA(HWND, UINT, DWORD, LONG);
__declspec(dllimport) LONG WINAPI GetWindowLongA(HWND, int);

typedef void        (__fastcall *FrameScriptExecuteFn)(const char* code, const char* codeAgain);
typedef const char* (__fastcall *FrameScriptGetTextFn)(const char* key, int playerGender, DWORD pluralCount);

static WNDPROC32 g_challenge_prev_wndproc = NULL;
static HWND g_challenge_hwnd = NULL;
static BOOL g_challenge_hooked = FALSE;
static DWORD g_next_bg_score_post_frame = 0u;
static volatile DWORD g_challenge_world_ready = 0u;
static DWORD g_challenge_world_polls = 0u;
static DWORD g_challenge_world_manager = 0u;
static DWORD g_challenge_world_guid_lo = 0u;
static DWORD g_challenge_world_guid_hi = 0u;
static HWND g_challenge_world_hwnd = NULL;

static void chal_world_reset(void) {
    g_challenge_world_ready = 0u;
    g_challenge_world_polls = 0u;
    g_challenge_world_manager = 0u;
    g_challenge_world_guid_lo = 0u;
    g_challenge_world_guid_hi = 0u;
    g_challenge_world_hwnd = NULL;
    g_next_bg_score_post_frame = g_render_frame + BG_SCORE_POLL_FRAMES;
    ++g_bg_score_version;
    g_bg_score_count=0u;
    g_bg_score_my_side=2u;
    g_bg_score_manager=0u;
    g_bg_score_mode=0u;
    ++g_bg_score_version;
}

static BOOL chal_probe_world(DWORD* outManager, DWORD* outLo, DWORD* outHi, HWND* outHwnd) {
    DWORD manager = 0u, linkBase = 0u, lo = 0u, hi = 0u;
    HWND hwnd = g_hooked_game_hwnd;
    HWND liveHwnd = ((GetGameWindowFn)FN_GET_GAME_WINDOW)(0);

    if (!hwnd || !liveHwnd || hwnd != liveHwnd || !IsWindow(liveHwnd)) return FALSE;
    if (!rd_u32(OBJMGR_GLOBAL, &manager)) return FALSE;
    if (manager < 0x00010000u || manager > 0x7FFF0000u) return FALSE;
    if (!readable4(manager + OM_LINK_BASE) ||
        !readable4(manager + OM_FIRST_OBJECT) ||
        !readable4(manager + OM_LOCAL_GUID_LO) ||
        !readable4(manager + OM_LOCAL_GUID_HI)) return FALSE;
    if (!rd_u32(manager + OM_LINK_BASE, &linkBase) || linkBase != 0x38u) return FALSE;
    if (!rd_u32(manager + OM_LOCAL_GUID_LO, &lo) ||
        !rd_u32(manager + OM_LOCAL_GUID_HI, &hi) ||
        (lo == 0u && hi == 0u)) return FALSE;
    if (!g_cached_local_obj || !cached_object_matches(g_cached_local_obj, lo, hi)) return FALSE;
    if (!hwnd || !IsWindow(hwnd)) return FALSE;

    if (outManager) *outManager = manager;
    if (outLo) *outLo = lo;
    if (outHi) *outHi = hi;
    if (outHwnd) *outHwnd = hwnd;
    return TRUE;
}

static BOOL chal_world_identity_ready(void) {
    DWORD manager, lo, hi;
    HWND hwnd;
    if (!g_challenge_world_ready) return FALSE;
    if (!chal_probe_world(&manager, &lo, &hi, &hwnd)) return FALSE;
    return manager == g_challenge_world_manager &&
           lo == g_challenge_world_guid_lo &&
           hi == g_challenge_world_guid_hi &&
           hwnd == g_challenge_world_hwnd;
}

static void chal_world_guard_tick(void) {
    DWORD manager, lo, hi;
    HWND hwnd;

    if (!chal_probe_world(&manager, &lo, &hi, &hwnd)) {
        chal_world_reset();
        return;
    }

    if (manager != g_challenge_world_manager ||
        lo != g_challenge_world_guid_lo ||
        hi != g_challenge_world_guid_hi ||
        hwnd != g_challenge_world_hwnd) {
        g_challenge_world_manager = manager;
        g_challenge_world_guid_lo = lo;
        g_challenge_world_guid_hi = hi;
        g_challenge_world_hwnd = hwnd;
        g_challenge_world_polls = 1u;
        g_challenge_world_ready = 0u;
        return;
    }

    if (g_challenge_world_polls < CHALLENGE_WORLD_STABLE_POLLS)
        ++g_challenge_world_polls;
    if (g_challenge_world_polls >= CHALLENGE_WORLD_STABLE_POLLS)
        g_challenge_world_ready = 1u;
}

static void chal_copy(char* dst, DWORD cap, const char* src) {
    DWORD i = 0u;
    if (!dst || !cap) return;
    if (src) while (src[i] && i + 1u < cap) { dst[i] = src[i]; ++i; }
    dst[i] = 0;
}

/* Scoreboard is queried ONLY through the game-window WndProc, not from the
 * ESP render worker. This avoids the native UnitReaction/CanAttack BG crash
 * path and uses the actual assigned BG side, not the character's race.
 * The player must appear on the same scoreboard: otherwise no BG override
 * is published. Empty/partial scoreboards never mark anyone as hostile. */
static void chal_bg_score_main_thread(void) {
    static const char script[] =
        "W112_ESP_BG_RESULT='';"
        "if type(GetNumBattlefieldScores)=='function' and type(GetBattlefieldScore)=='function' "
        "and type(UnitName)=='function' then "
        "local me=UnitName('player');local my=2;local rows={};"
        "local n=GetNumBattlefieldScores() or 0;if n>80 then n=80 end;"
        "local bt=nil;if type(GetBattlefieldInstanceRunTime)=='function' then "
        "bt=GetBattlefieldInstanceRunTime() "
        "elseif type(GetBattleFieldInstanceRunTime)=='function' then "
        "bt=GetBattleFieldInstanceRunTime() end;"
        "local active=(type(bt)=='number' and bt>0) or (bt==nil and n>0);"
        "for i=1,n do local nm,_,_,_,_,side=GetBattlefieldScore(i);"
        "if type(nm)=='string' and string.len(nm)>0 and string.len(nm)<=31 "
        "and (side==0 or side==1) then "
        "rows[table.getn(rows)+1]=nm..','..side;"
        "if nm==me then my=side end end end;"
        "if active and my<2 then W112_ESP_BG_RESULT=my..';'..table.concat(rows,';') "
        "elseif active then W112_ESP_BG_RESULT='P;' "
        "else W112_ESP_BG_RESULT='W;' end;"
        "if type(RequestBattlefieldScoreData)=='function' then "
        "if not W112_ESP_BG_REQUEST or GetTime()-W112_ESP_BG_REQUEST>=3 then "
        "RequestBattlefieldScoreData();W112_ESP_BG_REQUEST=GetTime() end end end";
    FrameScriptExecuteFn exec=(FrameScriptExecuteFn)FN_FRAMESCRIPT_EXECUTE;
    FrameScriptGetTextFn getText=(FrameScriptGetTextFn)FN_FRAMESCRIPT_GETTEXT;
    const char* raw;
    const char* p;
    DWORD count=0u, side=2u, manager=0u;
    DWORD i;
    if (!chal_world_identity_ready()) return;
    if (!g_render_manager || g_render_manager!=g_challenge_world_manager) return;
    exec(script,script);
    raw=getText("W112_ESP_BG_RESULT",-1,0u);
    if (!raw || raw[1]!=';' ||
        (raw[0]!='0' && raw[0]!='1' && raw[0]!='P' && raw[0]!='W'))
        return;
    if (raw[0]=='W') {
        ++g_bg_score_version;
        g_bg_score_mode=0u;
        g_bg_score_manager=0u;
        g_bg_score_count=0u;
        g_bg_score_my_side=2u;
        ++g_bg_score_version;
        return;
    }
    if (raw[0]=='P') {
        ++g_bg_score_version;
        g_bg_score_mode=1u;
        g_bg_score_manager=g_render_manager;
        g_bg_score_count=0u;
        g_bg_score_my_side=2u;
        ++g_bg_score_version;
        return;
    }
    side=(DWORD)(raw[0]-'0');
    p=raw+2;
    /* Parse into the currently inactive snapshot before publishing the new
       count/team. Reader ignores the odd version during the short write. */
    ++g_bg_score_version;
    g_bg_score_count=0u;
    g_bg_score_my_side=2u;
    for (i=0u; i<BG_SCORE_ROWS && *p; ++i) {
        DWORD j=0u;
        char name[MAX_PLAYER_NAME+1u];
        while (*p && *p!=',' && *p!=';' && j<MAX_PLAYER_NAME)
            name[j++]=*p++;
        name[j]=0;
        if (*p!=',' || !name[0]) break;
        ++p;
        if (*p!='0' && *p!='1') break;
        g_bg_score_rows[count].side=(BYTE)(*p++-'0');
        chal_copy(g_bg_score_rows[count].name,sizeof(g_bg_score_rows[count].name),name);
        ++count;
        if (*p!=';' && *p) break;
        if (*p==';') ++p;
    }
    manager=g_render_manager;
    g_bg_score_manager=manager;
    g_bg_score_mode=1u;
    g_bg_score_frame=g_render_frame;
    g_bg_score_count=count;
    g_bg_score_my_side=side;
    ++g_bg_score_version;
}

static LONG WINAPI chal_game_wndproc(HWND hwnd, UINT msg, DWORD wParam, LONG lParam) {
    /* v1.2 consumes F8 to toggle its range sweep. In the aggregate active stack
       MovementCore also owns physical F8 for SafeBreak. Let the existing WndProc
       chain process the key, then force the ESP sweep back off before its next
       render tick can start spoofing position. */
    if (msg == WM_KEYDOWN && wParam == VK_F8) {
        LONG result = 0;
        if (g_challenge_prev_wndproc)
            result = CallWindowProcA(g_challenge_prev_wndproc, hwnd, msg, wParam, lParam);
        if (g_range_sweep_enabled) {
            g_range_sweep_enabled = 0u;
            log_line("RANGE_SWEEP_BLOCKED reason=F8_reserved_for_MovementCore_SafeBreak");
        }
        return result;
    }
    if (msg == WM_W112_ESP_BG_SCORE) {
        chal_bg_score_main_thread();
        return 0;
    }
    if (g_challenge_prev_wndproc)
        return CallWindowProcA(g_challenge_prev_wndproc, hwnd, msg, wParam, lParam);
    return 0;
}

static void chal_clear_hook_tracking(void) {
    g_challenge_hooked = FALSE;
    g_challenge_hwnd = NULL;
    g_challenge_prev_wndproc = NULL;
}

/*
 * A valid secondary subclass does NOT have to be the current top-level WndProc.
 * WoWControlHub may legitimately sit above it while retaining us as its saved
 * predecessor. Treating that state as "lost" and installing chal_game_wndproc
 * again would put the same proc twice in the chain and make the global
 * g_challenge_prev_wndproc point back through ControlHub to ourselves.
 */
static BOOL chal_hook_is_current(void) {
    if (!g_challenge_hooked || !g_challenge_hwnd || !g_challenge_prev_wndproc) return FALSE;
    if (g_challenge_hwnd != g_hooked_game_hwnd) return FALSE;
    return IsWindow(g_challenge_hwnd) ? TRUE : FALSE;
}

/* Restore only if our proc is still the actual top-level WndProc. If another
   owner is above us, never overwrite that newer chain on the old window. */
static void chal_remove_hook(void) {
    LONG current;
    if (g_challenge_hooked && g_challenge_hwnd && g_challenge_prev_wndproc && IsWindow(g_challenge_hwnd)) {
        current = GetWindowLongA(g_challenge_hwnd, GWL_WNDPROC);
        if ((WNDPROC32)(DWORD)current == chal_game_wndproc)
            SetWindowLongA(g_challenge_hwnd, GWL_WNDPROC, (LONG)(DWORD)g_challenge_prev_wndproc);
    }
    chal_clear_hook_tracking();
}

static BOOL chal_release_for_migration(void) {
    LONG current;
    if (!g_challenge_hooked || !g_challenge_hwnd || !g_challenge_prev_wndproc) {
        chal_clear_hook_tracking();
        return TRUE;
    }
    if (!IsWindow(g_challenge_hwnd)) {
        chal_clear_hook_tracking();
        return TRUE;
    }

    current = GetWindowLongA(g_challenge_hwnd, GWL_WNDPROC);
    if ((WNDPROC32)(DWORD)current != chal_game_wndproc)
        return FALSE;

    SetWindowLongA(g_challenge_hwnd, GWL_WNDPROC, (LONG)(DWORD)g_challenge_prev_wndproc);
    chal_clear_hook_tracking();
    return TRUE;
}

static BOOL chal_try_install_hook(void) {
    LONG oldProc;

    if (chal_hook_is_current()) return TRUE;

    /* Keep the saved predecessor tied to the old HWND until that callback can
       no longer be reached through a higher subclass (normally ControlHub). */
    if (!chal_release_for_migration()) return FALSE;

    if (!g_hooked_game_hwnd || !g_old_game_wndproc || !IsWindow(g_hooked_game_hwnd)) return FALSE;
    oldProc = GetWindowLongA(g_hooked_game_hwnd, GWL_WNDPROC);
    if (!oldProc) return FALSE;
    if ((WNDPROC32)(DWORD)oldProc == chal_game_wndproc) return FALSE;

    oldProc = SetWindowLongA(g_hooked_game_hwnd, GWL_WNDPROC, (LONG)(DWORD)chal_game_wndproc);
    if (!oldProc) return FALSE;
    g_challenge_prev_wndproc = (WNDPROC32)(DWORD)oldProc;
    g_challenge_hwnd = g_hooked_game_hwnd;
    g_challenge_hooked = TRUE;
    log_line("ESP_BG_HOOK_OK scoreboard_bridge=1 chain_safe=1 migration_safe=1");
    return TRUE;
}

static DWORD WINAPI EspBgWorker(LPVOID ignored) {
    (void)ignored;
    while (!g_stop) {
        chal_world_guard_tick();
        if (g_challenge_world_ready) {
            if (!chal_hook_is_current()) chal_try_install_hook();
            if (chal_hook_is_current() && chal_world_identity_ready()) {
                if (g_render_frame>=g_next_bg_score_post_frame) {
                    if (PostMessageA(g_challenge_hwnd,WM_W112_ESP_BG_SCORE,0u,0))
                        g_next_bg_score_post_frame=g_render_frame+BG_SCORE_POLL_FRAMES;
                }
            }
        }
        Sleep(100u);
    }
    return 0u;
}

/* Read-only pipeline states give the in-game GUI a precise diagnostic when
   ESP is enabled but BG labels have not returned. */
static const W112_ControlEnumOptionV1 g_espPipelineOptions[] = {
    {0, "STARTING"}, {1, "WORLD_NOT_READY"}, {2, "LOCAL_GUID_MISSING"},
    {3, "LOCAL_PLAYER_MISSING"}, {4, "WORLD_STABILIZING"},
    {5, "ESP_DISABLED"}, {6, "PROJECTION_NOT_READY"},
    {7, "GAME_RECT_INVALID"}, {8, "GAME_NOT_FOCUSED"},
    {9, "LABEL_BUFFER_FAIL"}, {10, "NO_HOSTILE_RACES"},
    {11, "HOSTILES_OFF_SCREEN"}, {12, "LABELS_DRAWN"},
    {13, "NO_REMOTE_PLAYERS"}
};
static W112_ControlSettingV1 g_controlSettings[10];
static volatile DWORD g_controlDescriptorReady=0u;

static void init_control_descriptor(void)
{
    W112_ControlSettingV1*s;
    if(g_controlDescriptorReady)return;

    s=&g_controlSettings[0];
    s->struct_size=(w112_u32)sizeof(W112_ControlSettingV1);s->setting_id=1u;s->key="esp_enabled";s->label="ESP labels";
    s->type=W112_CTL_BOOL;s->default_value.u32=1u;s->min_value.u32=0u;s->max_value.u32=1u;s->step.u32=1u;s->flags=W112_CTL_LIVE;s->enum_options=0;s->enum_option_count=0u;

    s=&g_controlSettings[1];
    s->struct_size=(w112_u32)sizeof(W112_ControlSettingV1);s->setting_id=2u;s->key="range_sweep";s->label="Range sweep";
    s->type=W112_CTL_BOOL;s->default_value.u32=0u;s->min_value.u32=0u;s->max_value.u32=1u;s->step.u32=1u;s->flags=W112_CTL_LIVE;s->enum_options=0;s->enum_option_count=0u;

    s=&g_controlSettings[2];
    s->struct_size=(w112_u32)sizeof(W112_ControlSettingV1);s->setting_id=3u;s->key="cached_players";s->label="Cached hostile players";
    s->type=W112_CTL_INT;s->default_value.i32=0;s->min_value.i32=0;s->max_value.i32=128;s->step.i32=1;s->flags=W112_CTL_READ_ONLY|W112_CTL_LIVE;s->enum_options=0;s->enum_option_count=0u;

    s=&g_controlSettings[3];
    s->struct_size=(w112_u32)sizeof(W112_ControlSettingV1);s->setting_id=4u;s->key="click_targets";s->label="Clickable ESP targets";
    s->type=W112_CTL_INT;s->default_value.i32=0;s->min_value.i32=0;s->max_value.i32=128;s->step.i32=1;s->flags=W112_CTL_READ_ONLY|W112_CTL_LIVE;s->enum_options=0;s->enum_option_count=0u;

    s=&g_controlSettings[4];
    s->struct_size=(w112_u32)sizeof(W112_ControlSettingV1);s->setting_id=5u;s->key="world_ready";s->label="ESP world ready";
    s->type=W112_CTL_BOOL;s->default_value.u32=0u;s->min_value.u32=0u;s->max_value.u32=1u;s->step.u32=1u;s->flags=W112_CTL_READ_ONLY|W112_CTL_LIVE;s->enum_options=0;s->enum_option_count=0u;

    s=&g_controlSettings[5];
    s->struct_size=(w112_u32)sizeof(W112_ControlSettingV1);s->setting_id=6u;s->key="wsg_flag_carrier";s->label="WSG Flag Carrier";
    s->type=W112_CTL_BOOL;s->default_value.u32=1u;s->min_value.u32=0u;s->max_value.u32=1u;s->step.u32=1u;s->flags=W112_CTL_LIVE;s->enum_options=0;s->enum_option_count=0u;

    s=&g_controlSettings[6];
    s->struct_size=(w112_u32)sizeof(W112_ControlSettingV1);s->setting_id=7u;s->key="pipeline";s->label="ESP render state";
    s->type=W112_CTL_ENUM;s->default_value.i32=0;s->min_value.i32=0;s->max_value.i32=13;s->step.i32=1;s->flags=W112_CTL_READ_ONLY|W112_CTL_LIVE;s->enum_options=g_espPipelineOptions;s->enum_option_count=(w112_u32)(sizeof(g_espPipelineOptions)/sizeof(g_espPipelineOptions[0]));

    s=&g_controlSettings[7];
    s->struct_size=(w112_u32)sizeof(W112_ControlSettingV1);s->setting_id=8u;s->key="seen_players";s->label="Visible remote players";
    s->type=W112_CTL_INT;s->default_value.i32=0;s->min_value.i32=0;s->max_value.i32=4096;s->step.i32=1;s->flags=W112_CTL_READ_ONLY|W112_CTL_LIVE;s->enum_options=0;s->enum_option_count=0u;

    s=&g_controlSettings[8];
    s->struct_size=(w112_u32)sizeof(W112_ControlSettingV1);s->setting_id=9u;s->key="drawn_labels";s->label="Labels rendered";
    s->type=W112_CTL_INT;s->default_value.i32=0;s->min_value.i32=0;s->max_value.i32=128;s->step.i32=1;s->flags=W112_CTL_READ_ONLY|W112_CTL_LIVE;s->enum_options=0;s->enum_option_count=0u;

    s=&g_controlSettings[9];
    s->struct_size=(w112_u32)sizeof(W112_ControlSettingV1);s->setting_id=10u;s->key="world_frames";s->label="World stable frames";
    s->type=W112_CTL_INT;s->default_value.i32=0;s->min_value.i32=0;s->max_value.i32=60;s->step.i32=1;s->flags=W112_CTL_READ_ONLY|W112_CTL_LIVE;s->enum_options=0;s->enum_option_count=0u;

    g_controlDescriptorReady=1u;
}

static int W112_CTL_STDCALL esp_control_get(w112_u32 id,W112_ControlValueV1*out)
{
    if(!out)return 0;
    if(id==1u){out->u32=g_esp_enabled?1u:0u;return 1;}
    if(id==2u){out->u32=g_range_sweep_enabled?1u:0u;return 1;}
    if(id==3u){out->i32=(w112_i32)g_esp_cache_count;return 1;}
    if(id==4u){out->i32=(w112_i32)g_click_hit_count;return 1;}
    if(id==5u){out->u32=g_challenge_world_ready?1u:0u;return 1;}
    if(id==6u){out->u32=g_esp_flag_enabled?1u:0u;return 1;}
    if(id==7u){out->i32=(w112_i32)g_esp_status;return 1;}
    if(id==8u){out->i32=(w112_i32)g_esp_scan_players;return 1;}
    if(id==9u){out->i32=(w112_i32)g_esp_drawn_labels;return 1;}
    if(id==10u){out->i32=(w112_i32)g_relation_world_stable_frames;return 1;}
    return 0;
}

static int W112_CTL_STDCALL esp_control_set(w112_u32 id,const W112_ControlValueV1*value)
{
    if(!value||value->u32>1u)return 0;
    if(id==1u){
        g_esp_enabled=value->u32;
        if(!g_esp_enabled)g_range_sweep_enabled=0u;
        return 1;
    }
    if(id==2u){
        if(value->u32&&!g_esp_enabled)return 0;
        g_range_sweep_enabled=value->u32;
        if(g_range_sweep_enabled)g_sweep_next_frame=g_render_frame+1u;
        return 1;
    }
    if(id==6u){g_esp_flag_enabled=value->u32;return 1;}
    return 0;
}

static const W112_ControlModuleV1 g_controlModule={
    W112_CONTROL_API_V1,(w112_u32)sizeof(W112_ControlModuleV1),
    "playeresp","PlayerESP",0x00010401u,10u,g_controlSettings,
    esp_control_get,esp_control_set
};

W112_CTL_EXPORT const W112_ControlModuleV1 * W112_CTL_STDCALL W112_Control_GetModuleV1(void)
{
    init_control_descriptor();
    return &g_controlModule;
}

BOOL WINAPI DllMain(HMODULE hinst, DWORD reason, LPVOID reserved) {
    HANDLE th;
    BOOL ok;

    /* Remove the secondary subclass before v1.2 tears down its primary hook.
       The conditional restore above prevents stale-chain writes. */
    if (reason == DLL_PROCESS_DETACH) {
        g_stop = 1;
        chal_remove_hook();
        return W112_PlayerESP_Base_DllMain(hinst, reason, reserved);
    }

    ok = W112_PlayerESP_Base_DllMain(hinst, reason, reserved);
    if (!ok) return FALSE;
    if (reason == DLL_PROCESS_ATTACH) {
        th = CreateThread(NULL, 0u, EspBgWorker, NULL, 0u, NULL);
        if (th) CloseHandle(th);
    }
    return TRUE;
}
