#!/usr/bin/env python3
"""Preflight for Win32 declarations used by the parallel ESP native GUI.

The Windows x86 compiler is still authoritative. This fast check reports a
specific ABI mismatch early, before a candidate can be advertised as ready.
"""
from pathlib import Path
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
    print("PARALLEL_GUI_WIN32_ABI: PASS (CreateFontA prototype and %d calls)" % (len(calls)-1))
    return 0

if __name__ == "__main__":
    sys.exit(main())
