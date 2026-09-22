/*
 * WoWMovementCore_5875_v20_AUTOPP_REARONLY_HARDLOS3D_RETRY.c
 * World of Warcraft 1.12.1 build 5875 x86
 *
 * V62 Mining-first + HARD server/client LOS retry + combat Mining build:
 *   - V43 NoFall + SafeBreak preserved
 *   - adds AutoGather for vanilla Mining/Herbalism nodes visible to client
 *   - 300 yd client-side scan cap; server visibility still limits loaded GO set
 *   - detailed file logging: AutoGather_debug.log
 *   - NO automatic looting; waits for manual loot window and resumes after close
 *   - no max-attempt blacklist: matching Mining nodes are retried until depleted/gone
 *   - only real profession casts count as gather (all Vanilla Mining/Herbalism rank IDs)
 *   - Mining has priority over automatic Pick Pocket when a valid Mining node is visible within 300 yd
 *   - Mining HARD LOS retry: after a normal interaction fails, retries BOTH the server-side
 *     near-node approach point and the local interaction ray.  The first retry is the exact
 *     node XYZ (zero-range approach), then +/-X/Y and small +/-Z points; each approach is
 *     repeated through local world translations up to +/-35 yd.
 *   - Mining is allowed to continue/start while UNIT_FLAG_IN_COMBAT is set.  Herb/AutoOpen
 *     keep their previous combat-safe behavior.
 *   - without a valid Mining node, Pick Pocket keeps the existing fast path and priority over Herb/other gather state
 *   - LongPickPocket v0.8 is verified as downstream owner of PP spoofing
 *   - outgoing Pick Pocket (921) is intercepted BEFORE LongPickPocket; only if a FAR
 *     gather spoof was actually active do we release it and send real heartbeats
 *   - LongPickPocket active state is read through the verified downstream-hook layout;
 *     AutoGather never rewrites movement while LongPP owns spoof state
 *   - PP send-hook fast path does no file I/O and does not scan LocalPlayer unless a
 *     real gather spoof must be released; diagnostic logging is deferred to timer
 *   - startup fail-safe blocks AutoGather if the expected LongPP chain/order is missing
 *   - global loot-window pause prevents gathering from fighting PP/corpse loot
 *   - rogue Stealth/Vanish is explicitly cancelled immediately before a gather interaction
 *     (Vanilla 1.12 does not auto-unstealth for otherwise unavailable actions)
 *
 * Previous V43 basis:
 *   - source-level merge of WoWNoFall_5875_v1 and
 *     WoWManualSafeBreak_5875_v13_LALT_INSTANCE_UNREACHABLE
 *   - ONE owner of callsite 0x00600ACA instead of two chained DLLs
 *   - preserves V42 logical order inside the hook:
 *       NoFall packet transform -> SafeBreak suppress decision -> previous hook target
 *   - LongPickPocket / PositionalSpoof remain separate and are chained downstream.
 *
 * No CRT. Uses verified WoW.exe IAT slots for build 5875.
 */
#if !defined(_M_IX86) && !defined(__i386__)
#error This DLL is x86-only.
#endif

typedef unsigned char BYTE;
typedef unsigned short WORD;
typedef unsigned long DWORD;
typedef signed long LONG;
typedef unsigned int UINT;
typedef int BOOL;
typedef void* HANDLE;
typedef void* HINSTANCE;
typedef void* HWND;
typedef void* LPVOID;
typedef DWORD UINT_PTR;

#define TRUE 1
#define FALSE 0
#define DLL_PROCESS_ATTACH 1
#define DLL_PROCESS_DETACH 0
#define PAGE_EXECUTE_READWRITE 0x40u

int _fltused = 0x9875;

/* clang may lower some structure/byte copies to memcpy even with /Zl. */
void* __cdecl memcpy(void*d,const void*s,unsigned int n)
{
    BYTE*dd=(BYTE*)d;const BYTE*ss=(const BYTE*)s;unsigned int i;
    for(i=0u;i<n;i++)dd[i]=ss[i];return d;
}

/* Shared / verified client addresses. */
#define ADDR_MOVE_SEND_CALL        0x00600ACAu
#define ADDR_MOVE_SEND_NEXT        0x00600ACFu
#define ADDR_SEND_MOVE             0x00600A10u
#define ADDR_CLIENT_SEND           0x005AB630u
#define ADDR_PP_FAIL_CALL          0x006E73ACu
#define ADDR_DATASTORE_VTABLE      0x007FF9E4u
#define ADDR_OBJMGR_GLOBAL         0x00B41414u
#define ADDR_SELECTED_GUID_LOW     0x00B4E2D8u
#define ADDR_SELECTED_GUID_HIGH    0x00B4E2DCu
#define ADDR_ONRIGHTCLICK_OBJECT   0x005F8660u
#define ADDR_FRAMESCRIPT_EXECUTE   0x00704CD0u
#define ADDR_CASTING_SPELLID       0x00CECA88u
#define ADDR_IS_LOOTING_STATE      0x00B71B48u

/* Object manager / unit offsets from MSB13. */
#define OFF_OM_FIRST_OBJECT        0x00ACu
#define OFF_OM_LOCAL_GUID_LOW      0x00C0u
#define OFF_OM_LOCAL_GUID_HIGH     0x00C4u
#define OFF_OBJ_DESCRIPTOR_PTR     0x0008u
#define OFF_OBJ_GUID_LOW           0x0030u
#define OFF_OBJ_GUID_HIGH          0x0034u
#define OFF_OBJ_NEXT               0x003Cu
#define OFF_UNIT_X                 0x09B8u
#define OFF_UNIT_Y                 0x09BCu
#define OFF_UNIT_Z                 0x09C0u
#define OFF_UNIT_O                 0x09C4u
#define OFF_PLAYER_MOVEINFO_PTR    0x0118u
#define OFF_MOVEINFO_FLAGS         0x0040u
#define UNIT_FIELD_HEALTH_INDEX    0x0016u
#define UNIT_FIELD_FLAGS_INDEX     0x002Eu
#define UNIT_FIELD_AURA_INDEX      0x002Fu
#define UNIT_FIELD_AURA_SLOTS      48u
#define UNIT_FLAG_IN_COMBAT        0x00080000u

/* Update-field / GameObject data for 1.12.1 build 5875. */
#define OBJECT_FIELD_TYPE_INDEX       0x0002u
#define OBJECT_FIELD_ENTRY_INDEX      0x0003u
#define TYPEMASK_UNIT                 0x00000008u
#define TYPEMASK_PLAYER               0x00000010u
#define TYPEMASK_GAMEOBJECT           0x00000020u
#define PLAYER_SKILL_INFO_BASE_INDEX  0x02CEu
#define PLAYER_SKILL_SLOT_STRIDE       3u
#define PLAYER_SKILL_SLOT_COUNT      128u
#define SKILL_HERBALISM              182u
#define SKILL_MINING                 186u
/* GameObject positions are update fields in vanilla.  OBJECT_END=0x06 and
 * GAMEOBJECT_POS_X/Y/Z are +0x09/+0x0A/+0x0B => indices 0x0F..0x11.
 * Keep the older client-struct offsets only as diagnostics/fallback. */
#define GAMEOBJECT_POS_X_INDEX       0x000Fu
#define GAMEOBJECT_POS_Y_INDEX       0x0010u
#define GAMEOBJECT_POS_Z_INDEX       0x0011u
#define OFF_OBJ_MOVEMENT_DATA        0x0118u
#define OFF_OBJMOVE_POS_X            0x0010u
#define OFF_OBJMOVE_POS_Y            0x0014u
#define OFF_OBJMOVE_POS_Z            0x0018u
#define OFF_GO_LEGACY_X              0x0240u
#define OFF_GO_LEGACY_Y              0x0244u
#define OFF_GO_LEGACY_Z              0x0248u

/* Movement constants. */
#define MSG_MOVE_FALL_LAND         0x000000C9u
#define MSG_MOVE_HEARTBEAT         0x000000EEu
#define MOVEFLAG_FLYING            0x00000800u
#define MOVEFLAG_SWIMMING          0x00200000u
#define MOVEFLAG_ONTRANSPORT       0x02000000u
#define MAX_PACKET_SIZE            0x1000u
#define CLONE_CAPACITY             0x80u

/* Existing Win32 imports in WoW.exe. */
#define WOW_IAT_VIRTUALPROTECT         0x007FF35Cu
#define WOW_IAT_FLUSHICACHE            0x007FF320u
#define WOW_IAT_GETCURRENTPROCESS      0x007FF390u
#define WOW_IAT_GETTICKCOUNT           0x007FF310u
#define WOW_IAT_GETASYNCKEYSTATE       0x007FF644u
#define WOW_IAT_SETTIMER               0x007FF4F4u
#define WOW_IAT_KILLTIMER              0x007FF4F8u
#define WOW_IAT_CLOSEHANDLE            0x007FF15Cu
#define WOW_IAT_SETFILEPOINTER         0x007FF190u
#define WOW_IAT_GETFILESIZE            0x007FF194u
#define WOW_IAT_SETENDOFFILE           0x007FF1A0u
#define WOW_IAT_CREATEFILEA            0x007FF1D4u
#define WOW_IAT_WRITEFILE              0x007FF2ECu

/* SafeBreak keys / modes -- unchanged from v13. */
#define VK_F7       0x76
#define VK_F8       0x77
#define VK_LMENU    0xA4
#define VK_F10      0x79
#define VK_F11      0x7A
#define VK_F9       0x78
#define VK_F12      0x7B
#define MODE_OFF                    0u
#define MODE_LEGACY_FAST            1u
#define MODE_LOCAL_STRONG           2u
#define MODE_PURSUIT                3u
#define MODE_INSTANCE_UNREACHABLE   4u
#define LEGACY_FAST_DISTANCE        200.0f
#define LEGACY_FAST_Z_DOWN          0.0f
#define LEGACY_FAST_MS              2600u
#define LEGACY_FAST_GAP_MS          360u
#define LOCAL_STRONG_DISTANCE       260.0f
#define LOCAL_STRONG_Z_DOWN         25.0f
#define LOCAL_STRONG_MS             3600u
#define LOCAL_STRONG_GAP_MS         150u
#define PURSUIT_DISTANCE            200.0f
#define PURSUIT_Z_DOWN              0.0f
#define PURSUIT_MS                  17000u
#define PURSUIT_GAP_MS              360u
#define INSTANCE_Z_UP               30.0f
#define INSTANCE_MS                 4500u
#define INSTANCE_GAP_MS             75u
#define TIMER_MS                    15u
#define CLEAR_SETTLE_MS             300u

/* AutoGather experimental defaults. */
#define GATHER_SCAN_RANGE             300.0f
#define GATHER_SCAN_RANGE_SQ        90000.0f
#define GATHER_NODE_OFFSET             1.5f
#define GATHER_NEAR_RANGE_SQ          16.0f  /* <=4 yd native; 4+ yd uses spoof (server interaction baseline is ~5 yd) */
#define AUTOOPEN_MELEE_RANGE_SQ         16.0f  /* AutoOpen ONLY: real 3D distance <=4 yd; never spoof. */
#define GATHER_FAR_CLICK_DELAY_MS      160u
#define GATHER_TIMER_SCAN_MS          250u
#define GATHER_STATUS_LOG_MS         2000u
#define GATHER_HB_GAP_MS              150u
#define GATHER_HERB_HOLD_MS          6200u  /* fallback only if cast-state is not observed */
#define GATHER_MINING_HOLD_MS       18000u  /* HARD LOS sweep, combat-safe Mining */
#define MINING_EARLY_CANCEL_WINDOW_MS 1200u /* Cast ending this soon after restore is treated as interruption. */
#define MINING_3D_RETRY_FIRST_MS       300u
#define MINING_3D_RETRY_GAP_MS         180u
#define MINING_3D_RETRY_SETTLE_MS       90u
#define MINING_3D_RETRY_COUNT           56u
#define MINING_3D_XY_SHIFT              6.0f
#define MINING_SERVER_XY_STEP            1.25f
#define MINING_SERVER_Z_STEP             0.75f
/* Vertical mining TEST: retain near-node server position below the ore throughout
 * cast and loot; 4.0 yd vertical offset with zero XY is below a ~5 yd interaction
 * radius, without asserting the private server accepts the below-ground ray. */
#define MINING_BELOW_NODE_Z_OFFSET       4.0f
/* Chest uses Mining's near-node spoof / local hard-LOS sweep.
 * Deepest attempted server position starts 4 yd below (not 30 yd beyond
 * interaction range); raise in 0.5 yd increments before the 3D sweep. */
#define CHEST_DEPTH_YD                    4.0f
#define CHEST_STEP_YD                     0.5f
#define CHEST_MAX_STEPS                     8u
/* Chest LOS fallback stays near the GO: group zero has no translated world. */
#define CHEST_3D_RETRY_COUNT                8u
#define CHEST_RETRY_MS                    300u
#define CHEST_LOS_BLACKLIST_MS          30000u
#define CHEST_LOS_BLACKLIST_CAP            16u
#define GATHER_RESCAN_DELAY_MS         60u
#define COMBAT_VEIN_WINDOW_MS         1800u
#define COMBAT_VEIN_MAX                128u
#define GATHER_LOOT_OPEN_GRACE_MS      1200u
#define GATHER_LOOT_MIN_OPEN_MS         120u
#define PP_POST_CAST_QUIET_MS          1200u
#define PP_FAIL_PENDING_MS               900u
#define PP_BLACK_DEATH_SCAN_MS           200u
#define PP_BLACK_CAP                    1024u
#define PP_SWEEP_CAP                     512u
#define PP_HARDLOS_VARIANTS               56u
#define PP_HARDLOS_RETRY_DELAY_MS          75u
#define PP_HARDLOS_PACKET_CAP             128u
#define PP_FAIL_SENTINEL                 0xFFu
#define SPELL_FAILED_LINE_OF_SIGHT       0x2Au
#define SPELL_FAILED_TARGET_NO_POCKETS   0x72u
#define MINING_PRIORITY_SCAN_MS           90u
#define MINING_PRIORITY_HOLD_MS          360u
#define SPELL_MINING                    2575u
#define SPELL_HERBALISM                 2366u
#define SPELL_PICK_POCKET                921u
#define SPELL_PICK_LOCK                  1804u
#define SPELL_STEALTH_R1                 1784u
#define SPELL_STEALTH_R2                 1785u
#define SPELL_STEALTH_R3                 1786u
#define SPELL_STEALTH_R4                 1787u
#define SPELL_VANISH_STEALTH_R1         11327u
#define SPELL_VANISH_STEALTH_R2         11329u
#define GATHER_STEALTH_BREAK_DELAY_MS      180u
#define AUTOOPEN_PICKLOCK_SETTLE_MS         300u
#define AUTOOPEN_CLICK_RETRY_MS             550u
#define AUTOOPEN_CLICK_MAX_ATTEMPTS           3u
#define AUTOOPEN_HOLD_MS                    5600u
#define AUTOOPEN_CHAT_REPEAT_MS             10000u
#define GATHER_LOG_MAX_BYTES       4194304u

#define GENERIC_WRITE            0x40000000u
#define FILE_SHARE_READ          0x00000001u
#define FILE_SHARE_WRITE         0x00000002u
#define OPEN_ALWAYS                       4u
#define FILE_ATTRIBUTE_NORMAL    0x00000080u
#define FILE_BEGIN                         0u
#define FILE_END                           2u
#define INVALID_HANDLE_VALUE    ((HANDLE)(LONG)-1)

/* A short re-acquire delay is used only after an ACTIVE SafeBreak mode loses
 * and then regains LocalPlayer during a world transition. Normal movement and
 * NoFall are not delayed by this guard. */
#define WORLD_REACQUIRE_MS          750u

typedef BOOL (__stdcall *VirtualProtect_t)(LPVOID,DWORD,DWORD,DWORD*);
typedef BOOL (__stdcall *FlushInstructionCache_t)(HANDLE,const void*,DWORD);
typedef HANDLE (__stdcall *GetCurrentProcess_t)(void);
typedef DWORD (__stdcall *GetTickCount_t)(void);
typedef short (__stdcall *GetAsyncKeyState_t)(int);
typedef void (__stdcall *TimerProc_t)(HWND,UINT,UINT_PTR,DWORD);
typedef UINT_PTR (__stdcall *SetTimer_t)(HWND,UINT_PTR,UINT,TimerProc_t);
typedef BOOL (__stdcall *KillTimer_t)(HWND,UINT_PTR);
typedef HANDLE (__stdcall *CreateFileA_t)(const char*,DWORD,DWORD,LPVOID,DWORD,DWORD,HANDLE);
typedef BOOL (__stdcall *WriteFile_t)(HANDLE,const void*,DWORD,DWORD*,LPVOID);
typedef DWORD (__stdcall *SetFilePointer_t)(HANDLE,LONG,LONG*,DWORD);
typedef DWORD (__stdcall *GetFileSize_t)(HANDLE,DWORD*);
typedef BOOL (__stdcall *SetEndOfFile_t)(HANDLE);
typedef BOOL (__stdcall *CloseHandle_t)(HANDLE);
typedef void (__thiscall *SendMove_t)(void*,DWORD);
typedef void (__thiscall *ClientSend_t)(void*);
typedef void (__thiscall *RightClickObject_t)(void*,int);

typedef struct DataStore5875 {
    DWORD vtable;
    BYTE* dataPtr;
    DWORD backOffset;
    DWORD capacity;
    DWORD size;
    DWORD unk14;
} DataStore5875;

/* Unified hook state. */
static volatile DWORD g_installed = 0;
static volatile DWORD g_nextMoveTarget = 0;
static volatile DWORD g_nextSendTarget = 0;
static volatile DWORD g_status = 0;
static volatile DWORD g_ppChainOk=0u,g_ppActivePtr=0u,g_ppInjectPtr=0u;
static volatile DWORD g_ppQuietUntil=0u,g_ppTxPreempts=0u,g_ppStateYields=0u,g_ppMoveBypasses=0u;
static volatile DWORD g_ppSendRecursion=0u,g_foreignLootPauses=0u,g_foreignLootLogged=0u;
static volatile DWORD g_ppPendingEvent=0u,g_ppPendingTick=0u,g_ppPendingEntry=0u,g_ppPendingLo=0u,g_ppPendingHi=0u,g_ppPendingAttempts=0u;
static volatile DWORD g_ppFastNoTouch=0u,g_ppRealResets=0u,g_ppInjectYields=0u,g_ppResetInProgress=0u;
static volatile DWORD g_ppNoFallYields=0u,g_ppSafeBreakYields=0u,g_gatherNoFallYields=0u;
static volatile DWORD g_ppForward=1u,g_miningPriorityBlocks=0u,g_miningPriorityScans=0u;
static volatile DWORD g_miningPriorityValidUntil=0u,g_miningPriorityNextScan=0u,g_miningPriorityEntry=0u,g_miningPriorityLo=0u,g_miningPriorityHi=0u;
static float g_miningPriorityD2=0.0f;
static float g_ppPendingD2=0.0f;

/* SafeBreak v13 state. */
static volatile DWORD g_mode=0,g_started=0,g_lastInject=0,g_injecting=0,g_forwardCurrent=1,g_timerId=0;
static volatile DWORD g_safeBreakPauseTick=0u,g_safeBreakPauseMs=0u,g_safeBreakResumes=0u;
static volatile DWORD g_seenCombat=0,g_clearTick=0,g_key7=0,g_key8=0,g_keyAlt=0,g_key10=0,g_key11=0;
static volatile DWORD g_autoPPEnabled=1u,g_autoPPBlocked=0u,g_autoPPManualPass=0u,g_autoPPTargetPlayerBlocks=0u;
/* V68 AutoPP per-life blacklist + rear-only PP HARDLOS3D state. */
typedef struct PPBlackSlot { DWORD lo,hi; BYTE state; BYTE pad0,pad1,pad2; } PPBlackSlot;
typedef struct PPSweepSlot { DWORD lo,hi,index; BYTE state; BYTE pad0,pad1,pad2; } PPSweepSlot;
static PPBlackSlot g_ppBlack[PP_BLACK_CAP];
static PPSweepSlot g_ppSweep[PP_SWEEP_CAP];
static volatile DWORD g_ppBlackCount=0u,g_ppBlackAdds=0u,g_ppBlackBlocks=0u,g_ppBlackDeathClears=0u,g_ppBlackNextDeathScan=0u;
static volatile DWORD g_ppFailPendingAuto=0u,g_ppFailPendingLo=0u,g_ppFailPendingHi=0u,g_ppFailPendingUntil=0u,g_ppFailPendingVariant=0u,g_ppFailPendingSawActive=0u,g_ppPendingSerialBlocks=0u;
static volatile DWORD g_ppHardLOSArms=0u,g_ppHardLOSLOSFailures=0u,g_ppHardLOSOverrides=0u;
static BYTE g_ppHardRetryPacket[PP_HARDLOS_PACKET_CAP];
static volatile DWORD g_ppHardRetryActive=0u,g_ppHardRetryScheduled=0u,g_ppHardRetryInjecting=0u,g_ppHardRetryDue=0u,g_ppHardRetrySize=0u,g_ppHardRetryAttempts=0u,g_ppHardRetrySent=0u,g_ppHardRetryExhausted=0u;
static volatile DWORD g_ppHardRetryLo=0u,g_ppHardRetryHi=0u;
static volatile DWORD g_longPPBase=0u,g_longPPReasonPtr=0u,g_longPPGuidLoPtr=0u,g_longPPGuidHiPtr=0u,g_longPPSpoofXPtr=0u,g_longPPSpoofYPtr=0u,g_longPPSpoofZPtr=0u,g_longPPSpoofOPtr=0u;
static volatile DWORD g_nextPPFailTarget=0u,g_ppFailHookOk=0u,g_ppFailLogEvent=0u,g_ppFailLogLo=0u,g_ppFailLogHi=0u,g_ppFailLogVariant=0u;
static volatile DWORD g_ppHardArmed=0u,g_ppHardLo=0u,g_ppHardHi=0u;
static float g_ppHardX=0.0f,g_ppHardY=0.0f,g_ppHardZ=0.0f,g_ppHardO=0.0f;
#if defined(W112_PP_ALWAYS_BEHIND)
#define PP_REAR_FOLLOW_REFRESH_MS 50u
static float g_ppRearBack=2.75f,g_ppRearSide=0.0f,g_ppRearDz=0.0f;
static float g_ppRearTargetX=0.0f,g_ppRearTargetY=0.0f,g_ppRearTargetZ=0.0f,g_ppRearTargetO=0.0f;
static volatile DWORD g_ppRearLastRefresh=0u,g_ppRearLiveRefresh=0u;
#endif
static volatile DWORD g_suppressed=0,g_hb=0,g_moveInfoFailures=0;
static volatile DWORD g_worldLost=0,g_worldReadySince=0,g_worldGuardHits=0;
static float g_x=0,g_y=0,g_z=0,g_o=0;

/* NoFall state. */
static volatile DWORD g_preLandGuard = 0;
static volatile DWORD g_noFallPackets = 0;
static volatile DWORD g_preLandHeartbeats = 0;

/* AutoGather state. */
static volatile DWORD g_gatherEnabled=1u,g_gatherActive=0u,g_gatherKey9=0u,g_gatherReadyChat=0u;
static volatile DWORD g_autoOpenEnabled=1u,g_autoOpenKey12=0u,g_autoOpenPickPrimed=0u;
/* Gather/Herb/AutoOpen/AutoChest share the same scanner, spoof and loot owner. */
static volatile DWORD g_chestEnabled=0u,g_chestGroupsMask=63u,g_chestAutoLoot=1u;
/* Passive minimap chest tracking is independent of AutoChest's movement/loot owner. */
static volatile DWORD g_trackChestsEnabled=0u,g_trackChestNext=0u,g_trackChestShown=0u,g_trackChestCount=0u;
/* Native 5875 resource-tracking probe. The descriptor layout agrees with the
 * already-used PLAYER_SKILL_INFO_BASE_INDEX=0x2CE: 128 * 3 skill dwords,
 * two character points, creature tracking, then resource tracking = 0x451.
 * Spell 2481 has Track Resources misc=6 => bit (6-1) = 0x20.
 * See vmangos UpdateFields_1_12_1.h / SpellAuras.cpp and
 * https://github.com/WowDevs/Fishbot-1.12.1 for independent 5875 layout.
 * Client-side field override is experimental and is NOT a server aura. */
#define TRACK_NATIVE_RESOURCES_INDEX 0x0451u
#define TRACK_NATIVE_TREASURE_BIT 0x00000020u
static volatile DWORD g_trackChestNativeMode=0u,g_trackNativeMask=0u,g_trackNativeOwn=0u;
static DWORD *g_trackNativeDesc=0;
static volatile DWORD g_chestStep=0u,g_chestRetryAt=0u;
/* No cast/loot after chest click is suspected obstruction, not verified LOS. */
static volatile DWORD g_chestLoSCheck=1u,g_chestLoSRecovery=1u,g_chestLowestZ=1u;
static volatile DWORD g_chestLoSBlacklist=1u,g_chestMaxAttempts=4u;
static volatile DWORD g_chestAttemptCount=0u,g_chestSuspectedLoS=0u,g_chestLastReason=0u;
static volatile DWORD g_chestBlacklistCount=0u,g_chestBlacklistNext=0u;
typedef struct W112ChestSkip { DWORD lo,hi,until; } W112ChestSkip;
static W112ChestSkip g_chestLoSSkip[CHEST_LOS_BLACKLIST_CAP];
/* Successfully looted GO is excluded until despawn, never by a timed cooldown. */
static volatile DWORD g_chestSkipLo=0u,g_chestSkipHi=0u;
/* A chest which actually triggered combat is not revisited until it despawns
 * or AutoChest is re-enabled. This is a safety blacklist, NOT a time cooldown. */
static volatile DWORD g_chestAggroLo=0u,g_chestAggroHi=0u;
static volatile DWORD g_lastChestChatLo=0u,g_lastChestChatHi=0u,g_lastChestChatTick=0u;
/* The GUI exposes loaded/eligible counts and current target as live diagnostics. */
static volatile DWORD g_chestScanSeen=0u,g_chestScanEligible=0u,g_chestScanLastEntry=0u;
/* Scan reason: 0 none, 1 ready, 2 off, 3 type off, 4 combat,
 * 5 already looted, 6 no position, 7 out of range, 8 transaction active,
 * 9 aggro blacklist, 10 temporary no-response blacklist. */
static volatile DWORD g_chestScanReason=0u,g_chestScanPosSrc=0u;
static volatile DWORD g_autoOpenClickCount=0u,g_autoOpenLastClickAt=0u;
static volatile DWORD g_lastMiningChatLo=0u,g_lastMiningChatHi=0u,g_lastMiningChatTick=0u;
static volatile DWORD g_lastOpenChatLo=0u,g_lastOpenChatHi=0u,g_lastOpenChatTick=0u;
static volatile DWORD g_hasMining=0u,g_hasHerbalism=0u,g_lastProfBits=0xFFFFFFFFu;
static volatile DWORD g_gatherTargetLo=0u,g_gatherTargetHi=0u,g_gatherEntry=0u,g_gatherKind=0u;
static volatile DWORD g_gatherAttempts=0u,g_gatherStart=0u,g_gatherLastHB=0u,g_gatherNextScan=0u,g_gatherLastStatusLog=0u;
static volatile DWORD g_gatherScanVisible=0u,g_gatherScanNodes=0u,g_gatherScanProfMatch=0u,g_gatherScanInRange=0u,g_gatherScanPosFail=0u,g_gatherScanEligible=0u,g_gatherClicks=0u,g_gatherAborts=0u;
static volatile DWORD g_gatherSpoof=0u,g_gatherClickPending=0u,g_gatherClickAt=0u,g_gatherPosSource=0u;
static volatile DWORD g_gatherLootWait=0u,g_gatherLootWaitUntil=0u,g_gatherLootTargetGoneLogged=0u;
static volatile DWORD g_gatherLootStart=0u,g_gatherLootSeenOpen=0u,g_gatherLootOpenLogged=0u;
static volatile DWORD g_gatherSawCast=0u,g_gatherCastSeenLogged=0u;
/* Opt-in Mining-only experiment: restore real server XYZ during the mining cast.
 * Re-arm near-node XYZ before the original manual loot window gate. */
static volatile DWORD g_miningEarlyRestoreEnabled=0u,g_miningEarlyRestored=0u,g_miningEarlyRestoreUsed=0u;
static volatile DWORD g_miningEarlyRestoreAt=0u,g_miningEarlyRestoreCount=0u,g_miningEarlyCancelCount=0u;
static volatile DWORD g_miningBelowNodeEnabled=0u;
static volatile DWORD g_gatherStealthBreaks=0u,g_gatherStealthWaits=0u,g_gatherStealthPending=0u;
static volatile DWORD g_mining3DRetryIndex=0u,g_mining3DRetryAt=0u,g_mining3DRetryActive=0u,g_mining3DRetries=0u,g_mining3DSweepsExhausted=0u;
static float g_mining3DDx=0.0f,g_mining3DDy=0.0f,g_mining3DDz=0.0f;
static float g_miningServerDx=0.0f,g_miningServerDy=0.0f,g_miningServerDz=0.0f;
static float g_gatherNodeX=0.0f,g_gatherNodeY=0.0f,g_gatherNodeZ=0.0f;
static volatile DWORD g_ppPriorityAborts=0u,g_foreignCastAborts=0u,g_gatherPacketRewrites=0u;
static float g_gatherX=0,g_gatherY=0,g_gatherZ=0,g_gatherDistSq=0;
/* Nearest Copper Vein diagnostics from the latest scan. */
static volatile DWORD g_diagEntry=0u,g_diagObj=0u,g_diagPosSource=0u;
static float g_diagX=0,g_diagY=0,g_diagZ=0,g_diagD2=0;
static float g_diagDescX=0,g_diagDescY=0,g_diagDescZ=0;
static float g_diagMoveX=0,g_diagMoveY=0,g_diagMoveZ=0;
static float g_diagLegacyX=0,g_diagLegacyY=0,g_diagLegacyZ=0;
static const char g_gatherLogName[]="AutoGather_debug.log";
static DWORD ChestLoSSkipped(DWORD lo,DWORD hi,DWORD now)
{
    DWORD i;
    for(i=0u;i<CHEST_LOS_BLACKLIST_CAP;i++){
        W112ChestSkip*e=&g_chestLoSSkip[i];
        if(!(e->lo|e->hi))continue;
        if((LONG)(now-e->until)>=0){
            e->lo=e->hi=e->until=0u;
            if(g_chestBlacklistCount)--g_chestBlacklistCount;
            continue;
        }
        if(e->lo==lo&&e->hi==hi)return 1u;
    }
    return 0u;
}
static void ChestLoSDefer(DWORD lo,DWORD hi,DWORD now)
{
    DWORD i;W112ChestSkip*e;
    if(!(lo|hi)||!g_chestLoSBlacklist)return;
    if(ChestLoSSkipped(lo,hi,now))return;
    for(i=0u;i<CHEST_LOS_BLACKLIST_CAP;i++)
        if(!(g_chestLoSSkip[i].lo|g_chestLoSSkip[i].hi))break;
    if(i==CHEST_LOS_BLACKLIST_CAP)
        i=g_chestBlacklistNext%CHEST_LOS_BLACKLIST_CAP;
    else ++g_chestBlacklistCount;
    e=&g_chestLoSSkip[i];e->lo=lo;e->hi=hi;
    e->until=now+CHEST_LOS_BLACKLIST_MS;
    g_chestBlacklistNext=(i+1u)%CHEST_LOS_BLACKLIST_CAP;
}
static void ChestLoSClear(void)
{
    DWORD i;
    for(i=0u;i<CHEST_LOS_BLACKLIST_CAP;i++)
        g_chestLoSSkip[i].lo=g_chestLoSSkip[i].hi=g_chestLoSSkip[i].until=0u;
    g_chestBlacklistCount=g_chestBlacklistNext=0u;
}
static DWORD GatherHasStealth(BYTE*p);

static VirtualProtect_t VP(void){return *(VirtualProtect_t*)WOW_IAT_VIRTUALPROTECT;}
static FlushInstructionCache_t FIC(void){return *(FlushInstructionCache_t*)WOW_IAT_FLUSHICACHE;}
static GetCurrentProcess_t GCP(void){return *(GetCurrentProcess_t*)WOW_IAT_GETCURRENTPROCESS;}
static GetTickCount_t GT(void){return *(GetTickCount_t*)WOW_IAT_GETTICKCOUNT;}
static GetAsyncKeyState_t GK(void){return *(GetAsyncKeyState_t*)WOW_IAT_GETASYNCKEYSTATE;}
static SetTimer_t ST(void){return *(SetTimer_t*)WOW_IAT_SETTIMER;}
static KillTimer_t KT(void){return *(KillTimer_t*)WOW_IAT_KILLTIMER;}
static CreateFileA_t CF(void){return *(CreateFileA_t*)WOW_IAT_CREATEFILEA;}
static WriteFile_t WF(void){return *(WriteFile_t*)WOW_IAT_WRITEFILE;}
static SetFilePointer_t SFP(void){return *(SetFilePointer_t*)WOW_IAT_SETFILEPOINTER;}
static GetFileSize_t GFS(void){return *(GetFileSize_t*)WOW_IAT_GETFILESIZE;}
static SetEndOfFile_t SEOF(void){return *(SetEndOfFile_t*)WOW_IAT_SETENDOFFILE;}
static CloseHandle_t CH(void){return *(CloseHandle_t*)WOW_IAT_CLOSEHANDLE;}

static BOOL Ptr(const void* p){DWORD v=(DWORD)p; return v>=0x10000u && v<=0x7FFDFFFFu && !(v&1u);}
static BOOL WMem(BYTE* d,const BYTE* s,DWORD n){DWORD o=0,t=0,i; if(!VP()||!FIC()||!GCP()||!VP()(d,n,PAGE_EXECUTE_READWRITE,&o))return FALSE; for(i=0;i<n;i++)d[i]=s[i]; FIC()(GCP(),d,n); VP()(d,n,o,&t); return TRUE;}
static DWORD DCall(DWORD site){LONG r;if(*(BYTE*)site!=0xE8)return 0;r=*(LONG*)(site+1);return site+5u+r;}
static BOOL PCall(DWORD site,DWORD target){BYTE p[5];LONG r=(LONG)(target-(site+5u));p[0]=0xE8;p[1]=(BYTE)r;p[2]=(BYTE)(r>>8);p[3]=(BYTE)(r>>16);p[4]=(BYTE)(r>>24);return WMem((BYTE*)site,p,5);}
static DWORD DJump(DWORD site){LONG r;if(*(BYTE*)site!=0xE9)return 0;r=*(LONG*)(site+1);return site+5u+r;}
static BOOL PJump(DWORD site,DWORD target){BYTE p[5];LONG r=(LONG)(target-(site+5u));p[0]=0xE9;p[1]=(BYTE)r;p[2]=(BYTE)(r>>8);p[3]=(BYTE)(r>>16);p[4]=(BYTE)(r>>24);return WMem((BYTE*)site,p,5);}

/* LongPickPocket v0.8-facing integration.  With the supported load order the
 * movement callsite points at LongPP RVA 0x1970 and ClientServices::Send
 * entry points at LongPP RVA 0x1A70.  The state DWORD at RVA 0x502C is the
 * exact flag used by LongPP movement hook before rewriting packet XYZ. */
static DWORD DecodeLongPPMoveHook(DWORD t,DWORD*activePtr,DWORD*injectPtr)
{
    BYTE*b=(BYTE*)t;DWORD a=0u,i=0u;
    if(activePtr)*activePtr=0u;if(injectPtr)*injectPtr=0u;
    if(!Ptr(b)||!Ptr(b+0x20))return 0u;
    /* v0.8 hook prologue plus the two absolute state tests:
       +0x0A: 83 3D <injectPtr> 00 75
       +0x18: 83 3D <activePtr> 00 74 */
    if(!(b[0]==0x57&&b[1]==0x56&&b[2]==0x89&&b[3]==0xCE&&b[4]==0x8B&&b[5]==0x3D&&
         b[10]==0x83&&b[11]==0x3D&&b[16]==0x00&&b[17]==0x75&&
         b[24]==0x83&&b[25]==0x3D&&b[30]==0x00&&b[31]==0x74))return 0u;
    i=*(DWORD*)(b+12);a=*(DWORD*)(b+26);
    if(!Ptr((void*)i)||!Ptr((void*)a))return 0u;
    if(activePtr)*activePtr=a;if(injectPtr)*injectPtr=i;return 1u;
}
static DWORD IsLongPPSendHook(DWORD t)
{
    BYTE*b=(BYTE*)t;if(!Ptr(b)||!Ptr(b+0x20))return 0u;
    return b[0]==0x9C&&b[1]==0x60&&b[2]==0x51&&b[3]==0xE8&&b[8]==0x83&&b[9]==0xC4&&
           b[10]==0x04&&b[11]==0xA3&&b[16]==0x61&&b[17]==0x9D ? 1u:0u;
}
static DWORD LongPPActive(void)
{
    if(!g_ppChainOk||!Ptr((void*)g_ppActivePtr))return 0u;
    return (*(DWORD*)g_ppActivePtr)!=0u ? 1u:0u;
}
static DWORD LongPPInjecting(void)
{
    if(!g_ppChainOk||!Ptr((void*)g_ppInjectPtr))return 0u;
    return (*(DWORD*)g_ppInjectPtr)!=0u ? 1u:0u;
}

/* ----------------------------- NoFall ----------------------------- */
static BYTE* PacketRawBase(DataStore5875* p)
{
    if(!p || !p->dataPtr) return (BYTE*)0;
    if(p->backOffset > 0x01000000u) return (BYTE*)0;
    return p->dataPtr - p->backOffset;
}

static DWORD ComputeFallTimeOffset(const BYTE* raw,DWORD packetSize)
{
    DWORD flags,off=0x1Cu;
    if(!raw || packetSize<0x20u) return 0u;
    flags=*(const DWORD*)(raw+0x04u);
    if(flags&MOVEFLAG_ONTRANSPORT) off+=0x18u;
    if(flags&MOVEFLAG_SWIMMING) off+=0x04u;
    if(off>packetSize || packetSize-off<4u) return 0u;
    return off;
}

static void DirectClientSend(DataStore5875* packet)
{
    ((ClientSend_t)ADDR_CLIENT_SEND)((void*)packet);
}

static void SendPreLandHeartbeat(const BYTE* raw,DWORD packetSize)
{
    BYTE cloneBuf[CLONE_CAPACITY];
    DataStore5875 clone;
    DWORD i,fallOff;
    if(!raw || packetSize<0x20u || packetSize>CLONE_CAPACITY) return;
    for(i=0;i<packetSize;i++) cloneBuf[i]=raw[i];
    *(DWORD*)(cloneBuf+0x00u)=MSG_MOVE_HEARTBEAT;
    fallOff=ComputeFallTimeOffset(cloneBuf,packetSize);
    if(!fallOff) return;
    *(DWORD*)(cloneBuf+fallOff)=0u;
    clone.vtable=ADDR_DATASTORE_VTABLE;
    clone.dataPtr=cloneBuf;
    clone.backOffset=0u;
    clone.capacity=CLONE_CAPACITY;
    clone.size=packetSize;
    clone.unk14=0u;
    g_preLandGuard=1u;
    DirectClientSend(&clone);
    g_preLandGuard=0u;
    ++g_preLandHeartbeats;
}

static void __cdecl NoFall_ProcessMovementPacket(DataStore5875* packet)
{
    BYTE* raw; DWORD size,opcode,fallOff;
    if(!packet) return;
    size=packet->size;
    if(size<0x20u || size>MAX_PACKET_SIZE) return;
    raw=PacketRawBase(packet);
    if(!raw) return;
    fallOff=ComputeFallTimeOffset(raw,size);
    if(!fallOff) return;
    *(DWORD*)(raw+fallOff)=0u;
    ++g_noFallPackets;
    opcode=*(DWORD*)(raw+0x00u);
    if(opcode==MSG_MOVE_FALL_LAND && !g_preLandGuard){
        DWORD now=GT()?GT()():0u;
        /* SendPreLandHeartbeat uses ClientSend directly and therefore bypasses the
         * movement callsite where LongPP normally rewrites XYZ.  Never inject that
         * extra packet while PP owns, or has just claimed, the movement timeline. */
        if(g_gatherSpoof&&(g_gatherActive||g_gatherLootWait)){
            /* The direct clone bypasses the movement callsite, so it would leak
               real XYZ while AutoGather is intentionally holding server position. */
            ++g_gatherNoFallYields;
        }else if(LongPPActive()||LongPPInjecting()||(*(DWORD*)ADDR_CASTING_SPELLID)==SPELL_PICK_POCKET||((LONG)(g_ppQuietUntil-now)>0)){
            ++g_ppNoFallYields;
        }else SendPreLandHeartbeat(raw,size);
    }
}

/* --------------------------- SafeBreak ---------------------------- */
static BYTE* LocalPlayer(void)
{
    BYTE*m=*(BYTE**)ADDR_OBJMGR_GLOBAL,*o;DWORD lo,hi,i;
    if(!Ptr(m))return 0;
    lo=*(DWORD*)(m+OFF_OM_LOCAL_GUID_LOW);hi=*(DWORD*)(m+OFF_OM_LOCAL_GUID_HIGH);
    if((lo|hi)==0)return 0;
    o=*(BYTE**)(m+OFF_OM_FIRST_OBJECT);
    for(i=0;i<4095&&Ptr(o);i++){BYTE*n;if(*(DWORD*)(o+OFF_OBJ_GUID_LOW)==lo&&*(DWORD*)(o+OFF_OBJ_GUID_HIGH)==hi)return o;n=*(BYTE**)(o+OFF_OBJ_NEXT);if(n==o)break;o=n;}
    return 0;
}

static BYTE* ObjByGuid(DWORD lo,DWORD hi)
{
    BYTE*m=*(BYTE**)ADDR_OBJMGR_GLOBAL,*o;DWORD i;
    if(!Ptr(m)||(lo|hi)==0)return 0;
    o=*(BYTE**)(m+OFF_OM_FIRST_OBJECT);
    for(i=0;i<4095&&Ptr(o);i++){BYTE*n;if(*(DWORD*)(o+OFF_OBJ_GUID_LOW)==lo&&*(DWORD*)(o+OFF_OBJ_GUID_HIGH)==hi)return o;n=*(BYTE**)(o+OFF_OBJ_NEXT);if(n==o)break;o=n;}
    return 0;
}

static DWORD Combat(BYTE*p){DWORD*d;if(!Ptr(p))return 0;d=*(DWORD**)(p+OFF_OBJ_DESCRIPTOR_PTR);if(!Ptr(d))return 0;return(d[UNIT_FIELD_FLAGS_INDEX]&UNIT_FLAG_IN_COMBAT)?1u:0u;}
static DWORD CurrentTargetIsPlayer(void)
{
    DWORD lo=*(DWORD*)ADDR_SELECTED_GUID_LOW,hi=*(DWORD*)ADDR_SELECTED_GUID_HIGH;BYTE*t;DWORD*d;
    if((lo|hi)==0u)return 0u;
    t=ObjByGuid(lo,hi);if(!Ptr(t))return 0u;
    d=*(DWORD**)(t+OFF_OBJ_DESCRIPTOR_PTR);if(!Ptr(d))return 0u;
    return (d[OBJECT_FIELD_TYPE_INDEX]&TYPEMASK_PLAYER)?1u:0u;
}

static void GatherFileLog(const char*ev,DWORD now,DWORD entry,DWORD lo,DWORD hi,float distSq,DWORD attempts,DWORD aux);

/* ---------------- V68 AutoPP blacklist + rear-only HARDLOS3D ---------------- */
static DWORD PPHash(DWORD lo,DWORD hi,DWORD mask){DWORD h=lo*2654435761u;h^=hi*2246822519u;h^=h>>16;return h&mask;}
static DWORD PPBlackFind(DWORD lo,DWORD hi)
{
    DWORD i,h;if((lo|hi)==0u)return 0u;h=PPHash(lo,hi,PP_BLACK_CAP-1u);
    for(i=0u;i<PP_BLACK_CAP;i++){PPBlackSlot*b=&g_ppBlack[(h+i)&(PP_BLACK_CAP-1u)];if(b->state==0u)return 0u;if(b->state==1u&&b->lo==lo&&b->hi==hi)return 1u;}return 0u;
}
static DWORD PPBlackAdd(DWORD lo,DWORD hi)
{
    DWORD i,h,firstT=0xFFFFFFFFu;if((lo|hi)==0u)return 0u;h=PPHash(lo,hi,PP_BLACK_CAP-1u);
    for(i=0u;i<PP_BLACK_CAP;i++){DWORD k=(h+i)&(PP_BLACK_CAP-1u);PPBlackSlot*b=&g_ppBlack[k];if(b->state==1u&&b->lo==lo&&b->hi==hi)return 0u;if(b->state==2u&&firstT==0xFFFFFFFFu)firstT=k;if(b->state==0u){if(firstT!=0xFFFFFFFFu)b=&g_ppBlack[firstT];b->lo=lo;b->hi=hi;b->state=1u;++g_ppBlackCount;++g_ppBlackAdds;return 1u;}}
    if(firstT!=0xFFFFFFFFu){PPBlackSlot*b=&g_ppBlack[firstT];b->lo=lo;b->hi=hi;b->state=1u;++g_ppBlackCount;++g_ppBlackAdds;return 1u;}return 0u;
}
static DWORD PPBlackRemove(DWORD lo,DWORD hi)
{
    DWORD i,h;if((lo|hi)==0u)return 0u;h=PPHash(lo,hi,PP_BLACK_CAP-1u);
    for(i=0u;i<PP_BLACK_CAP;i++){PPBlackSlot*b=&g_ppBlack[(h+i)&(PP_BLACK_CAP-1u)];if(b->state==0u)return 0u;if(b->state==1u&&b->lo==lo&&b->hi==hi){b->state=2u;b->lo=b->hi=0u;if(g_ppBlackCount)--g_ppBlackCount;return 1u;}}return 0u;
}
static PPSweepSlot* PPSweepGet(DWORD lo,DWORD hi)
{
    DWORD i,h,firstT=0xFFFFFFFFu;if((lo|hi)==0u)return (PPSweepSlot*)0;h=PPHash(lo,hi,PP_SWEEP_CAP-1u);
    for(i=0u;i<PP_SWEEP_CAP;i++){DWORD k=(h+i)&(PP_SWEEP_CAP-1u);PPSweepSlot*b=&g_ppSweep[k];if(b->state==1u&&b->lo==lo&&b->hi==hi)return b;if(b->state==2u&&firstT==0xFFFFFFFFu)firstT=k;if(b->state==0u){if(firstT!=0xFFFFFFFFu)b=&g_ppSweep[firstT];b->lo=lo;b->hi=hi;b->index=0u;b->state=1u;return b;}}return (PPSweepSlot*)0;
}
static void PPSweepRemove(DWORD lo,DWORD hi)
{
    DWORD i,h;if((lo|hi)==0u)return;h=PPHash(lo,hi,PP_SWEEP_CAP-1u);
    for(i=0u;i<PP_SWEEP_CAP;i++){PPSweepSlot*b=&g_ppSweep[(h+i)&(PP_SWEEP_CAP-1u)];if(b->state==0u)return;if(b->state==1u&&b->lo==lo&&b->hi==hi){b->state=2u;b->lo=b->hi=b->index=0u;return;}}
}
static DWORD PPDecodeTargetGuid(DataStore5875*packet,DWORD*olo,DWORD*ohi)
{
    BYTE*raw;DWORD avail,pos=1u,i,lo=0u,hi=0u;BYTE mask,b;
    if(olo)*olo=0u;if(ohi)*ohi=0u;if(!packet||packet->size<11u)return 0u;raw=PacketRawBase(packet);if(!raw)return 0u;
    /* 5875 CMSG_CAST_SPELL: opcode[0..3], spell[4..7], targetMask[8..9], packed GUID[10..]. */
    avail=packet->size-10u;mask=raw[10];
    for(i=0u;i<8u;i++)if(mask&(1u<<i)){if(pos>=avail)return 0u;b=raw[10u+pos++];if(i<4u)lo|=((DWORD)b)<<(i*8u);else hi|=((DWORD)b)<<((i-4u)*8u);}
    if((lo|hi)==0u){lo=*(DWORD*)ADDR_SELECTED_GUID_LOW;hi=*(DWORD*)ADDR_SELECTED_GUID_HIGH;}
    if(olo)*olo=lo;if(ohi)*ohi=hi;return (lo|hi)?1u:0u;
}
/* No CRT: x87 FSINCOS keeps the rear-sector calculation self-contained on x86. */
static void SinCosF(float a,float*s,float*c)
{
    __asm {
        fld a
        fsincos
        mov eax,c
        fstp dword ptr [eax]
        mov eax,s
        fstp dword ptr [eax]
    }
}

/* Keep LongPP orientation coherent with MovementCore's rear-sector XYZ override.
 * Verified active LongPP layout stores spoof O at base+0x50FC, immediately after XYZ. */
static float PPAtan2YX(float y,float x)
{
    float r;
    __asm {
        fld y
        fld x
        fpatan
        fstp dword ptr [r]
    }
    return r;
}

#if defined(W112_PP_FIXED_POINT)
static void PPFixed_Queue(DWORD event,DWORD reason,DWORD lo,DWORD hi,DWORD variant,float rawX,float rawY,float rawZ);
static volatile DWORD g_ppFixedFirstSeen=0u;
static float g_ppFixedTargetX=0.0f,g_ppFixedTargetY=0.0f,g_ppFixedTargetZ=0.0f;
#endif
static void PPHardSelect(DWORD lo,DWORD hi,DWORD*variantOut)
{
    PPSweepSlot*ss;BYTE*t;DWORD idx,group,variant;
    float x,y,z,o,sn=0.0f,cs=1.0f,zbase=0.0f,dz=0.0f,back=2.75f,side=0.0f;
    float fx,fy,rx,ry;
    g_ppHardArmed=0u;if(variantOut)*variantOut=0u;ss=PPSweepGet(lo,hi);if(!ss)return;idx=ss->index%PP_HARDLOS_VARIANTS;ss->index=(idx+1u)%PP_HARDLOS_VARIANTS;group=idx/8u;variant=idx%8u;
    t=ObjByGuid(lo,hi);if(!Ptr(t))return;
    x=*(float*)(t+OFF_UNIT_X);y=*(float*)(t+OFF_UNIT_Y);z=*(float*)(t+OFF_UNIT_Z);o=*(float*)(t+OFF_UNIT_O);
    SinCosF(o,&sn,&cs);fx=cs;fy=sn;rx=-fy;ry=fx;

    /*
     * V68: every PP HARDLOS candidate is in the target's REAR hemisphere.
     * Never fall back to exact target XYZ or world-axis +/-X/Y points, because
     * those can put the spoofed rogue in front of the mob.  Eight horizontal
     * candidates stay within ~3.1 yd and sweep a narrow rear sector; seven Z
     * groups preserve the old 56-point HARDLOS retry budget.
     */
    if(group==1u)zbase=0.75f;else if(group==2u)zbase=-0.75f;else if(group==3u)zbase=1.50f;else if(group==4u)zbase=-1.50f;else if(group==5u)zbase=3.00f;else if(group==6u)zbase=-3.00f;

    if(variant==1u){back=2.55f;side=0.55f;}
    else if(variant==2u){back=2.55f;side=-0.55f;}
    else if(variant==3u){back=2.85f;side=0.95f;}
    else if(variant==4u){back=2.85f;side=-0.95f;}
    else if(variant==5u){back=2.20f;side=0.35f;dz=0.50f;}
    else if(variant==6u){back=2.20f;side=-0.35f;dz=-0.50f;}
    else if(variant==7u){back=3.05f;side=0.0f;}

    g_ppHardX=x-(fx*back)+(rx*side);
    g_ppHardY=y-(fy*back)+(ry*side);
    g_ppHardZ=z+zbase+dz;
    g_ppHardO=PPAtan2YX(y-g_ppHardY,x-g_ppHardX);if(g_ppHardO<0.0f)g_ppHardO+=6.28318530717958647692f;
#if defined(W112_PP_ALWAYS_BEHIND)
    /* Remember the selected LOS rear-sector variant; follow this target's
       current facing/XYZ without changing retry offsets or its GUID owner. */
    g_ppRearBack=back;g_ppRearSide=side;g_ppRearDz=zbase+dz;
    g_ppRearTargetX=x;g_ppRearTargetY=y;g_ppRearTargetZ=z;g_ppRearTargetO=o;
    g_ppRearLastRefresh=0u;
#endif
    g_ppHardLo=lo;g_ppHardHi=hi;g_ppHardArmed=1u;g_ppFailPendingVariant=idx;++g_ppHardLOSArms;if(variantOut)*variantOut=idx;
#if defined(W112_PP_FIXED_POINT)
    g_ppFixedFirstSeen=0u;g_ppFixedTargetX=x;g_ppFixedTargetY=y;g_ppFixedTargetZ=z;
    PPFixed_Queue(1u,0u,lo,hi,idx,x,y,z);
#endif
}
#if defined(W112_PP_ALWAYS_BEHIND) && !defined(W112_PP_FIXED_POINT)
/* Refresh at most every 50 ms, only inside the existing active PP movement
   chain. Re-resolve by GUID (never trust a potentially stale object pointer).
   A target turn/move updates the same rear-sector offset before LongPP
   rewrites this movement packet; the 56-way HARDLOS retry sweep is intact. */
static void PPHardRefreshBehind(void)
{
    DWORD now;BYTE*t;float x,y,z,o,sn=0.0f,cs=1.0f;
    if(!g_ppHardArmed||(g_ppHardLo|g_ppHardHi)==0u)return;
    now=GT()?GT()():0u;
    if(g_ppRearLastRefresh&&(DWORD)(now-g_ppRearLastRefresh)<PP_REAR_FOLLOW_REFRESH_MS)return;
    g_ppRearLastRefresh=now;
    t=ObjByGuid(g_ppHardLo,g_ppHardHi);if(!Ptr(t))return;
    if(*(DWORD*)(t+OFF_OBJ_GUID_LOW)!=g_ppHardLo||*(DWORD*)(t+OFF_OBJ_GUID_HIGH)!=g_ppHardHi)return;
    x=*(float*)(t+OFF_UNIT_X);y=*(float*)(t+OFF_UNIT_Y);
    z=*(float*)(t+OFF_UNIT_Z);o=*(float*)(t+OFF_UNIT_O);
    if(x==g_ppRearTargetX&&y==g_ppRearTargetY&&z==g_ppRearTargetZ&&o==g_ppRearTargetO)return;
    SinCosF(o,&sn,&cs);
    g_ppHardX=x-cs*g_ppRearBack-sn*g_ppRearSide;
    g_ppHardY=y-sn*g_ppRearBack+cs*g_ppRearSide;
    g_ppHardZ=z+g_ppRearDz;
    g_ppHardO=PPAtan2YX(y-g_ppHardY,x-g_ppHardX);
    if(g_ppHardO<0.0f)g_ppHardO+=6.28318530717958647692f;
    g_ppRearTargetX=x;g_ppRearTargetY=y;g_ppRearTargetZ=z;g_ppRearTargetO=o;
    ++g_ppRearLiveRefresh;
}
#endif
static void PPHardApplySpoof(void)
{
    if(!g_ppHardArmed||!g_ppChainOk||!LongPPActive())return;
    if(!Ptr((void*)g_longPPSpoofXPtr)||!Ptr((void*)g_longPPSpoofYPtr)||!Ptr((void*)g_longPPSpoofZPtr)||!Ptr((void*)g_longPPSpoofOPtr)||!Ptr((void*)g_longPPGuidLoPtr)||!Ptr((void*)g_longPPGuidHiPtr))return;
    if(*(DWORD*)g_longPPGuidLoPtr!=g_ppHardLo||*(DWORD*)g_longPPGuidHiPtr!=g_ppHardHi)return;
#if defined(W112_PP_ALWAYS_BEHIND) && !defined(W112_PP_FIXED_POINT)
    PPHardRefreshBehind();
#endif
    *(float*)g_longPPSpoofXPtr=g_ppHardX;*(float*)g_longPPSpoofYPtr=g_ppHardY;*(float*)g_longPPSpoofZPtr=g_ppHardZ;*(float*)g_longPPSpoofOPtr=g_ppHardO;++g_ppHardLOSOverrides;
}
static void PPHardRetryCancel(void)
{
    g_ppHardRetryActive=0u;g_ppHardRetryScheduled=0u;g_ppHardRetryInjecting=0u;g_ppHardRetryDue=0u;g_ppHardRetrySize=0u;g_ppHardRetryAttempts=0u;g_ppHardRetryLo=0u;g_ppHardRetryHi=0u;g_ppHardArmed=0u;
}
static void PPHardRetryCapture(DataStore5875*packet,DWORD lo,DWORD hi)
{
    BYTE*raw;DWORD i,sz;if(!packet||(lo|hi)==0u)return;sz=packet->size;if(sz<11u||sz>PP_HARDLOS_PACKET_CAP)return;raw=PacketRawBase(packet);if(!raw)return;
    for(i=0u;i<sz;i++)g_ppHardRetryPacket[i]=raw[i];
    g_ppHardRetryActive=1u;g_ppHardRetryScheduled=0u;g_ppHardRetryDue=0u;g_ppHardRetrySize=sz;g_ppHardRetryAttempts=1u;g_ppHardRetryLo=lo;g_ppHardRetryHi=hi;
}
static void PPHardRetryTick(DWORD now)
{
    DataStore5875 clone;BYTE buf[PP_HARDLOS_PACKET_CAP];DWORD i,sz;
    if(!g_ppHardRetryActive||!g_ppHardRetryScheduled||g_ppFailPendingAuto||g_ppHardRetryInjecting)return;
    if((LONG)(now-g_ppHardRetryDue)<0)return;
    if(!g_autoPPEnabled||PPBlackFind(g_ppHardRetryLo,g_ppHardRetryHi)){PPHardRetryCancel();return;}
    if(g_ppHardRetryAttempts>=PP_HARDLOS_VARIANTS){++g_ppHardRetryExhausted;g_ppFailLogEvent=4u;g_ppFailLogLo=g_ppHardRetryLo;g_ppFailLogHi=g_ppHardRetryHi;g_ppFailLogVariant=g_ppHardRetryAttempts;PPHardRetryCancel();return;}
    sz=g_ppHardRetrySize;if(sz<11u||sz>PP_HARDLOS_PACKET_CAP){PPHardRetryCancel();return;}
    for(i=0u;i<sz;i++)buf[i]=g_ppHardRetryPacket[i];
    clone.vtable=ADDR_DATASTORE_VTABLE;clone.dataPtr=buf;clone.backOffset=0u;clone.capacity=PP_HARDLOS_PACKET_CAP;clone.size=sz;clone.unk14=0u;
    g_ppHardRetryScheduled=0u;++g_ppHardRetryAttempts;++g_ppHardRetrySent;g_ppHardRetryInjecting=1u;DirectClientSend(&clone);g_ppHardRetryInjecting=0u;
    /* A higher-priority arbiter (player target / Mining-first) may have blocked the
       synthetic retry before it became a pending PP transaction. Retry later and
       do not consume a HARDLOS variant in that case. */
    if(g_ppHardRetryActive&&!g_ppFailPendingAuto){if(g_ppHardRetryAttempts>1u)--g_ppHardRetryAttempts;g_ppHardRetryScheduled=1u;g_ppHardRetryDue=now+100u;}
}
#if defined(W112_PP_SELECTOR_BLACKLIST_BRIDGE)
static void W112_PPSelector_ReleaseTracked(DWORD lo,DWORD hi);
#endif
static void __cdecl PPBlacklistOnFail(DWORD reason)
{
    DWORD lo,hi,added,now;
    if(!g_ppFailPendingAuto)return;
    lo=g_ppFailPendingLo;hi=g_ppFailPendingHi;
#if defined(W112_PP_FIXED_POINT)
    PPFixed_Queue(3u,reason,lo,hi,g_ppFailPendingVariant,0.0f,0.0f,0.0f);
#endif
    g_ppFailPendingAuto=0u;g_ppFailPendingSawActive=0u;g_ppHardArmed=0u;
    if(reason==SPELL_FAILED_TARGET_NO_POCKETS){
        added=PPBlackAdd(lo,hi);g_ppFailLogEvent=added?1u:2u;g_ppFailLogLo=lo;g_ppFailLogHi=hi;g_ppFailLogVariant=g_ppBlackCount;PPHardRetryCancel();
#if defined(W112_PP_SELECTOR_BLACKLIST_BRIDGE)
        /* A no-pockets result must release the tracked PP transaction now;
           waiting for its original 350-ms retries would starve the selector. */
        W112_PPSelector_ReleaseTracked(lo,hi);
#endif
    }else if(reason==SPELL_FAILED_LINE_OF_SIGHT){
        ++g_ppHardLOSLOSFailures;g_ppFailLogEvent=3u;g_ppFailLogLo=lo;g_ppFailLogHi=hi;g_ppFailLogVariant=g_ppFailPendingVariant;
        if(g_ppHardRetryActive&&g_ppHardRetryLo==lo&&g_ppHardRetryHi==hi&&g_ppHardRetryAttempts<PP_HARDLOS_VARIANTS){now=GT()?GT()():0u;g_ppHardRetryScheduled=1u;g_ppHardRetryDue=now+PP_HARDLOS_RETRY_DELAY_MS;}else PPHardRetryCancel();
    }else PPHardRetryCancel();
}
__declspec(naked) static void PPBlacklist_FailThunk(void)
{
    __asm {
        cmp ecx, 921
        jne pp_fail_chain
        movzx eax, dl
        pushfd
        pushad
        push eax
        call PPBlacklistOnFail
        add esp, 4
        popad
        popfd
pp_fail_chain:
        jmp dword ptr [g_nextPPFailTarget]
    }
}
static void PPScanBlacklistDeaths(DWORD now)
{
    BYTE*m,*o;DWORD i=0u;if((LONG)(now-g_ppBlackNextDeathScan)<0)return;g_ppBlackNextDeathScan=now+PP_BLACK_DEATH_SCAN_MS;if(!g_ppBlackCount)return;
    m=*(BYTE**)ADDR_OBJMGR_GLOBAL;if(!Ptr(m))return;o=*(BYTE**)(m+OFF_OM_FIRST_OBJECT);
    while(i++<4095u&&Ptr(o)){BYTE*n=*(BYTE**)(o+OFF_OBJ_NEXT);DWORD lo=*(DWORD*)(o+OFF_OBJ_GUID_LOW),hi=*(DWORD*)(o+OFF_OBJ_GUID_HIGH),*d=*(DWORD**)(o+OFF_OBJ_DESCRIPTOR_PTR);if(Ptr(d)&&(d[OBJECT_FIELD_TYPE_INDEX]&TYPEMASK_UNIT)&&d[UNIT_FIELD_HEALTH_INDEX]==0u&&PPBlackFind(lo,hi)){if(PPBlackRemove(lo,hi)){PPSweepRemove(lo,hi);++g_ppBlackDeathClears;GatherFileLog("AUTOPP_BLACKLIST_CLEAR_DEATH",now,0u,lo,hi,0.0f,0u,g_ppBlackCount);}}if(n==o)break;o=n;}
}
static void PPBlacklistTick(DWORD now)
{
    DWORD ev=g_ppFailLogEvent,lo,hi,aux;
    if(g_ppFailPendingAuto){if(LongPPActive())g_ppFailPendingSawActive=1u;else if(g_ppFailPendingSawActive){g_ppFailPendingAuto=0u;g_ppFailPendingSawActive=0u;PPHardRetryCancel();}else if((LONG)(now-g_ppFailPendingUntil)>=0){g_ppFailPendingAuto=0u;PPHardRetryCancel();}}
    if(ev){lo=g_ppFailLogLo;hi=g_ppFailLogHi;aux=g_ppFailLogVariant;g_ppFailLogEvent=0u;if(ev==1u)GatherFileLog("AUTOPP_BLACKLIST_EMPTY_POCKETS",now,0u,lo,hi,0.0f,0u,aux);else if(ev==2u)GatherFileLog("AUTOPP_BLACKLIST_ALREADY",now,0u,lo,hi,0.0f,0u,aux);else if(ev==3u)GatherFileLog("AUTOPP_HARDLOS_LOS_RETRY",now,0u,lo,hi,0.0f,0u,aux);else if(ev==4u)GatherFileLog("AUTOPP_HARDLOS_SWEEP_EXHAUSTED",now,0u,lo,hi,0.0f,0u,aux);}
    PPScanBlacklistDeaths(now);
    PPHardRetryTick(now);
}
static float AbsF(float v){return v<0?-v:v;}
static void SendReal(BYTE*p){if(Ptr(p))((SendMove_t)ADDR_SEND_MOVE)(p,MSG_MOVE_HEARTBEAT);}
static DWORD* MoveFlags(BYTE*p){BYTE*mi;if(!Ptr(p))return 0;mi=*(BYTE**)(p+OFF_PLAYER_MOVEINFO_PTR);if(!Ptr(mi))return 0;return(DWORD*)(mi+OFF_MOVEINFO_FLAGS);}


/* ---------------------------- AutoGather --------------------------- */
static char* AppStr(char*p,const char*s){while(*s)*p++=*s++;return p;}
static char* AppU32(char*p,DWORD v){char t[16];DWORD n=0;if(!v){*p++='0';return p;}while(v&&n<15u){t[n++]=(char)('0'+(v%10u));v/=10u;}while(n)*p++=t[--n];return p;}
static char* AppHex32(char*p,DWORD v){static const char h[]="0123456789ABCDEF";int i;for(i=7;i>=0;i--)*p++=h[(v>>(i*4))&0xFu];return p;}
static char* AppS32(char*p,LONG v){DWORD u;if(v<0){*p++='-';u=(DWORD)(-v);}else u=(DWORD)v;return AppU32(p,u);}
static DWORD FToU10(float v){if(v<=0.0f)return 0u;if(v>429496000.0f)return 0xFFFFFFFFu;return (DWORD)(v*10.0f);}

static void GatherFileLog(const char*ev,DWORD now,DWORD entry,DWORD lo,DWORD hi,float distSq,DWORD attempts,DWORD aux)
{
    char b[1536];char*p=b;DWORD wr=0,size=0;HANDLE h;CreateFileA_t cf=CF();WriteFile_t wf=WF();SetFilePointer_t sfp=SFP();GetFileSize_t gfs=GFS();SetEndOfFile_t seof=SEOF();CloseHandle_t ch=CH();BYTE*pl=LocalPlayer();DWORD combat=pl?Combat(pl):0u;
    if(!cf||!wf||!sfp||!ch)return;
    p=AppStr(p,"tick=");p=AppU32(p,now);p=AppStr(p," event=");p=AppStr(p,ev);
    p=AppStr(p," enabled=");p=AppU32(p,g_gatherEnabled);p=AppStr(p," combat=");p=AppU32(p,combat);p=AppStr(p," stealth=");p=AppU32(p,pl?GatherHasStealth(pl):0u);
    p=AppStr(p," mining=");p=AppU32(p,g_hasMining);p=AppStr(p," herbalism=");p=AppU32(p,g_hasHerbalism);
    p=AppStr(p," active=");p=AppU32(p,g_gatherActive);p=AppStr(p," lootwait=");p=AppU32(p,g_gatherLootWait);p=AppStr(p," ppchain=");p=AppU32(p,g_ppChainOk);p=AppStr(p," ppactive=");p=AppU32(p,LongPPActive());p=AppStr(p," ppfast=");p=AppU32(p,g_ppFastNoTouch);p=AppStr(p," pppreempt=");p=AppU32(p,g_ppTxPreempts);p=AppStr(p," ppreset=");p=AppU32(p,g_ppRealResets);p=AppStr(p," ppinjectyield=");p=AppU32(p,g_ppInjectYields);p=AppStr(p," ppnofallyield=");p=AppU32(p,g_ppNoFallYields);p=AppStr(p," ppsbyield=");p=AppU32(p,g_ppSafeBreakYields);p=AppStr(p," gnofallyield=");p=AppU32(p,g_gatherNoFallYields);
    if(g_gatherLootWait){p=AppStr(p," waitleft=");p=AppU32(p,((LONG)(g_gatherLootWaitUntil-now)>0)?(g_gatherLootWaitUntil-now):0u);}
    p=AppStr(p," entry=");p=AppU32(p,entry);
    p=AppStr(p," guid=");p=AppHex32(p,hi);p=AppHex32(p,lo);p=AppStr(p," dist2x10=");p=AppU32(p,FToU10(distSq));
    p=AppStr(p," attempts=");p=AppU32(p,attempts);p=AppStr(p," aux=");p=AppU32(p,aux);
    p=AppStr(p," visible=");p=AppU32(p,g_gatherScanVisible);p=AppStr(p," nodes=");p=AppU32(p,g_gatherScanNodes);p=AppStr(p," profmatch=");p=AppU32(p,g_gatherScanProfMatch);p=AppStr(p," inrange=");p=AppU32(p,g_gatherScanInRange);p=AppStr(p," posfail=");p=AppU32(p,g_gatherScanPosFail);p=AppStr(p," eligible=");p=AppU32(p,g_gatherScanEligible);
    if(pl){p=AppStr(p," px10=");p=AppS32(p,(LONG)(*(float*)(pl+OFF_UNIT_X)*10.0f));p=AppStr(p," py10=");p=AppS32(p,(LONG)(*(float*)(pl+OFF_UNIT_Y)*10.0f));p=AppStr(p," pz10=");p=AppS32(p,(LONG)(*(float*)(pl+OFF_UNIT_Z)*10.0f));}
    if(g_gatherTargetLo){p=AppStr(p," gx10=");p=AppS32(p,(LONG)(g_gatherX*10.0f));p=AppStr(p," gy10=");p=AppS32(p,(LONG)(g_gatherY*10.0f));p=AppStr(p," gz10=");p=AppS32(p,(LONG)(g_gatherZ*10.0f));p=AppStr(p," spoof=");p=AppU32(p,g_gatherSpoof);p=AppStr(p," possrc=");p=AppU32(p,g_gatherPosSource);}
    if(g_diagEntry){p=AppStr(p," diag_entry=");p=AppU32(p,g_diagEntry);p=AppStr(p," diag_obj=0x");p=AppHex32(p,g_diagObj);p=AppStr(p," diag_src=");p=AppU32(p,g_diagPosSource);p=AppStr(p," diag_d2x10=");p=AppU32(p,FToU10(g_diagD2));p=AppStr(p," diag_xyz10=");p=AppS32(p,(LONG)(g_diagX*10.0f));*p++=',';p=AppS32(p,(LONG)(g_diagY*10.0f));*p++=',';p=AppS32(p,(LONG)(g_diagZ*10.0f));p=AppStr(p," desc10=");p=AppS32(p,(LONG)(g_diagDescX*10.0f));*p++=',';p=AppS32(p,(LONG)(g_diagDescY*10.0f));*p++=',';p=AppS32(p,(LONG)(g_diagDescZ*10.0f));p=AppStr(p," move10=");p=AppS32(p,(LONG)(g_diagMoveX*10.0f));*p++=',';p=AppS32(p,(LONG)(g_diagMoveY*10.0f));*p++=',';p=AppS32(p,(LONG)(g_diagMoveZ*10.0f));p=AppStr(p," legacy10=");p=AppS32(p,(LONG)(g_diagLegacyX*10.0f));*p++=',';p=AppS32(p,(LONG)(g_diagLegacyY*10.0f));*p++=',';p=AppS32(p,(LONG)(g_diagLegacyZ*10.0f));}
    *p++='\r';*p++='\n';
    h=cf(g_gatherLogName,GENERIC_WRITE,FILE_SHARE_READ|FILE_SHARE_WRITE,0,OPEN_ALWAYS,FILE_ATTRIBUTE_NORMAL,0);if(h==INVALID_HANDLE_VALUE||!h)return;
    if(gfs&&seof){size=gfs(h,0);if(size!=0xFFFFFFFFu&&size>GATHER_LOG_MAX_BYTES){sfp(h,0,0,FILE_BEGIN);seof(h);}}
    sfp(h,0,0,FILE_END);wf(h,b,(DWORD)(p-b),&wr,0);ch(h);
}

static void DebugChat(const char*script)
{
    DWORD fn=ADDR_FRAMESCRIPT_EXECUTE;if(!script)return;
    __asm {
        push ebx
        mov ecx, script
        mov edx, script
        xor eax, eax
        mov ebx, fn
        call ebx
        pop ebx
    }
}
static const char g_chatReady[]="if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage('|cff55ff55[MovementCore V68]|r Mining HARD-LOS + PP death-blacklist + PP REAR-ONLY HARDLOS3D retry + F11 loaded') end";
static const char g_chatPPOn[]="if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage('|cff55ff55[AutoPP]|r ON - F11 toggle') end";
static const char g_chatPPOff[]="if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage('|cffffaa00[AutoPP]|r OFF - manual Pick Pocket still works') end";
static const char g_chatChainBad[]="if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage('|cffff3333[AutoGather]|r LongPickPocket chain/order invalid - AutoGather blocked to protect PP') end";
static const char g_chatOn[]="if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage('|cff55ff55[AutoGather]|r ON') end";
static const char g_chatOff[]="if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage('|cffffaa00[AutoGather]|r OFF') end";
static const char g_chatOpenOn[]="if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage('|cff55ff55[AutoOpen]|r ON - F12 toggle') end";
static const char g_chatOpenOff[]="if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage('|cffffaa00[AutoOpen]|r OFF - F12 toggle') end";
static const char g_pickLockScript[]="CastSpellByName('Pick Lock')";
static const char g_chestLootScript[]="if LootFrame and LootFrame:IsShown() then for i=1,GetNumLootItems() do LootSlot(i) end end";

/* AutoOpen is always native and in melee. Never prime Pick Lock with a
 * temporary player-position overwrite, even if gather spoof is active. */
static DWORD AutoOpenInMelee(BYTE*p,BYTE*obj,float*outDistSq);
static void AutoOpenPrimePickLock(BYTE*p,DWORD now)
{
    BYTE*obj;
    if(!Ptr(p))return;
    obj=ObjByGuid(g_gatherTargetLo,g_gatherTargetHi);
    if(!Ptr(obj)||!AutoOpenInMelee(p,obj,0))return;
    DebugChat(g_pickLockScript);
    GatherFileLog("AUTOOPEN_PICKLOCK_PRIME_NATIVE",now,g_gatherEntry,g_gatherTargetLo,g_gatherTargetHi,g_gatherDistSq,g_gatherAttempts,g_gatherKind);
}

static DWORD IsStealthSpell(DWORD spell)
{
    return spell==SPELL_STEALTH_R1||spell==SPELL_STEALTH_R2||spell==SPELL_STEALTH_R3||spell==SPELL_STEALTH_R4||
           spell==SPELL_VANISH_STEALTH_R1||spell==SPELL_VANISH_STEALTH_R2;
}

static DWORD GatherHasStealth(BYTE*p)
{
    DWORD*d,i,spell;if(!Ptr(p))return 0u;d=*(DWORD**)(p+OFF_OBJ_DESCRIPTOR_PTR);if(!Ptr(d))return 0u;
    for(i=0u;i<UNIT_FIELD_AURA_SLOTS;i++){spell=d[UNIT_FIELD_AURA_INDEX+i];if(spell&&IsStealthSpell(spell))return 1u;}
    return 0u;
}

/* Vanilla 1.12 does not have the later auto-unshift behavior for actions that
 * cannot be used while stealthed.  Use only 1.12-era buff APIs and cancel the
 * rogue Stealth/Vanish aura immediately before the gather interaction. */
static const char g_breakStealthScript[]=
"for i=0,15 do local b=GetPlayerBuff(i,'HELPFUL'); if b and b>=0 then local t=GetPlayerBuffTexture(b); if t then local q=string.lower(t); if string.find(q,'ability_stealth') or string.find(q,'ability_vanish') then CancelPlayerBuff(b); break end end end end";

static DWORD GatherRequestStealthBreak(BYTE*p,DWORD now)
{
    if(!GatherHasStealth(p)){g_gatherStealthPending=0u;return 0u;}
    ++g_gatherStealthBreaks;g_gatherStealthPending=1u;DebugChat(g_breakStealthScript);
    GatherFileLog("STEALTH_BREAK_REQUEST",now,g_gatherEntry,g_gatherTargetLo,g_gatherTargetHi,g_gatherDistSq,g_gatherAttempts,g_gatherKind);
    return 1u;
}

static DWORD GatherLootOpen(void)
{
    return (*(DWORD*)ADDR_IS_LOOTING_STATE)!=0u ? 1u : 0u;
}

static DWORD SkillPresent(BYTE*p,DWORD skill)
{
    DWORD*d,i,v;if(!Ptr(p))return 0u;d=*(DWORD**)(p+OFF_OBJ_DESCRIPTOR_PTR);if(!Ptr(d))return 0u;
    for(i=0u;i<PLAYER_SKILL_SLOT_COUNT;i++){v=d[PLAYER_SKILL_INFO_BASE_INDEX+i*PLAYER_SKILL_SLOT_STRIDE]&0xFFFFu;if(v==skill)return 1u;if(v==0u&&i>64u)break;}
    return 0u;
}

static void RefreshProfessions(BYTE*p,DWORD now)
{
    DWORD bits;g_hasMining=SkillPresent(p,SKILL_MINING);g_hasHerbalism=SkillPresent(p,SKILL_HERBALISM);bits=(g_hasMining?1u:0u)|(g_hasHerbalism?2u:0u);
    if(bits!=g_lastProfBits){g_lastProfBits=bits;GatherFileLog("PROF_CHANGE",now,0u,0u,0u,0.0f,0u,bits);}
}

static DWORD IsHerbEntry(DWORD e)
{
    /* Vanilla aliases matter: several visually/minimap-identical herbs use
       alternate GO entries in specific zones/instances. */
    switch(e){
        case 1617u:case 3725u:                         /* Silverleaf */
        case 1618u:case 3724u:                         /* Peacebloom */
        case 1619u:case 3726u:                         /* Earthroot */
        case 1620u:case 3727u:case 100022u:            /* Mageroyal */
        case 1621u:case 3729u:case 100027u:            /* Briarthorn */
        case 2045u:case 100177u:                       /* Stranglekelp */
        case 1622u:case 3730u:case 100045u:            /* Bruiseweed */
        case 1623u:case 100433u:                       /* Wild Steelbloom */
        case 1628u:                                    /* Grave Moss */
        case 1624u:case 100134u:                       /* Kingsblood */
        case 2041u:                                    /* Liferoot */
        case 2042u:                                    /* Fadeleaf */
        case 2046u:                                    /* Goldthorn */
        case 2043u:                                    /* Khadgar's Whisker */
        case 2044u:                                    /* Wintersbite */
        case 2866u:                                    /* Firebloom */
        case 142140u:case 180165u:                     /* Purple Lotus */
        case 142141u:case 176642u:                     /* Arthas' Tears */
        case 142142u:case 176636u:case 180164u:        /* Sungrass */
        case 142143u:case 183046u:                     /* Blindweed alias */
        case 142144u:                                  /* Ghost Mushroom */
        case 142145u:case 176637u:                     /* Gromsblood */
        case 176583u:case 176638u:case 180167u:        /* Golden Sansam */
        case 176584u:case 176639u:case 180168u:        /* Dreamfoil */
        case 176586u:case 176640u:case 180166u:        /* Mountain Silversage */
        case 176587u:case 176641u:                     /* Plaguebloom */
        case 176588u:                                  /* Icecap */
        case 176589u:                                  /* Black Lotus */
            return 1u;
        default:return 0u;
    }
}
/* One bit per ore family (including every supported alternate GO entry).
 * A family disabled in the GUI must also disappear from the Mining-first PP
 * arbitration scan; never blacklist individual GUIDs or retry attempts. */
static volatile DWORD g_miningBlacklistMask=0u;
/* Separate session-local GUID blacklist: a combat onset shortly after a
 * mining interaction can be associated with the node without blocking its ore family. */
typedef struct { DWORD entry,lo,hi; } CombatVein;
static CombatVein g_combatVeins[COMBAT_VEIN_MAX];
static volatile DWORD g_combatVeinCount=0u,g_combatVeinEnabled=1u;
static volatile DWORD g_combatWatch=0u,g_combatWatchStart=0u,g_combatWatchClicks=0u;
static volatile DWORD g_combatWatchEntry=0u,g_combatWatchLo=0u,g_combatWatchHi=0u;
static volatile DWORD g_combatVeinLastCombat=0u;
static DWORD CombatVeinContains(DWORD entry,DWORD lo,DWORD hi)
{
    DWORD i;
    if(!g_combatVeinEnabled)return 0u;
    for(i=0;i<g_combatVeinCount;i++)
        if(g_combatVeins[i].entry==entry&&g_combatVeins[i].lo==lo&&g_combatVeins[i].hi==hi)return 1u;
    return 0u;
}
static DWORD CombatVeinAdd(DWORD entry,DWORD lo,DWORD hi)
{
    DWORD i;
    if(!g_combatVeinEnabled||!entry||(!lo&&!hi)||CombatVeinContains(entry,lo,hi))return 0u;
    i=g_combatVeinCount;
    if(i>=COMBAT_VEIN_MAX)return 0u;
    g_combatVeins[i].entry=entry;g_combatVeins[i].lo=lo;g_combatVeins[i].hi=hi;
    g_combatVeinCount=i+1u;return 1u;
}


static DWORD MiningBlacklistBit(DWORD e)
{
    switch(e){
        case 1731u:case 2055u:case 3763u:case 100145u:case 103713u:case 103714u:return 1u<<0;  /* Copper */
        case 1732u:case 2054u:case 3764u:case 100147u:case 100224u:case 103709u:case 103711u:return 1u<<1; /* Tin */
        case 1733u:case 100162u:case 105569u:case 73940u:return 1u<<2;  /* Silver */
        case 1735u:case 100163u:case 103710u:case 103712u:case 73939u:return 1u<<3; /* Iron */
        case 1734u:case 100666u:case 150080u:case 181109u:case 73941u:return 1u<<4; /* Gold */
        case 2040u:case 100176u:case 150079u:case 176645u:case 123310u:return 1u<<5; /* Mithril */
        case 2047u:case 100197u:case 150081u:case 181108u:case 123309u:return 1u<<6; /* Truesilver */
        case 324u:case 150082u:case 176643u:case 123848u:return 1u<<7; /* Small Thorium */
        case 175404u:case 176644u:case 177388u:return 1u<<8; /* Rich Thorium */
        case 165658u:return 1u<<9;  /* Dark Iron */
        case 2653u:return 1u<<10;   /* Lesser Bloodstone */
        case 1610u:case 1667u:return 1u<<11; /* Incendicite */
        case 19903u:return 1u<<12;  /* Indurium */
        case 180215u:return 1u<<13; /* Hakkari Thorium */
        default:return 0u;
    }
}

static DWORD IsMiningEntry(DWORD e)
{
    DWORD bit=MiningBlacklistBit(e);
    return bit&&!(g_miningBlacklistMask&bit);
}

static const char* MiningName(DWORD e)
{
    switch(e){
        case 1731u:case 2055u:case 3763u:case 100145u:case 103713u:case 103714u:return "Copper Vein";
        case 1732u:case 2054u:case 3764u:case 100147u:case 100224u:case 103709u:case 103711u:return "Tin Vein";
        case 1733u:case 100162u:case 105569u:case 73940u:return "Silver Vein";
        case 1735u:case 100163u:case 103710u:case 103712u:case 73939u:return "Iron Deposit";
        case 1734u:case 100666u:case 150080u:case 181109u:case 73941u:return "Gold Vein";
        case 2040u:case 100176u:case 150079u:case 176645u:case 123310u:return "Mithril Deposit";
        case 2047u:case 100197u:case 150081u:case 181108u:case 123309u:return "Truesilver Deposit";
        case 324u:case 150082u:case 176643u:case 123848u:return "Small Thorium Vein";
        case 175404u:case 176644u:case 177388u:return "Rich Thorium Vein";
        case 165658u:return "Dark Iron Deposit";
        case 2653u:return "Lesser Bloodstone Deposit";
        case 1610u:case 1667u:return "Incendicite Mineral Vein";
        case 19903u:return "Indurium Mineral Vein";
        case 180215u:return "Hakkari Thorium Vein";
        default:return "Mining node";
    }
}

/* Explicit 5875-world treasure IDs; never sweep generic/quest GO objects.
 * Each entry belongs to exactly one selectable group (bits 0..5). */
static DWORD ChestGroupBit(DWORD e)
{
    switch(e){
        /* Vanilla Battered Chest templates: 2843/2844/2846/2849/
         * 106318/106319. The former 2-ID filter missed the common spawns.
         * Evidence: https://vanillawow.home.blog/2021/03/26/all-treasure-chests-in-vanilla-wow/
         * Actual private-server entry must still be confirmed by GUI debug. */
        case 2843u:case 2844u:case 2846u:case 2849u:
        case 106318u:case 106319u:return 1u<<0;
        case 2850u:case 2852u:case 2855u:case 2857u:case 4149u:return 1u<<1; /* solid variants: 2852 also spawns in Duskwood */
        case 75293u:return 1u<<2; /* large battered */
        case 74448u:case 75298u:case 75299u:case 75300u:return 1u<<3; /* large solid */
        case 74447u:case 75295u:case 75296u:case 75297u:return 1u<<4; /* iron bound */
        case 131978u:case 153469u:return 1u<<5; /* mithril bound */
        default:return 0u;
    }
}

static DWORD IsAutoOpenEntry(DWORD e)
{
    /* Vanilla lockpicking-training/world footlockers only.  Deliberately not a
       generic chest scanner, so quest chests and unrelated objects are safe. */
    switch(e){
        case 178244u:                                     /* Practice Lockbox */
        case 179486u:case 179488u:case 179490u:           /* Battered Footlocker */
        case 179487u:case 179489u:case 179491u:           /* Waterlogged Footlocker */
        case 179492u:case 179494u:case 179496u:           /* Dented Footlocker */
        case 179493u:case 179497u:                        /* Mossy Footlocker */
        case 179498u:                                     /* Scarlet Footlocker */
        case 123330u:case 123331u:case 123332u:case 123333u: /* Buccaneer's Strongbox: vanilla GO entries */
            return 1u;
        default:return 0u;
    }
}

static const char* AutoOpenName(DWORD e)
{
    switch(e){
        case 178244u:return "Practice Lockbox";
        case 179486u:case 179488u:case 179490u:return "Battered Footlocker";
        case 179487u:case 179489u:case 179491u:return "Waterlogged Footlocker";
        case 179492u:case 179494u:case 179496u:return "Dented Footlocker";
        case 179493u:case 179497u:return "Mossy Footlocker";
        case 179498u:return "Scarlet Footlocker";
        case 123330u:case 123331u:case 123332u:case 123333u:return "Buccaneer\\'s Strongbox";
        default:return "Locked footlocker";
    }
}

static void ChatAttempt(DWORD kind,DWORD entry,DWORD lo,DWORD hi,DWORD now)
{
    char b[512];char*p=b;const char*name;DWORD allow=1u;
    if(kind==2u){
        if(lo==g_lastMiningChatLo&&hi==g_lastMiningChatHi&&(DWORD)(now-g_lastMiningChatTick)<AUTOOPEN_CHAT_REPEAT_MS)allow=0u;
        if(!allow)return;g_lastMiningChatLo=lo;g_lastMiningChatHi=hi;g_lastMiningChatTick=now;name=MiningName(entry);
        p=AppStr(p,"if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage('|cff55ff55[AutoGather]|r Mining: wykryto " );
        p=AppStr(p,name);p=AppStr(p," (entry " );p=AppU32(p,entry);p=AppStr(p,") - probuje kopac') end");
    }else if(kind==3u){
        if(lo==g_lastOpenChatLo&&hi==g_lastOpenChatHi&&(DWORD)(now-g_lastOpenChatTick)<AUTOOPEN_CHAT_REPEAT_MS)allow=0u;
        if(!allow)return;g_lastOpenChatLo=lo;g_lastOpenChatHi=hi;g_lastOpenChatTick=now;name=AutoOpenName(entry);
        p=AppStr(p,"if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage('|cff66ccff[AutoOpen]|r wykryto " );
        p=AppStr(p,name);p=AppStr(p," (entry " );p=AppU32(p,entry);p=AppStr(p,") - probuje otworzyc') end");
    }else if(kind==4u){
        /* One discovery line per GO; a failed retry is not another find. */
        if(lo==g_lastChestChatLo&&hi==g_lastChestChatHi&&
           (DWORD)(now-g_lastChestChatTick)<60000u)return;
        g_lastChestChatLo=lo;g_lastChestChatHi=hi;g_lastChestChatTick=now;
        p=AppStr(p,"if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage('|cff55ff55[AutoChest]|r Znaleziono ");
        switch(ChestGroupBit(entry)){
            case 1u:p=AppStr(p,"Battered Chest");break;
            case 2u:p=AppStr(p,"Solid Chest");break;
            case 4u:p=AppStr(p,"Large Battered Chest");break;
            case 8u:p=AppStr(p,"Large Solid Chest");break;
            case 16u:p=AppStr(p,"Iron Bound Chest");break;
            case 32u:p=AppStr(p,"Mithril Bound Chest");break;
            default:p=AppStr(p,"Chest");break;
        }
        p=AppStr(p," (entry ");p=AppU32(p,entry);
        p=AppStr(p,") - probuje otworzyc') end");
    }else return;
    *p=0;DebugChat(b);
}

static float DistSq3(float ax,float ay,float az,float bx,float by,float bz){float dx=ax-bx,dy=ay-by,dz=az-bz;return dx*dx+dy*dy+dz*dz;}

static DWORD ValidWorldPos(float x,float y,float z)
{
    if(x!=x||y!=y||z!=z)return 0u;
    if(AbsF(x)>20000.0f||AbsF(y)>20000.0f||AbsF(z)>5000.0f)return 0u;
    return 1u;
}

/* Position sources: 1=GAMEOBJECT_POS_* descriptor fields (preferred),
 * 2=ObjectMovementData->Position, 3=legacy object+0x240 fallback. */
static DWORD GetGOPos(BYTE*o,DWORD*desc,float*x,float*y,float*z,DWORD*src)
{
    BYTE*mv;float a,b,c;
    if(src)*src=0u;if(!Ptr(o))return 0u;
    if(Ptr(desc)){
        a=*(float*)&desc[GAMEOBJECT_POS_X_INDEX];b=*(float*)&desc[GAMEOBJECT_POS_Y_INDEX];c=*(float*)&desc[GAMEOBJECT_POS_Z_INDEX];
        if(ValidWorldPos(a,b,c)){*x=a;*y=b;*z=c;if(src)*src=1u;return 1u;}
    }
    mv=*(BYTE**)(o+OFF_OBJ_MOVEMENT_DATA);
    if(Ptr(mv)){
        a=*(float*)(mv+OFF_OBJMOVE_POS_X);b=*(float*)(mv+OFF_OBJMOVE_POS_Y);c=*(float*)(mv+OFF_OBJMOVE_POS_Z);
        if(ValidWorldPos(a,b,c)){*x=a;*y=b;*z=c;if(src)*src=2u;return 1u;}
    }
    a=*(float*)(o+OFF_GO_LEGACY_X);b=*(float*)(o+OFF_GO_LEGACY_Y);c=*(float*)(o+OFF_GO_LEGACY_Z);
    if(ValidWorldPos(a,b,c)){*x=a;*y=b;*z=c;if(src)*src=3u;return 1u;}
    return 0u;
}

/* Chest-only position resolution: a zeroed descriptor XYZ is a valid finite
 * float triplet, but NOT a loaded chest's world location. Probe descriptor,
 * ObjectMovementData and legacy position, selecting the closest credible
 * source to the player. Mining/Herb/AutoOpen keep their current provenance.
 * src 1=descriptor, 2=movement, 3=legacy. */
static DWORD ChestChoosePos(float a,float b,float c,DWORD source,
                           float px,float py,float pz,float*best,
                           float*x,float*y,float*z,DWORD*src)
{
    float d2;
    if(!ValidWorldPos(a,b,c)||(a==0.0f&&b==0.0f&&c==0.0f))return 0u;
    d2=DistSq3(px,py,pz,a,b,c);
    if(d2>=*best)return 0u;
    *best=d2;*x=a;*y=b;*z=c;if(src)*src=source;return 1u;
}
static DWORD GetChestPos(BYTE*o,DWORD*desc,float px,float py,float pz,
                         float*x,float*y,float*z,DWORD*src)
{
    BYTE*mv;float best=1.0e30f;DWORD found=0u;
    if(src)*src=0u;
    if(!Ptr(o))return 0u;
    if(Ptr(desc))
        found|=ChestChoosePos(*(float*)&desc[GAMEOBJECT_POS_X_INDEX],
                              *(float*)&desc[GAMEOBJECT_POS_Y_INDEX],
                              *(float*)&desc[GAMEOBJECT_POS_Z_INDEX],1u,
                              px,py,pz,&best,x,y,z,src);
    mv=*(BYTE**)(o+OFF_OBJ_MOVEMENT_DATA);
    if(Ptr(mv))
        found|=ChestChoosePos(*(float*)(mv+OFF_OBJMOVE_POS_X),
                              *(float*)(mv+OFF_OBJMOVE_POS_Y),
                              *(float*)(mv+OFF_OBJMOVE_POS_Z),2u,
                              px,py,pz,&best,x,y,z,src);
    found|=ChestChoosePos(*(float*)(o+OFF_GO_LEGACY_X),
                          *(float*)(o+OFF_GO_LEGACY_Y),
                          *(float*)(o+OFF_GO_LEGACY_Z),3u,
                          px,py,pz,&best,x,y,z,src);
    return found;
}


/* Track Chests: client-visible GO scan with the *same* entry/position filters
 * as AutoChest. Runs on the existing game timer; it never sends movement,
 * right clicks, spell casts or loot requests. Only the current loaded world
 * and enabled chest groups can produce minimap dots. 5875 minimap zoom
 * radii (yards) are 150/120/90/60/40/25; positions use a north-up map
 * basis (world X decreases east, world Y increases north). */
#define TRACK_CHEST_MAX_DOTS 16u
#define TRACK_CHEST_RANGE_SQ 22500.0f
#define TRACK_CHEST_SCAN_MS 400u
static const char g_trackChestHide[]=
    "if W112_ChestDots then for i=1,16 do local t=W112_ChestDots[i];if t then t:Hide() end end end";
/* Only touch the currently verified local player's descriptor. The native
 * renderer remains responsible for filtering, range, zoom and native icons.
 * Preserve herbs/minerals/any other bits; remove only our own treasure bit.
 * Never chase an old pointer through a map/BG transition. */
static void TrackChestNativeTick(BYTE*p)
{
    DWORD*desc=0u;DWORD mask;
    if(Ptr(p))desc=*(DWORD**)(p+OFF_OBJ_DESCRIPTOR_PTR);
    if(!Ptr(desc)||(desc[OBJECT_FIELD_TYPE_INDEX]&TYPEMASK_PLAYER)==0u){
        g_trackNativeDesc=0u;g_trackNativeOwn=0u;g_trackNativeMask=0u;
        return;
    }
    if(desc!=g_trackNativeDesc){
        g_trackNativeDesc=desc;g_trackNativeOwn=0u;
    }
    mask=desc[TRACK_NATIVE_RESOURCES_INDEX];
    if(g_trackChestsEnabled&&g_trackChestNativeMode){
        if(!(mask&TRACK_NATIVE_TREASURE_BIT)){
            mask|=TRACK_NATIVE_TREASURE_BIT;
            desc[TRACK_NATIVE_RESOURCES_INDEX]=mask;
            g_trackNativeOwn=1u;
        }
    }else if(g_trackNativeOwn){
        if(mask&TRACK_NATIVE_TREASURE_BIT){
            mask&=~TRACK_NATIVE_TREASURE_BIT;
            desc[TRACK_NATIVE_RESOURCES_INDEX]=mask;
        }
        g_trackNativeOwn=0u;
    }
    g_trackNativeMask=mask;
}
static void TrackChestTick(BYTE*p,DWORD now)
{
    BYTE*m,*o;DWORD i,count=0u,*desc,group,src=0u;
    float px,py,pz,x,y,z,dx,dy;static char script[4096];char*w=script;
    if(!g_trackChestsEnabled||g_trackChestNativeMode||!Ptr(p)){
        g_trackChestCount=0u;g_trackChestNext=0u;
        if(g_trackChestShown){DebugChat(g_trackChestHide);g_trackChestShown=0u;}
        return;
    }
    if(g_trackChestNext&&(LONG)(now-g_trackChestNext)<0)return;
    g_trackChestNext=now+TRACK_CHEST_SCAN_MS;
    m=*(BYTE**)ADDR_OBJMGR_GLOBAL;
    if(!Ptr(m)){
        g_trackChestCount=0u;
        if(g_trackChestShown){DebugChat(g_trackChestHide);g_trackChestShown=0u;}
        return;
    }
    px=*(float*)(p+OFF_UNIT_X);py=*(float*)(p+OFF_UNIT_Y);
    pz=*(float*)(p+OFF_UNIT_Z);
    w=AppStr(w,
        "if Minimap then W112_ChestDots=W112_ChestDots or {};"
        "local m=Minimap;local z=m:GetZoom() or 0;"
        "local rad=({150,120,90,60,40,25})[z+1] or 150;"
        "local scale=(m:GetWidth()/2)/rad;"
        /* Vanilla 5875 does not register the rotateMinimap CVar. The
         * client throws a blocking Lua error even when comparing to '1'.
         * Draw north-up without asking the engine for that absent CVar. */
        "local dots={");
    o=*(BYTE**)(m+OFF_OM_FIRST_OBJECT);
    for(i=0u;i<4095u&&Ptr(o);++i){
        BYTE*n=*(BYTE**)(o+OFF_OBJ_NEXT);
        desc=*(DWORD**)(o+OFF_OBJ_DESCRIPTOR_PTR);
        if(count<TRACK_CHEST_MAX_DOTS&&Ptr(desc)&&
           (desc[OBJECT_FIELD_TYPE_INDEX]&TYPEMASK_GAMEOBJECT)){
            group=ChestGroupBit(desc[OBJECT_FIELD_ENTRY_INDEX]);
            if(group&&(g_chestGroupsMask&group)&&
               GetChestPos(o,desc,px,py,pz,&x,&y,&z,&src)){
                dx=x-px;dy=y-py;
                if(dx*dx+dy*dy<=TRACK_CHEST_RANGE_SQ){
                    if(count)w=AppStr(w,",");
                    w=AppStr(w,"{");w=AppS32(w,(LONG)(-dx*10.0f));
                    w=AppStr(w,",");w=AppS32(w,(LONG)(dy*10.0f));
                    w=AppStr(w,"}");++count;
                }
            }
        }
        if(!Ptr(n)||n==o)break;
        o=n;
    }
    g_trackChestCount=count;
    w=AppStr(w,
        "};for i=1,16 do local v=dots[i];local t=W112_ChestDots[i];"
        "if v and not t then t=m:CreateTexture(nil,'OVERLAY');"
        "t:SetTexture(1,0.8,0);t:SetWidth(7);t:SetHeight(7);"
        "W112_ChestDots[i]=t end;"
        "if t then if v then local a=v[1]/10;local b=v[2]/10;"
        /* Minimap is north-up on this client: no rotation transform. */
        "if a*a+b*b<=rad*rad then t:ClearAllPoints();"
        "t:SetPoint('CENTER',m,'CENTER',a*scale,b*scale);t:Show()"
        "else t:Hide() end else t:Hide() end end end end");
    *w=0;
    DebugChat(script);
    g_trackChestShown=1u;
}

/* Read the real player XYZ and current GO XYZ for each AutoOpen phase.
 * Reject invalid/missing positions and any target farther than melee range.
 * This check is private to AutoOpen: mining/herbalism retain their own ranges. */
static DWORD AutoOpenInMelee(BYTE*p,BYTE*obj,float*outDistSq)
{
    DWORD*desc,src=0u;
    float x,y,z,d2;
    if(outDistSq)*outDistSq=0.0f;
    if(!Ptr(p)||!Ptr(obj))return 0u;
    desc=*(DWORD**)(obj+OFF_OBJ_DESCRIPTOR_PTR);
    if(!GetGOPos(obj,desc,&x,&y,&z,&src))return 0u;
    d2=DistSq3(*(float*)(p+OFF_UNIT_X),*(float*)(p+OFF_UNIT_Y),*(float*)(p+OFF_UNIT_Z),x,y,z);
    if(outDistSq)*outDistSq=d2;
    return d2<=AUTOOPEN_MELEE_RANGE_SQ?1u:0u;
}

static void CaptureCopperDiag(BYTE*o,DWORD*desc,float px,float py,float pz,float x,float y,float z,DWORD src,float d2)
{
    BYTE*mv=0;g_diagEntry=1731u;g_diagObj=(DWORD)o;g_diagPosSource=src;g_diagX=x;g_diagY=y;g_diagZ=z;g_diagD2=d2;
    if(Ptr(desc)){g_diagDescX=*(float*)&desc[GAMEOBJECT_POS_X_INDEX];g_diagDescY=*(float*)&desc[GAMEOBJECT_POS_Y_INDEX];g_diagDescZ=*(float*)&desc[GAMEOBJECT_POS_Z_INDEX];}
    else g_diagDescX=g_diagDescY=g_diagDescZ=0.0f;
    mv=*(BYTE**)(o+OFF_OBJ_MOVEMENT_DATA);if(Ptr(mv)){g_diagMoveX=*(float*)(mv+OFF_OBJMOVE_POS_X);g_diagMoveY=*(float*)(mv+OFF_OBJMOVE_POS_Y);g_diagMoveZ=*(float*)(mv+OFF_OBJMOVE_POS_Z);}else g_diagMoveX=g_diagMoveY=g_diagMoveZ=0.0f;
    g_diagLegacyX=*(float*)(o+OFF_GO_LEGACY_X);g_diagLegacyY=*(float*)(o+OFF_GO_LEGACY_Y);g_diagLegacyZ=*(float*)(o+OFF_GO_LEGACY_Z);
    (void)px;(void)py;(void)pz;
}

/* Mining-first arbitration.  This is deliberately a lightweight Mining-only
 * scan separate from the full gather selector so that herbs/AutoOpen never
 * suppress Pick Pocket.  A short-lived cache is refreshed from the 15 ms
 * timer path; the hot ClientServices::Send hook only reads the cache. */
static BYTE* FindBestPriorityMiningNode(BYTE*p,DWORD*oe,DWORD*olo,DWORD*ohi,float*od2)
{
    BYTE*m=*(BYTE**)ADDR_OBJMGR_GLOBAL,*o,*best=0;DWORD i,entry,src=0,lo=0,hi=0;float px,py,pz,x,y,z,d2,bestd=GATHER_SCAN_RANGE_SQ+1.0f;DWORD*desc;
    if(oe)*oe=0u;if(olo)*olo=0u;if(ohi)*ohi=0u;if(od2)*od2=0.0f;
    if(!Ptr(m)||!Ptr(p))return 0;
    px=*(float*)(p+OFF_UNIT_X);py=*(float*)(p+OFF_UNIT_Y);pz=*(float*)(p+OFF_UNIT_Z);o=*(BYTE**)(m+OFF_OM_FIRST_OBJECT);
    for(i=0u;i<4095u&&Ptr(o);i++){
        BYTE*n=*(BYTE**)(o+OFF_OBJ_NEXT);desc=*(DWORD**)(o+OFF_OBJ_DESCRIPTOR_PTR);
        if(Ptr(desc)&&(desc[OBJECT_FIELD_TYPE_INDEX]&TYPEMASK_GAMEOBJECT)){
            entry=desc[OBJECT_FIELD_ENTRY_INDEX];
            if(IsMiningEntry(entry)&&!CombatVeinContains(entry,*(DWORD*)(o+OFF_OBJ_GUID_LOW),*(DWORD*)(o+OFF_OBJ_GUID_HIGH))&&GetGOPos(o,desc,&x,&y,&z,&src)){
                d2=DistSq3(px,py,pz,x,y,z);
                if(d2<=GATHER_SCAN_RANGE_SQ&&d2<bestd){best=o;bestd=d2;lo=*(DWORD*)(o+OFF_OBJ_GUID_LOW);hi=*(DWORD*)(o+OFF_OBJ_GUID_HIGH);if(oe)*oe=entry;if(olo)*olo=lo;if(ohi)*ohi=hi;}
            }
        }
        if(!Ptr(n)||n==o)break;o=n;
    }
    if(best&&od2)*od2=bestd;return best;
}

static void RefreshMiningPriority(BYTE*p,DWORD now)
{
    DWORD entry=0u,lo=0u,hi=0u;float d2=0.0f;BYTE*obj;
    if(!Ptr(p)||!g_gatherEnabled||g_mode!=MODE_OFF||!g_hasMining||GatherLootOpen()){
        g_miningPriorityValidUntil=0u;g_miningPriorityEntry=g_miningPriorityLo=g_miningPriorityHi=0u;g_miningPriorityD2=0.0f;return;
    }
    if((g_gatherActive||g_gatherLootWait)&&g_gatherKind==2u){
        g_miningPriorityEntry=g_gatherEntry;g_miningPriorityLo=g_gatherTargetLo;g_miningPriorityHi=g_gatherTargetHi;g_miningPriorityD2=g_gatherDistSq;g_miningPriorityValidUntil=now+MINING_PRIORITY_HOLD_MS;return;
    }
    if((LONG)(g_miningPriorityNextScan-now)>0)return;
    g_miningPriorityNextScan=now+MINING_PRIORITY_SCAN_MS;++g_miningPriorityScans;
    obj=FindBestPriorityMiningNode(p,&entry,&lo,&hi,&d2);
    if(obj){g_miningPriorityEntry=entry;g_miningPriorityLo=lo;g_miningPriorityHi=hi;g_miningPriorityD2=d2;g_miningPriorityValidUntil=now+MINING_PRIORITY_HOLD_MS;g_gatherNextScan=0u;}
    else{g_miningPriorityValidUntil=0u;g_miningPriorityEntry=g_miningPriorityLo=g_miningPriorityHi=0u;g_miningPriorityD2=0.0f;}
}

static DWORD MiningPriorityOwnsPP(DWORD now)
{
    return g_miningPriorityValidUntil&&((LONG)(g_miningPriorityValidUntil-now)>0)&&g_miningPriorityEntry ? 1u:0u;
}

static BYTE* FindBestGatherNode(BYTE*p,DWORD now,DWORD*oe,DWORD*olo,DWORD*ohi,DWORD*okind,float*od2)
{
    BYTE*m=*(BYTE**)ADDR_OBJMGR_GLOBAL,*o,*best=0;DWORD i,visible=0,nodes=0,profmatch=0,inrange=0,posfail=0,eligible=0,entry=0,kind=0,lo=0,hi=0,src=0,match=0,inCombat=0u,chestSeen=0u,chestEligible=0u,chestLastEntry=0u,chestReason=0u,chestPosSrc=0u;float px,py,pz,d2,bestd=GATHER_SCAN_RANGE_SQ+1.0f,x=0,y=0,z=0,copperBest=1000000000.0f;DWORD*desc;
    g_diagEntry=0u;
    g_chestScanSeen=0u;g_chestScanEligible=0u;g_chestScanLastEntry=0u;
    g_chestScanReason=0u;g_chestScanPosSrc=0u;
    if(!Ptr(m)||!Ptr(p))return 0;inCombat=Combat(p);px=*(float*)(p+OFF_UNIT_X);py=*(float*)(p+OFF_UNIT_Y);pz=*(float*)(p+OFF_UNIT_Z);o=*(BYTE**)(m+OFF_OM_FIRST_OBJECT);
    for(i=0u;i<4095u&&Ptr(o);i++){
        BYTE*n=*(BYTE**)(o+OFF_OBJ_NEXT);visible++;desc=*(DWORD**)(o+OFF_OBJ_DESCRIPTOR_PTR);
        if(Ptr(desc)&&(desc[OBJECT_FIELD_TYPE_INDEX]&TYPEMASK_GAMEOBJECT)){
            entry=desc[OBJECT_FIELD_ENTRY_INDEX];kind=IsHerbEntry(entry)?1u:(IsMiningEntry(entry)?2u:(IsAutoOpenEntry(entry)?3u:(ChestGroupBit(entry)?4u:0u)));
            if(kind==4u){
                ++chestSeen;chestLastEntry=entry;
                if(!g_chestEnabled)chestReason=2u;
                else if(!(g_chestGroupsMask&ChestGroupBit(entry)))chestReason=3u;
                else if(inCombat)chestReason=4u;
                else if(ChestLoSSkipped(*(DWORD*)(o+OFF_OBJ_GUID_LOW),*(DWORD*)(o+OFF_OBJ_GUID_HIGH),now))chestReason=10u;
                else if((g_chestAggroLo||g_chestAggroHi)&&
                        g_chestAggroLo==*(DWORD*)(o+OFF_OBJ_GUID_LOW)&&
                        g_chestAggroHi==*(DWORD*)(o+OFF_OBJ_GUID_HIGH))chestReason=9u;
                else if(g_chestSkipLo==*(DWORD*)(o+OFF_OBJ_GUID_LOW)&&
                        g_chestSkipHi==*(DWORD*)(o+OFF_OBJ_GUID_HIGH)&&
                        (g_chestSkipLo||g_chestSkipHi))chestReason=5u;
                else chestReason=0u;
            }
            if(kind==2u&&CombatVeinContains(entry,*(DWORD*)(o+OFF_OBJ_GUID_LOW),*(DWORD*)(o+OFF_OBJ_GUID_HIGH)))kind=0u;
            if(kind){
                nodes++;match=((kind==1u&&!inCombat&&g_gatherEnabled&&g_hasHerbalism)||(kind==2u&&g_gatherEnabled&&g_hasMining)||(kind==3u&&!inCombat&&g_autoOpenEnabled)||(kind==4u&&!inCombat&&g_chestEnabled&&(g_chestGroupsMask&ChestGroupBit(entry))&&!ChestLoSSkipped(*(DWORD*)(o+OFF_OBJ_GUID_LOW),*(DWORD*)(o+OFF_OBJ_GUID_HIGH),now)&&!(g_chestAggroLo==*(DWORD*)(o+OFF_OBJ_GUID_LOW)&&g_chestAggroHi==*(DWORD*)(o+OFF_OBJ_GUID_HIGH)&&(g_chestAggroLo||g_chestAggroHi))&&!(g_chestSkipLo==*(DWORD*)(o+OFF_OBJ_GUID_LOW)&&g_chestSkipHi==*(DWORD*)(o+OFF_OBJ_GUID_HIGH)&&(g_chestSkipLo||g_chestSkipHi))))?1u:0u;if(match)profmatch++;
                if((kind==4u)?GetChestPos(o,desc,px,py,pz,&x,&y,&z,&src):GetGOPos(o,desc,&x,&y,&z,&src)){
                    d2=DistSq3(px,py,pz,x,y,z);
                    if(kind==4u){
                        chestPosSrc=src;
                        if(match)chestReason=d2<=GATHER_SCAN_RANGE_SQ?1u:7u;
                    }
                    if(entry==1731u&&d2<copperBest){copperBest=d2;CaptureCopperDiag(o,desc,px,py,pz,x,y,z,src,d2);}
                    if(match&&d2<=((kind==3u)?AUTOOPEN_MELEE_RANGE_SQ:GATHER_SCAN_RANGE_SQ)){
                        inrange++;eligible++;if(kind==4u)++chestEligible;lo=*(DWORD*)(o+OFF_OBJ_GUID_LOW);hi=*(DWORD*)(o+OFF_OBJ_GUID_HIGH);
                        /* Never suppress a matching node because of previous attempts. */
                        if(d2<bestd){best=o;bestd=d2;*oe=entry;*olo=lo;*ohi=hi;*okind=kind;}
                    }
                }else if(match){posfail++;if(kind==4u)chestReason=6u;}
            }
        }
        if(!Ptr(n)||n==o)break;o=n;
    }
    g_chestScanSeen=chestSeen;g_chestScanEligible=chestEligible;g_chestScanLastEntry=chestLastEntry;
    g_chestScanReason=chestReason;g_chestScanPosSrc=chestPosSrc;
    g_gatherScanVisible=visible;g_gatherScanNodes=nodes;g_gatherScanProfMatch=profmatch;g_gatherScanInRange=inrange;g_gatherScanPosFail=posfail;g_gatherScanEligible=eligible;if(od2)*od2=best?bestd:0.0f;(void)now;return best;
}

static void GatherSendFake(BYTE*p,DWORD now)
{
    float x,y,z,o;SendMove_t sm=(SendMove_t)ADDR_SEND_MOVE;if(!Ptr(p)||LongPPActive()||LongPPInjecting()||(*(DWORD*)ADDR_CASTING_SPELLID)==SPELL_PICK_POCKET)return;x=*(float*)(p+OFF_UNIT_X);y=*(float*)(p+OFF_UNIT_Y);z=*(float*)(p+OFF_UNIT_Z);o=*(float*)(p+OFF_UNIT_O);g_injecting=1;*(float*)(p+OFF_UNIT_X)=g_gatherX;*(float*)(p+OFF_UNIT_Y)=g_gatherY;*(float*)(p+OFF_UNIT_Z)=g_gatherZ;sm(p,MSG_MOVE_HEARTBEAT);sm(p,MSG_MOVE_HEARTBEAT);g_hb+=2u;*(float*)(p+OFF_UNIT_X)=x;*(float*)(p+OFF_UNIT_Y)=y;*(float*)(p+OFF_UNIT_Z)=z;*(float*)(p+OFF_UNIT_O)=o;g_injecting=0;g_gatherLastHB=now;
}

/* World-frame RMB: use the same build-5875 native projection and game
 * window helper verified by the active PlayerESP lineage.  Do not click when
 * the box is off screen, another app is focused, or the native ABI differs. */
typedef struct W112OpenPoint { LONG x,y; } W112OpenPoint;
typedef struct W112OpenRect { LONG left,top,right,bottom; } W112OpenRect;
typedef BOOL (__thiscall *W112OpenProject)(DWORD,float*,float*);
typedef void (__fastcall *W112OpenDdc)(float*,float*,float,float);
typedef HWND (__fastcall *W112OpenGetWindow)(int);
__declspec(dllimport) HWND __stdcall GetForegroundWindow(void);
__declspec(dllimport) BOOL __stdcall GetClientRect(HWND,W112OpenRect*);
__declspec(dllimport) BOOL __stdcall ClientToScreen(HWND,W112OpenPoint*);
__declspec(dllimport) BOOL __stdcall GetCursorPos(W112OpenPoint*);
__declspec(dllimport) BOOL __stdcall SetCursorPos(int,int);
__declspec(dllimport) LONG __stdcall SendMessageA(HWND,UINT,DWORD,LONG);
static DWORD W112AutoOpenScreenRightClick(BYTE*obj)
{
    static const BYTE w2s[]={0x55u,0x8Bu,0xECu,0x83u,0xECu,0x24u};
    static const BYTE ddc[]={0x55u,0x8Bu,0xECu,0x85u,0xC9u,0x74u};
    W112OpenPoint prior,point;
    W112OpenRect rect;
    HWND window;
    DWORD i,frame,src=0u,packed;
    DWORD*desc;
    float xyz[3],raw[3]={0.0f,0.0f,0.0f},nx=-1.0f,ny=-1.0f;
    if(!Ptr(obj))return 0u;
    for(i=0u;i<sizeof(w2s);i++)if(((BYTE*)0x00483EE0u)[i]!=w2s[i])return 0u;
    for(i=0u;i<sizeof(ddc);i++)if(((BYTE*)0x0041ADE0u)[i]!=ddc[i])return 0u;
    window=((W112OpenGetWindow)0x00435C30u)(0);
    if(!window||GetForegroundWindow()!=window||!GetClientRect(window,&rect)||
       rect.right<=rect.left||rect.bottom<=rect.top)return 0u;
    frame=*(DWORD*)0x00B4B2BCu;
    if(!Ptr((void*)frame))return 0u;
    desc=*(DWORD**)(obj+OFF_OBJ_DESCRIPTOR_PTR);
    if(!GetGOPos(obj,desc,&xyz[0],&xyz[1],&xyz[2],&src))return 0u;
    xyz[2]+=0.5f;
    if(!((W112OpenProject)0x00483EE0u)(frame,xyz,raw))return 0u;
    ((W112OpenDdc)0x0041ADE0u)(&nx,&ny,raw[0],raw[1]);
    if(nx<0.02f||nx>0.98f||ny<0.02f||ny>0.98f)return 0u;
    point.x=(LONG)(nx*(float)(rect.right-rect.left));
    point.y=(LONG)((1.0f-ny)*(float)(rect.bottom-rect.top));
    packed=(DWORD)(WORD)point.x|((DWORD)(WORD)point.y<<16);
    if(!GetCursorPos(&prior)||!ClientToScreen(window,&point))return 0u;
    if(!SetCursorPos(point.x,point.y))return 0u;
    SendMessageA(window,0x0200u,0u,(LONG)packed);
    SendMessageA(window,0x0204u,0x0002u,(LONG)packed);
    SendMessageA(window,0x0205u,0u,(LONG)packed);
    SetCursorPos(prior.x,prior.y);
    return 1u;
}
static void GatherClickNative(BYTE*p,BYTE*obj,DWORD now)
{
    DWORD sent;
    if(!Ptr(p)||!Ptr(obj)||LongPPActive()||LongPPInjecting()||
       (*(DWORD*)ADDR_CASTING_SPELLID)==SPELL_PICK_POCKET)return;
    if(g_gatherKind==3u){
        if(!AutoOpenInMelee(p,obj,&g_gatherDistSq))return;
        sent=W112AutoOpenScreenRightClick(obj);
        ++g_autoOpenClickCount;g_autoOpenLastClickAt=now;
        if(sent)++g_gatherClicks;
        GatherFileLog(sent?"AUTOOPEN_SCREEN_RMB_SENT":"AUTOOPEN_SCREEN_RMB_SKIPPED",
                      now,g_gatherEntry,g_gatherTargetLo,g_gatherTargetHi,
                      g_gatherDistSq,g_autoOpenClickCount,g_gatherKind);
        return;
    }
    ((RightClickObject_t)ADDR_ONRIGHTCLICK_OBJECT)(obj,0);
    if(g_gatherKind==4u){++g_chestAttemptCount;g_chestRetryAt=now+CHEST_RETRY_MS;}
    ++g_gatherClicks;
    GatherFileLog("NEAR_NATIVE_CLICK",now,g_gatherEntry,g_gatherTargetLo,
                  g_gatherTargetHi,g_gatherDistSq,g_gatherAttempts,g_gatherKind);
}

static float Mining3DWorldZ(DWORD group)
{
    switch(group){
        case 1u:return 8.0f;
        case 2u:return -8.0f;
        case 3u:return 20.0f;
        case 4u:return -20.0f;
        case 5u:return 35.0f;
        case 6u:return -35.0f;
        default:return 0.0f;
    }
}

static void Mining3DSelectOffset(DWORD idx)
{
    DWORD group=idx>>3,variant=idx&7u;
    g_mining3DDx=g_mining3DDy=g_mining3DDz=0.0f;
    g_miningServerDx=g_miningServerDy=g_miningServerDz=0.0f;

    /* Server approach points stay very close to the real node.  idx%8==0 is
       deliberately EXACT node XYZ: server range becomes zero and the LOS ray
       has no intervening geometry. */
    if(variant==1u)g_miningServerDx= MINING_SERVER_XY_STEP;
    else if(variant==2u)g_miningServerDx=-MINING_SERVER_XY_STEP;
    else if(variant==3u)g_miningServerDy= MINING_SERVER_XY_STEP;
    else if(variant==4u)g_miningServerDy=-MINING_SERVER_XY_STEP;
    else if(variant==5u)g_miningServerDz= MINING_SERVER_Z_STEP;
    else if(variant==6u)g_miningServerDz=-MINING_SERVER_Z_STEP;
    else if(variant==7u){g_miningServerDx=0.85f;g_miningServerDy=0.85f;}

    /* Repeat all eight server approach points through several translated local
       worlds.  Static client geometry moves relative to the temporary ray, but
       the player->node relative vector remains the same. */
    g_mining3DDz=Mining3DWorldZ(group);
    if(group==1u||group==4u)g_mining3DDx= MINING_3D_XY_SHIFT;
    else if(group==2u||group==5u)g_mining3DDx=-MINING_3D_XY_SHIFT;
    else if(group==3u)g_mining3DDy= MINING_3D_XY_SHIFT;
    else if(group==6u)g_mining3DDy=-MINING_3D_XY_SHIFT;
}

static void GatherClickMining3D(BYTE*p,BYTE*obj,DWORD now)
{
    float px,py,pz,po,dx,dy,dz;
    DWORD*desc=0;BYTE*mv=0;DWORD hd=0u,hm=0u,hl=0u;
    float d0x=0,d0y=0,d0z=0,m0x=0,m0y=0,m0z=0,l0x=0,l0y=0,l0z=0;
    if(!Ptr(p)||!Ptr(obj))return;
    dx=g_mining3DDx;dy=g_mining3DDy;dz=g_mining3DDz;
    px=*(float*)(p+OFF_UNIT_X);py=*(float*)(p+OFF_UNIT_Y);pz=*(float*)(p+OFF_UNIT_Z);po=*(float*)(p+OFF_UNIT_O);

    /* Shift every known local GO position source together with the temporary
       local player position.  Relative player->node range is unchanged, while
       the client LOS ray is translated through world geometry. */
    desc=*(DWORD**)(obj+OFF_OBJ_DESCRIPTOR_PTR);
    if(Ptr(desc)){
        d0x=*(float*)&desc[GAMEOBJECT_POS_X_INDEX];d0y=*(float*)&desc[GAMEOBJECT_POS_Y_INDEX];d0z=*(float*)&desc[GAMEOBJECT_POS_Z_INDEX];
        if(ValidWorldPos(d0x,d0y,d0z)){*(float*)&desc[GAMEOBJECT_POS_X_INDEX]=d0x+dx;*(float*)&desc[GAMEOBJECT_POS_Y_INDEX]=d0y+dy;*(float*)&desc[GAMEOBJECT_POS_Z_INDEX]=d0z+dz;hd=1u;}
    }
    mv=*(BYTE**)(obj+OFF_OBJ_MOVEMENT_DATA);
    if(Ptr(mv)){
        m0x=*(float*)(mv+OFF_OBJMOVE_POS_X);m0y=*(float*)(mv+OFF_OBJMOVE_POS_Y);m0z=*(float*)(mv+OFF_OBJMOVE_POS_Z);
        if(ValidWorldPos(m0x,m0y,m0z)){*(float*)(mv+OFF_OBJMOVE_POS_X)=m0x+dx;*(float*)(mv+OFF_OBJMOVE_POS_Y)=m0y+dy;*(float*)(mv+OFF_OBJMOVE_POS_Z)=m0z+dz;hm=1u;}
    }
    l0x=*(float*)(obj+OFF_GO_LEGACY_X);l0y=*(float*)(obj+OFF_GO_LEGACY_Y);l0z=*(float*)(obj+OFF_GO_LEGACY_Z);
    if(ValidWorldPos(l0x,l0y,l0z)){*(float*)(obj+OFF_GO_LEGACY_X)=l0x+dx;*(float*)(obj+OFF_GO_LEGACY_Y)=l0y+dy;*(float*)(obj+OFF_GO_LEGACY_Z)=l0z+dz;hl=1u;}

    *(float*)(p+OFF_UNIT_X)=g_gatherX+dx;*(float*)(p+OFF_UNIT_Y)=g_gatherY+dy;*(float*)(p+OFF_UNIT_Z)=g_gatherZ+dz;
    ((RightClickObject_t)ADDR_ONRIGHTCLICK_OBJECT)(obj,0);
    *(float*)(p+OFF_UNIT_X)=px;*(float*)(p+OFF_UNIT_Y)=py;*(float*)(p+OFF_UNIT_Z)=pz;*(float*)(p+OFF_UNIT_O)=po;
    if(hd){*(float*)&desc[GAMEOBJECT_POS_X_INDEX]=d0x;*(float*)&desc[GAMEOBJECT_POS_Y_INDEX]=d0y;*(float*)&desc[GAMEOBJECT_POS_Z_INDEX]=d0z;}
    if(hm){*(float*)(mv+OFF_OBJMOVE_POS_X)=m0x;*(float*)(mv+OFF_OBJMOVE_POS_Y)=m0y;*(float*)(mv+OFF_OBJMOVE_POS_Z)=m0z;}
    if(hl){*(float*)(obj+OFF_GO_LEGACY_X)=l0x;*(float*)(obj+OFF_GO_LEGACY_Y)=l0y;*(float*)(obj+OFF_GO_LEGACY_Z)=l0z;}
    ++g_gatherClicks;++g_mining3DRetries;
    GatherFileLog(g_gatherKind==4u?"AUTOCHEST_MINING3D_CLICK":"MINING_HARDLOS_CLICK",now,g_gatherEntry,g_gatherTargetLo,g_gatherTargetHi,g_gatherDistSq,g_gatherAttempts,g_mining3DRetryIndex);
}

static void GatherClickSpoof(BYTE*p,BYTE*obj,DWORD now)
{
    float x,y,z,o;if(!Ptr(p)||!Ptr(obj)||LongPPActive()||LongPPInjecting()||(*(DWORD*)ADDR_CASTING_SPELLID)==SPELL_PICK_POCKET)return;
    if(g_gatherKind==4u){++g_chestAttemptCount;g_chestRetryAt=now+CHEST_RETRY_MS;}
    if((g_gatherKind==2u||g_gatherKind==4u)&&g_mining3DRetryActive){GatherClickMining3D(p,obj,now);g_mining3DRetryActive=0u;return;}
    x=*(float*)(p+OFF_UNIT_X);y=*(float*)(p+OFF_UNIT_Y);z=*(float*)(p+OFF_UNIT_Z);o=*(float*)(p+OFF_UNIT_O);*(float*)(p+OFF_UNIT_X)=g_gatherX;*(float*)(p+OFF_UNIT_Y)=g_gatherY;*(float*)(p+OFF_UNIT_Z)=g_gatherZ;((RightClickObject_t)ADDR_ONRIGHTCLICK_OBJECT)(obj,0);*(float*)(p+OFF_UNIT_X)=x;*(float*)(p+OFF_UNIT_Y)=y;*(float*)(p+OFF_UNIT_Z)=z;*(float*)(p+OFF_UNIT_O)=o;++g_gatherClicks;GatherFileLog("FAR_SPOOF_CLICK",now,g_gatherEntry,g_gatherTargetLo,g_gatherTargetHi,g_gatherDistSq,g_gatherAttempts,g_gatherKind);
}

static DWORD Mining3DQueueRetry(BYTE*p,DWORD now)
{
    if((g_gatherKind!=2u&&g_gatherKind!=4u)||g_gatherSawCast||g_mining3DRetryIndex>=(g_gatherKind==4u?CHEST_3D_RETRY_COUNT:MINING_3D_RETRY_COUNT))return 0u;
    Mining3DSelectOffset(g_mining3DRetryIndex);
    /* TEST: keep server XYZ consistently below ore during HARDLOS retry.
     * Shift only local LOS geometry as before; do not shift the server point
     * back up to the ore on retry. */
    if(g_gatherKind==2u&&g_miningBelowNodeEnabled){
        g_miningServerDx=0.0f;g_miningServerDy=0.0f;
        g_miningServerDz=-MINING_BELOW_NODE_Z_OFFSET;
    }
    /* Chest: after trying the deepest Z first, use near-node LOS vectors,
     * never reset the server back underground to -4 yd on every retry. */
    /* V62: server sees a different near-node endpoint on every retry too. */
    g_gatherX=g_gatherNodeX+g_miningServerDx;
    g_gatherY=g_gatherNodeY+g_miningServerDy;
    g_gatherZ=g_gatherNodeZ+g_miningServerDz;
    ++g_mining3DRetryIndex;g_mining3DRetryActive=1u;g_mining3DRetryAt=0u;
    g_gatherSpoof=1u;GatherSendFake(p,now);g_gatherClickPending=1u;g_gatherClickAt=now+MINING_3D_RETRY_SETTLE_MS;
    GatherFileLog(g_gatherKind==4u?"AUTOCHEST_MINING3D_POINT":"MINING_HARDLOS_POINT",now,g_gatherEntry,g_gatherTargetLo,g_gatherTargetHi,g_gatherDistSq,g_gatherAttempts,g_mining3DRetryIndex);
    return 1u;
}

static void GatherStop(BYTE*p,DWORD now,const char*reason,DWORD sendReal,DWORD blacklist)
{
    DWORD lo=g_gatherTargetLo,hi=g_gatherTargetHi,entry=g_gatherEntry,attempts=g_gatherAttempts;float d2=g_gatherDistSq;(void)blacklist;g_gatherActive=0u;g_gatherLootWait=0u;g_gatherLootWaitUntil=0u;g_gatherLootTargetGoneLogged=0u;g_gatherLootStart=0u;g_gatherLootSeenOpen=0u;g_gatherLootOpenLogged=0u;g_gatherSawCast=0u;g_gatherCastSeenLogged=0u;g_gatherStealthPending=0u;g_mining3DRetryIndex=0u;g_mining3DRetryAt=0u;g_mining3DRetryActive=0u;g_mining3DDx=g_mining3DDy=g_mining3DDz=0.0f;g_miningServerDx=g_miningServerDy=g_miningServerDz=0.0f;g_gatherNodeX=g_gatherNodeY=g_gatherNodeZ=0.0f;g_autoOpenPickPrimed=0u;g_gatherStart=0u;g_gatherLastHB=0u;g_gatherSpoof=0u;g_miningEarlyRestored=0u;g_miningEarlyRestoreUsed=0u;g_miningEarlyRestoreAt=0u;g_gatherClickPending=0u;g_gatherClickAt=0u;g_gatherPosSource=0u;g_gatherTargetLo=g_gatherTargetHi=g_gatherEntry=g_gatherKind=0u;g_gatherX=g_gatherY=g_gatherZ=g_gatherDistSq=0.0f;g_gatherNextScan=now+GATHER_RESCAN_DELAY_MS;if(sendReal&&Ptr(p))SendReal(p);GatherFileLog(reason,now,entry,lo,hi,d2,attempts,blacklist);
}

static void CombatVeinObserve(BYTE*p,DWORD now)
{
    DWORD combat,entry,lo,hi;
    if(!Ptr(p)){g_combatWatch=0u;g_combatVeinLastCombat=0u;return;}
    combat=Combat(p);
    if(g_combatWatch&&(DWORD)(now-g_combatWatchStart)<=COMBAT_VEIN_WINDOW_MS&&
       combat&&!g_combatVeinLastCombat&&g_gatherClicks>g_combatWatchClicks){
        entry=g_combatWatchEntry;lo=g_combatWatchLo;hi=g_combatWatchHi;
        if(CombatVeinAdd(entry,lo,hi))
            GatherFileLog("COMBAT_VEIN_BLACKLIST_ADD",now,entry,lo,hi,g_gatherDistSq,g_gatherAttempts,g_combatVeinCount);
        g_combatWatch=0u;
        g_miningPriorityValidUntil=0u;g_miningPriorityEntry=g_miningPriorityLo=g_miningPriorityHi=0u;
        g_miningPriorityNextScan=0u;g_gatherNextScan=now+GATHER_RESCAN_DELAY_MS;
        if((g_gatherActive||g_gatherLootWait)&&g_gatherKind==2u&&
           g_gatherEntry==entry&&g_gatherTargetLo==lo&&g_gatherTargetHi==hi)
            GatherStop(p,now,"COMBAT_VEIN_ABORT",1u,0u);
    }
    if(g_combatWatch&&(DWORD)(now-g_combatWatchStart)>COMBAT_VEIN_WINDOW_MS)g_combatWatch=0u;
    g_combatVeinLastCombat=combat;
}

static void GatherBegin(BYTE*p,BYTE*obj,DWORD now,DWORD entry,DWORD lo,DWORD hi,DWORD kind,float d2)
{
    DWORD*desc,src=0;float nx=0,ny=0,nz=0,px,py,pz,dx,dy;
    if(!Ptr(p)||!Ptr(obj))return;
    px=*(float*)(p+OFF_UNIT_X);py=*(float*)(p+OFF_UNIT_Y);pz=*(float*)(p+OFF_UNIT_Z);
    desc=*(DWORD**)(obj+OFF_OBJ_DESCRIPTOR_PTR);
    if(!(kind==4u?GetChestPos(obj,desc,px,py,pz,&nx,&ny,&nz,&src):GetGOPos(obj,desc,&nx,&ny,&nz,&src))){GatherFileLog("POS_FAIL_RETRY",now,entry,lo,hi,d2,g_gatherAttempts,kind);g_gatherNextScan=now+GATHER_RESCAN_DELAY_MS;return;}
    /* Recheck when starting: the player may have moved since selection. */
    if(kind==3u&&!AutoOpenInMelee(p,obj,&d2))return;
    g_combatWatch=0u;
    if(kind==2u&&g_combatVeinEnabled&&!Combat(p)){
        g_combatWatchEntry=entry;g_combatWatchLo=lo;g_combatWatchHi=hi;
        g_combatWatchStart=now;g_combatWatchClicks=g_gatherClicks;g_combatWatch=1u;
    }
    g_gatherActive=1u;g_gatherLootWait=0u;g_gatherLootWaitUntil=0u;g_gatherLootTargetGoneLogged=0u;g_gatherLootStart=0u;g_gatherLootSeenOpen=0u;g_gatherLootOpenLogged=0u;g_gatherSawCast=0u;g_gatherCastSeenLogged=0u;g_mining3DRetryIndex=0u;g_mining3DRetryAt=0u;g_mining3DRetryActive=0u;g_mining3DDx=g_mining3DDy=g_mining3DDz=0.0f;g_miningServerDx=g_miningServerDy=g_miningServerDz=0.0f;g_autoOpenPickPrimed=0u;g_autoOpenClickCount=0u;g_autoOpenLastClickAt=0u;g_gatherTargetLo=lo;g_gatherTargetHi=hi;g_gatherEntry=entry;g_gatherKind=kind;g_gatherStart=now;g_gatherLastHB=0u;g_gatherDistSq=d2;g_gatherPosSource=src;g_miningEarlyRestored=0u;g_miningEarlyRestoreUsed=0u;g_miningEarlyRestoreAt=0u;
    ChatAttempt(kind,entry,lo,hi,now);
    px=*(float*)(p+OFF_UNIT_X);py=*(float*)(p+OFF_UNIT_Y);dx=px-nx;dy=py-ny;
    g_gatherNodeX=nx;g_gatherNodeY=ny;g_gatherNodeZ=nz;g_gatherX=nx;g_gatherY=ny;g_gatherZ=nz;
    g_chestAttemptCount=0u;g_chestLastReason=kind==4u?1u:0u;
    g_chestStep=(kind==4u&&!g_chestLowestZ)?CHEST_MAX_STEPS:0u;
    g_chestRetryAt=kind==4u?now+CHEST_RETRY_MS:0u;
    if(AbsF(dx)>=AbsF(dy))g_gatherX=nx+((dx>=0.0f)?GATHER_NODE_OFFSET:-GATHER_NODE_OFFSET);else g_gatherY=ny+((dy>=0.0f)?GATHER_NODE_OFFSET:-GATHER_NODE_OFFSET);
    if(kind==4u){
        g_gatherX=nx;g_gatherY=ny;g_gatherZ=nz-(g_chestLowestZ?CHEST_DEPTH_YD:0.0f);
        GatherFileLog("AUTOCHEST_MINING_NEAR_BEGIN",now,entry,lo,hi,d2,0u,g_chestLowestZ?4u:0u);
    }else if(kind==2u&&g_miningBelowNodeEnabled&&d2>GATHER_NEAR_RANGE_SQ){
        g_gatherX=nx;g_gatherY=ny;g_gatherZ=nz-MINING_BELOW_NODE_Z_OFFSET;
        GatherFileLog("MINING_BELOW_NODE_BEGIN",now,entry,lo,hi,d2,g_gatherAttempts,40u);
    }
    if(kind==3u||(kind!=4u&&d2<=GATHER_NEAR_RANGE_SQ)){
        g_gatherSpoof=0u;GatherFileLog(kind==3u?"AUTOOPEN_TARGET_BEGIN_NEAR":"TARGET_BEGIN_NEAR",now,entry,lo,hi,d2,g_gatherAttempts,kind);
        if(GatherRequestStealthBreak(p,now)){g_gatherClickPending=1u;g_gatherClickAt=now+GATHER_STEALTH_BREAK_DELAY_MS;}
        else if(kind==3u){AutoOpenPrimePickLock(p,now);g_autoOpenPickPrimed=1u;g_gatherClickPending=1u;g_gatherClickAt=now+AUTOOPEN_PICKLOCK_SETTLE_MS;}
        else{g_gatherClickPending=0u;GatherClickNative(p,obj,now);if(kind==2u)g_mining3DRetryAt=now+MINING_3D_RETRY_FIRST_MS;}
    }else{
        g_gatherSpoof=1u;g_gatherClickPending=1u;g_gatherClickAt=now+GATHER_FAR_CLICK_DELAY_MS;GatherFileLog(kind==3u?"AUTOOPEN_TARGET_BEGIN_FAR":"TARGET_BEGIN_FAR",now,entry,lo,hi,d2,g_gatherAttempts,kind);GatherSendFake(p,now);
        if(GatherRequestStealthBreak(p,now))g_gatherClickAt=now+GATHER_STEALTH_BREAK_DELAY_MS;
        else if(kind==3u){AutoOpenPrimePickLock(p,now);g_autoOpenPickPrimed=1u;g_gatherClickAt=now+AUTOOPEN_PICKLOCK_SETTLE_MS;}
    }
}

static DWORD GatherCastMatches(DWORD kind,DWORD castId)
{
    /* 1.12 profession ranks have distinct spell IDs.  Some clients/actions
       expose the base ID while others expose the learned rank, so accept the
       complete vanilla rank family rather than treating a valid gather as a
       foreign cast. */
    if(kind==2u)return castId==2575u||castId==2576u||castId==3564u||castId==10248u;
    if(kind==1u)return castId==2366u||castId==2368u||castId==3570u||castId==11993u;
    if(kind==3u)return castId==SPELL_PICK_LOCK;
    if(kind==4u)return castId==3365u; /* Vanilla Opening cast; never steal an unrelated cast. */
    return 0u;
}

static void GatherBeginManualLootWait(BYTE*p,DWORD now,const char*reason)
{
    /* Preserve the existing near-node loot protocol. Only the mining cast may
     * run at real XYZ; restore spoof before handing off to the loot gate. */
    if(g_gatherKind==2u&&g_miningEarlyRestored){
        g_miningEarlyRestored=0u;
        g_miningEarlyRestoreAt=0u;
        g_gatherSpoof=1u;
        GatherSendFake(p,now);
        GatherFileLog("MINING_EARLY_REARM_LOOT",now,g_gatherEntry,g_gatherTargetLo,g_gatherTargetHi,g_gatherDistSq,g_gatherAttempts,0u);
    }
    g_gatherActive=0u;
    g_gatherClickPending=0u;
    g_gatherLootWait=1u;
    g_gatherLootStart=now;
    g_gatherLootWaitUntil=now+GATHER_LOOT_OPEN_GRACE_MS;
    g_gatherLootSeenOpen=GatherLootOpen();
    g_gatherLootOpenLogged=g_gatherLootSeenOpen;
    if(g_gatherKind==4u&&g_gatherLootSeenOpen&&g_chestAutoLoot)DebugChat(g_chestLootScript);
    g_gatherLootTargetGoneLogged=0u;
    g_gatherNextScan=now;
    GatherFileLog(reason,now,g_gatherEntry,g_gatherTargetLo,g_gatherTargetHi,g_gatherDistSq,g_gatherAttempts,GATHER_LOOT_OPEN_GRACE_MS);
    if(g_gatherLootSeenOpen)GatherFileLog("MANUALLOOT_OPEN",now,g_gatherEntry,g_gatherTargetLo,g_gatherTargetHi,g_gatherDistSq,g_gatherAttempts,g_gatherKind);
}

static void GatherFinishManualLoot(BYTE*p,DWORD now,const char*reason)
{
    if(g_gatherKind==4u&&g_gatherLootSeenOpen){
        g_chestLastReason=6u;
        /* Mark as completed only after a real loot window was observed.
         * A failed click is immediately eligible again; no chest cooldown. */
        g_chestSkipLo=g_gatherTargetLo;g_chestSkipHi=g_gatherTargetHi;
    }
    g_gatherLootWait=0u;
    g_gatherLootWaitUntil=0u;
    g_gatherLootStart=0u;
    g_gatherLootSeenOpen=0u;
    g_gatherLootOpenLogged=0u;
    g_gatherLootTargetGoneLogged=0u;
    g_gatherSawCast=0u;
    g_gatherCastSeenLogged=0u;
    g_autoOpenPickPrimed=0u;
    if(g_gatherSpoof){g_gatherSpoof=0u;SendReal(p);}
    g_gatherNextScan=now+GATHER_RESCAN_DELAY_MS;
    GatherFileLog(reason,now,g_gatherEntry,g_gatherTargetLo,g_gatherTargetHi,g_gatherDistSq,g_gatherAttempts,g_gatherKind);
}

static void QueuePPLog(DWORD ev,DWORD now,DWORD entry,DWORD lo,DWORD hi,float d2,DWORD attempts)
{
    /* Single-threaded client path in practice; latest event wins if two PP packets
       land inside one 15 ms timer window. Counters remain exact. */
    g_ppPendingEntry=entry;g_ppPendingLo=lo;g_ppPendingHi=hi;g_ppPendingD2=d2;g_ppPendingAttempts=attempts;g_ppPendingTick=now;g_ppPendingEvent=ev;
}

static void FlushPendingPPLog(void)
{
    DWORD ev=g_ppPendingEvent,tm,entry,lo,hi,attempts,now;float d2;
    if(!ev)return;
    now=GT()?GT()():0u;
    /* Keep file I/O completely outside the PP protected interval.  This is only
       diagnostics; counters/state are updated synchronously in the hot path. */
    if(LongPPActive()||LongPPInjecting()||(*(DWORD*)ADDR_CASTING_SPELLID)==SPELL_PICK_POCKET||((LONG)(g_ppQuietUntil-now)>0))return;
    tm=g_ppPendingTick;entry=g_ppPendingEntry;lo=g_ppPendingLo;hi=g_ppPendingHi;attempts=g_ppPendingAttempts;d2=g_ppPendingD2;
    g_ppPendingEvent=0u;
    if(ev==2u)GatherFileLog("PP_TX_PREEMPT",tm,entry,lo,hi,d2,attempts,0u);
}

static void GatherClearForPPFast(DWORD now,DWORD logEvent)
{
    DWORD lo=g_gatherTargetLo,hi=g_gatherTargetHi,entry=g_gatherEntry,attempts=g_gatherAttempts;float d2=g_gatherDistSq;
    g_gatherActive=0u;g_gatherLootWait=0u;g_gatherLootWaitUntil=0u;g_gatherLootTargetGoneLogged=0u;
    g_gatherLootStart=0u;g_gatherLootSeenOpen=0u;g_gatherLootOpenLogged=0u;g_gatherSawCast=0u;g_gatherCastSeenLogged=0u;g_gatherStealthPending=0u;g_autoOpenPickPrimed=0u;
    g_gatherStart=0u;g_gatherLastHB=0u;g_gatherSpoof=0u;g_miningEarlyRestored=0u;g_miningEarlyRestoreUsed=0u;g_miningEarlyRestoreAt=0u;g_gatherClickPending=0u;g_gatherClickAt=0u;g_gatherPosSource=0u;g_mining3DRetryIndex=0u;g_mining3DRetryAt=0u;g_mining3DRetryActive=0u;g_mining3DDx=g_mining3DDy=g_mining3DDz=0.0f;
    g_gatherTargetLo=g_gatherTargetHi=g_gatherEntry=g_gatherKind=0u;g_gatherX=g_gatherY=g_gatherZ=g_gatherDistSq=0.0f;
    g_gatherNextScan=now+PP_POST_CAST_QUIET_MS;
    if(logEvent)QueuePPLog(logEvent,now,entry,lo,hi,d2,attempts);
}

static void GatherClearForPPLogged(BYTE*p,DWORD now,const char*reason)
{
    DWORD lo=g_gatherTargetLo,hi=g_gatherTargetHi,entry=g_gatherEntry,attempts=g_gatherAttempts;float d2=g_gatherDistSq;
    (void)p;GatherClearForPPFast(now,0u);GatherFileLog(reason,now,entry,lo,hi,d2,attempts,0u);
}

static void PPPreemptOutgoing(DWORD now)
{
    DWORD hadState=(g_gatherActive||g_gatherLootWait||g_gatherSpoof)?1u:0u;
    DWORD hadSpoof=g_gatherSpoof?1u:0u;BYTE*p=0;
    g_ppQuietUntil=now+PP_POST_CAST_QUIET_MS;
    g_foreignLootLogged=0u;
    if(hadState){
        ++g_ppTxPreempts;
        /* Clear BEFORE any real heartbeat so Gather_ProcessMovementPacket cannot
           rewrite the reset packet back to the node. */
        GatherClearForPPFast(now,2u);
        if(hadSpoof&&!LongPPActive()&&!LongPPInjecting()){
            p=LocalPlayer();
            if(Ptr(p)&&!g_ppSendRecursion){g_ppSendRecursion=1u;g_ppResetInProgress=1u;SendReal(p);SendReal(p);g_ppResetInProgress=0u;g_ppSendRecursion=0u;++g_ppRealResets;}
        }
    }else{
        /* Critical fast path: ordinary PP while gather is idle must not alter
           movement or perform file I/O/object scans. */
        ++g_ppFastNoTouch;
    }
}

#if defined(W112_PP_DETECTION_GUARD)
static DWORD W112_PPGuard_Allow(DWORD lo,DWORD hi,DWORD now);
#endif
static void __cdecl PPArbiter_BeforeSend(DataStore5875* packet,DWORD returnAddr)
{
    BYTE*raw;DWORD op,spell,now,isAutoSource,tlo=0u,thi=0u,variant=0u;
    g_ppForward=1u;
    if(g_ppSendRecursion||!packet||packet->size<8u||packet->size>MAX_PACKET_SIZE)return;
    raw=PacketRawBase(packet);if(!raw)return;op=*(DWORD*)raw;if(op!=0x12Eu)return;spell=*(DWORD*)(raw+4u);if(spell!=SPELL_PICK_POCKET)return;
    now=GT()?GT()():0u;
    /* WoW.exe lives below 0x01000000 in build 5875. AutoLootPP is a DLL and
       reaches ClientServices::Send from its relocated module address. */
    isAutoSource=(returnAddr>=0x01000000u&&returnAddr<=0x7FFDFFFFu)?1u:0u;
    PPDecodeTargetGuid(packet,&tlo,&thi);
#if defined(W112_PP_DETECTION_GUARD)
    if(isAutoSource&&!W112_PPGuard_Allow(tlo,thi,now)){
        g_ppForward=0u;++g_autoPPBlocked;g_ppQuietUntil=0u;return;
    }
#endif
    if(isAutoSource&&CurrentTargetIsPlayer()){g_ppForward=0u;++g_autoPPBlocked;++g_autoPPTargetPlayerBlocks;g_ppQuietUntil=0u;return;}
    if(!g_autoPPEnabled&&isAutoSource){g_ppForward=0u;++g_autoPPBlocked;g_ppQuietUntil=0u;return;}
    /* One auto PP transaction at a time: failure callbacks have no GUID in 5875.
       Serialization makes 0x72 -> GUID mapping deterministic even under scanner pressure. */
    if(isAutoSource&&g_ppFailPendingAuto){g_ppForward=0u;++g_autoPPBlocked;++g_ppPendingSerialBlocks;g_ppQuietUntil=0u;return;}
    if(isAutoSource&&g_ppHardRetryActive&&g_ppHardRetryScheduled&&!g_ppHardRetryInjecting){g_ppForward=0u;++g_autoPPBlocked;++g_ppPendingSerialBlocks;g_ppQuietUntil=0u;return;}
    if(isAutoSource&&(tlo|thi)&&PPBlackFind(tlo,thi)){g_ppForward=0u;++g_autoPPBlocked;++g_ppBlackBlocks;g_ppQuietUntil=0u;return;}
    if(!isAutoSource)++g_autoPPManualPass;
    if(MiningPriorityOwnsPP(now)){g_ppForward=0u;++g_miningPriorityBlocks;g_ppQuietUntil=0u;g_gatherNextScan=0u;return;}
    if(isAutoSource&&(tlo|thi)&&Ptr((void*)g_longPPReasonPtr)){
        /* Exact failure ownership is handled by the chained 5875 spell-fail callsite.
           The pending GUID is set before LongPP sees this cast, so 0x72 is blacklisted synchronously. */
        g_ppFailPendingAuto=1u;g_ppFailPendingSawActive=0u;g_ppFailPendingLo=tlo;g_ppFailPendingHi=thi;g_ppFailPendingUntil=now+PP_FAIL_PENDING_MS;
        if(!g_ppHardRetryInjecting)PPHardRetryCapture(packet,tlo,thi);
        PPHardSelect(tlo,thi,&variant);
    }
    PPPreemptOutgoing(now);
}

static void GatherTick(BYTE*p,DWORD now)
{
    DWORD hold,entry=0,lo=0,hi=0,kind=0,castId=0,lootOpen=0,lootAge=0,ppActive=0,ppInjecting=0;float d2=0.0f;BYTE*obj;
    if(!Ptr(p))return;
    castId=*(DWORD*)ADDR_CASTING_SPELLID;ppActive=LongPPActive();ppInjecting=LongPPInjecting();
    RefreshProfessions(p,now);
    RefreshMiningPriority(p,now);

    /* Hard arbitration: LongPP owns movement from the instant it raises its
     * internal active flag until it restores.  Never send/rewrite gather
     * movement in that window.  The outgoing send hook handles the earlier
     * normal-range PP race before LongPP can decide not to spoof. */
    if(ppActive||ppInjecting||castId==SPELL_PICK_POCKET){
        /* If a Mining candidate owns automation, do not destroy an already
         * started Mining transaction.  New PP packets are blocked by the send
         * arbiter; an older PP already in flight is merely allowed to clear. */
        if(MiningPriorityOwnsPP(now)){
            g_ppQuietUntil=0u;
            if(ppInjecting)++g_ppInjectYields;
            return;
        }
        g_ppQuietUntil=now+PP_POST_CAST_QUIET_MS;
        if(g_gatherActive||g_gatherLootWait){
            ++g_ppPriorityAborts;++g_ppStateYields;if(ppInjecting)++g_ppInjectYields;
            /* Do not perform synchronous file I/O while PP owns the timeline. */
            GatherClearForPPFast(now,2u);
        }
        return;
    }
    if((LONG)(g_ppQuietUntil-now)>0)return;
    if(!g_ppChainOk){if(g_gatherActive||g_gatherLootWait)GatherClearForPPLogged(p,now,"PPCHAIN_BLOCK_ABORT");return;}

    if(!g_gatherEnabled&&!g_autoOpenEnabled&&!g_chestEnabled){if(g_gatherActive||g_gatherLootWait)GatherStop(p,now,"ALL_AUTO_DISABLED_ABORT",1u,0u);return;}
    if(!g_gatherEnabled&&g_gatherActive&&g_gatherKind!=3u&&g_gatherKind!=4u){GatherStop(p,now,"GATHER_DISABLED_ABORT",1u,0u);return;}
    if(!g_chestEnabled&&g_gatherActive&&g_gatherKind==4u){GatherStop(p,now,"AUTOCHEST_DISABLED_ABORT",1u,0u);return;}
    if(!g_autoOpenEnabled&&g_gatherActive&&g_gatherKind==3u){GatherStop(p,now,"AUTOOPEN_DISABLED_ABORT",1u,0u);return;}
    if(g_mode!=MODE_OFF){if(g_gatherActive||g_gatherLootWait)GatherStop(p,now,"SAFEBREAK_ABORT",1u,0u);return;}
    if(Combat(p)&&(g_gatherActive||g_gatherLootWait)&&g_gatherKind!=2u){
        ++g_gatherAborts;
        if(g_gatherKind==4u){
            g_chestAggroLo=g_gatherTargetLo;g_chestAggroHi=g_gatherTargetHi;
            g_chestLastReason=4u;
            GatherStop(p,now,"AUTOCHEST_AGGRO_BLACKLIST_ABORT",1u,0u);
        }else GatherStop(p,now,"COMBAT_ABORT_NONMINING",1u,0u);
        return;
    }
    if(!g_hasMining&&!g_hasHerbalism&&!g_autoOpenEnabled&&!g_chestEnabled){if(g_gatherActive||g_gatherLootWait)GatherStop(p,now,"NO_SOURCE_ABORT",1u,0u);return;}

    /* Manual-loot gate.  There is deliberately NO LootSlot/ConfirmLootSlot
     * execution in V50.  While a real loot window is open we never click the
     * node again, avoiding "Item is already in use". */
    if(g_gatherLootWait){
        obj=ObjByGuid(g_gatherTargetLo,g_gatherTargetHi);
        if(g_gatherKind==3u&&Ptr(obj)&&!AutoOpenInMelee(p,obj,&d2)){
            GatherStop(p,now,"AUTOOPEN_OUT_OF_MELEE_LOOTWAIT",0u,0u);return;
        }
        if(!Ptr(obj)&&!g_gatherLootTargetGoneLogged){g_gatherLootTargetGoneLogged=1u;GatherFileLog("MANUALLOOT_TARGET_GONE",now,g_gatherEntry,g_gatherTargetLo,g_gatherTargetHi,g_gatherDistSq,g_gatherAttempts,g_gatherKind);}
        if(g_gatherSpoof&&(!g_gatherLastHB||(DWORD)(now-g_gatherLastHB)>=GATHER_HB_GAP_MS))GatherSendFake(p,now);
        lootOpen=GatherLootOpen();
        if(lootOpen){
            g_gatherLootSeenOpen=1u;
            if(g_gatherKind==4u&&g_chestAutoLoot)DebugChat(g_chestLootScript);
            if(!g_gatherLootOpenLogged){g_gatherLootOpenLogged=1u;GatherFileLog("MANUALLOOT_OPEN",now,g_gatherEntry,g_gatherTargetLo,g_gatherTargetHi,g_gatherDistSq,g_gatherAttempts,g_gatherKind);}
        }
        lootAge=(DWORD)(now-g_gatherLootStart);
        if(g_gatherLootSeenOpen&&!lootOpen&&lootAge>=GATHER_LOOT_MIN_OPEN_MS){GatherFinishManualLoot(p,now,"MANUALLOOT_CLOSED_RETRY");return;}
        if(!g_gatherLootSeenOpen&&lootAge>=GATHER_LOOT_OPEN_GRACE_MS){GatherFinishManualLoot(p,now,"MANUALLOOT_NO_WINDOW_RETRY");return;}
        return;
    }

    if(!g_gatherActive&&!g_gatherLootWait&&GatherLootOpen()){
        ++g_foreignLootPauses;
        if(!g_foreignLootLogged){g_foreignLootLogged=1u;GatherFileLog("FOREIGN_LOOT_PAUSE",now,0u,0u,0u,0.0f,0u,0u);}
        g_gatherNextScan=now+150u;return;
    }
    if(g_foreignLootLogged){g_foreignLootLogged=0u;g_gatherNextScan=now+150u;}
    if(!g_gatherActive&&castId)return;
    if(g_gatherActive){
        /* A loot window can arrive in the same timer slice as cast-end.  If we
           already observed this gather cast, promote it directly to our manual
           loot gate and KEEP the far spoof alive.  Otherwise the loot belongs
           to PP/corpse/another action and gathering yields immediately. */
        lootOpen=GatherLootOpen();
        if(lootOpen){
            if(g_gatherKind==4u){GatherBeginManualLootWait(p,now,"AUTOCHEST_LOOT_OPEN");return;}
            if(g_gatherSawCast&&!castId){GatherBeginManualLootWait(p,now,"MANUALLOOT_WAIT_OPEN");return;}
            ++g_foreignLootPauses;
            GatherStop(p,now,"FOREIGN_LOOT_ABORT",1u,0u);
            g_foreignLootLogged=1u;g_gatherNextScan=now+150u;return;
        }
        obj=ObjByGuid(g_gatherTargetLo,g_gatherTargetHi);
        if(!Ptr(obj)){GatherStop(p,now,"TARGET_GONE",1u,0u);return;}
        if(g_gatherKind==3u){
            if(!AutoOpenInMelee(p,obj,&d2)){
                GatherStop(p,now,"AUTOOPEN_OUT_OF_MELEE",0u,0u);return;
            }
            g_gatherDistSq=d2;
        }

        /* Never classify arbitrary player spells as gather casts.  If another
         * spell starts while gathering, yield immediately; PP gets its own
         * explicit event name above for diagnostics. */
        if(castId&&!GatherCastMatches(g_gatherKind,castId)){
            ++g_foreignCastAborts;
            GatherStop(p,now,"FOREIGN_CAST_ABORT",1u,0u);
            return;
        }

        if(g_gatherKind==3u&&!g_gatherClickPending&&g_autoOpenPickPrimed&&
           g_autoOpenClickCount>0u&&g_autoOpenClickCount<AUTOOPEN_CLICK_MAX_ATTEMPTS&&
           !g_gatherSawCast&&!castId&&!lootOpen&&
           (DWORD)(now-g_autoOpenLastClickAt)>=AUTOOPEN_CLICK_RETRY_MS){
            /* Some clients do not dispatch the pending Pick Lock cursor on the
             * first native GO click. Retry the same real-GO interaction at most
             * twice; every retry still passes the melee gate above. */
            g_gatherClickPending=1u;g_gatherClickAt=now;
            GatherFileLog("AUTOOPEN_CLICK_RETRY",now,g_gatherEntry,g_gatherTargetLo,g_gatherTargetHi,g_gatherDistSq,g_autoOpenClickCount,g_gatherKind);
        }
        if(g_gatherKind==4u&&!g_gatherClickPending&&!castId&&!g_gatherSawCast&&g_chestRetryAt&&
           (LONG)(now-g_chestRetryAt)>=0){
            if(g_chestLoSCheck){
                ++g_chestSuspectedLoS;g_chestLastReason=2u;
                GatherFileLog("AUTOCHEST_NO_CAST_OR_LOOT_SUSPECT_LOS",now,g_gatherEntry,
                              g_gatherTargetLo,g_gatherTargetHi,g_gatherDistSq,
                              g_chestAttemptCount,g_chestStep);
            }
            if(!g_chestLoSRecovery||g_chestAttemptCount>=g_chestMaxAttempts){
                ChestLoSDefer(g_gatherTargetLo,g_gatherTargetHi,now);
                g_chestLastReason=g_chestLoSBlacklist?3u:2u;
                GatherStop(p,now,"AUTOCHEST_NO_RESPONSE_ATTEMPTS_EXHAUSTED",1u,0u);
                g_gatherNextScan=now+1500u;return;
            }
            g_chestLastReason=5u;
            if(g_chestStep>=CHEST_MAX_STEPS){
                /* After eight near-node Z attempts, retry around exact chest XYZ
                 * (eight LOS vectors, no distant world translations). */
                if(!Mining3DQueueRetry(p,now)){
                    /* Exhausting this sweep must not temporarily blacklist the GO.
                     * The next ordinary scan may retry immediately. */
                    ChestLoSDefer(g_gatherTargetLo,g_gatherTargetHi,now);
                    g_chestLastReason=g_chestLoSBlacklist?3u:2u;
                    GatherStop(p,now,"AUTOCHEST_MINING3D_EXHAUSTED",1u,0u);
                    g_gatherNextScan=now+1500u;return;
                }
                g_chestRetryAt=now+CHEST_RETRY_MS;
            }else{
                ++g_chestStep;
                g_gatherX=g_gatherNodeX;g_gatherY=g_gatherNodeY;
                g_gatherZ=g_gatherNodeZ-CHEST_DEPTH_YD+CHEST_STEP_YD*(float)g_chestStep;
                g_chestRetryAt=now+CHEST_RETRY_MS;
                GatherSendFake(p,now);
                g_gatherClickPending=1u;g_gatherClickAt=now+MINING_3D_RETRY_SETTLE_MS;
                GatherFileLog("AUTOCHEST_MINING_RAISE_Z",now,g_gatherEntry,g_gatherTargetLo,
                              g_gatherTargetHi,g_gatherDistSq,g_chestStep,0u);
            }
        }
        if(g_gatherSpoof&&(!g_gatherLastHB||(DWORD)(now-g_gatherLastHB)>=GATHER_HB_GAP_MS))GatherSendFake(p,now);
        if(g_gatherKind==2u&&!g_gatherSawCast&&!g_gatherClickPending&&!GatherCastMatches(2u,castId)&&g_mining3DRetryAt&&(LONG)(now-g_mining3DRetryAt)>=0){
            if(!Mining3DQueueRetry(p,now)){
                ++g_mining3DSweepsExhausted;GatherFileLog("MINING_HARDLOS_SWEEP_EXHAUSTED",now,g_gatherEntry,g_gatherTargetLo,g_gatherTargetHi,g_gatherDistSq,g_gatherAttempts,g_mining3DRetryIndex);
                GatherStop(p,now,"MINING_HARDLOS_NO_CAST",1u,0u);g_gatherNextScan=now+750u;return;
            }
        }
        if(g_gatherClickPending&&(LONG)(now-g_gatherClickAt)>=0){
            if(GatherHasStealth(p)){
                ++g_gatherStealthWaits;GatherRequestStealthBreak(p,now);g_gatherClickAt=now+GATHER_STEALTH_BREAK_DELAY_MS;
            }else{
                if(g_gatherKind==3u&&!AutoOpenInMelee(p,obj,&d2)){
                    GatherStop(p,now,"AUTOOPEN_OUT_OF_MELEE_BEFORE_CLICK",0u,0u);return;
                }
                if(g_gatherKind==3u&&!g_autoOpenPickPrimed){AutoOpenPrimePickLock(p,now);g_autoOpenPickPrimed=1u;g_gatherClickAt=now+AUTOOPEN_PICKLOCK_SETTLE_MS;}
                else{
                    g_gatherClickPending=0u;g_gatherStealthPending=0u;
                    GatherFileLog(g_gatherKind==3u?"AUTOOPEN_CLICK":"STEALTH_CLEAR_CLICK",now,g_gatherEntry,g_gatherTargetLo,g_gatherTargetHi,g_gatherDistSq,g_gatherAttempts,g_gatherKind);
                    if(g_gatherSpoof)GatherClickSpoof(p,obj,now);else GatherClickNative(p,obj,now);
                    if(g_gatherKind==2u&&!g_gatherSawCast)g_mining3DRetryAt=now+((g_mining3DRetryIndex==0u)?MINING_3D_RETRY_FIRST_MS:MINING_3D_RETRY_GAP_MS);
                }
            }
        }

        castId=*(DWORD*)ADDR_CASTING_SPELLID;
        if(GatherCastMatches(g_gatherKind,castId)){
            g_gatherSawCast=1u;
            if(!g_gatherCastSeenLogged){g_gatherCastSeenLogged=1u;GatherFileLog("GATHER_CAST_SEEN",now,g_gatherEntry,g_gatherTargetLo,g_gatherTargetHi,g_gatherDistSq,g_gatherAttempts,castId);}
            if(g_gatherKind==2u&&g_miningEarlyRestoreEnabled&&!g_miningBelowNodeEnabled&&g_gatherSpoof&&
               !g_miningEarlyRestoreUsed&&!Combat(p)){
                /* Only after observing the mining cast; never release a pending
                 * click / LOS retry or any herb, open, PP or combat transaction. */
                g_miningEarlyRestoreUsed=1u;
                g_miningEarlyRestored=1u;
                g_miningEarlyRestoreAt=now;
                g_gatherSpoof=0u;
                SendReal(p);
                ++g_miningEarlyRestoreCount;
                GatherFileLog("MINING_EARLY_RESTORE_REAL",now,g_gatherEntry,g_gatherTargetLo,g_gatherTargetHi,g_gatherDistSq,g_gatherAttempts,castId);
            }
        }else if(castId){
            if(castId==SPELL_PICK_POCKET){++g_ppPriorityAborts;GatherClearForPPFast(now,2u);}
            else{++g_foreignCastAborts;GatherStop(p,now,"FOREIGN_CAST_ABORT",1u,0u);}
            return;
        }

        if(g_gatherKind==2u&&g_miningEarlyRestored&&!castId&&!GatherLootOpen()&&
           (DWORD)(now-g_miningEarlyRestoreAt)<MINING_EARLY_CANCEL_WINDOW_MS){
            /* Early disappearance of the cast after real XYZ is treated as
             * interruption. Re-arm once and retry through the existing HARDLOS
             * machinery. Fail closed to legacy mining until manually re-enabled. */
            g_miningEarlyRestored=0u;
            g_miningEarlyRestoreAt=0u;
            g_miningEarlyRestoreEnabled=0u;
            g_gatherSpoof=1u;
            GatherSendFake(p,now);
            g_gatherSawCast=0u;
            g_gatherCastSeenLogged=0u;
            g_mining3DRetryAt=now+MINING_3D_RETRY_FIRST_MS;
            ++g_miningEarlyCancelCount;
            GatherFileLog("MINING_EARLY_INTERRUPTED_LEGACY",now,g_gatherEntry,g_gatherTargetLo,g_gatherTargetHi,g_gatherDistSq,g_gatherAttempts,0u);
            return;
        }
        hold=(g_gatherKind==1u)?GATHER_HERB_HOLD_MS:((g_gatherKind==3u)?AUTOOPEN_HOLD_MS:GATHER_MINING_HOLD_MS);
        if(g_gatherSawCast&&!castId&&(DWORD)(now-g_gatherStart)>=350u){GatherBeginManualLootWait(p,now,"MANUALLOOT_WAIT_CAST_END");return;}
        if((DWORD)(now-g_gatherStart)>=hold){GatherBeginManualLootWait(p,now,"MANUALLOOT_WAIT_FALLBACK");return;}
        return;
    }

    if((LONG)(g_gatherNextScan-now)>0)return;g_gatherNextScan=now+GATHER_TIMER_SCAN_MS;
    /* A completed chest becomes selectable again only after despawn.
     * This is an object-lifecycle guard, not a time-based cooldown. */
    ChestLoSSkipped(0u,0u,now); /* prune expired entries */
    if((g_chestSkipLo||g_chestSkipHi)&&
       !Ptr(ObjByGuid(g_chestSkipLo,g_chestSkipHi)))
        g_chestSkipLo=g_chestSkipHi=0u;
    if((g_chestAggroLo||g_chestAggroHi)&&
       !Ptr(ObjByGuid(g_chestAggroLo,g_chestAggroHi)))
        g_chestAggroLo=g_chestAggroHi=0u;
    obj=FindBestGatherNode(p,now,&entry,&lo,&hi,&kind,&d2);
    if(g_gatherLastStatusLog==0u||(DWORD)(now-g_gatherLastStatusLog)>=GATHER_STATUS_LOG_MS){g_gatherLastStatusLog=now;GatherFileLog("SCAN_STATUS",now,0u,0u,0u,0.0f,0u,0u);}
    if(obj){if(lo==g_gatherTargetLo&&hi==g_gatherTargetHi&&entry==g_gatherEntry)g_gatherAttempts++;else g_gatherAttempts=1u;GatherBegin(p,obj,now,entry,lo,hi,kind,d2);}
}

static void Stop(BOOL sendReal)
{
    BYTE*p=LocalPlayer();
    g_mode=MODE_OFF;g_started=0;g_lastInject=0;g_safeBreakPauseTick=0u;g_seenCombat=0;g_clearTick=0;g_worldLost=0;g_worldReadySince=0;
    if(sendReal&&p&&!g_injecting)SendReal(p);
}

static void Start(DWORD mode,DWORD now)
{
    BYTE*p=LocalPlayer(),*t=0;DWORD lo,hi;float px,py,pz,po,dist,down,dx,dy;
    if(!p)return;
    if(mode==MODE_INSTANCE_UNREACHABLE&&!Combat(p))return;
    px=*(float*)(p+OFF_UNIT_X);py=*(float*)(p+OFF_UNIT_Y);pz=*(float*)(p+OFF_UNIT_Z);po=*(float*)(p+OFF_UNIT_O);
    if(mode==MODE_LEGACY_FAST){dist=LEGACY_FAST_DISTANCE;down=LEGACY_FAST_Z_DOWN;}
    else if(mode==MODE_LOCAL_STRONG){dist=LOCAL_STRONG_DISTANCE;down=LOCAL_STRONG_Z_DOWN;}
    else if(mode==MODE_PURSUIT){dist=PURSUIT_DISTANCE;down=PURSUIT_Z_DOWN;}
    else{dist=0.0f;down=0.0f;}
    lo=*(DWORD*)ADDR_SELECTED_GUID_LOW;hi=*(DWORD*)ADDR_SELECTED_GUID_HIGH;t=ObjByGuid(lo,hi);
    g_x=px+dist;g_y=py;g_z=pz-down;g_o=po;
    if(mode==MODE_LOCAL_STRONG&&t){dx=px-*(float*)(t+OFF_UNIT_X);dy=py-*(float*)(t+OFF_UNIT_Y);if(AbsF(dx)>=AbsF(dy)){g_x=(dx<0)?px-dist:px+dist;g_y=py;}else{g_x=px;g_y=(dy<0)?py-dist:py+dist;}}
    if(mode==MODE_INSTANCE_UNREACHABLE){g_x=px;g_y=py;g_z=pz+INSTANCE_Z_UP;}
    g_mode=mode;g_started=now;g_lastInject=0;g_safeBreakPauseTick=0u;g_seenCombat=Combat(p);g_clearTick=0;g_worldLost=0;g_worldReadySince=now;
}

static void Inject(BYTE*p)
{
    float x,y,z,o,sx,sy,sz,so;DWORD*fp=0,oldFlags=0;SendMove_t sm=(SendMove_t)ADDR_SEND_MOVE;
    if(!Ptr(p))return;
    x=*(float*)(p+OFF_UNIT_X);y=*(float*)(p+OFF_UNIT_Y);z=*(float*)(p+OFF_UNIT_Z);o=*(float*)(p+OFF_UNIT_O);
    sx=g_x;sy=g_y;sz=g_z;so=g_o;
    if(g_mode==MODE_INSTANCE_UNREACHABLE){fp=MoveFlags(p);if(!fp){++g_moveInfoFailures;Stop(TRUE);return;}oldFlags=*fp;sx=x;sy=y;sz=z+INSTANCE_Z_UP;so=o;}
    g_injecting=1;
    if(fp)*fp=oldFlags|MOVEFLAG_FLYING;
    *(float*)(p+OFF_UNIT_X)=sx;*(float*)(p+OFF_UNIT_Y)=sy;*(float*)(p+OFF_UNIT_Z)=sz;*(float*)(p+OFF_UNIT_O)=so;
    sm(p,MSG_MOVE_HEARTBEAT);sm(p,MSG_MOVE_HEARTBEAT);g_hb+=2u;
    *(float*)(p+OFF_UNIT_X)=x;*(float*)(p+OFF_UNIT_Y)=y;*(float*)(p+OFF_UNIT_Z)=z;*(float*)(p+OFF_UNIT_O)=o;
    if(fp)*fp=oldFlags;
    g_injecting=0;
}

static void __stdcall TimerProc(HWND w,UINT m,UINT_PTR id,DWORD tm)
{
    DWORD now,dur,gap,k7,k8,k9,kAlt,k10,k11,k12,paused;BYTE*p;
    (void)w;(void)m;(void)id;(void)tm;
    if(!GT()||!GK())return;
    now=GT()();
    PPBlacklistTick(now);
    FlushPendingPPLog();
    k7=(GK()(VK_F7)&(short)0x8000)?1u:0u;k8=(GK()(VK_F8)&(short)0x8000)?1u:0u;k9=(GK()(VK_F9)&(short)0x8000)?1u:0u;kAlt=(GK()(VK_LMENU)&(short)0x8000)?1u:0u;k10=(GK()(VK_F10)&(short)0x8000)?1u:0u;k11=(GK()(VK_F11)&(short)0x8000)?1u:0u;k12=(GK()(VK_F12)&(short)0x8000)?1u:0u;
    if(k7&&!g_key7){Stop(TRUE);if(g_gatherActive||g_gatherLootWait)GatherStop(LocalPlayer(),now,"F7_ABORT",1u,0u);}if(k8&&!g_key8)Start(MODE_LEGACY_FAST,now);if(k9&&!g_gatherKey9){g_gatherEnabled=g_gatherEnabled?0u:1u;GatherFileLog(g_gatherEnabled?"TOGGLE_ON":"TOGGLE_OFF",now,0u,0u,0u,0.0f,0u,0u);DebugChat(g_gatherEnabled?g_chatOn:g_chatOff);}if(kAlt&&!g_keyAlt)Start(MODE_LOCAL_STRONG,now);if(k10&&!g_key10)Start(MODE_PURSUIT,now);if(k11&&!g_key11){g_autoPPEnabled=g_autoPPEnabled?0u:1u;DebugChat(g_autoPPEnabled?g_chatPPOn:g_chatPPOff);GatherFileLog(g_autoPPEnabled?"AUTOPP_TOGGLE_ON":"AUTOPP_TOGGLE_OFF",now,0u,0u,0u,0.0f,0u,0u);}if(k12&&!g_autoOpenKey12){g_autoOpenEnabled=g_autoOpenEnabled?0u:1u;DebugChat(g_autoOpenEnabled?g_chatOpenOn:g_chatOpenOff);GatherFileLog(g_autoOpenEnabled?"AUTOOPEN_TOGGLE_ON":"AUTOOPEN_TOGGLE_OFF",now,0u,0u,0u,0.0f,0u,0u);if(!g_autoOpenEnabled&&g_gatherActive&&g_gatherKind==3u)GatherStop(LocalPlayer(),now,"AUTOOPEN_DISABLED_ABORT",1u,0u);}
    g_key7=k7;g_key8=k8;g_gatherKey9=k9;g_keyAlt=kAlt;g_key10=k10;g_key11=k11;g_autoOpenKey12=k12;
    p=LocalPlayer();if(p){if(!g_gatherReadyChat){g_gatherReadyChat=1u;DebugChat(g_ppChainOk?g_chatReady:g_chatChainBad);if(g_ppChainOk){DebugChat(g_autoPPEnabled?g_chatPPOn:g_chatPPOff);DebugChat(g_autoOpenEnabled?g_chatOpenOn:g_chatOpenOff);}}GatherTick(p,now);}else if(g_gatherActive||g_gatherLootWait){g_gatherActive=0u;g_gatherLootWait=0u;g_gatherLootWaitUntil=0u;g_gatherLootStart=0u;g_gatherLootSeenOpen=0u;g_gatherLootOpenLogged=0u;g_gatherSawCast=0u;g_gatherCastSeenLogged=0u;g_gatherStealthPending=0u;g_gatherSpoof=0u;GatherFileLog("WORLD_LOST_ABORT",now,g_gatherEntry,g_gatherTargetLo,g_gatherTargetHi,g_gatherDistSq,g_gatherAttempts,0u);}
    if(g_mode==MODE_OFF)return;

    /* SafeBreak synthetic movement must never race Pick Pocket.  Far PP is
     * covered by LongPP active/injecting; normal-range PP is covered by the
     * outgoing 921 quiet window even when LongPP correctly decides not to spoof. */
    if(LongPPActive()||LongPPInjecting()||(*(DWORD*)ADDR_CASTING_SPELLID)==SPELL_PICK_POCKET||((LONG)(g_ppQuietUntil-now)>0)){
        /* Do not burn SafeBreak lifetime while PP owns movement. */
        if(!g_safeBreakPauseTick)g_safeBreakPauseTick=now;
        ++g_ppSafeBreakYields;
        return;
    }
    if(g_safeBreakPauseTick){
        paused=(DWORD)(now-g_safeBreakPauseTick);
        g_started+=paused;
        g_safeBreakPauseMs+=paused;
        g_safeBreakPauseTick=0u;
        g_lastInject=0u; /* resume with an immediate spoof pulse */
        ++g_safeBreakResumes;
    }

    p=LocalPlayer();
    if(!p){g_worldLost=1u;g_worldReadySince=0u;++g_worldGuardHits;return;}
    if(g_worldLost){
        if(!g_worldReadySince){g_worldReadySince=now;++g_worldGuardHits;return;}
        if((DWORD)(now-g_worldReadySince)<WORLD_REACQUIRE_MS){++g_worldGuardHits;return;}
        /* An active synthetic mode should not continue across a map/BG rebuild. */
        Stop(FALSE);
        return;
    }

    dur=(g_mode==MODE_LEGACY_FAST)?LEGACY_FAST_MS:(g_mode==MODE_LOCAL_STRONG)?LOCAL_STRONG_MS:(g_mode==MODE_PURSUIT)?PURSUIT_MS:INSTANCE_MS;
    gap=(g_mode==MODE_LEGACY_FAST)?LEGACY_FAST_GAP_MS:(g_mode==MODE_LOCAL_STRONG)?LOCAL_STRONG_GAP_MS:(g_mode==MODE_PURSUIT)?PURSUIT_GAP_MS:INSTANCE_GAP_MS;
    if(g_seenCombat){if(!Combat(p)){if(!g_clearTick)g_clearTick=now;else if((DWORD)(now-g_clearTick)>=CLEAR_SETTLE_MS){Stop(TRUE);return;}}else g_clearTick=0;}
    if((DWORD)(now-g_started)>=dur){Stop(TRUE);return;}
    if(!g_lastInject||(DWORD)(now-g_lastInject)>=gap){g_lastInject=now;Inject(p);}
}

/* Rewrite gather XYZ in the outer movement packet, but ALWAYS forward it to
 * the downstream hook.  LongPickPocket can therefore rewrite the same packet
 * afterwards and wins whenever its own spoof is active. */
static void __cdecl Gather_ProcessMovementPacket(DataStore5875* packet)
{
    BYTE*raw;DWORD size;
    if(!g_gatherSpoof||!(g_gatherActive||g_gatherLootWait)||!packet)return;
    if(LongPPActive()||LongPPInjecting()||(*(DWORD*)ADDR_CASTING_SPELLID)==SPELL_PICK_POCKET){++g_ppMoveBypasses;return;}
    size=packet->size;if(size<0x20u||size>MAX_PACKET_SIZE)return;
    raw=PacketRawBase(packet);if(!raw)return;
    *(float*)(raw+0x0Cu)=g_gatherX;
    *(float*)(raw+0x10u)=g_gatherY;
    *(float*)(raw+0x14u)=g_gatherZ;
    ++g_gatherPacketRewrites;
}

static void __cdecl MoveIntercept(void)
{
    g_forwardCurrent=1;
    if(g_injecting||g_ppResetInProgress)return;
    if(LongPPActive()||LongPPInjecting()||(*(DWORD*)ADDR_CASTING_SPELLID)==SPELL_PICK_POCKET)return;
    /* AutoGather never suppresses here in V50. It rewrites XYZ and forwards,
     * preserving the downstream LongPickPocket movement hook. */
    if(g_mode==MODE_LOCAL_STRONG||g_mode==MODE_PURSUIT||g_mode==MODE_INSTANCE_UNREACHABLE){g_forwardCurrent=0;++g_suppressed;}
}

/* Send-entry arbiter.  The supported chain is:
 *   WoW 0x5AB630 -> this wrapper -> LongPickPocket send wrapper -> original.
 * We only observe outgoing CMSG_CAST_SPELL and synchronously preempt gather
 * for spell 921 before LongPP makes its normal-range/spoof decision. */
__declspec(naked) static void PPArbiter_SendWrapper(void)
{
    __asm {
        pushfd
        pushad
        push dword ptr [esp+36]
        push ecx
        call PPArbiter_BeforeSend
        add  esp, 8
        popad
        popfd
        cmp  dword ptr [g_ppForward], 0
        je   pp_blocked_packet
        mov  eax, dword ptr [g_nextSendTarget]
        jmp  eax
pp_blocked_packet:
        xor  eax, eax
        ret
    }
}

/* One movement-callsite owner. V50 order: NoFall -> conditional Gather XYZ
 * rewrite -> SafeBreak -> LongPickPocket -> PositionalSpoof -> client. */
__declspec(naked) static void MovementCore_MoveWrapper(void)
{
    __asm {
        /* V42 NoFall was the outermost hook. */
        pushfd
        pushad
        push ecx
        call NoFall_ProcessMovementPacket
        add  esp, 4
        popad
        popfd

        /* V50 AutoGather rewrites XYZ but does not consume the packet.
         * Downstream LongPickPocket is still called and may override it. */
        pushfd
        pushad
        push ecx
        call Gather_ProcessMovementPacket
        add  esp, 4
        popad
        popfd

        /* Then V42 SafeBreak decided whether to forward this packet. */
        cmp  dword ptr [g_injecting], 0
        jne  forward_packet
        pushfd
        pushad
        call MoveIntercept
        popad
        popfd
        cmp  dword ptr [g_forwardCurrent], 0
        je   suppress_packet

forward_packet:
        pushfd
        pushad
        call PPHardApplySpoof
        popad
        popfd
        mov  eax, dword ptr [g_nextMoveTarget]
        call eax
        ret

suppress_packet:
        xor  eax, eax
        ret
    }
}

static BOOL InstallUnified(void)
{
    static const BYTE sig[8]={0x55,0x8B,0xEC,0x8B,0x45,0x08,0x56,0x6A};
    DWORD i,t,st,ft,decodedActive=0u,decodedInject=0u;
    if(*(BYTE*)ADDR_MOVE_SEND_CALL!=0xE8){g_status=2u;return FALSE;}
    for(i=0;i<8;i++)if(*((BYTE*)ADDR_SEND_MOVE+i)!=sig[i]){g_status=6u;return FALSE;}
    t=DCall(ADDR_MOVE_SEND_CALL);if(!t){g_status=2u;return FALSE;}
    if(t==(DWORD)(LPVOID)&MovementCore_MoveWrapper){g_status=4u;g_installed=1u;return TRUE;}
    st=DJump(ADDR_CLIENT_SEND);
    g_nextMoveTarget=t;g_nextSendTarget=st;

    /* Require the exact LongPP v0.8-facing chain used by this project.
     * If order/version is wrong, leave AutoGather fail-safe blocked rather
     * than risk corrupting Pick Pocket movement state. */
    if(st&&DecodeLongPPMoveHook(t,&decodedActive,&decodedInject)&&IsLongPPSendHook(st)&&st==t+0x100u){
        g_ppChainOk=1u;g_ppActivePtr=decodedActive;g_ppInjectPtr=decodedInject;
        /* Supported LongPP layout: move hook RVA 0x1970, persistent state at 0x50E4..0x5104. */
        g_longPPBase=t-0x1970u;g_longPPGuidLoPtr=g_longPPBase+0x50E4u;g_longPPGuidHiPtr=g_longPPBase+0x50E8u;
        g_longPPSpoofXPtr=g_longPPBase+0x50F0u;g_longPPSpoofYPtr=g_longPPBase+0x50F4u;g_longPPSpoofZPtr=g_longPPBase+0x50F8u;g_longPPSpoofOPtr=g_longPPBase+0x50FCu;g_longPPReasonPtr=g_longPPBase+0x5104u;
    }else{
        g_ppChainOk=0u;g_ppActivePtr=0u;g_ppInjectPtr=0u;g_longPPBase=g_longPPReasonPtr=g_longPPGuidLoPtr=g_longPPGuidHiPtr=g_longPPSpoofXPtr=g_longPPSpoofYPtr=g_longPPSpoofZPtr=g_longPPSpoofOPtr=0u;
    }

    ft=DCall(ADDR_PP_FAIL_CALL);
    if(g_ppChainOk&&ft==t+0xE0u){g_nextPPFailTarget=ft;if(PCall(ADDR_PP_FAIL_CALL,(DWORD)(LPVOID)&PPBlacklist_FailThunk))g_ppFailHookOk=1u;else{g_ppFailHookOk=0u;g_ppChainOk=0u;}}
    else{g_nextPPFailTarget=ft;g_ppFailHookOk=0u;g_ppChainOk=0u;}

    if(!PCall(ADDR_MOVE_SEND_CALL,(DWORD)(LPVOID)&MovementCore_MoveWrapper)){if(g_ppFailHookOk&&DCall(ADDR_PP_FAIL_CALL)==(DWORD)(LPVOID)&PPBlacklist_FailThunk)PCall(ADDR_PP_FAIL_CALL,g_nextPPFailTarget);g_status=3u;return FALSE;}
    if(g_ppChainOk){
        if(!PJump(ADDR_CLIENT_SEND,(DWORD)(LPVOID)&PPArbiter_SendWrapper)){if(g_ppFailHookOk&&DCall(ADDR_PP_FAIL_CALL)==(DWORD)(LPVOID)&PPBlacklist_FailThunk)PCall(ADDR_PP_FAIL_CALL,g_nextPPFailTarget);PCall(ADDR_MOVE_SEND_CALL,t);g_status=8u;return FALSE;}
    }
    if(ST())g_timerId=(DWORD)ST()((HWND)0,(UINT_PTR)0,TIMER_MS,TimerProc);
    if(!g_timerId){if(g_ppChainOk&&DJump(ADDR_CLIENT_SEND)==(DWORD)(LPVOID)&PPArbiter_SendWrapper)PJump(ADDR_CLIENT_SEND,st);if(g_ppFailHookOk&&DCall(ADDR_PP_FAIL_CALL)==(DWORD)(LPVOID)&PPBlacklist_FailThunk)PCall(ADDR_PP_FAIL_CALL,g_nextPPFailTarget);PCall(ADDR_MOVE_SEND_CALL,t);g_status=7u;return FALSE;}
    g_installed=1u;g_status=1u;
    GatherFileLog("READY",GT()?GT()():0u,0u,0u,0u,0.0f,0u,0x000C0000u);
    GatherFileLog("CHAIN_MOVE_NEXT",GT()?GT()():0u,0u,0u,0u,0.0f,0u,g_nextMoveTarget);
    GatherFileLog("CHAIN_SEND_NEXT",GT()?GT()():0u,0u,0u,0u,0.0f,0u,g_nextSendTarget);
    GatherFileLog(g_ppChainOk?"PPCHAIN_OK":"PPCHAIN_BAD_GATHER_BLOCKED",GT()?GT()():0u,0u,0u,0u,0.0f,0u,g_ppChainOk);
    if(g_ppChainOk)GatherFileLog("AUTOPP_V68_REARONLY_HARDLOS3D_RETRY_READY",GT()?GT()():0u,0u,0u,0u,0.0f,0u,g_longPPBase);
    GatherFileLog(g_ppFailHookOk?"AUTOPP_FAILHOOK_OK":"AUTOPP_FAILHOOK_BAD",GT()?GT()():0u,0u,0u,0u,0.0f,0u,g_nextPPFailTarget);
    return TRUE;
}

static void RemoveUnified(void)
{
    DWORD cur,scur;
    if(g_timerId&&KT())KT()((HWND)0,(UINT_PTR)g_timerId);
    g_timerId=0;if(g_gatherActive||g_gatherLootWait)GatherStop(LocalPlayer(),GT()?GT()():0u,"DLL_DETACH",0u,0u);Stop(FALSE);
    if(g_ppFailHookOk&&DCall(ADDR_PP_FAIL_CALL)==(DWORD)(LPVOID)&PPBlacklist_FailThunk&&g_nextPPFailTarget)PCall(ADDR_PP_FAIL_CALL,g_nextPPFailTarget);g_ppFailHookOk=0u;
    scur=DJump(ADDR_CLIENT_SEND);
    if(scur==(DWORD)(LPVOID)&PPArbiter_SendWrapper&&g_nextSendTarget)PJump(ADDR_CLIENT_SEND,g_nextSendTarget);
    cur=DCall(ADDR_MOVE_SEND_CALL);
    if(cur==(DWORD)(LPVOID)&MovementCore_MoveWrapper&&g_nextMoveTarget)PCall(ADDR_MOVE_SEND_CALL,g_nextMoveTarget);
    g_installed=0;g_status=5u;
}

/* Compatibility exports retained from the merged modules. */
__declspec(dllexport) DWORD __stdcall MSB13_GetStatus(void){return g_installed;}
__declspec(dllexport) DWORD __stdcall MSB13_GetMode(void){return g_mode;}
__declspec(dllexport) DWORD __stdcall MSB13_GetHeartbeats(void){return g_hb;}
__declspec(dllexport) DWORD __stdcall MSB13_GetSuppressed(void){return g_suppressed;}
__declspec(dllexport) DWORD __stdcall MSB13_GetMoveInfoFailures(void){return g_moveInfoFailures;}
__declspec(dllexport) DWORD __stdcall WoWNoFall_GetStatus(void){return g_status;}
__declspec(dllexport) DWORD __stdcall WoWNoFall_GetVersion(void){return 0x00010000u;}

/* V43 diagnostics. */
__declspec(dllexport) DWORD __stdcall MovementCore_GetVersion(void){return 0x00110000u;}
__declspec(dllexport) DWORD __stdcall MovementCore_GetStatus(void){return g_status;}
__declspec(dllexport) DWORD __stdcall MovementCore_GetNextHook(void){return g_nextMoveTarget;}
__declspec(dllexport) DWORD __stdcall MovementCore_GetNoFallPackets(void){return g_noFallPackets;}
__declspec(dllexport) DWORD __stdcall MovementCore_GetPreLandHeartbeats(void){return g_preLandHeartbeats;}
__declspec(dllexport) DWORD __stdcall MovementCore_GetWorldGuardHits(void){return g_worldGuardHits;}

__declspec(dllexport) DWORD __stdcall AutoGather_GetEnabled(void){return g_gatherEnabled;}
__declspec(dllexport) DWORD __stdcall AutoGather_GetActive(void){return g_gatherActive;}
__declspec(dllexport) DWORD __stdcall AutoGather_GetMining(void){return g_hasMining;}
__declspec(dllexport) DWORD __stdcall AutoGather_GetHerbalism(void){return g_hasHerbalism;}
__declspec(dllexport) DWORD __stdcall AutoGather_GetTargetEntry(void){return g_gatherEntry;}
__declspec(dllexport) DWORD __stdcall AutoGather_GetClicks(void){return g_gatherClicks;}
__declspec(dllexport) DWORD __stdcall AutoGather_GetVisibleObjects(void){return g_gatherScanVisible;}
__declspec(dllexport) DWORD __stdcall AutoGather_GetEligibleNodes(void){return g_gatherScanEligible;}
__declspec(dllexport) DWORD __stdcall AutoGather_GetSpoof(void){return g_gatherSpoof;}
__declspec(dllexport) DWORD __stdcall AutoGather_GetPosSource(void){return g_gatherPosSource;}
__declspec(dllexport) DWORD __stdcall AutoGather_GetLootWait(void){return g_gatherLootWait;}
__declspec(dllexport) DWORD __stdcall AutoGather_GetLootWaitRemaining(void){DWORD now=GT()?GT()():0u;return(g_gatherLootWait&&(LONG)(g_gatherLootWaitUntil-now)>0)?(g_gatherLootWaitUntil-now):0u;}
__declspec(dllexport) DWORD __stdcall AutoGather_GetAutoLootPulses(void){return 0u;}
__declspec(dllexport) DWORD __stdcall AutoGather_GetPPPriorityAborts(void){return g_ppPriorityAborts;}
__declspec(dllexport) DWORD __stdcall AutoGather_GetForeignCastAborts(void){return g_foreignCastAborts;}
__declspec(dllexport) DWORD __stdcall AutoGather_GetPacketRewrites(void){return g_gatherPacketRewrites;}
__declspec(dllexport) DWORD __stdcall AutoGather_GetLootOpen(void){return GatherLootOpen();}
__declspec(dllexport) DWORD __stdcall AutoGather_GetLootSeenOpen(void){return g_gatherLootSeenOpen;}
__declspec(dllexport) DWORD __stdcall AutoGather_GetSawCast(void){return g_gatherSawCast;}
__declspec(dllexport) DWORD __stdcall AutoGather_GetProfMatchNodes(void){return g_gatherScanProfMatch;}
__declspec(dllexport) DWORD __stdcall AutoGather_GetInRangeNodes(void){return g_gatherScanInRange;}
__declspec(dllexport) DWORD __stdcall AutoGather_GetPosFailNodes(void){return g_gatherScanPosFail;}



__declspec(dllexport) DWORD __stdcall AutoPP_GetEnabled(void){return g_autoPPEnabled;}
__declspec(dllexport) DWORD __stdcall AutoPP_GetBlocked(void){return g_autoPPBlocked;}
__declspec(dllexport) DWORD __stdcall AutoPP_GetManualPass(void){return g_autoPPManualPass;}
__declspec(dllexport) DWORD __stdcall AutoPP_GetTargetPlayerBlocks(void){return g_autoPPTargetPlayerBlocks;}
__declspec(dllexport) DWORD __stdcall AutoPP_GetTargetIsPlayer(void){return CurrentTargetIsPlayer();}
__declspec(dllexport) DWORD __stdcall AutoPP_GetFailHookOk(void){return g_ppFailHookOk;}
__declspec(dllexport) DWORD __stdcall AutoPP_GetBlacklistCount(void){return g_ppBlackCount;}
__declspec(dllexport) DWORD __stdcall AutoPP_GetBlacklistAdds(void){return g_ppBlackAdds;}
__declspec(dllexport) DWORD __stdcall AutoPP_GetBlacklistBlocks(void){return g_ppBlackBlocks;}
__declspec(dllexport) DWORD __stdcall AutoPP_GetPendingSerialBlocks(void){return g_ppPendingSerialBlocks;}
__declspec(dllexport) DWORD __stdcall AutoPP_GetBlacklistDeathClears(void){return g_ppBlackDeathClears;}
__declspec(dllexport) DWORD __stdcall AutoPP_GetHardLOSArms(void){return g_ppHardLOSArms;}
__declspec(dllexport) DWORD __stdcall AutoPP_GetHardLOSLOSFailures(void){return g_ppHardLOSLOSFailures;}
__declspec(dllexport) DWORD __stdcall AutoPP_GetHardLOSOverrides(void){return g_ppHardLOSOverrides;}
__declspec(dllexport) DWORD __stdcall AutoPP_GetHardLOSRetrySent(void){return g_ppHardRetrySent;}
__declspec(dllexport) DWORD __stdcall AutoPP_GetHardLOSRetryExhausted(void){return g_ppHardRetryExhausted;}
__declspec(dllexport) DWORD __stdcall AutoPP_GetHardLOSRetryAttempts(void){return g_ppHardRetryAttempts;}
__declspec(dllexport) DWORD __stdcall PPIntegration_GetChainOk(void){return g_ppChainOk;}
__declspec(dllexport) DWORD __stdcall PPIntegration_GetLongPPActive(void){return LongPPActive();}
__declspec(dllexport) DWORD __stdcall PPIntegration_GetNextSendHook(void){return g_nextSendTarget;}
__declspec(dllexport) DWORD __stdcall PPIntegration_GetTxPreempts(void){return g_ppTxPreempts;}
__declspec(dllexport) DWORD __stdcall PPIntegration_GetStateYields(void){return g_ppStateYields;}
__declspec(dllexport) DWORD __stdcall PPIntegration_GetMoveBypasses(void){return g_ppMoveBypasses;}
__declspec(dllexport) DWORD __stdcall PPIntegration_GetForeignLootPauses(void){return g_foreignLootPauses;}
__declspec(dllexport) DWORD __stdcall PPIntegration_GetQuietRemaining(void){DWORD now=GT()?GT()():0u;return((LONG)(g_ppQuietUntil-now)>0)?(g_ppQuietUntil-now):0u;}
__declspec(dllexport) DWORD __stdcall PPIntegration_GetFastNoTouch(void){return g_ppFastNoTouch;}
__declspec(dllexport) DWORD __stdcall PPIntegration_GetRealResets(void){return g_ppRealResets;}
__declspec(dllexport) DWORD __stdcall PPIntegration_GetInjectYields(void){return g_ppInjectYields;}
__declspec(dllexport) DWORD __stdcall PPIntegration_GetNoFallYields(void){return g_ppNoFallYields;}
__declspec(dllexport) DWORD __stdcall PPIntegration_GetSafeBreakYields(void){return g_ppSafeBreakYields;}
__declspec(dllexport) DWORD __stdcall PPIntegration_GetMiningPriorityBlocks(void){return g_miningPriorityBlocks;}
__declspec(dllexport) DWORD __stdcall PPIntegration_GetMiningPriorityScans(void){return g_miningPriorityScans;}
__declspec(dllexport) DWORD __stdcall PPIntegration_GetMiningPriorityEntry(void){return g_miningPriorityEntry;}
__declspec(dllexport) DWORD __stdcall PPIntegration_GetMiningPriorityActive(void){DWORD now=GT()?GT()():0u;return MiningPriorityOwnsPP(now);}
__declspec(dllexport) DWORD __stdcall AutoGather_GetNoFallYields(void){return g_gatherNoFallYields;}
__declspec(dllexport) DWORD __stdcall AutoGather_GetStealthBreaks(void){return g_gatherStealthBreaks;}
__declspec(dllexport) DWORD __stdcall AutoGather_GetStealthWaits(void){return g_gatherStealthWaits;}
__declspec(dllexport) DWORD __stdcall AutoGather_GetStealthPending(void){return g_gatherStealthPending;}
__declspec(dllexport) DWORD __stdcall AutoGather_GetMining3DRetries(void){return g_mining3DRetries;}
__declspec(dllexport) DWORD __stdcall AutoGather_GetMining3DSweepsExhausted(void){return g_mining3DSweepsExhausted;}
__declspec(dllexport) DWORD __stdcall AutoGather_GetMining3DRetryIndex(void){return g_mining3DRetryIndex;}
__declspec(dllexport) DWORD __stdcall AutoGather_GetCombatMiningAllowed(void){return 1u;}
__declspec(dllexport) DWORD __stdcall AutoOpen_GetEnabled(void){return g_autoOpenEnabled;}
__declspec(dllexport) DWORD __stdcall AutoOpen_GetActive(void){return (g_gatherActive&&g_gatherKind==3u)?1u:0u;}
__declspec(dllexport) DWORD __stdcall AutoOpen_GetTargetEntry(void){return (g_gatherKind==3u)?g_gatherEntry:0u;}
BOOL __stdcall DllMain(HINSTANCE h,DWORD r,LPVOID x)
{
    (void)h;(void)x;
    if(r==DLL_PROCESS_ATTACH){if(!InstallUnified())return FALSE;}
    else if(r==DLL_PROCESS_DETACH)RemoveUnified();
    return TRUE;
}
