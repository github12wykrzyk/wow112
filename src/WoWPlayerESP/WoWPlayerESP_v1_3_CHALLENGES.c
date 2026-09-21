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
#define WM_W112_REAR_TICK (0x8000u + 0x0119u)
#define VK_INSERT 0x2Du
#define BG_SCORE_POLL_FRAMES 30u /* ~1s at 33ms/render frame */
#define CHALLENGE_WORLD_STABLE_POLLS 15u /* 15 x 100 ms = 1.5 s quarantine after world/BG rebuild */

#define FN_FRAMESCRIPT_EXECUTE 0x00704CD0u
#define FN_FRAMESCRIPT_GETTEXT 0x00703BF0u

__declspec(dllimport) BOOL WINAPI PostMessageA(HWND, UINT, DWORD, LONG);
__declspec(dllimport) HMODULE WINAPI GetModuleHandleA(LPCSTR);
__declspec(dllimport) void* WINAPI GetProcAddress(HMODULE,LPCSTR);
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
    if (msg==WM_KEYDOWN && wParam==VK_INSERT) {
        g_parallel_gui_open=g_parallel_gui_open?0u:1u;
        return 0;
    }
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
    if (msg == WM_W112_REAR_TICK) {
        /* This WndProc owns the game's thread. The worker only posts here;
           never call native pose/heartbeat from a foreign worker thread. */
        HMODULE rear=GetModuleHandleA("WoWPVERear360_5875_v1.dll");
        if(rear) {
            typedef DWORD (WINAPI *RearTickFn)(HWND);
            RearTickFn fn=(RearTickFn)GetProcAddress(rear,"PVERear360_GameWindowTick");
            if(fn)fn(hwnd);
        }
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


/* PARALLEL: one readable native window with real ESP / ROGUE / STATUS tabs.
   The GUI owns its existing ESP render-thread window only: no new game
   WndProc hook, no in-game engine access from GUI callbacks, and no unsafe
   hot-unloading of the legacy hook-owning PP/loot DLLs. */
#define UI_CHILD 0x40000000u
#define UI_VISIBLE 0x10000000u
#define UI_CAPTION 0x00C00000u
#define UI_SYSMENU 0x00080000u
#define UI_CHECKBOX 0x00000002u
#define UI_BUTTON 0x00000000u
#define UI_COMMAND 0x0111u
#define UI_CLOSE 0x0010u
#define UI_SETFONT 0x0030u
#define UI_SETCHECK 0x00F1u
#define UI_WIDTH 750
#define UI_HEIGHT 660
#define UI_MAX_PAGE_CONTROLS 14u
#define UI_TAB_ESP 0u
#define UI_TAB_ROGUE 1u
#define UI_TAB_STATUS 2u

typedef void* HFONT;
__declspec(dllimport) HFONT WINAPI CreateFontA(int,int,int,int,int,DWORD,DWORD,DWORD,DWORD,DWORD,DWORD,DWORD,DWORD,LPCSTR);
__declspec(dllimport) LONG WINAPI SendMessageA(HWND,UINT,DWORD,LONG);
__declspec(dllimport) BOOL WINAPI SetForegroundWindow(HWND);
__declspec(dllimport) BOOL WINAPI SetWindowTextA(HWND,LPCSTR);

#define PAR_SPEED_DLL "WoWNonPvPSpeedFloor_v0_4_ALWAYS_FLOOR7_1_DIAG.dll"
#define PAR_RANGE_DLL "PickPocketSelectiveRange_5875_v10_PP300_PICKLOCK300_9YD.dll"
#define PAR_LOOT_DLL "WoWAutoLootPP_v0_14_PP300YD_HU_ATTACKABLE_LEVELGATE3_NOSKIP_SELECTORCHECK.dll"
#define PAR_LONGPP_DLL "WoWLongPickPocket_v1_0_ALLRANGE_360FACING_HARDLOS025.dll"
#define PAR_REAR_DLL "WoWPVERear360_5875_v1.dll"
#define PAR_CORE_DLL "MovementCore_V68_MINING_HARDLOS_COMBAT_AUTOPP_F11_BLACKLIST_HARDLOS3D_REARONLY_RETRY.dll"
#define PAR_WSG_DLL "WoWAutoFlagWSG_5875_v1.dll"

static WNDPROC32 g_ui_prev=NULL;
static HFONT g_ui_font=NULL,g_ui_title_font=NULL;
static HWND g_ui_tabs[3]={NULL,NULL,NULL};
static HWND g_ui_pages[3][UI_MAX_PAGE_CONTROLS];
static DWORD g_ui_page_count[3]={0u,0u,0u};
static DWORD g_ui_current_tab=UI_TAB_ESP;
static HWND g_ui_checks[4]={NULL,NULL,NULL,NULL};
static HWND g_ui_speedfloor_check=NULL;
static HWND g_ui_hostile_guard_check=NULL;
static HWND g_ui_speedfloor_state=NULL;
static HWND g_ui_speedfloor_value=NULL;
static HWND g_ui_pp_check=NULL,g_ui_junkbox_check=NULL;
static HWND g_ui_pp_control_state=NULL,g_ui_core_state=NULL;
static HWND g_ui_autopp_state=NULL;
static HWND g_ui_longpp_state=NULL;
static HWND g_ui_range_state=NULL;
static HWND g_ui_esp_state=NULL;
static HWND g_ui_rear_state=NULL;
static HWND g_ui_wsg_check=NULL,g_ui_wsg_state=NULL;
static DWORD g_ui_shown=0u;
/* Stdcall exports may be decorated on Win32/x86. Resolve all supported
   spellings, as the existing ControlHub adapter already does. */
static W112_ControlGetModuleV1Fn ui_find_control_export(HMODULE dll) {
    void *p;
    if(!dll)return NULL;
    p=GetProcAddress(dll,"W112_Control_GetModuleV1");
    if(!p)p=GetProcAddress(dll,"_W112_Control_GetModuleV1@0");
    if(!p)p=GetProcAddress(dll,"_W112_Control_GetModuleV1");
    return (W112_ControlGetModuleV1Fn)p;
}

/* The canonical SpeedFloor source exports these stable setting IDs.
   Query its ABI and values on demand; never hardcode a displayed "7.1"
   after the user changes the live runtime minimum. */
static const W112_ControlModuleV1* ui_speedfloor_module(void) {
    HMODULE dll=GetModuleHandleA(PAR_SPEED_DLL);
    W112_ControlGetModuleV1Fn get;
    const W112_ControlModuleV1 *m;
    if (!dll) return NULL;
    get=ui_find_control_export(dll);
    if (!get) return NULL;
    m=get();
    if (!m || m->abi_version!=W112_CONTROL_API_V1 ||
        m->struct_size!=sizeof(W112_ControlModuleV1) ||
        m->setting_count<3u || !m->get_value || !m->set_value) return NULL;
    return m;
}
static BOOL ui_floor_get(DWORD setting,W112_ControlValueV1 *out) {
    const W112_ControlModuleV1 *m=ui_speedfloor_module();
    return m && out && m->get_value(setting,out) ? TRUE : FALSE;
}
static BOOL ui_floor_set(DWORD setting,const W112_ControlValueV1 *value) {
    const W112_ControlModuleV1 *m=ui_speedfloor_module();
    return m && value && m->set_value(setting,value) ? TRUE : FALSE;
}
/* Only work-source controls are exposed: MovementCore id=2 gates AutoPP,
   PickPocketSelectiveRange id=1 controls AutoJunkbox. The exact AutoLootPP
   and LongPP binaries do not expose a verified live control ABI. */
static const W112_ControlModuleV1* ui_work_pp_module(const char* name,DWORD minimum) {
    HMODULE dll=GetModuleHandleA(name);
    W112_ControlGetModuleV1Fn get;
    const W112_ControlModuleV1 *m;
    if(!dll)return NULL;
    get=ui_find_control_export(dll);
    if(!get)return NULL;
    m=get();
    if(!m||m->abi_version!=W112_CONTROL_API_V1||
       m->struct_size!=sizeof(W112_ControlModuleV1)||
       m->setting_count<minimum||!m->get_value||!m->set_value)return NULL;
    return m;
}
static BOOL ui_work_pp_get(const char* dll,DWORD minimum,DWORD id,W112_ControlValueV1*out) {
    const W112_ControlModuleV1*m=ui_work_pp_module(dll,minimum);
    return m&&out&&m->get_value(id,out)?TRUE:FALSE;
}
static BOOL ui_work_pp_flip(const char* dll,DWORD minimum,DWORD id) {
    const W112_ControlModuleV1*m=ui_work_pp_module(dll,minimum);
    W112_ControlValueV1 value;
    if(!m||!m->get_value(id,&value)||value.u32>1u)return FALSE;
    value.u32=value.u32?0u:1u;
    return m->set_value(id,&value)?TRUE:FALSE;
}
/* This companion retains its work source and W112_CONTROL_API_V1 ABI.
   Never treat a missing/unready DLL as enabled. Only setting 1 is writable. */
static void ui_sync_wsg(void) {
    W112_ControlValueV1 enabled,attempts,entry,zone;
    BOOL live=ui_work_pp_get(PAR_WSG_DLL,4u,1u,&enabled);
    char buf[210],*p=buf;
    if(g_ui_wsg_check)
        SendMessageA(g_ui_wsg_check,UI_SETCHECK,
                     live&&enabled.u32?1u:0u,0);
    if(!g_ui_wsg_state)return;
    if(!live){SetWindowTextA(g_ui_wsg_state,
        "WSG AutoFlag: NOT READY (DLL/control unavailable)");return;}
    p=app_str(p,"WSG AutoFlag: ");p=app_str(p,enabled.u32?"ON":"OFF");
    if(ui_work_pp_get(PAR_WSG_DLL,4u,2u,&zone)){
        p=app_str(p," | WSG: ");p=app_str(p,zone.u32?"YES":"NO");
    }
    if(ui_work_pp_get(PAR_WSG_DLL,4u,3u,&attempts)){
        p=app_str(p," | clicks: ");p=app_u32(p,attempts.u32);
    }
    if(ui_work_pp_get(PAR_WSG_DLL,4u,4u,&entry)){
        p=app_str(p," | flag entry: ");p=app_u32(p,entry.u32);
    }
    *p=0;SetWindowTextA(g_ui_wsg_state,buf);
}
static void ui_sync_esp(void) {
    DWORD state[4]={g_esp_enabled,g_parallel_show_horde,
                    g_parallel_show_alliance,g_parallel_show_hostile};
    DWORD i;
    for(i=0u;i<4u;++i)
        if(g_ui_checks[i]) SendMessageA(g_ui_checks[i],UI_SETCHECK,state[i]?1u:0u,0);
}
static void ui_sync_rogue(void) {
    W112_ControlValueV1 enabled,guard,floor;
    BOOL live=ui_floor_get(1u,&enabled) &&
              ui_floor_get(2u,&floor) &&
              ui_floor_get(3u,&guard);
    if(g_ui_speedfloor_check)
        SendMessageA(g_ui_speedfloor_check,UI_SETCHECK,
                     live&&enabled.u32?1u:0u,0);
    if(g_ui_hostile_guard_check)
        SendMessageA(g_ui_hostile_guard_check,UI_SETCHECK,
                     live&&guard.u32?1u:0u,0);
    if(g_ui_speedfloor_state)
        SetWindowTextA(g_ui_speedfloor_state,live?
            "SpeedFloor: live module control available" :
            "SpeedFloor: control unavailable (settings unchanged)");
    if(g_ui_speedfloor_value) {
        if(live && floor.f32>=1.0f && floor.f32<=14.0f) {
            char buf[100],*p=buf;
            DWORD tenths=(DWORD)(floor.f32*10.0f+0.5f);
            p=app_str(p,"Minimum speed: ");
            p=app_u32(p,tenths/10u);
            *p++='.';
            p=app_u32(p,tenths%10u);
            p=app_str(p,"   (- / + adjusts by 0.1)");
            *p=0;
            SetWindowTextA(g_ui_speedfloor_value,buf);
        } else {
            SetWindowTextA(g_ui_speedfloor_value,"Minimum speed: unavailable");
        }
    }
    {
        W112_ControlValueV1 pp,junk;
        BOOL ppLive=ui_work_pp_get(PAR_CORE_DLL,25u,2u,&pp);
        BOOL junkLive=ui_work_pp_get(PAR_RANGE_DLL,7u,1u,&junk);
        if(g_ui_pp_check)SendMessageA(g_ui_pp_check,UI_SETCHECK,
                                      ppLive&&pp.u32?1u:0u,0);
        if(g_ui_junkbox_check)SendMessageA(g_ui_junkbox_check,UI_SETCHECK,
                                           junkLive&&junk.u32?1u:0u,0);
        if(g_ui_pp_control_state)SetWindowTextA(g_ui_pp_control_state,
            !ppLive?"AutoPP: MovementCore control unavailable":
            pp.u32?"AutoPP: ON (work / F11; blacklist + retry)":
                   "AutoPP: OFF (manual PP remains available)");
        if(g_ui_core_state)SetWindowTextA(g_ui_core_state,
            !ppLive?"MovementCore: NOT READY (PP control unavailable)":
            pp.u32?"MovementCore AutoPP: ON (live control)":
                   "MovementCore AutoPP: OFF (live control)");
    }
    if(g_ui_autopp_state)
        SetWindowTextA(g_ui_autopp_state,GetModuleHandleA(PAR_LOOT_DLL)?
            "AutoLootPP: LOADED (exact work-runtime binary)" :
            "AutoLootPP: NOT LOADED");
    if(g_ui_longpp_state)
        SetWindowTextA(g_ui_longpp_state,GetModuleHandleA(PAR_LONGPP_DLL)?
            "Long Pick Pocket: LOADED (exact work-runtime binary)" :
            "Long Pick Pocket: NOT LOADED");
    if(g_ui_range_state)
        SetWindowTextA(g_ui_range_state,GetModuleHandleA(PAR_RANGE_DLL)?
            "PickPocketSelectiveRange: LOADED (work AutoJunkbox source)" :
            "PickPocketSelectiveRange: NOT LOADED");
    if(g_ui_esp_state)
        SetWindowTextA(g_ui_esp_state,g_esp_enabled?
            "ESP: ON (click live labels to target)" :
            "ESP: OFF");
}
/* Passive diagnostics only. Pulse count is not server acceptance or a hit. */
static void ui_sync_rear(void) {
    HMODULE dll=GetModuleHandleA(PAR_REAR_DLL);
    typedef DWORD (WINAPI *RearValueFn)(void);
    RearValueFn status,count,attempts,tx,go,err,retry,busy,aborted;
    DWORD code,pulses;
    const char* desc;
    char buf[240],*p=buf;
    if(!g_ui_rear_state)return;
    if(!dll){SetWindowTextA(g_ui_rear_state,"Rear 360 PvE/PvP: NOT LOADED");return;}
    status=(RearValueFn)GetProcAddress(dll,"PVERear360_GetStatus");
    count=(RearValueFn)GetProcAddress(dll,"PVERear360_GetPulseCount");
    if(!status||!count){SetWindowTextA(g_ui_rear_state,"Rear 360 PvE/PvP: diagnostics unavailable");return;}
    attempts=(RearValueFn)GetProcAddress(dll,"PVERear360_GetAttempts");
    tx=(RearValueFn)GetProcAddress(dll,"PVERear360_GetCastCount");
    go=(RearValueFn)GetProcAddress(dll,"PVERear360_GetServerGo");
    err=(RearValueFn)GetProcAddress(dll,"PVERear360_GetPositionalFailures");
    retry=(RearValueFn)GetProcAddress(dll,"PVERear360_GetAdaptiveRetries");
    busy=(RearValueFn)GetProcAddress(dll,"PVERear360_GetBusyDrops");
    aborted=(RearValueFn)GetProcAddress(dll,"PVERear360_GetAborted");
    code=status();pulses=count();
    desc=code==0u?"READY (cast-synchronized, NPC only)":
         code==1u?"CAST PRIMED (awaiting restore)":
         code==2u?"PAUSED (cast/pending)":
         code==3u?"BUILD MISMATCH":
         code==4u?"CAST/MOVEMENT HOOK NOT READY":
         code==5u?"DISABLED":
         code==6u?"WAITING FOR GAME WINDOW":
         code==7u?"WORKER START ERROR":
         code==8u?"PAUSED (PP / MovementCore owns movement)":
         code==9u?"WAITING FOR WORK MOVEMENTCORE":
         code==10u?"CAST HOOK CONFLICT (0x006E5872)":
         code==11u?"MOVEMENT HOOK CONFLICT (0x00600ACA)":
         code==12u?"HOOK MEMORY PATCH FAILED":
         code==13u?"SPELL FAIL HOOK CONFLICT":
         code==14u?"SPELL GO HOOK CONFLICT":"UNKNOWN";
    p=app_str(p,"Rear 360 PvE/PvP: ");p=app_str(p,desc);
    p=app_str(p,"\r\nTry ");p=app_u32(p,attempts?attempts():0u);
    p=app_str(p," | prime ");p=app_u32(p,pulses);
    p=app_str(p," | sent ");p=app_u32(p,tx?tx():0u);
    p=app_str(p," | GO ");p=app_u32(p,go?go():0u);
    p=app_str(p," | posfail ");p=app_u32(p,err?err():0u);
    p=app_str(p," | retry ");p=app_u32(p,retry?retry():0u);
    p=app_str(p," | busy ");p=app_u32(p,busy?busy():0u);
    p=app_str(p," | cancel ");p=app_u32(p,aborted?aborted():0u);*p=0;
    SetWindowTextA(g_ui_rear_state,buf);
}
/* Switching tabs changes only HWND visibility; ESP cache rescans are
   requested solely when a filter actually changes. */
static void ui_set_page(DWORD page) {
    static const char *tab_names[3][3]={
        {"[ ESP ]","ROGUE","STATUS"},
        {"ESP","[ ROGUE ]","STATUS"},
        {"ESP","ROGUE","[ STATUS ]"}
    };
    DWORD t,i;
    if(page>UI_TAB_STATUS)return;
    g_ui_current_tab=page;
    for(t=0u;t<3u;++t) {
        if(g_ui_tabs[t])SetWindowTextA(g_ui_tabs[t],tab_names[page][t]);
        for(i=0u;i<g_ui_page_count[t];++i) {
            HWND control=g_ui_pages[t][i];
            if(control)ShowWindow(control,t==page?SW_SHOWNOACTIVATE:SW_HIDE);
        }
    }
    if(page==UI_TAB_ESP){ui_sync_esp();ui_sync_wsg();}
    else if(page==UI_TAB_STATUS){ui_sync_rogue();ui_sync_rear();ui_sync_wsg();}
    else ui_sync_rogue();
}
static void ui_add_to_page(DWORD page,HWND control) {
    if(page>UI_TAB_STATUS || !control)return;
    if(g_ui_page_count[page]<UI_MAX_PAGE_CONTROLS)
        g_ui_pages[page][g_ui_page_count[page]++]=control;
}
static HWND ui_label(HWND parent,const char* label,
                     int x,int y,int width,int height,BOOL title) {
    HWND ctl=CreateWindowExA(0u,"STATIC",label,UI_CHILD|UI_VISIBLE,
                            x,y,width,height,parent,NULL,g_self,NULL);
    HFONT font=title?g_ui_title_font:g_ui_font;
    if(ctl && font)SendMessageA(ctl,UI_SETFONT,(DWORD)font,1);
    return ctl;
}
static HWND ui_button(HWND parent,const char* label,
                      int x,int y,int width,int height,DWORD id,BOOL check) {
    HWND ctl=CreateWindowExA(0u,"BUTTON",label,
        UI_CHILD|UI_VISIBLE|(check?UI_CHECKBOX:UI_BUTTON),
        x,y,width,height,parent,(HANDLE)id,g_self,NULL);
    if(ctl && g_ui_font)SendMessageA(ctl,UI_SETFONT,(DWORD)g_ui_font,1);
    return ctl;
}
/* A control change must request a fresh guarded scan; scoreboard reads stay
   exclusively on the existing game WndProc, never inside this GUI. */
static void ui_filters_changed(void) {
    ++g_parallel_filter_revision;
    g_next_bg_score_post_frame=0u;
}
static LONG WINAPI ui_wndproc(HWND hwnd,UINT msg,DWORD wp,LONG lp) {
    DWORD id;
    if(msg==UI_CLOSE || (msg==WM_KEYDOWN && wp==VK_INSERT)) {
        g_parallel_gui_open=0u;
        ShowWindow(hwnd,SW_HIDE);
        if(g_hooked_game_hwnd && IsWindow(g_hooked_game_hwnd))
            SetForegroundWindow(g_hooked_game_hwnd);
        return 0;
    }
    if(msg==UI_COMMAND) {
        W112_ControlValueV1 value;
        id=wp&0xFFFFu;
        if(id>=201u && id<=203u) {
            ui_set_page(id-201u);return 0;
        }
        if(id==101u) {
            g_esp_enabled=g_esp_enabled?0u:1u;
            if(!g_esp_enabled)g_range_sweep_enabled=0u;
            ui_filters_changed();ui_sync_esp();return 0;
        }
        if(id==102u) {
            g_parallel_show_horde=g_parallel_show_horde?0u:1u;
            ui_filters_changed();ui_sync_esp();return 0;
        }
        if(id==103u) {
            g_parallel_show_alliance=g_parallel_show_alliance?0u:1u;
            ui_filters_changed();ui_sync_esp();return 0;
        }
        if(id==104u) {
            g_parallel_show_hostile=g_parallel_show_hostile?0u:1u;
            ui_filters_changed();ui_sync_esp();return 0;
        }
        if(id==105u || id==106u) {
            DWORD key=id==105u?1u:3u;
            if(ui_floor_get(key,&value)) {
                value.u32=value.u32?0u:1u;
                ui_floor_set(key,&value);
            }
            ui_sync_rogue();return 0;
        }
        if(id==111u) {
            ui_work_pp_flip(PAR_WSG_DLL,4u,1u);
            ui_sync_wsg();return 0;
        }
        if(id==109u || id==110u) {
            if(id==109u)ui_work_pp_flip(PAR_CORE_DLL,25u,2u);
            else ui_work_pp_flip(PAR_RANGE_DLL,7u,1u);
            ui_sync_rogue();return 0;
        }
        if(id==107u || id==108u) {
            if(ui_floor_get(2u,&value)) {
                /* Convert to tenths and clamp the exact module-supported
                   1.0..14.0 interval; no floating-point drift on clicks. */
                int tenths=(int)(value.f32*10.0f+0.5f);
                if(id==107u && tenths>10) --tenths;
                if(id==108u && tenths<140) ++tenths;
                value.f32=(float)tenths/10.0f;
                ui_floor_set(2u,&value);
            }
            ui_sync_rogue();return 0;
        }
    }
    return g_ui_prev?CallWindowProcA(g_ui_prev,hwnd,msg,wp,lp):0;
}
static BOOL ui_create(HWND game) {
    struct POINT32 pt;
    struct RECT32 rc;
    DWORD i;
    static const char* filters[4]={
        "ESP - display player labels",
        "HORDE - display Horde characters",
        "ALLIANCE - display Alliance characters",
        "HOSTILE TO ME - opposing BG team"
    };
    if(!game || !IsWindow(game))return FALSE;
    pt.x=pt.y=0;
    if(!GetClientRect(game,&rc) || !ClientToScreen(game,&pt))return FALSE;
    g_parallel_ui_hwnd=CreateWindowExA(WS_EX_TOPMOST|WS_EX_TOOLWINDOW,
        "STATIC","PARALLEL - ESP / Rogue",WS_POPUP|UI_CAPTION|UI_SYSMENU,
        (int)(pt.x+(rc.right-UI_WIDTH)/2),(int)(pt.y+(rc.bottom-UI_HEIGHT)/2),
        UI_WIDTH,UI_HEIGHT,NULL,NULL,g_self,NULL);
    if(!g_parallel_ui_hwnd)return FALSE;
    g_ui_prev=(WNDPROC32)(DWORD)SetWindowLongA(
        g_parallel_ui_hwnd,GWL_WNDPROC,(LONG)(DWORD)ui_wndproc);
    if(!g_ui_prev) {
        DestroyWindow(g_parallel_ui_hwnd);
        g_parallel_ui_hwnd=NULL;return FALSE;
    }
    g_ui_font=CreateFontA(-22,0,0,0,500,0,0,0,1,0,0,0,0,"Segoe UI");
    g_ui_title_font=CreateFontA(-29,0,0,0,700,0,0,0,1,0,0,0,0,"Segoe UI");
    ui_label(g_parallel_ui_hwnd,"PARALLEL / CONTROL",26,15,680,42,TRUE);
    g_ui_tabs[0]=ui_button(g_parallel_ui_hwnd,"ESP",30,75,212,47,201u,FALSE);
    g_ui_tabs[1]=ui_button(g_parallel_ui_hwnd,"ROGUE",267,75,212,47,202u,FALSE);
    g_ui_tabs[2]=ui_button(g_parallel_ui_hwnd,"STATUS",503,75,212,47,203u,FALSE);

    ui_add_to_page(UI_TAB_ESP,ui_label(g_parallel_ui_hwnd,
        "PLAYER ESP",36,137,670,37,TRUE));
    ui_add_to_page(UI_TAB_ESP,ui_label(g_parallel_ui_hwnd,
        "Live filters refresh nearby players. Click a visible label to target.",
        42,179,665,30,FALSE));
    for(i=0u;i<4u;++i) {
        g_ui_checks[i]=ui_button(g_parallel_ui_hwnd,filters[i],
            46,224+(int)i*59,650,44,101u+i,TRUE);
        ui_add_to_page(UI_TAB_ESP,g_ui_checks[i]);
    }
    ui_add_to_page(UI_TAB_ESP,ui_label(g_parallel_ui_hwnd,
        "Faction filters combine (OR). HOSTILE uses BG team on mixed BG.",
        40,475,675,34,FALSE));
    g_ui_wsg_check=ui_button(g_parallel_ui_hwnd,
        "WSG AUTO FLAG - dropped flags only (4.75 yd)",46,526,665,43,111u,TRUE);
    ui_add_to_page(UI_TAB_ESP,g_ui_wsg_check);

    ui_add_to_page(UI_TAB_ROGUE,ui_label(g_parallel_ui_hwnd,
        "ROGUE / STEALTH FLOOR + PP",36,137,665,39,TRUE));
    ui_add_to_page(UI_TAB_ROGUE,ui_label(g_parallel_ui_hwnd,
        "Current work AutoPP + Junkbox; exact AutoLootPP / LongPP binaries.",
        42,181,672,34,FALSE));
    g_ui_speedfloor_check=ui_button(g_parallel_ui_hwnd,
        "STEALTH FLOOR - enabled",46,228,650,43,105u,TRUE);
    ui_add_to_page(UI_TAB_ROGUE,g_ui_speedfloor_check);
    g_ui_hostile_guard_check=ui_button(g_parallel_ui_hwnd,
        "Disable floor when targeting a hostile player",46,283,665,42,106u,TRUE);
    ui_add_to_page(UI_TAB_ROGUE,g_ui_hostile_guard_check);
    g_ui_speedfloor_value=ui_label(g_parallel_ui_hwnd,
        "",48,351,440,38,FALSE);
    ui_add_to_page(UI_TAB_ROGUE,g_ui_speedfloor_value);
    ui_add_to_page(UI_TAB_ROGUE,ui_button(g_parallel_ui_hwnd,
        "-",508,338,72,47,107u,FALSE));
    ui_add_to_page(UI_TAB_ROGUE,ui_button(g_parallel_ui_hwnd,
        "+",606,338,72,47,108u,FALSE));
    g_ui_speedfloor_state=ui_label(g_parallel_ui_hwnd,
        "",46,404,665,32,FALSE);
    ui_add_to_page(UI_TAB_ROGUE,g_ui_speedfloor_state);
    g_ui_pp_check=ui_button(g_parallel_ui_hwnd,
        "AUTO PICKPOCKET - work MovementCore (F11)",46,440,665,42,109u,TRUE);
    ui_add_to_page(UI_TAB_ROGUE,g_ui_pp_check);
    g_ui_junkbox_check=ui_button(g_parallel_ui_hwnd,
        "AUTO JUNKBOX - work PickPocketSelectiveRange",46,491,665,42,110u,TRUE);
    ui_add_to_page(UI_TAB_ROGUE,g_ui_junkbox_check);
    g_ui_pp_control_state=ui_label(g_parallel_ui_hwnd,
        "",46,548,665,35,FALSE);
    ui_add_to_page(UI_TAB_ROGUE,g_ui_pp_control_state);

    ui_add_to_page(UI_TAB_STATUS,ui_label(g_parallel_ui_hwnd,
        "ACTIVE MODULES",36,137,665,40,TRUE));
    ui_add_to_page(UI_TAB_STATUS,ui_label(g_parallel_ui_hwnd,
        "LOADED means the DLL is present; successful PP/loot needs a game test.",
        42,179,665,37,FALSE));
    g_ui_esp_state=ui_label(g_parallel_ui_hwnd,"",46,244,665,31,FALSE);
    ui_add_to_page(UI_TAB_STATUS,g_ui_esp_state);
    g_ui_range_state=ui_label(g_parallel_ui_hwnd,"",46,293,665,31,FALSE);
    ui_add_to_page(UI_TAB_STATUS,g_ui_range_state);
    g_ui_autopp_state=ui_label(g_parallel_ui_hwnd,"",46,342,665,31,FALSE);
    ui_add_to_page(UI_TAB_STATUS,g_ui_autopp_state);
    g_ui_longpp_state=ui_label(g_parallel_ui_hwnd,"",46,391,665,31,FALSE);
    ui_add_to_page(UI_TAB_STATUS,g_ui_longpp_state);
    g_ui_rear_state=ui_label(g_parallel_ui_hwnd,"",46,440,665,47,FALSE);
    ui_add_to_page(UI_TAB_STATUS,g_ui_rear_state);
    g_ui_core_state=ui_label(g_parallel_ui_hwnd,"",46,490,665,31,FALSE);
    ui_add_to_page(UI_TAB_STATUS,g_ui_core_state);
    ui_add_to_page(UI_TAB_STATUS,ui_label(g_parallel_ui_hwnd,
        "AutoLootPP / LongPP remain exact-byte modules, not hot-unloaded.",
        42,548,665,35,FALSE));
    g_ui_wsg_state=ui_label(g_parallel_ui_hwnd,"",46,585,665,34,FALSE);
    ui_add_to_page(UI_TAB_STATUS,g_ui_wsg_state);

    ui_sync_esp();
    ui_sync_rogue();
    ui_set_page(g_ui_current_tab);
    g_ui_shown=0u;
    return TRUE;
}
static void parallel_gui_tick(void) {
    HWND game=g_hooked_game_hwnd,fg;
    if(!game || !IsWindow(game) || !g_parallel_gui_open) {
        if(g_parallel_ui_hwnd && IsWindow(g_parallel_ui_hwnd))
            ShowWindow(g_parallel_ui_hwnd,SW_HIDE);
        g_ui_shown=0u;return;
    }
    fg=GetForegroundWindow();
    if(fg!=game && fg!=g_parallel_ui_hwnd) {
        if(g_parallel_ui_hwnd && IsWindow(g_parallel_ui_hwnd))
            ShowWindow(g_parallel_ui_hwnd,SW_HIDE);
        g_ui_shown=0u;return;
    }
    if(!g_parallel_ui_hwnd || !IsWindow(g_parallel_ui_hwnd)) {
        g_parallel_ui_hwnd=NULL;
        if(!ui_create(game))return;
    }
    if(!g_ui_shown || !IsWindowVisible(g_parallel_ui_hwnd)) {
        ui_set_page(g_ui_current_tab);
        ShowWindow(g_parallel_ui_hwnd,SW_SHOWNOACTIVATE);
        g_ui_shown=1u;
    }
    if(g_render_frame%15u==0u) {
        if(g_ui_current_tab==UI_TAB_STATUS){
            ui_sync_rogue();ui_sync_rear();ui_sync_wsg();
        } else if(g_ui_current_tab==UI_TAB_ESP)ui_sync_wsg();
    }
}
static void parallel_gui_destroy(void) {
    DWORD page;
    if(g_parallel_ui_hwnd && IsWindow(g_parallel_ui_hwnd)) {
        if(g_ui_prev)
            SetWindowLongA(g_parallel_ui_hwnd,GWL_WNDPROC,(LONG)(DWORD)g_ui_prev);
        DestroyWindow(g_parallel_ui_hwnd);
    }
    g_parallel_ui_hwnd=NULL;g_ui_prev=NULL;
    for(page=0u;page<3u;++page) {
        g_ui_tabs[page]=NULL;
        g_ui_page_count[page]=0u;
    }
    for(page=0u;page<4u;++page)g_ui_checks[page]=NULL;
    g_ui_speedfloor_check=NULL;g_ui_hostile_guard_check=NULL;
    g_ui_speedfloor_state=NULL;g_ui_speedfloor_value=NULL;
    g_ui_pp_check=NULL;g_ui_junkbox_check=NULL;
    g_ui_pp_control_state=NULL;g_ui_core_state=NULL;
    g_ui_esp_state=NULL;g_ui_autopp_state=NULL;g_ui_longpp_state=NULL;
    g_ui_range_state=NULL;g_ui_rear_state=NULL;
    g_ui_wsg_check=NULL;g_ui_wsg_state=NULL;
    if(g_ui_font)DeleteObject((HGDIOBJ)g_ui_font);
    if(g_ui_title_font)DeleteObject((HGDIOBJ)g_ui_title_font);
    g_ui_font=NULL;g_ui_title_font=NULL;
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
