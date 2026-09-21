/*
 * PARALLEL read-only cast/channel observer for WoW 1.12.1 build 5875 x86.
 * LazyScript alone authorizes/dispatches Kick. No gameplay hooks or casts.
 * Verified native address lineage: src/AutoKick/WoWAutoKick_5875_v3_SAFE_GUI.c
 */
#if !defined(_M_IX86) && !defined(__i386__)
#error Requires WoW 1.12.1 build 5875 x86
#endif
#if defined(_MSC_VER)
#define STDCALL __stdcall
#define FASTCALL __fastcall
#else
#define STDCALL __attribute__((stdcall))
#define FASTCALL __attribute__((fastcall))
#endif
typedef unsigned char u8;
typedef unsigned int u32;
typedef unsigned long long u64;
typedef signed int s32;
typedef int BOOL32;
typedef void* HANDLE32;
typedef void* HWND32;
typedef u32 TIMER32;
typedef void (STDCALL *TimerProc)(HWND32,u32,TIMER32,u32);
typedef TIMER32 (STDCALL *SetTimerFn)(HWND32,TIMER32,u32,TimerProc);
typedef BOOL32 (STDCALL *KillTimerFn)(HWND32,TIMER32);
typedef u32 (STDCALL *GetTickCountFn)(void);
typedef u32 (FASTCALL *GetObjectByGuidFn)(u64);
typedef BOOL32 (FASTCALL *FrameScriptExecuteFn)(const char*,const char*);

#define OBJMGR 0x00B41414u
#define TARGET_GUID_LO 0x00B4E2D8u
#define TARGET_GUID_HI 0x00B4E2DCu
#define GET_OBJECT 0x00464870u
#define FRAME_EXECUTE 0x00704CD0u
#define UNIT_CAST_SETTER 0x0060D026u
#define UNIT_CAST_CLEARER 0x0060D066u
#define IAT_TICK 0x007FF310u
#define IAT_TIMER 0x007FF4F4u
#define IAT_KILL 0x007FF4F8u
#define UNIT_CHANNEL_INDEX 0x90u
#define UNIT_CAST_OFFSET 0xC8Cu
#define SPELL_NORMAL 1u
#define SPELL_CHANNEL 2u
#define REMAINING_UNKNOWN 65535u
#define DLL_PROCESS_ATTACH 1u
#define DLL_PROCESS_DETACH 0u
int _fltused=0;
static volatile u32 g_installed=0u,g_busy=0u,g_inWorld=0u,g_readyAfter=0u;
static TIMER32 g_timer=0u;
static u32 g_lastEmit=0u,g_lastKind=0u,g_lastLo=0u,g_lastHi=0u,g_lastSpell=0u;

static u32 read32(u32 a){return *(volatile u32*)(u32)a;}
static void *iat(u32 a){return (void*)(u32)read32(a);}
static int valid_ptr(u32 p){return p>=0x10000u && p<=0x7FFE0000u && !(p&3u);}
static int signature(u32 a,const u8 *s,u32 n){
    volatile const u8 *p=(volatile const u8*)(u32)a;u32 i;
    for(i=0u;i<n;i++)if(p[i]!=s[i])return 0;return 1;
}
static int safe_build(void){
    static const u8 getSig[]={0x55,0x8B,0xEC,0x8B,0x45,0x08,0x8B,0x4D,0x0C,0x8B,0xD0,0x0B,0xD1};
    static const u8 scriptSig[]={0x56,0x6A,0x00,0x8B,0xF1,0x52,0x56,0xE8};
    static const u8 setSig[]={0x89,0x81,0x8C,0x0C,0x00,0x00};
    static const u8 clearSig[]={0xC7,0x86,0x8C,0x0C,0x00,0x00,0x00,0x00,0x00,0x00};
    return signature(GET_OBJECT,getSig,sizeof(getSig)) &&
           signature(FRAME_EXECUTE,scriptSig,sizeof(scriptSig)) &&
           signature(UNIT_CAST_SETTER,setSig,sizeof(setSig)) &&
           signature(UNIT_CAST_CLEARER,clearSig,sizeof(clearSig));
}
static u32 current_tick(void){GetTickCountFn f=(GetTickCountFn)iat(IAT_TICK);return f?f():0u;}
static u32 object_by_guid(u32 lo,u32 hi){
    u64 guid;u32 obj;GetObjectByGuidFn f;
    if(!(lo|hi))return 0u;
    guid=((u64)hi<<32)|(u64)lo;
    f=(GetObjectByGuidFn)(u32)GET_OBJECT;
    obj=f(guid);
    if(!valid_ptr(obj))return 0u;
    if(read32(obj+0x30u)!=lo||read32(obj+0x34u)!=hi)return 0u;
    return obj;
}
static int world_ready(void){
    u32 mgr=read32(OBJMGR),lo,hi,obj;
    if(!valid_ptr(mgr))return 0;
    lo=read32(mgr+0xC0u);hi=read32(mgr+0xC4u);
    obj=object_by_guid(lo,hi);
    return obj && read32(obj+0x14u)==4u;
}
static char *cat(char *p,const char *s){while(*s)*p++=*s++;return p;}
static char *decimal(char *p,u32 n){
    char d[11];u32 k=0u;
    do{d[k++]=(char)('0'+n%10u);n/=10u;}while(n);
    while(k)*p++=d[--k];return p;
}
static char *hex8(char *p,u32 n){
    static const char digits[]="0123456789ABCDEF";u32 i;
    for(i=0u;i<8u;i++)*p++=digits[(n>>(28u-4u*i))&15u];
    return p;
}
static void publish(u32 lo,u32 hi,u32 spell,u32 kind,u32 now){
    char lua[230],*p=lua;
    FrameScriptExecuteFn run=(FrameScriptExecuteFn)(u32)FRAME_EXECUTE;
    /* Keep active snapshots fresh for LS. Explicit idle clears stale casts. */
    if(!kind && !g_lastKind && (u32)(now-g_lastEmit)<180u)return;
    p=cat(p,"if lazyScript and lazyScript.interrupt and lazyScript.interrupt.OnNativeCast then lazyScript.interrupt.OnNativeCast('");
    if(kind){p=hex8(p,hi);p=hex8(p,lo);}
    p=cat(p,"',");p=decimal(p,kind?spell:0u);
    *p++=',';p=decimal(p,kind?REMAINING_UNKNOWN:0u);
    *p++=',';p=decimal(p,kind);
    p=cat(p,",0) end");*p=0;
    run(lua,"WoWCastObserver");
    g_lastEmit=now;g_lastLo=lo;g_lastHi=hi;g_lastSpell=spell;g_lastKind=kind;
}
static void STDCALL observe_timer(HWND32 hwnd,u32 msg,TIMER32 timer,u32 tick){
    u32 now,lo=0u,hi=0u,obj=0u,typeId=0u,desc=0u;
    u32 normal=0u,channel=0u,kind=0u,spell=0u;
    (void)hwnd;(void)msg;(void)timer;(void)tick;
    if(!g_installed||g_busy)return;g_busy=1u;
    now=current_tick();
    if(!world_ready()){
        g_inWorld=0u;g_readyAfter=0u;g_lastKind=0u;
        g_busy=0u;return;
    }
    if(!g_inWorld){
        g_inWorld=1u;g_readyAfter=now+750u;g_lastKind=0u;
        g_busy=0u;return;
    }
    if((s32)(now-g_readyAfter)<0){g_busy=0u;return;}
    lo=read32(TARGET_GUID_LO);hi=read32(TARGET_GUID_HI);
    obj=object_by_guid(lo,hi);
    if(obj){
        typeId=read32(obj+0x14u);
        if(typeId==3u||typeId==4u){
            desc=read32(obj+0x08u);
            if(valid_ptr(desc))channel=read32(desc+UNIT_CHANNEL_INDEX*4u);
            /* Channel descriptor wins if both slots are briefly set. */
            normal=read32(obj+UNIT_CAST_OFFSET);
            if(channel){kind=SPELL_CHANNEL;spell=channel;}
            else if(normal){kind=SPELL_NORMAL;spell=normal;}
        }
    }
    publish(lo,hi,spell,kind,now);
    g_busy=0u;
}
static int install(void){
    SetTimerFn setTimer;
    if(!safe_build())return 0; /* inert on unexpected EXE; never block launch */
    setTimer=(SetTimerFn)iat(IAT_TIMER);
    if(!setTimer)return 0;
    g_timer=setTimer(0,0u,25u,observe_timer);
    if(!g_timer)return 0;
    g_installed=1u;return 1;
}
static void uninstall(void){
    KillTimerFn stop=(KillTimerFn)iat(IAT_KILL);
    g_installed=0u;
    if(g_timer&&stop)stop(0,g_timer);g_timer=0u;
}
BOOL32 STDCALL DllMain(void *module,u32 reason,void *reserved){
    (void)module;(void)reserved;
    if(reason==DLL_PROCESS_ATTACH)(void)install();
    if(reason==DLL_PROCESS_DETACH)uninstall();
    return 1;
}
