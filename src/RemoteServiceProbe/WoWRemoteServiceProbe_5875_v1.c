/*
 * WoWRemoteServiceProbe_5875_v1.c
 * Diagnostic-only remote service handshake probe for WoW 1.12.1 build 5875.
 *
 * Learns the exact outbound packet used by the live realm for BANK / MAIL / AH
 * after one normal nearby interaction, then replays that exact packet on demand.
 * It does not move the player, spoof position, move items, send mail, bid/buy,
 * or call service APIs beyond the learned open/list handshake.
 *
 * Commands:
 *   /rsp arm bank|mail|ah   - arm passive learning; then open the service normally
 *   /rsp test bank|mail|ah  - replay exact learned handshake from current position
 *   /rsp status             - print learned packet/GUID/object/distance state
 *   /rsp dump               - print last test result and log location
 *   /rsp reset bank|mail|ah|all
 *
 * Deep evidence is appended to .wow112_debug\RemoteServiceProbe.log
 */
typedef unsigned char u8;
typedef unsigned short u16;
typedef unsigned long u32;
typedef signed long s32;
typedef unsigned long long u64;
typedef int BOOL32;
typedef void* HANDLE32;
typedef void* HWND32;
typedef u32 UINT32;
typedef u32 UINT_PTR32;

#define STDCALL __stdcall
#define FASTCALL __fastcall
#define THISCALL __thiscall
#define NAKED __declspec(naked)

__declspec(dllimport) BOOL32 STDCALL VirtualProtect(void*,u32,u32,u32*);
__declspec(dllimport) BOOL32 STDCALL FlushInstructionCache(HANDLE32,const void*,u32);
__declspec(dllimport) HANDLE32 STDCALL GetCurrentProcess(void);
__declspec(dllimport) u32 STDCALL GetTickCount(void);
__declspec(dllimport) BOOL32 STDCALL CreateDirectoryA(const char*,void*);
__declspec(dllimport) HANDLE32 STDCALL CreateFileA(const char*,u32,u32,void*,u32,u32,HANDLE32);
__declspec(dllimport) BOOL32 STDCALL WriteFile(HANDLE32,const void*,u32,u32*,void*);
__declspec(dllimport) BOOL32 STDCALL CloseHandle(HANDLE32);
__declspec(dllimport) UINT_PTR32 STDCALL SetTimer(HWND32,UINT_PTR32,UINT32,void*);
__declspec(dllimport) BOOL32 STDCALL KillTimer(HWND32,UINT_PTR32);

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

#define DLL_PROCESS_DETACH 0u
#define DLL_PROCESS_ATTACH 1u
#define PAGE_EXECUTE_READWRITE32 0x40u
#define INVALID_HANDLE_VALUE32 ((HANDLE32)(u32)0xFFFFFFFFu)
#define FILE_APPEND_DATA32 0x00000004u
#define FILE_SHARE_READ32 0x00000001u
#define OPEN_ALWAYS32 4u
#define FILE_ATTRIBUTE_NORMAL32 0x00000080u
#define FILE_END32 2u

#define ADDR_CLIENT_SEND         0x005AB630u
#define WOW_OBJMGR              0x00B41414u
#define WOW_GET_OBJECT_BY_GUID  0x00464870u
#define WOW_FRAMESCRIPT_GETTEXT 0x00703BF0u
#define WOW_FRAMESCRIPT_EXECUTE 0x00704CD0u
#define OM_LOCAL_GUID_LO        0x00C0u
#define OM_LOCAL_GUID_HI        0x00C4u
#define OBJ_GUID_LO             0x0030u
#define OBJ_GUID_HI             0x0034u
#define OBJ_TYPE_ID             0x0014u
#define OBJ_POS_X               0x09B8u
#define OBJ_POS_Y               0x09BCu
#define OBJ_POS_Z               0x09C0u

#define TIMER_MS 25u
#define MAX_PACKET 512u
#define RING_COUNT 64u
#define LEARN_WINDOW_MS 2500u
#define TEST_TIMEOUT_MS 5000u

typedef struct PacketSnap {
    u32 tick;
    u32 owner;
    u32 len;
    u32 opcode;
    u8 data[MAX_PACKET];
} PacketSnap;

typedef struct ServiceSnap {
    const char *name;
    u32 learned;
    u32 learnedAt;
    u32 owner;
    u32 len;
    u32 opcode;
    u64 guid;
    u8 data[MAX_PACKET];
    u32 learnPx,learnPy,learnPz;
    u32 tests;
    u32 successes;
    u32 timeouts;
    u32 lastSendAt;
    u32 lastResultAt;
    u32 lastResult; /* 0 none,1 success,2 timeout */
    u32 eventSeqAtSend;
} ServiceSnap;

static PacketSnap g_ring[RING_COUNT];
static u32 g_ringWrite=0u;
static ServiceSnap g_services[3]={{"bank",0},{"mail",0},{"ah",0}};
static u32 g_nextSend=0u;
static UINT_PTR32 g_timer=0u;
static u32 g_installed=0u;
static u32 g_lastEventSeq=0u;
static u32 g_lastCmdSeq=0u;
static int g_activeTest=-1;

static int valid_ptr(u32 p){return p>=0x10000u && p<=0x7FFE0000u;}
static u32 read32(u32 a){return *(volatile u32*)(u32)a;}
static int streq(const char*a,const char*b){while(*a&&*b&&*a==*b){a++;b++;}return *a==0&&*b==0;}
static char* cat(char*p,const char*s){while(*s)*p++=*s++;return p;}
static char* dec(char*p,u32 n){char d[11];u32 k=0;do{d[k++]=(char)('0'+n%10u);n/=10u;}while(n);while(k)*p++=d[--k];return p;}
static char* hex32(char*p,u32 n){static const char h[]="0123456789ABCDEF";int i;for(i=7;i>=0;i--)*p++=h[(n>>(i*4))&15u];return p;}
static u32 parse_u32(const char*s){u32 n=0;if(!s)return 0;while(*s>='0'&&*s<='9'){n=n*10u+(u32)(*s-'0');s++;}return n;}
static int service_index(const char*s){if(!s)return -1;if(streq(s,"bank"))return 0;if(streq(s,"mail"))return 1;if(streq(s,"ah"))return 2;return -1;}
static u8* packet_raw(DataStore5875*p){if(!p||!p->data||p->cursor>0x01000000u||p->size>0x01000000u)return 0;return p->data-p->cursor;}
static u32 decode_jump(u32 site){s32 rel;if(*(volatile u8*)(u32)site!=0xE9u)return 0u;rel=*(volatile s32*)(u32)(site+1u);return site+5u+(u32)rel;}
static BOOL32 write_mem(void*dst,const void*src,u32 n){u32 old=0,tmp=0;BOOL32 ok;if(!VirtualProtect(dst,n,PAGE_EXECUTE_READWRITE32,&old))return 0;{u32 i;for(i=0;i<n;i++)((volatile u8*)dst)[i]=((const u8*)src)[i];}FlushInstructionCache(GetCurrentProcess(),dst,n);ok=VirtualProtect(dst,n,old,&tmp);return ok;}
static BOOL32 patch_jump(u32 site,u32 target){u8 p[5];s32 rel=(s32)(target-(site+5u));p[0]=0xE9u;p[1]=(u8)rel;p[2]=(u8)(rel>>8);p[3]=(u8)(rel>>16);p[4]=(u8)(rel>>24);return write_mem((void*)(u32)site,p,5u);}
static void lua_exec(const char*s,const char*tag){((FrameScriptExecuteFn)(u32)WOW_FRAMESCRIPT_EXECUTE)(s,tag);}
static const char* lua_text(const char*name){return ((FrameScriptGetTextFn)(u32)WOW_FRAMESCRIPT_GETTEXT)(name,-1,0u);}

static void log_line(const char*s){
    HANDLE32 h;u32 n=0,w=0;CreateDirectoryA(".wow112_debug",0);
    while(s[n])n++;
    h=CreateFileA(".wow112_debug\\RemoteServiceProbe.log",FILE_APPEND_DATA32,FILE_SHARE_READ32,0,OPEN_ALWAYS32,FILE_ATTRIBUTE_NORMAL32,0);
    if(h!=INVALID_HANDLE_VALUE32){WriteFile(h,s,n,&w,0);WriteFile(h,"\r\n",2u,&w,0);CloseHandle(h);}
}
static void log_packet(const char*prefix,const PacketSnap*q){
    char b[420],*p=b;u32 i,cap=q->len<48u?q->len:48u;
    p=cat(p,prefix);p=cat(p," t=");p=dec(p,q->tick);p=cat(p," op=0x");p=hex32(p,q->opcode);
    p=cat(p," len=");p=dec(p,q->len);p=cat(p," owner=0x");p=hex32(p,q->owner);p=cat(p," bytes=");
    for(i=0;i<cap;i++){static const char h[]="0123456789ABCDEF";*p++=h[(q->data[i]>>4)&15];*p++=h[q->data[i]&15];}
    *p=0;log_line(b);
}
static u32 player_ptr(void){
    u32 om=read32(WOW_OBJMGR),lo,hi;if(!valid_ptr(om))return 0u;
    lo=read32(om+OM_LOCAL_GUID_LO);hi=read32(om+OM_LOCAL_GUID_HI);
    return ((GetObjectByGuidFn)(u32)WOW_GET_OBJECT_BY_GUID)(((u64)hi<<32)|lo);
}
static u32 fbits(u32 obj,u32 off){return valid_ptr(obj)?read32(obj+off):0u;}
static u32 dist100(u32 a,u32 b){
    float dx,dy,dz,d2;if(!valid_ptr(a)||!valid_ptr(b))return 0xFFFFFFFFu;
    dx=*(volatile float*)(a+OBJ_POS_X)-*(volatile float*)(b+OBJ_POS_X);
    dy=*(volatile float*)(a+OBJ_POS_Y)-*(volatile float*)(b+OBJ_POS_Y);
    dz=*(volatile float*)(a+OBJ_POS_Z)-*(volatile float*)(b+OBJ_POS_Z);
    d2=dx*dx+dy*dy+dz*dz;
    if(d2<0.0f||d2>42900000.0f)return 0xFFFFFFFEu;
    return (u32)(d2*100.0f);
}
static void snapshot_pos(ServiceSnap*s){u32 p=player_ptr();s->learnPx=fbits(p,OBJ_POS_X);s->learnPy=fbits(p,OBJ_POS_Y);s->learnPz=fbits(p,OBJ_POS_Z);}

static void capture_packet(DataStore5875*p){
    PacketSnap*q;u8*raw;u32 n,i;
    raw=packet_raw(p);if(!raw||p->size<4u)return;
    n=p->size;if(n>MAX_PACKET)n=MAX_PACKET;
    q=&g_ring[g_ringWrite++%RING_COUNT];q->tick=GetTickCount();q->owner=p->owner;q->len=n;q->opcode=*(u32*)raw;
    for(i=0;i<n;i++)q->data[i]=raw[i];
}
NAKED static void SendWrapper(void){
#if defined(_MSC_VER)
    __asm {
        pushfd
        pushad
        push ecx
        call capture_packet
        add esp,4
        popad
        popfd
        mov eax,dword ptr [g_nextSend]
        jmp eax
    }
#else
    __asm__ __volatile__(
        "pushfl\n\tpushal\n\tpushl %ecx\n\tcall _capture_packet\n\taddl $4,%esp\n\tpopal\n\tpopfl\n\tmovl _g_nextSend,%eax\n\tjmp *%eax\n\t"
    );
#endif
}
static int install_send_hook(void){
    u32 next=decode_jump(ADDR_CLIENT_SEND);
    if(!valid_ptr(next))return 0;
    g_nextSend=next;
    return patch_jump(ADDR_CLIENT_SEND,(u32)(void*)&SendWrapper)?1:0;
}
static void restore_send_hook(void){
    if(*(volatile u8*)(u32)ADDR_CLIENT_SEND==0xE9u && decode_jump(ADDR_CLIENT_SEND)==(u32)(void*)&SendWrapper && valid_ptr(g_nextSend))
        patch_jump(ADDR_CLIENT_SEND,g_nextSend);
}

static PacketSnap* choose_learn_packet(u32 now){
    u32 k;
    for(k=0;k<RING_COUNT;k++){
        u32 idx=(g_ringWrite-1u-k)%RING_COUNT;PacketSnap*q=&g_ring[idx];u64 guid;
        if(!q->tick||now-q->tick>LEARN_WINDOW_MS)break;
        if(q->len<12u)continue;
        guid=*(u64*)(q->data+4u);
        log_packet("LEARN_CANDIDATE",q);
        if(guid!=0u)return q;
    }
    return 0;
}
static void learn_service(int ix,u32 now){
    PacketSnap*q=choose_learn_packet(now);ServiceSnap*s;if(ix<0||ix>2)return;s=&g_services[ix];
    if(!q){log_line("LEARN_FAIL no outbound packet with nonzero GUID in 2500ms window");return;}
    s->learned=1u;s->learnedAt=now;s->owner=q->owner;s->len=q->len;s->opcode=q->opcode;s->guid=*(u64*)(q->data+4u);
    {u32 i;for(i=0;i<q->len;i++)s->data[i]=q->data[i];}
    snapshot_pos(s);
    {
        char b[300],*p=b;p=cat(p,"LEARN_OK service=");p=cat(p,s->name);p=cat(p," op=0x");p=hex32(p,s->opcode);
        p=cat(p," len=");p=dec(p,s->len);p=cat(p," guid=");p=hex32(p,(u32)(s->guid>>32));p=hex32(p,(u32)s->guid);*p=0;log_line(b);
    }
}
static void send_learned(int ix,u32 now,u32 eventSeq){
    ServiceSnap*s;DataStore5875 p;u8 local[MAX_PACKET];u32 i,obj,pl,d100;
    if(ix<0||ix>2)return;s=&g_services[ix];
    if(!s->learned||!s->len||!valid_ptr(g_nextSend)){log_line("TEST_REFUSED service not learned or send chain invalid");return;}
    for(i=0;i<s->len;i++)local[i]=s->data[i];
    obj=((GetObjectByGuidFn)(u32)WOW_GET_OBJECT_BY_GUID)(s->guid);pl=player_ptr();d100=dist100(pl,obj);
    {
      char b[360],*x=b;x=cat(x,"TEST_SEND service=");x=cat(x,s->name);x=cat(x," t=");x=dec(x,now);
      x=cat(x," op=0x");x=hex32(x,s->opcode);x=cat(x," len=");x=dec(x,s->len);
      x=cat(x," object=0x");x=hex32(x,obj);x=cat(x," objType=");x=dec(x,valid_ptr(obj)?read32(obj+OBJ_TYPE_ID):0u);
      x=cat(x," dist2x100=");x=dec(x,d100);x=cat(x," zone=");x=cat(x,lua_text("W112_RSP_ZONE")?lua_text("W112_RSP_ZONE"):"?");
      x=cat(x," subzone=");x=cat(x,lua_text("W112_RSP_SUBZONE")?lua_text("W112_RSP_SUBZONE"):"?");*x=0;log_line(b);
    }
    p.owner=s->owner;p.data=local;p.cursor=0u;p.capacity=MAX_PACKET;p.size=s->len;p.reserved=0u;
    s->tests++;s->lastSendAt=now;s->lastResult=0u;s->eventSeqAtSend=eventSeq;g_activeTest=ix;
    ((void(THISCALL*)(DataStore5875*))(u32)g_nextSend)(&p);
}
static void print_status(void){
    int i;for(i=0;i<3;i++){ServiceSnap*s=&g_services[i];u32 obj=s->learned?((GetObjectByGuidFn)(u32)WOW_GET_OBJECT_BY_GUID)(s->guid):0u;u32 d=dist100(player_ptr(),obj);
      char q[520],*p=q;p=cat(p,"if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage('|cff66ccff[RSP] ");p=cat(p,s->name);
      p=cat(p,"|r learned=");p=dec(p,s->learned);p=cat(p," op=0x");p=hex32(p,s->opcode);p=cat(p," len=");p=dec(p,s->len);
      p=cat(p," obj=");p=dec(p,valid_ptr(obj)?1u:0u);p=cat(p," d2x100=");p=dec(p,d);
      p=cat(p," tests=");p=dec(p,s->tests);p=cat(p," ok=");p=dec(p,s->successes);p=cat(p," timeout=");p=dec(p,s->timeouts);
      p=cat(p,"') end");*p=0;lua_exec(q,"RemoteServiceProbeStatus");
    }
}
static void reset_service(int ix){if(ix>=0&&ix<3){const char*n=g_services[ix].name;u32 i;u8*z=(u8*)&g_services[ix];for(i=0;i<sizeof(ServiceSnap);i++)z[i]=0;g_services[ix].name=n;}}
static void process_command(u32 now){
    const char*seqs=lua_text("W112_RSP_CMD_SEQ"),*cmd=lua_text("W112_RSP_CMD"),*arg=lua_text("W112_RSP_ARG");u32 seq=parse_u32(seqs);int ix;
    if(!seq||seq==g_lastCmdSeq||!cmd)return;g_lastCmdSeq=seq;ix=service_index(arg);
    if(streq(cmd,"arm")){char b[180],*p=b;p=cat(p,"ARM service=");p=cat(p,ix>=0?g_services[ix].name:"invalid");p=cat(p," t=");p=dec(p,now);*p=0;log_line(b);}
    else if(streq(cmd,"test"))send_learned(ix,now,g_lastEventSeq);
    else if(streq(cmd,"status")||streq(cmd,"dump"))print_status();
    else if(streq(cmd,"reset")){if(arg&&streq(arg,"all")){reset_service(0);reset_service(1);reset_service(2);}else reset_service(ix);log_line("RESET");}
}
static void process_event(u32 now){
    const char*seqs=lua_text("W112_RSP_EVENT_SEQ"),*svc=lua_text("W112_RSP_EVENT_SERVICE"),*err=lua_text("W112_RSP_LAST_ERROR");u32 seq=parse_u32(seqs);int ix=service_index(svc);
    if(!seq||seq==g_lastEventSeq)return;g_lastEventSeq=seq;
    if(ix>=0){
        if(g_activeTest==ix && g_services[ix].lastSendAt && seq>g_services[ix].eventSeqAtSend){
            ServiceSnap*s=&g_services[ix];s->successes++;s->lastResult=1u;s->lastResultAt=now;g_activeTest=-1;
            {char b[280],*p=b;p=cat(p,"TEST_SUCCESS service=");p=cat(p,s->name);p=cat(p," latencyMs=");p=dec(p,now-s->lastSendAt);p=cat(p," error=");p=cat(p,err?err:"");*p=0;log_line(b);}
        }else{
            learn_service(ix,now);
        }
    }
}
static void poll_timeout(u32 now){
    if(g_activeTest>=0&&g_activeTest<3){ServiceSnap*s=&g_services[g_activeTest];if(s->lastSendAt&&now-s->lastSendAt>=TEST_TIMEOUT_MS){
        const char*err=lua_text("W112_RSP_LAST_ERROR");s->timeouts++;s->lastResult=2u;s->lastResultAt=now;
        {char b[340],*p=b;p=cat(p,"TEST_TIMEOUT service=");p=cat(p,s->name);p=cat(p," elapsedMs=");p=dec(p,now-s->lastSendAt);p=cat(p," error=");p=cat(p,err?err:"");*p=0;log_line(b);}
        g_activeTest=-1;
    }}
}
static void STDCALL timer_proc(HWND32 hwnd,u32 msg,UINT_PTR32 id,u32 now){(void)hwnd;(void)msg;(void)id;process_event(now);process_command(now);poll_timeout(now);}

static void install_lua(void){
    static const char script[]=
      "W112_RSP_CMD_SEQ=0;W112_RSP_CMD='';W112_RSP_ARG='';W112_RSP_EVENT_SEQ=0;W112_RSP_EVENT_SERVICE='';W112_RSP_LAST_ERROR='';"
      "W112_RSP_ZONE='';W112_RSP_SUBZONE='';"
      "local f=CreateFrame('Frame');"
      "f:RegisterEvent('BANKFRAME_OPENED');f:RegisterEvent('MAIL_SHOW');f:RegisterEvent('AUCTION_HOUSE_SHOW');"
      "f:RegisterEvent('UI_ERROR_MESSAGE');f:RegisterEvent('CHAT_MSG_SYSTEM');"
      "f:SetScript('OnEvent',function() "
      " if event=='UI_ERROR_MESSAGE' or event=='CHAT_MSG_SYSTEM' then W112_RSP_LAST_ERROR=tostring(arg1 or '') return end;"
      " local s=nil;if event=='BANKFRAME_OPENED' then s='bank' elseif event=='MAIL_SHOW' then s='mail' elseif event=='AUCTION_HOUSE_SHOW' then s='ah' end;"
      " if s then W112_RSP_EVENT_SERVICE=s;W112_RSP_EVENT_SEQ=(W112_RSP_EVENT_SEQ or 0)+1 end end);"
      "SLASH_W112RSP1='/rsp';SlashCmdList['W112RSP']=function(msg) "
      " local _,_,c,a=string.find(msg or '','^(%S+)%s*(.-)%s*
      " if c=='arm' or c=='test' or c=='reset' or c=='status' or c=='dump' then "
      "  W112_RSP_ZONE=(GetZoneText and GetZoneText()) or '';W112_RSP_SUBZONE=(GetSubZoneText and GetSubZoneText()) or '';"
      "  W112_RSP_CMD=c;W112_RSP_ARG=a;W112_RSP_CMD_SEQ=(W112_RSP_CMD_SEQ or 0)+1;"
      "  if c=='arm' then DEFAULT_CHAT_FRAME:AddMessage('|cff66ccff[RSP]|r armed '..a..' - open it normally once') "
      "  elseif c=='test' then DEFAULT_CHAT_FRAME:AddMessage('|cff66ccff[RSP]|r replay '..a..' sent/queued') "
      "  elseif c=='reset' then DEFAULT_CHAT_FRAME:AddMessage('|cff66ccff[RSP]|r reset '..a) end "
      " else DEFAULT_CHAT_FRAME:AddMessage('|cff66ccff[RSP]|r /rsp arm|test|reset bank|mail|ah, /rsp status, /rsp dump') end end;"
      "DEFAULT_CHAT_FRAME:AddMessage('|cff66ccff[RemoteServiceProbe]|r loaded. Learn nearby with /rsp arm bank|mail|ah');";
    lua_exec(script,"RemoteServiceProbeInit");
}
BOOL32 STDCALL DllMain(void*h,u32 reason,void*r){
    (void)h;(void)r;
    if(reason==DLL_PROCESS_ATTACH){
        log_line("=== RemoteServiceProbe attach build=5875 v1 ===");
        if(!install_send_hook()){log_line("FATAL send hook install failed");return 1;}
        install_lua();g_timer=SetTimer(0,0,TIMER_MS,(void*)&timer_proc);g_installed=1u;
    }else if(reason==DLL_PROCESS_DETACH){
        if(g_timer)KillTimer(0,g_timer);restore_send_hook();log_line("=== RemoteServiceProbe detach ===");
    }
    return 1;
}
);c=string.lower(c or 'status');a=string.lower(a or '');"
      " if c=='arm' or c=='test' or c=='reset' or c=='status' or c=='dump' then "
      "  W112_RSP_ZONE=(GetZoneText and GetZoneText()) or '';W112_RSP_SUBZONE=(GetSubZoneText and GetSubZoneText()) or '';"
      "  W112_RSP_CMD=c;W112_RSP_ARG=a;W112_RSP_CMD_SEQ=(W112_RSP_CMD_SEQ or 0)+1;"
      "  if c=='arm' then DEFAULT_CHAT_FRAME:AddMessage('|cff66ccff[RSP]|r armed '..a..' - open it normally once') "
      "  elseif c=='test' then DEFAULT_CHAT_FRAME:AddMessage('|cff66ccff[RSP]|r replay '..a..' sent/queued') "
      "  elseif c=='reset' then DEFAULT_CHAT_FRAME:AddMessage('|cff66ccff[RSP]|r reset '..a) end "
      " else DEFAULT_CHAT_FRAME:AddMessage('|cff66ccff[RSP]|r /rsp arm|test|reset bank|mail|ah, /rsp status, /rsp dump') end end;"
      "DEFAULT_CHAT_FRAME:AddMessage('|cff66ccff[RemoteServiceProbe]|r loaded. Learn nearby with /rsp arm bank|mail|ah');";
    lua_exec(script,"RemoteServiceProbeInit");
}
BOOL32 STDCALL DllMain(void*h,u32 reason,void*r){
    (void)h;(void)r;
    if(reason==DLL_PROCESS_ATTACH){
        log_line("=== RemoteServiceProbe attach build=5875 v1 ===");
        if(!install_send_hook()){log_line("FATAL send hook install failed");return 1;}
        install_lua();g_timer=SetTimer(0,0,TIMER_MS,(void*)&timer_proc);g_installed=1u;
    }else if(reason==DLL_PROCESS_DETACH){
        if(g_timer)KillTimer(0,g_timer);restore_send_hook();log_line("=== RemoteServiceProbe detach ===");
    }
    return 1;
}
