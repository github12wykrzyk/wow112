/*
 * WoWTargetAuraReveal_5875_v1
 * World of Warcraft 1.12.1 build 5875 x86.
 *
 * Read-only hostile-target aura discovery from UnitFields + client DBCs.
 * UI delivery uses FrameScript_Execute from a Win32 timer callback (game/UI
 * thread), leaving stock debuffs untouched. Friendly targets retain Blizzard's
 * normal MAX_TARGET_BUFFS=5 behavior.
 *
 * Exact-build evidence already present in this repo:
 *   target GUID globals / timer IAT / FrameScript_Execute: CastObserver
 *   object+descriptor / aura raw slots 0..47: PlayerESP / PickPocketSelective
 * Exact packaged-EXE disassembly confirms the 5875 DBC reads used below:
 *   Spell records 0x00C0D788 / count 0x00C0D78C,
 *   SpellIcon records 0x00C0D7EC / count 0x00C0D7F0,
 *   locale 0x00C0E080, DispelType +0x10, SpellIconID +0x1D4,
 *   localized name +0x1E0, SpellIcon path +0x04.
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
typedef void* HWND32;
typedef u32 TIMER32;
typedef void (STDCALL *TimerProc)(HWND32,u32,TIMER32,u32);
typedef TIMER32 (STDCALL *SetTimerFn)(HWND32,TIMER32,u32,TimerProc);
typedef BOOL32 (STDCALL *KillTimerFn)(HWND32,TIMER32);
typedef BOOL32 (STDCALL *IsBadReadPtrFn)(const void*,u32);
typedef u32 (FASTCALL *GetObjectByGuidFn)(u64);
typedef BOOL32 (FASTCALL *FrameScriptExecuteFn)(const char*,const char*);

#define DLL_PROCESS_DETACH 0u
#define DLL_PROCESS_ATTACH 1u

#define OBJMGR             0x00B41414u
#define TARGET_GUID_LO     0x00B4E2D8u
#define TARGET_GUID_HI     0x00B4E2DCu
#define GET_OBJECT         0x00464870u
#define FRAME_EXECUTE      0x00704CD0u
#define IAT_ISBADREADPTR   0x007FF1E0u
#define IAT_TIMER          0x007FF4F4u
#define IAT_KILL           0x007FF4F8u

#define SPELL_RECORDS_VAR      0x00C0D788u
#define SPELL_COUNT_VAR        0x00C0D78Cu
#define SPELLICON_RECORDS_VAR  0x00C0D7ECu
#define SPELLICON_COUNT_VAR    0x00C0D7F0u
#define LOCALE_INDEX           0x00C0E080u
#define SPELL_DISPEL_OFF       0x00000010u
#define SPELL_ICON_OFF         0x000001D4u
#define SPELL_NAME_OFF         0x000001E0u
#define DISPEL_MAGIC           1u

#define OBJ_TYPE           0x00000014u
#define OBJ_GUID_LO        0x00000030u
#define OBJ_GUID_HI        0x00000034u
#define OBJ_UNIT_FIELDS    0x00000110u
#define UNIT_AURA_OFF      0x000000A4u
#define UNIT_AURA_APPLICATIONS_OFF 0x000001ACu
#define POSITIVE_AURAS     32u

#define TIMER_PERIOD_MS    100u
#define WORLD_SETTLE_MS    1000u
#define FORCE_REFRESH_MS   1000u
#define LUA_CAP            24576u
#define NAME_CAP           128u
#define ICON_CAP           192u

int _fltused=0;
static volatile u32 g_installed=0u,g_busy=0u,g_inWorld=0u,g_readyAfter=0u;
static TIMER32 g_timer=0u;
static u32 g_lastHash=0u,g_lastRefresh=0u;
static char g_lua[LUA_CAP];

struct AuraRow { u32 spellId; u32 rawSlot; u32 applications; u32 dispelType; char name[NAME_CAP]; char icon[ICON_CAP]; };
static struct AuraRow g_rows[POSITIVE_AURAS];
static u32 g_diagSpell=0u,g_diagTable=0u,g_diagCount=0u,g_diagRow=0u,g_diagLocale=0u,g_diagNamePtr=0u;
static u32 g_diagIconId=0u,g_diagIconTable=0u,g_diagIconCount=0u,g_diagIconRow=0u,g_diagIconPtr=0u;

static u32 read32(u32 a){return *(volatile u32*)(u32)a;}
static u8 read8(u32 a){return *(volatile u8*)(u32)a;}
static void *iat(u32 a){return (void*)(u32)read32(a);}
static int high_readable(u32 p,u32 n){
    IsBadReadPtrFn bad;
    if(p<0x00010000u||!n)return 0;
    bad=(IsBadReadPtrFn)iat(IAT_ISBADREADPTR);
    if(!bad)return 0;
    return bad((const void*)(u32)p,n)==0;
}
static int valid_ptr(u32 p){
    if(p<0x00010000u||(p&3u))return 0;
    if(p<=0x7FFE0000u)return 1;
    return high_readable(p,4u);
}
static int valid_byte_ptr(u32 p){
    if(p<0x00010000u)return 0;
    if(p<=0x7FFEFFFFu)return 1;
    return high_readable(p,1u);
}
static int signature(u32 a,const u8 *s,u32 n){
    volatile const u8 *p=(volatile const u8*)(u32)a;u32 i;
    for(i=0u;i<n;i++)if(p[i]!=s[i])return 0;return 1;
}
static int safe_build(void){
    static const u8 getSig[]={0x55,0x8B,0xEC,0x8B,0x45,0x08,0x8B,0x4D,0x0C,0x8B,0xD0,0x0B,0xD1};
    static const u8 scriptSig[]={0x56,0x6A,0x00,0x8B,0xF1,0x52,0x56,0xE8};
    return signature(GET_OBJECT,getSig,sizeof(getSig)) && signature(FRAME_EXECUTE,scriptSig,sizeof(scriptSig)) && iat(IAT_ISBADREADPTR)!=0;
}
static u32 object_by_guid(u32 lo,u32 hi){
    u64 guid;u32 obj;GetObjectByGuidFn f;
    if(!(lo|hi))return 0u;
    guid=((u64)hi<<32)|(u64)lo;
    f=(GetObjectByGuidFn)(u32)GET_OBJECT;
    obj=f(guid);
    if(!valid_ptr(obj))return 0u;
    if(read32(obj+OBJ_GUID_LO)!=lo||read32(obj+OBJ_GUID_HI)!=hi)return 0u;
    return obj;
}
static int world_ready(void){
    u32 mgr=read32(OBJMGR),lo,hi,obj;
    if(!valid_ptr(mgr))return 0;
    lo=read32(mgr+0xC0u);hi=read32(mgr+0xC4u);
    obj=object_by_guid(lo,hi);
    return obj && read32(obj+OBJ_TYPE)==4u;
}
static u32 hash_mix(u32 h,u32 x){
    h^=x;h*=16777619u;h^=h>>13;h*=0x85EBCA6Bu;return h;
}
static char *cat(char *p,char *end,const char *s){while(*s&&p+1<end)*p++=*s++;return p;}
static char *num(char *p,char *end,u32 n){
    char d[11];u32 k=0u;do{d[k++]=(char)('0'+n%10u);n/=10u;}while(n&&k<11u);
    while(k&&p+1<end)*p++=d[--k];return p;
}
static void copy_text(char *out,u32 cap,u32 src){
    u32 i=0u;if(!cap){return;}out[0]=0;
    if(!valid_byte_ptr(src))return;
    while(i+1u<cap){char c=*(volatile char*)(u32)(src+i);if(!c)break;out[i++]=c;}out[i]=0;
}
static char *lua_q(char *p,char *end,const char *s){
    if(p+1<end)*p++='\'';
    while(*s&&p+2<end){unsigned char c=(unsigned char)*s++;
        if(c=='\\'||c=='\''){*p++='\\';*p++=(char)c;}
        else if(c=='\n'){*p++='\\';*p++='n';}
        else if(c=='\r'){*p++='\\';*p++='r';}
        else if(c>=32u)*p++=(char)c;
    }
    if(p+1<end)*p++='\'';return p;
}
static u32 dbc_row(u32 recordsVar,u32 countVar,u32 id){
    u32 table,count,row;
    if(!id)return 0u;
    count=read32(countVar);
    if(id>count||count>1000000u)return 0u;
    table=read32(recordsVar);
    if(!valid_ptr(table))return 0u;
    row=read32(table+id*4u);
    if(!valid_ptr(row))return 0u;
    return row;
}
static u32 localized_name_ptr(u32 rec,u32 locale){
    u32 p,i;
    if(locale>8u)locale=0u;
    p=read32(rec+SPELL_NAME_OFF+locale*4u);
    if(valid_byte_ptr(p)&&read8(p)!=0u)return p;
    for(i=0u;i<9u;++i){
        if(i==locale)continue;
        p=read32(rec+SPELL_NAME_OFF+i*4u);
        if(valid_byte_ptr(p)&&read8(p)!=0u)return p;
    }
    return 0u;
}
static int spell_visual(u32 spellId,char *name,char *icon,u32 *dispelType){
    u32 rec,iconId,iconRec,namePtr,iconPtr,locale;
    name[0]=0;icon[0]=0;if(dispelType)*dispelType=0u;
    g_diagSpell=spellId;
    g_diagTable=read32(SPELL_RECORDS_VAR);g_diagCount=read32(SPELL_COUNT_VAR);
    g_diagRow=0u;g_diagNamePtr=0u;g_diagIconId=0u;g_diagIconTable=read32(SPELLICON_RECORDS_VAR);
    g_diagIconCount=read32(SPELLICON_COUNT_VAR);g_diagIconRow=0u;g_diagIconPtr=0u;
    rec=dbc_row(SPELL_RECORDS_VAR,SPELL_COUNT_VAR,spellId);g_diagRow=rec;if(!rec)return 0;
    if(dispelType)*dispelType=read32(rec+SPELL_DISPEL_OFF);
    locale=read32(LOCALE_INDEX);if(locale>8u)locale=0u;g_diagLocale=locale;
    namePtr=localized_name_ptr(rec,locale);g_diagNamePtr=namePtr;
    copy_text(name,NAME_CAP,namePtr);
    iconId=read32(rec+SPELL_ICON_OFF);g_diagIconId=iconId;
    if(iconId){
        iconRec=dbc_row(SPELLICON_RECORDS_VAR,SPELLICON_COUNT_VAR,iconId);g_diagIconRow=iconRec;
        if(iconRec){
            iconPtr=read32(iconRec+4u);g_diagIconPtr=iconPtr;
            if(valid_byte_ptr(iconPtr))copy_text(icon,ICON_CAP,iconPtr);
        }
    }
    return name[0]!=0;
}
static u32 collect(u32 obj,u32 *hashOut){
    u32 fields,slot,spell,count=0u,h=2166136261u;
    if(hashOut)*hashOut=0u;
    if(!obj||!valid_ptr(obj))return 0u;
    fields=read32(obj+OBJ_UNIT_FIELDS);if(!valid_ptr(fields))return 0u;
    for(slot=0u;slot<POSITIVE_AURAS;++slot){
        spell=read32(fields+UNIT_AURA_OFF+slot*4u);h=hash_mix(h,spell);
        if(!spell)continue;
        if(count<POSITIVE_AURAS){
            u32 dispelType=0u;
            if(!spell_visual(spell,g_rows[count].name,g_rows[count].icon,&dispelType)){
                char *np=g_rows[count].name,*ne=g_rows[count].name+NAME_CAP;
                np=cat(np,ne,"Spell ");np=num(np,ne,spell);*np=0;
            }
            if(!g_rows[count].icon[0]){
                char *ip=g_rows[count].icon,*ie=g_rows[count].icon+ICON_CAP;
                ip=cat(ip,ie,"Interface\\Icons\\INV_Misc_QuestionMark");*ip=0;
            }
            {
                u32 rawApplications=(u32)read8(fields+UNIT_AURA_APPLICATIONS_OFF+slot);
                g_rows[count].spellId=spell;
                g_rows[count].rawSlot=slot;
                g_rows[count].applications=(rawApplications<255u)?(rawApplications+1u):1u;
                g_rows[count].dispelType=dispelType;
                ++count;
            }
        }
    }
    h=hash_mix(h,count);if(hashOut)*hashOut=h;return count;
}
static char *append_setup(char *p,char *end){
    p=cat(p,end,"if not W112AuraReveal and TargetFrame and TargetFrameBuff1 then W112AuraReveal={};for i=1,32 do local b=CreateFrame('Button','W112AuraRevealBuff'..i,TargetFrame);b:SetWidth(21);b:SetHeight(21);local t=b:CreateTexture(nil,'ARTWORK');t:SetAllPoints(b);b.icon=t;");
    p=cat(p,end,"if i==1 then b:SetPoint('TOPLEFT',TargetFrameBuff1,'TOPLEFT',0,0);elseif math.mod(i-1,6)==0 then b:SetPoint('TOPLEFT',getglobal('W112AuraRevealBuff'..(i-6)),'BOTTOMLEFT',0,-2);else b:SetPoint('LEFT',getglobal('W112AuraRevealBuff'..(i-1)),'RIGHT',3,0);end;");
    p=cat(p,end,"b:SetScript('OnEnter',function() GameTooltip:SetOwner(this,'ANCHOR_BOTTOMRIGHT',15,-25);GameTooltip:SetText(this.spellName or '');if this.dispelType==1 then GameTooltip:AddLine('Dispel: Magic',0.25,0.75,1,1);end;local d=W112AuraRevealDiag;if d and d.spellId==this.spellId and string.sub(this.spellName or '',1,6)=='Spell ' then GameTooltip:AddLine('DBC row='..tostring(d.row or 0)..' name='..tostring(d.namePtr or 0),1,0.82,0,1);GameTooltip:AddLine('table='..tostring(d.table or 0)..' count='..tostring(d.count or 0),0.8,0.8,0.8,1);end;GameTooltip:Show();end);b:SetScript('OnLeave',function() GameTooltip:Hide();end);b:Hide();W112AuraReveal[i]=b;end;end;");
    return p;
}
static void publish(u32 count,u32 targetLo,u32 targetHi){
    char *p=g_lua,*end=g_lua+LUA_CAP;u32 i;
    FrameScriptExecuteFn run=(FrameScriptExecuteFn)(u32)FRAME_EXECUTE;
    p=append_setup(p,end);
    p=cat(p,end,"W112AuraRevealDiag={spellId=");p=num(p,end,g_diagSpell);
    p=cat(p,end,",table=");p=num(p,end,g_diagTable);p=cat(p,end,",count=");p=num(p,end,g_diagCount);
    p=cat(p,end,",row=");p=num(p,end,g_diagRow);p=cat(p,end,",locale=");p=num(p,end,g_diagLocale);
    p=cat(p,end,",namePtr=");p=num(p,end,g_diagNamePtr);p=cat(p,end,",iconId=");p=num(p,end,g_diagIconId);
    p=cat(p,end,",iconTable=");p=num(p,end,g_diagIconTable);p=cat(p,end,",iconCount=");p=num(p,end,g_diagIconCount);
    p=cat(p,end,",iconRow=");p=num(p,end,g_diagIconRow);p=cat(p,end,",iconPtr=");p=num(p,end,g_diagIconPtr);p=cat(p,end,"};");
    p=cat(p,end,"W112NativeTargetBuffs={count=");p=num(p,end,count);
    p=cat(p,end,",targetLo=");p=num(p,end,targetLo);p=cat(p,end,",targetHi=");p=num(p,end,targetHi);
    p=cat(p,end,",hostile=(UnitExists('target') and UnitIsEnemy('player','target')) and 1 or 0,hasMagic=0,bySpell={},byName={}};");
    p=cat(p,end,"if W112AuraReveal then local hostile=W112NativeTargetBuffs.hostile==1;for i=1,32 do W112AuraReveal[i]:Hide();end;if hostile then MAX_TARGET_BUFFS=0;for i=1,5 do local b=getglobal('TargetFrameBuff'..i);if b then b:Hide();end;end;");
    for(i=0u;i<count&&p+320<end;++i){
        p=cat(p,end,"local r={spellId=");p=num(p,end,g_rows[i].spellId);
        p=cat(p,end,",rawSlot=");p=num(p,end,g_rows[i].rawSlot);
        p=cat(p,end,",applications=");p=num(p,end,g_rows[i].applications);
        p=cat(p,end,",dispelType=");p=num(p,end,g_rows[i].dispelType);
        p=cat(p,end,",name=");p=lua_q(p,end,g_rows[i].name);
        p=cat(p,end,",texture=");p=lua_q(p,end,g_rows[i].icon);
        p=cat(p,end,"};W112NativeTargetBuffs[");p=num(p,end,i+1u);p=cat(p,end,"]=r;W112NativeTargetBuffs.bySpell[r.spellId]=r;W112NativeTargetBuffs.byName[r.name]=r;if r.dispelType==1 then W112NativeTargetBuffs.hasMagic=1 end;");
        p=cat(p,end,"W112AuraReveal[");p=num(p,end,i+1u);p=cat(p,end,"].spellId=r.spellId;W112AuraReveal[");p=num(p,end,i+1u);p=cat(p,end,"].spellName=r.name;W112AuraReveal[");p=num(p,end,i+1u);p=cat(p,end,"].dispelType=r.dispelType;W112AuraReveal[");p=num(p,end,i+1u);p=cat(p,end,"].icon:SetTexture(r.texture);W112AuraReveal[");p=num(p,end,i+1u);p=cat(p,end,"].id=r.spellId;W112AuraReveal[");p=num(p,end,i+1u);p=cat(p,end,"]:Show();");
    }
    p=cat(p,end,"else MAX_TARGET_BUFFS=5;if TargetDebuffButton_Update then TargetDebuffButton_Update();end;end;end;if lazyScript then lazyScript.nativeTargetBuffs=W112NativeTargetBuffs;end");
    *p=0;run(g_lua,"WoWTargetAuraReveal");
}
static void STDCALL aura_timer(HWND32 hwnd,u32 msg,TIMER32 timer,u32 tick){
    u32 lo,hi,obj,typeId,count=0u,h=0u,refresh;
    (void)hwnd;(void)msg;(void)timer;
    if(!g_installed||g_busy)return;g_busy=1u;
    if(!world_ready()){
        g_inWorld=0u;g_readyAfter=0u;g_lastHash=0u;g_busy=0u;return;
    }
    if(!g_inWorld){g_inWorld=1u;g_readyAfter=tick+WORLD_SETTLE_MS;g_lastHash=0u;g_busy=0u;return;}
    if((s32)(tick-g_readyAfter)<0){g_busy=0u;return;}
    lo=read32(TARGET_GUID_LO);hi=read32(TARGET_GUID_HI);obj=object_by_guid(lo,hi);
    h=hash_mix(2166136261u,lo);h=hash_mix(h,hi);
    if(obj){typeId=read32(obj+OBJ_TYPE);if(typeId==3u||typeId==4u){u32 ah=0u;count=collect(obj,&ah);h=hash_mix(h,ah);}}
    refresh=(h!=g_lastHash)||((u32)(tick-g_lastRefresh)>=FORCE_REFRESH_MS);
    if(refresh){publish(count,lo,hi);g_lastHash=h;g_lastRefresh=tick;}
    g_busy=0u;
}
static int install(void){
    SetTimerFn setTimer;
    if(!safe_build())return 0;
    setTimer=(SetTimerFn)iat(IAT_TIMER);if(!setTimer)return 0;
    g_timer=setTimer(0,0u,TIMER_PERIOD_MS,aura_timer);if(!g_timer)return 0;
    g_installed=1u;return 1;
}
static void uninstall(void){
    KillTimerFn stop=(KillTimerFn)iat(IAT_KILL);g_installed=0u;
    if(g_timer&&stop)stop(0,g_timer);g_timer=0u;
}
BOOL32 STDCALL DllMain(void *module,u32 reason,void *reserved){
    (void)module;(void)reserved;
    if(reason==DLL_PROCESS_ATTACH)(void)install();
    if(reason==DLL_PROCESS_DETACH)uninstall();
    return 1;
}
