/*
 * WoWAutoLootPP_v0_14_PP300YD_HU_ATTACKABLE_LEVELGATE3_NOSKIP_SELECTORCHECK_RECONSTRUCTED.c
 *
 * Target: World of Warcraft 1.12.1 build 5875, Windows x86.
 *
 * Classification:
 *   FUNCTIONALLY EQUIVALENT RECONSTRUCTION
 *
 * Evidence base:
 *   - final v0.14 DLL SHA256
 *     05f1e031008a2ecb7b88bd5028bc6877b220565e92dc4bd92bfb21a18357f845
 *   - exact preserved v0.13 DLL SHA256
 *     641b64187e387fabfea41426962734ff3c1e5d0c2bbc4652e7df823d51e20a73
 *   - v0.13 -> v0.14 differs at exactly 3 bytes, file offset 0x0F07:
 *       v0.13: 0F 93 C4    setae ah
 *       v0.14: 30 E4 90    xor ah,ah / nop
 *     VA 0x10001B07.  The patched term was (pp_send_count >= 1).
 *     v0.14 therefore no longer skips an otherwise valid tracked PP target
 *     merely because one send has already occurred.  The guid_hi==0 guard
 *     remains active.  This is the exact ONESHOT -> NOSKIP lineage change.
 *
 * This file is normal, buildable C intended for continued development.  It
 * is NOT claimed to be the original source and is not expected to rebuild
 * byte-for-byte with the historical MSVC toolchain.  Addresses, object
 * offsets, packet opcode/layout, hook site, selector gates and the NOSKIP
 * branch are taken from the final machine code.
 */

#if !defined(_M_IX86) && !defined(__i386__)
#error WoW 1.12.1 build 5875 module: x86 only
#endif

#if defined(_MSC_VER)
#define STDCALL   __stdcall
#define THISCALL  __thiscall
#define FASTCALL  __fastcall
#define CDECL     __cdecl
#define NAKED     __declspec(naked)
#define DLLEXPORT __declspec(dllexport)
#else
#define STDCALL   __attribute__((stdcall))
#define THISCALL  __attribute__((thiscall))
#define FASTCALL  __attribute__((fastcall))
#define CDECL     __attribute__((cdecl))
#define NAKED     __attribute__((naked))
#define DLLEXPORT __attribute__((dllexport))
#endif

typedef unsigned char  u8;
typedef unsigned short u16;
typedef unsigned int   u32;
typedef signed int     s32;
typedef u32            uptr;
typedef int            BOOL32;
typedef void          *HANDLE32;
typedef void          *HWND32;
typedef u32            UINT32;
typedef u32            UINT_PTR32;
typedef s32            NTSTATUS32;

#define TRUE32  1
#define FALSE32 0
#define DLL_PROCESS_DETACH 0u
#define DLL_PROCESS_ATTACH 1u

/* ---- WoW 1.12.1 build 5875 absolute addresses recovered from v0.14 ---- */
#define WOW_OBJECT_MANAGER_PTR      0x00B41414u
#define WOW_TARGET_GUID_LO          0x00B71B48u
#define WOW_TARGET_GUID_HI          0x00B71B4Cu
#define WOW_LOOT_WINDOW_FLAG        0x00B71B44u

#define WOW_SEND_PACKET_THIS        0x007FF9E4u
#define WOW_NET_SEND_FN             0x005AB630u
#define WOW_NATIVE_LOOT_ALL_FN      0x004C1FA0u
#define WOW_NATIVE_CLOSE_LOOT_FN    0x0048F200u
#define WOW_LOOT_OPEN_FN            0x004C2A70u
#define WOW_CREATURE_TYPE_FN        0x00605570u
#define WOW_ATTACKABLE_FN           0x00606980u

#define WOW_LOOT_ERROR_HOOK_SITE    0x005EBA07u
#define WOW_LOOT_ERROR_HOOK_RETURN  0x005EBA0Eu

/* ---- Object layout recovered from final code ---- */
#define OM_FIRST_OBJECT_OFF         0x00ACu
#define OM_PLAYER_GUID_LO_OFF       0x00C0u
#define OM_PLAYER_GUID_HI_OFF       0x00C4u

#define OBJ_DESCRIPTOR_OFF          0x0008u
#define OBJ_TYPE_OFF                0x0014u
#define OBJ_GUID_LO_OFF             0x0030u
#define OBJ_GUID_HI_OFF             0x0034u
#define OBJ_NEXT_OFF                0x003Cu
#define OBJ_UNIT_AUX_OFF            0x0110u
#define OBJ_X_OFF                   0x09B8u
#define OBJ_Y_OFF                   0x09BCu
#define OBJ_Z_OFF                   0x09C0u

#define DESC_HEALTH_OFF             0x0058u
#define DESC_BOUNDING_RADIUS_OFF    0x0208u
#define DESC_PP_LIFE_MARKER_OFF     0x1260u
#define AUX_LEVEL_OFF               0x0070u

#define WOW_OBJECT_UNIT             3u
#define CREATURE_TYPE_HUMANOID      7u
#define CREATURE_TYPE_UNDEAD        6u

#define PP_SCAN_RANGE2              90000.0f /* 300 yd squared */
#define PP_RANGE2                   PP_SCAN_RANGE2
#define PP_SCAN_MS                  100u
#define WORLD_SCAN_MS               80u
#define TIMER_PERIOD_MS             5u
#define LOOT_OPEN_TIMEOUT_MS        450u
#define DRAIN_RETRY_MS               50u
#define MAX_DRAIN_PASSES              20u
#define TOO_FAR_RETRY_MS            120u
#define CORPSE_COOLDOWN_MS          1500u
#define MAX_OBJECT_STEPS            0x1000u
#define MAX_PP_ATTEMPTS             3u
#define MAX_BACKOFF                 32u
#define MAX_CORPSE_QUEUE            16u

#define PP_OPCODE                   0x012Eu
#define PP_SUBOP                    0x0399u
#define PP_PACKET_KIND              0x0002u

#define GENERIC_WRITE32          0x40000000u
#define FILE_SHARE_RW32          0x00000003u
#define OPEN_ALWAYS32            4u
#define FILE_ATTRIBUTE_NORMAL32  0x00000080u
#define FILE_END32               2u
#define PAGE_EXECUTE_READWRITE32 0x40u
#define INVALID_HANDLE32         ((HANDLE32)(uptr)0xFFFFFFFFu)

/* APIs are resolved from loaded PE export tables, matching the importless DLL. */
typedef HANDLE32 (STDCALL *CreateFileAFn)(const char*,u32,u32,void*,u32,u32,HANDLE32);
typedef BOOL32   (STDCALL *WriteFileFn)(HANDLE32,const void*,u32,u32*,void*);
typedef BOOL32   (STDCALL *CloseHandleFn)(HANDLE32);
typedef UINT_PTR32 (STDCALL *SetTimerFn)(HWND32,UINT_PTR32,UINT32,void*);
typedef BOOL32   (STDCALL *KillTimerFn)(HWND32,UINT_PTR32);
typedef NTSTATUS32 (STDCALL *NtProtectVirtualMemoryFn)(HANDLE32,void**,u32*,u32,u32*);

typedef void (THISCALL *NetSendFn)(void *send_desc);
typedef void (THISCALL *LootAllFn)(u32 one);
typedef void (FASTCALL *CloseLootFn)(u32 one,u32 zero,void *nil);
typedef int  (THISCALL *CreatureTypeFn)(void *unit);
typedef int  (STDCALL *AttackableFn)(void *unit);

typedef struct Guid64 {
    u32 lo;
    u32 hi;
} Guid64;

typedef struct CooldownEntry {
    Guid64 guid;
    u32 until_tick;
    u32 failures;
    u32 reserved;
} CooldownEntry;

typedef struct PickPocketTrack {
    Guid64 guid;
    u32 send_count;       /* exact global represented by final VA 0x1000EAE4 */
    u32 life_marker;      /* snapshot from descriptor + 0x1260 */
    u32 send_tick;
    u8  active;
} PickPocketTrack;

typedef struct SendDesc {
    u8 *packet;
    u32 zero0;
    u32 capacity;
    u32 length;
    u32 zero1;
} SendDesc;

typedef enum LootState {
    LOOT_IDLE = 0,
    LOOT_WAIT_OPEN = 1,
    LOOT_DRAINING = 2
} LootState;

static CreateFileAFn g_CreateFileA;
static WriteFileFn g_WriteFile;
static CloseHandleFn g_CloseHandle;
static SetTimerFn g_SetTimer;
static KillTimerFn g_KillTimer;
static NtProtectVirtualMemoryFn g_NtProtectVirtualMemory;

static HANDLE32 g_log;
static UINT_PTR32 g_timer;
static PickPocketTrack g_pp;
static CooldownEntry g_backoff[MAX_BACKOFF];
static u32 g_backoff_cursor;
static u32 g_pp_scan_tick;
static u32 g_world_scan_tick;
static LootState g_loot_state;
static Guid64 g_loot_guid;
static u32 g_loot_state_tick;
static u32 g_drain_pass;
static u32 g_server_error_code;
static u32 g_server_error_tick;
static u8 g_hook_original[7];
static u8 g_hook_installed;

static const char kLogName[] = "WoWAutoLootPP_v0_9_FullDrain_ServerAware.log";
static const char kLoad[] = "LOAD WoWAutoLootPP v0.9 FullDrain ServerAware";
static const char kReady[] = "READY WoWAutoLootPP v0.9 full_drain=1 native_lootall=0x4C1FA0 native_close=0x48F200 exact_reach=1 request_margin_yd=0.65 server_loot_error_hook=1 too_far_retry_ms=120 too_far_burst=8 world_scan_ms=80 open_timeout_ms=450 corpse_queue=16 nearest_first=1 target_required=0 mouseover_required=0 per_guid_backoff=1 fresh_corpse_tracking=1 drain_retries=20 drain_retry_ms=50 fullbag_locked_release=1 pp_proximity=1 pp_range_yd=4.5 pp_full_drain=1 pp_respawn_aware=1 pp_life_scan_ms=100 pp_reset=hp0_to_alive|reappear|ptr_change corpse_range_reenter_reset=1 out_of_range_abort_no_backoff=1 corpse_priority_over_pp=1";

static u32 read_u32(uptr a){ return *(volatile u32*)a; }
static u16 read_u16(uptr a){ return *(volatile u16*)a; }
static u8  read_u8 (uptr a){ return *(volatile u8*)a; }
static float read_f32(uptr a){ return *(volatile float*)a; }
static void write_u8(uptr a,u8 v){ *(volatile u8*)a=v; }

static int sane_ptr(uptr p){ return p>=0x10000u && p<0x7FFE0000u && !(p&1u); }
static int guid_eq(Guid64 a,Guid64 b){ return a.lo==b.lo && a.hi==b.hi; }
static int guid_zero(Guid64 g){ return (g.lo|g.hi)==0u; }

/* The stock 1.12.1 casting bar also tracks game-object interactions (AB flags).
   Read only on a prospective auto-PP send, never from a packet hook. */
static int W112_PlayerActionActive(void)
{
    static const char script[] =
        "W112_PP_ACTION_BUSY='0';"
        "if CastingBarFrame and (CastingBarFrame.casting or CastingBarFrame.channeling) then W112_PP_ACTION_BUSY='1' end";
    typedef void (FASTCALL *FrameScriptExecuteFn)(const char*,const char*);
    typedef const char* (FASTCALL *FrameScriptGetTextFn)(const char*,int,u32);
    const char *value;
    /* Do not send a new PP while the native client has a pending spell. */
    if(read_u32(0x00CECA88u))return 1;
    ((FrameScriptExecuteFn)(uptr)0x00704CD0u)(script,script);
    value=((FrameScriptGetTextFn)(uptr)0x00703BF0u)("W112_PP_ACTION_BUSY",-1,0u);
    return value && value[0]=='1' && value[1]==0;
}

/* Minimal PEB/LDR export resolver: no normal PE import table is required. */
static int str_eq(const char *a,const char *b){while(*a&&*b){if(*a++!=*b++)return 0;}return *a==*b;}
static int wide_ascii_eq(const u16 *w,u16 bytes,const char *s)
{
    u32 i,n=(u32)bytes/2u;
    for(i=0;i<n;i++){
        char wc=(char)(w[i]&0xFFu),sc=s[i];
        if(sc==0)return 0;
        if(wc>='A'&&wc<='Z')wc=(char)(wc+32);
        if(sc>='A'&&sc<='Z')sc=(char)(sc+32);
        if(wc!=sc)return 0;
    }
    return s[n]==0;
}

#if defined(_MSC_VER)
static uptr get_peb(void)
{
    uptr peb;
# if defined(__clang__)
    __asm mov eax, fs:[30h]
    __asm mov peb, eax
# else
    __asm mov eax, fs:[30h]
    __asm mov peb, eax
# endif
    return peb;
}
#else
static uptr get_peb(void){uptr p;__asm__ __volatile__("movl %%fs:0x30,%0":"=r"(p));return p;}
#endif

static uptr find_module_base(const char *lower_name)
{
    uptr peb=get_peb(),ldr,node,head;
    if(!sane_ptr(peb))return 0;
    ldr=read_u32(peb+0x0Cu); if(!sane_ptr(ldr))return 0;
    head=ldr+0x14u; node=read_u32(head);
    while(sane_ptr(node)&&node!=head){
        uptr entry=node-0x08u;
        u16 len=read_u16(entry+0x2Cu);
        uptr buf=read_u32(entry+0x30u);
        if(sane_ptr(buf)&&wide_ascii_eq((const u16*)buf,len,lower_name))return read_u32(entry+0x18u);
        node=read_u32(node);
    }
    return 0;
}

static uptr find_export(uptr base,const char *name)
{
    u8 *b=(u8*)base;u32 pe,erva,esz,n,i;u8 *e;u32 *func,*names;u16 *ords;
    if(!sane_ptr(base)||*(u16*)b!=0x5A4Du)return 0;
    pe=*(u32*)(b+0x3Cu);if(*(u32*)(b+pe)!=0x00004550u)return 0;
    erva=*(u32*)(b+pe+0x78u);esz=*(u32*)(b+pe+0x7Cu);if(!erva)return 0;
    e=b+erva;n=*(u32*)(e+0x18u);func=(u32*)(b+*(u32*)(e+0x1Cu));names=(u32*)(b+*(u32*)(e+0x20u));ords=(u16*)(b+*(u32*)(e+0x24u));
    for(i=0;i<n;i++){
        const char *s=(const char*)(b+names[i]);
        if(str_eq(s,name)){
            u32 rva=func[ords[i]];
            if(rva>=erva&&rva<erva+esz)return 0;
            return base+rva;
        }
    }
    return 0;
}

static void resolve_apis(void)
{
    uptr k=find_module_base("kernel32.dll"),n=find_module_base("ntdll.dll");
    if(k){
        g_CreateFileA=(CreateFileAFn)find_export(k,"CreateFileA");
        g_WriteFile=(WriteFileFn)find_export(k,"WriteFile");
        g_CloseHandle=(CloseHandleFn)find_export(k,"CloseHandle");
        g_SetTimer=(SetTimerFn)find_export(k,"SetTimer");
        g_KillTimer=(KillTimerFn)find_export(k,"KillTimer");
    }
    if(n)g_NtProtectVirtualMemory=(NtProtectVirtualMemoryFn)find_export(n,"NtProtectVirtualMemory");
}

static u32 cstrlen(const char *s){u32 n=0;while(s[n])n++;return n;}
static char *append_str(char *p,const char *s){while(*s)*p++=*s++;return p;}
static char *append_u32(char *p,u32 v){char t[16];u32 n=0;if(!v){*p++='0';return p;}while(v){u32 q=v/10;t[n++]=(char)('0'+v-q*10);v=q;}while(n)*p++=t[--n];return p;}
static char *append_hex(char *p,u32 v){static const char h[]="0123456789ABCDEF";int s;*p++='0';*p++='x';for(s=28;s>=0;s-=4)*p++=h[(v>>s)&15];return p;}

static void log_line(const char *event,const char *source,Guid64 g,u32 a,u32 b)
{
    char buf[320]; char *p=buf; u32 wr=0;
    if(!g_CreateFileA||!g_WriteFile||!g_CloseHandle) return;
    if(!g_log || g_log==INVALID_HANDLE32)
        g_log=g_CreateFileA(kLogName,GENERIC_WRITE32,FILE_SHARE_RW32,0,OPEN_ALWAYS32,FILE_ATTRIBUTE_NORMAL32,0);
    if(!g_log || g_log==INVALID_HANDLE32) return;
    p=append_str(p,event);
    if(source){p=append_str(p," source=");p=append_str(p,source);}
    p=append_str(p," a=");p=append_u32(p,a);
    p=append_str(p," b=");p=append_u32(p,b);
    p=append_str(p," guid_lo=");p=append_hex(p,g.lo);
    p=append_str(p," guid_hi=");p=append_hex(p,g.hi);
    *p++='\r';*p++='\n';
    g_WriteFile(g_log,buf,(u32)(p-buf),&wr,0);
}

static void log_text(const char *s)
{
    Guid64 z; z.lo=0u; z.hi=0u; log_line(s,0,z,0,0);
}

static uptr object_manager(void){return read_u32(WOW_OBJECT_MANAGER_PTR);}
static Guid64 object_guid(uptr o){Guid64 g={read_u32(o+OBJ_GUID_LO_OFF),read_u32(o+OBJ_GUID_HI_OFF)};return g;}
static Guid64 target_guid(void){Guid64 g={read_u32(WOW_TARGET_GUID_LO),read_u32(WOW_TARGET_GUID_HI)};return g;}
static uptr descriptor(uptr o){uptr p=read_u32(o+OBJ_DESCRIPTOR_OFF);return sane_ptr(p)?p:0;}
static uptr unit_aux(uptr o){uptr p=read_u32(o+OBJ_UNIT_AUX_OFF);return sane_ptr(p)?p:0;}

static Guid64 player_guid(void)
{
    uptr om=object_manager();Guid64 z={0,0};if(!sane_ptr(om))return z;
    z.lo=read_u32(om+OM_PLAYER_GUID_LO_OFF);z.hi=read_u32(om+OM_PLAYER_GUID_HI_OFF);return z;
}

static uptr find_object(Guid64 g)
{
    uptr om=object_manager(),o;u32 guard=MAX_OBJECT_STEPS;
    if(!sane_ptr(om)||guid_zero(g))return 0;
    o=read_u32(om+OM_FIRST_OBJECT_OFF);
    while(guard--&&sane_ptr(o)){
        if(guid_eq(object_guid(o),g))return o;
        {uptr n=read_u32(o+OBJ_NEXT_OFF);if(n==o)break;o=n;}
    }
    return 0;
}

static uptr find_player(void){return find_object(player_guid());}
static u32 unit_level(uptr o){uptr a=unit_aux(o);return a?read_u32(a+AUX_LEVEL_OFF):0u;}
static int alive(uptr o){uptr d=descriptor(o);return d&&read_u32(d+DESC_HEALTH_OFF)!=0u;}
static int creature_type(uptr o){return ((CreatureTypeFn)(uptr)WOW_CREATURE_TYPE_FN)((void*)o);}
static int attackable(uptr o){return ((AttackableFn)(uptr)WOW_ATTACKABLE_FN)((void*)o)!=0;}

static float dist2(uptr a,uptr b)
{
    float x=read_f32(a+OBJ_X_OFF)-read_f32(b+OBJ_X_OFF);
    float y=read_f32(a+OBJ_Y_OFF)-read_f32(b+OBJ_Y_OFF);
    float z=read_f32(a+OBJ_Z_OFF)-read_f32(b+OBJ_Z_OFF);
    return x*x+y*y+z*z;
}

static int cooldown_active(Guid64 g,u32 now)
{
    u32 i;for(i=0;i<MAX_BACKOFF;i++)if(guid_eq(g_backoff[i].guid,g)&&g_backoff[i].until_tick>now)return 1;return 0;
}

static void pp_set_backoff(Guid64 g,u32 now,u32 failures)
{
    CooldownEntry *e=&g_backoff[g_backoff_cursor++%MAX_BACKOFF];
    e->guid=g;e->failures=failures;e->until_tick=now+300u+(failures*150u);e->reserved=0;
}

static uptr select_pp_target(uptr player,u32 now,float *out_d2)
{
    uptr om=object_manager(),o,best=0;u32 guard=MAX_OBJECT_STEPS;float bestd=PP_RANGE2+1.0f;u32 plvl=unit_level(player);
    if(!sane_ptr(om)||!player)return 0;
    o=read_u32(om+OM_FIRST_OBJECT_OFF);
    while(guard--&&sane_ptr(o)){
        if(read_u32(o+OBJ_TYPE_OFF)==WOW_OBJECT_UNIT&&alive(o)){
            int ct=creature_type(o);
            if((ct==CREATURE_TYPE_HUMANOID||ct==CREATURE_TYPE_UNDEAD)&&attackable(o)){
                u32 lvl=unit_level(o);Guid64 g=object_guid(o);float d=dist2(player,o);
                if(lvl<plvl+3u && d<=PP_RANGE2 && !cooldown_active(g,now) && d<bestd){best=o;bestd=d;}
            }
        }
        {uptr n=read_u32(o+OBJ_NEXT_OFF);if(n==o)break;o=n;}
    }
    if(best&&out_d2)*out_d2=bestd;
    return best;
}

/* Exact semantic form of the v0.14 patched branch at VA 0x10001B07. */
static int pp_tracked_target_should_skip(Guid64 tracked)
{
    /* v0.13: return tracked.hi==0 || g_pp.send_count>=1; */
    /* v0.14 NOSKIP: the send_count term is forcibly zeroed in machine code. */
    return tracked.hi==0u;
}

static u32 pack_guid(u8 *dst,Guid64 g)
{
    u8 bytes[8];u8 mask=0;u32 i,n=1;
    bytes[0]=(u8)(g.lo);bytes[1]=(u8)(g.lo>>8);bytes[2]=(u8)(g.lo>>16);bytes[3]=(u8)(g.lo>>24);
    bytes[4]=(u8)(g.hi);bytes[5]=(u8)(g.hi>>8);bytes[6]=(u8)(g.hi>>16);bytes[7]=(u8)(g.hi>>24);
    for(i=0;i<8;i++)if(bytes[i])mask|=(u8)(1u<<i);
    dst[0]=mask;
    for(i=0;i<8;i++)if(bytes[i])dst[n++]=bytes[i];
    return n;
}

/* Reconstructed packet sender at 0x10004B60. */
static void send_pickpocket(uptr player,uptr target,u32 now,float d2)
{
    u8 packet[64];u32 n=0;Guid64 g=object_guid(target);uptr d=descriptor(target);SendDesc sd;
    *(u32*)(packet+n)=PP_OPCODE;n+=4;
    *(u32*)(packet+n)=PP_SUBOP;n+=4;
    *(u16*)(packet+n)=PP_PACKET_KIND;n+=2;
    n+=pack_guid(packet+n,g);
    sd.packet=packet;sd.zero0=0u;sd.capacity=0x40u;sd.length=n;sd.zero1=0u;
    ((NetSendFn)(uptr)WOW_NET_SEND_FN)((void*)&sd);
    g_pp.guid=g;g_pp.send_count++;g_pp.life_marker=d?read_u32(d+DESC_PP_LIFE_MARKER_OFF):0u;g_pp.send_tick=now;g_pp.active=1;
    log_line(g_pp.send_count==1u?"AUTO_PP_SEND_SCAN":"AUTO_PP_RETRY_SCAN","scan",g,g_pp.send_count,*(u32*)&d2);
    (void)player;
}

static void pp_reset(void){g_pp.guid.lo=g_pp.guid.hi=0;g_pp.send_count=0;g_pp.life_marker=0;g_pp.send_tick=0;g_pp.active=0;}

static int has_stealth_aura(uptr o)
{
    /* Kept as a conservative descriptor scan helper for development. The final
       selector does not use Retail aura API and never depends on modern API. */
    uptr d=descriptor(o);u32 off;if(!d)return 0;
    for(off=0xBCu;off<=0x178u;off+=4u){u32 id=read_u32(d+off);if((id>=1784u&&id<=1787u)||id==11327u||id==11329u)return 1;}
    return 0;
}

static void service_pickpocket(uptr player,u32 now)
{
    uptr target;float d2=0.0f;
    if(g_loot_state!=LOOT_IDLE)return; /* final runtime gives corpses priority over PP */

    if(g_pp.active){
        uptr o=find_object(g_pp.guid);
        if(!o){log_line("AUTO_PP_RESPAWN_RESET","pickpocket",g_pp.guid,0,0);pp_reset();}
        else if(pp_tracked_target_should_skip(g_pp.guid))pp_reset();
        else {
            uptr d=read_u32(o+OBJ_DESCRIPTOR_OFF);u32 life=sane_ptr(d)?read_u32(d+DESC_PP_LIFE_MARKER_OFF):0u;
            if(g_pp.life_marker==0u && life!=0u){log_line("AUTO_PP_RESPAWN_RESET","pickpocket",g_pp.guid,0,life);pp_reset();}
            else if(now-g_pp.send_tick>=350u){
                if(g_pp.send_count<MAX_PP_ATTEMPTS){
                    if(W112_PlayerActionActive()){g_pp.send_tick=now;return;}
                    send_pickpocket(player,o,now,dist2(player,o));
                }
                else {log_line("AUTO_PP_GIVEUP","pickpocket",g_pp.guid,g_pp.send_count,0);pp_set_backoff(g_pp.guid,now,g_pp.send_count);pp_reset();}
            }
            /* If stealth disappears the final scanner still keeps the tracked GUID; no
               synthetic success is invented here.  Loot/money confirmation paths clear it. */
            return;
        }
    }

    if(now-g_pp_scan_tick<PP_SCAN_MS)return;
    g_pp_scan_tick=now;
    target=select_pp_target(player,now,&d2);
    if(!target)return;
    if(W112_PlayerActionActive())return;
    g_pp.send_count=0;
    log_line("AUTO_PP_READY_SCAN","scan",object_guid(target),0,0);
    send_pickpocket(player,target,now,d2);
}

static void native_loot_all(void){((LootAllFn)(uptr)WOW_NATIVE_LOOT_ALL_FN)(1u);}
static void native_close_loot(void){((CloseLootFn)(uptr)WOW_NATIVE_CLOSE_LOOT_FN)(1u,0u,0);}
static int loot_window_open(void){typedef int (CDECL *Fn)(void);return ((Fn)(uptr)WOW_LOOT_OPEN_FN)()!=0;}

/*
 * Full-drain controller reconstructed from state transitions and embedded
 * timing constants.  The final binary contains additional fixed-size history
 * bookkeeping used for diagnostics/backoff; this source keeps the same
 * externally visible state transitions without pretending the compiler layout
 * is original source.
 */
static void service_loot(u32 now)
{
    if(g_loot_state==LOOT_WAIT_OPEN){
        if(loot_window_open()){
            log_line("LOOT_OPEN","scan",g_loot_guid,g_drain_pass,g_server_error_code);
            native_loot_all();g_drain_pass=1;g_loot_state=LOOT_DRAINING;g_loot_state_tick=now;
            log_line("LOOT_DRAIN_PASS","scan",g_loot_guid,g_drain_pass,g_server_error_code);
        }else if(now-g_loot_state_tick>=LOOT_OPEN_TIMEOUT_MS){
            log_line("LOOT_OPEN_TIMEOUT","scan",g_loot_guid,LOOT_OPEN_TIMEOUT_MS,0);
            g_loot_state=LOOT_IDLE;
        }
    }else if(g_loot_state==LOOT_DRAINING){
        if(!loot_window_open()){
            log_line("LOOT_DONE_RELEASED","scan",g_loot_guid,g_drain_pass,0);
            g_loot_state=LOOT_IDLE;g_loot_guid.lo=g_loot_guid.hi=0;
        }else if(now-g_loot_state_tick>=DRAIN_RETRY_MS){
            if(g_drain_pass<MAX_DRAIN_PASSES){native_loot_all();g_drain_pass++;g_loot_state_tick=now;log_line("LOOT_DRAIN_PASS","scan",g_loot_guid,g_drain_pass,g_server_error_code);}
            else {native_close_loot();log_line("LOOT_DRAIN_TIMEOUT_RELEASE","scan",g_loot_guid,g_drain_pass,0);g_loot_state=LOOT_IDLE;}
        }
    }
}

/* Hook-side error capture, called with values taken from original stack frame. */
void CDECL loot_error_capture(u32 guid_lo,u32 guid_hi,u32 error_code)
{
    Guid64 g={guid_lo,guid_hi};
    if(g_loot_state==LOOT_WAIT_OPEN || g_loot_state==LOOT_DRAINING){
        if(guid_eq(g,g_loot_guid)){g_server_error_code=error_code;log_line("LOOT_SERVER_ERROR","scan",g,error_code,0);}
    }
}

#if defined(_MSC_VER) && !defined(__clang__)
static NAKED void LootErrorHookStub(void)
{
    __asm {
        pushfd
        pushad
        mov eax,[ebp-14h]
        mov edx,[ebp-10h]
        movzx ecx,byte ptr [ebp+0Fh]
        push ecx
        push edx
        push eax
        call loot_error_capture
        add esp,0Ch
        popad
        popfd
        movzx eax,byte ptr [ebp+0Fh]
        add eax,-4
        mov edx,WOW_LOOT_ERROR_HOOK_RETURN
        jmp edx
    }
}
#else
static NAKED void LootErrorHookStub(void)
{
    __asm__ __volatile__(
        "pushfl\n\t"
        "pushal\n\t"
        "movl -0x14(%%ebp),%%eax\n\t"
        "movl -0x10(%%ebp),%%edx\n\t"
        "movzbl 0x0F(%%ebp),%%ecx\n\t"
        "pushl %%ecx\n\t"
        "pushl %%edx\n\t"
        "pushl %%eax\n\t"
        "call _loot_error_capture\n\t"
        "addl $12,%%esp\n\t"
        "popal\n\t"
        "popfl\n\t"
        "movzbl 0x0F(%%ebp),%%eax\n\t"
        "addl $-4,%%eax\n\t"
        "movl $0x005EBA0E,%%edx\n\t"
        "jmp *%%edx\n\t" ::: "memory");
}
#endif

static int protect_rw_exec(uptr addr,u32 size,u32 *oldp)
{
    void *base=(void*)addr;u32 region=size;
    if(!g_NtProtectVirtualMemory)return 0;
    return g_NtProtectVirtualMemory((HANDLE32)(uptr)0xFFFFFFFFu,&base,&region,PAGE_EXECUTE_READWRITE32,oldp)>=0;
}

static int install_loot_error_hook(void)
{
    static const u8 expected[7]={0x0F,0xB6,0x45,0x0F,0x83,0xC0,0xFC};
    uptr p=WOW_LOOT_ERROR_HOOK_SITE;u32 oldp=0,dummy=0,i;u32 rel;
    for(i=0;i<7;i++){g_hook_original[i]=read_u8(p+i);if(g_hook_original[i]!=expected[i])return 0;}
    if(!protect_rw_exec(p,7,&oldp))return 0;
    rel=(u32)((uptr)&LootErrorHookStub-(p+5u));
    write_u8(p,0xE9);*(volatile u32*)(p+1u)=rel;write_u8(p+5u,0x90);write_u8(p+6u,0x90);
    {void *base=(void*)p;u32 region=7;if(g_NtProtectVirtualMemory)g_NtProtectVirtualMemory((HANDLE32)(uptr)0xFFFFFFFFu,&base,&region,oldp,&dummy);}
    g_hook_installed=1;return 1;
}

static void remove_loot_error_hook(void)
{
    uptr p=WOW_LOOT_ERROR_HOOK_SITE;u32 oldp=0,dummy=0,i;if(!g_hook_installed)return;
    if(protect_rw_exec(p,7,&oldp)){
        for(i=0;i<7;i++)write_u8(p+i,g_hook_original[i]);
        {void *base=(void*)p;u32 region=7;if(g_NtProtectVirtualMemory)g_NtProtectVirtualMemory((HANDLE32)(uptr)0xFFFFFFFFu,&base,&region,oldp,&dummy);}
    }
    g_hook_installed=0;
}

static void begin_loot(Guid64 g,u32 now)
{
    g_loot_guid=g;g_loot_state=LOOT_WAIT_OPEN;g_loot_state_tick=now;g_drain_pass=0;g_server_error_code=0;
    log_line("LOOT_REQUEST","scan",g,0,0);
}

static void STDCALL timer_proc(HWND32 hwnd,UINT32 msg,UINT_PTR32 id,u32 now)
{
    uptr player=find_player();(void)hwnd;(void)msg;(void)id;
    if(!player)return;
    service_loot(now);
    service_pickpocket(player,now);
}

BOOL32 STDCALL DllMain(void *module,u32 reason,void *reserved)
{
    (void)module;(void)reserved;
    if(reason==DLL_PROCESS_ATTACH){
        resolve_apis();
        log_text(kLoad);
        if(install_loot_error_hook())log_text("LOOT_ERROR_HOOK_OK site=0x5EBA07");
        log_text(kReady);
        if(g_SetTimer)g_timer=g_SetTimer(0,0,TIMER_PERIOD_MS,(void*)&timer_proc);
    }else if(reason==DLL_PROCESS_DETACH){
        if(g_KillTimer&&g_timer)g_KillTimer(0,g_timer);
        remove_loot_error_hook();
        if(g_CloseHandle&&g_log&&g_log!=INVALID_HANDLE32)g_CloseHandle(g_log);
        g_log=0;
    }
    return TRUE32;
}

/* Exported helpers for development/runtime inspection. */
DLLEXPORT u32 STDCALL AutoLootPP_GetPPAttempts(void){return g_pp.send_count;}
DLLEXPORT u32 STDCALL AutoLootPP_GetLootState(void){return (u32)g_loot_state;}
DLLEXPORT u32 STDCALL AutoLootPP_GetVersion(void){return 0x000E0000u;}

/* Required by MSVC-style x86 floating-point object files when no CRT is linked. */
int _fltused=0x9875;
