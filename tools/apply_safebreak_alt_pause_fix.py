#!/usr/bin/env python3
from pathlib import Path

PATH = Path("src/MovementCore/WoWMovementCore_5875_v20_AUTOPP_REARONLY_HARDLOS3D_RETRY.c")
text = PATH.read_text(encoding="utf-8")

replacements = [
    (
        "static volatile DWORD g_mode=0,g_started=0,g_lastInject=0,g_injecting=0,g_forwardCurrent=1,g_timerId=0;\n",
        "static volatile DWORD g_mode=0,g_started=0,g_lastInject=0,g_injecting=0,g_forwardCurrent=1,g_timerId=0;\n"
        "static volatile DWORD g_safeBreakPauseTick=0u,g_safeBreakPauseMs=0u,g_safeBreakResumes=0u;\n",
    ),
    (
        "    g_mode=MODE_OFF;g_started=0;g_lastInject=0;g_seenCombat=0;g_clearTick=0;g_worldLost=0;g_worldReadySince=0;\n",
        "    g_mode=MODE_OFF;g_started=0;g_lastInject=0;g_safeBreakPauseTick=0u;g_seenCombat=0;g_clearTick=0;g_worldLost=0;g_worldReadySince=0;\n",
    ),
    (
        "    g_mode=mode;g_started=now;g_lastInject=0;g_seenCombat=Combat(p);g_clearTick=0;g_worldLost=0;g_worldReadySince=now;\n",
        "    g_mode=mode;g_started=now;g_lastInject=0;g_safeBreakPauseTick=0u;g_seenCombat=Combat(p);g_clearTick=0;g_worldLost=0;g_worldReadySince=now;\n",
    ),
    (
        "    DWORD now,dur,gap,k7,k8,k9,kAlt,k10,k11,k12;BYTE*p;\n",
        "    DWORD now,dur,gap,k7,k8,k9,kAlt,k10,k11,k12,paused;BYTE*p;\n",
    ),
    (
        "    if(LongPPActive()||LongPPInjecting()||(*(DWORD*)ADDR_CASTING_SPELLID)==SPELL_PICK_POCKET||((LONG)(g_ppQuietUntil-now)>0)){\n"
        "        ++g_ppSafeBreakYields;\n"
        "        return;\n"
        "    }\n\n"
        "    p=LocalPlayer();\n",
        "    if(LongPPActive()||LongPPInjecting()||(*(DWORD*)ADDR_CASTING_SPELLID)==SPELL_PICK_POCKET||((LONG)(g_ppQuietUntil-now)>0)){\n"
        "        /* Do not burn SafeBreak lifetime while PP owns movement. */\n"
        "        if(!g_safeBreakPauseTick)g_safeBreakPauseTick=now;\n"
        "        ++g_ppSafeBreakYields;\n"
        "        return;\n"
        "    }\n"
        "    if(g_safeBreakPauseTick){\n"
        "        paused=(DWORD)(now-g_safeBreakPauseTick);\n"
        "        g_started+=paused;\n"
        "        g_safeBreakPauseMs+=paused;\n"
        "        g_safeBreakPauseTick=0u;\n"
        "        g_lastInject=0u; /* resume with an immediate spoof pulse */\n"
        "        ++g_safeBreakResumes;\n"
        "    }\n\n"
        "    p=LocalPlayer();\n",
    ),
]

changed = False
for old, new in replacements:
    if old in text:
        text = text.replace(old, new, 1)
        changed = True
    elif new in text:
        continue
    else:
        raise SystemExit("SafeBreak fix anchor not found; refusing to modify source")

if changed:
    PATH.write_text(text, encoding="utf-8", newline="\n")
    print("SafeBreak Alt pause/resume fix applied")
else:
    print("SafeBreak Alt pause/resume fix already present")
