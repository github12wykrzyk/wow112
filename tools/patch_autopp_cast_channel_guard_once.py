from pathlib import Path

AUTO = Path("src/AutoLootPP/WoWAutoLootPP_v0_14_PP300YD_HU_ATTACKABLE_LEVELGATE3_NOSKIP_SELECTORCHECK_RECONSTRUCTED.c")
MOVE = Path("src/MovementCore/WoWMovementCore_5875_v20_AUTOPP_REARONLY_HARDLOS3D_RETRY.c")


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected exactly one match, got {count}: {old[:160]!r}")
    return text.replace(old, new, 1)


a = AUTO.read_text(encoding="utf-8")
a = replace_once(
    a,
    "#define WOW_LOOT_WINDOW_FLAG        0x00B71B44u\n",
    "#define WOW_LOOT_WINDOW_FLAG        0x00B71B44u\n"
    "#define WOW_CASTING_SPELLID         0x00CECA88u /* current local-player cast id; shared with MovementCore */\n",
    "AutoLootPP casting global",
)
a = replace_once(
    a,
    "#define DESC_HEALTH_OFF             0x0058u\n#define DESC_BOUNDING_RADIUS_OFF    0x0208u\n",
    "#define DESC_HEALTH_OFF             0x0058u\n"
    "#define DESC_CHANNEL_SPELL_OFF      0x0240u /* UNIT_CHANNEL_SPELL, descriptor index 144 in vanilla 1.12.1 */\n"
    "#define DESC_BOUNDING_RADIUS_OFF    0x0208u\n",
    "AutoLootPP channel field",
)
a = replace_once(
    a,
    "static void service_pickpocket(uptr player,u32 now)\n{\n    uptr target;float d2=0.0f;\n    if(g_loot_state!=LOOT_IDLE)return; /* final runtime gives corpses priority over PP */\n",
    "static int player_busy_with_foreign_cast_or_channel(uptr player)\n"
    "{\n"
    "    u32 cast_id=read_u32(WOW_CASTING_SPELLID);uptr d;\n"
    "    /* Do not make AutoPP interrupt the player's own cast.  Pick Pocket's\n"
    "       own transient cast id is excluded so an already-started PP retry can finish. */\n"
    "    if(cast_id!=0u && cast_id!=PP_SUBOP)return 1;\n"
    "    d=descriptor(player);\n"
    "    if(d && read_u32(d+DESC_CHANNEL_SPELL_OFF)!=0u)return 1;\n"
    "    return 0;\n"
    "}\n\n"
    "static void service_pickpocket(uptr player,u32 now)\n"
    "{\n"
    "    uptr target;float d2=0.0f;\n"
    "    if(g_loot_state!=LOOT_IDLE)return; /* final runtime gives corpses priority over PP */\n"
    "    if(player_busy_with_foreign_cast_or_channel(player))return;\n",
    "AutoLootPP service gate",
)
AUTO.write_text(a, encoding="utf-8", newline="\n")

m = MOVE.read_text(encoding="utf-8")
m = replace_once(
    m,
    "#define UNIT_FIELD_FLAGS_INDEX     0x002Eu\n#define UNIT_FIELD_AURA_INDEX      0x002Fu\n",
    "#define UNIT_FIELD_FLAGS_INDEX     0x002Eu\n"
    "#define UNIT_FIELD_AURA_INDEX      0x002Fu\n"
    "#define UNIT_CHANNEL_SPELL_INDEX   0x0090u /* vanilla 1.12.1 UNIT_CHANNEL_SPELL = descriptor index 144 */\n",
    "MovementCore channel index",
)
m = replace_once(
    m,
    "static DWORD Combat(BYTE*p){DWORD*d;if(!Ptr(p))return 0;d=*(DWORD**)(p+OFF_OBJ_DESCRIPTOR_PTR);if(!Ptr(d))return 0;return(d[UNIT_FIELD_FLAGS_INDEX]&UNIT_FLAG_IN_COMBAT)?1u:0u;}\nstatic DWORD CurrentTargetIsPlayer(void)\n",
    "static DWORD Combat(BYTE*p){DWORD*d;if(!Ptr(p))return 0;d=*(DWORD**)(p+OFF_OBJ_DESCRIPTOR_PTR);if(!Ptr(d))return 0;return(d[UNIT_FIELD_FLAGS_INDEX]&UNIT_FLAG_IN_COMBAT)?1u:0u;}\n"
    "static DWORD PlayerBusyWithForeignCastOrChannel(void)\n"
    "{\n"
    "    DWORD castId=*(DWORD*)ADDR_CASTING_SPELLID;BYTE*p;DWORD*d;\n"
    "    /* Preserve Pick Pocket's own in-flight/retry state; block only a different\n"
    "       player cast or any active vanilla channel. */\n"
    "    if(castId!=0u&&castId!=SPELL_PICK_POCKET)return 1u;\n"
    "    p=LocalPlayer();if(!Ptr(p))return 0u;d=*(DWORD**)(p+OFF_OBJ_DESCRIPTOR_PTR);if(!Ptr(d))return 0u;\n"
    "    return d[UNIT_CHANNEL_SPELL_INDEX]!=0u?1u:0u;\n"
    "}\n"
    "static DWORD CurrentTargetIsPlayer(void)\n",
    "MovementCore busy helper",
)
m = replace_once(
    m,
    "    PPDecodeTargetGuid(packet,&tlo,&thi);\n    if(isAutoSource&&CurrentTargetIsPlayer()){g_ppForward=0u;++g_autoPPBlocked;++g_autoPPTargetPlayerBlocks;g_ppQuietUntil=0u;return;}\n",
    "    PPDecodeTargetGuid(packet,&tlo,&thi);\n"
    "    /* Defense-in-depth: all automatic PP sources and HARDLOS retries must yield\n"
    "       while the local player is casting another spell or channeling. Manual PP\n"
    "       remains user-controlled. */\n"
    "    if(isAutoSource&&PlayerBusyWithForeignCastOrChannel()){g_ppForward=0u;++g_autoPPBlocked;g_ppQuietUntil=0u;return;}\n"
    "    if(isAutoSource&&CurrentTargetIsPlayer()){g_ppForward=0u;++g_autoPPBlocked;++g_autoPPTargetPlayerBlocks;g_ppQuietUntil=0u;return;}\n",
    "MovementCore PP arbiter gate",
)
MOVE.write_text(m, encoding="utf-8", newline="\n")

print("Patched AutoLootPP + MovementCore: automatic Pick Pocket yields to foreign casts and channels.")
