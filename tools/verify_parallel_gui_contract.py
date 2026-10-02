#!/usr/bin/env python3
"""Source-level behavioral contract for the parallel native GUI.

This deliberately does not call itself an ABI test: it protects routing,
persistence, teardown and diagnostic wiring while leaving runtime acceptance
to the x86 candidate build and in-game test.
"""
from pathlib import Path
import json
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "src/WoWPlayerESP/WoWPlayerESP_v1_3_CHALLENGES.c"

def main():
    text = SOURCE.read_text(encoding="utf-8")
    # Regression: a control notifies its immediate HWND parent. In the
    # conservative 3-tab layout that parent is the root window; in the
    # experimental scrolled layout the viewport must explicitly relay clicks.
    # Verify the *actual* selected creation path and every live setting ID.
    top_proc = text.split("static LONG WINAPI ui_wndproc(", 1)
    if len(top_proc) != 2:
        print("ERROR: Parallel panel WndProc missing")
        return 1
    top_body = top_proc[1].split("static BOOL ui_create(", 1)[0]
    if 'if(msg==UI_COMMAND)' not in top_body:
        print("ERROR: root UI is missing WM_COMMAND dispatch")
        return 1
    for setting_id in range(101, 111):
        if 'id==%du' % setting_id not in top_body:
            print("ERROR: root GUI action missing for control", setting_id)
            return 1
    if 'g_ui_checks[i]=ui_button(g_parallel_ui_hwnd' in text:
        if 'g_ui_pp_check=ui_button(g_parallel_ui_hwnd' not in text or (
            'g_ui_junkbox_check=ui_button(g_parallel_ui_hwnd' not in text
        ):
            print("ERROR: direct-parent GUI has settings with divergent parent")
            return 1
        print("PARALLEL_GUI_CLICK_ROUTING: PASS (direct-parent -> handlers 101..110)")
    elif 'g_ui_checks[i]=ui_button(g_ui_content' in text:
        content_proc = text.split("static LONG WINAPI ui_content_wndproc(", 1)
        if len(content_proc) != 2:
            print("ERROR: scroll viewport has no command relay")
            return 1
        content_body = content_proc[1].split("static void ui_set_page(", 1)[0]
        if 'return SendMessageA(g_parallel_ui_hwnd,UI_COMMAND,wp,lp);' not in content_body:
            print("ERROR: scroll-viewport WM_COMMAND relay missing")
            return 1
        print("PARALLEL_GUI_CLICK_ROUTING: PASS (viewport -> root -> handlers)")
    else:
        print("ERROR: unrecognized control-parent layout; cannot verify click routing")
        return 1
    # Recovery is opt-in and must have a real root-parent button, wired
    # handler, saved profile entry and full teardown; do not merely draw text.
    for token in (
        'g_ui_pp_recovery_check=ui_button(g_parallel_ui_hwnd',
        'ui_add_to_page(UI_TAB_ROGUE,g_ui_pp_recovery_check)',
        'if(id==129u||id==130u||id==131u){',
        'g_ui_pp_low_hp_check=ui_button(g_parallel_ui_hwnd',
        'ui_add_to_page(UI_TAB_ROGUE,g_ui_pp_low_hp_check)',
        'g_ui_map_fall_check=ui_button(g_parallel_ui_hwnd',
        'ui_add_to_page(UI_TAB_ROGUE,g_ui_map_fall_check)',
        'ui_work_pp_get(PAR_CORE_DLL,70u,70u,&mapFall);',
        'ui_work_pp_flip(PAR_CORE_DLL,70u,id==129u?60u:id==130u?66u:70u);',
        'g_ui_profile_core_ids[]={1u,2u,3u,',
        '49u,60u,66u,70u,75u,76u,77u,78u,79u,80u};',
        '{PAR_CORE_DLL,89u,g_ui_profile_core_ids,41u,FALSE',
        'g_ui_pp_check=NULL;g_ui_pp_recovery_check=NULL;g_ui_pp_low_hp_check=NULL;g_ui_map_fall_check=NULL;g_ui_junkbox_check=NULL;',
    ):
        if token not in text:
            print("ERROR: AutoPP recovery GUI/persistence/teardown missing:", token)
            return 1
    print("PARALLEL_GUI_AUTOPP_RECOVERY: PASS (root handler, saved toggle, teardown)")
    # Layout guard: never render rear counters inside the compact STATUS row.
    # The full metrics have their own fourth *internal* page. All interactive
    # buttons must still parent directly to the original top-level HWND.
    if not all(token in text for token in (
        '#define UI_SS_WHITERECT 0x00000006u',
        'WS_POPUP|UI_CAPTION|UI_SYSMENU|UI_SS_WHITERECT',
        '#define UI_TAB_REAR 3u',
        'g_ui_pages[7][UI_MAX_PAGE_CONTROLS]',
        'if(id==204u){ui_set_page(UI_TAB_REAR);return 0;}',
        'if(id==205u){ui_set_page(UI_TAB_STATUS);return 0;}',
        'ui_button(g_parallel_ui_hwnd,',
        'g_ui_rear_details_state=ui_label(g_parallel_ui_hwnd',
        'if(g_ui_current_tab==UI_TAB_REAR)ui_sync_rear();',
    )):
        print("ERROR: compact STATUS / Rear360 separate diagnostics page regression")
        return 1
    rear = text.split("static void ui_sync_rear(void)", 1)
    if len(rear) != 2:
        print("ERROR: missing Rear360 GUI diagnostics sync")
        return 1
    rear_body = rear[1].split("static void ui_set_page(", 1)[0]
    compact = rear_body.split("SetWindowTextA(g_ui_rear_state,buf);", 1)
    if len(compact) != 2 or ('p=app_str(p,"\\r\\n' in compact[0]):
        print("ERROR: multiline counters rendered into compact STATUS row")
        return 1
    rear_row = re.search(
        r'g_ui_rear_state=ui_label\(g_parallel_ui_hwnd,"",46,(\d+),665,(\d+),FALSE\);',
        text,
    )
    core_row = re.search(
        r'g_ui_core_state=ui_label\(g_parallel_ui_hwnd,"",46,(\d+),665,(\d+),FALSE\);',
        text,
    )
    wsg_row = re.search(
        r'g_ui_wsg_state=ui_label\(g_parallel_ui_hwnd,"",46,(\d+),665,(\d+),FALSE\);',
        text,
    )
    if not rear_row or not core_row or not wsg_row:
        print("ERROR: missing/changed STATUS row rectangle")
        return 1
    rear_y, rear_h = map(int, rear_row.groups())
    core_y, core_h = map(int, core_row.groups())
    wsg_y, wsg_h = map(int, wsg_row.groups())
    if rear_y+rear_h > core_y or core_y+core_h > wsg_y or wsg_y+wsg_h > 634:
        print("ERROR: STATUS rows overlap or overflow minimum 660px window")
        return 1
    print("PARALLEL_GUI_STATUS_LAYOUT: PASS (one-line summary, separate details)")
    # Include the actual base render-loop wiring: merely declaring the GUI
    # functions in the wrapper does not prove they are ever invoked.
    base = (SOURCE.parent / "WoWPlayerESP_v1_2_range_sweep.c").read_text(encoding="utf-8")
    required_base = ("static void parallel_gui_tick(void);",
                     "static void parallel_gui_destroy(void);",
                     "    parallel_gui_tick();", "    parallel_gui_destroy();")
    if any(base.count(token) != 1 for token in required_base):
        print("ERROR: ESP base render-loop GUI tick or teardown is missing/duplicated")
        return 1
    if "pump_overlay_messages();\n    parallel_gui_tick();" not in base:
        print("ERROR: GUI tick is no longer integrated with ESP overlay message pump")
        return 1
    # The panel buttons all notify their immediate parent. A tab only changes
    # visibility; it must not steal WM_COMMAND routing from the root panel.
    for token in (
        'g_ui_tabs[0]=ui_button(g_parallel_ui_hwnd',
        'g_ui_tabs[1]=ui_button(g_parallel_ui_hwnd',
        'g_ui_tabs[2]=ui_button(g_parallel_ui_hwnd',
        'g_ui_tabs[3]=ui_button(g_parallel_ui_hwnd',
        'g_ui_speedfloor_check=ui_button(g_parallel_ui_hwnd',
        'g_ui_hostile_guard_check=ui_button(g_parallel_ui_hwnd',
        'g_ui_pp_check=ui_button(g_parallel_ui_hwnd',
        'g_ui_junkbox_check=ui_button(g_parallel_ui_hwnd',
        'ui_add_to_page(UI_TAB_ROGUE,g_ui_pp_check)',
        'ui_add_to_page(UI_TAB_ROGUE,g_ui_junkbox_check)',
        'if(id>=201u && id<=203u)',
        'ui_set_page(id-201u);return 0;',
        'if(id==228u){ui_set_page(UI_TAB_SUMMON);return 0;}',
    ):
        if token not in text:
            print("ERROR: GUI control creation/tab routing regression:", token)
            return 1
    if not all(token in text for token in (
        'g_parallel_gui_open=g_parallel_gui_open?0u:1u;',
        'if(!game || !IsWindow(game) || !g_parallel_gui_open)',
        'if(!g_ui_shown || !IsWindowVisible(g_parallel_ui_hwnd))',
        'ShowWindow(g_parallel_ui_hwnd,SW_SHOWNOACTIVATE);',
        'ShowWindow(g_parallel_ui_hwnd,SW_HIDE);',
        'g_ui_current_tab=page;',
        'if(g_ui_prev)',
        'DestroyWindow(g_parallel_ui_hwnd);',
        'g_ui_pp_check=NULL;g_ui_pp_recovery_check=NULL;g_ui_pp_low_hp_check=NULL;g_ui_map_fall_check=NULL;g_ui_junkbox_check=NULL;',
    )):
        print("ERROR: Insert/open/close/recreate or GUI state retention guard failed")
        return 1
    hook = text.split("static LONG WINAPI chal_game_wndproc(", 1)[1].split(
        "static DWORD WINAPI EspBgWorker(", 1)[0]
    if not all(token in hook for token in (
        'g_challenge_prev_wndproc)',
        'CallWindowProcA(g_challenge_prev_wndproc, hwnd, msg, wParam, lParam)',
        'if (chal_hook_is_current()) return TRUE;',
        'if (!chal_release_for_migration()) return FALSE;',
        'if ((WNDPROC32)(DWORD)oldProc == chal_game_wndproc) return FALSE;',
        'if ((WNDPROC32)(DWORD)current != chal_game_wndproc)',
        'if ((WNDPROC32)(DWORD)current == chal_game_wndproc)',
    )):
        print("ERROR: game WndProc chain/duplicate install/migration guard failed")
        return 1
    for token in (
        '#define UI_TAB_SUMMON 4u',
        '#define PAR_SUMMON_DLL "WoWAutoSummonAssist_5875_v1.dll"',
        'g_ui_tabs[3]=ui_button(g_parallel_ui_hwnd,"SUMMON"',
        'ui_add_to_page(UI_TAB_SUMMON,g_ui_summon_check)',
        'ui_sync_summon();',
        'ui_work_pp_flip(PAR_SUMMON_DLL,33u,1u);',
        'ui_work_pp_flip(PAR_SUMMON_DLL,33u,21u);',
        'if(id==230u){',
        'Nearest GO <=12yd: entry ',
        'TYPE 18 = ritual fallback.',
        'page==UI_TAB_SUMMON?3u:(page==UI_TAB_PATROL?4u:(page==UI_TAB_FOLLOW?5u:page))',
        'background-safe, no mouse/focus',
        'Native POST returns',
        'Gate reason',
        'ANTI-AFK - SPACE to this WoW every random 100-120s',
        'lastAction.u32==1u?"SPACE":"NONE"',
        'p=app_str(p," | posts ");',
        'g_ui_summon_antiafk_state=ui_label',
        'cast/channel defers',
        'g_ui_summon_check=NULL;g_ui_summon_antiafk_check=NULL;',
        'g_ui_summon_loaded=NULL;g_ui_summon_candidate=NULL;',
        'g_ui_summon_antiafk_state=NULL;',
        'g_ui_summon_master_profile=ui_button(g_parallel_ui_hwnd',
        'g_ui_summon_slave_profile=ui_button(g_parallel_ui_hwnd',
        'if(id==233u||id==234u){',
        'ui_summon_toggle_role(id==234u?1u:2u);',
        'if(level.u32!=1u)return FALSE;',
        'value.u32=role.u32==2u?0u:2u;',
        'return m->set_value(32u,&value)?TRUE:FALSE;',
        'SendMessageA(g_ui_summon_master_profile,UI_SETCHECK,role.u32==2u?1u:0u,0);',
        'SendMessageA(g_ui_summon_slave_profile,UI_SETCHECK,role.u32==1u?1u:0u,0);',
        'static const DWORD g_ui_profile_summon_ids[]={1u,21u};',
        '{PAR_SUMMON_DLL,33u,g_ui_profile_summon_ids,2u,FALSE',
        'Lvl 1 = forced SLAVE + Anti-AFK ON.',
        'both unchecked = NONE.',
        'g_ui_summon_master_profile=NULL;g_ui_summon_slave_profile=NULL;',
    ):
        if token not in text:
            print("ERROR: AutoSummon dedicated debug tab regression:", token)
            return 1
    print("PARALLEL_GUI_AUTOSUMMON_DEBUG: PASS (dedicated tab + live provider diagnostics)")
    for token in (
        '#define UI_TAB_PATROL 5u',
        'g_ui_tabs[4]=ui_button(g_parallel_ui_hwnd,"PATROL"',
        'if(id==231u){ui_set_page(UI_TAB_PATROL);return 0;}',
        'ui_add_to_page(UI_TAB_PATROL,g_ui_patrol_check)',
        'ui_add_to_page(UI_TAB_PATROL,g_ui_patrol_record_check)',
        'FINISH + SAVE',
        'CLEAR ROUTE',
        'ui_work_pp_module(PAR_CORE_DLL,89u)',
        'ui_sync_patrol();',
        'else if(g_ui_current_tab==UI_TAB_PATROL)ui_sync_patrol();',
        'g_ui_patrol_check=NULL;g_ui_patrol_record_check=NULL;',
    ):
        if token not in text:
            print("ERROR: Patrol GUI/control contract regression:", token)
            return 1
    print("PARALLEL_GUI_PATROL: PASS (dedicated tab + recorder + live diagnostics)")
    for token in (
        '#define UI_TAB_FOLLOW 6u',
        'g_ui_tabs[5]=ui_button(g_parallel_ui_hwnd,"FOLLOW"',
        'if(id==232u){ui_set_page(UI_TAB_FOLLOW);return 0;}',
        'ui_add_to_page(UI_TAB_FOLLOW,g_ui_follow_master)',
        'ui_add_to_page(UI_TAB_FOLLOW,g_ui_follow_follower)',
        'MASTER TAG ONLY: LOCKED ON',
        'ui_work_pp_module(PAR_CORE_DLL,109u)',
        'ui_work_pp_get(PAR_CORE_DLL,109u,91u,&value)',
        'ui_sync_follow();',
        'else if(g_ui_current_tab==UI_TAB_FOLLOW)ui_sync_follow();',
        'g_ui_follow_off=NULL;g_ui_follow_master=NULL;g_ui_follow_follower=NULL;',
    ):
        if token not in text:
            print("ERROR: Follow/Master GUI/control contract regression:", token)
            return 1
    print("PARALLEL_GUI_FOLLOW_MASTER: PASS (role/channel/tag-only/LazyScript controls)")
    Path("dist").mkdir(exist_ok=True)
    Path("dist/parallel_gui_regression.json").write_text(
        json.dumps({"result": "PASS", "scope": "source/Win32 ABI and render-loop wiring",
                    "game_runtime_tested": False, "insert": True,
                    "gui_controls": list(range(101, 111)), "tabs": [201, 202, 203, 228, 231, 232],
                    "wndproc_chain": True, "render_tick_and_destroy": True},
                   indent=2) + "\n", encoding="utf-8")
    print("PARALLEL_GUI_REGRESSION: PASS (source guards only; in-game test required)")
    return 0
if __name__ == "__main__":
    sys.exit(main())
