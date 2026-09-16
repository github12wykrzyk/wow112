from pathlib import Path

SRC = Path("src/MovementCore/WoWMovementCore_5875_v20_AUTOPP_REARONLY_HARDLOS3D_RETRY.c")
WF = Path(".github/workflows/build_work_candidate.yml")

s = SRC.read_text(encoding="utf-8")
replacements = [
    (
        "static volatile DWORD g_longPPBase=0u,g_longPPReasonPtr=0u,g_longPPGuidLoPtr=0u,g_longPPGuidHiPtr=0u,g_longPPSpoofXPtr=0u,g_longPPSpoofYPtr=0u,g_longPPSpoofZPtr=0u;",
        "static volatile DWORD g_longPPBase=0u,g_longPPReasonPtr=0u,g_longPPGuidLoPtr=0u,g_longPPGuidHiPtr=0u,g_longPPSpoofXPtr=0u,g_longPPSpoofYPtr=0u,g_longPPSpoofZPtr=0u,g_longPPSpoofOPtr=0u;",
    ),
    (
        "static float g_ppHardX=0.0f,g_ppHardY=0.0f,g_ppHardZ=0.0f;",
        "static float g_ppHardX=0.0f,g_ppHardY=0.0f,g_ppHardZ=0.0f,g_ppHardO=0.0f;",
    ),
    (
        "static void PPHardSelect(DWORD lo,DWORD hi,DWORD*variantOut)\n{",
        "/* Keep LongPP orientation coherent with MovementCore's rear-sector XYZ override.\n"
        " * Verified active LongPP layout stores spoof O at base+0x50FC, immediately after XYZ. */\n"
        "static float PPAtan2YX(float y,float x)\n"
        "{\n"
        "    float r;\n"
        "    __asm {\n"
        "        fld y\n"
        "        fld x\n"
        "        fpatan\n"
        "        fstp dword ptr [r]\n"
        "    }\n"
        "    return r;\n"
        "}\n\n"
        "static void PPHardSelect(DWORD lo,DWORD hi,DWORD*variantOut)\n{",
    ),
    (
        "    g_ppHardZ=z+zbase+dz;\n"
        "    g_ppHardLo=lo;g_ppHardHi=hi;g_ppHardArmed=1u;g_ppFailPendingVariant=idx;++g_ppHardLOSArms;if(variantOut)*variantOut=idx;",
        "    g_ppHardZ=z+zbase+dz;\n"
        "    g_ppHardO=PPAtan2YX(y-g_ppHardY,x-g_ppHardX);if(g_ppHardO<0.0f)g_ppHardO+=6.28318530717958647692f;\n"
        "    g_ppHardLo=lo;g_ppHardHi=hi;g_ppHardArmed=1u;g_ppFailPendingVariant=idx;++g_ppHardLOSArms;if(variantOut)*variantOut=idx;",
    ),
    (
        "    if(!Ptr((void*)g_longPPSpoofXPtr)||!Ptr((void*)g_longPPSpoofYPtr)||!Ptr((void*)g_longPPSpoofZPtr)||!Ptr((void*)g_longPPGuidLoPtr)||!Ptr((void*)g_longPPGuidHiPtr))return;",
        "    if(!Ptr((void*)g_longPPSpoofXPtr)||!Ptr((void*)g_longPPSpoofYPtr)||!Ptr((void*)g_longPPSpoofZPtr)||!Ptr((void*)g_longPPSpoofOPtr)||!Ptr((void*)g_longPPGuidLoPtr)||!Ptr((void*)g_longPPGuidHiPtr))return;",
    ),
    (
        "    *(float*)g_longPPSpoofXPtr=g_ppHardX;*(float*)g_longPPSpoofYPtr=g_ppHardY;*(float*)g_longPPSpoofZPtr=g_ppHardZ;++g_ppHardLOSOverrides;",
        "    *(float*)g_longPPSpoofXPtr=g_ppHardX;*(float*)g_longPPSpoofYPtr=g_ppHardY;*(float*)g_longPPSpoofZPtr=g_ppHardZ;*(float*)g_longPPSpoofOPtr=g_ppHardO;++g_ppHardLOSOverrides;",
    ),
    (
        "        g_longPPSpoofXPtr=g_longPPBase+0x50F0u;g_longPPSpoofYPtr=g_longPPBase+0x50F4u;g_longPPSpoofZPtr=g_longPPBase+0x50F8u;g_longPPReasonPtr=g_longPPBase+0x5104u;",
        "        g_longPPSpoofXPtr=g_longPPBase+0x50F0u;g_longPPSpoofYPtr=g_longPPBase+0x50F4u;g_longPPSpoofZPtr=g_longPPBase+0x50F8u;g_longPPSpoofOPtr=g_longPPBase+0x50FCu;g_longPPReasonPtr=g_longPPBase+0x5104u;",
    ),
    (
        "        g_ppChainOk=0u;g_ppActivePtr=0u;g_ppInjectPtr=0u;g_longPPBase=g_longPPReasonPtr=g_longPPGuidLoPtr=g_longPPGuidHiPtr=g_longPPSpoofXPtr=g_longPPSpoofYPtr=g_longPPSpoofZPtr=0u;",
        "        g_ppChainOk=0u;g_ppActivePtr=0u;g_ppInjectPtr=0u;g_longPPBase=g_longPPReasonPtr=g_longPPGuidLoPtr=g_longPPGuidHiPtr=g_longPPSpoofXPtr=g_longPPSpoofYPtr=g_longPPSpoofZPtr=g_longPPSpoofOPtr=0u;",
    ),
]

for old, new in replacements:
    count = s.count(old)
    if count != 1:
        raise SystemExit(f"MovementCore patch expected exactly one match, got {count}: {old[:120]!r}")
    s = s.replace(old, new, 1)

SRC.write_text(s, encoding="utf-8", newline="\n")

# Restore the normal candidate artifact contents after the temporary source-export helper.
w = WF.read_text(encoding="utf-8")
export_line = "            src/MovementCore/WoWMovementCore_5875_v20_AUTOPP_REARONLY_HARDLOS3D_RETRY.c\n"
if w.count(export_line) != 1:
    raise SystemExit("temporary MovementCore source export line missing or duplicated")
WF.write_text(w.replace(export_line, "", 1), encoding="utf-8", newline="\n")

print("Patched MovementCore PickPocket facing and restored build workflow.")
