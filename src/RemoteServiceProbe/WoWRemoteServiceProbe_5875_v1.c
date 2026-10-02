
#include <windows.h>

#if !defined(_M_IX86) && !defined(__i386__)
#error WoWRemoteServiceProbe requires WoW 1.12.1 build 5875 x86
#endif

#if defined(_MSC_VER)
#define FASTCALL __fastcall
#define THISCALL __thiscall
#define STDCALL __stdcall
#define NAKED __declspec(naked)
/* Export stable undecorated ABI names for GetProcAddress consumers on x86. */
#pragma comment(linker, "/EXPORT:W112_RSP_GetLearnedGuid=_W112_RSP_GetLearnedGuid@20")
#pragma comment(linker, "/EXPORT:W112_RSP_GetLearnedMask=_W112_RSP_GetLearnedMask@0")
#pragma comment(linker, "/EXPORT:W112_RSP_ReplayLocalOpener=_W112_RSP_ReplayLocalOpener@8")
#else
#define FASTCALL __attribute__((fastcall))
#define THISCALL __attribute__((thiscall))
#define STDCALL __attribute__((stdcall))
#define NAKED __attribute__((naked))
#endif

typedef unsigned char u8;
typedef unsigned int u32;
typedef signed int s32;
typedef unsigned long long u64;
typedef int BOOL32;

/* MSVC x86 floating-point marker required by the CRT-less /NODEFAULTLIB build. */
int _fltused = 0x9875;

typedef BOOL32 (FASTCALL *FrameScriptExecuteFn)(const char*,const char*);
typedef const char* (FASTCALL *FrameScriptGetTextFn)(const char*,int,u32);
typedef u32 (FASTCALL *GetObjectByGuidFn)(u64);

typedef struct DataStore5875 {
    u32 owner;
    u8 *data;
    u32 cursor;
    u32 capacity;
    u32 size;
    u32 reserved;
} DataStore5875;

#define ADDR_CLIENT_SEND       0x005AB630u
#define ADDR_FRAME_EXECUTE     0x00704CD0u
#define ADDR_FRAME_GETTEXT     0x00703BF0u
#define ADDR_GET_OBJECT_GUID   0x00464870u
#define OBJMGR_GLOBAL          0x00B41414u
#define OM_LOCAL_GUID_LO       0x000000C0u
#define OM_LOCAL_GUID_HI       0x000000C4u
#define OBJ_TYPE_OFF           0x00000014u
#define OBJ_POS_X              0x000009B8u
#define OBJ_POS_Y              0x000009BCu
#define OBJ_POS_Z              0x000009C0u

#define OPCODE_AH_LIST         0x0258u

#define SERVICE_BANK 1u
#define SERVICE_MAIL 2u
#define SERVICE_AH   3u
#define SERVICE_MAX  3u

#define PACKET_RING_CAP 96u
#define MAX_PACKET_COPY 256u
#define LEARN_WINDOW_MS 1400u
#define TEST_TIMEOUT_MS 3500u
#define TIMER_MS 25u
#define LUA_RETRY_MS 750u
#define SWEEP_RETRY_MS 4500u
#define SUMMARY_PACKET_BYTES 96u

typedef struct PacketRecord {
    u32 tick;
    u32 opcode;
    u32 len;
    u32 owner;
    u32 guidLo;
    u32 guidHi;
    u32 guidOffset;
    u32 hash;
    u8 bytes[MAX_PACKET_COPY];
} PacketRecord;

typedef struct LearnedService {
    u32 valid;
    u32 captures;
    u32 sameShape;
    u32 learnedAt;
    u32 objectType;
    u32 learnDist100;
    s32 tx100;
    s32 ty100;
    s32 tz100;
    PacketRecord packet;
} LearnedService;

static volatile u32 g_installed=0u;
static volatile u32 g_injecting=0u;
static u32 g_nextSend=0u;
static UINT_PTR g_timer=0;
static u32 g_luaReady=0u;
static u32 g_lastLuaTry=0u;
static u32 g_lastCmdSeq=0u;
static u32 g_lastOpenSeq=0u;
static u32 g_lastCloseSeq=0u;
static u32 g_lastErrorSeq=0u;
static u32 g_lastDataSeq=0u;
static volatile u32 g_sendHead=0u;
static PacketRecord g_ring[PACKET_RING_CAP];
static LearnedService g_learn[SERVICE_MAX+1u];

static u32 g_testActive=0u;
static u32 g_testService=0u;
static u32 g_testAttempt=0u;
static u32 g_testSentAt=0u;
static u32 g_testStartOpenSeq=0u;
static u32 g_testStartDataSeq=0u;
static u32 g_testDataSeen=0u;
static char g_testLastError[192];

static u32 g_sweepService=0u;
static u32 g_sweepNextAt=0u;
static u32 g_sweepAttempts[6];
static u32 g_pass[SERVICE_MAX+1u];
static u32 g_fail[SERVICE_MAX+1u];
static u32 g_verbose=1u;
static u32 g_hookHealthy=0u;
static u32 g_lastHookCheck=0u;

static char g_logPath[MAX_PATH];

static int ptr_ok(u32 p){ return p>=0x00010000u && p<=0x7FFE0000u; }
static u32 rd32(u32 a){ return *(volatile u32*)(u32)a; }

static const char *service_name(u32 s){
    if(s==SERVICE_BANK)return "bank";
    if(s==SERVICE_MAIL)return "mail";
    if(s==SERVICE_AH)return "ah";
    return "none";
}
static const char *open_event(u32 s){
    if(s==SERVICE_BANK)return "BANKFRAME_OPENED";
    if(s==SERVICE_MAIL)return "MAIL_SHOW";
    if(s==SERVICE_AH)return "AUCTION_HOUSE_SHOW";
    return "";
}
static u32 service_from_open(const char *s){
    if(!s)return 0u;
    if(lstrcmpiA(s,"BANKFRAME_OPENED")==0)return SERVICE_BANK;
    if(lstrcmpiA(s,"MAIL_SHOW")==0)return SERVICE_MAIL;
    if(lstrcmpiA(s,"AUCTION_HOUSE_SHOW")==0)return SERVICE_AH;
    return 0u;
}
static u32 parse_u32(const char *s){
    u32 v=0u;
    if(!s)return 0u;
    while(*s>='0'&&*s<='9'){v=v*10u+(u32)(*s-'0');++s;}
    return v;
}
static void str_copy(char *dst,u32 cap,const char *src){
    u32 i=0u;
    if(!dst||!cap)return;
    if(!src)src="";
    while(i+1u<cap&&src[i]){dst[i]=src[i];++i;}
    dst[i]=0;
}
static void append_text(char *dst,u32 cap,u32 *p,const char *src){
    if(!src)return;
    while(*src&&*p+1u<cap){dst[(*p)++]=*src++;dst[*p]=0;}
}
static void append_char(char *dst,u32 cap,u32 *p,char c){
    if(*p+1u>=cap)return;
    dst[(*p)++]=c;dst[*p]=0;
}
static void append_u32(char *dst,u32 cap,u32 *p,u32 v){
    char t[16];u32 n=0u;
    if(!v){append_char(dst,cap,p,'0');return;}
    while(v&&n<sizeof(t)){t[n++]=(char)('0'+(v%10u));v/=10u;}
    while(n)append_char(dst,cap,p,t[--n]);
}
static void append_s32(char *dst,u32 cap,u32 *p,s32 v){
    u32 m;
    if(v<0){append_char(dst,cap,p,'-');m=(u32)(-(v+1));++m;}else m=(u32)v;
    append_u32(dst,cap,p,m);
}
static void append_hex32(char *dst,u32 cap,u32 *p,u32 v){
    static const char h[]="0123456789abcdef";int i;
    append_text(dst,cap,p,"0x");
    for(i=7;i>=0;--i)append_char(dst,cap,p,h[(v>>(i*4))&0xFu]);
}
static void append_hex_bytes(char *dst,u32 cap,u32 *p,const u8 *b,u32 n){
    static const char h[]="0123456789abcdef";u32 i;
    for(i=0u;i<n&&*p+2u<cap;i++){
        append_char(dst,cap,p,h[(b[i]>>4)&0xFu]);
        append_char(dst,cap,p,h[b[i]&0xFu]);
    }
}
static void json_escape(char *out,u32 cap,const char *src){
    u32 p=0u;unsigned char c;
    if(!out||!cap)return;
    out[0]=0;
    if(!src)return;
    while(*src&&p+2u<cap){
        c=(unsigned char)*src++;
        if(c=='"'||c=='\\'){append_char(out,cap,&p,'\\');append_char(out,cap,&p,(char)c);}
        else if(c=='\r')append_text(out,cap,&p,"\\r");
        else if(c=='\n')append_text(out,cap,&p,"\\n");
        else if(c=='\t')append_text(out,cap,&p,"\\t");
        else if(c<0x20u){append_text(out,cap,&p,"?");}
        else append_char(out,cap,&p,(char)c);
    }
}
static u32 fnv1a(const u8 *b,u32 n){
    u32 h=2166136261u,i;
    for(i=0u;i<n;i++){h^=b[i];h*=16777619u;}
    return h;
}
static float fsqrt_pos(float x){
    float r;u32 i;
    if(x<=0.0f)return 0.0f;
    r=x>1.0f?x:1.0f;
    for(i=0u;i<8u;i++)r=0.5f*(r+x/r);
    return r;
}
static s32 scale100(float v){ return (s32)(v*100.0f); }

static int prepare_log(void){
    char exe[MAX_PATH];DWORD n;int i;
    if(g_logPath[0])return 1;
    n=GetModuleFileNameA(NULL,exe,MAX_PATH);
    if(!n||n>=MAX_PATH)return 0;
    i=(int)n-1;while(i>=0&&exe[i]!='\\'&&exe[i]!='/')--i;
    if(i<1)return 0;
    exe[i]=0;
    if((u32)lstrlenA(exe)+40u>=MAX_PATH)return 0;
    lstrcatA(exe,"\\.wow112_debug");
    CreateDirectoryA(exe,NULL);
    wsprintfA(g_logPath,"%s\\remote_service_probe_%lu_%lu.jsonl",exe,GetCurrentProcessId(),GetTickCount());
    return 1;
}
static void log_line(const char *event,u32 svc,u32 attempt,u32 opcode,u32 len,u32 guidLo,u32 guidHi,
                     u32 loaded,u32 type,u32 dist100,s32 px,s32 py,s32 pz,s32 tx,s32 ty,s32 tz,const char *detail){
    HANDLE f;DWORD wrote=0u;static char line[4096],de[1800],zone[384],ze[520];
    const char *z="";
    if(!prepare_log())return;
    json_escape(de,sizeof(de),detail?detail:"");
    if(g_luaReady){
        z=((FrameScriptGetTextFn)(u32)ADDR_FRAME_GETTEXT)("W112_RSP_ZONE",-1,0u);
        if(!z)z="";
    }
    str_copy(zone,sizeof(zone),z);json_escape(ze,sizeof(ze),zone);
    wsprintfA(line,
      "{\"tick\":%lu,\"pid\":%lu,\"event\":\"%s\",\"service\":\"%s\",\"attempt\":%lu,"
      "\"opcode\":%lu,\"len\":%lu,\"guid_lo\":%lu,\"guid_hi\":%lu,\"loaded\":%lu,\"type\":%lu,"
      "\"dist100\":%lu,\"px100\":%ld,\"py100\":%ld,\"pz100\":%ld,\"tx100\":%ld,\"ty100\":%ld,\"tz100\":%ld,"
      "\"zone\":\"%s\",\"detail\":\"%s\"}\r\n",
      GetTickCount(),GetCurrentProcessId(),event?event:"",service_name(svc),attempt,
      opcode,len,guidLo,guidHi,loaded,type,dist100,px,py,pz,tx,ty,tz,ze,de);
    f=CreateFileA(g_logPath,FILE_APPEND_DATA,FILE_SHARE_READ|FILE_SHARE_WRITE,NULL,OPEN_ALWAYS,FILE_ATTRIBUTE_NORMAL,NULL);
    if(f==INVALID_HANDLE_VALUE)return;
    WriteFile(f,line,(DWORD)lstrlenA(line),&wrote,NULL);
    FlushFileBuffers(f);CloseHandle(f);
}
static void lua_exec(const char *s,const char *tag){
    ((FrameScriptExecuteFn)(u32)ADDR_FRAME_EXECUTE)(s,tag);
}
static const char *lua_get(const char *name){
    return ((FrameScriptGetTextFn)(u32)ADDR_FRAME_GETTEXT)(name,-1,0u);
}
static void lua_chat(const char *msg){
    char esc[512],script[700];u32 p=0u;const char *s=msg;
    esc[0]=0;
    while(s&&*s&&p+2u<sizeof(esc)){
        if(*s=='\\'||*s=='\'')esc[p++]='\\';
        esc[p++]=*s++;
    }
    esc[p]=0;
    wsprintfA(script,"if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage('|cff66ccff[RSP]|r %s') end",esc);
    lua_exec(script,"RemoteServiceProbeChat");
}
static void refresh_context(void){
    static const char s[]=
      "W112_RSP_BANK_VISIBLE=(BankFrame and BankFrame:IsVisible()) and 1 or 0;"
      "W112_RSP_MAIL_VISIBLE=(MailFrame and MailFrame:IsVisible()) and 1 or 0;"
      "W112_RSP_AH_VISIBLE=(AuctionFrame and AuctionFrame:IsVisible()) and 1 or 0;"
      "W112_RSP_ZONE=(GetRealZoneText and GetRealZoneText()) or (GetZoneText and GetZoneText()) or '';"
      "W112_RSP_COMBAT=(UnitAffectingCombat and UnitAffectingCombat('player')) and 1 or 0;"
      "W112_RSP_LATENCY=0;if GetNetStats then local a,b,c=GetNetStats();W112_RSP_LATENCY=c or 0 end";
    lua_exec(s,"RemoteServiceProbeContext");
}
static u32 service_visible(u32 svc){
    const char *v;
    if(svc==SERVICE_BANK)v=lua_get("W112_RSP_BANK_VISIBLE");
    else if(svc==SERVICE_MAIL)v=lua_get("W112_RSP_MAIL_VISIBLE");
    else if(svc==SERVICE_AH)v=lua_get("W112_RSP_AH_VISIBLE");
    else return 0u;
    return parse_u32(v)?1u:0u;
}

static u32 decode_jump(u32 site){
    s32 rel;
    if(*(volatile u8*)(u32)site!=0xE9u)return 0u;
    rel=*(volatile s32*)(u32)(site+1u);
    return site+5u+(u32)rel;
}
static BOOL32 patch_jump(u32 site,u32 target){
    DWORD old=0u,tmp=0u;u8 b[5];s32 rel=(s32)(target-(site+5u));
    b[0]=0xE9u;b[1]=(u8)rel;b[2]=(u8)(rel>>8);b[3]=(u8)(rel>>16);b[4]=(u8)(rel>>24);
    if(!VirtualProtect((void*)(u32)site,5u,PAGE_EXECUTE_READWRITE,&old))return 0;
    *(volatile u8*)(u32)(site+0u)=b[0];*(volatile u8*)(u32)(site+1u)=b[1];
    *(volatile u8*)(u32)(site+2u)=b[2];*(volatile u8*)(u32)(site+3u)=b[3];
    *(volatile u8*)(u32)(site+4u)=b[4];
    FlushInstructionCache(GetCurrentProcess(),(const void*)(u32)site,5u);
    VirtualProtect((void*)(u32)site,5u,old,&tmp);
    return 1;
}
static int sig_ok(u32 a,const u8 *b,u32 n){
    u32 i;const volatile u8 *p=(const volatile u8*)(u32)a;
    for(i=0u;i<n;i++)if(p[i]!=b[i])return 0;
    return 1;
}
static int build_guard(void){
    static const u8 scriptSig[]={0x56,0x6A,0x00,0x8B,0xF1,0x52,0x56,0xE8};
    static const u8 objSig[]={0x55,0x8B,0xEC,0x8B,0x45,0x08,0x8B,0x4D,0x0C,0x8B,0xD0,0x0B,0xD1};
    if(!sig_ok(ADDR_FRAME_EXECUTE,scriptSig,sizeof(scriptSig)))return 0;
    if(!sig_ok(ADDR_GET_OBJECT_GUID,objSig,sizeof(objSig)))return 0;
    if(!ptr_ok(decode_jump(ADDR_CLIENT_SEND)))return 0;
    return 1;
}
static u8 *packet_raw(DataStore5875 *p){
    if(!p||!p->data||p->cursor>0x01000000u||p->size>0x01000000u)return 0;
    return p->data-p->cursor;
}
static u32 find_object(u32 lo,u32 hi){
    u64 g=((u64)hi<<32)|(u64)lo;
    if(!lo&&!hi)return 0u;
    return ((GetObjectByGuidFn)(u32)ADDR_GET_OBJECT_GUID)(g);
}
static u32 local_player(void){
    u32 mgr=rd32(OBJMGR_GLOBAL),lo,hi;
    if(!ptr_ok(mgr))return 0u;
    lo=rd32(mgr+OM_LOCAL_GUID_LO);hi=rd32(mgr+OM_LOCAL_GUID_HI);
    if(!lo&&!hi)return 0u;
    return find_object(lo,hi);
}
static u32 snapshot_positions(u32 target,u32 *type,u32 *dist100,s32 *px,s32 *py,s32 *pz,s32 *tx,s32 *ty,s32 *tz){
    u32 p=local_player();float x,y,z,a,b,c,dx,dy,dz;
    *type=0u;*dist100=0u;*px=*py=*pz=*tx=*ty=*tz=0;
    if(ptr_ok(p)){
        x=*(volatile float*)(u32)(p+OBJ_POS_X);y=*(volatile float*)(u32)(p+OBJ_POS_Y);z=*(volatile float*)(u32)(p+OBJ_POS_Z);
        *px=scale100(x);*py=scale100(y);*pz=scale100(z);
    }else return 0u;
    if(!ptr_ok(target))return 0u;
    *type=rd32(target+OBJ_TYPE_OFF);
    a=*(volatile float*)(u32)(target+OBJ_POS_X);b=*(volatile float*)(u32)(target+OBJ_POS_Y);c=*(volatile float*)(u32)(target+OBJ_POS_Z);
    *tx=scale100(a);*ty=scale100(b);*tz=scale100(c);
    dx=x-a;dy=y-b;dz=z-c;
    *dist100=(u32)(fsqrt_pos(dx*dx+dy*dy+dz*dz)*100.0f);
    return 1u;
}

static void observe_send(DataStore5875 *packet){
    PacketRecord *r;u8 *raw;u32 n,i,head;
    if(g_injecting||!packet)return;
    raw=packet_raw(packet);if(!raw||packet->size<4u)return;
    n=packet->size;if(n>MAX_PACKET_COPY)n=MAX_PACKET_COPY;
    head=g_sendHead;r=&g_ring[head%PACKET_RING_CAP];
    r->tick=GetTickCount();r->opcode=*(u32*)raw;r->len=packet->size;r->owner=packet->owner;
    r->guidLo=(packet->size>=12u)?*(u32*)(raw+4u):0u;
    r->guidHi=(packet->size>=12u)?*(u32*)(raw+8u):0u;
    r->guidOffset=(packet->size>=12u)?4u:0u;
    for(i=0u;i<n;i++)r->bytes[i]=raw[i];
    r->hash=fnv1a(r->bytes,n);
    MemoryBarrier();
    g_sendHead=head+1u;
}

NAKED static void SendWrapper(void){
#if defined(_MSC_VER)
    __asm {
        pushfd
        pushad
        push ecx
        call observe_send
        add esp,4
        popad
        popfd
        mov eax,dword ptr [g_nextSend]
        jmp eax
    }
#else
    __asm__ __volatile__("pushf; pusha; pushl %ecx; call _observe_send; addl $4,%esp; popa; popf; movl _g_nextSend,%eax; jmp *%eax");
#endif
}

static int type_matches(u32 svc,u32 type){
    if(svc==SERVICE_MAIL)return type==5u;
    if(svc==SERVICE_BANK||svc==SERVICE_AH)return type==3u;
    return 0;
}
static void recent_ops_text(char *out,u32 cap,u32 now){
    u32 p=0u,head=g_sendHead,count=head<PACKET_RING_CAP?head:PACKET_RING_CAP,i,start=head-count,shown=0u;
    out[0]=0;
    for(i=0u;i<count;i++){
        PacketRecord *r=&g_ring[(start+i)%PACKET_RING_CAP];
        if((u32)(now-r->tick)>LEARN_WINDOW_MS)continue;
        if(shown++)append_char(out,cap,&p,',');
        append_hex32(out,cap,&p,r->opcode);append_char(out,cap,&p,'/');
        append_u32(out,cap,&p,r->len);append_char(out,cap,&p,'/');
        append_u32(out,cap,&p,(u32)(now-r->tick));
        if(shown>=14u)break;
    }
}
static PacketRecord *choose_candidate(u32 svc,u32 now,u32 *objOut,u32 *typeOut,u32 *distOut,
                                      s32 *px,s32 *py,s32 *pz,s32 *tx,s32 *ty,s32 *tz,
                                      u32 *guidLoOut,u32 *guidHiOut,u32 *guidOffOut){
    u32 head=g_sendHead,count=head<PACKET_RING_CAP?head:PACKET_RING_CAP,i,start=head-count;
    PacketRecord *best=0;u32 bestScore=0u,bestObj=0u,bestType=0u,bestDist=0u,bestLo=0u,bestHi=0u,bestOff=0u;
    s32 bpx=0,bpy=0,bpz=0,btx=0,bty=0,btz=0;
    for(i=0u;i<count;i++){
        PacketRecord *r=&g_ring[(start+i)%PACKET_RING_CAP];u32 age,off,maxOff;
        if(!r->tick||r->len<12u||r->len>MAX_PACKET_COPY)continue;
        age=now-r->tick;if(age>LEARN_WINDOW_MS)continue;
        if(svc==SERVICE_AH&&r->opcode==OPCODE_AH_LIST)continue;
        maxOff=r->len>=8u?r->len-8u:0u;if(maxOff>40u)maxOff=40u;
        for(off=4u;off<=maxOff;off+=4u){
            u32 lo=*(u32*)(r->bytes+off),hi=*(u32*)(r->bytes+off+4u);
            u32 obj,type,dist,score=0u; s32 x,y,z,a,b,c;
            if(!lo&&!hi)continue;
            obj=find_object(lo,hi);if(!ptr_ok(obj))continue;
            if(!snapshot_positions(obj,&type,&dist,&x,&y,&z,&a,&b,&c))continue;
            if(type!=3u&&type!=5u)continue;
            /* Service identity is a hard gate, not a scoring hint.
             * MAIL_SHOW must never learn a nearby unit/AH GUID and AH/BANK
             * must never learn a GameObject GUID. */
            if(!type_matches(svc,type))continue;
            score=170u;
            if(age<=180u)score+=60u;else if(age<=450u)score+=40u;else if(age<=900u)score+=20u;
            if(r->len<=32u)score+=30u;else if(r->len<=96u)score+=15u;
            if(off==4u)score+=10u;
            if(score>=bestScore){
                bestScore=score;best=r;bestObj=obj;bestType=type;bestDist=dist;bestLo=lo;bestHi=hi;bestOff=off;
                bpx=x;bpy=y;bpz=z;btx=a;bty=b;btz=c;
            }
        }
    }
    if(best){
        *objOut=bestObj;*typeOut=bestType;*distOut=bestDist;
        *px=bpx;*py=bpy;*pz=bpz;*tx=btx;*ty=bty;*tz=btz;
        *guidLoOut=bestLo;*guidHiOut=bestHi;*guidOffOut=bestOff;
    }
    return best;
}
static void packet_detail(const PacketRecord *r,char *out,u32 cap,u32 includeBytes){
    u32 p=0u,n;
    out[0]=0;if(!r)return;
    append_text(out,cap,&p,"opcode=");append_hex32(out,cap,&p,r->opcode);
    append_text(out,cap,&p," len=");append_u32(out,cap,&p,r->len);
    append_text(out,cap,&p," owner=");append_hex32(out,cap,&p,r->owner);
    append_text(out,cap,&p," guid=");append_hex32(out,cap,&p,r->guidHi);append_char(out,cap,&p,':');append_hex32(out,cap,&p,r->guidLo);
    append_text(out,cap,&p," guidoff=");append_u32(out,cap,&p,r->guidOffset);
    append_text(out,cap,&p," hash=");append_hex32(out,cap,&p,r->hash);
    if(includeBytes){
        n=r->len<MAX_PACKET_COPY?r->len:MAX_PACKET_COPY;
        if(n>SUMMARY_PACKET_BYTES)n=SUMMARY_PACKET_BYTES;
        append_text(out,cap,&p," bytes=");append_hex_bytes(out,cap,&p,r->bytes,n);
    }
}
static void learn_service(u32 svc,u32 now){
    PacketRecord *r;LearnedService *l=&g_learn[svc];u32 obj=0u,type=0u,dist=0u,glo=0u,ghi=0u,goff=0u; s32 px=0,py=0,pz=0,tx=0,ty=0,tz=0;
    static char detail[1500],recent[900];u32 same=0u,i,n;
    r=choose_candidate(svc,now,&obj,&type,&dist,&px,&py,&pz,&tx,&ty,&tz,&glo,&ghi,&goff);
    if(!r){
        recent_ops_text(recent,sizeof(recent),now);
        wsprintfA(detail,"no safe GUID-bearing opener candidate; recent=%s",recent);
        log_line("learn_fail",svc,0u,0u,0u,0u,0u,0u,0u,0u,px,py,pz,0,0,0,detail);
        if(g_verbose)lua_chat("learn FAIL: brak bezpiecznego pakietu otwarcia; zapisano diagnostyke");
        return;
    }
    same=l->valid&&l->packet.opcode==r->opcode&&l->packet.len==r->len;
    l->valid=1u;l->captures+=1u;l->sameShape=same?(l->sameShape+1u):1u;l->learnedAt=now;
    l->objectType=type;l->learnDist100=dist;l->tx100=tx;l->ty100=ty;l->tz100=tz;
    l->packet.tick=r->tick;l->packet.opcode=r->opcode;l->packet.len=r->len;l->packet.owner=r->owner;
    l->packet.guidLo=glo;l->packet.guidHi=ghi;l->packet.guidOffset=goff;l->packet.hash=r->hash;
    n=r->len<MAX_PACKET_COPY?r->len:MAX_PACKET_COPY;
    for(i=0u;i<n;i++)l->packet.bytes[i]=r->bytes[i];
    packet_detail(&l->packet,detail,sizeof(detail),1u);
    recent_ops_text(recent,sizeof(recent),now);
    {
        static char full[1500];wsprintfA(full,"%s recent=%s",detail,recent);str_copy(detail,sizeof(detail),full);
    }
    log_line("learn_ok",svc,0u,r->opcode,r->len,glo,ghi,1u,type,dist,px,py,pz,tx,ty,tz,detail);
    if(g_verbose){
        char m[220];
        wsprintfA(m,"learn OK %s: opcode 0x%04X len %lu, GUIDoff=%lu dist100=%lu",service_name(svc),r->opcode,r->len,goff,dist);
        lua_chat(m);
    }
}

static u32 distance_bucket(u32 svc,u32 *loaded,u32 *type,u32 *dist,
                           s32 *px,s32 *py,s32 *pz,s32 *tx,s32 *ty,s32 *tz){
    LearnedService *l=&g_learn[svc];u32 obj;
    *loaded=0u;*type=0u;*dist=0u;*px=*py=*pz=*tx=*ty=*tz=0;
    if(!l->valid)return 5u;
    obj=find_object(l->packet.guidLo,l->packet.guidHi);
    if(!ptr_ok(obj)){
        u32 p=local_player();
        if(ptr_ok(p)){*px=scale100(*(float*)(u32)(p+OBJ_POS_X));*py=scale100(*(float*)(u32)(p+OBJ_POS_Y));*pz=scale100(*(float*)(u32)(p+OBJ_POS_Z));}
        return 5u;
    }
    *loaded=snapshot_positions(obj,type,dist,px,py,pz,tx,ty,tz);
    if(!*loaded)return 5u;
    if(*dist<=600u)return 0u;
    if(*dist<=1200u)return 1u;
    if(*dist<=3000u)return 2u;
    if(*dist<=8000u)return 3u;
    return 4u;
}
static void replay_learned(u32 svc){
    LearnedService *l=&g_learn[svc];DataStore5875 p;u8 local[MAX_PACKET_COPY];u32 i,n;
    if(!l->valid||!g_nextSend||l->packet.len>MAX_PACKET_COPY)return;
    n=l->packet.len;for(i=0u;i<n;i++)local[i]=l->packet.bytes[i];
    p.owner=l->packet.owner;p.data=local;p.cursor=0u;p.capacity=MAX_PACKET_COPY;p.size=n;p.reserved=0u;
    g_injecting=1u;
    ((void(THISCALL*)(DataStore5875*))(u32)g_nextSend)(&p);
    g_injecting=0u;
}
static void write_summary(void){
    static char d[3000];u32 p=0u,s,n;
    d[0]=0;
    append_text(d,sizeof(d),&p,"SAFE opener-only probe; no item move/bid/buy/mail-send/position spoof. ");
    for(s=1u;s<=SERVICE_MAX;s++){
        LearnedService *l=&g_learn[s];
        if(s>1u)append_text(d,sizeof(d),&p," | ");
        append_text(d,sizeof(d),&p,service_name(s));append_char(d,sizeof(d),&p,':');
        if(!l->valid){append_text(d,sizeof(d),&p,"unlearned");continue;}
        append_text(d,sizeof(d),&p,"op=");append_hex32(d,sizeof(d),&p,l->packet.opcode);
        append_text(d,sizeof(d),&p,",len=");append_u32(d,sizeof(d),&p,l->packet.len);
        append_text(d,sizeof(d),&p,",guid=");append_hex32(d,sizeof(d),&p,l->packet.guidHi);append_char(d,sizeof(d),&p,':');append_hex32(d,sizeof(d),&p,l->packet.guidLo);
        append_text(d,sizeof(d),&p,",goff=");append_u32(d,sizeof(d),&p,l->packet.guidOffset);
        append_text(d,sizeof(d),&p,",captures=");append_u32(d,sizeof(d),&p,l->captures);
        append_text(d,sizeof(d),&p,",shape=");append_u32(d,sizeof(d),&p,l->sameShape);
        append_text(d,sizeof(d),&p,",pass=");append_u32(d,sizeof(d),&p,g_pass[s]);
        append_text(d,sizeof(d),&p,",fail=");append_u32(d,sizeof(d),&p,g_fail[s]);
        append_text(d,sizeof(d),&p,",hash=");append_hex32(d,sizeof(d),&p,l->packet.hash);
        n=l->packet.len<MAX_PACKET_COPY?l->packet.len:MAX_PACKET_COPY;if(n>SUMMARY_PACKET_BYTES)n=SUMMARY_PACKET_BYTES;
        append_text(d,sizeof(d),&p,",bytes=");append_hex_bytes(d,sizeof(d),&p,l->packet.bytes,n);
    }
    log_line("summary",0u,g_testAttempt,0u,0u,0u,0u,0u,0u,0u,0,0,0,0,0,0,d);
}
static void finish_test(u32 pass,const char *why,u32 now){
    u32 svc=g_testService,loaded,type,dist,bucket; s32 px,py,pz,tx,ty,tz;static char d[700];
    if(!g_testActive)return;
    bucket=distance_bucket(svc,&loaded,&type,&dist,&px,&py,&pz,&tx,&ty,&tz);
    wsprintfA(d,"%s latency_ms=%lu bucket=%lu data_seen=%lu last_error=%s",
              why?why:"",now-g_testSentAt,bucket,g_testDataSeen,g_testLastError[0]?g_testLastError:"none");
    if(pass)++g_pass[svc];else ++g_fail[svc];
    log_line(pass?"test_pass":"test_fail",svc,g_testAttempt,g_learn[svc].packet.opcode,g_learn[svc].packet.len,
             g_learn[svc].packet.guidLo,g_learn[svc].packet.guidHi,loaded,type,dist,px,py,pz,tx,ty,tz,d);
    if(g_verbose){
        char m[260];wsprintfA(m,"%s %s: %s, dist100=%lu, loaded=%lu",pass?"PASS":"FAIL",service_name(svc),why?why:"",dist,loaded);
        lua_chat(m);
    }
    g_testActive=0u;g_testService=0u;g_testSentAt=0u;g_testDataSeen=0u;g_testLastError[0]=0;
    if(g_sweepService)g_sweepNextAt=now+SWEEP_RETRY_MS;
    write_summary();
}
static int start_test(u32 svc,u32 now){
    LearnedService *l=&g_learn[svc];u32 loaded,type,dist,bucket; s32 px,py,pz,tx,ty,tz;static char d[1000];
    if(g_testActive||!g_luaReady)return 0;
    if(!g_hookHealthy||decode_jump(ADDR_CLIENT_SEND)!=(u32)(void*)&SendWrapper){
        log_line("test_blocked",svc,0u,0u,0u,0u,0u,0u,0u,0u,0,0,0,0,0,0,"send hook chain not healthy");
        lua_chat("test blocked: ClientServices send hook chain changed; wyslij raport");
        return 0;
    }
    if(!l->valid){
        log_line("test_blocked",svc,0u,0u,0u,0u,0u,0u,0u,0u,0,0,0,0,0,0,"service not learned; open it normally once first");
        lua_chat("test blocked: najpierw normalnie otworz te usluge raz");
        return 0;
    }
    refresh_context();
    if(service_visible(svc)){
        log_line("test_blocked",svc,0u,l->packet.opcode,l->packet.len,l->packet.guidLo,l->packet.guidHi,0u,0u,0u,0,0,0,0,0,0,"service frame already visible; close it before replay");
        if(g_verbose)lua_chat("test paused: zamknij okno uslugi przed replay");
        return 0;
    }
    bucket=distance_bucket(svc,&loaded,&type,&dist,&px,&py,&pz,&tx,&ty,&tz);
    ++g_testAttempt;g_testActive=1u;g_testService=svc;g_testSentAt=now;
    g_testStartOpenSeq=g_lastOpenSeq;g_testStartDataSeq=g_lastDataSeq;g_testDataSeen=0u;g_testLastError[0]=0;
    packet_detail(&l->packet,d,sizeof(d),1u);
    {
        static char extra[1500];wsprintfA(extra,"%s bucket=%lu learned_type=%lu captures=%lu shape=%lu",d,bucket,l->objectType,l->captures,l->sameShape);
        log_line("test_send",svc,g_testAttempt,l->packet.opcode,l->packet.len,l->packet.guidLo,l->packet.guidHi,loaded,type,dist,px,py,pz,tx,ty,tz,extra);
    }
    replay_learned(svc);
    return 1;
}
static void sweep_tick(u32 now){
    u32 loaded,type,dist,bucket; s32 px,py,pz,tx,ty,tz;
    if(!g_sweepService||g_testActive||(s32)(now-g_sweepNextAt)<0)return;
    bucket=distance_bucket(g_sweepService,&loaded,&type,&dist,&px,&py,&pz,&tx,&ty,&tz);
    if(bucket>5u)bucket=5u;
    if(g_sweepAttempts[bucket]>=2u){g_sweepNextAt=now+1000u;return;}
    refresh_context();
    if(service_visible(g_sweepService)){g_sweepNextAt=now+1000u;return;}
    ++g_sweepAttempts[bucket];
    if(!start_test(g_sweepService,now))g_sweepNextAt=now+1500u;
}

static void clear_service(u32 svc){
    u32 i;u8 *p=(u8*)&g_learn[svc];
    for(i=0u;i<sizeof(LearnedService);i++)p[i]=0u;
    g_pass[svc]=g_fail[svc]=0u;
}
static int starts_ci(const char *s,const char *w){
    char a,b;
    if(!s||!w)return 0;
    while(*w){
        if(!*s)return 0;
        a=*s++;b=*w++;
        if(a>='A'&&a<='Z')a=(char)(a-'A'+'a');
        if(b>='A'&&b<='Z')b=(char)(b-'A'+'a');
        if(a!=b)return 0;
    }
    return 1;
}
static u32 parse_service_word(const char *s){
    while(s&&(*s==' '||*s=='\t'))++s;
    if(!s)return 0u;
    if(starts_ci(s,"bank"))return SERVICE_BANK;
    if(starts_ci(s,"mail"))return SERVICE_MAIL;
    if(starts_ci(s,"ah"))return SERVICE_AH;
    return 0u;
}
static const char *after_word(const char *s){
    while(s&&*s&&*s!=' '&&*s!='\t')++s;
    while(s&&(*s==' '||*s=='\t'))++s;
    return s;
}
static void status_chat(void){
    char m[420];
    wsprintfA(m,"bank=%lu(op=%04X) mail=%lu(op=%04X) ah=%lu(op=%04X) test=%lu sweep=%s log=%s",
      g_learn[SERVICE_BANK].valid,g_learn[SERVICE_BANK].packet.opcode,
      g_learn[SERVICE_MAIL].valid,g_learn[SERVICE_MAIL].packet.opcode,
      g_learn[SERVICE_AH].valid,g_learn[SERVICE_AH].packet.opcode,
      g_testActive,service_name(g_sweepService),g_logPath[0]?g_logPath:"pending");
    lua_chat(m);
}
static void handle_command(const char *cmd,u32 now){
    u32 svc,i;const char *arg;
    if(!cmd)cmd="";
    while(*cmd==' '||*cmd=='\t')++cmd;
    if(!*cmd||lstrcmpiA(cmd,"help")==0){
        lua_chat("komendy: /rsp status | test bank/mail/ah | sweep bank/mail/ah | stop | clear bank/mail/ah/all | summary | verbose on/off");
        return;
    }
    if(lstrcmpiA(cmd,"status")==0){status_chat();write_summary();return;}
    if(lstrcmpiA(cmd,"summary")==0||lstrcmpiA(cmd,"report")==0){write_summary();lua_chat("summary zapisane; teraz mozesz wyslac raport updaterem");return;}
    if(lstrcmpiA(cmd,"stop")==0){g_sweepService=0u;if(g_testActive)finish_test(0u,"stopped_by_user",now);lua_chat("sweep/test STOP");return;}
    if(lstrcmpiA(cmd,"verbose on")==0){g_verbose=1u;lua_chat("verbose ON");return;}
    if(lstrcmpiA(cmd,"verbose off")==0){g_verbose=0u;lua_chat("verbose OFF");return;}
    if(lstrcmpiA(cmd,"clear all")==0){for(i=1u;i<=SERVICE_MAX;i++)clear_service(i);write_summary();lua_chat("learned state cleared");return;}
    if(starts_ci(cmd,"clear")){
        arg=after_word(cmd);svc=parse_service_word(arg);if(svc){clear_service(svc);write_summary();lua_chat("service learned state cleared");}else lua_chat("clear: bank/mail/ah/all");return;
    }
    if(starts_ci(cmd,"test")){
        arg=after_word(cmd);svc=parse_service_word(arg);if(svc){g_sweepService=0u;(void)start_test(svc,now);}else lua_chat("test: bank/mail/ah");return;
    }
    if(starts_ci(cmd,"sweep")){
        arg=after_word(cmd);svc=parse_service_word(arg);
        if(!svc){lua_chat("sweep: bank/mail/ah");return;}
        if(!g_learn[svc].valid){lua_chat("sweep blocked: najpierw normalnie otworz usluge raz");return;}
        g_sweepService=svc;for(i=0u;i<6u;i++)g_sweepAttempts[i]=0u;g_sweepNextAt=now+250u;
        lua_chat("SWEEP ON: oddalaj sie; max 2 bezpieczne opener replay na bucket, po sukcesie zamknij okno");
        log_line("sweep_start",svc,0u,g_learn[svc].packet.opcode,g_learn[svc].packet.len,g_learn[svc].packet.guidLo,g_learn[svc].packet.guidHi,0u,0u,0u,0,0,0,0,0,0,"buckets <=6, <=12, <=30, <=80, >80, unloaded; max2 each");
        return;
    }
    lua_chat("nieznana komenda; /rsp help");
}
static int install_lua(void){
    static const char script[]=
      "if not W112_RSP_LUA_READY then "
      "W112_RSP_CMDSEQ=0;W112_RSP_CMD='';W112_RSP_OPEN_SEQ=0;W112_RSP_OPEN_NAME='';"
      "W112_RSP_CLOSE_SEQ=0;W112_RSP_CLOSE_NAME='';W112_RSP_ERROR_SEQ=0;W112_RSP_ERROR_TEXT='';"
      "W112_RSP_DATA_SEQ=0;W112_RSP_DATA_NAME='';"
      "local f=CreateFrame('Frame');"
      "f:RegisterEvent('BANKFRAME_OPENED');f:RegisterEvent('BANKFRAME_CLOSED');"
      "f:RegisterEvent('MAIL_SHOW');f:RegisterEvent('MAIL_CLOSED');"
      "f:RegisterEvent('AUCTION_HOUSE_SHOW');f:RegisterEvent('AUCTION_HOUSE_CLOSED');"
      "f:RegisterEvent('UI_ERROR_MESSAGE');f:RegisterEvent('MAIL_INBOX_UPDATE');"
      "f:RegisterEvent('AUCTION_ITEM_LIST_UPDATE');f:RegisterEvent('PLAYERBANKSLOTS_CHANGED');"
      "f:SetScript('OnEvent',function() "
      "if event=='BANKFRAME_OPENED' or event=='MAIL_SHOW' or event=='AUCTION_HOUSE_SHOW' then "
      "W112_RSP_OPEN_SEQ=W112_RSP_OPEN_SEQ+1;W112_RSP_OPEN_NAME=event;"
      "elseif event=='BANKFRAME_CLOSED' or event=='MAIL_CLOSED' or event=='AUCTION_HOUSE_CLOSED' then "
      "W112_RSP_CLOSE_SEQ=W112_RSP_CLOSE_SEQ+1;W112_RSP_CLOSE_NAME=event;"
      "elseif event=='UI_ERROR_MESSAGE' then W112_RSP_ERROR_SEQ=W112_RSP_ERROR_SEQ+1;W112_RSP_ERROR_TEXT=tostring(arg1 or '');"
      "else W112_RSP_DATA_SEQ=W112_RSP_DATA_SEQ+1;W112_RSP_DATA_NAME=event;end end);"
      "SLASH_W112RSP1='/rsp';SlashCmdList['W112RSP']=function(msg) "
      "W112_RSP_CMDSEQ=W112_RSP_CMDSEQ+1;W112_RSP_CMD=msg or '';end;"
      "W112_RSP_LUA_READY=1;"
      "if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage('|cff66ccff[RSP]|r Remote Service Probe ready. Normalnie otworz bank/mail/AH raz, potem /rsp help') end "
      "end";
    lua_exec(script,"RemoteServiceProbeInit");
    return parse_u32(lua_get("W112_RSP_LUA_READY"))?1:0;
}
static void poll_lua(u32 now){
    u32 seq,svc;const char *v,*name,*err,*cmd;
    if((u32)(now-g_lastHookCheck)>=1000u){
        u32 cur;g_lastHookCheck=now;cur=decode_jump(ADDR_CLIENT_SEND);
        if(cur!=(u32)(void*)&SendWrapper){
            if(g_hookHealthy)log_line("hook_chain_changed",0u,0u,0u,0u,0u,0u,0u,0u,0u,0,0,0,0,0,0,"ClientServices::Send entry no longer points to RSP wrapper; active replay disabled");
            g_hookHealthy=0u;
        }else g_hookHealthy=1u;
    }
    if(g_luaReady && !parse_u32(lua_get("W112_RSP_LUA_READY"))){
        g_luaReady=0u;g_lastCmdSeq=0u;g_lastOpenSeq=0u;g_lastCloseSeq=0u;g_lastErrorSeq=0u;g_lastDataSeq=0u;
        log_line("lua_reset_detected",0u,0u,0u,0u,0u,0u,0u,0u,0u,0,0,0,0,0,0,"Lua globals disappeared (reload/login transition); reinstall pending");
    }
    if(!g_luaReady){
        if(!ptr_ok(local_player()))return;
        if((u32)(now-g_lastLuaTry)<LUA_RETRY_MS)return;
        g_lastLuaTry=now;
        g_luaReady=install_lua()?1u:0u;
        if(g_luaReady){refresh_context();log_line("lua_ready",0u,0u,0u,0u,0u,0u,0u,0u,0u,0,0,0,0,0,0,"events/slash/context installed");}
        return;
    }
    refresh_context();
    v=lua_get("W112_RSP_CMDSEQ");seq=parse_u32(v);
    if(seq!=g_lastCmdSeq){
        g_lastCmdSeq=seq;cmd=lua_get("W112_RSP_CMD");handle_command(cmd,now);
    }
    v=lua_get("W112_RSP_OPEN_SEQ");seq=parse_u32(v);
    if(seq!=g_lastOpenSeq){
        g_lastOpenSeq=seq;name=lua_get("W112_RSP_OPEN_NAME");svc=service_from_open(name);
        if(svc){
            if(g_testActive&&svc==g_testService&&g_testSentAt)finish_test(1u,"expected_open_event",now);
            else learn_service(svc,now);
        }
    }
    v=lua_get("W112_RSP_DATA_SEQ");seq=parse_u32(v);
    if(seq!=g_lastDataSeq){
        g_lastDataSeq=seq;name=lua_get("W112_RSP_DATA_NAME");
        if(g_testActive){
            g_testDataSeen=1u;
            log_line("data_event",g_testService,g_testAttempt,g_learn[g_testService].packet.opcode,g_learn[g_testService].packet.len,
                     g_learn[g_testService].packet.guidLo,g_learn[g_testService].packet.guidHi,0u,0u,0u,0,0,0,0,0,0,name?name:"");
        }
    }
    v=lua_get("W112_RSP_ERROR_SEQ");seq=parse_u32(v);
    if(seq!=g_lastErrorSeq){
        g_lastErrorSeq=seq;err=lua_get("W112_RSP_ERROR_TEXT");str_copy(g_testLastError,sizeof(g_testLastError),err);
        if(g_testActive)log_line("ui_error",g_testService,g_testAttempt,g_learn[g_testService].packet.opcode,g_learn[g_testService].packet.len,
                                g_learn[g_testService].packet.guidLo,g_learn[g_testService].packet.guidHi,0u,0u,0u,0,0,0,0,0,0,err?err:"");
    }
    v=lua_get("W112_RSP_CLOSE_SEQ");seq=parse_u32(v);
    if(seq!=g_lastCloseSeq){g_lastCloseSeq=seq;name=lua_get("W112_RSP_CLOSE_NAME");log_line("close_event",0u,0u,0u,0u,0u,0u,0u,0u,0u,0,0,0,0,0,0,name?name:"");}
    if(g_testActive&&(u32)(now-g_testSentAt)>=TEST_TIMEOUT_MS)finish_test(0u,"timeout_no_open_event",now);
    sweep_tick(now);
}
static VOID CALLBACK timer_proc(HWND hwnd,UINT msg,UINT_PTR id,DWORD time){
    (void)hwnd;(void)msg;(void)id;(void)time;
    if(!g_installed)return;
    poll_lua(GetTickCount());
}
static int install(void){
    u32 prev;
    if(!prepare_log())return 0;
    log_line("load",0u,0u,0u,0u,0u,0u,0u,0u,0u,0,0,0,0,0,0,"Remote Service Probe V1 loading");
    if(!build_guard()){log_line("install_fail",0u,0u,0u,0u,0u,0u,0u,0u,0u,0,0,0,0,0,0,"build guard/client send chain failed");return 0;}
    prev=decode_jump(ADDR_CLIENT_SEND);if(!ptr_ok(prev)){log_line("install_fail",0u,0u,0u,0u,0u,0u,0u,0u,0u,0,0,0,0,0,0,"no chain target");return 0;}
    g_nextSend=prev;
    if(!patch_jump(ADDR_CLIENT_SEND,(u32)(void*)&SendWrapper)){log_line("install_fail",0u,0u,0u,0u,0u,0u,0u,0u,0u,0,0,0,0,0,0,"send hook patch failed");return 0;}
    g_timer=SetTimer(NULL,0,TIMER_MS,timer_proc);
    if(!g_timer){if(decode_jump(ADDR_CLIENT_SEND)==(u32)(void*)&SendWrapper)patch_jump(ADDR_CLIENT_SEND,g_nextSend);g_nextSend=0u;return 0;}
    g_installed=1u;g_hookHealthy=1u;
    {
        char d[240];wsprintfA(d,"ordered ClientServices::Send observer installed; chain_prev=0x%08X wrapper=0x%08X; opener replay fail-closed",g_nextSend,(u32)(void*)&SendWrapper);
        log_line("installed",0u,0u,0u,0u,0u,0u,0u,0u,0u,0,0,0,0,0,0,d);
    }
    return 1;
}
/* Read-only in-process provider for consumers such as MarketWorker.
 * No packet is sent and no service frame is touched by these exports. */
__declspec(dllexport) u32 STDCALL W112_RSP_GetLearnedGuid(
    u32 service,u32 *guidLo,u32 *guidHi,u32 *objectType,u32 *learnDist100)
{
    LearnedService *l;
    if(service<1u||service>SERVICE_MAX)return 0u;
    l=&g_learn[service];
    if(!l->valid||!type_matches(service,l->objectType))return 0u;
    if(guidLo)*guidLo=l->packet.guidLo;
    if(guidHi)*guidHi=l->packet.guidHi;
    if(objectType)*objectType=l->objectType;
    if(learnDist100)*learnDist100=l->learnDist100;
    return 1u;
}
__declspec(dllexport) u32 STDCALL W112_RSP_GetLearnedMask(void)
{
    u32 mask=0u,s;
    for(s=1u;s<=SERVICE_MAX;s++)if(g_learn[s].valid)mask|=(1u<<(s-1u));
    return mask;
}

/* Local-only opener fallback for MarketWorker. This is intentionally restricted
 * to the auctioneer service and normal melee interaction range. It never moves
 * the player or spoofs coordinates; it only replays the exact opener learned
 * while the same loaded auctioneer object is physically in range. */
__declspec(dllexport) u32 STDCALL W112_RSP_ReplayLocalOpener(u32 service,u32 maxDist100)
{
    LearnedService *l;u32 loaded=0u,type=0u,dist=0u,bucket; s32 px,py,pz,tx,ty,tz;char d[260];
    if(service!=SERVICE_AH)return 2u;
    if(maxDist100==0u||maxDist100>600u)maxDist100=600u;
    l=&g_learn[service];
    if(!l->valid||!type_matches(service,l->objectType))return 3u;
    if(!g_hookHealthy||decode_jump(ADDR_CLIENT_SEND)!=(u32)(void*)&SendWrapper||!g_nextSend)return 4u;
    bucket=distance_bucket(service,&loaded,&type,&dist,&px,&py,&pz,&tx,&ty,&tz);
    if(!loaded||type!=3u)return 5u;
    if(dist>maxDist100)return 6u;
    refresh_context();
    if(service_visible(service))return 7u;
    replay_learned(service);
    wsprintfA(d,"local worker opener replay bucket=%lu dist100=%lu max=%lu type=%lu",bucket,dist,maxDist100,type);
    log_line("local_replay",service,0u,l->packet.opcode,l->packet.len,l->packet.guidLo,l->packet.guidHi,
             loaded,type,dist,px,py,pz,tx,ty,tz,d);
    return 1u;
}

static void uninstall(int terminating){
    u32 cur;
    g_installed=0u;
    if(terminating){g_timer=0;g_nextSend=0u;return;}
    if(g_timer){KillTimer(NULL,g_timer);g_timer=0;}
    cur=decode_jump(ADDR_CLIENT_SEND);
    if(cur==(u32)(void*)&SendWrapper&&g_nextSend)patch_jump(ADDR_CLIENT_SEND,g_nextSend);
    write_summary();
    g_nextSend=0u;
}
BOOL WINAPI DllMain(HINSTANCE h,DWORD reason,LPVOID reserved){
    (void)h;
    if(reason==DLL_PROCESS_ATTACH){DisableThreadLibraryCalls(h);(void)install();}
    else if(reason==DLL_PROCESS_DETACH)uninstall(reserved!=NULL);
    return TRUE;
}
