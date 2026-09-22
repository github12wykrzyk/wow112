#!/usr/bin/env python3
"""Preflight for Win32 declarations used by the parallel ESP native GUI.

The Windows x86 compiler is still authoritative. This fast check reports a
specific ABI mismatch early, before a candidate can be advertised as ready.
"""
from pathlib import Path
import json
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "src/WoWPlayerESP/WoWPlayerESP_v1_3_CHALLENGES.c"

def main():
    text = SOURCE.read_text(encoding="utf-8")
    prototypes = re.findall(
        r"__declspec\(dllimport\)\s+HFONT\s+WINAPI\s+CreateFontA\s*\(([^()]*)\)\s*;",
        text,
    )
    if len(prototypes) != 1:
        print("ERROR: expected one explicit CreateFontA Win32 import prototype")
        return 1
    types = [x.strip() for x in prototypes[0].split(",")]
    expected = ["int"] * 5 + ["DWORD"] * 8 + ["LPCSTR"]
    if types != expected:
        print("ERROR: CreateFontA Win32 ABI requires 5 int + 8 DWORD + LPCSTR (14 arguments)")
        print("GOT:", types)
        return 1
    calls = re.findall(r"\bCreateFontA\s*\(([^()]*)\)", text)
    if len(calls) < 3:
        print("ERROR: expected CreateFontA declaration and both GUI font allocations")
        return 1
    for call in calls:
        argc = len(call.split(","))
        if argc != 14:
            print("ERROR: CreateFontA declaration/call has", argc, "arguments; expected 14")
            return 1
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
        'if(id==129u){',
        'ui_work_pp_flip(PAR_CORE_DLL,65u,60u);',
        'g_ui_profile_core_ids[]={1u,2u,3u,',
        '49u,60u};',
        '{PAR_CORE_DLL,65u,g_ui_profile_core_ids,33u,FALSE',
        'g_ui_pp_check=NULL;g_ui_pp_recovery_check=NULL;g_ui_junkbox_check=NULL;',
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
        'g_ui_pages[4][UI_MAX_PAGE_CONTROLS]',
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
        'g_ui_speedfloor_check=ui_button(g_parallel_ui_hwnd',
        'g_ui_hostile_guard_check=ui_button(g_parallel_ui_hwnd',
        'g_ui_pp_check=ui_button(g_parallel_ui_hwnd',
        'g_ui_junkbox_check=ui_button(g_parallel_ui_hwnd',
        'ui_add_to_page(UI_TAB_ROGUE,g_ui_pp_check)',
        'ui_add_to_page(UI_TAB_ROGUE,g_ui_junkbox_check)',
        'if(id>=201u && id<=203u)',
        'ui_set_page(id-201u);return 0;',
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
        'g_ui_pp_check=NULL;g_ui_pp_recovery_check=NULL;g_ui_junkbox_check=NULL;',
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
    Path("dist").mkdir(exist_ok=True)
    Path("dist/parallel_gui_regression.json").write_text(
        json.dumps({"result": "PASS", "scope": "source/Win32 ABI and render-loop wiring",
                    "game_runtime_tested": False, "insert": True,
                    "gui_controls": list(range(101, 111)), "tabs": [201, 202, 203],
                    "wndproc_chain": True, "render_tick_and_destroy": True},
                   indent=2) + "\n", encoding="utf-8")
    print("PARALLEL_GUI_REGRESSION: PASS (source guards only; in-game test required)")
    print("PARALLEL_GUI_WIN32_ABI: PASS (CreateFontA prototype and %d calls)" % (len(calls)-1))
    return 0

if __name__ == "__main__":
    sys.exit(main())
