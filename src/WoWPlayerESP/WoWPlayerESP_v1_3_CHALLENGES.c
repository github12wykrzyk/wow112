/*
  WoWPlayerESP v1.3 CHALLENGES wrapper
  Target: World of Warcraft 1.12.1 build 5875, Windows x86.

  Keeps the complete v1.2 range_sweep implementation unchanged, renames its
  DllMain inside this translation unit, then adds a small Turtle/SuperWoW
  challenge bridge. Active challenges are learned from the same server protocol
  used by Turtle's TargetFrame tooltip and appended to the ESP player name,
  e.g. "Thunderboy [War Mode]".

  Protocol verified against Turtle UI source:
    request:  SendAddonMessage("TW_UI", "REQUEST_PLAYER_CHALLENGES;<guid>", "GUILD")
    response: CHAT_MSG_ADDON prefix RESPONSE_PLAYER_CHALLENGES, body <guid>:<mask>

  FrameScript addresses are exact-build 5875 addresses.
  Challenge Lua is deliberately world-state guarded because GlueXML/login and
  BG/world transitions can temporarily expose a different Lua global set.

  WndProc chain rule:
    HWND migration is deferred while an old subclass node remains reachable
    below another module, so its saved predecessor stays bound to one window.
    the v1.2 base owns the primary game-window subclass and this wrapper adds
    one secondary subclass. A later module (currently WoWControlHub) is allowed
    to subclass above us. Therefore "attached" means same live game HWND, not
    "our proc is the current top-level WndProc". Reinstalling merely because a
    legitimate later subclass is on top can duplicate chal_game_wndproc inside
    the chain (Challenges -> ControlHub -> Challenges) and recurse until stack
    exhaustion. Reinstallation is done only when the base moves to a different
    game HWND/world-window instance.

  Hotkey ownership rule:
    F8 belongs to MovementCore SafeBreak in the active stack. The legacy v1.2
    ESP range-sweep F8 toggle is suppressed here so one key press cannot start
    two independent position-spoof systems at once.
*/

/* The included base now invalidates its local-object cache when the Object
   Manager changes across a BG/world transition. Keep this wrapper marked as
   the active build input so build_changed_active rebuilds PlayerESP. */
#define DllMain W112_PlayerESP_Base_DllMain
#include "WoWPlayerESP_v1_2_range_sweep.c"
#undef DllMain

#include "../common/W112ControlAPI.h"

#define WM_W112_ESP_CHALLENGE (0x8000u + 0x0112u)
#define CHALLENGE_CACHE_SIZE 256u
#define CHALLENGE_REQUERY_FRAMES 60u
#define CHALLENGE_POST_GAP_FRAMES 15u
#define CHALLENGE_WORLD_STABLE_POLLS 15u /* 15 x 100 ms = 1.5 s quarantine after world/BG rebuild */

#define FN_FRAMESCRIPT_EXECUTE 0x00704CD0u
#define FN_FRAMESCRIPT_GETTEXT 0x00703BF0u

__declspec(dllimport) BOOL WINAPI PostMessageA(HWND, UINT, DWORD, LONG);
__declspec(dllimport) LONG WINAPI GetWindowLongA(HWND, int);

typedef void        (__fastcall *FrameScriptExecuteFn)(const char* code, const char* codeAgain);
typedef const char* (__fastcall *FrameScriptGetTextFn)(const char* key, int playerGender, DWORD pluralCount);

struct ChallengeInfo {
    BYTE used;
    volatile BYTE known;
    DWORD guidLo;
    DWORD guidHi;
    DWORD lastQueryFrame;
    char text[64];
    char baseName[MAX_PLAYER_NAME + 1u];
};

static struct ChallengeInfo g_challenges[CHALLENGE_CACHE_SIZE];
static WNDPROC32 g_challenge_prev_wndproc = NULL;
static HWND g_challenge_hwnd = NULL;
static BOOL g_challenge_hooked = FALSE;
static DWORD g_next_challenge_post_frame = 0u;
static BOOL g_challenge_logged = FALSE;
static volatile DWORD g_challenge_world_ready = 0u;
static DWORD g_challenge_world_polls = 0u;
static DWORD g_challenge_world_manager = 0u;
static DWORD g_challenge_world_guid_lo = 0u;
static DWORD g_challenge_world_guid_hi = 0u;
static HWND g_challenge_world_hwnd = NULL;

static void chal_world_reset(void) {
    g_challenge_world_ready = 0u;
    g_challenge_world_polls = 0u;
    g_challenge_world_manager = 0u;
    g_challenge_world_guid_lo = 0u;
    g_challenge_world_guid_hi = 0u;
    g_challenge_world_hwnd = NULL;
    g_next_challenge_post_frame = g_render_frame + CHALLENGE_POST_GAP_FRAMES;
}

static BOOL chal_probe_world(DWORD* outManager, DWORD* outLo, DWORD* outHi, HWND* outHwnd) {
    DWORD manager = 0u, linkBase = 0u, lo = 0u, hi = 0u;
    HWND hwnd = g_hooked_game_hwnd;
    HWND liveHwnd = ((GetGameWindowFn)FN_GET_GAME_WINDOW)(0);

    if (!hwnd || !liveHwnd || hwnd != liveHwnd || !IsWindow(liveHwnd)) return FALSE;
    if (!rd_u32(OBJMGR_GLOBAL, &manager)) return FALSE;
    if (manager < 0x00010000u || manager > 0x7FFF0000u) return FALSE;
    if (!readable4(manager + OM_LINK_BASE) ||
        !readable4(manager + OM_FIRST_OBJECT) ||
        !readable4(manager + OM_LOCAL_GUID_LO) ||
        !readable4(manager + OM_LOCAL_GUID_HI)) return FALSE;
    if (!rd_u32(manager + OM_LINK_BASE, &linkBase) || linkBase != 0x38u) return FALSE;
    if (!rd_u32(manager + OM_LOCAL_GUID_LO, &lo) ||
        !rd_u32(manager + OM_LOCAL_GUID_HI, &hi) ||
        (lo == 0u && hi == 0u)) return FALSE;
    if (!g_cached_local_obj || !cached_object_matches(g_cached_local_obj, lo, hi)) return FALSE;
    if (!hwnd || !IsWindow(hwnd)) return FALSE;

    if (outManager) *outManager = manager;
    if (outLo) *outLo = lo;
    if (outHi) *outHi = hi;
    if (outHwnd) *outHwnd = hwnd;
    return TRUE;
}

static BOOL chal_world_identity_ready(void) {
    DWORD manager, lo, hi;
    HWND hwnd;
    if (!g_challenge_world_ready) return FALSE;
    if (!chal_probe_world(&manager, &lo, &hi, &hwnd)) return FALSE;
    return manager == g_challenge_world_manager &&
           lo == g_challenge_world_guid_lo &&
           hi == g_challenge_world_guid_hi &&
           hwnd == g_challenge_world_hwnd;
}

static void chal_world_guard_tick(void) {
    DWORD manager, lo, hi;
    HWND hwnd;

    if (!chal_probe_world(&manager, &lo, &hi, &hwnd)) {
        chal_world_reset();
        return;
    }

    if (manager != g_challenge_world_manager ||
        lo != g_challenge_world_guid_lo ||
        hi != g_challenge_world_guid_hi ||
        hwnd != g_challenge_world_hwnd) {
        g_challenge_world_manager = manager;
        g_challenge_world_guid_lo = lo;
        g_challenge_world_guid_hi = hi;
        g_challenge_world_hwnd = hwnd;
        g_challenge_world_polls = 1u;
        g_challenge_world_ready = 0u;
        g_next_challenge_post_frame = g_render_frame + CHALLENGE_POST_GAP_FRAMES;
        return;
    }

    if (g_challenge_world_polls < CHALLENGE_WORLD_STABLE_POLLS)
        ++g_challenge_world_polls;
    if (g_challenge_world_polls >= CHALLENGE_WORLD_STABLE_POLLS)
        g_challenge_world_ready = 1u;
}

static DWORD chal_strlen(const char* s) {
    DWORD n = 0u;
    if (!s) return 0u;
    while (s[n] && n < 4095u) n++;
    return n;
}

static void chal_copy(char* dst, DWORD cap, const char* src) {
    DWORD i = 0u;
    if (!dst || cap == 0u) return;
    if (src) {
        while (src[i] && i + 1u < cap) {
            dst[i] = src[i];
            i++;
        }
    }
    dst[i] = 0;
}

static BOOL chal_has_suffix(const char* s) {
    DWORD i = 0u;
    if (!s) return FALSE;
    while (s[i] && i < MAX_PLAYER_NAME) {
        if (s[i] == ' ' && s[i + 1u] == '[') return TRUE;
        i++;
    }
    return FALSE;
}

static void chal_guid_token(char out[19], DWORD lo, DWORD hi) {
    static const char hex[] = "0123456789ABCDEF";
    int i;
    out[0] = '0'; out[1] = 'x';
    for (i = 0; i < 8; ++i) out[2 + i] = hex[(hi >> ((7 - i) * 4)) & 0xFu];
    for (i = 0; i < 8; ++i) out[10 + i] = hex[(lo >> ((7 - i) * 4)) & 0xFu];
    out[18] = 0;
}

static struct ChallengeInfo* chal_find(DWORD lo, DWORD hi) {
    DWORD i;
    for (i = 0u; i < CHALLENGE_CACHE_SIZE; ++i) {
        if (g_challenges[i].used && g_challenges[i].guidLo == lo && g_challenges[i].guidHi == hi)
            return &g_challenges[i];
    }
    return NULL;
}

static struct ChallengeInfo* chal_find_or_create(DWORD lo, DWORD hi, const char* currentName) {
    DWORD i;
    struct ChallengeInfo* c = chal_find(lo, hi);
    if (c) {
        if (currentName && currentName[0] && !chal_has_suffix(currentName) && !c->baseName[0])
            chal_copy(c->baseName, sizeof(c->baseName), currentName);
        return c;
    }
    for (i = 0u; i < CHALLENGE_CACHE_SIZE; ++i) {
        if (!g_challenges[i].used) {
            c = &g_challenges[i];
            c->used = 1u;
            c->known = 0u;
            c->guidLo = lo;
            c->guidHi = hi;
            c->lastQueryFrame = 0u;
            c->text[0] = 0;
            c->baseName[0] = 0;
            if (currentName && currentName[0] && !chal_has_suffix(currentName))
                chal_copy(c->baseName, sizeof(c->baseName), currentName);
            return c;
        }
    }
    return NULL;
}

static void chal_make_name(char out[MAX_PLAYER_NAME + 1u], const char* base, const char* challenge) {
    DWORD n = 0u, i = 0u;
    if (!out) return;
    out[0] = 0;
    if (!base || !base[0]) base = "Unknown";
    while (base[i] && n < MAX_PLAYER_NAME) out[n++] = base[i++];
    if (challenge && challenge[0] && challenge[0] != '-' && n + 4u <= MAX_PLAYER_NAME) {
        out[n++] = ' ';
        out[n++] = '[';
        i = 0u;
        /* Reserve one byte for the closing bracket and one for NUL. */
        while (challenge[i] && n < (MAX_PLAYER_NAME - 1u)) out[n++] = challenge[i++];
        out[n++] = ']';
    }
    out[n] = 0;
}

static void chal_invalidate_label(DWORD lo, DWORD hi) {
    DWORD i;
    for (i = 0u; i < MAX_ESP_PLAYERS; ++i) {
        if (g_labels[i].contentValid && g_labels[i].lastGuidLo == lo && g_labels[i].lastGuidHi == hi)
            g_labels[i].contentValid = FALSE;
    }
}

static BOOL chal_apply_to_buffer(char* name, struct ChallengeInfo* c) {
    char decorated[MAX_PLAYER_NAME + 1u];
    DWORD i = 0u;
    if (!name || !c || !c->known || !c->text[0] || c->text[0] == '-') return FALSE;

    if (!chal_has_suffix(name)) {
        if (!c->baseName[0] && name[0]) chal_copy(c->baseName, sizeof(c->baseName), name);
        chal_make_name(decorated, c->baseName[0] ? c->baseName : name, c->text);
        while (decorated[i] == name[i] && decorated[i]) i++;
        if (decorated[i] != name[i]) {
            copy_name_small(name, decorated);
            return TRUE;
        }
    }
    return FALSE;
}

static void chal_apply_known_names(void) {
    DWORD i, j;
    for (i = 0u; i < MAX_TRACKED_PLAYERS; ++i) {
        struct ChallengeInfo* c;
        BOOL changed = FALSE;
        if (!g_tracked[i].used) continue;
        c = chal_find_or_create(g_tracked[i].guidLo, g_tracked[i].guidHi, g_tracked[i].name);
        if (!c || !c->known) continue;
        changed = chal_apply_to_buffer(g_tracked[i].name, c);

        for (j = 0u; j < g_esp_cache_count; ++j) {
            if (g_esp_cache[j].guidLo == c->guidLo && g_esp_cache[j].guidHi == c->guidHi) {
                if (chal_apply_to_buffer(g_esp_cache[j].name, c)) changed = TRUE;
            }
        }
        if (changed) chal_invalidate_label(c->guidLo, c->guidHi);
    }
}

static void chal_lua_init(void) {
    static const char initScript[] =
        "if type(GetRealmName)=='function' and type(SendAddonMessage)=='function' and type(CreateFrame)=='function' then "
        "if not W112_ESP_CHAL_FRAME then "
        "W112_ESP_CHAL_CACHE={};W112_ESP_CHAL_SENT={};W112_ESP_CHAL_LAST={};"
        "W112_ESP_CHAL_NAMES={'Slow&Steady','Exhaustion','War Mode','Hardcore','Vagrant','Boaring','Lvl1','Craftmaster','Brewmaster','Heroism','Samurai','Together','True HC'};"
        "W112_ESP_CHAL_FRAME=CreateFrame('Frame');W112_ESP_CHAL_FRAME:RegisterEvent('CHAT_MSG_ADDON');"
        "W112_ESP_CHAL_FRAME:SetScript('OnEvent',function() "
        "if event=='CHAT_MSG_ADDON' and arg1=='RESPONSE_PLAYER_CHALLENGES' then "
        "local _,_,g,m=string.find(arg2 or '', '^(.+):(%d*)$');"
        "if g then W112_ESP_CHAL_CACHE[g]=tonumber(m) or 0 end end end);end;"
        "W112_ESP_CHAL_RESULT='';end";
    FrameScriptExecuteFn exec = (FrameScriptExecuteFn)FN_FRAMESCRIPT_EXECUTE;
    exec(initScript, initScript);
}

static void chal_query_main_thread(DWORD lo, DWORD hi) {
    char guid[19];
    char script[1800];
    char* p = script;
    const char* result;
    struct ChallengeInfo* c;
    FrameScriptExecuteFn exec = (FrameScriptExecuteFn)FN_FRAMESCRIPT_EXECUTE;
    FrameScriptGetTextFn getText = (FrameScriptGetTextFn)FN_FRAMESCRIPT_GETTEXT;

    if (!chal_world_identity_ready()) return;
    c = chal_find(lo, hi);
    if (!c) return;

    /* Re-run the idempotent init every query. Login/logout and BG transitions can
       rebuild the Lua state while the injected DLL remains loaded. The init and
       query scripts therefore guard all game-only globals instead of throwing a
       modal Lua error on GlueXML screens. */
    chal_lua_init();

    chal_guid_token(guid, lo, hi);
    p = app_str(p, "W112_ESP_CHAL_RESULT='';if type(W112_ESP_CHAL_CACHE)=='table' and type(GetRealmName)=='function' and type(GetTime)=='function' and type(SendAddonMessage)=='function' then do local u='");
    p = app_str(p, guid);
    p = app_str(p, "';local g=u;if type(UnitExists)=='function' then local _,ug=UnitExists(u);if ug then g=ug end end;local m=W112_ESP_CHAL_CACHE[g];");
    p = app_str(p, "if m==nil then local r=GetRealmName();local t=(type(Turtle_ChallengesCache)=='table') and Turtle_ChallengesCache[r];");
    p = app_str(p, "if t and t[g] and t[g]>0 then m=t[g];W112_ESP_CHAL_CACHE[g]=m end end;");
    p = app_str(p, "if m~=nil then if m==0 then W112_ESP_CHAL_RESULT='-' else local o='';local b=1;");
    p = app_str(p, "for i=1,table.getn(W112_ESP_CHAL_NAMES) do if math.mod(m,b*2)>=b then if o~='' then o=o..'/' end;o=o..W112_ESP_CHAL_NAMES[i] end;b=b*2 end;");
    p = app_str(p, "if o=='' then o='Challenge' end;W112_ESP_CHAL_RESULT=o end else local s=W112_ESP_CHAL_SENT[g] or 0;local n=GetTime();local l=W112_ESP_CHAL_LAST[g] or -999;");
    p = app_str(p, "if s<2 and n-l>2 then W112_ESP_CHAL_SENT[g]=s+1;W112_ESP_CHAL_LAST[g]=n;SendAddonMessage('TW_UI','REQUEST_PLAYER_CHALLENGES;'..g,'GUILD') end end end end");
    *p = 0;

    exec(script, script);
    result = getText("W112_ESP_CHAL_RESULT", -1, 0u);
    if (!result || !result[0]) return;

    c->known = 0u;
    chal_copy(c->text, sizeof(c->text), result);
    c->known = 1u;
    if (!g_challenge_logged && c->text[0] != '-') {
        char b[160]; char* q = b;
        q = app_str(q, "CHALLENGE_BRIDGE_OK guid="); q = app_str(q, guid);
        q = app_str(q, " value="); q = app_str(q, c->text); *q = 0;
        log_line(b);
        g_challenge_logged = TRUE;
    }
}

static LONG WINAPI chal_game_wndproc(HWND hwnd, UINT msg, DWORD wParam, LONG lParam) {
    /* v1.2 consumes F8 to toggle its range sweep. In the aggregate active stack
       MovementCore also owns physical F8 for SafeBreak. Let the existing WndProc
       chain process the key, then force the ESP sweep back off before its next
       render tick can start spoofing position. */
    if (msg == WM_KEYDOWN && wParam == VK_F8) {
        LONG result = 0;
        if (g_challenge_prev_wndproc)
            result = CallWindowProcA(g_challenge_prev_wndproc, hwnd, msg, wParam, lParam);
        if (g_range_sweep_enabled) {
            g_range_sweep_enabled = 0u;
            log_line("RANGE_SWEEP_BLOCKED reason=F8_reserved_for_MovementCore_SafeBreak");
        }
        return result;
    }
    if (msg == WM_W112_ESP_CHALLENGE) {
        chal_query_main_thread((DWORD)wParam, (DWORD)lParam);
        return 0;
    }
    if (g_challenge_prev_wndproc)
        return CallWindowProcA(g_challenge_prev_wndproc, hwnd, msg, wParam, lParam);
    return 0;
}

static void chal_clear_hook_tracking(void) {
    g_challenge_hooked = FALSE;
    g_challenge_hwnd = NULL;
    g_challenge_prev_wndproc = NULL;
}

/*
 * A valid secondary subclass does NOT have to be the current top-level WndProc.
 * WoWControlHub may legitimately sit above it while retaining us as its saved
 * predecessor. Treating that state as "lost" and installing chal_game_wndproc
 * again would put the same proc twice in the chain and make the global
 * g_challenge_prev_wndproc point back through ControlHub to ourselves.
 */
static BOOL chal_hook_is_current(void) {
    if (!g_challenge_hooked || !g_challenge_hwnd || !g_challenge_prev_wndproc) return FALSE;
    if (g_challenge_hwnd != g_hooked_game_hwnd) return FALSE;
    return IsWindow(g_challenge_hwnd) ? TRUE : FALSE;
}

/* Restore only if our proc is still the actual top-level WndProc. If another
   owner is above us, never overwrite that newer chain on the old window. */
static void chal_remove_hook(void) {
    LONG current;
    if (g_challenge_hooked && g_challenge_hwnd && g_challenge_prev_wndproc && IsWindow(g_challenge_hwnd)) {
        current = GetWindowLongA(g_challenge_hwnd, GWL_WNDPROC);
        if ((WNDPROC32)(DWORD)current == chal_game_wndproc)
            SetWindowLongA(g_challenge_hwnd, GWL_WNDPROC, (LONG)(DWORD)g_challenge_prev_wndproc);
    }
    chal_clear_hook_tracking();
}

static BOOL chal_release_for_migration(void) {
    LONG current;
    if (!g_challenge_hooked || !g_challenge_hwnd || !g_challenge_prev_wndproc) {
        chal_clear_hook_tracking();
        return TRUE;
    }
    if (!IsWindow(g_challenge_hwnd)) {
        chal_clear_hook_tracking();
        return TRUE;
    }

    current = GetWindowLongA(g_challenge_hwnd, GWL_WNDPROC);
    if ((WNDPROC32)(DWORD)current != chal_game_wndproc)
        return FALSE;

    SetWindowLongA(g_challenge_hwnd, GWL_WNDPROC, (LONG)(DWORD)g_challenge_prev_wndproc);
    chal_clear_hook_tracking();
    return TRUE;
}

static BOOL chal_try_install_hook(void) {
    LONG oldProc;

    if (chal_hook_is_current()) return TRUE;

    /* Keep the saved predecessor tied to the old HWND until that callback can
       no longer be reached through a higher subclass (normally ControlHub). */
    if (!chal_release_for_migration()) return FALSE;

    if (!g_hooked_game_hwnd || !g_old_game_wndproc || !IsWindow(g_hooked_game_hwnd)) return FALSE;
    oldProc = GetWindowLongA(g_hooked_game_hwnd, GWL_WNDPROC);
    if (!oldProc) return FALSE;
    if ((WNDPROC32)(DWORD)oldProc == chal_game_wndproc) return FALSE;

    oldProc = SetWindowLongA(g_hooked_game_hwnd, GWL_WNDPROC, (LONG)(DWORD)chal_game_wndproc);
    if (!oldProc) return FALSE;
    g_challenge_prev_wndproc = (WNDPROC32)(DWORD)oldProc;
    g_challenge_hwnd = g_hooked_game_hwnd;
    g_challenge_hooked = TRUE;
    log_line("CHALLENGE_HOOK_OK Turtle RESPONSE_PLAYER_CHALLENGES bridge active chain_safe=1 migration_safe=1");
    return TRUE;
}

static void chal_schedule_query(void) {
    DWORD i;
    if (!chal_world_identity_ready()) return;
    if (!chal_hook_is_current()) return;
    if (g_render_frame < g_next_challenge_post_frame) return;

    for (i = 0u; i < MAX_TRACKED_PLAYERS; ++i) {
        struct ChallengeInfo* c;
        if (!g_tracked[i].used) continue;
        if (!(g_tracked[i].reaction >= 1 && g_tracked[i].reaction <= 3)) continue;
        c = chal_find_or_create(g_tracked[i].guidLo, g_tracked[i].guidHi, g_tracked[i].name);
        if (!c || c->known) continue;
        if (c->lastQueryFrame != 0u && (g_render_frame - c->lastQueryFrame) < CHALLENGE_REQUERY_FRAMES) continue;
        if (PostMessageA(g_challenge_hwnd, WM_W112_ESP_CHALLENGE, c->guidLo, (LONG)c->guidHi)) {
            c->lastQueryFrame = g_render_frame;
            g_next_challenge_post_frame = g_render_frame + CHALLENGE_POST_GAP_FRAMES;
        }
        break;
    }
}

static DWORD WINAPI ChallengeWorker(LPVOID ignored) {
    (void)ignored;
    while (!g_stop) {
        chal_world_guard_tick();
        if (g_challenge_world_ready) {
            if (!chal_hook_is_current()) chal_try_install_hook();
            if (chal_hook_is_current() && chal_world_identity_ready()) {
                chal_apply_known_names();
                chal_schedule_query();
            }
        }
        Sleep(100u);
    }
    return 0u;
}

static W112_ControlSettingV1 g_controlSettings[6];
static volatile DWORD g_controlDescriptorReady=0u;

static void init_control_descriptor(void)
{
    W112_ControlSettingV1*s;
    if(g_controlDescriptorReady)return;

    s=&g_controlSettings[0];
    s->struct_size=(w112_u32)sizeof(W112_ControlSettingV1);s->setting_id=1u;s->key="esp_enabled";s->label="ESP labels";
    s->type=W112_CTL_BOOL;s->default_value.u32=1u;s->min_value.u32=0u;s->max_value.u32=1u;s->step.u32=1u;s->flags=W112_CTL_LIVE;s->enum_options=0;s->enum_option_count=0u;

    s=&g_controlSettings[1];
    s->struct_size=(w112_u32)sizeof(W112_ControlSettingV1);s->setting_id=2u;s->key="range_sweep";s->label="Range sweep";
    s->type=W112_CTL_BOOL;s->default_value.u32=0u;s->min_value.u32=0u;s->max_value.u32=1u;s->step.u32=1u;s->flags=W112_CTL_LIVE;s->enum_options=0;s->enum_option_count=0u;

    s=&g_controlSettings[2];
    s->struct_size=(w112_u32)sizeof(W112_ControlSettingV1);s->setting_id=3u;s->key="cached_players";s->label="Cached hostile players";
    s->type=W112_CTL_INT;s->default_value.i32=0;s->min_value.i32=0;s->max_value.i32=128;s->step.i32=1;s->flags=W112_CTL_READ_ONLY|W112_CTL_LIVE;s->enum_options=0;s->enum_option_count=0u;

    s=&g_controlSettings[3];
    s->struct_size=(w112_u32)sizeof(W112_ControlSettingV1);s->setting_id=4u;s->key="click_targets";s->label="Clickable ESP targets";
    s->type=W112_CTL_INT;s->default_value.i32=0;s->min_value.i32=0;s->max_value.i32=128;s->step.i32=1;s->flags=W112_CTL_READ_ONLY|W112_CTL_LIVE;s->enum_options=0;s->enum_option_count=0u;

    s=&g_controlSettings[4];
    s->struct_size=(w112_u32)sizeof(W112_ControlSettingV1);s->setting_id=5u;s->key="challenge_ready";s->label="Challenge bridge ready";
    s->type=W112_CTL_BOOL;s->default_value.u32=0u;s->min_value.u32=0u;s->max_value.u32=1u;s->step.u32=1u;s->flags=W112_CTL_READ_ONLY|W112_CTL_LIVE;s->enum_options=0;s->enum_option_count=0u;

    s=&g_controlSettings[5];
    s->struct_size=(w112_u32)sizeof(W112_ControlSettingV1);s->setting_id=6u;s->key="wsg_flag_carrier";s->label="WSG Flag Carrier";
    s->type=W112_CTL_BOOL;s->default_value.u32=1u;s->min_value.u32=0u;s->max_value.u32=1u;s->step.u32=1u;s->flags=W112_CTL_LIVE;s->enum_options=0;s->enum_option_count=0u;

    g_controlDescriptorReady=1u;
}

static int W112_CTL_STDCALL esp_control_get(w112_u32 id,W112_ControlValueV1*out)
{
    if(!out)return 0;
    if(id==1u){out->u32=g_esp_enabled?1u:0u;return 1;}
    if(id==2u){out->u32=g_range_sweep_enabled?1u:0u;return 1;}
    if(id==3u){out->i32=(w112_i32)g_esp_cache_count;return 1;}
    if(id==4u){out->i32=(w112_i32)g_click_hit_count;return 1;}
    if(id==5u){out->u32=g_challenge_world_ready?1u:0u;return 1;}
    if(id==6u){out->u32=g_esp_flag_enabled?1u:0u;return 1;}
    return 0;
}

static int W112_CTL_STDCALL esp_control_set(w112_u32 id,const W112_ControlValueV1*value)
{
    if(!value||value->u32>1u)return 0;
    if(id==1u){
        g_esp_enabled=value->u32;
        if(!g_esp_enabled)g_range_sweep_enabled=0u;
        return 1;
    }
    if(id==2u){
        if(value->u32&&!g_esp_enabled)return 0;
        g_range_sweep_enabled=value->u32;
        if(g_range_sweep_enabled)g_sweep_next_frame=g_render_frame+1u;
        return 1;
    }
    if(id==6u){g_esp_flag_enabled=value->u32;return 1;}
    return 0;
}

static const W112_ControlModuleV1 g_controlModule={
    W112_CONTROL_API_V1,(w112_u32)sizeof(W112_ControlModuleV1),
    "playeresp","PlayerESP",0x00010400u,6u,g_controlSettings,
    esp_control_get,esp_control_set
};

W112_CTL_EXPORT const W112_ControlModuleV1 * W112_CTL_STDCALL W112_Control_GetModuleV1(void)
{
    init_control_descriptor();
    return &g_controlModule;
}

BOOL WINAPI DllMain(HMODULE hinst, DWORD reason, LPVOID reserved) {
    HANDLE th;
    BOOL ok;

    /* Remove the secondary subclass before v1.2 tears down its primary hook.
       The conditional restore above prevents stale-chain writes. */
    if (reason == DLL_PROCESS_DETACH) {
        g_stop = 1;
        chal_remove_hook();
        return W112_PlayerESP_Base_DllMain(hinst, reason, reserved);
    }

    ok = W112_PlayerESP_Base_DllMain(hinst, reason, reserved);
    if (!ok) return FALSE;
    if (reason == DLL_PROCESS_ATTACH) {
        th = CreateThread(NULL, 0u, ChallengeWorker, NULL, 0u, NULL);
        if (th) CloseHandle(th);
    }
    return TRUE;
}
