/*
 * WoW112 Operator Console transport for the existing AutoLoginBridge/HOTPROBE.
 * Build 5875 x86 only. Transport-only shared memory; no parser, invite, login,
 * world, AH, mail or economic mutation semantics live here.
 */
#define OPERATOR_BRIDGE_MAGIC        0x4F323157u /* W12O */
#define OPERATOR_BRIDGE_VERSION      1u
#define OPERATOR_BRIDGE_POLL_MS      100u
#define OPERATOR_BRIDGE_RING_COUNT   16u
#define OPERATOR_BRIDGE_PLAYER_CAP   64u
#define OPERATOR_BRIDGE_TEXT_CAP     256u
#define OPERATOR_BRIDGE_CORR_CAP     64u
#define OPERATOR_BRIDGE_ERROR_CAP    128u
#define OPERATOR_BRIDGE_MAP_CAP      96u
#define OPERATOR_GETTEXT             0x00703BF0u

#define OPERATOR_COMMAND_NONE        0u
#define OPERATOR_COMMAND_WHISPER     1u
#define OPERATOR_COMMAND_PENDING     1u
#define OPERATOR_COMMAND_ACCEPTED    2u
#define OPERATOR_COMMAND_REJECTED    3u
#define OPERATOR_COMMAND_UNCERTAIN   4u

typedef const char* (__fastcall *OperatorFrameScriptGetTextFn)(const char*,int,DWORD);

typedef struct OperatorEventSlotV1 {
    volatile DWORD seq;
    DWORD kind;
    DWORD confidence_milli;
    DWORD flags;
    char character[64];
    char player[64];
    char text[256];
    char result[32];
    char destination[32];
    char intent[32];
    char keywords[96];
    char matched_rule[96];
    char reason[144];
    char correlation[64];
} OperatorEventSlotV1;

typedef struct OperatorBridgeMapV1 {
    volatile DWORD magic;
    volatile DWORD version;
    volatile DWORD pid;
    volatile DWORD heartbeat_tick;
    volatile DWORD world_ready;
    volatile DWORD event_seq;
    volatile DWORD event_dropped;
    volatile DWORD command_seq;
    volatile DWORD command_ack_seq;
    volatile DWORD command_status;
    volatile DWORD command_kind;
    char command_player[OPERATOR_BRIDGE_PLAYER_CAP];
    char command_text[OPERATOR_BRIDGE_TEXT_CAP];
    char command_correlation[OPERATOR_BRIDGE_CORR_CAP];
    char command_error[OPERATOR_BRIDGE_ERROR_CAP];
    OperatorEventSlotV1 events[OPERATOR_BRIDGE_RING_COUNT];
} OperatorBridgeMapV1;

static HANDLE g_operator_map_handle=NULL;
static OperatorBridgeMapV1 *g_operator_map=NULL;
static UINT_PTR g_operator_timer=0u;
static DWORD g_operator_last_event_seq=0u;
static DWORD g_operator_transport_dropped=0u;

static DWORD operator_parse_u32(const char *s)
{
    DWORD value=0u,digit;
    if(!s || !*s) return 0u;
    while(*s>='0' && *s<='9') {
        digit=(DWORD)(*s-'0');
        if(value>429496729u || (value==429496729u && digit>5u)) return 0u;
        value=value*10u+digit;
        ++s;
    }
    return value;
}

static void operator_copy_text(char *dst,DWORD cap,const char *src)
{
    DWORD i=0u;
    if(!dst || cap==0u) return;
    if(src) {
        while(src[i] && i+1u<cap) { dst[i]=src[i]; ++i; }
    }
    dst[i]=0;
    while(++i<cap) dst[i]=0;
}

static void operator_copy_volatile(char *dst,DWORD cap,const char *src)
{
    DWORD i=0u;
    if(!dst || cap==0u) return;
    if(src) {
        while(i+1u<cap) {
            char c=((volatile const char*)src)[i];
            dst[i]=c;
            if(!c) break;
            ++i;
        }
    }
    if(i>=cap || dst[i]!=0) dst[cap-1u]=0;
}

static DWORD operator_bounded_len(const char *s,DWORD cap)
{
    DWORD n=0u;
    if(!s) return 0u;
    while(n<cap && s[n]) ++n;
    return n;
}

static const char *operator_get_text(const char *name)
{
    return ((OperatorFrameScriptGetTextFn)(DWORD)OPERATOR_GETTEXT)(name,-1,0u);
}

static int operator_append_hex(char *dst,DWORD cap,DWORD *used,const char *src,DWORD src_cap)
{
    static const char hex[]="0123456789ABCDEF";
    DWORD i,n=operator_bounded_len(src,src_cap);
    if(!dst || !used) return 0;
    for(i=0u;i<n;i++) {
        BYTE b=(BYTE)src[i];
        if(*used+2u>=cap) return 0;
        dst[(*used)++]=hex[(b>>4)&15u];
        dst[(*used)++]=hex[b&15u];
    }
    dst[*used]=0;
    return 1;
}

static void operator_set_command_result(DWORD seq,DWORD status,const char *error)
{
    if(!g_operator_map) return;
    operator_copy_text(g_operator_map->command_error,OPERATOR_BRIDGE_ERROR_CAP,error);
    g_operator_map->command_status=status;
    MemoryBarrier();
    g_operator_map->command_ack_seq=seq;
}

static int operator_build_map_name(char *name,DWORD cap)
{
    DWORD used=0u;
    if(!name || cap<32u || !g_pid) return 0;
    name[0]=0;
    if(!append_text(name,cap,&used,"Local\\WoW112_OperatorBridge_")) return 0;
    if(!append_u32(name,cap,&used,g_pid)) return 0;
    return 1;
}

static void operator_map_init(void)
{
    char name[OPERATOR_BRIDGE_MAP_CAP];
    if(g_operator_map || !operator_build_map_name(name,OPERATOR_BRIDGE_MAP_CAP)) return;
    g_operator_map_handle=CreateFileMappingA(INVALID_HANDLE_VALUE,NULL,PAGE_READWRITE,0,
        (DWORD)sizeof(OperatorBridgeMapV1),name);
    if(!g_operator_map_handle) return;
    g_operator_map=(OperatorBridgeMapV1*)MapViewOfFile(g_operator_map_handle,FILE_MAP_ALL_ACCESS,0,0,
        sizeof(OperatorBridgeMapV1));
    if(!g_operator_map) {
        CloseHandle(g_operator_map_handle);
        g_operator_map_handle=NULL;
        return;
    }
    ZeroMemory(g_operator_map,sizeof(OperatorBridgeMapV1));
    g_operator_map->magic=OPERATOR_BRIDGE_MAGIC;
    g_operator_map->version=OPERATOR_BRIDGE_VERSION;
    g_operator_map->pid=g_pid;
}

static void operator_map_shutdown(void)
{
    if(g_operator_map) {
        g_operator_map->world_ready=0u;
        g_operator_map->magic=0u;
        UnmapViewOfFile(g_operator_map);
        g_operator_map=NULL;
    }
    if(g_operator_map_handle) {
        CloseHandle(g_operator_map_handle);
        g_operator_map_handle=NULL;
    }
}

static void operator_copy_event_field(char *dst,DWORD cap,const char *global_name)
{
    const char *value=operator_get_text(global_name);
    operator_copy_text(dst,cap,value);
}

static int operator_poll_one_event(void)
{
    static const char popScript[]=
        "if W112_OPERATOR_BRIDGE_POP then W112_OPERATOR_BRIDGE_POP() "
        "else W112_OPERATOR_EVT_SEQ='0' end";
    const char *seq_text;
    DWORD seq,index,flags=0u,dropped;
    OperatorEventSlotV1 *slot;
    BOOL ok;

    if(!g_operator_map) return 0;
    ok=((FrameScriptExecuteFn)(DWORD)FRAMESCRIPT_EXECUTE)(popScript,"WoW112OperatorPop");
    if(!ok) return 0;
    seq_text=operator_get_text("W112_OPERATOR_EVT_SEQ");
    seq=operator_parse_u32(seq_text);
    if(!seq || seq==g_operator_last_event_seq) return 0;

    if(g_operator_last_event_seq!=0u && seq>g_operator_last_event_seq+1u)
        g_operator_transport_dropped+=seq-g_operator_last_event_seq-1u;

    index=(seq-1u)%OPERATOR_BRIDGE_RING_COUNT;
    slot=&g_operator_map->events[index];
    slot->seq=0u;
    slot->kind=operator_parse_u32(operator_get_text("W112_OPERATOR_EVT_KIND"));
    slot->confidence_milli=operator_parse_u32(operator_get_text("W112_OPERATOR_EVT_CONFIDENCE"));
    if(operator_parse_u32(operator_get_text("W112_OPERATOR_EVT_COMPETITION"))) flags|=1u;
    if(operator_parse_u32(operator_get_text("W112_OPERATOR_EVT_SUMMON_REQUEST"))) flags|=2u;
    slot->flags=flags;
    operator_copy_event_field(slot->character,(DWORD)sizeof(slot->character),"W112_OPERATOR_EVT_CHARACTER");
    operator_copy_event_field(slot->player,(DWORD)sizeof(slot->player),"W112_OPERATOR_EVT_PLAYER");
    operator_copy_event_field(slot->text,(DWORD)sizeof(slot->text),"W112_OPERATOR_EVT_TEXT");
    operator_copy_event_field(slot->result,(DWORD)sizeof(slot->result),"W112_OPERATOR_EVT_RESULT");
    operator_copy_event_field(slot->destination,(DWORD)sizeof(slot->destination),"W112_OPERATOR_EVT_DESTINATION");
    operator_copy_event_field(slot->intent,(DWORD)sizeof(slot->intent),"W112_OPERATOR_EVT_INTENT");
    operator_copy_event_field(slot->keywords,(DWORD)sizeof(slot->keywords),"W112_OPERATOR_EVT_KEYWORDS");
    operator_copy_event_field(slot->matched_rule,(DWORD)sizeof(slot->matched_rule),"W112_OPERATOR_EVT_MATCHED_RULE");
    operator_copy_event_field(slot->reason,(DWORD)sizeof(slot->reason),"W112_OPERATOR_EVT_REASON");
    operator_copy_event_field(slot->correlation,(DWORD)sizeof(slot->correlation),"W112_OPERATOR_EVT_CORRELATION");
    MemoryBarrier();
    slot->seq=seq;
    g_operator_map->event_seq=seq;
    dropped=operator_parse_u32(operator_get_text("W112_OPERATOR_EVT_DROPPED"));
    g_operator_map->event_dropped=dropped+g_operator_transport_dropped;
    g_operator_last_event_seq=seq;
    return 1;
}

static void operator_process_command(void)
{
    char player[OPERATOR_BRIDGE_PLAYER_CAP];
    char text[OPERATOR_BRIDGE_TEXT_CAP];
    char correlation[OPERATOR_BRIDGE_CORR_CAP];
    char script[1400];
    DWORD used=0u,seq,kind,ack,status;
    const char *ack_text,*status_text,*error_text;
    BOOL ok;

    if(!g_operator_map || !g_operator_map->world_ready) return;
    seq=g_operator_map->command_seq;
    if(!seq || seq==g_operator_map->command_ack_seq) return;
    MemoryBarrier();
    kind=g_operator_map->command_kind;
    operator_copy_volatile(player,OPERATOR_BRIDGE_PLAYER_CAP,g_operator_map->command_player);
    operator_copy_volatile(text,OPERATOR_BRIDGE_TEXT_CAP,g_operator_map->command_text);
    operator_copy_volatile(correlation,OPERATOR_BRIDGE_CORR_CAP,g_operator_map->command_correlation);

    if(kind!=OPERATOR_COMMAND_WHISPER) {
        operator_set_command_result(seq,OPERATOR_COMMAND_REJECTED,"unsupported operator command");
        return;
    }
    if(!player[0] || !text[0]) {
        operator_set_command_result(seq,OPERATOR_COMMAND_REJECTED,"empty whisper command");
        return;
    }

    script[0]=0;
    if(!append_text(script,(DWORD)sizeof(script),&used,"if W112_OPERATOR_BRIDGE_RECEIVE then W112_OPERATOR_BRIDGE_RECEIVE(")) goto build_fail;
    if(!append_u32(script,(DWORD)sizeof(script),&used,seq)) goto build_fail;
    if(!append_text(script,(DWORD)sizeof(script),&used,",'")) goto build_fail;
    if(!operator_append_hex(script,(DWORD)sizeof(script),&used,player,OPERATOR_BRIDGE_PLAYER_CAP)) goto build_fail;
    if(!append_text(script,(DWORD)sizeof(script),&used,"','")) goto build_fail;
    if(!operator_append_hex(script,(DWORD)sizeof(script),&used,text,OPERATOR_BRIDGE_TEXT_CAP)) goto build_fail;
    if(!append_text(script,(DWORD)sizeof(script),&used,"','")) goto build_fail;
    if(!operator_append_hex(script,(DWORD)sizeof(script),&used,correlation,OPERATOR_BRIDGE_CORR_CAP)) goto build_fail;
    if(!append_text(script,(DWORD)sizeof(script),&used,"') else W112_OPERATOR_CMD_ACK_SEQ='0' end")) goto build_fail;

    g_operator_map->command_status=OPERATOR_COMMAND_PENDING;
    ok=((FrameScriptExecuteFn)(DWORD)FRAMESCRIPT_EXECUTE)(script,"WoW112OperatorCommand");
    wipe(script,(DWORD)sizeof(script));
    if(!ok) {
        operator_set_command_result(seq,OPERATOR_COMMAND_UNCERTAIN,"FrameScriptExecute returned failure; not retried");
        return;
    }

    ack_text=operator_get_text("W112_OPERATOR_CMD_ACK_SEQ");
    ack=operator_parse_u32(ack_text);
    status_text=operator_get_text("W112_OPERATOR_CMD_ACK_STATUS");
    status=operator_parse_u32(status_text);
    error_text=operator_get_text("W112_OPERATOR_CMD_ACK_ERROR");
    if(ack!=seq) {
        operator_set_command_result(seq,OPERATOR_COMMAND_UNCERTAIN,"Lua ACK missing/mismatched; not retried");
        return;
    }
    if(status!=OPERATOR_COMMAND_ACCEPTED && status!=OPERATOR_COMMAND_REJECTED) {
        operator_set_command_result(seq,OPERATOR_COMMAND_UNCERTAIN,"Lua ACK status invalid; not retried");
        return;
    }
    operator_set_command_result(seq,status,error_text);
    return;

build_fail:
    wipe(script,(DWORD)sizeof(script));
    operator_set_command_result(seq,OPERATOR_COMMAND_REJECTED,"operator command encoding overflow");
}

static VOID CALLBACK operator_timer_tick(HWND hwnd,UINT msg,UINT_PTR timerId,DWORD now)
{
    DWORD i;
    (void)hwnd; (void)msg; (void)timerId;
    if(!g_operator_map) return;
    g_operator_map->heartbeat_tick=now;
    g_operator_map->world_ready=(guard_ok() && hot_world_ready())?1u:0u;
    if(!g_operator_map->world_ready) return;
    operator_process_command();
    for(i=0u;i<8u;i++) if(!operator_poll_one_event()) break;
}

static void operator_bridge_attach(void)
{
    g_operator_timer=0u;
    g_operator_last_event_seq=0u;
    g_operator_transport_dropped=0u;
    if(!g_pid) g_pid=GetCurrentProcessId();
    operator_map_init();
    if(g_operator_map)
        g_operator_timer=SetTimer(NULL,0u,OPERATOR_BRIDGE_POLL_MS,operator_timer_tick);
}

static void operator_bridge_detach(void)
{
    if(g_operator_timer) KillTimer(NULL,g_operator_timer);
    g_operator_timer=0u;
    operator_map_shutdown();
}
