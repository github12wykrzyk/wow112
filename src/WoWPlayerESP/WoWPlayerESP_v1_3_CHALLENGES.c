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
#define UI_WIDTH 820
#define UI_HEIGHT 630
#define UI_MAX_PAGE_CONTROLS 40u
#define UI_TAB_ESP 0u
#define UI_TAB_ROGUE 1u
#define UI_TAB_MOVEMENT 2u
#define UI_TAB_STATUS 3u
#define UI_TAB_SETTINGS 4u
#define UI_PAGE_COUNT 5u
#define UI_CONTENT_X 198
#define UI_CONTENT_Y 96
#define UI_CONTENT_W 600
#define UI_CONTENT_H 476
#define UI_SCROLL_STEP 52
#define UI_MOUSEWHEEL 0x020Au
#define UI_VSCROLL 0x0115u
#define UI_SB_VERT 1
#define UI_SIF_ALL 0x0017u
#define UI_SIF_TRACKPOS 0x0010u
#define UI_WS_VSCROLL 0x00200000u
#define UI_WS_BORDER 0x00800000u
#define UI_SWP_NOZORDER 0x0004u

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

static WNDPROC32 g_ui_prev=NULL;
static HFONT g_ui_font=NULL,g_ui_title_font=NULL;
struct UIPageItem { HWND hwnd; int x,y,w,h; };
struct UIScrollInfo {
    UINT cbSize; UINT fMask; int nMin; int nMax;
    UINT nPage; int nPos; int nTrackPos;
};
__declspec(dllimport) BOOL WINAPI GetWindowRect(HWND,struct RECT32*);
__declspec(dllimport) BOOL WINAPI ScreenToClient(HWND,struct POINT32*);
__declspec(dllimport) int WINAPI SetScrollInfo(HWND,int,const struct UIScrollInfo*,BOOL);
__declspec(dllimport) BOOL WINAPI GetScrollInfo(HWND,int,struct UIScrollInfo*);
static HWND g_ui_tabs[UI_PAGE_COUNT]={NULL,NULL,NULL,NULL,NULL};
static struct UIPageItem g_ui_pages[UI_PAGE_COUNT][UI_MAX_PAGE_CONTROLS];
static DWORD g_ui_page_count[UI_PAGE_COUNT]={0u,0u,0u,0u,0u};
static int g_ui_scroll[UI_PAGE_COUNT]={0,0,0,0,0};
static int g_ui_page_h[UI_PAGE_COUNT]={0,0,0,0,0};
static int g_ui_view_h=UI_CONTENT_H;
static HWND g_ui_content=NULL;
static WNDPROC32 g_ui_prev_content=NULL;
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
static HWND g_ui_speed_loaded_state=NULL,g_ui_wotf_state=NULL,g_ui_ground_state=NULL;
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
    p=app_str(p,"\r\nsent ");p=app_u32(p,tx?tx():0u);
    p=app_str(p," | GO ");p=app_u32(p,go?go():0u);
    p=app_str(p,"\r\nposfail ");p=app_u32(p,err?err():0u);
    p=app_str(p," | retry ");p=app_u32(p,retry?retry():0u);
    p=app_str(p,"\r\nbusy ");p=app_u32(p,busy?busy():0u);
    p=app_str(p," | cancel ");p=app_u32(p,aborted?aborted():0u);*p=0;
    SetWindowTextA(g_ui_rear_state,buf);
}

/* A single clipped child viewport owns all scrollable page controls.
   The sidebar, title and footer remain on the root and never scroll.
   No new subclass is installed on the game window. */
static void ui_scroll_to(DWORD page,int position) {
    DWORD i;
    int max;
    struct UIScrollInfo si;
    if(page>=UI_PAGE_COUNT||!g_ui_content)return;
    max=g_ui_page_h[page]-g_ui_view_h;
    if(max<0)max=0;
    if(position<0)position=0;
    if(position>max)position=max;
    g_ui_scroll[page]=position;
    if(page!=g_ui_current_tab)return;
    for(i=0u;i<g_ui_page_count[page];++i) {
        struct UIPageItem *item=&g_ui_pages[page][i];
        if(item->hwnd)SetWindowPos(item->hwnd,NULL,item->x,
            item->y-position,item->w,item->h,
            SWP_NOACTIVATE|UI_SWP_NOZORDER);
    }
    si.cbSize=sizeof(si);si.fMask=UI_SIF_ALL;
    si.nMin=0;si.nMax=g_ui_page_h[page]>0?g_ui_page_h[page]-1:0;
    si.nPage=(UINT)g_ui_view_h;si.nPos=position;si.nTrackPos=0;
    SetScrollInfo(g_ui_content,UI_SB_VERT,&si,TRUE);
}
static LONG WINAPI ui_content_wndproc(HWND hwnd,UINT msg,DWORD wp,LONG lp) {
    /* All ESP/Rogue buttons are children of the clipped scroll viewport.
       Win32 delivers their BN_CLICKED/WM_COMMAND to that immediate parent,
       not to the top-level panel where the existing setting handlers live.
       Route only genuine viewport button clicks to the original dispatch;
       sidebar buttons still notify the top-level window directly. */
    if(msg==UI_COMMAND) {
        DWORD id=wp&0xffffu;
        DWORD notification=(wp>>16)&0xffffu;
        if(lp!=0 && notification==0u && id>=101u && id<=110u &&
           g_parallel_ui_hwnd && IsWindow(g_parallel_ui_hwnd))
            return SendMessageA(g_parallel_ui_hwnd,UI_COMMAND,wp,lp);
    }
    if(msg==UI_VSCROLL) {
        int p=g_ui_scroll[g_ui_current_tab];
        UINT code=wp&0xffffu;
        struct UIScrollInfo si;
        if(code==0u)p-=UI_SCROLL_STEP;       /* SB_LINEUP */
        else if(code==1u)p+=UI_SCROLL_STEP;  /* SB_LINEDOWN */
        else if(code==2u)p-=g_ui_view_h;     /* SB_PAGEUP */
        else if(code==3u)p+=g_ui_view_h;     /* SB_PAGEDOWN */
        else if(code==4u||code==5u) {
            si.cbSize=sizeof(si);si.fMask=UI_SIF_TRACKPOS;
            if(GetScrollInfo(hwnd,UI_SB_VERT,&si))p=si.nTrackPos;
        }
        else if(code==6u)p=0;
        else if(code==7u)p=g_ui_page_h[g_ui_current_tab];
        ui_scroll_to(g_ui_current_tab,p);
        return 0;
    }
    if(msg==UI_MOUSEWHEEL) {
        ui_scroll_to(g_ui_current_tab,g_ui_scroll[g_ui_current_tab]-
            ((short)((wp>>16)&0xffffu)>0?UI_SCROLL_STEP*3:-UI_SCROLL_STEP*3));
        return 0;
    }
    return g_ui_prev_content?CallWindowProcA(g_ui_prev_content,hwnd,msg,wp,lp):0;
}
static void ui_set_page(DWORD page) {
    static const char *names[UI_PAGE_COUNT]={"ESP","ROGUE","MOVEMENT","STATUS","SETTINGS"};
    DWORD t,i;
    if(page>=UI_PAGE_COUNT)return;
    g_ui_current_tab=page;
    for(t=0u;t<UI_PAGE_COUNT;++t) {
        if(g_ui_tabs[t]) {
            char label[28],*p=label;
            if(t==page)p=app_str(p,"> ");
            p=app_str(p,names[t]);*p=0;
            SetWindowTextA(g_ui_tabs[t],label);
        }
        for(i=0u;i<g_ui_page_count[t];++i) {
            HWND ctl=g_ui_pages[t][i].hwnd;
            if(ctl)ShowWindow(ctl,t==page?SW_SHOWNOACTIVATE:SW_HIDE);
        }
    }
    ui_scroll_to(page,g_ui_scroll[page]);
    if(page==UI_TAB_ESP)ui_sync_esp();
    else if(page==UI_TAB_ROGUE || page==UI_TAB_MOVEMENT)ui_sync_rogue();
    else if(page==UI_TAB_STATUS){ui_sync_rogue();ui_sync_rear();}
}
static void ui_add_to_page(DWORD page,HWND control) {
    struct RECT32 rc;
    struct POINT32 a,b;
    struct UIPageItem *item;
    if(page>=UI_PAGE_COUNT||!control||!g_ui_content)return;
    if(g_ui_page_count[page]>=UI_MAX_PAGE_CONTROLS)return;
    if(!GetWindowRect(control,&rc))return;
    a.x=rc.left;a.y=rc.top;
    b.x=rc.right;b.y=rc.bottom;
    if(!ScreenToClient(g_ui_content,&a) ||
       !ScreenToClient(g_ui_content,&b))return;
    item=&g_ui_pages[page][g_ui_page_count[page]++];
    item->hwnd=control;item->x=a.x;item->y=a.y;
    item->w=b.x-a.x;item->h=b.y-a.y;
    if(item->y+item->h+24>g_ui_page_h[page])
        g_ui_page_h[page]=item->y+item->h+24;
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
    if(msg==UI_MOUSEWHEEL) {
        ui_scroll_to(g_ui_current_tab,g_ui_scroll[g_ui_current_tab]-
            ((short)((wp>>16)&0xffffu)>0?UI_SCROLL_STEP*3:-UI_SCROLL_STEP*3));
        return 0;
    }
    if(msg==UI_COMMAND) {
        W112_ControlValueV1 value;
        id=wp&0xFFFFu;
        if(id>=201u && id<=205u) {
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

/* Compact native layout: fixed navigation and footer, independent per-tab scroll.
   All gameplay-setting buttons retain their pre-existing verified ABI IDs. */
static BOOL ui_create(HWND game) {
    struct POINT32 pt;
    struct RECT32 rc;
    DWORD i;
    int window_h;
    const char *nav[UI_PAGE_COUNT]={"ESP","ROGUE","MOVEMENT","STATUS","SETTINGS"};
    const char *filters[4]={
        "ESP - show player labels",
        "Show Horde characters",
        "Show Alliance characters",
        "Show hostile players (BG team)"
    };
    if(!game||!IsWindow(game))return FALSE;
    pt.x=pt.y=0;
    if(!GetClientRect(game,&rc)||!ClientToScreen(game,&pt))return FALSE;
    window_h=UI_HEIGHT;
    if(rc.bottom>440 && window_h>rc.bottom-16)window_h=rc.bottom-16;
    g_ui_view_h=window_h-UI_CONTENT_Y-53;
    if(g_ui_view_h<260)g_ui_view_h=260;
    g_parallel_ui_hwnd=CreateWindowExA(WS_EX_TOPMOST|WS_EX_TOOLWINDOW,
        "STATIC","PARALLEL / CONTROL CENTER",WS_POPUP|UI_CAPTION|UI_SYSMENU,
        (int)(pt.x+(rc.right-UI_WIDTH)/2),(int)(pt.y+(rc.bottom-window_h)/2),
        UI_WIDTH,window_h,NULL,NULL,g_self,NULL);
    if(!g_parallel_ui_hwnd)return FALSE;
    g_ui_prev=(WNDPROC32)(DWORD)SetWindowLongA(
        g_parallel_ui_hwnd,GWL_WNDPROC,(LONG)(DWORD)ui_wndproc);
    if(!g_ui_prev){DestroyWindow(g_parallel_ui_hwnd);g_parallel_ui_hwnd=NULL;return FALSE;}
    g_ui_font=CreateFontA(-19,0,0,0,500,0,0,0,1,0,0,0,0,"Segoe UI");
    g_ui_title_font=CreateFontA(-27,0,0,0,700,0,0,0,1,0,0,0,0,"Segoe UI");
    ui_label(g_parallel_ui_hwnd,"PARALLEL / CONTROL CENTER",20,12,748,36,TRUE);
    ui_label(g_parallel_ui_hwnd,"WoW 1.12.1  |  Build 5875  |  PARALLEL TEST",
        22,51,760,24,FALSE);
    for(i=0u;i<UI_PAGE_COUNT;++i)
        g_ui_tabs[i]=ui_button(g_parallel_ui_hwnd,nav[i],18,97+(int)i*61,
                              164,48,201u+i,FALSE);
    ui_label(g_parallel_ui_hwnd,"PARALLEL - TEST CANDIDATE",18,window_h-44,370,28,FALSE);
    ui_label(g_parallel_ui_hwnd,"Insert - Close",650,window_h-44,150,28,FALSE);
    g_ui_content=CreateWindowExA(0u,"STATIC","",
        UI_CHILD|UI_VISIBLE|UI_WS_VSCROLL|UI_WS_BORDER,
        UI_CONTENT_X,UI_CONTENT_Y,UI_CONTENT_W,g_ui_view_h,
        g_parallel_ui_hwnd,NULL,g_self,NULL);
    if(!g_ui_content)return FALSE;
    g_ui_prev_content=(WNDPROC32)(DWORD)SetWindowLongA(
        g_ui_content,GWL_WNDPROC,(LONG)(DWORD)ui_content_wndproc);
    if(!g_ui_prev_content)return FALSE;

    /* ESP -- native cache/filter behavior remains unchanged. */
    ui_add_to_page(UI_TAB_ESP,ui_label(g_ui_content,"PLAYER ESP",18,15,525,38,TRUE));
    ui_add_to_page(UI_TAB_ESP,ui_label(g_ui_content,
        "Live filters. Click a visible ESP label to target.",20,60,535,49,FALSE));
    for(i=0u;i<4u;++i) {
        g_ui_checks[i]=ui_button(g_ui_content,filters[i],20,120+(int)i*61,
                                 526,47,101u+i,TRUE);
        ui_add_to_page(UI_TAB_ESP,g_ui_checks[i]);
    }
    ui_add_to_page(UI_TAB_ESP,ui_label(g_ui_content,
        "Faction filters combine (OR). Hostile mode follows BG teams.",
        22,379,528,64,FALSE));

    /* Rogue -- short, separate function rows; all toggles are live values. */
    ui_add_to_page(UI_TAB_ROGUE,ui_label(g_ui_content,"ROGUE",18,12,527,39,TRUE));
    ui_add_to_page(UI_TAB_ROGUE,ui_label(g_ui_content,
        "Stealth Floor",21,61,526,34,TRUE));
    g_ui_speedfloor_check=ui_button(g_ui_content,"Enable Stealth Floor",
        24,103,522,41,105u,TRUE);
    ui_add_to_page(UI_TAB_ROGUE,g_ui_speedfloor_check);
    g_ui_hostile_guard_check=ui_button(g_ui_content,
        "Disable floor on hostile player target",24,151,522,44,106u,TRUE);
    ui_add_to_page(UI_TAB_ROGUE,g_ui_hostile_guard_check);
    g_ui_speedfloor_value=ui_label(g_ui_content,"",24,213,340,32,FALSE);
    ui_add_to_page(UI_TAB_ROGUE,g_ui_speedfloor_value);
    ui_add_to_page(UI_TAB_ROGUE,ui_button(g_ui_content,"-",387,204,62,46,107u,FALSE));
    ui_add_to_page(UI_TAB_ROGUE,ui_button(g_ui_content,"+",478,204,62,46,108u,FALSE));
    g_ui_speedfloor_state=ui_label(g_ui_content,"",24,263,532,49,FALSE);
    ui_add_to_page(UI_TAB_ROGUE,g_ui_speedfloor_state);
    ui_add_to_page(UI_TAB_ROGUE,ui_label(g_ui_content,"Pick Pocket",21,332,524,37,TRUE));
    g_ui_pp_check=ui_button(g_ui_content,"Automatic Pick Pocket (F11)",
                            24,377,522,44,109u,TRUE);
    ui_add_to_page(UI_TAB_ROGUE,g_ui_pp_check);
    g_ui_pp_control_state=ui_label(g_ui_content,"",24,430,530,60,FALSE);
    ui_add_to_page(UI_TAB_ROGUE,g_ui_pp_control_state);
    ui_add_to_page(UI_TAB_ROGUE,ui_label(g_ui_content,"Auto Junkbox",21,515,524,37,TRUE));
    g_ui_junkbox_check=ui_button(g_ui_content,"Open eligible junkboxes",
                                 24,559,522,44,110u,TRUE);
    ui_add_to_page(UI_TAB_ROGUE,g_ui_junkbox_check);
    ui_add_to_page(UI_TAB_ROGUE,ui_label(g_ui_content,
        "AutoLootPP and LongPP are exact-byte loaded modules, not hot-unloaded.",
        24,624,525,74,FALSE));

    /* Movement exposes *verified* runtime status, not fictional new controls. */
    ui_add_to_page(UI_TAB_MOVEMENT,ui_label(g_ui_content,"MOVEMENT",18,12,520,39,TRUE));
    ui_add_to_page(UI_TAB_MOVEMENT,ui_label(g_ui_content,
        "MovementCore",22,63,516,39,TRUE));
    ui_add_to_page(UI_TAB_MOVEMENT,ui_label(g_ui_content,
        "Shared movement / PP arbitration and current F11 state.",24,110,520,66,FALSE));
    ui_add_to_page(UI_TAB_MOVEMENT,ui_label(g_ui_content,
        "Rear 360",22,201,516,39,TRUE));
    ui_add_to_page(UI_TAB_MOVEMENT,ui_label(g_ui_content,
        "Cast-synchronized NPC-only diagnostics are shown in Status.",24,253,518,76,FALSE));
    ui_add_to_page(UI_TAB_MOVEMENT,ui_label(g_ui_content,
        "Movement settings will appear here only after their native control ABI is verified.",
        24,355,515,100,FALSE));

    /* Status: distinguish loader presence, live setting and server outcome.
       Use multiple short rows; rear diagnostics get room for all counters. */
    ui_add_to_page(UI_TAB_STATUS,ui_label(g_ui_content,"MODULE STATUS",18,12,526,39,TRUE));
    ui_add_to_page(UI_TAB_STATUS,ui_label(g_ui_content,
        "LOADED = DLL present. PP / loot / rear success requires an in-game test.",
        20,61,528,74,FALSE));
    ui_add_to_page(UI_TAB_STATUS,ui_label(g_ui_content,"Player ESP",22,147,519,32,TRUE));
    g_ui_esp_state=ui_label(g_ui_content,"",24,182,522,43,FALSE);
    ui_add_to_page(UI_TAB_STATUS,g_ui_esp_state);
    ui_add_to_page(UI_TAB_STATUS,ui_label(g_ui_content,
        "PickPocketSelectiveRange",22,237,525,34,TRUE));
    g_ui_range_state=ui_label(g_ui_content,"",24,275,520,50,FALSE);
    ui_add_to_page(UI_TAB_STATUS,g_ui_range_state);
    ui_add_to_page(UI_TAB_STATUS,ui_label(g_ui_content,"AutoLootPP",22,339,518,34,TRUE));
    g_ui_autopp_state=ui_label(g_ui_content,"",24,376,520,46,FALSE);
    ui_add_to_page(UI_TAB_STATUS,g_ui_autopp_state);
    ui_add_to_page(UI_TAB_STATUS,ui_label(g_ui_content,"Long Pick Pocket",22,438,518,34,TRUE));
    g_ui_longpp_state=ui_label(g_ui_content,"",24,477,520,47,FALSE);
    ui_add_to_page(UI_TAB_STATUS,g_ui_longpp_state);
    ui_add_to_page(UI_TAB_STATUS,ui_label(g_ui_content,"MovementCore",22,536,518,34,TRUE));
    g_ui_core_state=ui_label(g_ui_content,"",24,574,520,47,FALSE);
    ui_add_to_page(UI_TAB_STATUS,g_ui_core_state);
    ui_add_to_page(UI_TAB_STATUS,ui_label(g_ui_content,"SpeedFloor",22,638,518,34,TRUE));
    g_ui_speed_loaded_state=ui_label(g_ui_content,"",24,676,520,45,FALSE);
    ui_add_to_page(UI_TAB_STATUS,g_ui_speed_loaded_state);
    ui_add_to_page(UI_TAB_STATUS,ui_label(g_ui_content,"Rear 360",22,738,518,34,TRUE));
    g_ui_rear_state=ui_label(g_ui_content,"",24,778,518,145,FALSE);
    ui_add_to_page(UI_TAB_STATUS,g_ui_rear_state);
    ui_add_to_page(UI_TAB_STATUS,ui_label(g_ui_content,"Auto WotF",22,941,518,34,TRUE));
    g_ui_wotf_state=ui_label(g_ui_content,"",24,979,520,45,FALSE);
    ui_add_to_page(UI_TAB_STATUS,g_ui_wotf_state);
    ui_add_to_page(UI_TAB_STATUS,ui_label(g_ui_content,"Ground Target Assist",22,1038,518,35,TRUE));
    g_ui_ground_state=ui_label(g_ui_content,"",24,1080,520,47,FALSE);
    ui_add_to_page(UI_TAB_STATUS,g_ui_ground_state);

    ui_add_to_page(UI_TAB_SETTINGS,ui_label(g_ui_content,"SETTINGS",18,12,530,39,TRUE));
    ui_add_to_page(UI_TAB_SETTINGS,ui_label(g_ui_content,
        "Insert: open / close this panel.",24,72,521,47,FALSE));
    ui_add_to_page(UI_TAB_SETTINGS,ui_label(g_ui_content,
        "Use the mouse wheel or the right scrollbar to navigate each page.",
        24,137,521,72,FALSE));
    ui_add_to_page(UI_TAB_SETTINGS,ui_label(g_ui_content,
        "All gameplay settings are available under ESP or Rogue. Legacy PP / loot DLLs cannot be safely hot-unloaded.",
        24,232,518,109,FALSE));

    ui_sync_esp();ui_sync_rogue();ui_sync_rear();
    if(g_ui_speed_loaded_state)SetWindowTextA(g_ui_speed_loaded_state,
        GetModuleHandleA(PAR_SPEED_DLL)?"LOADED - live stealth floor control":"NOT LOADED");
    if(g_ui_wotf_state)SetWindowTextA(g_ui_wotf_state,
        GetModuleHandleA("WoWAutoWotF_5875_v1.dll")?"LOADED - verify CC break in game":"NOT LOADED");
    if(g_ui_ground_state)SetWindowTextA(g_ui_ground_state,
        GetModuleHandleA("WoWGroundTargetAssist_5875_v1.dll")?
            "LOADED - verify targeting in game":"NOT LOADED");
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
    if(g_ui_current_tab==UI_TAB_STATUS && (g_render_frame%15u)==0u){
        ui_sync_rogue();ui_sync_rear();
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
    for(page=0u;page<UI_PAGE_COUNT;++page) {
        g_ui_tabs[page]=NULL;
        g_ui_page_count[page]=0u;
        g_ui_scroll[page]=0;g_ui_page_h[page]=0;
    }
    g_ui_content=NULL;g_ui_prev_content=NULL;
    for(page=0u;page<4u;++page)g_ui_checks[page]=NULL;
    g_ui_speedfloor_check=NULL;g_ui_hostile_guard_check=NULL;
    g_ui_speedfloor_state=NULL;g_ui_speedfloor_value=NULL;
    g_ui_pp_check=NULL;g_ui_junkbox_check=NULL;
    g_ui_pp_control_state=NULL;g_ui_core_state=NULL;
    g_ui_esp_state=NULL;g_ui_autopp_state=NULL;g_ui_longpp_state=NULL;
    g_ui_range_state=NULL;g_ui_rear_state=NULL;
    g_ui_speed_loaded_state=NULL;g_ui_wotf_state=NULL;g_ui_ground_state=NULL;
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
