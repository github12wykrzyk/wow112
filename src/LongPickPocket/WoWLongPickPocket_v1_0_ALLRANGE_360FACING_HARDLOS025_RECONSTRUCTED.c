/*
 * WoWLongPickPocket_v1_0_ALLRANGE_360FACING_HARDLOS025_RECONSTRUCTED.c
 * Target: World of Warcraft 1.12.1 build 5875, Windows x86.
 *
 * Classification: FUNCTIONALLY EQUIVALENT RECONSTRUCTION
 *
 * This is normal maintainable C reconstructed from the final DLL and the
 * exact preserved v0.8/v0.9 binary lineage. It is NOT original source.
 *
 * Proven binary lineage:
 *   v0.8 SHA256 aa7db3a6191c4675d8dbdacd24a70c558d516dd67573e7e7231381553c11312c
 *   v0.9 SHA256 764605590462e4161b4c4badb37db990a33a8ae0037e730e03db78233d2c3717
 *   v1.0 SHA256 dc4a8d85b850728f39e07a04c49a7f7b60e72b8ec2fdebb94b86dad3a47474d2
 *
 * v0.8 -> v0.9 changes the spoof distance from 3.00 yd to 0.25 yd.
 * v0.9 -> v1.0 changes exactly six bytes at file offset 0x1497,
 * VA 0x10002097:
 *      0F 83 CF 01 00 00   jae 0x1000226C
 *   -> 90 90 90 90 90 90   nop x6
 * The removed branch was the distance <= 4.5 yd native-range fallback.
 * v1.0 therefore routes both close and far Pick Pocket through the same
 * spoof/facing path while retaining the 0.25 yd HARDLOS approach.
 */

#if !defined(_M_IX86) && !defined(__i386__)
#error WoW 1.12.1 build 5875 module: x86 only
#endif

#if defined(_MSC_VER)
#define STDCALL   __stdcall
#define THISCALL  __thiscall
#define CDECL     __cdecl
#define NAKED     __declspec(naked)
#else
#define STDCALL   __attribute__((stdcall))
#define THISCALL  __attribute__((thiscall))
#define CDECL     __attribute__((cdecl))
#define NAKED     __attribute__((naked))
#endif

typedef unsigned char  u8;
typedef unsigned short u16;
typedef unsigned int   u32;
typedef signed int     s32;
typedef u32            uptr;
typedef int            BOOL32;

/* MSVC x86 floating-point marker, required when linking without CRT. */
int _fltused = 0x9875;
typedef void          *HANDLE32;

enum { FALSE32=0, TRUE32=1 };
#define DLL_PROCESS_ATTACH 1u
#define INVALID_HANDLE32 ((HANDLE32)(uptr)0xFFFFFFFFu)

#define IAT_CLOSEHANDLE           0x007FF15Cu
#define IAT_SETFILEPOINTER        0x007FF190u
#define IAT_CREATEFILEA           0x007FF1D4u
#define IAT_WRITEFILE             0x007FF2ECu
#define IAT_GETTICKCOUNT          0x007FF310u
#define IAT_FLUSHINSTRUCTIONCACHE 0x007FF320u
#define IAT_VIRTUALPROTECT        0x007FF35Cu

#define WOW_OBJECT_MANAGER_PTR   0x00B41414u
#define WOW_FALLBACK_GUID1_LO    0x00B4E2D8u
#define WOW_FALLBACK_GUID1_HI    0x00B4E2DCu
#define WOW_FALLBACK_GUID2_LO    0x00B4E2C8u
#define WOW_FALLBACK_GUID2_HI    0x00B4E2CCu
#define WOW_CLIENTSERVICES_THIS  0x007FF9E4u
#define WOW_SEND_ENTRY           0x005AB630u
#define WOW_SEND_ORIGINAL        0x005AB490u
#define WOW_SEND_CONTINUE        0x005AB635u
#define WOW_MOVE_CALLSITE        0x00600ACAu
#define WOW_SEND_MOVEMENT        0x00600A10u
#define WOW_SPELLFAIL_CALLSITE   0x006E73ACu
#define WOW_LOOT_ENTRY           0x005EB900u
#define WOW_LOOT_CONTINUE        0x005EB906u

#define OM_FIRST_OBJECT          0x00ACu
#define OM_PLAYER_GUID_LO        0x00C0u
#define OM_PLAYER_GUID_HI        0x00C4u
#define OBJ_DESC                 0x0008u
#define OBJ_GUID_LO              0x0030u
#define OBJ_GUID_HI              0x0034u
#define OBJ_NEXT                 0x003Cu
#define OBJ_X                    0x09B8u
#define OBJ_Y                    0x09BCu
#define OBJ_Z                    0x09C0u
#define OBJ_O                    0x09C4u
#define DESC_COINAGE             0x1260u

#define SPELL_PICK_POCKET        921u
#define OPCODE_CAST_SPELL        0x012Eu
#define OPCODE_LOOT_MONEY        0x015Eu
#define OPCODE_LOOT_RELEASE      0x015Fu
#define MOVE_EVENT_HEARTBEAT     0x00EEu
#define SPOOF_DISTANCE_YD        0.25f
#define MIN_DISTANCE_YD          0.10f
#define TWO_PI_F                 6.28318548f
#define ACTIVE_TIMEOUT_MS        1800u
#define POST_LOOT_TIMEOUT_MS     4000u
#define MONEY_RETRY_MS           120u
#define MONEY_INITIAL_RETRY_MS   40u
#define MONEY_MAX_RETRIES        10u
#define MAX_PACKET_COPY          64u
#define MAX_OBJECT_STEPS         0x0FFFu

#define GENERIC_WRITE32          0x40000000u
#define FILE_SHARE_RW32          0x00000003u
#define OPEN_ALWAYS32            4u
#define FILE_ATTRIBUTE_NORMAL32  0x00000080u
#define FILE_END32               2u
#define PAGE_EXECUTE_READWRITE32 0x40u

typedef HANDLE32 (STDCALL *CreateFileAFn)(const char*,u32,u32,void*,u32,u32,HANDLE32);
typedef u32      (STDCALL *SetFilePointerFn)(HANDLE32,s32,s32*,u32);
typedef BOOL32   (STDCALL *WriteFileFn)(HANDLE32,const void*,u32,u32*,void*);
typedef BOOL32   (STDCALL *CloseHandleFn)(HANDLE32);
typedef u32      (STDCALL *GetTickCountFn)(void);
typedef BOOL32   (STDCALL *VirtualProtectFn)(void*,u32,u32,u32*);
typedef BOOL32   (STDCALL *FlushInstructionCacheFn)(HANDLE32,const void*,u32);
typedef void     (THISCALL *MovementPulseFn)(void*,u32);

#define API_AT(type,addr) (*(type*)(uptr)(addr))
static CreateFileAFn CF(void){return API_AT(CreateFileAFn,IAT_CREATEFILEA);}
static SetFilePointerFn SFP(void){return API_AT(SetFilePointerFn,IAT_SETFILEPOINTER);}
static WriteFileFn WF(void){return API_AT(WriteFileFn,IAT_WRITEFILE);}
static CloseHandleFn CH(void){return API_AT(CloseHandleFn,IAT_CLOSEHANDLE);}
static GetTickCountFn GT(void){return API_AT(GetTickCountFn,IAT_GETTICKCOUNT);}
static VirtualProtectFn VP(void){return API_AT(VirtualProtectFn,IAT_VIRTUALPROTECT);}
static FlushInstructionCacheFn FIC(void){return API_AT(FlushInstructionCacheFn,IAT_FLUSHINSTRUCTIONCACHE);}

typedef struct DataStore5875 {
    u32 owner;
    u8 *data;
    u32 cursor;
    u32 capacity;
    u32 size;
    u32 reserved;
} DataStore5875;
typedef struct Guid64 { u32 lo,hi; } Guid64;

static u32 g_nextMove = WOW_SEND_ENTRY;
static u32 g_nextFail = 0x006E1A00u;
static u32 g_prevLoot;
static u32 g_sendHookOK,g_moveHookOK,g_failHookOK,g_lootHookOK;
static u32 g_blockSend,g_injecting;
static u32 g_active;
static u8 g_moneyPacket[MAX_PACKET_COPY];
static u32 g_moneyOwner,g_moneyLen,g_moneyValid,g_retryCount,g_walletBefore,g_lootResponseTick;
static u8 g_releasePacket[MAX_PACKET_COPY];
static u32 g_releaseOwner,g_releaseLen,g_releaseHeld,g_firstHoldTick,g_nextRetryTick,g_walletValid,g_startTick;
static Guid64 g_targetGuid;
static void *g_playerObj,*g_targetObj;
static float g_spoofX,g_spoofY,g_spoofZ,g_spoofO;
static u32 g_failReason;

static const char kLogName[]="WoWLongPickPocket_v0_8_FacingOnly.log";
static const char kLoad[]="LOAD WoWLongPickPocket v0.8-facing build=5875";
static const char kReady[]="READY WoWLongPickPocket v0.8-facing send=1 move=1 fail=1 loot=1 spoof_yd=0.25 timeout_ms=1800 wallet_check=1 money_retry_ms=120 money_max_retries=10 release_hold=1 global_send=1";

static u32 rd32(uptr a){return *(volatile u32*)a;}
static int Ptr(const void*p){uptr v=(uptr)p;return v>=0x10000u&&v<=0x7FFDFFFFu&&!(v&1u);}
static int GuidZero(Guid64 a){return (a.lo|a.hi)==0u;}
static u32 StrLen(const char*s){u32 n=0;if(!s)return 0;while(s[n])n++;return n;}
static char* App(char*p,const char*s){while(*s)*p++=*s++;return p;}
static char* AppU32(char*p,u32 v){char t[16];u32 n=0;if(!v){*p++='0';return p;}while(v){u32 q=v/10;t[n++]=(char)('0'+v-q*10);v=q;}while(n)*p++=t[--n];return p;}
static char* AppHex8(char*p,u32 v){static const char h[]="0123456789ABCDEF";int s;for(s=28;s>=0;s-=4)*p++=h[(v>>s)&15];return p;}
static char* AppHex2(char*p,u32 v){static const char h[]="0123456789ABCDEF";*p++=h[(v>>4)&15];*p++=h[v&15];return p;}

static void LogRaw(const char*line){HANDLE32 h;u32 wr=0,n=StrLen(line);CreateFileAFn cf=CF();SetFilePointerFn sfp=SFP();WriteFileFn wf=WF();CloseHandleFn ch=CH();if(!cf||!sfp||!wf||!ch||!n)return;h=cf(kLogName,GENERIC_WRITE32,FILE_SHARE_RW32,0,OPEN_ALWAYS32,FILE_ATTRIBUTE_NORMAL32,0);if(!h||h==INVALID_HANDLE32)return;sfp(h,0,0,FILE_END32);wf(h,line,n,&wr,0);wf(h,"\r\n",2,&wr,0);ch(h);}
static void LogGuidEvent(const char*event,Guid64 g){char b[180],*p=b;u32 now=GT()?GT()():0;p=App(p,event);p=App(p," tick=");p=AppU32(p,now);p=App(p," guid=");p=AppHex8(p,g.hi);*p++=':';p=AppHex8(p,g.lo);*p=0;LogRaw(b);}
static void LogMoney(const char*event,u32 now,u32 before,u32 current,u32 tries){char b[200],*p=b;p=App(p,event);p=App(p," tick=");p=AppU32(p,now);p=App(p," before=");p=AppU32(p,before);p=App(p," now=");p=AppU32(p,current);p=App(p," tries=");p=AppU32(p,tries);*p=0;LogRaw(b);}
static void LogFail(Guid64 g,u32 reason){char b[220],*p=b;u32 now=GT()?GT()():0;p=App(p,"PP_RESTORE_SPELL_FAIL tick=");p=AppU32(p,now);p=App(p," guid=");p=AppHex8(p,g.hi);*p++=':';p=AppHex8(p,g.lo);p=App(p," reason=0x");p=AppHex2(p,reason&0xFFu);*p=0;LogRaw(b);}
static void LogSpoof(Guid64 g,float dist){char b[220],*p=b;u32 now=GT()?GT()():0,whole=(u32)dist,frac=(u32)((dist-(float)(u32)dist)*100.0f);p=App(p,"PP_SPOOF_BEGIN tick=");p=AppU32(p,now);p=App(p," guid=");p=AppHex8(p,g.hi);*p++=':';p=AppHex8(p,g.lo);p=App(p," dist=");p=AppU32(p,whole);*p++='.';*p++=(char)('0'+((frac/10)%10));*p++=(char)('0'+(frac%10));*p=0;LogRaw(b);}

static BOOL32 WriteMem(void*dst,const void*src,u32 n){u32 old=0,tmp=0,i;VirtualProtectFn vp=VP();FlushInstructionCacheFn fic=FIC();if(!vp||!fic||!dst||!src||!n)return FALSE32;if(!vp(dst,n,PAGE_EXECUTE_READWRITE32,&old))return FALSE32;for(i=0;i<n;i++)((volatile u8*)dst)[i]=((const u8*)src)[i];fic((HANDLE32)(uptr)0xFFFFFFFFu,dst,n);vp(dst,n,old,&tmp);return TRUE32;}
static u32 DecodeRel32(u32 site,u8 opcode){s32 rel;if(*(volatile u8*)site!=opcode)return 0;rel=*(volatile s32*)(site+1u);return site+5u+(u32)rel;}
static BOOL32 PatchRel32(u32 site,u8 opcode,u32 target){u8 p[5];s32 rel=(s32)(target-(site+5u));p[0]=opcode;p[1]=(u8)rel;p[2]=(u8)(rel>>8);p[3]=(u8)(rel>>16);p[4]=(u8)(rel>>24);return WriteMem((void*)site,p,5u);}

static void*FindObject(Guid64 g){u32 om=rd32(WOW_OBJECT_MANAGER_PTR),p,n=MAX_OBJECT_STEPS;if(!Ptr((void*)om)||GuidZero(g))return 0;p=rd32(om+OM_FIRST_OBJECT);while(n--&&Ptr((void*)p)){if(rd32(p+OBJ_GUID_LO)==g.lo&&rd32(p+OBJ_GUID_HI)==g.hi)return(void*)p;{u32 q=rd32(p+OBJ_NEXT);if(q==p)break;p=q;}}return 0;}
static Guid64 PlayerGuid(void){Guid64 g={0,0};u32 om=rd32(WOW_OBJECT_MANAGER_PTR);if(Ptr((void*)om)){g.lo=rd32(om+OM_PLAYER_GUID_LO);g.hi=rd32(om+OM_PLAYER_GUID_HI);}return g;}
static void*LocalPlayer(void){return FindObject(PlayerGuid());}
static u32 Coinage(void){void*p=g_playerObj;if(!Ptr(p))p=LocalPlayer();if(Ptr(p)){u32 d=rd32((uptr)p+OBJ_DESC);if(Ptr((void*)d))return rd32(d+DESC_COINAGE);}return 0;}

static float SqrtPositive(float x){union{float f;u32 u;}a,g;int i;if(x<=0.0f)return 0.0f;a.f=x;g.u=(a.u>>1)+0x1FC00000u;for(i=0;i<4;i++)g.f=0.5f*(g.f+x/g.f);return g.f;}
static float Atan2YX(float y,float x){float r;
#if defined(_MSC_VER)
    __asm {
        fld dword ptr [y]
        fld dword ptr [x]
        fpatan
        fstp dword ptr [r]
    }
#else
    __asm__ __volatile__("flds %1; flds %2; fpatan; fstps %0":"=m"(r):"m"(y),"m"(x));
#endif
    return r;
}

static u8*PacketRaw(DataStore5875*p){if(!p||!p->data||p->cursor>0x01000000u||p->size>0x01000000u)return 0;return p->data-p->cursor;}
static u32 CopyPacket(DataStore5875*p,u8*out,u32*owner){u8*raw;u32 n,i;if(owner)*owner=0;if(!p||!out)return 0;raw=PacketRaw(p);if(!raw)return 0;n=p->size;if(n>MAX_PACKET_COPY)n=MAX_PACKET_COPY;for(i=0;i<n;i++)out[i]=raw[i];if(owner)*owner=p->owner;return n;}
static int DecodePackedGuid(DataStore5875*p,Guid64*out){u8*raw,mask;u32 remain,pos=1,i;u8 bytes[8]={0,0,0,0,0,0,0,0};if(!p||!out||p->size<11u)return 0;raw=PacketRaw(p);if(!raw)return 0;mask=raw[10];remain=p->size-10u;for(i=0;i<8u;i++)if(mask&(1u<<i)){if(pos>=remain)return 0;bytes[i]=raw[10u+pos++];}out->lo=(u32)bytes[0]|((u32)bytes[1]<<8)|((u32)bytes[2]<<16)|((u32)bytes[3]<<24);out->hi=(u32)bytes[4]|((u32)bytes[5]<<8)|((u32)bytes[6]<<16)|((u32)bytes[7]<<24);return!GuidZero(*out);}

static void SendMovementPulse(void*player,int twice){MovementPulseFn fn=(MovementPulseFn)(uptr)WOW_SEND_MOVEMENT;if(!Ptr(player))return;fn(player,MOVE_EVENT_HEARTBEAT);if(twice)fn(player,MOVE_EVENT_HEARTBEAT);}
static void SpoofPulse(void*player){float x,y,z,o;if(!Ptr(player))return;x=*(float*)((uptr)player+OBJ_X);y=*(float*)((uptr)player+OBJ_Y);z=*(float*)((uptr)player+OBJ_Z);o=*(float*)((uptr)player+OBJ_O);*(float*)((uptr)player+OBJ_X)=g_spoofX;*(float*)((uptr)player+OBJ_Y)=g_spoofY;*(float*)((uptr)player+OBJ_Z)=g_spoofZ;*(float*)((uptr)player+OBJ_O)=g_spoofO;SendMovementPulse(player,1);*(float*)((uptr)player+OBJ_X)=x;*(float*)((uptr)player+OBJ_Y)=y;*(float*)((uptr)player+OBJ_Z)=z;*(float*)((uptr)player+OBJ_O)=o;}
static void ReplayPacket(const u8*bytes,u32 len,u32 owner){DataStore5875 p;u8 local[MAX_PACKET_COPY];u32 i;if(!bytes||!len||len>MAX_PACKET_COPY)return;for(i=0;i<len;i++)local[i]=bytes[i];p.owner=owner?owner:WOW_CLIENTSERVICES_THIS;p.data=local;p.cursor=0;p.capacity=MAX_PACKET_COPY;p.size=len;p.reserved=0;g_injecting=1;((void(THISCALL*)(DataStore5875*))(uptr)WOW_SEND_ENTRY)(&p);g_injecting=0;}
static void ClearTxn(void){g_active=0;g_lootResponseTick=0;g_releaseHeld=0;g_moneyValid=0;g_retryCount=0;g_firstHoldTick=0;g_nextRetryTick=0;g_moneyLen=0;g_releaseLen=0;g_walletValid=0;}
static void Restore(const char*reason){Guid64 g=g_targetGuid;void*p=g_playerObj;if(!g_active)return;ClearTxn();if(reason)LogGuidEvent(reason,g);if(!Ptr(p))p=LocalPlayer();if(Ptr(p))SendMovementPulse(p,0);}
static void Maintain(void){u32 now,current;if(!g_active||!g_releaseHeld||!g_moneyValid||g_injecting)return;now=GT()?GT()():0;current=Coinage();if(g_walletValid&&current>g_walletBefore){LogMoney("PP_WALLET_CONFIRMED",now,g_walletBefore,current,g_retryCount);if(g_releaseLen)ReplayPacket(g_releasePacket,g_releaseLen,g_releaseOwner);Restore("PP_RESTORE_WALLET_CONFIRMED");return;}if((g_firstHoldTick&&(u32)(now-g_firstHoldTick)>ACTIVE_TIMEOUT_MS)||g_retryCount>=MONEY_MAX_RETRIES){LogMoney("PP_WALLET_GIVEUP",now,g_walletBefore,current,g_retryCount);if(g_releaseLen)ReplayPacket(g_releasePacket,g_releaseLen,g_releaseOwner);Restore("PP_RESTORE_WALLET_GIVEUP");return;}if(g_nextRetryTick&&(s32)(now-g_nextRetryTick)>=0&&g_moneyLen){++g_retryCount;g_nextRetryTick=now+MONEY_RETRY_MS;LogMoney("PP_MONEY_RETRY",now,g_walletBefore,current,g_retryCount);g_injecting=1;SpoofPulse(g_playerObj);g_injecting=0;ReplayPacket(g_moneyPacket,g_moneyLen,g_moneyOwner);}}

static Guid64 ResolveTargetGuid(DataStore5875*packet,void**target){Guid64 g={0,0};void*o=0;if(DecodePackedGuid(packet,&g))o=FindObject(g);if(!o){g.lo=rd32(WOW_FALLBACK_GUID1_LO);g.hi=rd32(WOW_FALLBACK_GUID1_HI);o=FindObject(g);}if(!o){g.lo=rd32(WOW_FALLBACK_GUID2_LO);g.hi=rd32(WOW_FALLBACK_GUID2_HI);o=FindObject(g);}if(target)*target=o;return g;}
static int BeginPickPocket(DataStore5875*packet){Guid64 g;void*player,*target;float px,py,pz,tx,ty,tz,dx,dy,dz,d2,dist,scale,ang;if(g_active)Restore("PP_RESTORE_RESTART");g=ResolveTargetGuid(packet,&target);player=LocalPlayer();if(GuidZero(g)||!Ptr(player)||!Ptr(target)){LogGuidEvent("PP_SKIP_NO_OBJECT",g);return 0;}px=*(float*)((uptr)player+OBJ_X);py=*(float*)((uptr)player+OBJ_Y);pz=*(float*)((uptr)player+OBJ_Z);tx=*(float*)((uptr)target+OBJ_X);ty=*(float*)((uptr)target+OBJ_Y);tz=*(float*)((uptr)target+OBJ_Z);dx=px-tx;dy=py-ty;dz=pz-tz;d2=dx*dx+dy*dy+dz*dz;if(d2<=0.0f){LogGuidEvent("PP_NORMAL_RANGE",g);return 0;}dist=SqrtPositive(d2);/* v1.0 ALLRANGE: no distance <=4.5 bypass */if(dist<MIN_DISTANCE_YD){LogGuidEvent("PP_NORMAL_RANGE",g);return 0;}scale=SPOOF_DISTANCE_YD/dist;g_spoofX=tx+dx*scale;g_spoofY=ty+dy*scale;g_spoofZ=tz+dz*scale;ang=Atan2YX(ty-g_spoofY,tx-g_spoofX);if(ang<0.0f)ang+=TWO_PI_F;g_spoofO=ang;g_playerObj=player;g_targetObj=target;g_targetGuid=g;g_startTick=GT()?GT()():0;g_lootResponseTick=0;g_releaseHeld=0;g_moneyValid=0;g_retryCount=0;g_firstHoldTick=0;g_nextRetryTick=0;g_moneyLen=0;g_releaseLen=0;g_walletBefore=Coinage();g_walletValid=1;g_active=1;LogSpoof(g,dist);LogMoney("PP_WALLET_SNAPSHOT",g_startTick,g_walletBefore,g_walletBefore,0);SpoofPulse(player);return 0;}
static int HandleRelease(DataStore5875*packet){u32 current,now;if(!g_active)return 0;current=Coinage();if(g_lootResponseTick&&g_moneyValid&&g_walletValid&&current<=g_walletBefore){g_releaseLen=CopyPacket(packet,g_releasePacket,&g_releaseOwner);g_releaseHeld=1;now=GT()?GT()():0;if(!g_firstHoldTick)g_firstHoldTick=now;g_nextRetryTick=now+MONEY_INITIAL_RETRY_MS;LogMoney("PP_RELEASE_HELD",now,g_walletBefore,current,g_retryCount);return 1;}Restore("PP_RESTORE_LOOT_RELEASE_TX");return 0;}

int CDECL LongPP_BeforeSend(DataStore5875*packet){u8*raw;u32 opcode,spell,now,current;if(g_injecting)return 0;if(g_active){Maintain();if(g_active){now=GT()?GT()():0;if(g_releaseHeld)Maintain();else if(g_lootResponseTick){if((u32)(now-g_lootResponseTick)>POST_LOOT_TIMEOUT_MS)Restore("PP_RESTORE_POST_LOOT_TIMEOUT");}else if((u32)(now-g_startTick)>ACTIVE_TIMEOUT_MS)Restore("PP_RESTORE_TIMEOUT");}}if(!packet||(raw=PacketRaw(packet))==0||packet->size<4)return 0;opcode=*(u32*)raw;if(opcode==OPCODE_CAST_SPELL&&packet->size>=8u){spell=*(u32*)(raw+4);if(spell==SPELL_PICK_POCKET)return BeginPickPocket(packet);if(g_active)Restore("PP_RESTORE_OTHER_CAST");return 0;}if(opcode==OPCODE_LOOT_MONEY&&g_active){g_moneyLen=CopyPacket(packet,g_moneyPacket,&g_moneyOwner);g_moneyValid=(g_moneyLen!=0);current=Coinage();LogMoney("PP_LOOT_MONEY_TX",GT()?GT()():0,g_walletBefore,current,g_retryCount);return 0;}if(opcode==OPCODE_LOOT_RELEASE)return HandleRelease(packet);Maintain();return 0;}
void CDECL LongPP_MovementPre(DataStore5875*packet){u8*raw;u32 now;if(!g_injecting)Maintain();if(!g_active)return;now=GT()?GT()():0;if(g_releaseHeld){Maintain();if(!g_active)return;}else if(g_lootResponseTick){if((u32)(now-g_lootResponseTick)>POST_LOOT_TIMEOUT_MS){Restore("PP_RESTORE_POST_LOOT_TIMEOUT");return;}}else if((u32)(now-g_startTick)>ACTIVE_TIMEOUT_MS){Restore("PP_RESTORE_TIMEOUT");return;}if(!packet||packet->size<0x1Cu||(raw=PacketRaw(packet))==0)return;*(float*)(raw+0x0C)=g_spoofX;*(float*)(raw+0x10)=g_spoofY;*(float*)(raw+0x14)=g_spoofZ;*(float*)(raw+0x18)=g_spoofO;}
void CDECL LongPP_OnSpellFail(void){Guid64 g=g_targetGuid;void*p=g_playerObj;if(!g_active)return;ClearTxn();LogFail(g,g_failReason);if(!Ptr(p))p=LocalPlayer();if(Ptr(p))SendMovementPulse(p,0);}
void CDECL LongPP_OnLootResponse(void){if(g_active){g_lootResponseTick=GT()?GT()():0;LogGuidEvent("PP_LOOT_RESPONSE_HOLD",g_targetGuid);}}

NAKED void LongPP_MoveWrapper(void){
#if defined(_MSC_VER)
    __asm {
        pushfd
        pushad
        push ecx
        call LongPP_MovementPre
        add esp,4
        popad
        popfd
        mov eax,dword ptr [g_nextMove]
        jmp eax
    }
#else
    __asm__ __volatile__("pushf; pusha; pushl %ecx; call _LongPP_MovementPre; addl $4,%esp; popa; popf; movl _g_nextMove,%eax; jmp *%eax");
#endif
}
NAKED void LongPP_FailWrapper(void){
#if defined(_MSC_VER)
    __asm {
        cmp ecx,0399h
        jne fail_chain
        movzx eax,dl
        mov dword ptr [g_failReason],eax
        pushfd
        pushad
        call LongPP_OnSpellFail
        popad
        popfd
    fail_chain:
        mov eax,dword ptr [g_nextFail]
        jmp eax
    }
#else
    __asm__ __volatile__("cmpl $0x399,%ecx; jne 1f; movzbl %dl,%eax; movl %eax,_g_failReason; pushf; pusha; call _LongPP_OnSpellFail; popa; popf; 1: movl _g_nextFail,%eax; jmp *%eax");
#endif
}
NAKED void LongPP_SendWrapper(void){
#if defined(_MSC_VER)
    __asm {
        pushfd
        pushad
        push ecx
        call LongPP_BeforeSend
        add esp,4
        mov dword ptr [g_blockSend],eax
        popad
        popfd
        cmp dword ptr [g_blockSend],0
        jne send_blocked
        mov eax,WOW_SEND_ORIGINAL
        call eax
        mov eax,WOW_SEND_CONTINUE
        jmp eax
    send_blocked:
        ret
    }
#else
    __asm__ __volatile__("pushf; pusha; pushl %ecx; call _LongPP_BeforeSend; addl $4,%esp; movl %eax,_g_blockSend; popa; popf; cmpl $0,_g_blockSend; jne 1f; movl $0x5AB490,%eax; call *%eax; movl $0x5AB635,%eax; jmp *%eax; 1: ret");
#endif
}
NAKED void LongPP_LootWrapper(void){
#if defined(_MSC_VER)
    __asm {
        pushad
        call LongPP_OnLootResponse
        popad
        cmp dword ptr [g_prevLoot],0
        jne loot_chain
        push ebp
        mov ebp,esp
        sub esp,02Ch
        mov eax,WOW_LOOT_CONTINUE
        jmp eax
    loot_chain:
        mov eax,dword ptr [g_prevLoot]
        jmp eax
    }
#else
    __asm__ __volatile__("pusha; call _LongPP_OnLootResponse; popa; cmpl $0,_g_prevLoot; jne 1f; pushl %ebp; movl %esp,%ebp; subl $0x2c,%esp; movl $0x5EB906,%eax; jmp *%eax; 1: movl _g_prevLoot,%eax; jmp *%eax");
#endif
}

static BOOL32 InstallHooks(void){u32 target;u8 lootPatch[6];static const u8 sendOriginal[5]={0xE8,0x5B,0xFE,0xFF,0xFF};u32 i;g_sendHookOK=0;g_moveHookOK=0;g_failHookOK=0;g_lootHookOK=0;for(i=0;i<5u;i++)if(*(volatile u8*)(WOW_SEND_ENTRY+i)!=sendOriginal[i])goto no_send;if(PatchRel32(WOW_SEND_ENTRY,0xE9,(u32)(uptr)LongPP_SendWrapper))g_sendHookOK=1;no_send:target=DecodeRel32(WOW_MOVE_CALLSITE,0xE8);if(target){g_nextMove=target;if(target==(u32)(uptr)LongPP_MoveWrapper)g_moveHookOK=1;else if(PatchRel32(WOW_MOVE_CALLSITE,0xE8,(u32)(uptr)LongPP_MoveWrapper))g_moveHookOK=1;}target=DecodeRel32(WOW_SPELLFAIL_CALLSITE,0xE8);if(target){g_nextFail=target;if(target==(u32)(uptr)LongPP_FailWrapper)g_failHookOK=1;else if(PatchRel32(WOW_SPELLFAIL_CALLSITE,0xE8,(u32)(uptr)LongPP_FailWrapper))g_failHookOK=1;}if(*(volatile u8*)WOW_LOOT_ENTRY==0xE9)g_prevLoot=DecodeRel32(WOW_LOOT_ENTRY,0xE9);else if(*(volatile u8*)WOW_LOOT_ENTRY==0x55&&*(volatile u8*)(WOW_LOOT_ENTRY+1)==0x8B&&*(volatile u8*)(WOW_LOOT_ENTRY+2)==0xEC&&*(volatile u8*)(WOW_LOOT_ENTRY+3)==0x83&&*(volatile u8*)(WOW_LOOT_ENTRY+4)==0xEC&&*(volatile u8*)(WOW_LOOT_ENTRY+5)==0x2C)g_prevLoot=0;else return g_sendHookOK&&g_moveHookOK&&g_failHookOK;lootPatch[0]=0xE9;{s32 rel=(s32)((u32)(uptr)LongPP_LootWrapper-(WOW_LOOT_ENTRY+5u));lootPatch[1]=(u8)rel;lootPatch[2]=(u8)(rel>>8);lootPatch[3]=(u8)(rel>>16);lootPatch[4]=(u8)(rel>>24);}lootPatch[5]=0x90;if(WriteMem((void*)WOW_LOOT_ENTRY,lootPatch,6u))g_lootHookOK=1;return g_sendHookOK&&g_moveHookOK&&g_failHookOK&&g_lootHookOK;}
BOOL32 STDCALL DllMain(void*module,u32 reason,void*reserved){(void)module;(void)reserved;if(reason==DLL_PROCESS_ATTACH){LogRaw(kLoad);InstallHooks();LogRaw(kReady);}return TRUE32;}
