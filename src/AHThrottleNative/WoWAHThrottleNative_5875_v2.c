/*
 * WoWAHThrottleNative_5875_v2.c
 * Target: World of Warcraft 1.12.1 build 5875, Windows x86.
 *
 * Diagnostic-only maximum-throughput benchmark for Auction House browse queries.
 * It never bids/buys.
 *
 * F5 triggers one stock QueryAuctionItems(page=0) through Lua. The DLL captures
 * the exact outbound CMSG_AUCTION_LIST_ITEMS packet at ClientServices::Send,
 * validates the build-specific packet shape (opcode 0x0258 and listfrom==0),
 * then replays mutated copies using distinct listfrom values.
 *
 * Test stages: 500, 350, 250, 200, 150, 125, 100, 75 and 50 ms.
 * Each stage sends 25 distinct pages and allows 2500 ms to drain responses.
 * AHThrottleTest deduplicates AUCTION_ITEM_LIST_UPDATE by a multi-row result
 * signature and reports the fastest stage with 25/25 unique responses.
 *
 * Exact-build provenance:
 * - ClientServices::Send entry 0x005AB630 / DataStore5875 ABI:
 *   canonical LongPickPocket reconstruction in this repo.
 * - FrameScript_Execute 0x00704CD0 and Win32 timer/key IAT addresses:
 *   canonical current parallel native modules.
 * - Vanilla CMaNGOS decodes CMSG_AUCTION_LIST_ITEMS as:
 *   ObjectGuid (8), listfrom (u32), searchedname..., so with this project's
 *   DataStore raw layout (4-byte opcode first), listfrom is raw+12.
 * - Runtime capture additionally requires opcode==0x0258, packet>=16 bytes,
 *   and captured listfrom==0 before any mutated replay can occur.
 */
#if !defined(_M_IX86) && !defined(__i386__)
#error Requires WoW 1.12.1 build 5875 x86
#endif

#if defined(_MSC_VER)
#define STDCALL __stdcall
#define THISCALL __thiscall
#define FASTCALL __fastcall
#define NAKED __declspec(naked)
#else
#define STDCALL __attribute__((stdcall))
#define THISCALL __attribute__((thiscall))
#define FASTCALL __attribute__((fastcall))
#define NAKED __attribute__((naked))
#endif

typedef unsigned char u8;
typedef unsigned int u32;
typedef signed int s32;
typedef int BOOL32;
typedef void* HANDLE32;
typedef void* HWND32;
typedef u32 TIMER32;
typedef void (STDCALL *TimerProcFn)(HWND32,u32,TIMER32,u32);
typedef TIMER32 (STDCALL *SetTimerFn)(HWND32,TIMER32,u32,TimerProcFn);
typedef BOOL32 (STDCALL *KillTimerFn)(HWND32,TIMER32);
typedef u32 (STDCALL *GetTickCountFn)(void);
typedef short (STDCALL *GetAsyncKeyStateFn)(int);
typedef BOOL32 (STDCALL *VirtualProtectFn)(void*,u32,u32,u32*);
typedef BOOL32 (STDCALL *FlushInstructionCacheFn)(HANDLE32,const void*,u32);
typedef BOOL32 (FASTCALL *FrameScriptExecuteFn)(const char*,const char*);

typedef struct DataStore5875 {
    u32 owner;
    u8 *data;
    u32 cursor;
    u32 capacity;
    u32 size;
    u32 reserved;
} DataStore5875;

#define DLL_PROCESS_DETACH 0u
#define DLL_PROCESS_ATTACH 1u
#define PAGE_EXECUTE_READWRITE32 0x40u
#define INVALID_HANDLE_VALUE32 ((HANDLE32)(u32)0xFFFFFFFFu)

#define ADDR_CLIENT_SEND 0x005AB630u
#define FRAME_EXECUTE    0x00704CD0u
#define IAT_TICK         0x007FF310u
#define IAT_TIMER        0x007FF4F4u
#define IAT_KILL         0x007FF4F8u
#define IAT_KEY          0x007FF644u
#define IAT_VPROTECT     0x007FF35Cu
#define IAT_FLUSH        0x007FF320u

#define OPCODE_AH_LIST   0x0258u
#define VK_F5_KEY        0x74
#define TIMER_MS         25u
#define CAPTURE_TIMEOUT_MS 1800u
#define BASELINE_DRAIN_MS 1500u
#define STAGE_DRAIN_MS   2500u
#define STAGE_GAP_MS     1000u
#define BENCH_TIMEOUT_MS 120000u
#define MAX_PACKET_COPY  512u
#define STAGE_SENDS      25u
#define STAGE_COUNT      9u
#define FIRST_TEST_PAGE  10u
#define STAGE_PAGE_STRIDE 30u

int _fltused=0;

static const u32 g_intervals[STAGE_COUNT]={500u,350u,250u,200u,150u,125u,100u,75u,50u};

static volatile u32 g_installed=0u;
static volatile u32 g_busy=0u;
static u32 g_nextSend=0u;
static TIMER32 g_timer=0u;
static u32 g_keyF5=0u;

static u32 g_active=0u;
static u32 g_armed=0u;
static u32 g_captured=0u;
static u32 g_capturePublished=0u;
static u32 g_startedAt=0u;
static u32 g_captureAt=0u;
static u32 g_packetOwner=0u;
static u32 g_packetLen=0u;
static u8 g_packet[MAX_PACKET_COPY];

static u32 g_phase=0u; /* 0 capture, 1 baseline drain, 2 send, 3 drain, 4 gap */
static u32 g_stage=0u;
static u32 g_stageSent=0u;
static u32 g_nextSendAt=0u;
static u32 g_phaseUntil=0u;

static u32 read32(u32 a){return *(volatile u32*)(u32)a;}
static void *iat(u32 a){return (void*)(u32)read32(a);}
static int valid_ptr(u32 p){return p>=0x10000u && p<=0x7FFE0000u;}
static u32 tick_now(void){GetTickCountFn f=(GetTickCountFn)iat(IAT_TICK);return f?f():0u;}

static u8 *packet_raw(DataStore5875 *p){
    if(!p||!p->data||p->cursor>0x01000000u||p->size>0x01000000u)return 0;
    return p->data-p->cursor;
}
static u32 decode_jump(u32 site){
    s32 rel;
    if(*(volatile u8*)(u32)site!=0xE9u)return 0u;
    rel=*(volatile s32*)(u32)(site+1u);
    return site+5u+(u32)rel;
}
static BOOL32 write_mem(void *dst,const void *src,u32 n){
    u32 old=0u,tmp=0u,i;
    VirtualProtectFn vp=(VirtualProtectFn)iat(IAT_VPROTECT);
    FlushInstructionCacheFn fic=(FlushInstructionCacheFn)iat(IAT_FLUSH);
    if(!vp||!fic||!dst||!src||!n)return 0;
    if(!vp(dst,n,PAGE_EXECUTE_READWRITE32,&old))return 0;
    for(i=0u;i<n;i++)((volatile u8*)dst)[i]=((const u8*)src)[i];
    fic(INVALID_HANDLE_VALUE32,dst,n);
    vp(dst,n,old,&tmp);
    return 1;
}
static BOOL32 patch_jump(u32 site,u32 target){
    u8 p[5];s32 rel=(s32)(target-(site+5u));
    p[0]=0xE9u;p[1]=(u8)rel;p[2]=(u8)(rel>>8);p[3]=(u8)(rel>>16);p[4]=(u8)(rel>>24);
    return write_mem((void*)(u32)site,p,5u);
}
static int signature(u32 a,const u8 *s,u32 n){
    volatile const u8 *p=(volatile const u8*)(u32)a;u32 i;
    for(i=0u;i<n;i++)if(p[i]!=s[i])return 0;
    return 1;
}
static void lua_exec(const char *s,const char *tag){
    FrameScriptExecuteFn f=(FrameScriptExecuteFn)(u32)FRAME_EXECUTE;
    if(f)f(s,tag);
}
static char *cat(char *p,const char *s){while(*s)*p++=*s++;return p;}
static char *dec(char *p,u32 n){
    char d[11];u32 k=0u;
    do{d[k++]=(char)('0'+n%10u);n/=10u;}while(n);
    while(k)*p++=d[--k];
    return p;
}
static void publish_call3(const char *fn,u32 a,u32 b,u32 c,const char *tag){
    char s[220],*p=s;
    p=cat(p,"if ");p=cat(p,fn);p=cat(p," then ");p=cat(p,fn);*p++='(';
    p=dec(p,a);*p++=',';p=dec(p,b);*p++=',';p=dec(p,c);p=cat(p,") end");*p=0;
    lua_exec(s,tag);
}
static int safe_build(void){
    static const u8 scriptSig[]={0x56,0x6A,0x00,0x8B,0xF1,0x52,0x56,0xE8};
    u32 next;
    if(!signature(FRAME_EXECUTE,scriptSig,sizeof(scriptSig)))return 0;
    next=decode_jump(ADDR_CLIENT_SEND);
    if(!valid_ptr(next))return 0;
    g_nextSend=next;
    return 1;
}
static void reset_test(void){
    g_active=0u;g_armed=0u;g_captured=0u;g_capturePublished=0u;
    g_startedAt=0u;g_captureAt=0u;g_packetOwner=0u;g_packetLen=0u;
    g_phase=0u;g_stage=0u;g_stageSent=0u;g_nextSendAt=0u;g_phaseUntil=0u;
}
static void abort_test(const char *reason){
    char s[220],*p=s;
    p=cat(p,"if AHThrottleTest_BenchAbort then AHThrottleTest_BenchAbort('");
    p=cat(p,reason);p=cat(p,"') end");*p=0;
    lua_exec(s,"AHThrottleBenchAbort");
    reset_test();
}
static void capture_if_needed(DataStore5875 *packet){
    u8 *raw;u32 i,n;
    if(!g_active||!g_armed||g_captured||!packet)return;
    raw=packet_raw(packet);
    if(!raw||packet->size<16u)return;
    if(*(u32*)raw!=OPCODE_AH_LIST)return;
    if(*(u32*)(raw+12u)!=0u){abort_test("BASELINE_LISTFROM_NOT_ZERO");return;}
    n=packet->size;
    if(!n||n>MAX_PACKET_COPY){abort_test("PACKET_TOO_LARGE");return;}
    for(i=0u;i<n;i++)g_packet[i]=raw[i];
    g_packetLen=n;g_packetOwner=packet->owner;
    g_captureAt=tick_now();
    g_captured=1u;g_armed=0u;
    g_phase=1u;g_phaseUntil=g_captureAt+BASELINE_DRAIN_MS;
}
static void send_test_page(u32 page){
    DataStore5875 p;u8 local[MAX_PACKET_COPY];u32 i;
    if(!g_captured||!g_packetLen||!g_nextSend||g_packetLen<16u)return;
    for(i=0u;i<g_packetLen;i++)local[i]=g_packet[i];
    *(u32*)(local+12u)=page*50u; /* Vanilla server listfrom is auction row offset. */
    p.owner=g_packetOwner;p.data=local;p.cursor=0u;p.capacity=MAX_PACKET_COPY;
    p.size=g_packetLen;p.reserved=0u;
    ((void(THISCALL*)(DataStore5875*))(u32)g_nextSend)(&p);
}
static void start_stage(u32 now){
    u32 interval=g_intervals[g_stage];
    g_stageSent=0u;
    g_nextSendAt=now;
    g_phase=2u;
    publish_call3("AHThrottleTest_BenchStageStart",g_stage+1u,interval,STAGE_SENDS,"AHThrottleBenchStageStart");
}
static void finish_stage(u32 now){
    u32 interval=g_intervals[g_stage];
    publish_call3("AHThrottleTest_BenchStageDone",g_stage+1u,interval,g_stageSent,"AHThrottleBenchStageDone");
    ++g_stage;
    if(g_stage>=STAGE_COUNT){
        lua_exec("if AHThrottleTest_BenchFinished then AHThrottleTest_BenchFinished() end","AHThrottleBenchFinished");
        reset_test();
        return;
    }
    g_phase=4u;
    g_phaseUntil=now+STAGE_GAP_MS;
}

NAKED static void SendWrapper(void){
#if defined(_MSC_VER)
    __asm {
        pushfd
        pushad
        push ecx
        call capture_if_needed
        add esp,4
        popad
        popfd
        mov eax,dword ptr [g_nextSend]
        jmp eax
    }
#else
    __asm__ __volatile__("pushf; pusha; pushl %ecx; call _capture_if_needed; addl $4,%esp; popa; popf; movl _g_nextSend,%eax; jmp *%eax");
#endif
}

static void STDCALL timer_proc(HWND32 hwnd,u32 msg,TIMER32 timer,u32 ignored){
    u32 now,key,interval,page;
    GetAsyncKeyStateFn keyfn=(GetAsyncKeyStateFn)iat(IAT_KEY);
    (void)hwnd;(void)msg;(void)timer;(void)ignored;
    if(!g_installed||g_busy||!keyfn)return;
    g_busy=1u;now=tick_now();
    key=(keyfn(VK_F5_KEY)&(short)0x8000)?1u:0u;

    if(key&&!g_keyF5&&!g_active){
        reset_test();g_active=1u;g_armed=1u;g_startedAt=now;
        lua_exec("if AHThrottleTest_BenchNativeStart then AHThrottleTest_BenchNativeStart() end","AHThrottleBenchStart");
    }
    g_keyF5=key;

    if(g_active&&(u32)(now-g_startedAt)>=BENCH_TIMEOUT_MS){
        abort_test("BENCH_TIMEOUT");
        g_busy=0u;return;
    }
    if(g_active&&!g_captured&&(u32)(now-g_startedAt)>=CAPTURE_TIMEOUT_MS){
        abort_test("NO_CAPTURE");
        g_busy=0u;return;
    }
    if(g_active&&g_captured&&!g_capturePublished){
        g_capturePublished=1u;
        lua_exec("if AHThrottleTest_BenchMarkCapture then AHThrottleTest_BenchMarkCapture() end","AHThrottleBenchCapture");
    }

    if(g_active&&g_captured){
        if(g_phase==1u && (s32)(now-g_phaseUntil)>=0){
            g_stage=0u;start_stage(now);
        }else if(g_phase==2u){
            interval=g_intervals[g_stage];
            if(g_stageSent<STAGE_SENDS && (s32)(now-g_nextSendAt)>=0){
                page=FIRST_TEST_PAGE + g_stage*STAGE_PAGE_STRIDE + g_stageSent;
                send_test_page(page);
                ++g_stageSent;
                g_nextSendAt+=interval;
                if(g_stageSent>=STAGE_SENDS){
                    g_phase=3u;
                    g_phaseUntil=now+STAGE_DRAIN_MS;
                }
            }
        }else if(g_phase==3u && (s32)(now-g_phaseUntil)>=0){
            finish_stage(now);
        }else if(g_phase==4u && (s32)(now-g_phaseUntil)>=0){
            start_stage(now);
        }
    }
    g_busy=0u;
}
static int install(void){
    SetTimerFn st;u32 cur;
    if(!safe_build())return 0;
    cur=g_nextSend;
    if(!patch_jump(ADDR_CLIENT_SEND,(u32)(void*)&SendWrapper))return 0;
    st=(SetTimerFn)iat(IAT_TIMER);
    if(!st){patch_jump(ADDR_CLIENT_SEND,cur);return 0;}
    g_timer=st(0,0u,TIMER_MS,timer_proc);
    if(!g_timer){patch_jump(ADDR_CLIENT_SEND,cur);return 0;}
    g_installed=1u;return 1;
}
static void uninstall(void){
    KillTimerFn kt=(KillTimerFn)iat(IAT_KILL);
    u32 cur=decode_jump(ADDR_CLIENT_SEND);
    g_installed=0u;
    if(g_timer&&kt)kt(0,g_timer);g_timer=0u;
    if(cur==(u32)(void*)&SendWrapper&&g_nextSend)patch_jump(ADDR_CLIENT_SEND,g_nextSend);
    reset_test();
}
BOOL32 STDCALL DllMain(void *module,u32 reason,void *reserved){
    (void)module;(void)reserved;
    if(reason==DLL_PROCESS_ATTACH)(void)install();
    if(reason==DLL_PROCESS_DETACH)uninstall();
    return 1;
}
