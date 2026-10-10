/* WoW 1.12.1 build 5875: opt-in kill-objective NPC ESP, separate from PvP/player labels.
 * QuestLog calls run only on the existing game-window WndProc. The render
 * worker reads a versioned, world-bound snapshot and NEVER calls Lua/native
 * unit relation methods on its worker thread. Item-drop sources need an
 * authoritative creature->loot mapping and are intentionally not guessed.
 */
#define W112_Q_MAX_OBJECTIVES 32u
#define W112_Q_MAX_MARKERS 32u
#define W112_Q_NAME_BYTES 64u
#define WM_W112_QUEST_TICK (0x8000u + 0x0121u)
#define W112_Q_POLL_FRAMES 30u
#define W112_Q_TTL_FRAMES 180u
#define W112_Q_UNIT_TYPE 3u
#define W112_Q_NPC_NAME_PTR 0x00000B30u
#define W112_Q_MARKER_COLOR 0x0000FF00u
#define W112_ESP_PROFILE_POLL_FRAMES 30u
#define W112_ESP_PROFILE_FILE "wow112_esp_characters.ini"

struct QuestObjectiveName { char name[W112_Q_NAME_BYTES]; };
static struct QuestObjectiveName g_quest_objectives[W112_Q_MAX_OBJECTIVES];
static volatile DWORD g_quest_snapshot_version=0u;
static volatile DWORD g_quest_snapshot_count=0u;
static volatile DWORD g_quest_snapshot_manager=0u;
static volatile DWORD g_quest_snapshot_local_lo=0u;
static volatile DWORD g_quest_snapshot_local_hi=0u;
static volatile DWORD g_quest_snapshot_frame=0u;
/* All visual ESP surfaces are fail-closed until the current character profile
 * is known. A saved per-character value can opt them back in after login. */
static volatile DWORD g_quest_enabled=0u;
static DWORD g_quest_next_post_frame=0u;
static HWND g_quest_windows[W112_Q_MAX_MARKERS];

/* These objects are defined later in the aggregate PlayerESP translation unit.
 * Tentative declarations here let the always-called quest_draw_tick guard the
 * shared GUI bootstrap before it can restore the legacy global [esp] section. */
static char g_ui_profile_path[512];
static BOOL g_ui_profile_initialized;
static DWORD g_ui_profile_esp_last[5];
__declspec(dllimport) DWORD WINAPI GetPrivateProfileStringA(LPCSTR,LPCSTR,LPCSTR,char*,DWORD,LPCSTR);
__declspec(dllimport) BOOL WINAPI WritePrivateProfileStringA(LPCSTR,LPCSTR,LPCSTR,LPCSTR);

static char g_esp_character_profile_path[512];
static char g_esp_character_section[96];
static BOOL g_esp_character_guarded=FALSE;
static BOOL g_esp_character_ready=FALSE;
static DWORD g_esp_character_next_post_frame=0u;
static DWORD g_esp_character_last[5]={0u,0u,0u,0u,0u};

static volatile DWORD *const g_esp_character_flags[5]={
    &g_esp_enabled,&g_parallel_show_horde,&g_parallel_show_alliance,
    &g_parallel_show_hostile,&g_quest_enabled
};

static BOOL esp_profile_build_path(char out[512],const char* leaf) {
    DWORD n,start,i;
    if(!out||!leaf)return FALSE;
    n=GetModuleFileNameA(NULL,out,512u);
    if(!n||n>=512u){out[0]=0;return FALSE;}
    start=n;
    while(start&&out[start-1u]!='\\'&&out[start-1u]!='/')--start;
    if(!start){out[0]=0;return FALSE;}
    for(i=0u;leaf[i];++i) {
        if(start+i+1u>=512u){out[0]=0;return FALSE;}
        out[start+i]=leaf[i];
    }
    out[start+i]=0;
    return TRUE;
}
static BOOL esp_profile_read_bool(const char* section,DWORD id,DWORD* out) {
    static const char hex[]="0123456789ABCDEF";
    char key[16],value[16];
    char *end;
    DWORD i,bits=0u;
    if(!section||!section[0]||!out||!g_esp_character_profile_path[0])return FALSE;
    end=app_u32(key,id);*end=0;
    if(GetPrivateProfileStringA(section,key,"",value,sizeof(value),g_esp_character_profile_path)!=8u)
        return FALSE;
    for(i=0u;i<8u;++i) {
        const char *p=hex;
        while(*p&&*p!=value[i])++p;
        if(!*p)return FALSE;
        bits=(bits<<4u)|(DWORD)(p-hex);
    }
    if(bits>1u)return FALSE;
    *out=bits;
    return TRUE;
}
static BOOL esp_profile_write_bool(const char* section,DWORD id,DWORD bits) {
    static const char hex[]="0123456789ABCDEF";
    char key[16],text[9];
    char *end;
    DWORD i;
    if(!section||!section[0]||!g_esp_character_profile_path[0]||bits>1u)return FALSE;
    end=app_u32(key,id);*end=0;
    for(i=0u;i<8u;++i)text[i]=hex[(bits>>(28u-i*4u))&15u];
    text[8]=0;
    return WritePrivateProfileStringA(section,key,text,g_esp_character_profile_path);
}
static void esp_profile_force_off(void) {
    DWORD i;
    for(i=0u;i<5u;++i) {
        *g_esp_character_flags[i]=0u;
        g_ui_profile_esp_last[i]=0u;
    }
    g_range_sweep_enabled=0u;
    ++g_parallel_filter_revision;
    g_next_bg_score_post_frame=0u;
}
static void esp_profile_guard_bootstrap(void) {
    DWORD i;
    if(g_esp_character_guarded)return;
    g_esp_character_guarded=TRUE;
    esp_profile_force_off();
    for(i=0u;i<5u;++i)g_esp_character_last[i]=0u;

    /* Keep the legacy shared file only for non-ESP modules. Mark the bootstrap
     * initialized before parallel_gui_tick reaches ui_profile_bootstrap(), so
     * the old global [esp] section is never restored into a new character. */
    g_ui_profile_initialized=TRUE;
    if(!esp_profile_build_path(g_ui_profile_path,"wow112_parallel_gui.ini"))
        g_ui_profile_path[0]=0;
    if(!esp_profile_build_path(g_esp_character_profile_path,W112_ESP_PROFILE_FILE))
        g_esp_character_profile_path[0]=0;
}
static BOOL esp_profile_make_section(const char* raw,char out[96]) {
    DWORD i=0u,j=0u;
    static const char prefix[]="esp_";
    if(!raw||!raw[0]||!out)return FALSE;
    while(prefix[j]&&i+1u<96u)out[i++]=prefix[j++];
    j=0u;
    while(raw[j]&&i+1u<96u) {
        char c=raw[j++];
        if((c>='a'&&c<='z')||(c>='A'&&c<='Z')||(c>='0'&&c<='9')||c=='-'||c=='_')
            out[i++]=c;
        else if(c=='|')out[i++]='_';
        else out[i++]='_';
    }
    out[i]=0;
    return i>4u;
}
static void esp_profile_load_character(const char* section) {
    DWORD i,bits;
    if(!section||!section[0])return;
    for(i=0u;i<5u;++i) {
        bits=0u; /* missing/corrupt value = OFF */
        esp_profile_read_bool(section,i+1u,&bits);
        *g_esp_character_flags[i]=bits;
        g_esp_character_last[i]=bits;
        g_ui_profile_esp_last[i]=bits;
    }
    if(!g_esp_enabled)g_range_sweep_enabled=0u;
    ++g_parallel_filter_revision;
    g_next_bg_score_post_frame=0u;
}
static void esp_profile_poll_game_thread(void) {
    static const char script[]=
        "W112_ESP_PROFILE_ID='';"
        "if type(UnitName)=='function' and type(GetRealmName)=='function' then "
        "local n=UnitName('player');local r=GetRealmName();"
        "if type(n)=='string' and type(r)=='string' and string.len(n)>0 and "
        "string.len(n)<=31 and string.len(r)>0 and string.len(r)<=63 then "
        "W112_ESP_PROFILE_ID=r..'|'..n end end";
    FrameScriptExecuteFn exec=(FrameScriptExecuteFn)FN_FRAMESCRIPT_EXECUTE;
    FrameScriptGetTextFn getText=(FrameScriptGetTextFn)FN_FRAMESCRIPT_GETTEXT;
    const char* raw;
    char section[96];
    DWORD i;
    if(!chal_world_identity_ready())return;
    exec(script,script);
    raw=getText("W112_ESP_PROFILE_ID",-1,0u);
    if(!raw||!raw[0]||!esp_profile_make_section(raw,section))return;
    if(g_esp_character_ready) {
        for(i=0u;i<sizeof(g_esp_character_section)&&section[i]==g_esp_character_section[i];++i)
            if(!section[i])return;
    }
    for(i=0u;i+1u<sizeof(g_esp_character_section)&&section[i];++i)
        g_esp_character_section[i]=section[i];
    g_esp_character_section[i]=0;
    esp_profile_load_character(g_esp_character_section);
    g_esp_character_ready=TRUE;
}
static void esp_profile_tick(void) {
    DWORD i;
    esp_profile_guard_bootstrap();
    if(!chal_world_identity_ready()) {
        if(g_esp_character_ready||g_esp_enabled||g_parallel_show_horde||
           g_parallel_show_alliance||g_parallel_show_hostile||g_quest_enabled) {
            g_esp_character_ready=FALSE;
            g_esp_character_section[0]=0;
            esp_profile_force_off();
            for(i=0u;i<5u;++i)g_esp_character_last[i]=0u;
        }
        return;
    }
    if(g_challenge_hwnd&&IsWindow(g_challenge_hwnd)&&
       g_render_frame>=g_esp_character_next_post_frame) {
        if(PostMessageA(g_challenge_hwnd,WM_W112_QUEST_TICK,0u,0))
            g_esp_character_next_post_frame=g_render_frame+W112_ESP_PROFILE_POLL_FRAMES;
    }
    if(!g_esp_character_ready) {
        esp_profile_force_off();
        return;
    }
    for(i=0u;i<5u;++i) {
        DWORD live=*g_esp_character_flags[i]?1u:0u;
        if(live!=g_esp_character_last[i]&&
           esp_profile_write_bool(g_esp_character_section,i+1u,live)) {
            g_esp_character_last[i]=live;
            g_ui_profile_esp_last[i]=live;
        }
    }
}

static BOOL quest_same_name(const char* a,const char* b) {
    DWORD i;
    if(!a||!b)return FALSE;
    for(i=0u;i<W112_Q_NAME_BYTES;++i) {
        if(a[i]!=b[i])return FALSE;
        if(!a[i])return TRUE;
    }
    return FALSE;
}
/* Client creature cache: [unit+0xB30] -> [row+0] -> NUL name.
 * Unresolved rows are simply ignored. No client function/ABI is guessed. */
static BOOL quest_read_npc_name(DWORD obj,char out[W112_Q_NAME_BYTES]) {
    DWORD row,nameAddr,i;
    BYTE c;
    if(!out||!rd_u32(obj+W112_Q_NPC_NAME_PTR,&row) ||
       row<0x10000u||row>0x7FFF0000u ||
       !rd_u32(row,&nameAddr)||nameAddr<0x10000u||nameAddr>0x7FFF0000u)
       return FALSE;
    for(i=0u;i+1u<W112_Q_NAME_BYTES;++i) {
        if(!rd_u8(nameAddr+i,&c))return FALSE;
        if(!c){out[i]=0;return i>0u;}
        if(c<32u||c==';'||c==':')return FALSE;
        out[i]=(char)c;
    }
    out[0]=0; /* Do not match a truncated name. */
    return FALSE;
}
static void quest_poll_game_thread(void) {
    static const char script[] =
      "W112_QUEST_NPC_RESULT='';"
      "if type(GetNumQuestLogEntries)=='function' and "
      "type(GetQuestLogTitle)=='function' and "
      "type(GetNumQuestLeaderBoards)=='function' and "
      "type(GetQuestLogLeaderBoard)=='function' then "
      "local names={};local count=GetNumQuestLogEntries() or 0;"
      "if count>80 then count=80 end;"
      "for q=1,count do "
      "local _,_,_,header=GetQuestLogTitle(q);"
      "if not header then "
      "local n=GetNumQuestLeaderBoards(q) or 0;if n>20 then n=20 end;"
      "for k=1,n do "
      "local desc,kind,done=GetQuestLogLeaderBoard(k,q);"
      "if kind=='monster' and not done and type(desc)=='string' then "
      "local _,_,name=string.find(desc,'^(.+):%s*%d+%s*/%s*%d+$');"
      "if name then "
      "name=string.gsub(name,'%s+slain$','');"
      "name=string.gsub(name,'%s+killed$','');"
      "name=string.gsub(name,'%s+destroyed$','');"
      "if string.len(name)>0 and string.len(name)<64 and "
      "not string.find(name,';') then "
      "local seen=nil;for j=1,table.getn(names) do "
      "if names[j]==name then seen=1;break end end;"
      "if not seen and table.getn(names)<32 then "
      "table.insert(names,name) end end end end end end end;"
      "W112_QUEST_NPC_RESULT=table.concat(names,';') end";
    FrameScriptExecuteFn exec=(FrameScriptExecuteFn)FN_FRAMESCRIPT_EXECUTE;
    FrameScriptGetTextFn getText=(FrameScriptGetTextFn)FN_FRAMESCRIPT_GETTEXT;
    const char* p;
    DWORD count=0u,i=0u;
    esp_profile_poll_game_thread();
    if(!chal_world_identity_ready()||!g_quest_enabled)return;
    exec(script,script);
    p=getText("W112_QUEST_NPC_RESULT",-1,0u);
    if(!p)return;
    ++g_quest_snapshot_version;
    g_quest_snapshot_count=0u;
    while(*p&&count<W112_Q_MAX_OBJECTIVES) {
        i=0u;
        while(*p&&*p!=';'&&i+1u<W112_Q_NAME_BYTES)
            g_quest_objectives[count].name[i++]=*p++;
        g_quest_objectives[count].name[i]=0;
        if(*p&&*p!=';')break; /* reject overlong entries */
        if(i)++count;
        if(*p==';')++p;
    }
    g_quest_snapshot_manager=g_challenge_world_manager;
    g_quest_snapshot_local_lo=g_challenge_world_guid_lo;
    g_quest_snapshot_local_hi=g_challenge_world_guid_hi;
    g_quest_snapshot_frame=g_render_frame;
    g_quest_snapshot_count=count;
    ++g_quest_snapshot_version;
}
static void quest_hide_from(DWORD first) {
    DWORD i;
    for(i=first;i<W112_Q_MAX_MARKERS;++i)
        if(g_quest_windows[i]&&IsWindow(g_quest_windows[i]))
            ShowWindow(g_quest_windows[i],SW_HIDE);
}
static void quest_destroy_windows(void) {
    DWORD i;
    for(i=0u;i<W112_Q_MAX_MARKERS;++i) {
        if(g_quest_windows[i]&&IsWindow(g_quest_windows[i]))
            DestroyWindow(g_quest_windows[i]);
        g_quest_windows[i]=NULL;
    }
}
static BOOL quest_ensure_window(DWORD index,LONG x,LONG y) {
    HWND hwnd;
    if(index>=W112_Q_MAX_MARKERS)return FALSE;
    hwnd=g_quest_windows[index];
    if(!hwnd||!IsWindow(hwnd)) {
        hwnd=CreateWindowExA(
            WS_EX_TOPMOST|WS_EX_TOOLWINDOW|WS_EX_LAYERED|
            WS_EX_NOACTIVATE|WS_EX_TRANSPARENT,
            "STATIC","",WS_POPUP,(int)x,(int)y,LABEL_W,LABEL_H,
            NULL,NULL,g_self,NULL);
        if(!hwnd)return FALSE;
        g_quest_windows[index]=hwnd;
    }
    return SetWindowPos(hwnd,(HWND)(-1),(int)x,(int)y,LABEL_W,LABEL_H,
                        SWP_NOACTIVATE)?TRUE:FALSE;
}
static void quest_draw_tick(void) {
    DWORD ver,count,manager,localLo,localHi,linkBase,obj,visited=0u,drawn=0u;
    DWORD typ,lo,hi,next;
    char name[W112_Q_NAME_BYTES];
    struct ProjectionContext ctx;
    struct ProjectionResult proj;
    struct UnitMeta meta;
    const char* reason="UNKNOWN";
    LONG screenLeft,screenTop;
    DWORD width,height;
    float x,y,z;
    /* Called at the start of parallel_gui_tick(), before the base renderer
     * evaluates g_esp_enabled. This guarantees no default-ON frame leaks. */
    esp_profile_tick();
    if(!g_quest_enabled || !chal_world_identity_ready() ||
       !g_quest_snapshot_count || g_quest_snapshot_manager!=g_challenge_world_manager ||
       g_quest_snapshot_local_lo!=g_challenge_world_guid_lo ||
       g_quest_snapshot_local_hi!=g_challenge_world_guid_hi ||
       (g_render_frame-g_quest_snapshot_frame)>W112_Q_TTL_FRAMES) {
        quest_hide_from(0u);return;
    }
    /* NPC objects are enumerated on the same worker as player ESP. At 10 Hz,
       no persistent NPC pointer survives an Object Manager transition. */
    if((g_render_frame%3u)!=0u)return;
    ver=g_quest_snapshot_version;
    if(ver&1u){quest_hide_from(0u);return;}
    count=g_quest_snapshot_count;
    if(count>W112_Q_MAX_OBJECTIVES)count=W112_Q_MAX_OBJECTIVES;
    if(!count || !init_projection_context(&ctx,&reason) || !ctx.ready ||
       (GetForegroundWindow()!=ctx.hwnd &&
        GetForegroundWindow()!=g_parallel_ui_hwnd) ||
       !game_client_screen_rect(ctx.hwnd,&screenLeft,&screenTop,&width,&height) ||
       !ensure_label_backbuffer(ctx.hwnd) ||
       !rd_u32(OBJMGR_GLOBAL,&manager) ||
       manager!=g_challenge_world_manager ||
       !rd_u32(manager+OM_LINK_BASE,&linkBase) || linkBase!=0x38u ||
       !rd_u32(manager+OM_FIRST_OBJECT,&obj)) {
        quest_hide_from(0u);return;
    }
    g_next_offset=linkBase+4u;
    while(visited<MAX_OBJECTS && drawn<W112_Q_MAX_MARKERS) {
        DWORD matched=0u,j;
        if(!object_ptr_sane(obj)||seen_before(obj,visited))break;
        g_visited[visited++]=obj;
        if(rd_u32(obj+OBJ_TYPE,&typ)&&typ==W112_Q_UNIT_TYPE &&
           rd_u32(obj+OBJ_GUID_LO,&lo)&&rd_u32(obj+OBJ_GUID_HI,&hi) &&
           (lo||hi) && read_unit_meta(obj,&meta)&&meta.health &&
           quest_read_npc_name(obj,name)) {
            for(j=0u;j<count;++j)
                if(quest_same_name(name,g_quest_objectives[j].name)) {
                    matched=1u;break;
                }
            if(matched && rd_f32(obj+OBJ_POS_X,&x) &&
               rd_f32(obj+OBJ_POS_Y,&y) && rd_f32(obj+OBJ_POS_Z,&z) &&
               project_world(&ctx,x,y,z+HOSTILE_HEAD_Z,&proj) &&
               proj.nativeOk&&proj.onScreen) {
                LONG absX=screenLeft+(LONG)proj.screenX-(LABEL_W/2);
                LONG absY=screenTop+(LONG)proj.screenY-LABEL_TOP_PAD;
                if(quest_ensure_window(drawn,absX,absY)) {
                    char label[96],*p=label;
                    p=app_str(p,"[QUEST] ");p=app_str(p,name);*p=0;
                    clear_label_pixels();
                    draw_text_centered(g_label_memdc,LABEL_W/2,13,label,
                                       W112_Q_MARKER_COLOR);
                    finalize_label_alpha();
                    if(update_label_alpha(g_quest_windows[drawn],absX,absY)) {
                        ShowWindow(g_quest_windows[drawn],SW_SHOWNOACTIVATE);
                        ++drawn;
                    } else ShowWindow(g_quest_windows[drawn],SW_HIDE);
                }
            }
        }
        if(!rd_u32(obj+g_next_offset,&next)||next==obj||next==manager)break;
        obj=next;
    }
    if(ver!=g_quest_snapshot_version) {quest_hide_from(0u);return;}
    quest_hide_from(drawn);
}
