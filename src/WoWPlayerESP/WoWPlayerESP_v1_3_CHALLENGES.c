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
/* Multibox: the included base uses a PID-qualified diagnostic log so every
 * WoW process can start its ESP worker independently. */
#define W112_PLAYERESP_MULTIBOX_LOG_PID 1
#define DllMain W112_PlayerESP_Base_DllMain
#include "WoWPlayerESP_v1_2_range_sweep.c"
#undef DllMain
#include "../common/W112ControlAPI.h"


#define WM_W112_ESP_BG_SCORE (0x8000u + 0x0113u)
#define WM_W112_REAR_TICK (0x8000u + 0x0119u)

#define VK_INSERT 0x2Du
/* The game WndProc can be superseded by a companion DLL. Sample Insert in the
 * existing render tick as a fallback; both paths share one press latch. */
__declspec(dllimport) short WINAPI GetAsyncKeyState(int);
__declspec(dllimport) DWORD WINAPI GetCurrentProcessId(void);
__declspec(dllimport) DWORD WINAPI GetWindowThreadProcessId(HWND,DWORD*);
static volatile DWORD g_gui_insert_latched=0u;

static BOOL parallel_this_process_foreground(void) {
    DWORD pid=0u;
    HWND active=GetForegroundWindow();
    if(!active) return FALSE;
    if(!GetWindowThreadProcessId(active,&pid)) return FALSE;
    return pid==GetCurrentProcessId();
}
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

/* Quest objective snapshot and NPC marker renderer share the existing ESP threads. */
#include "W112QuestESP.inc"

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
        if(!g_gui_insert_latched) {
            g_gui_insert_latched=1u;
            g_parallel_gui_open=g_parallel_gui_open?0u:1u;
        }
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
    if (msg == WM_W112_QUEST_TICK) {
        quest_poll_game_thread();
        return 0;
    }
    if (msg == WM_W112_ESP_BG_SCORE) {
        chal_bg_score_main_thread();
        return 0;
    }
    if (msg == WM_W112_REAR_TICK) {
        /* This WndProc owns the game's thread. The worker only posts here;
           never call native pose/heartbeat from a foreign worker thread. */
        HMODULE rear=GetModuleHandleA("MovementCore_V68_MINING_HARDLOS_COMBAT_AUTOPP_F11_BLACKLIST_HARDLOS3D_REARONLY_RETRY.dll");
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
                if (g_quest_enabled && g_render_frame>=g_quest_next_post_frame) {
                    if (PostMessageA(g_challenge_hwnd,WM_W112_QUEST_TICK,0u,0))
                        g_quest_next_post_frame=g_render_frame+W112_Q_POLL_FRAMES;
                }
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


/* PARALLEL: one readable native window with real ESP / ROGUE / STATUS / SUMMON tabs.
   The GUI owns its existing ESP render-thread window only: no new game
   WndProc hook, no in-game engine access from GUI callbacks, and no unsafe
   hot-unloading of the legacy hook-owning PP/loot DLLs. */
#define UI_CHILD 0x40000000u
#define UI_VISIBLE 0x10000000u
#define UI_CAPTION 0x00C00000u
#define UI_SYSMENU 0x00080000u
#define UI_SS_WHITERECT 0x00000006u /* suppress duplicate client STATIC caption */
#define UI_CHECKBOX 0x00000002u
#define UI_BUTTON 0x00000000u
#define UI_COMMAND 0x0111u
#define UI_CLOSE 0x0010u
#define UI_PAINT 0x000Fu
#define UI_ERASEBKGND 0x0014u
#define UI_DRAWITEM 0x002Bu
#define UI_CTLCOLORBTN 0x0135u
#define UI_CTLCOLORSTATIC 0x0138u
#define UI_SETFONT 0x0030u
#define UI_SETCHECK 0x00F1u
#define UI_OWNERDRAW 0x0000000Bu
#define UI_ODS_SELECTED 0x0001u
#define UI_WIDTH 920
#define UI_HEIGHT 660
#define UI_CONTENT_X 170
#define UI_SIDEBAR_W 180
#define UI_MAX_PAGE_CONTROLS 20u

/* COLORREF = 0x00BBGGRR. The Parallel panel intentionally stays GDI-only:
   no external UI runtime, no new game hook, and negligible idle cost. */
#define UI_COLOR_SIDEBAR 0x001B1510u
#define UI_COLOR_CONTENT 0x00251F19u
#define UI_COLOR_BUTTON  0x00372E25u
#define UI_COLOR_PRESS   0x004A3D31u
#define UI_COLOR_ACCENT  0x00E39A3Fu
#define UI_COLOR_TEXT    0x00F4EFE9u
#define UI_COLOR_MUTED   0x00BFB5AAu
#define UI_TAB_ESP 0u
#define UI_TAB_ROGUE 1u
#define UI_TAB_STATUS 2u
#define UI_TAB_REAR 3u /* internal details page, same root HWND */
#define UI_TAB_SUMMON 4u
#define UI_TAB_PATROL 5u
#define UI_TAB_FOLLOW 6u

typedef void* HFONT;
typedef void* HBRUSH;
struct PAINTSTRUCT32 {
    HDC hdc; BOOL fErase; struct RECT32 rcPaint; BOOL fRestore; BOOL fIncUpdate;
    BYTE rgbReserved[32];
};
struct DRAWITEMSTRUCT32 {
    UINT CtlType; UINT CtlID; UINT itemID; UINT itemAction; UINT itemState;
    HWND hwndItem; HDC hDC; struct RECT32 rcItem; DWORD itemData;
};
__declspec(dllimport) HFONT WINAPI CreateFontA(int,int,int,int,int,DWORD,DWORD,DWORD,DWORD,DWORD,DWORD,DWORD,DWORD,LPCSTR);
__declspec(dllimport) LONG WINAPI SendMessageA(HWND,UINT,DWORD,LONG);
__declspec(dllimport) BOOL WINAPI SetForegroundWindow(HWND);
__declspec(dllimport) BOOL WINAPI SetWindowTextA(HWND,LPCSTR);
__declspec(dllimport) int WINAPI GetWindowTextA(HWND,char*,int);
__declspec(dllimport) HBRUSH WINAPI CreateSolidBrush(COLORREF);
__declspec(dllimport) int WINAPI FillRect(HDC,const struct RECT32*,HBRUSH);
__declspec(dllimport) COLORREF WINAPI SetBkColor(HDC,COLORREF);
__declspec(dllimport) BOOL WINAPI InvalidateRect(HWND,const struct RECT32*,BOOL);
__declspec(dllimport) HDC WINAPI BeginPaint(HWND,struct PAINTSTRUCT32*);
__declspec(dllimport) BOOL WINAPI EndPaint(HWND,const struct PAINTSTRUCT32*);

#define PAR_SPEED_DLL "WoWNonPvPSpeedFloor_v0_4_ALWAYS_FLOOR7_1_DIAG.dll"
#define PAR_RANGE_DLL "PickPocketSelectiveRange_5875_v10_PP300_PICKLOCK300_9YD.dll"
#define PAR_LOOT_DLL "WoWAutoLootPP_v0_14_PP300YD_HU_ATTACKABLE_LEVELGATE3_NOSKIP_SELECTORCHECK.dll"
#define PAR_LONGPP_DLL "WoWLongPickPocket_v1_0_ALLRANGE_360FACING_HARDLOS025.dll"
#define PAR_REAR_DLL "MovementCore_V68_MINING_HARDLOS_COMBAT_AUTOPP_F11_BLACKLIST_HARDLOS3D_REARONLY_RETRY.dll"
#define PAR_CORE_DLL "MovementCore_V68_MINING_HARDLOS_COMBAT_AUTOPP_F11_BLACKLIST_HARDLOS3D_REARONLY_RETRY.dll"
#define PAR_WSG_DLL "WoWAutoFlagWSG_5875_v1.dll"
#define PAR_SUMMON_DLL "WoWAutoSummonAssist_5875_v1.dll"

static WNDPROC32 g_ui_prev=NULL;
static HFONT g_ui_font=NULL,g_ui_title_font=NULL;
static HBRUSH g_ui_sidebar_brush=NULL,g_ui_content_brush=NULL;
static HBRUSH g_ui_button_brush=NULL,g_ui_press_brush=NULL,g_ui_accent_brush=NULL;
static HWND g_ui_brand=NULL,g_ui_build=NULL,g_ui_hotkey=NULL;
static HWND g_ui_sidebar_gather=NULL,g_ui_sidebar_chests=NULL;
static HWND g_ui_tabs[6]={NULL,NULL,NULL,NULL,NULL,NULL};
static HWND g_ui_pages[7][UI_MAX_PAGE_CONTROLS];
static DWORD g_ui_page_count[7]={0u,0u,0u,0u,0u,0u,0u};
static DWORD g_ui_current_tab=UI_TAB_ESP;
static HWND g_ui_checks[5]={NULL,NULL,NULL,NULL,NULL};
static HWND g_ui_speedfloor_check=NULL;
static HWND g_ui_hostile_guard_check=NULL;
static HWND g_ui_speedfloor_state=NULL;
static HWND g_ui_speedfloor_value=NULL;
static HWND g_ui_pp_check=NULL,g_ui_pp_recovery_check=NULL,g_ui_pp_low_hp_check=NULL,g_ui_map_fall_check=NULL,g_ui_junkbox_check=NULL;
static HWND g_ui_pp_control_state=NULL,g_ui_core_state=NULL;
static HWND g_ui_autopp_state=NULL;
static HWND g_ui_longpp_state=NULL;
static HWND g_ui_range_state=NULL;
static HWND g_ui_esp_state=NULL;
static HWND g_ui_rear_state=NULL,g_ui_rear_details_state=NULL;
static HWND g_ui_wsg_check=NULL,g_ui_wsg_state=NULL;
static HWND g_ui_summon_check=NULL,g_ui_summon_antiafk_check=NULL;
static HWND g_ui_summon_master_profile=NULL,g_ui_summon_slave_profile=NULL;
static HWND g_ui_summon_loaded=NULL,g_ui_summon_candidate=NULL;
static HWND g_ui_summon_guid=NULL,g_ui_summon_scan=NULL,g_ui_summon_nearest=NULL;
static HWND g_ui_summon_antiafk_state=NULL;
static HWND g_ui_patrol_check=NULL,g_ui_patrol_record_check=NULL;
static HWND g_ui_patrol_route=NULL,g_ui_patrol_config=NULL,g_ui_patrol_stats=NULL,g_ui_patrol_state=NULL;
static HWND g_ui_follow_off=NULL,g_ui_follow_master=NULL,g_ui_follow_follower=NULL;
static HWND g_ui_follow_assist=NULL,g_ui_follow_lazy=NULL,g_ui_follow_teleport=NULL;
static HWND g_ui_follow_state=NULL,g_ui_follow_link=NULL,g_ui_follow_target=NULL,g_ui_follow_config=NULL,g_ui_follow_stats=NULL;
/* Gather is a subview of the existing GUI: no new game-window hook. */
static HWND g_ui_gather_controls[40]={NULL};
static DWORD g_ui_gather_control_pages[40]={0u};
static HWND g_ui_gather_checks[16]={NULL};
static HWND g_ui_gather_extra_checks[4]={NULL};
static HWND g_ui_gather_chest_checks[8]={NULL};
static HWND g_ui_gather_chest_diag=NULL,g_ui_gather_chest_track=NULL,g_ui_gather_chest_native=NULL;
static DWORD g_ui_gather_page=0u;
static HWND g_ui_plane_check=NULL,g_ui_plane_status=NULL;
static HWND g_ui_gather_status=NULL;
static DWORD g_ui_gather_count=0u,g_ui_gather_open=0u;
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

static char *ui_app_centi(char *p,DWORD value) {
    DWORD frac=value%100u;
    p=app_u32(p,value/100u);
    *p++='.';
    if(frac<10u)*p++='0';
    return app_u32(p,frac);
}
static void ui_sync_summon(void) {
    static const char* states[8]={
        "DETACHED","WAIT WORLD","WORLD GRACE","ACTIVE",
        "DISABLED","BUILD MISMATCH","NO TIMER","CAST/CHANNEL"
    };
    static const char* matches[4]={"NONE","ENTRY 36727","TYPE 18","ENTRY+TYPE"};
    const W112_ControlModuleV1 *m=ui_work_pp_module(PAR_SUMMON_DLL,31u);
    W112_ControlValueV1 enabled,alive,candidate,source,entry,type,dist,lo,hi;
    W112_ControlValueV1 pre,current,post,scans,nearCount,nearEntry,nearType,nearDist,status,gate,busy;
    W112_ControlValueV1 anti,nextSec,actions,channelDefers,lastAction,downPosts,upPosts;
    char buf[260],*p;

    if(!m) {
        if(g_ui_summon_check)SendMessageA(g_ui_summon_check,UI_SETCHECK,0u,0);
        if(g_ui_summon_loaded)SetWindowTextA(g_ui_summon_loaded,
            "DLL/API: NOT LOADED - updater/dlls.txt or injection problem");
        if(g_ui_summon_candidate)SetWindowTextA(g_ui_summon_candidate,
            "Candidate: unavailable");
        if(g_ui_summon_guid)SetWindowTextA(g_ui_summon_guid,
            "GUID / retries: unavailable");
        if(g_ui_summon_scan)SetWindowTextA(g_ui_summon_scan,
            "Scanner: unavailable");
        if(g_ui_summon_nearest)SetWindowTextA(g_ui_summon_nearest,
            "Nearest GO: unavailable");
        if(g_ui_summon_antiafk_check)SendMessageA(g_ui_summon_antiafk_check,UI_SETCHECK,0u,0);
        if(g_ui_summon_master_profile)SendMessageA(g_ui_summon_master_profile,UI_SETCHECK,0u,0);
        if(g_ui_summon_slave_profile)SendMessageA(g_ui_summon_slave_profile,UI_SETCHECK,0u,0);
        if(g_ui_summon_antiafk_state)SetWindowTextA(g_ui_summon_antiafk_state,
            "ANTI-AFK: provider unavailable");
        return;
    }

    if(!m->get_value(1u,&enabled))enabled.u32=0u;
    if(!m->get_value(2u,&alive))alive.u32=0u;
    if(!m->get_value(3u,&candidate))candidate.u32=0u;
    if(!m->get_value(4u,&source))source.u32=0u;
    if(!m->get_value(5u,&entry))entry.u32=0u;
    if(!m->get_value(6u,&type))type.u32=0u;
    if(!m->get_value(7u,&dist))dist.u32=0u;
    if(!m->get_value(8u,&lo))lo.u32=0u;
    if(!m->get_value(9u,&hi))hi.u32=0u;
    if(!m->get_value(10u,&pre))pre.u32=0u;
    if(!m->get_value(11u,&current))current.u32=0u;
    if(!m->get_value(12u,&post))post.u32=0u;
    if(!m->get_value(13u,&scans))scans.u32=0u;
    if(!m->get_value(14u,&nearCount))nearCount.u32=0u;
    if(!m->get_value(15u,&nearEntry))nearEntry.u32=0u;
    if(!m->get_value(16u,&nearType))nearType.u32=0u;
    if(!m->get_value(17u,&nearDist))nearDist.u32=0u;
    if(!m->get_value(18u,&status))status.u32=0u;
    if(!m->get_value(19u,&gate))gate.u32=0u;
    if(!m->get_value(20u,&busy))busy.u32=0u;
    if(!m->get_value(21u,&anti))anti.u32=0u;
    if(!m->get_value(22u,&nextSec))nextSec.u32=0u;
    if(!m->get_value(23u,&actions))actions.u32=0u;
    if(!m->get_value(24u,&channelDefers))channelDefers.u32=0u;
    if(!m->get_value(29u,&lastAction))lastAction.u32=0u;
    if(!m->get_value(30u,&downPosts))downPosts.u32=0u;
    if(!m->get_value(31u,&upPosts))upPosts.u32=0u;

    if(g_ui_summon_check)
        SendMessageA(g_ui_summon_check,UI_SETCHECK,enabled.u32?1u:0u,0);
    if(g_ui_summon_antiafk_check)
        SendMessageA(g_ui_summon_antiafk_check,UI_SETCHECK,anti.u32?1u:0u,0);
    if(g_ui_summon_master_profile)
        SendMessageA(g_ui_summon_master_profile,UI_SETCHECK,(!enabled.u32&&!anti.u32)?1u:0u,0);
    if(g_ui_summon_slave_profile)
        SendMessageA(g_ui_summon_slave_profile,UI_SETCHECK,(enabled.u32&&anti.u32)?1u:0u,0);

    if(g_ui_summon_loaded){
        p=buf;p=app_str(p,"DLL: LOADED | API module v");
        p=app_u32(p,(m->module_version>>16)&0xFFFFu);
        p=app_str(p," | scanner heartbeat: ");p=app_str(p,alive.u32?"YES":"NO");
        p=app_str(p," | enabled: ");p=app_str(p,enabled.u32?"ON":"OFF");
        *p=0;SetWindowTextA(g_ui_summon_loaded,buf);
    }
    if(g_ui_summon_candidate){
        p=buf;p=app_str(p,"Ritual candidate: ");p=app_str(p,candidate.u32?"YES":"NO");
        p=app_str(p," | match: ");p=app_str(p,source.u32<4u?matches[source.u32]:"UNKNOWN");
        p=app_str(p," | entry ");p=app_u32(p,entry.u32);
        p=app_str(p," | type ");p=app_u32(p,type.u32);
        p=app_str(p," | dist ");p=ui_app_centi(p,dist.u32);p=app_str(p," yd");
        *p=0;SetWindowTextA(g_ui_summon_candidate,buf);
    }
    if(g_ui_summon_guid){
        p=buf;p=app_str(p,"GUID lo/hi: ");p=app_u32(p,lo.u32);
        *p++='/';p=app_u32(p,hi.u32);
        p=app_str(p," | retry PRE ");p=app_u32(p,current.u32);
        p=app_str(p,"/8 | PRE ");p=app_u32(p,pre.u32);
        p=app_str(p," | Native POST returns ");p=app_u32(p,post.u32);
        *p=0;SetWindowTextA(g_ui_summon_guid,buf);
    }
    if(g_ui_summon_scan){
        p=buf;p=app_str(p,"Scanner ticks: ");p=app_u32(p,scans.u32);
        p=app_str(p," | GO <=12yd: ");p=app_u32(p,nearCount.u32);
        p=app_str(p," | state: ");p=app_str(p,status.u32<8u?states[status.u32]:"UNKNOWN");
        p=app_str(p," | Gate reason ");p=app_u32(p,gate.u32);
        p=app_str(p," | busy ");p=app_u32(p,busy.u32);
        *p=0;SetWindowTextA(g_ui_summon_scan,buf);
    }
    if(g_ui_summon_nearest){
        p=buf;p=app_str(p,"Nearest GO <=12yd: entry ");p=app_u32(p,nearEntry.u32);
        p=app_str(p," | type ");p=app_u32(p,nearType.u32);
        p=app_str(p," | dist ");p=ui_app_centi(p,nearDist.u32);p=app_str(p," yd");
        *p=0;SetWindowTextA(g_ui_summon_nearest,buf);
    }
    if(g_ui_summon_antiafk_state){
        p=buf;p=app_str(p,"ANTI-AFK: ");p=app_str(p,anti.u32?"ON":"OFF");
        p=app_str(p," | next ~");p=app_u32(p,nextSec.u32);p=app_str(p,"s");
        p=app_str(p," | spaces ");p=app_u32(p,actions.u32);
        p=app_str(p," | posts ");p=app_u32(p,downPosts.u32);*p++='/';p=app_u32(p,upPosts.u32);
        p=app_str(p," | last ");p=app_str(p,lastAction.u32==1u?"SPACE":"NONE");
        p=app_str(p," | cast/channel defers ");p=app_u32(p,channelDefers.u32);
        *p=0;SetWindowTextA(g_ui_summon_antiafk_state,buf);
    }
}

static BOOL ui_summon_apply_profile(DWORD slave) {
    const W112_ControlModuleV1 *m=ui_work_pp_module(PAR_SUMMON_DLL,31u);
    W112_ControlValueV1 oldEnabled,oldAnti,value;
    if(!m||!m->get_value(1u,&oldEnabled)||!m->get_value(21u,&oldAnti))return FALSE;
    value.u32=slave?1u:0u;
    if(!m->set_value(1u,&value))return FALSE;
    if(!m->set_value(21u,&value)) {
        m->set_value(1u,&oldEnabled);
        return FALSE;
    }
    return TRUE;
}


static BOOL ui_core_set_u32(DWORD id,DWORD bits) {
    const W112_ControlModuleV1 *m=ui_work_pp_module(PAR_CORE_DLL,89u);
    W112_ControlValueV1 v;
    if(!m)return FALSE;v.u32=bits;return m->set_value(id,&v)?TRUE:FALSE;
}
static BOOL ui_core_set_i32(DWORD id,int value) {
    const W112_ControlModuleV1 *m=ui_work_pp_module(PAR_CORE_DLL,109u);
    W112_ControlValueV1 v;
    if(!m)return FALSE;v.i32=value;return m->set_value(id,&v)?TRUE:FALSE;
}
static void ui_sync_patrol(void) {
    static const char* states[11]={
        "OFF","NO ROUTE","RECORDING","WALKING","PAUSED: PICK POCKET",
        "PAUSED: COMBAT","PAUSED: OTHER MOVEMENT","WRONG AREA",
        "STOPPED: STUCK","READY","SAVED"
    };
    W112_ControlValueV1 enabled,recording,slot,width,spacing,timeout,pauseCombat,resumePP;
    W112_ControlValueV1 points,current,laps,ppPauses,stucks,state,ctm,loaded,saveOk;
    const W112_ControlModuleV1 *m=ui_work_pp_module(PAR_CORE_DLL,89u);
    char buf[260],*p;
    if(!m){
        if(g_ui_patrol_check)SendMessageA(g_ui_patrol_check,UI_SETCHECK,0u,0);
        if(g_ui_patrol_record_check)SendMessageA(g_ui_patrol_record_check,UI_SETCHECK,0u,0);
        if(g_ui_patrol_state)SetWindowTextA(g_ui_patrol_state,"PATROL: MovementCore control API not ready");
        return;
    }
    if(!m->get_value(71u,&enabled))enabled.u32=0u;
    if(!m->get_value(72u,&recording))recording.u32=0u;
    if(!m->get_value(75u,&slot))slot.u32=1u;
    if(!m->get_value(76u,&width))width.u32=100u;
    if(!m->get_value(77u,&spacing))spacing.u32=400u;
    if(!m->get_value(78u,&timeout))timeout.u32=2500u;
    if(!m->get_value(79u,&pauseCombat))pauseCombat.u32=1u;
    if(!m->get_value(80u,&resumePP))resumePP.u32=1u;
    if(!m->get_value(81u,&points))points.u32=0u;
    if(!m->get_value(82u,&current))current.u32=0u;
    if(!m->get_value(83u,&laps))laps.u32=0u;
    if(!m->get_value(84u,&ppPauses))ppPauses.u32=0u;
    if(!m->get_value(85u,&stucks))stucks.u32=0u;
    if(!m->get_value(86u,&state))state.u32=0u;
    if(!m->get_value(87u,&ctm))ctm.u32=0u;
    if(!m->get_value(88u,&loaded))loaded.u32=0u;
    if(!m->get_value(89u,&saveOk))saveOk.u32=0u;
    if(g_ui_patrol_check)SendMessageA(g_ui_patrol_check,UI_SETCHECK,enabled.u32?1u:0u,0);
    if(g_ui_patrol_record_check)SendMessageA(g_ui_patrol_record_check,UI_SETCHECK,recording.u32?1u:0u,0);
    if(g_ui_patrol_state){
        p=buf;p=app_str(p,"PATROL: ");
        p=app_str(p,state.u32<11u?states[state.u32]:"UNKNOWN");
        p=app_str(p," | loaded ");p=app_str(p,loaded.u32?"YES":"NO");
        p=app_str(p," | save ");p=app_str(p,saveOk.u32?"OK":"-");*p=0;
        SetWindowTextA(g_ui_patrol_state,buf);
    }
    if(g_ui_patrol_route){
        p=buf;p=app_str(p,"Route slot ");p=app_u32(p,slot.u32);
        p=app_str(p," | waypoint ");p=app_u32(p,current.u32);
        p=app_str(p," / ");p=app_u32(p,points.u32);*p=0;
        SetWindowTextA(g_ui_patrol_route,buf);
    }
    if(g_ui_patrol_config){
        p=buf;p=app_str(p,"Random +/-");p=ui_app_centi(p,width.u32);
        p=app_str(p," yd | spacing ");p=ui_app_centi(p,spacing.u32);
        p=app_str(p," yd | stuck ");p=app_u32(p,timeout.u32);p=app_str(p," ms");
        p=app_str(p," | combat ");p=app_str(p,pauseCombat.u32?"PAUSE":"IGNORE");
        p=app_str(p," | PP ");p=app_str(p,resumePP.u32?"AUTO RESUME":"HOLD");*p=0;
        SetWindowTextA(g_ui_patrol_config,buf);
    }
    if(g_ui_patrol_stats){
        p=buf;p=app_str(p,"Laps ");p=app_u32(p,laps.u32);
        p=app_str(p," | PP pauses ");p=app_u32(p,ppPauses.u32);
        p=app_str(p," | stuck ");p=app_u32(p,stucks.u32);
        p=app_str(p," | CTM calls ");p=app_u32(p,ctm.u32);*p=0;
        SetWindowTextA(g_ui_patrol_stats,buf);
    }
}


static char *ui_app_signed_centi(char *p,int value) {
    DWORD u;
    if(value<0){*p++='-';u=(DWORD)(-value);}else u=(DWORD)value;
    return ui_app_centi(p,u);
}
static void ui_sync_follow(void) {
    static const char* states[10]={
        "OFF","MASTER: PUBLISHING","WAIT MASTER","FOLLOWING","IN POSITION",
        "SAFE CATCH-UP","PAUSED: MOVEMENT OWNER","ZONE MISMATCH",
        "ASSISTING TAGGED TARGET","STALE / NO MASTER"
    };
    W112_ControlValueV1 role,channel,assist,lazy,tp,dist,tpdist,side,hb,liveDist,tagged,resolved;
    W112_ControlValueV1 pulses,targets,tps,state,pid,zone,link,lazyReady;
    const W112_ControlModuleV1 *m=ui_work_pp_module(PAR_CORE_DLL,109u);
    char buf[260],*p;
    if(!m){
        if(g_ui_follow_state)SetWindowTextA(g_ui_follow_state,"FOLLOW: MovementCore v1.4 not ready");
        return;
    }
    m->get_value(90u,&role);m->get_value(91u,&channel);m->get_value(92u,&assist);
    m->get_value(93u,&lazy);m->get_value(94u,&tp);m->get_value(95u,&dist);
    m->get_value(96u,&tpdist);m->get_value(97u,&side);m->get_value(98u,&hb);
    m->get_value(99u,&liveDist);m->get_value(100u,&tagged);m->get_value(101u,&resolved);
    m->get_value(102u,&pulses);m->get_value(103u,&targets);m->get_value(104u,&tps);
    m->get_value(105u,&state);m->get_value(106u,&pid);m->get_value(107u,&zone);
    m->get_value(108u,&link);m->get_value(109u,&lazyReady);
    if(g_ui_follow_off)SendMessageA(g_ui_follow_off,UI_SETCHECK,role.i32==0?1u:0u,0);
    if(g_ui_follow_master)SendMessageA(g_ui_follow_master,UI_SETCHECK,role.i32==1?1u:0u,0);
    if(g_ui_follow_follower)SendMessageA(g_ui_follow_follower,UI_SETCHECK,role.i32==2?1u:0u,0);
    if(g_ui_follow_assist)SendMessageA(g_ui_follow_assist,UI_SETCHECK,assist.u32?1u:0u,0);
    if(g_ui_follow_lazy)SendMessageA(g_ui_follow_lazy,UI_SETCHECK,lazy.u32?1u:0u,0);
    if(g_ui_follow_teleport)SendMessageA(g_ui_follow_teleport,UI_SETCHECK,tp.u32?1u:0u,0);
    if(g_ui_follow_state){
        p=buf;p=app_str(p,"ROLE ");
        p=app_str(p,role.i32==1?"MASTER":(role.i32==2?"FOLLOWER":"OFF"));
        p=app_str(p," | channel ");p=app_u32(p,channel.u32);
        p=app_str(p," | ");p=app_str(p,state.u32<10u?states[state.u32]:"UNKNOWN");*p=0;
        SetWindowTextA(g_ui_follow_state,buf);
    }
    if(g_ui_follow_link){
        p=buf;p=app_str(p,"Link ");p=app_str(p,link.u32?"READY":"WAIT");
        p=app_str(p," | master PID ");p=app_u32(p,pid.u32);
        p=app_str(p," | heartbeat ");p=app_u32(p,hb.u32);p=app_str(p," ms");
        p=app_str(p," | map ");p=app_str(p,zone.u32?"MATCH":"NO");*p=0;
        SetWindowTextA(g_ui_follow_link,buf);
    }
    if(g_ui_follow_target){
        p=buf;p=app_str(p,"MASTER TAG ONLY: LOCKED ON | tagged ");
        p=app_str(p,tagged.u32?"YES":"NO");
        p=app_str(p," | resolved ");p=app_str(p,resolved.u32?"YES":"NO");
        p=app_str(p," | LazyScript ");p=app_str(p,lazyReady.u32?"READY":"WAIT");*p=0;
        SetWindowTextA(g_ui_follow_target,buf);
    }
    if(g_ui_follow_config){
        p=buf;p=app_str(p,"Distance ");p=ui_app_centi(p,dist.u32);
        p=app_str(p," yd | catch-up >");p=ui_app_centi(p,tpdist.u32);
        p=app_str(p," yd | side ");p=ui_app_signed_centi(p,side.i32);
        p=app_str(p," yd | live ");p=ui_app_centi(p,liveDist.u32);p=app_str(p," yd");*p=0;
        SetWindowTextA(g_ui_follow_config,buf);
    }
    if(g_ui_follow_stats){
        p=buf;p=app_str(p,"Rotation pulses ");p=app_u32(p,pulses.u32);
        p=app_str(p," | targets ");p=app_u32(p,targets.u32);
        p=app_str(p," | catch-up starts ");p=app_u32(p,tps.u32);*p=0;
        SetWindowTextA(g_ui_follow_stats,buf);
    }
}

/* The active Parallel GUI is PlayerESP; gather stays inside MovementCore.
 * Page 0: vein blacklist. Page 1: AutoChest. Page 2: gather options.
 * All HWND children retain the root parent so WM_COMMAND routing is stable. */
static void ui_sync_gather(void) {
    static const DWORD extra_ids[4]={3u,25u,27u,22u};
    DWORD i;
    W112_ControlValueV1 v;
    BOOL live=ui_work_pp_module(PAR_CORE_DLL,36u)!=NULL;
    for(i=0u;i<16u;++i) {
        DWORD id=i==0u?1u:(i==1u?26u:i+6u);
        DWORD checked=live&&ui_work_pp_get(PAR_CORE_DLL,36u,id,&v)&&v.u32?1u:0u;
        if(g_ui_gather_checks[i])
            SendMessageA(g_ui_gather_checks[i],UI_SETCHECK,checked,0);
    }
    for(i=0u;i<4u;++i) {
        DWORD checked=live&&ui_work_pp_get(PAR_CORE_DLL,36u,extra_ids[i],&v)&&v.u32?1u:0u;
        if(g_ui_gather_extra_checks[i])
            SendMessageA(g_ui_gather_extra_checks[i],UI_SETCHECK,checked,0);
    }
    for(i=0u;i<8u;++i) {
        DWORD checked=live&&ui_work_pp_get(PAR_CORE_DLL,36u,29u+i,&v)&&v.u32?1u:0u;
        if(g_ui_gather_chest_checks[i])
            SendMessageA(g_ui_gather_chest_checks[i],UI_SETCHECK,checked,0);
    }
    if(g_ui_plane_check){
        DWORD on=live&&ui_work_pp_get(PAR_CORE_DLL,48u,45u,&v)&&v.u32?1u:0u;
        SendMessageA(g_ui_plane_check,UI_SETCHECK,on,0);
    }
    if(g_ui_plane_status){
        W112_ControlValueV1 depth,packets;
        char buf[180],*q=buf;
        BOOL ok=live&&ui_work_pp_get(PAR_CORE_DLL,48u,46u,&depth)&&
                ui_work_pp_get(PAR_CORE_DLL,48u,47u,&packets);
        if(!ok)SetWindowTextA(g_ui_plane_status,"Plane TEST: module not ready");
        else{
            q=app_str(q,"Outbound Z -");q=app_u32(q,depth.u32);
            q=app_str(q," yd | packets: ");q=app_u32(q,packets.u32);
            q=app_str(q," | server ACK unknown");*q=0;
            SetWindowTextA(g_ui_plane_status,buf);
        }
    }
    if(g_ui_gather_chest_track) {
        DWORD checked=live&&ui_work_pp_get(PAR_CORE_DLL,44u,43u,&v)&&v.u32?1u:0u;
        SendMessageA(g_ui_gather_chest_track,UI_SETCHECK,checked,0);
    }
    if(g_ui_gather_chest_native) {
        DWORD checked=live&&ui_work_pp_get(PAR_CORE_DLL,50u,49u,&v)&&v.u32?1u:0u;
        SendMessageA(g_ui_gather_chest_native,UI_SETCHECK,checked,0);
    }
    if(g_ui_gather_chest_diag){
        static const char* reasons[10]={"NONE","READY","OFF","TYPE OFF","COMBAT","LOOTED","NO XYZ","RANGE","ACTIVE","AGGRO SKIP"};
        W112_ControlValueV1 seen,eligible,entry,step,reason,source;
        char buf[160],*p=buf;
        BOOL ok=live&&ui_work_pp_get(PAR_CORE_DLL,40u,37u,&seen)&&
            ui_work_pp_get(PAR_CORE_DLL,40u,38u,&eligible)&&
            ui_work_pp_get(PAR_CORE_DLL,40u,39u,&entry)&&
            ui_work_pp_get(PAR_CORE_DLL,42u,40u,&step)&&
            ui_work_pp_get(PAR_CORE_DLL,42u,41u,&reason)&&
            ui_work_pp_get(PAR_CORE_DLL,42u,42u,&source);
        if(!ok)SetWindowTextA(g_ui_gather_chest_diag,"Chest scanner: NOT READY");
        else{
            p=app_str(p,"Chest ");p=app_u32(p,seen.u32);
            p=app_str(p,"/");p=app_u32(p,eligible.u32);
            p=app_str(p," | entry ");p=app_u32(p,entry.u32);
            p=app_str(p," | ");p=app_str(p,reason.u32<10u?reasons[reason.u32]:"UNKNOWN");
            p=app_str(p," | XYZ src ");p=app_u32(p,source.u32);
            p=app_str(p," | Z step ");p=app_u32(p,step.u32);
            if(ui_work_pp_get(PAR_CORE_DLL,50u,49u,&v)&&v.u32) {
                W112_ControlValueV1 mask;
                if(ui_work_pp_get(PAR_CORE_DLL,50u,50u,&mask)){
                    p=app_str(p," | native mask ");
                    p=app_u32(p,mask.u32);
                }
            }
            *p=0;SetWindowTextA(g_ui_gather_chest_diag,buf);
        }
    }
    if(g_ui_gather_status)SetWindowTextA(g_ui_gather_status,
        !live?"MovementCore controls unavailable: update Parallel candidate.":
        g_ui_gather_page==0u?"Checked ore = skip while vein blacklist is ON.":
        g_ui_gather_page==1u?"AutoChest: Mining spoof from Z -4, then 3D LOS retries.":
                             "Gather, AutoOpen and AutoChest share ONE MovementCore.");
}
static void ui_show_gather_page(DWORD page) {
    DWORD i;
    if(g_ui_current_tab!=UI_TAB_ROGUE || page>2u)return;
    g_ui_gather_open=1u;g_ui_gather_page=page;
    if(g_ui_sidebar_gather)InvalidateRect(g_ui_sidebar_gather,NULL,TRUE);
    if(g_ui_sidebar_chests)InvalidateRect(g_ui_sidebar_chests,NULL,TRUE);
    if(g_ui_tabs[1])InvalidateRect(g_ui_tabs[1],NULL,TRUE);
    for(i=0u;i<g_ui_page_count[UI_TAB_ROGUE];++i)
        if(g_ui_pages[UI_TAB_ROGUE][i])
            ShowWindow(g_ui_pages[UI_TAB_ROGUE][i],SW_HIDE);
    for(i=0u;i<g_ui_gather_count;++i)
        if(g_ui_gather_controls[i])
            ShowWindow(g_ui_gather_controls[i],
                g_ui_gather_control_pages[i]==page||g_ui_gather_control_pages[i]==3u?
                SW_SHOWNOACTIVATE:SW_HIDE);
    ui_sync_gather();
}
static void ui_show_gather(void) {ui_show_gather_page(0u);}
static void ui_add_gather_page_control(HWND control,DWORD page) {
    if(control && g_ui_gather_count<40u) {
        g_ui_gather_control_pages[g_ui_gather_count]=page;
        g_ui_gather_controls[g_ui_gather_count++]=control;
    }
}
static void ui_add_gather_control(HWND control) {
    ui_add_gather_page_control(control,0u);
}
static void ui_sync_esp(void) {
    DWORD state[4]={g_esp_enabled,g_parallel_show_horde,
                    g_parallel_show_alliance,g_parallel_show_hostile};
    DWORD i;
    for(i=0u;i<4u;++i)
        if(g_ui_checks[i]) SendMessageA(g_ui_checks[i],UI_SETCHECK,state[i]?1u:0u,0);
    if(g_ui_checks[4])SendMessageA(g_ui_checks[4],UI_SETCHECK,g_quest_enabled?1u:0u,0);
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
        W112_ControlValueV1 pp,junk,recovery,phase,resets,casts;
        BOOL ppLive=ui_work_pp_get(PAR_CORE_DLL,25u,2u,&pp);
        BOOL junkLive=ui_work_pp_get(PAR_RANGE_DLL,7u,1u,&junk);
        W112_ControlValueV1 lowHp,hold,hpPercent;
        BOOL recoveryLive=ui_work_pp_get(PAR_CORE_DLL,70u,60u,&recovery);
        W112_ControlValueV1 mapFall;
        BOOL lowHpLive=ui_work_pp_get(PAR_CORE_DLL,70u,66u,&lowHp);
        BOOL mapFallLive=ui_work_pp_get(PAR_CORE_DLL,70u,70u,&mapFall);
        if(g_ui_pp_check)SendMessageA(g_ui_pp_check,UI_SETCHECK,
                                      ppLive&&pp.u32?1u:0u,0);
        if(g_ui_pp_recovery_check)SendMessageA(g_ui_pp_recovery_check,UI_SETCHECK,
            recoveryLive&&recovery.u32?1u:0u,0);
        if(g_ui_pp_low_hp_check)SendMessageA(g_ui_pp_low_hp_check,UI_SETCHECK,
            lowHpLive&&lowHp.u32?1u:0u,0);
        if(g_ui_map_fall_check)SendMessageA(g_ui_map_fall_check,UI_SETCHECK,
            mapFallLive&&mapFall.u32?1u:0u,0);
        if(g_ui_junkbox_check)SendMessageA(g_ui_junkbox_check,UI_SETCHECK,
                                           junkLive&&junk.u32?1u:0u,0);
        if(g_ui_pp_control_state){
            char info[210],*q=info;
            if(!ppLive)q=app_str(q,"AutoPP: MovementCore unavailable");
            else if(!recoveryLive)q=app_str(q,"AutoPP: recovery control unavailable");
            else{
                q=app_str(q,recovery.u32?"Auto Stealth: ON":"Auto Stealth: OFF");
                if(ui_work_pp_get(PAR_CORE_DLL,70u,61u,&phase)&&
                   ui_work_pp_get(PAR_CORE_DLL,70u,62u,&resets)&&
                   ui_work_pp_get(PAR_CORE_DLL,70u,63u,&casts)){
                    q=app_str(q," | phase ");q=app_u32(q,phase.u32);
                    q=app_str(q," | ALT ");q=app_u32(q,resets.u32);
                    q=app_str(q," | Stealth ");q=app_u32(q,casts.u32);
                }
                if(lowHpLive&&lowHp.u32&&
                   ui_work_pp_get(PAR_CORE_DLL,70u,67u,&hold)&&
                   ui_work_pp_get(PAR_CORE_DLL,70u,68u,&hpPercent)){
                    q=app_str(q," | HP ");q=app_u32(q,hpPercent.u32);
                    q=app_str(q,hold.u32?"% HOLD":"% OK");
                }
            }
            *q=0;SetWindowTextA(g_ui_pp_control_state,info);
        }
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
    char buf[320],*p=buf;
    if(!g_ui_rear_state)return;
    if(!dll){
        SetWindowTextA(g_ui_rear_state,"Rear360: NOT LOADED");
        if(g_ui_rear_details_state)SetWindowTextA(g_ui_rear_details_state,"Rear360: NOT LOADED");
        return;
    }
    status=(RearValueFn)GetProcAddress(dll,"PVERear360_GetStatus");
    count=(RearValueFn)GetProcAddress(dll,"PVERear360_GetPulseCount");
    if(!status||!count){
        SetWindowTextA(g_ui_rear_state,"Rear360: diagnostics unavailable");
        if(g_ui_rear_details_state)SetWindowTextA(g_ui_rear_details_state,"Rear360: diagnostics unavailable");
        return;
    }
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
    /* The STATUS list uses one bounded visual row; never render live counters
       underneath the next module's child HWND. All counters stay on a separate
       native page, with the same existing Win32 parent and message routing. */
    p=app_str(p,"Rear360: ");p=app_str(p,desc);*p=0;
    SetWindowTextA(g_ui_rear_state,buf);
    if(!g_ui_rear_details_state)return;
    p=buf;
    p=app_str(p,"Rear360: ");p=app_str(p,desc);
    p=app_str(p,"\r\n\r\nAttempts ");p=app_u32(p,attempts?attempts():0u);
    p=app_str(p,"  |  primed ");p=app_u32(p,pulses);
    p=app_str(p,"\r\nSent ");p=app_u32(p,tx?tx():0u);
    p=app_str(p,"  |  GO ");p=app_u32(p,go?go():0u);
    p=app_str(p,"\r\nPositional failures ");p=app_u32(p,err?err():0u);
    p=app_str(p,"  |  retries ");p=app_u32(p,retry?retry():0u);
    p=app_str(p,"\r\nBusy ");p=app_u32(p,busy?busy():0u);
    p=app_str(p,"  |  cancelled ");p=app_u32(p,aborted?aborted():0u);*p=0;
    SetWindowTextA(g_ui_rear_details_state,buf);
}

/* Parallel's actual in-game GUI lives in PlayerESP, not ControlHub. Save only
 * writable controls shown in that GUI, with an INI next to the game EXE.
 * Updater-managed EXE/DLL replacement does not touch this local preference file. */
#define UI_PROFILE_NAME "wow112_parallel_gui.ini"
#define UI_PROFILE_POLL_FRAMES 30u
__declspec(dllimport) DWORD WINAPI GetPrivateProfileStringA(LPCSTR,LPCSTR,LPCSTR,char*,DWORD,LPCSTR);
__declspec(dllimport) BOOL WINAPI WritePrivateProfileStringA(LPCSTR,LPCSTR,LPCSTR,LPCSTR);
static char g_ui_profile_path[512];
static BOOL g_ui_profile_initialized=FALSE;
static DWORD g_ui_profile_next_frame=0u;
static const DWORD g_ui_profile_core_ids[]={1u,2u,3u,8u,9u,10u,11u,12u,13u,14u,15u,16u,17u,18u,19u,20u,21u,22u,25u,26u,27u,29u,30u,31u,32u,33u,34u,35u,36u,43u,46u,49u,60u,66u,70u,75u,76u,77u,78u,79u,80u};
static const DWORD g_ui_profile_floor_ids[]={1u,2u,3u};
static const DWORD g_ui_profile_single_ids[]={1u};
static const DWORD g_ui_profile_summon_ids[]={1u,21u};
struct UiProfileModule {
    const char *dll;
    DWORD minimum;
    const DWORD *ids;
    DWORD count;
    BOOL restored;
    DWORD last[48];
    BYTE seen[48];
};
static struct UiProfileModule g_ui_profile_modules[]={
    {PAR_CORE_DLL,89u,g_ui_profile_core_ids,41u,FALSE,{0},{0}},
    {PAR_SPEED_DLL,3u,g_ui_profile_floor_ids,3u,FALSE,{0},{0}},
    {PAR_RANGE_DLL,7u,g_ui_profile_single_ids,1u,FALSE,{0},{0}},
    {PAR_WSG_DLL,4u,g_ui_profile_single_ids,1u,FALSE,{0},{0}},
    {PAR_SUMMON_DLL,31u,g_ui_profile_summon_ids,2u,FALSE,{0},{0}}
};
static volatile DWORD *const g_ui_profile_esp_flags[]={
    &g_esp_enabled,&g_parallel_show_horde,&g_parallel_show_alliance,&g_parallel_show_hostile,&g_quest_enabled
};
static DWORD g_ui_profile_esp_last[5];

static void ui_profile_key(char key[16],DWORD id) {
    char *end=app_u32(key,id);
    *end=0;
}
static BOOL ui_profile_read(const char *section,const char *key,DWORD *out) {
    static const char hex[]="0123456789ABCDEF";
    char value[16];
    DWORD i,bits=0u;
    if(!g_ui_profile_path[0]||!section||!key||!out)return FALSE;
    if(GetPrivateProfileStringA(section,key,"",value,sizeof(value),g_ui_profile_path)!=8u)
        return FALSE;
    for(i=0u;i<8u;++i) {
        const char *p=hex;
        while(*p && *p!=value[i])++p;
        if(!*p)return FALSE;
        bits=(bits<<4u)|(DWORD)(p-hex);
    }
    *out=bits;
    return TRUE;
}
static BOOL ui_profile_write(const char *section,const char *key,DWORD bits) {
    static const char hex[]="0123456789ABCDEF";
    char text[9];
    DWORD i;
    if(!g_ui_profile_path[0]||!section||!key)return FALSE;
    for(i=0u;i<8u;++i)text[i]=hex[(bits>>(28u-i*4u))&15u];
    text[8]=0;
    return WritePrivateProfileStringA(section,key,text,g_ui_profile_path);
}
static BOOL ui_profile_value_valid(const W112_ControlSettingV1 *s,W112_ControlValueV1 value) {
    DWORD i;
    if(!s||(s->flags&W112_CTL_READ_ONLY))return FALSE;
    if(s->type==W112_CTL_BOOL)return value.u32<=1u;
    if(s->type==W112_CTL_INT)return value.i32>=s->min_value.i32&&value.i32<=s->max_value.i32;
    if(s->type==W112_CTL_FLOAT)return value.f32>=s->min_value.f32&&value.f32<=s->max_value.f32;
    if(s->type==W112_CTL_ENUM) {
        for(i=0u;i<s->enum_option_count;++i)
            if(s->enum_options&&s->enum_options[i].value==value.i32)return TRUE;
    }
    return FALSE;
}
static const W112_ControlSettingV1 *ui_profile_descriptor(const W112_ControlModuleV1 *m,DWORD id) {
    DWORD i;
    if(!m||!m->settings)return NULL;
    for(i=0u;i<m->setting_count;++i)
        if(m->settings[i].setting_id==id&&m->settings[i].struct_size>=sizeof(W112_ControlSettingV1))
            return &m->settings[i];
    return NULL;
}
static void ui_filters_changed(void); /* callback defined below; required by x86 C99 compiler */
static void ui_profile_bootstrap(void) {
    DWORD n,start,i,bits;
    if(g_ui_profile_initialized)return;
    g_ui_profile_initialized=TRUE;
    n=GetModuleFileNameA(NULL,g_ui_profile_path,sizeof(g_ui_profile_path));
    if(!n||n>=sizeof(g_ui_profile_path)){g_ui_profile_path[0]=0;return;}
    start=n;
    while(start&&g_ui_profile_path[start-1u]!='\\'&&g_ui_profile_path[start-1u]!='/')--start;
    if(!start||start+sizeof(UI_PROFILE_NAME)>sizeof(g_ui_profile_path)) {
        g_ui_profile_path[0]=0;return;
    }
    for(i=0u;i<sizeof(UI_PROFILE_NAME);++i)
        g_ui_profile_path[start+i]=UI_PROFILE_NAME[i];
    for(i=0u;i<5u;++i) {
        char key[16];
        ui_profile_key(key,i+1u);
        if(ui_profile_read("esp",key,&bits)&&bits<=1u)
            *g_ui_profile_esp_flags[i]=bits;
        g_ui_profile_esp_last[i]=*g_ui_profile_esp_flags[i]?1u:0u;
    }
    if(!g_esp_enabled)g_range_sweep_enabled=0u;
    ui_filters_changed();
}
/* A module can load later than ESP. Restore it only when its control API is
 * live; missing providers cannot overwrite old preferences with defaults.
 * Subsequent polling also catches F9/F11 hotkey changes while the GUI is shut. */
static void ui_profile_sync(void) {
    DWORD i,j,bits;
    if(!g_ui_profile_initialized)ui_profile_bootstrap();
    if(!g_ui_profile_path[0])return;
    for(i=0u;i<5u;++i) {
        DWORD live=*g_ui_profile_esp_flags[i]?1u:0u;
        if(live!=g_ui_profile_esp_last[i]) {
            char key[16];
            ui_profile_key(key,i+1u);
            if(ui_profile_write("esp",key,live))g_ui_profile_esp_last[i]=live;
        }
    }
    for(i=0u;i<sizeof(g_ui_profile_modules)/sizeof(g_ui_profile_modules[0]);++i) {
        struct UiProfileModule *p=&g_ui_profile_modules[i];
        const W112_ControlModuleV1 *m=ui_work_pp_module(p->dll,p->minimum);
        if(!m||!m->module_id||!m->settings)continue;
        if(!p->restored) {
            BOOL ready=TRUE;
            for(j=0u;j<p->count;++j) {
                const W112_ControlSettingV1 *s=ui_profile_descriptor(m,p->ids[j]);
                W112_ControlValueV1 value;
                char key[16];
                if(!s||(s->flags&W112_CTL_READ_ONLY)||!m->get_value(p->ids[j],&value)) {
                    ready=FALSE;break;
                }
                ui_profile_key(key,p->ids[j]);
                if(ui_profile_read(m->module_id,key,&bits)) {
                    W112_ControlValueV1 saved;
                    saved.u32=bits;
                    if(ui_profile_value_valid(s,saved)) {
                        if(!m->set_value(p->ids[j],&saved)||!m->get_value(p->ids[j],&value)) {
                            ready=FALSE;break;
                        }
                    }
                }
                p->last[j]=value.u32;
                p->seen[j]=1u;
            }
            if(ready)p->restored=TRUE;
            continue;
        }
        for(j=0u;j<p->count;++j) {
            const W112_ControlSettingV1 *s=ui_profile_descriptor(m,p->ids[j]);
            W112_ControlValueV1 value;
            char key[16];
            if(!s||(s->flags&W112_CTL_READ_ONLY)||!m->get_value(p->ids[j],&value))
                continue;
            if(p->seen[j]&&p->last[j]==value.u32)continue;
            ui_profile_key(key,p->ids[j]);
            if(ui_profile_write(m->module_id,key,value.u32)) {
                p->last[j]=value.u32;
                p->seen[j]=1u;
            }
        }
    }
}

/* Switching tabs changes only HWND visibility; ESP cache rescans are
   requested solely when a filter actually changes. */
static void ui_set_page(DWORD page) {
    static const char *tab_names[6][6]={
        {"ESP","ROGUE","STATUS","SUMMON","PATROL","FOLLOW"},
        {"ESP","ROGUE","STATUS","SUMMON","PATROL","FOLLOW"},
        {"ESP","ROGUE","STATUS","SUMMON","PATROL","FOLLOW"},
        {"ESP","ROGUE","STATUS","SUMMON","PATROL","FOLLOW"},
        {"ESP","ROGUE","STATUS","SUMMON","PATROL","FOLLOW"},
        {"ESP","ROGUE","STATUS","SUMMON","PATROL","FOLLOW"}
    };
    DWORD t,i;
    DWORD active_tab=page==UI_TAB_REAR?UI_TAB_STATUS:
        (page==UI_TAB_SUMMON?3u:(page==UI_TAB_PATROL?4u:(page==UI_TAB_FOLLOW?5u:page)));
    if(page>UI_TAB_FOLLOW)return;
    g_ui_current_tab=page;
    g_ui_gather_open=0u;
    for(i=0u;i<g_ui_gather_count;++i)
        if(g_ui_gather_controls[i])ShowWindow(g_ui_gather_controls[i],SW_HIDE);
    for(t=0u;t<6u;++t)
        if(g_ui_tabs[t])SetWindowTextA(g_ui_tabs[t],tab_names[active_tab][t]);
    for(t=0u;t<7u;++t)
        for(i=0u;i<g_ui_page_count[t];++i) {
            HWND control=g_ui_pages[t][i];
            if(control)ShowWindow(control,t==page?SW_SHOWNOACTIVATE:SW_HIDE);
        }
    if(page==UI_TAB_ESP){ui_sync_esp();ui_sync_wsg();}
    else if(page==UI_TAB_STATUS){ui_sync_rogue();ui_sync_rear();ui_sync_wsg();}
    else if(page==UI_TAB_REAR)ui_sync_rear();
    else if(page==UI_TAB_SUMMON)ui_sync_summon();
    else if(page==UI_TAB_PATROL)ui_sync_patrol();
    else if(page==UI_TAB_FOLLOW)ui_sync_follow();
    else ui_sync_rogue();
    for(t=0u;t<6u;++t)if(g_ui_tabs[t])InvalidateRect(g_ui_tabs[t],NULL,TRUE);
    if(g_ui_sidebar_gather)InvalidateRect(g_ui_sidebar_gather,NULL,TRUE);
    if(g_ui_sidebar_chests)InvalidateRect(g_ui_sidebar_chests,NULL,TRUE);
}
static void ui_add_to_page(DWORD page,HWND control) {
    if(page>UI_TAB_FOLLOW || !control)return;
    if(g_ui_page_count[page]<UI_MAX_PAGE_CONTROLS)
        g_ui_pages[page][g_ui_page_count[page]++]=control;
}
static BOOL ui_is_sidebar_id(DWORD id) {
    return id==201u||id==202u||id==203u||id==228u||id==231u||id==232u||id==240u||id==241u;
}
static BOOL ui_sidebar_id_active(DWORD id) {
    if(id==201u)return g_ui_current_tab==UI_TAB_ESP && !g_ui_gather_open;
    if(id==202u)return g_ui_current_tab==UI_TAB_ROGUE && !g_ui_gather_open;
    if(id==203u)return g_ui_current_tab==UI_TAB_STATUS || g_ui_current_tab==UI_TAB_REAR;
    if(id==228u)return g_ui_current_tab==UI_TAB_SUMMON;
    if(id==231u)return g_ui_current_tab==UI_TAB_PATROL;
    if(id==232u)return g_ui_current_tab==UI_TAB_FOLLOW;
    if(id==240u)return g_ui_current_tab==UI_TAB_ROGUE && g_ui_gather_open && g_ui_gather_page!=1u;
    if(id==241u)return g_ui_current_tab==UI_TAB_ROGUE && g_ui_gather_open && g_ui_gather_page==1u;
    return FALSE;
}
static void ui_paint_background(HDC dc,HWND hwnd) {
    struct RECT32 rc,side,accent;
    if(!dc||!GetClientRect(hwnd,&rc))return;
    if(g_ui_content_brush)FillRect(dc,&rc,g_ui_content_brush);
    side=rc;side.right=UI_SIDEBAR_W;
    if(g_ui_sidebar_brush)FillRect(dc,&side,g_ui_sidebar_brush);
    accent=rc;accent.left=UI_SIDEBAR_W-1;accent.right=UI_SIDEBAR_W+1;
    if(g_ui_accent_brush)FillRect(dc,&accent,g_ui_accent_brush);
}
static void ui_draw_button(struct DRAWITEMSTRUCT32 *d) {
    char text[96];
    struct SIZE32 sz;
    struct RECT32 r;
    HBRUSH brush;
    BOOL nav,active,pressed;
    COLORREF color;
    int x,y,n;
    if(!d||!d->hDC)return;
    nav=ui_is_sidebar_id(d->CtlID);
    active=nav&&ui_sidebar_id_active(d->CtlID);
    pressed=(d->itemState&UI_ODS_SELECTED)!=0u;
    brush=active?g_ui_accent_brush:(pressed?g_ui_press_brush:g_ui_button_brush);
    if(brush)FillRect(d->hDC,&d->rcItem,brush);
    r=d->rcItem;
    if(nav&&active&&g_ui_accent_brush){
        r.right=r.left+4;
        FillRect(d->hDC,&r,g_ui_accent_brush);
    }
    n=GetWindowTextA(d->hwndItem,text,(int)sizeof(text));
    if(n<0)n=0;
    text[n<(int)sizeof(text)?n:(int)sizeof(text)-1]=0;
    SetBkMode(d->hDC,TRANSPARENT_BK);
    color=active?UI_COLOR_TEXT:(nav?UI_COLOR_MUTED:UI_COLOR_TEXT);
    SetTextColor(d->hDC,color);
    sz.cx=0;sz.cy=0;
    GetTextExtentPoint32A(d->hDC,text,n,&sz);
    x=nav?d->rcItem.left+18:d->rcItem.left+(d->rcItem.right-d->rcItem.left-sz.cx)/2;
    y=d->rcItem.top+(d->rcItem.bottom-d->rcItem.top-sz.cy)/2;
    TextOutA(d->hDC,x,y,text,n);
}
static HWND ui_sidebar_label(const char* label,int x,int y,int width,int height,BOOL title) {
    HWND ctl=CreateWindowExA(0u,"STATIC",label,UI_CHILD|UI_VISIBLE,
                            x,y,width,height,g_parallel_ui_hwnd,NULL,g_self,NULL);
    HFONT font=title?g_ui_title_font:g_ui_font;
    if(ctl&&font)SendMessageA(ctl,UI_SETFONT,(DWORD)font,1);
    return ctl;
}
static HWND ui_label(HWND parent,const char* label,
                     int x,int y,int width,int height,BOOL title) {
    HWND ctl=CreateWindowExA(0u,"STATIC",label,UI_CHILD|UI_VISIBLE,
                            x+UI_CONTENT_X,y,width,height,parent,NULL,g_self,NULL);
    HFONT font=title?g_ui_title_font:g_ui_font;
    if(ctl && font)SendMessageA(ctl,UI_SETFONT,(DWORD)font,1);
    return ctl;
}
static HWND ui_button(HWND parent,const char* label,
                      int x,int y,int width,int height,DWORD id,BOOL check) {
    int drawX=ui_is_sidebar_id(id)?x:x+UI_CONTENT_X;
    DWORD style=check?UI_CHECKBOX:UI_OWNERDRAW;
    HWND ctl=CreateWindowExA(0u,"BUTTON",label,
        UI_CHILD|UI_VISIBLE|style,
        drawX,y,width,height,parent,(HANDLE)id,g_self,NULL);
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
    if(msg==UI_PAINT) {
        struct PAINTSTRUCT32 ps;
        HDC dc=BeginPaint(hwnd,&ps);
        if(dc)ui_paint_background(dc,hwnd);
        EndPaint(hwnd,&ps);
        return 0;
    }
    if(msg==UI_ERASEBKGND) {
        ui_paint_background((HDC)(DWORD)wp,hwnd);
        return 1;
    }
    if(msg==UI_CTLCOLORSTATIC) {
        HDC dc=(HDC)(DWORD)wp;
        HWND child=(HWND)(DWORD)lp;
        BOOL side=child==g_ui_brand||child==g_ui_build||child==g_ui_hotkey;
        SetBkMode(dc,TRANSPARENT_BK);
        SetBkColor(dc,side?UI_COLOR_SIDEBAR:UI_COLOR_CONTENT);
        SetTextColor(dc,side?UI_COLOR_MUTED:UI_COLOR_TEXT);
        return (LONG)(DWORD)(side?g_ui_sidebar_brush:g_ui_content_brush);
    }
    if(msg==UI_CTLCOLORBTN) {
        HDC dc=(HDC)(DWORD)wp;
        SetBkMode(dc,TRANSPARENT_BK);
        SetBkColor(dc,UI_COLOR_CONTENT);
        SetTextColor(dc,UI_COLOR_TEXT);
        return (LONG)(DWORD)g_ui_content_brush;
    }
    if(msg==UI_DRAWITEM) {
        ui_draw_button((struct DRAWITEMSTRUCT32*)(DWORD)lp);
        return 1;
    }
    if(msg==UI_CLOSE || (msg==WM_KEYDOWN && wp==VK_INSERT)) {
        if(msg==WM_KEYDOWN)g_gui_insert_latched=1u;
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
        if(id==204u){ui_set_page(UI_TAB_REAR);return 0;}
        if(id==228u){ui_set_page(UI_TAB_SUMMON);return 0;}
        if(id==231u){ui_set_page(UI_TAB_PATROL);return 0;}
        if(id==232u){ui_set_page(UI_TAB_FOLLOW);return 0;}
        if(id==255u){ui_core_set_i32(90u,0);ui_sync_follow();return 0;}
        if(id==256u){ui_core_set_i32(90u,1);ui_sync_follow();return 0;}
        if(id==257u){ui_core_set_i32(90u,2);ui_sync_follow();return 0;}
        if(id==258u){
            if(ui_work_pp_get(PAR_CORE_DLL,109u,91u,&value)){
                int v=value.i32>=4?1:value.i32+1;ui_core_set_i32(91u,v);
            }
            ui_sync_follow();return 0;
        }
        if(id==259u){ui_work_pp_flip(PAR_CORE_DLL,109u,92u);ui_sync_follow();return 0;}
        if(id==260u){ui_work_pp_flip(PAR_CORE_DLL,109u,93u);ui_sync_follow();return 0;}
        if(id==261u){ui_work_pp_flip(PAR_CORE_DLL,109u,94u);ui_sync_follow();return 0;}
        if(id==262u||id==263u){
            if(ui_work_pp_get(PAR_CORE_DLL,109u,95u,&value)){
                int v=value.i32+(id==262u?-50:50);if(v<100)v=100;if(v>1000)v=1000;ui_core_set_i32(95u,v);
            }
            ui_sync_follow();return 0;
        }
        if(id==264u||id==265u){
            if(ui_work_pp_get(PAR_CORE_DLL,109u,96u,&value)){
                int v=value.i32+(id==264u?-100:100);if(v<500)v=500;if(v>5000)v=5000;ui_core_set_i32(96u,v);
            }
            ui_sync_follow();return 0;
        }
        if(id==266u||id==267u){
            if(ui_work_pp_get(PAR_CORE_DLL,109u,97u,&value)){
                int v=value.i32+(id==266u?-50:50);if(v<-500)v=-500;if(v>500)v=500;ui_core_set_i32(97u,v);
            }
            ui_sync_follow();return 0;
        }
        if(id==242u){ui_work_pp_flip(PAR_CORE_DLL,89u,71u);ui_sync_patrol();return 0;}
        if(id==243u){ui_work_pp_flip(PAR_CORE_DLL,89u,72u);ui_sync_patrol();return 0;}
        if(id==244u){ui_core_set_u32(73u,1u);ui_sync_patrol();return 0;}
        if(id==245u){ui_core_set_u32(74u,1u);ui_sync_patrol();return 0;}
        if(id==246u){
            if(ui_work_pp_get(PAR_CORE_DLL,89u,75u,&value)){
                value.u32=value.u32>=3u?1u:value.u32+1u;ui_core_set_u32(75u,value.u32);
            }
            ui_sync_patrol();ui_profile_sync();return 0;
        }
        if(id==247u||id==248u){
            if(ui_work_pp_get(PAR_CORE_DLL,89u,76u,&value)){
                int v=value.i32+(id==247u?-25:25);if(v<0)v=0;if(v>150)v=150;ui_core_set_u32(76u,(DWORD)v);
            }
            ui_sync_patrol();ui_profile_sync();return 0;
        }
        if(id==249u||id==250u){
            if(ui_work_pp_get(PAR_CORE_DLL,89u,77u,&value)){
                int v=value.i32+(id==249u?-50:50);if(v<200)v=200;if(v>1000)v=1000;ui_core_set_u32(77u,(DWORD)v);
            }
            ui_sync_patrol();ui_profile_sync();return 0;
        }
        if(id==251u||id==252u){
            if(ui_work_pp_get(PAR_CORE_DLL,89u,78u,&value)){
                int v=value.i32+(id==251u?-250:250);if(v<1000)v=1000;if(v>8000)v=8000;ui_core_set_u32(78u,(DWORD)v);
            }
            ui_sync_patrol();ui_profile_sync();return 0;
        }
        if(id==253u){ui_work_pp_flip(PAR_CORE_DLL,89u,79u);ui_sync_patrol();ui_profile_sync();return 0;}
        if(id==254u){ui_work_pp_flip(PAR_CORE_DLL,89u,80u);ui_sync_patrol();ui_profile_sync();return 0;}
        if(id==240u){ui_set_page(UI_TAB_ROGUE);ui_show_gather_page(0u);return 0;}
        if(id==241u){ui_set_page(UI_TAB_ROGUE);ui_show_gather_page(1u);return 0;}
        if(id==233u||id==234u){
            ui_summon_apply_profile(id==234u?1u:0u);
            ui_profile_sync();
            ui_sync_summon();return 0;
        }
        if(id==229u){
            ui_work_pp_flip(PAR_SUMMON_DLL,31u,1u);
            ui_profile_sync();
            ui_sync_summon();return 0;
        }
        if(id==230u){
            ui_work_pp_flip(PAR_SUMMON_DLL,31u,21u);
            ui_profile_sync();
            ui_sync_summon();return 0;
        }
        if(id==205u){ui_set_page(UI_TAB_STATUS);return 0;}
        if(id==206u){ui_show_gather();return 0;}
        if(id==207u){ui_set_page(UI_TAB_ROGUE);return 0;}
        if(id==208u){ui_show_gather_page(0u);return 0;}
        if(id==209u){ui_show_gather_page(1u);return 0;}
        if(id==214u){ui_show_gather_page(2u);return 0;}
        if(id==224u){
            ui_work_pp_flip(PAR_CORE_DLL,48u,45u);
            ui_sync_gather();ui_profile_sync();return 0;
        }
        if(id==225u || id==226u){
            const W112_ControlModuleV1 *core=ui_work_pp_module(PAR_CORE_DLL,48u);
            if(core&&core->get_value(46u,&value)){
                if(id==225u && value.i32>4)--value.i32;
                if(id==226u && value.i32<40)++value.i32;
                core->set_value(46u,&value);
            }
            ui_sync_gather();ui_profile_sync();return 0;
        }
        if(id==227u){
            ui_work_pp_flip(PAR_CORE_DLL,50u,49u);
            ui_sync_gather();ui_profile_sync();return 0;
        }
        if(id==223u){
            ui_work_pp_flip(PAR_CORE_DLL,44u,43u);
            ui_sync_gather();ui_profile_sync();return 0;
        }
        if(id>=215u&&id<=222u){
            ui_work_pp_flip(PAR_CORE_DLL,36u,29u+(id-215u));
            ui_sync_gather();ui_profile_sync();return 0;
        }
        if(id>=210u&&id<=213u){
            static const DWORD extra_ids[4]={3u,25u,27u,22u};
            ui_work_pp_flip(PAR_CORE_DLL,36u,extra_ids[id-210u]);
            ui_sync_gather();ui_profile_sync();return 0;
        }
        if(id>=112u&&id<=127u) {
            DWORD setting=id==112u?1u:(id==113u?26u:id-106u);
            ui_work_pp_flip(PAR_CORE_DLL,26u,setting);
            ui_sync_gather();ui_profile_sync();return 0;
        }
        if(id==128u) {
            g_quest_enabled=g_quest_enabled?0u:1u;
            if(!g_quest_enabled)quest_hide_from(0u);
            ui_sync_esp();ui_profile_sync();return 0;
        }
        if(id==101u) {
            g_esp_enabled=g_esp_enabled?0u:1u;
            if(!g_esp_enabled)g_range_sweep_enabled=0u;
            ui_filters_changed();ui_sync_esp();ui_profile_sync();return 0;
        }
        if(id==102u) {
            g_parallel_show_horde=g_parallel_show_horde?0u:1u;
            ui_filters_changed();ui_sync_esp();ui_profile_sync();return 0;
        }
        if(id==103u) {
            g_parallel_show_alliance=g_parallel_show_alliance?0u:1u;
            ui_filters_changed();ui_sync_esp();ui_profile_sync();return 0;
        }
        if(id==104u) {
            g_parallel_show_hostile=g_parallel_show_hostile?0u:1u;
            ui_filters_changed();ui_sync_esp();ui_profile_sync();return 0;
        }
        if(id==105u || id==106u) {
            DWORD key=id==105u?1u:3u;
            if(ui_floor_get(key,&value)) {
                value.u32=value.u32?0u:1u;
                ui_floor_set(key,&value);
            }
            ui_sync_rogue();ui_profile_sync();return 0;
        }
        if(id==111u) {
            ui_work_pp_flip(PAR_WSG_DLL,4u,1u);
            ui_sync_wsg();ui_profile_sync();return 0;
        }
        if(id==129u||id==130u||id==131u){
            ui_work_pp_flip(PAR_CORE_DLL,70u,id==129u?60u:id==130u?66u:70u);
            ui_sync_rogue();ui_profile_sync();return 0;
        }
        if(id==109u || id==110u) {
            if(id==109u)ui_work_pp_flip(PAR_CORE_DLL,25u,2u);
            else ui_work_pp_flip(PAR_RANGE_DLL,7u,1u);
            ui_sync_rogue();ui_profile_sync();return 0;
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
            ui_sync_rogue();ui_profile_sync();return 0;
        }
    }
    return g_ui_prev?CallWindowProcA(g_ui_prev,hwnd,msg,wp,lp):0;
}
static BOOL ui_create(HWND game) {
    struct POINT32 pt;
    struct RECT32 rc;
    DWORD i;
    static const char* filters[5]={
        "Player ESP",
        "Horde players",
        "Alliance players",
        "Hostile BG team",
        "Quest targets"
    };
    if(!game || !IsWindow(game))return FALSE;
    pt.x=pt.y=0;
    if(!GetClientRect(game,&rc) || !ClientToScreen(game,&pt))return FALSE;
    if(!g_ui_sidebar_brush)g_ui_sidebar_brush=CreateSolidBrush(UI_COLOR_SIDEBAR);
    if(!g_ui_content_brush)g_ui_content_brush=CreateSolidBrush(UI_COLOR_CONTENT);
    if(!g_ui_button_brush)g_ui_button_brush=CreateSolidBrush(UI_COLOR_BUTTON);
    if(!g_ui_press_brush)g_ui_press_brush=CreateSolidBrush(UI_COLOR_PRESS);
    if(!g_ui_accent_brush)g_ui_accent_brush=CreateSolidBrush(UI_COLOR_ACCENT);
    g_parallel_ui_hwnd=CreateWindowExA(WS_EX_TOPMOST|WS_EX_TOOLWINDOW,
        "STATIC","PARALLEL CONTROL",WS_POPUP|UI_CAPTION|UI_SYSMENU|UI_SS_WHITERECT,
        (int)(pt.x+(rc.right-UI_WIDTH)/2),(int)(pt.y+(rc.bottom-UI_HEIGHT)/2),
        UI_WIDTH,UI_HEIGHT,NULL,NULL,g_self,NULL);
    if(!g_parallel_ui_hwnd)return FALSE;
    g_ui_prev=(WNDPROC32)(DWORD)SetWindowLongA(
        g_parallel_ui_hwnd,GWL_WNDPROC,(LONG)(DWORD)ui_wndproc);
    if(!g_ui_prev) {
        DestroyWindow(g_parallel_ui_hwnd);
        g_parallel_ui_hwnd=NULL;return FALSE;
    }
    g_ui_font=CreateFontA(-20,0,0,0,500,0,0,0,1,0,0,0,0,"Segoe UI");
    g_ui_title_font=CreateFontA(-28,0,0,0,700,0,0,0,1,0,0,0,0,"Segoe UI");
    g_ui_brand=ui_sidebar_label("PARALLEL",18,18,145,34,TRUE);
    g_ui_build=ui_sidebar_label("CONTROL CENTER",20,53,140,24,FALSE);
    g_ui_hotkey=ui_sidebar_label("5875 x86  |  INSERT",20,610,145,24,FALSE);
    ui_label(g_parallel_ui_hwnd,"PARALLEL CONTROL",26,15,680,38,TRUE);
    ui_label(g_parallel_ui_hwnd,"Live controls / diagnostics  |  branch: parallel",26,53,680,28,FALSE);
    g_ui_tabs[0]=ui_button(g_parallel_ui_hwnd,"ESP",18,112,144,40,201u,FALSE);
    g_ui_tabs[1]=ui_button(g_parallel_ui_hwnd,"ROGUE",18,158,144,40,202u,FALSE);
    g_ui_sidebar_gather=ui_button(g_parallel_ui_hwnd,"GATHER",18,204,144,40,240u,FALSE);
    g_ui_sidebar_chests=ui_button(g_parallel_ui_hwnd,"CHESTS",18,250,144,40,241u,FALSE);
    g_ui_tabs[3]=ui_button(g_parallel_ui_hwnd,"SUMMON",18,296,144,40,228u,FALSE);
    g_ui_tabs[4]=ui_button(g_parallel_ui_hwnd,"PATROL",18,342,144,40,231u,FALSE);
    g_ui_tabs[5]=ui_button(g_parallel_ui_hwnd,"FOLLOW",18,388,144,40,232u,FALSE);
    g_ui_tabs[2]=ui_button(g_parallel_ui_hwnd,"STATUS",18,434,144,40,203u,FALSE);

    ui_add_to_page(UI_TAB_ESP,ui_label(g_parallel_ui_hwnd,
        "ESP / PLAYERS",36,137,670,37,TRUE));
    ui_add_to_page(UI_TAB_ESP,ui_label(g_parallel_ui_hwnd,
        "Live overlay filters. Click a visible player label to target.",
        42,179,665,30,FALSE));
    for(i=0u;i<5u;++i) {
        g_ui_checks[i]=ui_button(g_parallel_ui_hwnd,filters[i],
            46,220+(int)i*51,650,43,i==4u?128u:101u+i,TRUE);
        ui_add_to_page(UI_TAB_ESP,g_ui_checks[i]);
    }
    ui_add_to_page(UI_TAB_ESP,ui_label(g_parallel_ui_hwnd,
        "BATTLEGROUND",40,483,675,30,TRUE));
    g_ui_wsg_check=ui_button(g_parallel_ui_hwnd,
        "WSG Auto Flag  -  dropped flags <= 4.75 yd",46,526,665,43,111u,TRUE);
    ui_add_to_page(UI_TAB_ESP,g_ui_wsg_check);

    ui_add_to_page(UI_TAB_ROGUE,ui_label(g_parallel_ui_hwnd,
        "ROGUE / COMBAT AUTOMATION",36,137,665,39,TRUE));
    ui_add_to_page(UI_TAB_ROGUE,ui_label(g_parallel_ui_hwnd,
        "Stealth floor, Pick Pocket recovery and junkbox controls.",
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
        "",46,395,665,26,FALSE);
    ui_add_to_page(UI_TAB_ROGUE,g_ui_speedfloor_state);
    g_ui_pp_check=ui_button(g_parallel_ui_hwnd,
        "AUTO PICKPOCKET (F11)",46,427,665,36,109u,TRUE);
    ui_add_to_page(UI_TAB_ROGUE,g_ui_pp_check);
    g_ui_pp_recovery_check=ui_button(g_parallel_ui_hwnd,
        "AUTO STEALTH + PP COMBAT RECOVERY (ALT)",46,472,665,36,129u,TRUE);
    ui_add_to_page(UI_TAB_ROGUE,g_ui_pp_recovery_check);
    g_ui_pp_low_hp_check=ui_button(g_parallel_ui_hwnd,
        "HP <30%: SAFE ALT (SEMI-AFK)",46,517,321,36,130u,TRUE);
    ui_add_to_page(UI_TAB_ROGUE,g_ui_pp_low_hp_check);
    g_ui_junkbox_check=ui_button(g_parallel_ui_hwnd,
        "AUTO JUNKBOX",379,517,332,36,110u,TRUE);
    ui_add_to_page(UI_TAB_ROGUE,g_ui_junkbox_check);
    g_ui_pp_control_state=ui_label(g_parallel_ui_hwnd,
        "",46,561,665,26,FALSE);
    ui_add_to_page(UI_TAB_ROGUE,g_ui_pp_control_state);
    ui_add_to_page(UI_TAB_ROGUE,ui_button(g_parallel_ui_hwnd,
        "OPEN GATHER TOOLS",46,591,310,42,206u,FALSE));
    g_ui_map_fall_check=ui_button(g_parallel_ui_hwnd,
        "MAP HIGH Z + S BACKSTEP",368,591,343,42,131u,TRUE);
    ui_add_to_page(UI_TAB_ROGUE,g_ui_map_fall_check);

    /* One compact Gather subview, two internal pages. Parent every HWND to root. */
    ui_add_gather_page_control(ui_button(g_parallel_ui_hwnd,
        "VEINS",46,137,210,34,208u,FALSE),3u);
    ui_add_gather_page_control(ui_button(g_parallel_ui_hwnd,
        "CHESTS",273,137,210,34,209u,FALSE),3u);
    ui_add_gather_page_control(ui_button(g_parallel_ui_hwnd,
        "OPTIONS",501,137,210,34,214u,FALSE),3u);
    g_ui_gather_status=ui_label(g_parallel_ui_hwnd,"",46,178,665,32,FALSE);
    ui_add_gather_page_control(g_ui_gather_status,3u);
    g_ui_gather_checks[0]=ui_button(g_parallel_ui_hwnd,
        "AUTO GATHER (F9)",46,215,665,42,112u,TRUE);
    ui_add_gather_control(g_ui_gather_checks[0]);
    g_ui_gather_checks[1]=ui_button(g_parallel_ui_hwnd,
        "VEIN BLACKLIST ON / OFF (keep selected veins)",46,266,665,42,113u,TRUE);
    ui_add_gather_control(g_ui_gather_checks[1]);
    {
        static const char* ores[14]={
            "Copper","Tin","Silver","Iron","Gold","Mithril","Truesilver",
            "Small Thorium","Rich Thorium","Dark Iron","Bloodstone",
            "Incendicite","Indurium","Hakkari Thorium"
        };
        for(i=0u;i<14u;++i) {
            g_ui_gather_checks[i+2u]=ui_button(g_parallel_ui_hwnd,ores[i],
                i<7u?46:382,324+(int)(i%7u)*37,307,34,114u+i,TRUE);
            ui_add_gather_control(g_ui_gather_checks[i+2u]);
        }
    }
    {
        static const char* options[4]={
            "AUTO OPEN (F12)","MINING BELOW NODE (Z -4)",
            "AUTO BLACKLIST VEINS AFTER COMBAT","MINING EARLY RESTORE (TEST)"
        };
        for(i=0u;i<4u;++i){
            g_ui_gather_extra_checks[i]=ui_button(g_parallel_ui_hwnd,options[i],
                46,216+(int)i*54,665,44,210u+i,TRUE);
            ui_add_gather_page_control(g_ui_gather_extra_checks[i],2u);
        }
    }
    /* The active Parallel GUI (PlayerESP) owns these widgets.
       Plane starts OFF even if the depth setting is saved in the local INI. */
    g_ui_plane_check=ui_button(g_parallel_ui_hwnd,
        "TELEPORT TO PLANE (TEST) - outgoing Z only",46,432,665,42,224u,TRUE);
    ui_add_gather_page_control(g_ui_plane_check,2u);
    g_ui_plane_status=ui_label(g_parallel_ui_hwnd,
        "Plane TEST: module not ready",46,486,665,32,FALSE);
    ui_add_gather_page_control(g_ui_plane_status,2u);
    ui_add_gather_page_control(ui_button(g_parallel_ui_hwnd,
        "DEPTH -",46,528,300,42,225u,FALSE),2u);
    ui_add_gather_page_control(ui_button(g_parallel_ui_hwnd,
        "DEPTH +",383,528,328,42,226u,FALSE),2u);
    /* Chest controls use their own page: no overlapping ore rows or hidden
     * toggles at the bottom of the 750x660 Parallel control window. */
    {
        static const char* chest_names[8]={
            "AUTO CHEST","BATTERED / TATTERED","SOLID",
            "LARGE BATTERED","LARGE SOLID","IRON BOUND",
            "MITHRIL BOUND","AUTO LOOT CHEST"
        };
        g_ui_gather_chest_checks[0]=ui_button(g_parallel_ui_hwnd,
            chest_names[0],46,212,665,39,215u,TRUE);
        ui_add_gather_page_control(g_ui_gather_chest_checks[0],1u);
        g_ui_gather_chest_checks[7]=ui_button(g_parallel_ui_hwnd,
            chest_names[7],46,257,665,39,222u,TRUE);
        ui_add_gather_page_control(g_ui_gather_chest_checks[7],1u);
        g_ui_gather_chest_track=ui_button(g_parallel_ui_hwnd,
            "TRACK CHESTS (MINIMAP)",46,302,665,39,223u,TRUE);
        ui_add_gather_page_control(g_ui_gather_chest_track,1u);
        g_ui_gather_chest_native=ui_button(g_parallel_ui_hwnd,
            "NATIVE TRACK CHESTS (TEST: CLIENT 5875)",46,347,665,36,227u,TRUE);
        ui_add_gather_page_control(g_ui_gather_chest_native,1u);
        for(i=1u;i<=6u;++i) {
            g_ui_gather_chest_checks[i]=ui_button(g_parallel_ui_hwnd,chest_names[i],
                i<=3u?46:382,389+(int)((i-1u)%3u)*45,307,39,215u+i,TRUE);
            ui_add_gather_page_control(g_ui_gather_chest_checks[i],1u);
        }
        g_ui_gather_chest_diag=ui_label(g_parallel_ui_hwnd,
            "Chest scanner: waiting for MovementCore",46,541,665,38,FALSE);
        ui_add_gather_page_control(g_ui_gather_chest_diag,1u);
    }
    ui_add_gather_page_control(ui_button(g_parallel_ui_hwnd,
        "< BACK TO ROGUE",46,596,275,43,207u,FALSE),3u);

    ui_add_to_page(UI_TAB_STATUS,ui_label(g_parallel_ui_hwnd,
        "SYSTEM HEALTH",36,137,665,40,TRUE));
    ui_add_to_page(UI_TAB_STATUS,ui_label(g_parallel_ui_hwnd,
        "Live module presence and runtime diagnostics. Gameplay still requires an in-game test.",
        42,179,665,32,FALSE));
    g_ui_esp_state=ui_label(g_parallel_ui_hwnd,"",46,229,665,31,FALSE);
    ui_add_to_page(UI_TAB_STATUS,g_ui_esp_state);
    g_ui_range_state=ui_label(g_parallel_ui_hwnd,"",46,274,665,31,FALSE);
    ui_add_to_page(UI_TAB_STATUS,g_ui_range_state);
    g_ui_autopp_state=ui_label(g_parallel_ui_hwnd,"",46,319,665,31,FALSE);
    ui_add_to_page(UI_TAB_STATUS,g_ui_autopp_state);
    g_ui_longpp_state=ui_label(g_parallel_ui_hwnd,"",46,364,665,31,FALSE);
    ui_add_to_page(UI_TAB_STATUS,g_ui_longpp_state);
    g_ui_rear_state=ui_label(g_parallel_ui_hwnd,"",46,409,665,37,FALSE);
    ui_add_to_page(UI_TAB_STATUS,g_ui_rear_state);
    ui_add_to_page(UI_TAB_STATUS,ui_button(g_parallel_ui_hwnd,
        "REAR360 DETAILS",500,451,210,36,204u,FALSE));
    g_ui_core_state=ui_label(g_parallel_ui_hwnd,"",46,500,665,31,FALSE);
    ui_add_to_page(UI_TAB_STATUS,g_ui_core_state);
    ui_add_to_page(UI_TAB_STATUS,ui_label(g_parallel_ui_hwnd,
        "AutoLootPP / LongPP are loaded, not hot-unloaded.",
        42,548,665,31,FALSE));
    g_ui_wsg_state=ui_label(g_parallel_ui_hwnd,"",46,592,665,33,FALSE);
    ui_add_to_page(UI_TAB_STATUS,g_ui_wsg_state);

    ui_add_to_page(UI_TAB_SUMMON,ui_label(g_parallel_ui_hwnd,
        "SUMMON / AUTOMATION",36,137,665,40,TRUE));
    ui_add_to_page(UI_TAB_SUMMON,ui_label(g_parallel_ui_hwnd,
        "Profiles persist; background-safe, no mouse/focus. MASTER: both OFF | SLAVE: both ON. TYPE 18 = ritual fallback.",
        42,181,665,32,FALSE));
    g_ui_summon_master_profile=ui_button(g_parallel_ui_hwnd,
        "MASTER / CASTER",46,221,321,36,233u,TRUE);
    ui_add_to_page(UI_TAB_SUMMON,g_ui_summon_master_profile);
    g_ui_summon_slave_profile=ui_button(g_parallel_ui_hwnd,
        "SLAVE / HELPER",389,221,322,36,234u,TRUE);
    ui_add_to_page(UI_TAB_SUMMON,g_ui_summon_slave_profile);
    g_ui_summon_check=ui_button(g_parallel_ui_hwnd,
        "AUTO SUMMON ASSIST - enabled",46,265,665,38,229u,TRUE);
    ui_add_to_page(UI_TAB_SUMMON,g_ui_summon_check);
    g_ui_summon_loaded=ui_label(g_parallel_ui_hwnd,"",46,310,665,28,FALSE);
    ui_add_to_page(UI_TAB_SUMMON,g_ui_summon_loaded);
    g_ui_summon_candidate=ui_label(g_parallel_ui_hwnd,"",46,345,665,34,FALSE);
    ui_add_to_page(UI_TAB_SUMMON,g_ui_summon_candidate);
    g_ui_summon_guid=ui_label(g_parallel_ui_hwnd,"",46,385,665,34,FALSE);
    ui_add_to_page(UI_TAB_SUMMON,g_ui_summon_guid);
    g_ui_summon_scan=ui_label(g_parallel_ui_hwnd,"",46,425,665,34,FALSE);
    ui_add_to_page(UI_TAB_SUMMON,g_ui_summon_scan);
    g_ui_summon_nearest=ui_label(g_parallel_ui_hwnd,"",46,465,665,34,FALSE);
    ui_add_to_page(UI_TAB_SUMMON,g_ui_summon_nearest);
    g_ui_summon_antiafk_check=ui_button(g_parallel_ui_hwnd,
        "ANTI-AFK - SPACE to this WoW every random 100-120s",
        46,507,665,36,230u,TRUE);
    ui_add_to_page(UI_TAB_SUMMON,g_ui_summon_antiafk_check);
    g_ui_summon_antiafk_state=ui_label(g_parallel_ui_hwnd,"",46,550,665,58,FALSE);
    ui_add_to_page(UI_TAB_SUMMON,g_ui_summon_antiafk_state);


    ui_add_to_page(UI_TAB_PATROL,ui_label(g_parallel_ui_hwnd,
        "PATROL / ROUTE RECORDER",36,137,665,40,TRUE));
    ui_add_to_page(UI_TAB_PATROL,ui_label(g_parallel_ui_hwnd,
        "Record one manual loop, save it, then CTM patrol yields automatically to AutoPP and other movement.",
        42,181,665,36,FALSE));
    g_ui_patrol_check=ui_button(g_parallel_ui_hwnd,
        "PATROL ON / OFF",46,226,321,40,242u,TRUE);
    ui_add_to_page(UI_TAB_PATROL,g_ui_patrol_check);
    g_ui_patrol_record_check=ui_button(g_parallel_ui_hwnd,
        "RECORD ROUTE",389,226,322,40,243u,TRUE);
    ui_add_to_page(UI_TAB_PATROL,g_ui_patrol_record_check);
    ui_add_to_page(UI_TAB_PATROL,ui_button(g_parallel_ui_hwnd,
        "FINISH + SAVE",46,278,205,40,244u,FALSE));
    ui_add_to_page(UI_TAB_PATROL,ui_button(g_parallel_ui_hwnd,
        "CLEAR ROUTE",269,278,205,40,245u,FALSE));
    ui_add_to_page(UI_TAB_PATROL,ui_button(g_parallel_ui_hwnd,
        "ROUTE SLOT 1 -> 2 -> 3",492,278,219,40,246u,FALSE));
    g_ui_patrol_state=ui_label(g_parallel_ui_hwnd,"",46,332,665,31,FALSE);
    ui_add_to_page(UI_TAB_PATROL,g_ui_patrol_state);
    g_ui_patrol_route=ui_label(g_parallel_ui_hwnd,"",46,370,665,31,FALSE);
    ui_add_to_page(UI_TAB_PATROL,g_ui_patrol_route);
    g_ui_patrol_config=ui_label(g_parallel_ui_hwnd,"",46,408,665,31,FALSE);
    ui_add_to_page(UI_TAB_PATROL,g_ui_patrol_config);
    ui_add_to_page(UI_TAB_PATROL,ui_button(g_parallel_ui_hwnd,
        "RANDOM -",46,450,150,38,247u,FALSE));
    ui_add_to_page(UI_TAB_PATROL,ui_button(g_parallel_ui_hwnd,
        "RANDOM +",210,450,150,38,248u,FALSE));
    ui_add_to_page(UI_TAB_PATROL,ui_button(g_parallel_ui_hwnd,
        "SPACING -",374,450,150,38,249u,FALSE));
    ui_add_to_page(UI_TAB_PATROL,ui_button(g_parallel_ui_hwnd,
        "SPACING +",538,450,173,38,250u,FALSE));
    ui_add_to_page(UI_TAB_PATROL,ui_button(g_parallel_ui_hwnd,
        "STUCK -",46,500,150,38,251u,FALSE));
    ui_add_to_page(UI_TAB_PATROL,ui_button(g_parallel_ui_hwnd,
        "STUCK +",210,500,150,38,252u,FALSE));
    ui_add_to_page(UI_TAB_PATROL,ui_button(g_parallel_ui_hwnd,
        "PAUSE IN COMBAT",374,500,160,38,253u,TRUE));
    ui_add_to_page(UI_TAB_PATROL,ui_button(g_parallel_ui_hwnd,
        "AUTO RESUME PP",548,500,163,38,254u,TRUE));
    g_ui_patrol_stats=ui_label(g_parallel_ui_hwnd,"",46,553,665,31,FALSE);
    ui_add_to_page(UI_TAB_PATROL,g_ui_patrol_stats);
    ui_add_to_page(UI_TAB_PATROL,ui_label(g_parallel_ui_hwnd,
        "Route files: PatrolRoute_1/2/3.w112 in the game folder. Patrol starts OFF after launch.",
        46,593,665,32,FALSE));


    ui_add_to_page(UI_TAB_FOLLOW,ui_label(g_parallel_ui_hwnd,
        "FOLLOW / MASTER ASSIST",36,137,665,40,TRUE));
    ui_add_to_page(UI_TAB_FOLLOW,ui_label(g_parallel_ui_hwnd,
        "Cross-process link. Follower attacks only a target already tagged by this channel's Master.",
        42,181,665,34,FALSE));
    g_ui_follow_off=ui_button(g_parallel_ui_hwnd,"OFF",46,226,205,38,255u,TRUE);
    ui_add_to_page(UI_TAB_FOLLOW,g_ui_follow_off);
    g_ui_follow_master=ui_button(g_parallel_ui_hwnd,"MASTER",269,226,205,38,256u,TRUE);
    ui_add_to_page(UI_TAB_FOLLOW,g_ui_follow_master);
    g_ui_follow_follower=ui_button(g_parallel_ui_hwnd,"FOLLOWER",492,226,219,38,257u,TRUE);
    ui_add_to_page(UI_TAB_FOLLOW,g_ui_follow_follower);
    ui_add_to_page(UI_TAB_FOLLOW,ui_button(g_parallel_ui_hwnd,
        "CHANNEL 1 -> 2 -> 3 -> 4",46,274,665,36,258u,FALSE));
    g_ui_follow_assist=ui_button(g_parallel_ui_hwnd,"ASSIST TAGGED",46,318,205,36,259u,TRUE);
    ui_add_to_page(UI_TAB_FOLLOW,g_ui_follow_assist);
    g_ui_follow_lazy=ui_button(g_parallel_ui_hwnd,"LAZYSCRIPT",269,318,205,36,260u,TRUE);
    ui_add_to_page(UI_TAB_FOLLOW,g_ui_follow_lazy);
    g_ui_follow_teleport=ui_button(g_parallel_ui_hwnd,"SAFE CATCH-UP",492,318,219,36,261u,TRUE);
    ui_add_to_page(UI_TAB_FOLLOW,g_ui_follow_teleport);
    g_ui_follow_state=ui_label(g_parallel_ui_hwnd,"",46,364,665,28,FALSE);
    ui_add_to_page(UI_TAB_FOLLOW,g_ui_follow_state);
    g_ui_follow_link=ui_label(g_parallel_ui_hwnd,"",46,397,665,28,FALSE);
    ui_add_to_page(UI_TAB_FOLLOW,g_ui_follow_link);
    g_ui_follow_target=ui_label(g_parallel_ui_hwnd,"",46,430,665,28,FALSE);
    ui_add_to_page(UI_TAB_FOLLOW,g_ui_follow_target);
    g_ui_follow_config=ui_label(g_parallel_ui_hwnd,"",46,463,665,28,FALSE);
    ui_add_to_page(UI_TAB_FOLLOW,g_ui_follow_config);
    ui_add_to_page(UI_TAB_FOLLOW,ui_button(g_parallel_ui_hwnd,"DIST -",46,500,150,34,262u,FALSE));
    ui_add_to_page(UI_TAB_FOLLOW,ui_button(g_parallel_ui_hwnd,"DIST +",210,500,150,34,263u,FALSE));
    ui_add_to_page(UI_TAB_FOLLOW,ui_button(g_parallel_ui_hwnd,"CATCHUP -",374,500,150,34,264u,FALSE));
    ui_add_to_page(UI_TAB_FOLLOW,ui_button(g_parallel_ui_hwnd,"CATCHUP +",538,500,173,34,265u,FALSE));
    ui_add_to_page(UI_TAB_FOLLOW,ui_button(g_parallel_ui_hwnd,"SIDE -",46,542,314,34,266u,FALSE));
    ui_add_to_page(UI_TAB_FOLLOW,ui_button(g_parallel_ui_hwnd,"SIDE +",374,542,337,34,267u,FALSE));
    g_ui_follow_stats=ui_label(g_parallel_ui_hwnd,"",46,585,665,32,FALSE);
    ui_add_to_page(UI_TAB_FOLLOW,g_ui_follow_stats);

    /* The detailed counters occupy their own view: no overlapping controls,
       no scroll subclass, no changes to Insert, ESP hook or settings parents. */
    ui_add_to_page(UI_TAB_REAR,ui_label(g_parallel_ui_hwnd,
        "REAR360 / DIAGNOSTICS",36,137,665,40,TRUE));
    ui_add_to_page(UI_TAB_REAR,ui_label(g_parallel_ui_hwnd,
        "Local counters only; server success requires an in-game test.",
        42,188,665,34,FALSE));
    g_ui_rear_details_state=ui_label(g_parallel_ui_hwnd,
        "",46,247,665,207,FALSE);
    ui_add_to_page(UI_TAB_REAR,g_ui_rear_details_state);
    ui_add_to_page(UI_TAB_REAR,ui_button(g_parallel_ui_hwnd,
        "BACK TO STATUS",46,506,278,45,205u,FALSE));

    ui_sync_esp();
    ui_sync_rogue();
    ui_set_page(g_ui_current_tab);
    g_ui_shown=0u;
    return TRUE;
}
static void parallel_gui_tick(void) {
    quest_draw_tick();
    /* GUI must remain reachable when ESP is disabled in the persisted profile,
     * or its click/label subclass has not been installed yet. The verified
     * client window getter is independent of ESP overlay initialization. */
    HWND game=((GetGameWindowFn)FN_GET_GAME_WINDOW)(0),fg;
    /* WndProc is not guaranteed to remain in the live subclass chain when
     * other runtime modules replace it. Render-loop polling restores Insert
     * without adding a hook or allowing one press to toggle twice. */
    {
        BOOL down=(GetAsyncKeyState(VK_INSERT)&0x8000)!=0;
        if(!down)g_gui_insert_latched=0u;
        else if(!g_gui_insert_latched && parallel_this_process_foreground()) {
            g_gui_insert_latched=1u;
            g_parallel_gui_open=g_parallel_gui_open?0u:1u;
        }
    }
    if(!g_ui_profile_initialized)ui_profile_bootstrap();
    if(g_render_frame>=g_ui_profile_next_frame) {
        g_ui_profile_next_frame=g_render_frame+UI_PROFILE_POLL_FRAMES;
        ui_profile_sync();
    }
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
        } else if(g_ui_current_tab==UI_TAB_REAR)ui_sync_rear();
        else if(g_ui_current_tab==UI_TAB_SUMMON)ui_sync_summon();
        else if(g_ui_current_tab==UI_TAB_PATROL)ui_sync_patrol();
        else if(g_ui_current_tab==UI_TAB_FOLLOW)ui_sync_follow();
        else if(g_ui_current_tab==UI_TAB_ESP)ui_sync_wsg();
        if(g_ui_gather_open)ui_sync_gather();
    }
}
static void parallel_gui_destroy(void) {
    DWORD page;
    quest_destroy_windows();
    if(g_parallel_ui_hwnd && IsWindow(g_parallel_ui_hwnd)) {
        if(g_ui_prev)
            SetWindowLongA(g_parallel_ui_hwnd,GWL_WNDPROC,(LONG)(DWORD)g_ui_prev);
        DestroyWindow(g_parallel_ui_hwnd);
    }
    g_parallel_ui_hwnd=NULL;g_ui_prev=NULL;
    for(page=0u;page<7u;++page) {
        if(page<6u)g_ui_tabs[page]=NULL;
        g_ui_page_count[page]=0u;
    }
    for(page=0u;page<5u;++page)g_ui_checks[page]=NULL;
    g_ui_speedfloor_check=NULL;g_ui_hostile_guard_check=NULL;
    g_ui_speedfloor_state=NULL;g_ui_speedfloor_value=NULL;
    g_ui_pp_check=NULL;g_ui_pp_recovery_check=NULL;g_ui_pp_low_hp_check=NULL;g_ui_map_fall_check=NULL;g_ui_junkbox_check=NULL;
    g_ui_pp_control_state=NULL;g_ui_core_state=NULL;
    g_ui_esp_state=NULL;g_ui_autopp_state=NULL;g_ui_longpp_state=NULL;
    g_ui_range_state=NULL;g_ui_rear_state=NULL;g_ui_rear_details_state=NULL;
    g_ui_wsg_check=NULL;g_ui_wsg_state=NULL;
    g_ui_summon_check=NULL;g_ui_summon_antiafk_check=NULL;
    g_ui_summon_master_profile=NULL;g_ui_summon_slave_profile=NULL;
    g_ui_summon_loaded=NULL;g_ui_summon_candidate=NULL;
    g_ui_summon_guid=NULL;g_ui_summon_scan=NULL;g_ui_summon_nearest=NULL;
    g_ui_summon_antiafk_state=NULL;
    g_ui_patrol_check=NULL;g_ui_patrol_record_check=NULL;
    g_ui_patrol_route=NULL;g_ui_patrol_config=NULL;g_ui_patrol_stats=NULL;g_ui_patrol_state=NULL;
    g_ui_follow_off=NULL;g_ui_follow_master=NULL;g_ui_follow_follower=NULL;
    g_ui_follow_assist=NULL;g_ui_follow_lazy=NULL;g_ui_follow_teleport=NULL;
    g_ui_follow_state=NULL;g_ui_follow_link=NULL;g_ui_follow_target=NULL;g_ui_follow_config=NULL;g_ui_follow_stats=NULL;
    for(page=0u;page<40u;++page){g_ui_gather_controls[page]=NULL;g_ui_gather_control_pages[page]=0u;}
    for(page=0u;page<16u;++page)g_ui_gather_checks[page]=NULL;
    for(page=0u;page<4u;++page)g_ui_gather_extra_checks[page]=NULL;
    for(page=0u;page<8u;++page)g_ui_gather_chest_checks[page]=NULL;
    g_ui_gather_chest_diag=NULL;g_ui_gather_chest_track=NULL;g_ui_gather_chest_native=NULL;
    g_ui_plane_check=NULL;g_ui_plane_status=NULL;
    g_ui_gather_status=NULL;g_ui_gather_count=0u;g_ui_gather_open=0u;g_ui_gather_page=0u;
    if(g_ui_font)DeleteObject((HGDIOBJ)g_ui_font);
    if(g_ui_title_font)DeleteObject((HGDIOBJ)g_ui_title_font);
    if(g_ui_sidebar_brush)DeleteObject((HGDIOBJ)g_ui_sidebar_brush);
    if(g_ui_content_brush)DeleteObject((HGDIOBJ)g_ui_content_brush);
    if(g_ui_button_brush)DeleteObject((HGDIOBJ)g_ui_button_brush);
    if(g_ui_press_brush)DeleteObject((HGDIOBJ)g_ui_press_brush);
    if(g_ui_accent_brush)DeleteObject((HGDIOBJ)g_ui_accent_brush);
    g_ui_font=NULL;g_ui_title_font=NULL;
    g_ui_sidebar_brush=NULL;g_ui_content_brush=NULL;
    g_ui_button_brush=NULL;g_ui_press_brush=NULL;g_ui_accent_brush=NULL;
    g_ui_brand=NULL;g_ui_build=NULL;g_ui_hotkey=NULL;
    g_ui_sidebar_gather=NULL;g_ui_sidebar_chests=NULL;
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
