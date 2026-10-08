/*
 * PARALLEL read-only cast/channel + movement + target melee-range observer
 * for WoW 1.12.1 build 5875 x86.
 * LazyScript alone authorizes/dispatches gameplay actions.
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

/* Verified 5875 object/update-field layout. */
#define OBJ_DESCRIPTOR_OFFSET 0x0008u
#define OBJ_TYPE_OFFSET 0x0014u
#define PLAYER_X_OFFSET 0x09B8u
#define PLAYER_Y_OFFSET 0x09BCu
#define PLAYER_Z_OFFSET 0x09C0u
/* UNIT_FIELD_BOUNDINGRADIUS is descriptor + 0x208; COMBATREACH follows. */
#define UNIT_COMBAT_REACH_OFFSET 0x020Cu
#define OBJECT_UNIT 3u
#define OBJECT_PLAYER 4u
#define BASE_MELEE_RANGE 5.0f
#define BASE_MELEE_OFFSET 1.3333334f

int _fltused=0;
static volatile u32 g_installed=0u,g_busy=0u,g_inWorld=0u,g_readyAfter=0u;
static TIMER32 g_timer=0u;
static u32 g_lastEmit=0u,g_lastKind=0u,g_lastLo=0u,g_lastHi=0u,g_lastSpell=0u;
static u32 g_motionObject=0u,g_motionCandidate=0u,g_motionCandidateSince=0u;
static u32 g_motionState=0u,g_motionKnown=0u,g_motionLastEmit=0u;
static float g_previousX=0.0f,g_previousY=0.0f;
static u32 g_meleeKnown=0u,g_meleeState=0u,g_meleeLastEmit=0u;

static u32 read32(u32 a){return *(volatile u32*)(u32)a;}
static float readf(u32 a){return *(volatile float*)(u32)a;}
static void *iat(u32 a){return (void*)(u32)read32(a);}
static int valid_ptr(u32 p){return p>=0x10000u && p<=0x7FFE0000u && !(p&3u);}
static int valid_coord(float v){return v==v && v>-100000.0f && v<100000.0f;}
static int valid_reach(float v){return v==v && v>0.0f && v<100.0f;}
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
static u32 player_object(void){
    u32 mgr=read32(OBJMGR),lo,hi,obj;
    if(!valid_ptr(mgr))return 0u;
    lo=read32(mgr+0xC0u);hi=read32(mgr+0xC4u);
    obj=object_by_guid(lo,hi);
    if(!obj||read32(obj+OBJ_TYPE_OFFSET)!=OBJECT_PLAYER)return 0u;
    return obj;
}
static int world_ready(void){return player_object()!=0u;}
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

/* Native position sampler, never a movement writer. */
static void publish_motion(u32 now){
    FrameScriptExecuteFn run=(FrameScriptExecuteFn)(u32)FRAME_EXECUTE;
    const char *lua=g_motionState
        ?"if lazyScript and lazyScript.OnNativePlayerMovement then lazyScript.OnNativePlayerMovement(1) end"
        :"if lazyScript and lazyScript.OnNativePlayerMovement then lazyScript.OnNativePlayerMovement(0) end";
    run(lua,"WoWCastObserverMovement");
    g_motionLastEmit=now;
}
static void observe_player_motion(u32 now){
    u32 obj=player_object();
    float x,y,dx,dy,dist2;
    u32 raw,hold;
    if(!obj){g_motionKnown=0u;g_motionObject=0u;return;}
    x=readf(obj+PLAYER_X_OFFSET);y=readf(obj+PLAYER_Y_OFFSET);
    if(!valid_coord(x)||!valid_coord(y)){g_motionKnown=0u;g_motionObject=0u;return;}
    if(obj!=g_motionObject){
        g_motionObject=obj;g_motionKnown=0u;
        g_motionCandidate=0u;g_motionCandidateSince=now;
        g_previousX=x;g_previousY=y;return;
    }
    dx=x-g_previousX;dy=y-g_previousY;
    g_previousX=x;g_previousY=y;
    dist2=dx*dx+dy*dy;
    if(dist2>10000.0f){
        g_motionKnown=0u;g_motionCandidate=0u;g_motionCandidateSince=now;
        return;
    }
    raw=(dist2>0.000225f)?1u:0u;
    if(raw!=g_motionCandidate){g_motionCandidate=raw;g_motionCandidateSince=now;}
    hold=raw?50u:100u;
    if((u32)(now-g_motionCandidateSince)>=hold &&
       (!g_motionKnown || g_motionState!=raw)){
        g_motionState=raw;g_motionKnown=1u;publish_motion(now);return;
    }
    if(g_motionKnown && (u32)(now-g_motionLastEmit)>=125u)publish_motion(now);
}

/*
 * Generic selected-target melee range for classes without a 5 yd spell probe.
 * The 1.12 client exposes combat reach in the unit descriptor. The classic
 * melee rule is both units' combat reach + ~1.333 yd, clamped to at least
 * 5 yd. We compare squared 3D world distance, so no CRT sqrt dependency.
 */
static void publish_melee(u32 state,u32 now){
    char lua[150],*p=lua;
    FrameScriptExecuteFn run=(FrameScriptExecuteFn)(u32)FRAME_EXECUTE;
    p=cat(p,"if lazyScript and lazyScript.OnNativeTargetMeleeRange then lazyScript.OnNativeTargetMeleeRange(");
    p=decimal(p,state);p=cat(p,") end");*p=0;
    run(lua,"WoWCastObserverMeleeRange");
    g_meleeLastEmit=now;
}
static void clear_melee(u32 now){
    if(!g_meleeKnown)return;
    g_meleeKnown=0u;
    publish_melee(2u,now); /* any non-0/1 state clears Lua's sample */
}
static void observe_target_melee(u32 now){
    u32 pobj=player_object(),tlo,thi,tobj,pdesc,tdesc,typeId,state;
    float px,py,pz,tx,ty,tz,pr,tr,reach,dx,dy,dz,d2;
    if(!pobj){clear_melee(now);return;}
    tlo=read32(TARGET_GUID_LO);thi=read32(TARGET_GUID_HI);
    tobj=object_by_guid(tlo,thi);
    if(!tobj){clear_melee(now);return;}
    typeId=read32(tobj+OBJ_TYPE_OFFSET);
    if(typeId!=OBJECT_UNIT && typeId!=OBJECT_PLAYER){clear_melee(now);return;}
    pdesc=read32(pobj+OBJ_DESCRIPTOR_OFFSET);tdesc=read32(tobj+OBJ_DESCRIPTOR_OFFSET);
    if(!valid_ptr(pdesc)||!valid_ptr(tdesc)){clear_melee(now);return;}

    px=readf(pobj+PLAYER_X_OFFSET);py=readf(pobj+PLAYER_Y_OFFSET);pz=readf(pobj+PLAYER_Z_OFFSET);
    tx=readf(tobj+PLAYER_X_OFFSET);ty=readf(tobj+PLAYER_Y_OFFSET);tz=readf(tobj+PLAYER_Z_OFFSET);
    pr=readf(pdesc+UNIT_COMBAT_REACH_OFFSET);tr=readf(tdesc+UNIT_COMBAT_REACH_OFFSET);
    if(!valid_coord(px)||!valid_coord(py)||!valid_coord(pz)||
       !valid_coord(tx)||!valid_coord(ty)||!valid_coord(tz)||
       !valid_reach(pr)||!valid_reach(tr)){
        clear_melee(now);return;
    }

    reach=pr+tr+BASE_MELEE_OFFSET;
    if(reach<BASE_MELEE_RANGE)reach=BASE_MELEE_RANGE;
    dx=px-tx;dy=py-ty;dz=pz-tz;d2=dx*dx+dy*dy+dz*dz;
    state=(d2<=reach*reach)?1u:0u;
    if(!g_meleeKnown || state!=g_meleeState || (u32)(now-g_meleeLastEmit)>=100u){
        g_meleeState=state;g_meleeKnown=1u;publish_melee(state,now);
    }
}

static void STDCALL observe_timer(HWND32 hwnd,u32 msg,TIMER32 timer,u32 tick){
    u32 now,lo=0u,hi=0u,obj=0u,typeId=0u,desc=0u;
    u32 normal=0u,channel=0u,kind=0u,spell=0u;
    (void)hwnd;(void)msg;(void)timer;(void)tick;
    if(!g_installed||g_busy)return;g_busy=1u;
    now=current_tick();
    if(!world_ready()){
        g_inWorld=0u;g_readyAfter=0u;g_lastKind=0u;
        g_motionKnown=0u;g_motionObject=0u;g_meleeKnown=0u;
        g_busy=0u;return;
    }
    if(!g_inWorld){
        g_inWorld=1u;g_readyAfter=now+750u;g_lastKind=0u;
        g_motionKnown=0u;g_motionObject=0u;g_meleeKnown=0u;
        g_busy=0u;return;
    }
    if((s32)(now-g_readyAfter)<0){g_busy=0u;return;}
    observe_player_motion(now);
    observe_target_melee(now);

    lo=read32(TARGET_GUID_LO);hi=read32(TARGET_GUID_HI);
    obj=object_by_guid(lo,hi);
    if(obj){
        typeId=read32(obj+OBJ_TYPE_OFFSET);
        if(typeId==OBJECT_UNIT||typeId==OBJECT_PLAYER){
            desc=read32(obj+OBJ_DESCRIPTOR_OFFSET);
            if(valid_ptr(desc))channel=read32(desc+UNIT_CHANNEL_INDEX*4u);
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
    if(!safe_build())return 0;
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
