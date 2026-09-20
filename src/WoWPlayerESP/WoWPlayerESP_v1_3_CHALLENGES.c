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
#define VK_INSERT 0x2Du
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


/* PARALLEL: one native GUI for ESP and the rebuilt SpeedFloor control ABI.
   The preserved AutoLootPP/LongPP binaries are reported as loaded, not
   deceptively exposed as independently live-configurable modules.
   Never load/unload a hooked legacy DLL from a GUI callback. */
#define UI_CHILD 0x40000000u
#define UI_VISIBLE 0x10000000u
#define UI_CAPTION 0x00C00000u
#define UI_SYSMENU 0x00080000u
#define UI_CHECKBOX 0x00000002u
#define UI_COMMAND 0x0111u
#define UI_CLOSE 0x0010u
#define UI_SETFONT 0x0030u
#define UI_SETCHECK 0x00F1u
#define UI_WIDTH 750
#define UI_HEIGHT 700
typedef void* HFONT;
__declspec(dllimport) HFONT WINAPI CreateFontA(int,int,int,int,int,DWORD,DWORD,DWORD,DWORD,DWORD,DWORD,DWORD,DWORD,LPCSTR);
__declspec(dllimport) LONG WINAPI SendMessageA(HWND,UINT,DWORD,LONG);
__declspec(dllimport) BOOL WINAPI SetForegroundWindow(HWND);
static WNDPROC32 g_ui_prev=NULL;
static HFONT g_ui_font=NULL, g_ui_title_font=NULL;
static HWND g_ui_checks[4]={NULL,NULL,NULL,NULL};
static HWND g_ui_speedfloor_check=NULL;
static HWND g_ui_speedfloor_state=NULL;
static HWND g_ui_autopp_state=NULL;
static HWND g_ui_longpp_state=NULL;
__declspec(dllimport) HMODULE WINAPI GetModuleHandleA(LPCSTR);
__declspec(dllimport) void* WINAPI GetProcAddress(HMODULE,LPCSTR);
__declspec(dllimport) BOOL WINAPI SetWindowTextA(HWND,LPCSTR);

#define PAR_SPEED_DLL "WoWNonPvPSpeedFloor_v0_4_ALWAYS_FLOOR7_1_DIAG.dll"
#define PAR_LOOT_DLL "WoWAutoLootPP_v0_14_PP300YD_HU_ATTACKABLE_LEVELGATE3_NOSKIP_SELECTORCHECK.dll"
#define PAR_LONGPP_DLL "WoWLongPickPocket_v1_0_ALLRANGE_360FACING_HARDLOS025.dll"

/* Only the reconstructed SpeedFloor candidate implements the live control
   ABI; the historical exact bytes are not assumed to export that interface. */
static const W112_ControlModuleV1* ui_speedfloor_module(void) {
    HMODULE dll=GetModuleHandleA(PAR_SPEED_DLL);
    W112_ControlGetModuleV1Fn get;
    const W112_ControlModuleV1 *m;
    if (!dll) return NULL;
    get=(W112_ControlGetModuleV1Fn)GetProcAddress(dll,"W112_Control_GetModuleV1");
    if (!get) return NULL;
    m=get();
    if (!m || m->abi_version!=W112_CONTROL_API_V1 ||
        m->struct_size!=sizeof(W112_ControlModuleV1) ||
        m->setting_count<1u || !m->get_value || !m->set_value) return NULL;
    return m;
}
static BOOL ui_speedfloor_state(DWORD *out) {
    const W112_ControlModuleV1 *m=ui_speedfloor_module();
    W112_ControlValueV1 value;
    if (!m || !out || !m->get_value(1u,&value)) return FALSE;
    *out=value.u32?1u:0u;
    return TRUE;
}
static void ui_sync_rogue(void) {
    DWORD enabled=0u;
    BOOL live=ui_speedfloor_state(&enabled);
    if (g_ui_speedfloor_check)
        SendMessageA(g_ui_speedfloor_check,UI_SETCHECK,live&&enabled?1u:0u,0);
    if (g_ui_speedfloor_state)
        SetWindowTextA(g_ui_speedfloor_state,live?
            "Stealth Floor: LIVE control (floor 7.1; hostile-player guard)" :
            "Stealth Floor: control ABI unavailable; no state changed");
    if (g_ui_autopp_state)
        SetWindowTextA(g_ui_autopp_state,GetModuleHandleA(PAR_LOOT_DLL)?
            "Auto PP + Auto Loot: legacy module LOADED (both always on)" :
            "Auto PP + Auto Loot: legacy module NOT LOADED");
    if (g_ui_longpp_state)
        SetWindowTextA(g_ui_longpp_state,GetModuleHandleA(PAR_LONGPP_DLL)?
            "Long PP: legacy 360 / range module LOADED" :
            "Long PP: legacy 360 / range module NOT LOADED");
}

static DWORD g_ui_shown=0u;
/* A control change must request a fresh, guarded scan instead of waiting
   for the normal cache timer. Scoreboard reads stay on the game WndProc. */
static void ui_filters_changed(void) {
    ++g_parallel_filter_revision;
    g_next_bg_score_post_frame=0u;
}
static void ui_check(DWORD n,DWORD on) {
    if (n<4u && g_ui_checks[n]) SendMessageA(g_ui_checks[n],UI_SETCHECK,on?1u:0u,0);
}
static LONG WINAPI ui_wndproc(HWND hwnd,UINT msg,DWORD wp,LONG lp) {
    DWORD id;
    if (msg==UI_CLOSE || (msg==WM_KEYDOWN && wp==VK_INSERT)) {
        g_parallel_gui_open=0u;
        ShowWindow(hwnd,SW_HIDE);
        if (g_hooked_game_hwnd && IsWindow(g_hooked_game_hwnd))
            SetForegroundWindow(g_hooked_game_hwnd);
        return 0;
    }
    if (msg==UI_COMMAND) {
        id=wp&0xFFFFu;
        if (id==101u) {
            g_esp_enabled=g_esp_enabled?0u:1u;
            if (!g_esp_enabled) g_range_sweep_enabled=0u;
            ui_filters_changed();
            ui_check(0u,g_esp_enabled);return 0;
        }
        if (id==102u) {
            g_parallel_show_horde=g_parallel_show_horde?0u:1u;
            ui_filters_changed();
            ui_check(1u,g_parallel_show_horde);return 0;
        }
        if (id==103u) {
            g_parallel_show_alliance=g_parallel_show_alliance?0u:1u;
            ui_filters_changed();
            ui_check(2u,g_parallel_show_alliance);return 0;
        }
        if (id==104u) {
            g_parallel_show_hostile=g_parallel_show_hostile?0u:1u;
            ui_filters_changed();
            ui_check(3u,g_parallel_show_hostile);return 0;
        }
        if (id==105u) {
            DWORD enabled=0u;
            const W112_ControlModuleV1 *m=ui_speedfloor_module();
            W112_ControlValueV1 value;
            if (m && ui_speedfloor_state(&enabled)) {
                value.u32=enabled?0u:1u;
                m->set_value(1u,&value);
            }
            ui_sync_rogue();return 0;
        }
    }
    return g_ui_prev?CallWindowProcA(g_ui_prev,hwnd,msg,wp,lp):0;
}
static void ui_label(HWND parent,const char* label,int x,int y,int width,int height,BOOL title) {
    HWND ctl=CreateWindowExA(0u,"STATIC",label,UI_CHILD|UI_VISIBLE,
                            x,y,width,height,parent,NULL,g_self,NULL);
    HFONT font=title?g_ui_title_font:g_ui_font;
    if (ctl && font) SendMessageA(ctl,UI_SETFONT,(DWORD)font,1);
}
static BOOL ui_create(HWND game) {
    struct POINT32 pt;
    struct RECT32 rc;
    DWORD i;
    const char* names[4]={
        "ESP - display player labels",
        "HORDE - display Horde characters",
        "ALLIANCE - display Alliance characters",
        "HOSTILE TO ME - display opposing BG team"
    };
    if (!game || !IsWindow(game)) return FALSE;
    pt.x=pt.y=0;
    if (!GetClientRect(game,&rc) || !ClientToScreen(game,&pt)) return FALSE;
    g_parallel_ui_hwnd=CreateWindowExA(WS_EX_TOPMOST|WS_EX_TOOLWINDOW,
        "STATIC","PARALLEL - Player ESP",WS_POPUP|UI_CAPTION|UI_SYSMENU,
        (int)(pt.x+(rc.right-UI_WIDTH)/2),(int)(pt.y+(rc.bottom-UI_HEIGHT)/2),
        UI_WIDTH,UI_HEIGHT,NULL,NULL,g_self,NULL);
    if (!g_parallel_ui_hwnd) return FALSE;
    g_ui_prev=(WNDPROC32)(DWORD)SetWindowLongA(
        g_parallel_ui_hwnd,GWL_WNDPROC,(LONG)(DWORD)ui_wndproc);
    if (!g_ui_prev) {
        DestroyWindow(g_parallel_ui_hwnd);
        g_parallel_ui_hwnd=NULL;return FALSE;
    }
    g_ui_font=CreateFontA(-22,0,0,0,500,0,0,0,1,0,0,0,0,"Segoe UI");
    g_ui_title_font=CreateFontA(-29,0,0,0,700,0,0,0,1,0,0,0,0,"Segoe UI");
    ui_label(g_parallel_ui_hwnd,"PARALLEL / PLAYER ESP",28,22,685,42,TRUE);
    ui_label(g_parallel_ui_hwnd,
        "Each switch refreshes nearby players. Click live ESP labels to target.",
        30,73,690,36,FALSE);
    for (i=0u;i<4u;++i) {
        g_ui_checks[i]=CreateWindowExA(0u,"BUTTON",names[i],
            UI_CHILD|UI_VISIBLE|UI_CHECKBOX,
            42,125+(int)(i*66u),680,48,g_parallel_ui_hwnd,
            (HANDLE)(DWORD)(101u+i),g_self,NULL);
        if (g_ui_checks[i] && g_ui_font)
            SendMessageA(g_ui_checks[i],UI_SETFONT,(DWORD)g_ui_font,1);
    }
    ui_check(0u,g_esp_enabled);
    ui_check(1u,g_parallel_show_horde);
    ui_check(2u,g_parallel_show_alliance);
    ui_check(3u,g_parallel_show_hostile);
    ui_label(g_parallel_ui_hwnd,"PARALLEL / ROGUE",28,393,680,40,TRUE);
    g_ui_speedfloor_check=CreateWindowExA(0u,"BUTTON",
        "STEALTH FLOOR - enable live",UI_CHILD|UI_VISIBLE|UI_CHECKBOX,
        42,443,670,43,g_parallel_ui_hwnd,(HANDLE)(DWORD)105u,g_self,NULL);
    if (g_ui_speedfloor_check && g_ui_font)
        SendMessageA(g_ui_speedfloor_check,UI_SETFONT,(DWORD)g_ui_font,1);
    g_ui_speedfloor_state=CreateWindowExA(0u,"STATIC","",UI_CHILD|UI_VISIBLE,
        42,488,680,29,g_parallel_ui_hwnd,NULL,g_self,NULL);
    g_ui_autopp_state=CreateWindowExA(0u,"STATIC","",UI_CHILD|UI_VISIBLE,
        42,528,680,29,g_parallel_ui_hwnd,NULL,g_self,NULL);
    g_ui_longpp_state=CreateWindowExA(0u,"STATIC","",UI_CHILD|UI_VISIBLE,
        42,568,680,29,g_parallel_ui_hwnd,NULL,g_self,NULL);
    if (g_ui_speedfloor_state && g_ui_font)
        SendMessageA(g_ui_speedfloor_state,UI_SETFONT,(DWORD)g_ui_font,1);
    if (g_ui_autopp_state && g_ui_font)
        SendMessageA(g_ui_autopp_state,UI_SETFONT,(DWORD)g_ui_font,1);
    if (g_ui_longpp_state && g_ui_font)
        SendMessageA(g_ui_longpp_state,UI_SETFONT,(DWORD)g_ui_font,1);
    ui_label(g_parallel_ui_hwnd,
        "ESP: click live labels to target. PP/loot legacy modules have no live toggle.",
        30,619,690,40,FALSE);
    ui_sync_rogue();
    g_ui_shown=0u;return TRUE;
}
static void parallel_gui_tick(void) {
    HWND game=g_hooked_game_hwnd,fg;
    if (!game || !IsWindow(game) || !g_parallel_gui_open) {
        if (g_parallel_ui_hwnd && IsWindow(g_parallel_ui_hwnd))
            ShowWindow(g_parallel_ui_hwnd,SW_HIDE);
        g_ui_shown=0u;return;
    }
    fg=GetForegroundWindow();
    if (fg!=game && fg!=g_parallel_ui_hwnd) {
        if (g_parallel_ui_hwnd && IsWindow(g_parallel_ui_hwnd))
            ShowWindow(g_parallel_ui_hwnd,SW_HIDE);
        g_ui_shown=0u;return;
    }
    if (!g_parallel_ui_hwnd || !IsWindow(g_parallel_ui_hwnd)) {
        g_parallel_ui_hwnd=NULL;
        if (!ui_create(game)) return;
    }
    if (!g_ui_shown || !IsWindowVisible(g_parallel_ui_hwnd)) {
        ui_sync_rogue();
        ShowWindow(g_parallel_ui_hwnd,SW_SHOWNOACTIVATE);
        g_ui_shown=1u;
    }
}
static void parallel_gui_destroy(void) {
    if (g_parallel_ui_hwnd && IsWindow(g_parallel_ui_hwnd)) {
        if (g_ui_prev)
            SetWindowLongA(g_parallel_ui_hwnd,GWL_WNDPROC,(LONG)(DWORD)g_ui_prev);
        DestroyWindow(g_parallel_ui_hwnd);
    }
    g_parallel_ui_hwnd=NULL;g_ui_prev=NULL;
    g_ui_speedfloor_check=NULL;g_ui_speedfloor_state=NULL;
    g_ui_autopp_state=NULL;g_ui_longpp_state=NULL;
    if (g_ui_font) DeleteObject((HGDIOBJ)g_ui_font);
    if (g_ui_title_font) DeleteObject((HGDIOBJ)g_ui_title_font);
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
