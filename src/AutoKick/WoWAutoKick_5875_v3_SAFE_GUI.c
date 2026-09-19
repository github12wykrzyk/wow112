/*
 * WoWAutoKick_5875_v3_SAFE_GUI.c
 *
 * World of Warcraft 1.12.1 build 5875, Windows x86 only.
 * New canonical project source derived from the preserved V2 AutoKick handoff,
 * with the unsafe raw target-pointer cache removed and current-repo safety
 * primitives/control ABI applied.
 *
 * V3 design:
 *   - normal casts: signature-guarded detour after SMSG_SPELL_START (0x131)
 *     has decoded caster GUID + spell id; only current selected target is latched;
 *   - channels: poll public UNIT_CHANNEL_SPELL on a FRESH GUID->object resolve;
 *   - no object pointer survives a timer tick;
 *   - world/BG transitions hard-reset state and require a reacquire grace period;
 *   - Kick is invoked on the UI thread through build-5875 FrameScript_Execute;
 *   - every patch/native primitive is signature/build guarded and DllMain always
 *     fails open (module inert) rather than preventing WoW from starting;
 *   - W112_CONTROL_API_V1 exposes live controls + diagnostics to WoWControlHub.
 */

#if !defined(_M_IX86) && !defined(__i386__)
#error WoWAutoKick is for World of Warcraft 1.12.1 build 5875 x86 only.
#endif

#include "../common/W112ControlAPI.h"

#if defined(_MSC_VER)
#define STDCALL   __stdcall
#define FASTCALL  __fastcall
#define DLLEXPORT __declspec(dllexport)
#pragma comment(linker, "/EXPORT:W112_Control_GetModuleV1=_W112_Control_GetModuleV1@0")
#pragma comment(linker, "/EXPORT:AutoKickV3_GetStatus=_AutoKickV3_GetStatus@0")
#pragma comment(linker, "/EXPORT:AutoKickV3_GetKickAttempts=_AutoKickV3_GetKickAttempts@0")
#pragma comment(linker, "/EXPORT:AutoKickV3_GetLastSpell=_AutoKickV3_GetLastSpell@0")
#else
#define STDCALL   __attribute__((stdcall))
#define FASTCALL  __attribute__((fastcall))
#define DLLEXPORT __attribute__((dllexport))
#endif

typedef unsigned char      u8;
typedef unsigned short     u16;
typedef unsigned int       u32;
typedef unsigned long long u64;
typedef signed int         s32;
typedef long               LONG32;
typedef u32                uptr32;
typedef int                BOOL32;
typedef void              *HANDLE32;
typedef void              *HWND32;
typedef u32                UINT32;
typedef u32                UINT_PTR32;

typedef void (STDCALL *TimerProc32)(HWND32,UINT32,UINT_PTR32,u32);
typedef UINT_PTR32 (STDCALL *SetTimerFn)(HWND32,UINT_PTR32,UINT32,TimerProc32);
typedef BOOL32 (STDCALL *KillTimerFn)(HWND32,UINT_PTR32);
typedef BOOL32 (STDCALL *VirtualProtectFn)(void*,u32,u32,u32*);
typedef BOOL32 (STDCALL *FlushInstructionCacheFn)(HANDLE32,const void*,u32);
typedef HANDLE32 (STDCALL *GetCurrentProcessFn)(void);
typedef u32 (STDCALL *GetTickCountFn)(void);
typedef u32 (FASTCALL *GetObjectByGuidFn)(u64 guid);
typedef BOOL32 (FASTCALL *FrameScriptExecuteFn)(const char *script,const char *scriptName);

#define TRUE32 1
#define FALSE32 0
#define DLL_PROCESS_DETACH 0u
#define DLL_PROCESS_ATTACH 1u
#define PAGE_EXECUTE_READWRITE 0x40u

#define VERSION_3_0 0x00030000u
#define TIMER_PERIOD_MS 10u
#define WORLD_REACQUIRE_MS 750u

#define SETTING_ENABLED           1u
#define SETTING_NORMAL_CASTS      2u
#define SETTING_CHANNELS          3u
#define SETTING_PLAYERS_ONLY      4u
#define SETTING_REACTION_DELAY_MS 5u
#define SETTING_DUP_GUARD_MS      6u
#define SETTING_STATUS            7u
#define SETTING_KICK_ATTEMPTS     8u
#define SETTING_LAST_SPELL        9u
#define SETTING_DROPS             10u

#define STATUS_DETACHED              0u
#define STATUS_INSTALLING            1u
#define STATUS_WAITING_WORLD         2u
#define STATUS_REACQUIRE             3u
#define STATUS_ACTIVE                4u
#define STATUS_DISABLED              5u
#define STATUS_HOOK_SIGNATURE_FAIL   6u
#define STATUS_BUILD_GUARD_FAIL      7u
#define STATUS_PATCH_FAIL            8u
#define STATUS_SETTIMER_MISSING      9u
#define STATUS_SETTIMER_FAILED      10u
#define STATUS_FRAMESCRIPT_MISMATCH 11u

#define ADDR_OBJMGR_GLOBAL          0x00B41414u
#define OFF_OM_LOCAL_GUID_LO        0x00C0u
#define OFF_OM_LOCAL_GUID_HI        0x00C4u
#define ADDR_SELECTED_GUID_LO       0x00B4E2D8u
#define ADDR_SELECTED_GUID_HI       0x00B4E2DCu
#define FN_GET_OBJECT_BY_GUID       0x00464870u
#define WOW_FRAMESCRIPT_EXECUTE     0x00704CD0u

#define ADDR_SPELL_START_HANDLER    0x006E7640u
#define ADDR_SPELL_START_HOOK       0x006E767Fu
#define ADDR_SPELL_START_CONTINUE   0x006E7686u

#define OFF_OBJ_DESCRIPTOR_PTR      0x0008u
#define OFF_OBJ_TYPE                0x0014u
#define OFF_OBJ_GUID_LO             0x0030u
#define OFF_OBJ_GUID_HI             0x0034u
#define TYPE_UNIT                   3u
#define TYPE_PLAYER                 4u
#define UNIT_CHANNEL_SPELL_INDEX    0x0090u

#define WOW_IAT_GETTICKCOUNT        0x007FF310u
#define WOW_IAT_FLUSHICACHE         0x007FF320u
#define WOW_IAT_VIRTUALPROTECT      0x007FF35Cu
#define WOW_IAT_GETCURRENTPROCESS   0x007FF390u
#define WOW_IAT_SETTIMER            0x007FF4F4u
#define WOW_IAT_KILLTIMER           0x007FF4F8u

#define REACTION_DELAY_MIN_MS 0
#define REACTION_DELAY_MAX_MS 500
#define REACTION_DELAY_STEP_MS 10
#define DUP_GUARD_MIN_MS 50
#define DUP_GUARD_MAX_MS 500
#define DUP_GUARD_STEP_MS 10

static const u8 g_hookOriginal[7] = {0x8B,0xC7,0x2D,0x31,0x01,0x00,0x00};
static const char g_kickLua[] =
    "if type(UnitExists)=='function' and type(UnitCanAttack)=='function' and "
    "type(CastSpellByName)=='function' and UnitExists('player') and UnitExists('target') "
    "and UnitCanAttack('player','target') then CastSpellByName('Kick') end";
static const char g_scriptName[] = "WoWAutoKickV3";

static volatile u32 g_installed = 0u;
static volatile UINT_PTR32 g_timerId = 0u;
static volatile u32 g_busy = 0u;
static volatile u32 g_status = STATUS_DETACHED;
static volatile u32 g_worldPresent = 0u;
static volatile u32 g_worldReadyAfter = 0u;

static volatile u32 g_cfgEnabled = 1u;
static volatile u32 g_cfgNormalCasts = 1u;
static volatile u32 g_cfgChannels = 1u;
static volatile u32 g_cfgPlayersOnly = 1u;
static volatile s32 g_cfgReactionDelayMs = 0;
static volatile s32 g_cfgDuplicateGuardMs = 120;

static volatile u32 g_pendingNormal = 0u;
static volatile u32 g_pendingGuidLo = 0u;
static volatile u32 g_pendingGuidHi = 0u;
static volatile u32 g_pendingSpell = 0u;

static volatile u32 g_queued = 0u;
static volatile u32 g_queueGuidLo = 0u;
static volatile u32 g_queueGuidHi = 0u;
static volatile u32 g_queueSpell = 0u;
static volatile u32 g_queueDue = 0u;

static volatile u32 g_lastChannelGuidLo = 0u;
static volatile u32 g_lastChannelGuidHi = 0u;
static volatile u32 g_lastChannelSpell = 0u;
static volatile u32 g_lastKickAttemptTick = 0u;
static volatile u32 g_lastKickSpell = 0u;

static volatile u32 g_normalEdges = 0u;
static volatile u32 g_channelEdges = 0u;
static volatile u32 g_kickAttempts = 0u;
static volatile u32 g_duplicateDrops = 0u;
static volatile u32 g_targetDrops = 0u;
static volatile u32 g_worldResets = 0u;
static volatile u32 g_luaFails = 0u;

static W112_ControlSettingV1 g_controlSettings[10];
static volatile u32 g_controlDescriptorReady = 0u;

static const W112_ControlEnumOptionV1 g_statusOptions[] = {
    {STATUS_DETACHED,"Detached"},
    {STATUS_INSTALLING,"Installing"},
    {STATUS_WAITING_WORLD,"Waiting world"},
    {STATUS_REACQUIRE,"World reacquire"},
    {STATUS_ACTIVE,"Active"},
    {STATUS_DISABLED,"Disabled"},
    {STATUS_HOOK_SIGNATURE_FAIL,"Hook signature fail"},
    {STATUS_BUILD_GUARD_FAIL,"Build guard fail"},
    {STATUS_PATCH_FAIL,"Patch fail"},
    {STATUS_SETTIMER_MISSING,"Timer missing"},
    {STATUS_SETTIMER_FAILED,"Timer failed"},
    {STATUS_FRAMESCRIPT_MISMATCH,"FrameScript mismatch"}
};

int _fltused = 0;

static u32 read_u32(uptr32 address){ return *(volatile u32 *)(uptr32)address; }
static void *load_iat_fn(uptr32 slot){ return (void *)(uptr32)read_u32(slot); }

static int valid_ptr(u32 p){ return p>=0x00010000u && p<=0x7FFE0000u && (p&3u)==0u; }

static int bytes_match(uptr32 address,const u8 *sig,u32 count)
{
    volatile const u8 *p=(volatile const u8 *)(uptr32)address;
    u32 i;
    for(i=0u;i<count;++i) if(p[i]!=sig[i]) return 0;
    return 1;
}

static int framescript_signature_ok(void)
{
    static const u8 sig[]={0x56,0x6A,0x00,0x8B,0xF1,0x52,0x56,0xE8};
    return bytes_match(WOW_FRAMESCRIPT_EXECUTE,sig,(u32)sizeof(sig));
}

static int getobject_signature_ok(void)
{
    static const u8 sig[]={0x55,0x8B,0xEC,0x8B,0x45,0x08,0x8B,0x4D,0x0C,0x8B,0xD0,0x0B,0xD1};
    return bytes_match(FN_GET_OBJECT_BY_GUID,sig,(u32)sizeof(sig));
}

static int spell_handler_signature_ok(void)
{
    static const u8 handlerSig[]={0x53,0x8B,0xDC,0x83,0xEC,0x08,0x83,0xE4};
    return bytes_match(ADDR_SPELL_START_HANDLER,handlerSig,(u32)sizeof(handlerSig));
}

static BOOL32 write_executable(void *dst,const void *src,u32 count)
{
    VirtualProtectFn vp=(VirtualProtectFn)load_iat_fn(WOW_IAT_VIRTUALPROTECT);
    FlushInstructionCacheFn fic=(FlushInstructionCacheFn)load_iat_fn(WOW_IAT_FLUSHICACHE);
    GetCurrentProcessFn gcp=(GetCurrentProcessFn)load_iat_fn(WOW_IAT_GETCURRENTPROCESS);
    u32 oldProt=0u,tmp=0u,i;
    u8 *d=(u8*)dst;
    const u8 *s=(const u8*)src;
    if(!vp||!fic||!gcp) return FALSE32;
    if(!vp(dst,count,PAGE_EXECUTE_READWRITE,&oldProt)) return FALSE32;
    for(i=0u;i<count;++i) d[i]=s[i];
    fic(gcp(),dst,count);
    vp(dst,count,oldProt,&tmp);
    return TRUE32;
}

static BOOL32 patch_jmp7(uptr32 site,uptr32 target)
{
    u8 p[7];
    LONG32 rel=(LONG32)(target-(site+5u));
    p[0]=0xE9u;
    p[1]=(u8)(rel&0xFF); p[2]=(u8)((rel>>8)&0xFF); p[3]=(u8)((rel>>16)&0xFF); p[4]=(u8)((rel>>24)&0xFF);
    p[5]=0x90u; p[6]=0x90u;
    return write_executable((void*)(uptr32)site,p,7u);
}

static u32 tick_now(void)
{
    GetTickCountFn fn=(GetTickCountFn)load_iat_fn(WOW_IAT_GETTICKCOUNT);
    return fn?fn():0u;
}

static u32 get_object(u32 lo,u32 hi)
{
    GetObjectByGuidFn fn;
    u64 guid;
    u32 obj;
    if((lo|hi)==0u || !getobject_signature_ok()) return 0u;
    guid=((u64)hi<<32)|(u64)lo;
    fn=(GetObjectByGuidFn)(uptr32)FN_GET_OBJECT_BY_GUID;
    obj=fn(guid);
    if(!valid_ptr(obj)) return 0u;
    if(read_u32(obj+OFF_OBJ_GUID_LO)!=lo || read_u32(obj+OFF_OBJ_GUID_HI)!=hi) return 0u;
    return obj;
}

static int world_ready(void)
{
    u32 mgr=read_u32(ADDR_OBJMGR_GLOBAL);
    u32 lo,hi,obj,typeId;
    if(!valid_ptr(mgr)) return 0;
    lo=read_u32(mgr+OFF_OM_LOCAL_GUID_LO);
    hi=read_u32(mgr+OFF_OM_LOCAL_GUID_HI);
    if((lo|hi)==0u) return 0;
    obj=get_object(lo,hi);
    if(!obj) return 0;
    typeId=read_u32(obj+OFF_OBJ_TYPE);
    return typeId==TYPE_PLAYER;
}

static void clear_transient_state(void)
{
    g_pendingNormal=0u;
    g_pendingGuidLo=0u; g_pendingGuidHi=0u; g_pendingSpell=0u;
    g_queued=0u; g_queueGuidLo=0u; g_queueGuidHi=0u; g_queueSpell=0u; g_queueDue=0u;
    g_lastChannelGuidLo=0u; g_lastChannelGuidHi=0u; g_lastChannelSpell=0u;
}

static int current_target_snapshot(u32 *outLo,u32 *outHi,u32 *outObj,u32 *outType)
{
    u32 lo=read_u32(ADDR_SELECTED_GUID_LO);
    u32 hi=read_u32(ADDR_SELECTED_GUID_HI);
    u32 obj,typeId;
    if((lo|hi)==0u) return 0;
    obj=get_object(lo,hi);
    if(!obj) return 0;
    typeId=read_u32(obj+OFF_OBJ_TYPE);
    if(typeId!=TYPE_UNIT && typeId!=TYPE_PLAYER) return 0;
    if(outLo)*outLo=lo; if(outHi)*outHi=hi; if(outObj)*outObj=obj; if(outType)*outType=typeId;
    return 1;
}

static u32 target_channel_spell(u32 lo,u32 hi,u32 *outType)
{
    u32 obj=get_object(lo,hi);
    u32 desc,typeId;
    if(!obj) return 0u;
    typeId=read_u32(obj+OFF_OBJ_TYPE);
    if(typeId!=TYPE_UNIT && typeId!=TYPE_PLAYER) return 0u;
    if(outType)*outType=typeId;
    desc=read_u32(obj+OFF_OBJ_DESCRIPTOR_PTR);
    if(!valid_ptr(desc)) return 0u;
    return read_u32(desc + UNIT_CHANNEL_SPELL_INDEX*4u);
}

static int execute_kick_lua(void)
{
    FrameScriptExecuteFn fn;
    if(!framescript_signature_ok()) return 0;
    fn=(FrameScriptExecuteFn)(uptr32)WOW_FRAMESCRIPT_EXECUTE;
    return fn(g_kickLua,g_scriptName)?1:0;
}

static void schedule_kick(u32 lo,u32 hi,u32 spell,u32 now)
{
    s32 delay=g_cfgReactionDelayMs;
    if(delay<REACTION_DELAY_MIN_MS) delay=REACTION_DELAY_MIN_MS;
    if(delay>REACTION_DELAY_MAX_MS) delay=REACTION_DELAY_MAX_MS;
    g_queueGuidLo=lo; g_queueGuidHi=hi; g_queueSpell=spell;
    g_queueDue=now+(u32)delay;
    g_queued=1u;
}

static void fire_queued_kick(u32 now)
{
    u32 lo,hi,obj,typeId;
    s32 guard;
    if(!g_queued) return;
    if((LONG32)(now-g_queueDue)<0) return;
    g_queued=0u;

    lo=read_u32(ADDR_SELECTED_GUID_LO);
    hi=read_u32(ADDR_SELECTED_GUID_HI);
    if(lo!=g_queueGuidLo || hi!=g_queueGuidHi){ ++g_targetDrops; return; }
    if(!current_target_snapshot(&lo,&hi,&obj,&typeId)){ ++g_targetDrops; return; }
    if(g_cfgPlayersOnly && typeId!=TYPE_PLAYER){ ++g_targetDrops; return; }

    guard=g_cfgDuplicateGuardMs;
    if(guard<DUP_GUARD_MIN_MS) guard=DUP_GUARD_MIN_MS;
    if(guard>DUP_GUARD_MAX_MS) guard=DUP_GUARD_MAX_MS;
    if(g_lastKickAttemptTick && (u32)(now-g_lastKickAttemptTick)<(u32)guard){ ++g_duplicateDrops; return; }

    if(!framescript_signature_ok()){
        g_status=STATUS_FRAMESCRIPT_MISMATCH;
        ++g_luaFails;
        return;
    }
    g_lastKickAttemptTick=now;
    g_lastKickSpell=g_queueSpell;
    ++g_kickAttempts;
    if(!execute_kick_lua()) ++g_luaFails;
}

static void poll_channel(u32 now)
{
    u32 lo,hi,obj,typeId,spell;
    if(!g_cfgChannels) return;
    if(!current_target_snapshot(&lo,&hi,&obj,&typeId)){
        g_lastChannelGuidLo=0u; g_lastChannelGuidHi=0u; g_lastChannelSpell=0u;
        return;
    }
    if(g_cfgPlayersOnly && typeId!=TYPE_PLAYER){
        g_lastChannelGuidLo=lo; g_lastChannelGuidHi=hi; g_lastChannelSpell=0u;
        return;
    }
    spell=target_channel_spell(lo,hi,&typeId);
    if(lo!=g_lastChannelGuidLo || hi!=g_lastChannelGuidHi){
        g_lastChannelGuidLo=lo; g_lastChannelGuidHi=hi; g_lastChannelSpell=0u;
    }
    if(!spell){ g_lastChannelSpell=0u; return; }
    if(spell!=g_lastChannelSpell){
        g_lastChannelSpell=spell;
        ++g_channelEdges;
        schedule_kick(lo,hi,spell,now);
    }
}

__declspec(naked) static void SpellStartDecodedHook(void)
{
    __asm {
        pushfd
        pushad
        cmp edi, 0x131
        jne hook_done
        cmp dword ptr [g_cfgEnabled], 0
        je hook_done
        cmp dword ptr [g_cfgNormalCasts], 0
        je hook_done
        mov eax, dword ptr [ebp-0x10]
        mov ecx, dword ptr [ebp-0x0C]
        cmp eax, dword ptr ds:[ADDR_SELECTED_GUID_LO]
        jne hook_done
        cmp ecx, dword ptr ds:[ADDR_SELECTED_GUID_HI]
        jne hook_done
        mov dword ptr [g_pendingGuidLo], eax
        mov dword ptr [g_pendingGuidHi], ecx
        mov edx, dword ptr [ebp-0x04]
        mov dword ptr [g_pendingSpell], edx
        mov dword ptr [g_pendingNormal], 1
        inc dword ptr [g_normalEdges]
    hook_done:
        popad
        popfd
        mov eax, edi
        sub eax, 0x131
        push ADDR_SPELL_START_CONTINUE
        ret
    }
}

static void STDCALL AutoKick_TimerProc(HWND32 hwnd,UINT32 msg,UINT_PTR32 timerId,u32 time)
{
    u32 now,lo,hi,spell;
    (void)hwnd;(void)msg;(void)timerId;(void)time;
    if(!g_installed || g_busy) return;
    g_busy=1u;
    now=tick_now();

    if(!world_ready()){
        if(g_worldPresent){ ++g_worldResets; clear_transient_state(); }
        g_worldPresent=0u;
        g_worldReadyAfter=0u;
        g_status=STATUS_WAITING_WORLD;
        g_busy=0u;
        return;
    }
    if(!g_worldPresent){
        g_worldPresent=1u;
        g_worldReadyAfter=now+WORLD_REACQUIRE_MS;
        clear_transient_state();
        g_status=STATUS_REACQUIRE;
        g_busy=0u;
        return;
    }
    if((LONG32)(now-g_worldReadyAfter)<0){
        g_status=STATUS_REACQUIRE;
        g_busy=0u;
        return;
    }

    if(!g_cfgEnabled){
        clear_transient_state();
        g_status=STATUS_DISABLED;
        g_busy=0u;
        return;
    }

    if(!framescript_signature_ok()){
        clear_transient_state();
        g_status=STATUS_FRAMESCRIPT_MISMATCH;
        g_busy=0u;
        return;
    }

    g_status=STATUS_ACTIVE;

    if(g_pendingNormal){
        lo=g_pendingGuidLo; hi=g_pendingGuidHi; spell=g_pendingSpell;
        g_pendingNormal=0u;
        schedule_kick(lo,hi,spell,now);
    }
    poll_channel(now);
    fire_queued_kick(now);
    g_busy=0u;
}

static BOOL32 install_module(void)
{
    SetTimerFn setTimer;
    g_status=STATUS_INSTALLING;
    if(!getobject_signature_ok() || !framescript_signature_ok() || !spell_handler_signature_ok()){
        g_status=STATUS_BUILD_GUARD_FAIL;
        return FALSE32;
    }
    if(!bytes_match(ADDR_SPELL_START_HOOK,g_hookOriginal,7u)){
        g_status=STATUS_HOOK_SIGNATURE_FAIL;
        return FALSE32;
    }
    if(!patch_jmp7(ADDR_SPELL_START_HOOK,(uptr32)SpellStartDecodedHook)){
        g_status=STATUS_PATCH_FAIL;
        return FALSE32;
    }
    setTimer=(SetTimerFn)load_iat_fn(WOW_IAT_SETTIMER);
    if(!setTimer){
        write_executable((void*)(uptr32)ADDR_SPELL_START_HOOK,g_hookOriginal,7u);
        g_status=STATUS_SETTIMER_MISSING;
        return FALSE32;
    }
    g_timerId=setTimer(0,0u,TIMER_PERIOD_MS,AutoKick_TimerProc);
    if(!g_timerId){
        write_executable((void*)(uptr32)ADDR_SPELL_START_HOOK,g_hookOriginal,7u);
        g_status=STATUS_SETTIMER_FAILED;
        return FALSE32;
    }
    g_installed=1u;
    g_status=STATUS_WAITING_WORLD;
    return TRUE32;
}

static void remove_module(void)
{
    KillTimerFn killTimer=(KillTimerFn)load_iat_fn(WOW_IAT_KILLTIMER);
    g_installed=0u;
    if(g_timerId && killTimer) killTimer(0,g_timerId);
    g_timerId=0u;
    if(*(volatile u8 *)(uptr32)ADDR_SPELL_START_HOOK==0xE9u){
        LONG32 rel=*(volatile LONG32 *)(uptr32)(ADDR_SPELL_START_HOOK+1u);
        uptr32 dst=ADDR_SPELL_START_HOOK+5u+(uptr32)rel;
        if(dst==(uptr32)SpellStartDecodedHook)
            write_executable((void*)(uptr32)ADDR_SPELL_START_HOOK,g_hookOriginal,7u);
    }
    clear_transient_state();
    g_status=STATUS_DETACHED;
}

static void init_setting(W112_ControlSettingV1 *s,w112_u32 id,const char *key,const char *label,w112_u32 type,w112_u32 flags)
{
    s->struct_size=(w112_u32)sizeof(W112_ControlSettingV1);
    s->setting_id=id; s->key=key; s->label=label; s->type=type; s->flags=flags;
    s->default_value.u32=0u; s->min_value.u32=0u; s->max_value.u32=0u; s->step.u32=0u;
    s->enum_options=0; s->enum_option_count=0u;
}

static void init_control_descriptor(void)
{
    W112_ControlSettingV1 *s;
    if(g_controlDescriptorReady) return;

    s=&g_controlSettings[0]; init_setting(s,SETTING_ENABLED,"enabled","Enabled",W112_CTL_BOOL,W112_CTL_LIVE); s->default_value.u32=1u; s->max_value.u32=1u; s->step.u32=1u;
    s=&g_controlSettings[1]; init_setting(s,SETTING_NORMAL_CASTS,"normal_casts","Normal casts",W112_CTL_BOOL,W112_CTL_LIVE); s->default_value.u32=1u; s->max_value.u32=1u; s->step.u32=1u;
    s=&g_controlSettings[2]; init_setting(s,SETTING_CHANNELS,"channels","Channels",W112_CTL_BOOL,W112_CTL_LIVE); s->default_value.u32=1u; s->max_value.u32=1u; s->step.u32=1u;
    s=&g_controlSettings[3]; init_setting(s,SETTING_PLAYERS_ONLY,"players_only","Players only",W112_CTL_BOOL,W112_CTL_LIVE); s->default_value.u32=1u; s->max_value.u32=1u; s->step.u32=1u;
    s=&g_controlSettings[4]; init_setting(s,SETTING_REACTION_DELAY_MS,"reaction_ms","Reaction delay ms",W112_CTL_INT,W112_CTL_LIVE); s->default_value.i32=0; s->min_value.i32=REACTION_DELAY_MIN_MS; s->max_value.i32=REACTION_DELAY_MAX_MS; s->step.i32=REACTION_DELAY_STEP_MS;
    s=&g_controlSettings[5]; init_setting(s,SETTING_DUP_GUARD_MS,"duplicate_ms","Duplicate guard ms",W112_CTL_INT,W112_CTL_LIVE); s->default_value.i32=120; s->min_value.i32=DUP_GUARD_MIN_MS; s->max_value.i32=DUP_GUARD_MAX_MS; s->step.i32=DUP_GUARD_STEP_MS;
    s=&g_controlSettings[6]; init_setting(s,SETTING_STATUS,"status","Status",W112_CTL_ENUM,W112_CTL_LIVE|W112_CTL_READ_ONLY); s->enum_options=g_statusOptions; s->enum_option_count=(w112_u32)(sizeof(g_statusOptions)/sizeof(g_statusOptions[0])); s->max_value.i32=STATUS_FRAMESCRIPT_MISMATCH;
    s=&g_controlSettings[7]; init_setting(s,SETTING_KICK_ATTEMPTS,"attempts","Kick attempts",W112_CTL_INT,W112_CTL_LIVE|W112_CTL_READ_ONLY); s->max_value.i32=0x7FFFFFFF;
    s=&g_controlSettings[8]; init_setting(s,SETTING_LAST_SPELL,"last_spell","Last spell ID",W112_CTL_INT,W112_CTL_LIVE|W112_CTL_READ_ONLY); s->max_value.i32=0x7FFFFFFF;
    s=&g_controlSettings[9]; init_setting(s,SETTING_DROPS,"drops","Drops",W112_CTL_INT,W112_CTL_LIVE|W112_CTL_READ_ONLY); s->max_value.i32=0x7FFFFFFF;
    g_controlDescriptorReady=1u;
}

static int W112_CTL_STDCALL autokick_control_get(w112_u32 id,W112_ControlValueV1 *out)
{
    if(!out) return 0;
    if(id==SETTING_ENABLED){ out->u32=g_cfgEnabled; return 1; }
    if(id==SETTING_NORMAL_CASTS){ out->u32=g_cfgNormalCasts; return 1; }
    if(id==SETTING_CHANNELS){ out->u32=g_cfgChannels; return 1; }
    if(id==SETTING_PLAYERS_ONLY){ out->u32=g_cfgPlayersOnly; return 1; }
    if(id==SETTING_REACTION_DELAY_MS){ out->i32=g_cfgReactionDelayMs; return 1; }
    if(id==SETTING_DUP_GUARD_MS){ out->i32=g_cfgDuplicateGuardMs; return 1; }
    if(id==SETTING_STATUS){ out->i32=(s32)g_status; return 1; }
    if(id==SETTING_KICK_ATTEMPTS){ out->u32=g_kickAttempts; return 1; }
    if(id==SETTING_LAST_SPELL){ out->u32=g_lastKickSpell; return 1; }
    if(id==SETTING_DROPS){ out->u32=g_targetDrops+g_duplicateDrops+g_luaFails; return 1; }
    return 0;
}

static int clamp_i32(s32 v,s32 lo,s32 hi){ if(v<lo)return lo; if(v>hi)return hi; return v; }

static int W112_CTL_STDCALL autokick_control_set(w112_u32 id,const W112_ControlValueV1 *value)
{
    if(!value) return 0;
    if(id==SETTING_ENABLED){ g_cfgEnabled=value->u32?1u:0u; if(!g_cfgEnabled)clear_transient_state(); return 1; }
    if(id==SETTING_NORMAL_CASTS){ g_cfgNormalCasts=value->u32?1u:0u; return 1; }
    if(id==SETTING_CHANNELS){ g_cfgChannels=value->u32?1u:0u; g_lastChannelSpell=0u; return 1; }
    if(id==SETTING_PLAYERS_ONLY){ g_cfgPlayersOnly=value->u32?1u:0u; return 1; }
    if(id==SETTING_REACTION_DELAY_MS){ g_cfgReactionDelayMs=clamp_i32(value->i32,REACTION_DELAY_MIN_MS,REACTION_DELAY_MAX_MS); return 1; }
    if(id==SETTING_DUP_GUARD_MS){ g_cfgDuplicateGuardMs=clamp_i32(value->i32,DUP_GUARD_MIN_MS,DUP_GUARD_MAX_MS); return 1; }
    return 0;
}

static const W112_ControlModuleV1 g_controlModule={
    W112_CONTROL_API_V1,
    (w112_u32)sizeof(W112_ControlModuleV1),
    "autokick",
    "AutoKick (target)",
    VERSION_3_0,
    10u,
    g_controlSettings,
    autokick_control_get,
    autokick_control_set
};

DLLEXPORT const W112_ControlModuleV1 * W112_CTL_STDCALL W112_Control_GetModuleV1(void)
{
    init_control_descriptor();
    return &g_controlModule;
}

DLLEXPORT u32 STDCALL AutoKickV3_GetStatus(void){ return g_status; }
DLLEXPORT u32 STDCALL AutoKickV3_GetKickAttempts(void){ return g_kickAttempts; }
DLLEXPORT u32 STDCALL AutoKickV3_GetLastSpell(void){ return g_lastKickSpell; }
DLLEXPORT u32 STDCALL AutoKickV3_GetNormalEdges(void){ return g_normalEdges; }
DLLEXPORT u32 STDCALL AutoKickV3_GetChannelEdges(void){ return g_channelEdges; }
DLLEXPORT u32 STDCALL AutoKickV3_GetWorldResets(void){ return g_worldResets; }

BOOL32 STDCALL DllMain(void *module,u32 reason,void *reserved)
{
    (void)module;(void)reserved;
    if(reason==DLL_PROCESS_ATTACH){
        init_control_descriptor();
        (void)install_module();
        return TRUE32;
    }
    if(reason==DLL_PROCESS_DETACH) remove_module();
    return TRUE32;
}
