/*
  WoWPlayerESP_v1_2_range_sweep - per-pixel-alpha pooled labels + native PvP state, exact-build guarded
  Target: World of Warcraft 1.12.1 build 5875, x86
  Per-pixel alpha pooled-label renderer: hostile players only, native PvP state, click-to-target via game WndProc.
*/

#define NULL ((void*)0)
typedef unsigned char  BYTE;
typedef unsigned short WORD;
typedef unsigned int   DWORD;
typedef unsigned long long QWORD;
typedef int            BOOL;
typedef int            LONG;
typedef unsigned int   UINT;
typedef unsigned int   SIZE_T;
typedef void*          HANDLE;
typedef void*          HMODULE;
typedef void*          HWND;
typedef void*          HDC;
typedef void*          HGDIOBJ;
typedef void*          HBITMAP;
typedef unsigned int   COLORREF;
typedef void*          LPVOID;
typedef const char*    LPCSTR;
typedef char*          LPSTR;

#define WINAPI __stdcall
typedef LONG (WINAPI *WNDPROC32)(HWND, UINT, DWORD, LONG);
#define TRUE 1
#define FALSE 0

#define WS_POPUP            0x80000000u
#define SS_BLACKRECT         0x00000004u
#define WS_EX_TOPMOST       0x00000008u
#define WS_EX_TRANSPARENT   0x00000020u
#define WS_EX_TOOLWINDOW    0x00000080u
#define WS_EX_LAYERED       0x00080000u
#define WS_EX_NOACTIVATE    0x08000000u
#define LWA_COLORKEY        0x00000001u
#define ULW_ALPHA           0x00000002u
#define AC_SRC_OVER         0x00u
#define AC_SRC_ALPHA        0x01u
#define BI_RGB              0u
#define DIB_RGB_COLORS      0u
#define SW_HIDE             0
#define SW_SHOWNOACTIVATE   4
#define SWP_NOACTIVATE      0x0010u
#define SWP_SHOWWINDOW      0x0040u
#define WM_LBUTTONDOWN      0x0201u
#define WM_KEYDOWN          0x0100u
#define VK_F8               0x77u
#define GWL_WNDPROC         (-4)
#define PM_REMOVE           0x0001u
#define TRANSPARENT_BK      1
#define BLACKNESS_ROP       0x00000042u
#define SRCCOPY_ROP         0x00CC0020u
#define DEFAULT_GUI_FONT_ID 17
#define HOSTILE_HEAD_Z      2.30f
#define RENDER_INTERVAL_MS  33u
#define CACHE_REFRESH_FRAMES 15u
#define DIAG_EVERY_FRAMES   300u
#define LABEL_W             360
#define LABEL_H             58
#define LABEL_HALF_W        180
#define LABEL_TOP_PAD       36
#define MAX_ESP_PLAYERS     128u
#define MAX_TRACKED_PLAYERS 256u
#define HISTORY_TTL_FRAMES  900u   /* ~30 seconds at 33ms render interval */
#define SWEEP_RADIUS         120.0f
#define SWEEP_POINTS         8u
#define SWEEP_DWELL_FRAMES   8u     /* ~264 ms per probe */
#define SWEEP_REST_FRAMES    360u   /* ~12 s between completed sweeps */
#define SWEEP_MOVE_ABORT2    4.0f   /* abort if real client moves >2 yd from sweep anchor */
#define MSG_MOVE_HEARTBEAT   0x000000EEu
#define SEND_MOVEMENT_WRAPPER 0x00600A10u
#define SOURCE_LIVE_ENUM     0u
#define SOURCE_GUID_LOOKUP   1u
#define SOURCE_STALE_CACHE   2u
#define COLOR_KEY_BLACK     0x00000000u
#define COLOR_ENEMY         0x004040FFu
#define COLOR_TEXT          0x00FFFFFFu
#define COLOR_SHADOW        0x00303030u
#define COLOR_PVP_ON        0x0000FFFFu
#define COLOR_PVP_OFF       0x00C0C0C0u

#define DLL_PROCESS_DETACH 0
#define DLL_PROCESS_ATTACH 1

#define GENERIC_WRITE        0x40000000u
#define FILE_SHARE_READ      0x00000001u
#define OPEN_ALWAYS          4u
#define FILE_ATTRIBUTE_NORMAL 0x00000080u
#define FILE_END             2u
#define INVALID_HANDLE_VALUE ((HANDLE)(-1))

#define MEM_COMMIT 0x1000u
#define PAGE_NOACCESS 0x01u
#define PAGE_GUARD    0x100u

#define OBJMGR_GLOBAL       0x00B41414u
#define OM_LINK_BASE        0x000000A4u
#define OM_FIRST_OBJECT     0x000000ACu
#define OM_LOCAL_GUID_LO    0x000000C0u
#define OM_LOCAL_GUID_HI    0x000000C4u
#define OBJ_DESC_PTR        0x00000008u
#define OBJ_TYPE            0x00000014u
#define OBJ_UNIT_FIELDS_PTR 0x00000110u

/* Full descriptor-base offsets, build 5875. */
#define DESC_HEALTH          0x00000058u
#define DESC_MAX_HEALTH      0x00000070u
#define DESC_LEVEL           0x00000088u
#define DESC_FACTION         0x0000008Cu
#define DESC_BYTES0          0x00000090u

/* Equivalent offsets from *(object+0x110), used only as a runtime cross-check. */
#define UF_HEALTH            0x00000040u
#define UF_MAX_HEALTH        0x00000058u
#define UF_LEVEL             0x00000070u
#define UF_FACTION           0x00000074u
#define UF_BYTES0            0x00000078u
#define OBJ_GUID_LO         0x00000030u
#define OBJ_GUID_HI         0x00000034u
#define OBJ_NEXT_EXPECTED   0x0000003Cu

#define FN_ENUM_VISIBLE     0x00468380u
#define FN_GETPTR_CORE      0x00464870u
#define FN_ACTIVE_GUID      0x00468550u
#define FN_UNIT_REACTION    0x006061E0u
#define FN_CAN_ATTACK       0x00606980u
#define FN_UNIT_IS_PVP      0x00605FF0u
#define FN_WORLD_TO_SCREEN  0x00483EE0u
#define FN_DDC_TO_NDC       0x0041ADE0u
#define FN_GET_GAME_WINDOW  0x00435C30u
#define FN_GET_ACTIVE_CAMERA 0x004818F0u
#define FN_TARGET_GUID      0x00489A40u
#define WORLD_FRAME_GLOBAL  0x00B4B2BCu
#define CAMERA_POS_X        0x00000008u
#define CAMERA_POS_Y        0x0000000Cu
#define CAMERA_POS_Z        0x00000010u
#define OBJ_POS_X           0x000009B8u
#define OBJ_POS_Y           0x000009BCu
#define OBJ_POS_Z           0x000009C0u
#define OBJ_POS_O           0x000009C4u
#define TYPEID_PLAYER       4u

/* Vanilla 1.12.1 player info/name cache used by UnitName/player-name lookups. */
#define PLAYER_NAME_CACHE_HEAD 0x00C0E230u
#define NAME_NODE_NEXT         0x00000000u
#define NAME_NODE_GUID_LO      0x0000000Cu
#define NAME_NODE_GUID_HI      0x00000010u
#define NAME_NODE_STRING       0x00000014u
#define MAX_NAME_NODES         2048u
#define MAX_PLAYER_NAME        31u

#define MAX_OBJECTS         4096u
#define SCAN_INTERVAL_MS    2000u

struct MEMORY_BASIC_INFORMATION32 {
    LPVOID BaseAddress;
    LPVOID AllocationBase;
    DWORD AllocationProtect;
    SIZE_T RegionSize;
    DWORD State;
    DWORD Protect;
    DWORD Type;
};

struct RECT32 {
    LONG left;
    LONG top;
    LONG right;
    LONG bottom;
};

struct POINT32 {
    LONG x;
    LONG y;
};

struct SIZE32 {
    LONG cx;
    LONG cy;
};

struct BITMAPINFOHEADER32 {
    DWORD biSize;
    LONG biWidth;
    LONG biHeight;
    WORD biPlanes;
    WORD biBitCount;
    DWORD biCompression;
    DWORD biSizeImage;
    LONG biXPelsPerMeter;
    LONG biYPelsPerMeter;
    DWORD biClrUsed;
    DWORD biClrImportant;
};

struct BITMAPINFO32 {
    struct BITMAPINFOHEADER32 bmiHeader;
    DWORD bmiColors[1];
};

struct BLENDFUNCTION32 {
    BYTE BlendOp;
    BYTE BlendFlags;
    BYTE SourceConstantAlpha;
    BYTE AlphaFormat;
};

struct MSG32 {
    HWND hwnd;
    UINT message;
    DWORD wParam;
    LONG lParam;
    DWORD time;
    struct POINT32 pt;
};

struct ProjectionContext {
    DWORD worldFrame;
    DWORD camera;
    HWND hwnd;
    DWORD width;
    DWORD height;
    float camX;
    float camY;
    float camZ;
    BOOL cameraPosOk;
    BOOL ready;
};

struct ProjectionResult {
    BOOL nativeOk;
    float rawX;
    float rawY;
    float ndcX;
    float ndcY;
    float screenX;
    float screenY;
    BOOL onScreen;
};

struct UnitMeta {
    DWORD desc;
    DWORD unitFields;
    DWORD health;
    DWORD maxHealth;
    DWORD level;
    DWORD faction;
    DWORD bytes0;
    BYTE raceId;
    BYTE classId;
    BYTE sexId;
    BOOL xcheckAvailable;
    BOOL xcheckOk;
};

struct EspCacheEntry {
    DWORD obj;
    DWORD guidLo;
    DWORD guidHi;
    int reaction;
    BYTE canAttack;
    BYTE pvpEnabled;
    BYTE source;
    DWORD lastSeenFrame;
    float x;
    float y;
    float z;
    DWORD health;
    DWORD maxHealth;
    char name[MAX_PLAYER_NAME + 1u];
};

struct TrackedPlayer {
    BYTE used;
    BYTE seenThisRefresh;
    DWORD obj;
    DWORD guidLo;
    DWORD guidHi;
    int reaction;
    BYTE canAttack;
    BYTE pvpEnabled;
    DWORD lastSeenFrame;
    float x;
    float y;
    float z;
    DWORD health;
    DWORD maxHealth;
    char name[MAX_PLAYER_NAME + 1u];
};

struct LabelOverlay {
    HWND hwnd;
    BOOL visible;
    LONG x;
    LONG y;
    DWORD lastGuidLo;
    DWORD lastGuidHi;
    DWORD lastHp;
    DWORD lastMaxHp;
    DWORD lastYd;
    BYTE lastPvp;
    BYTE lastSource;
    DWORD lastAgeSec;
    BOOL contentValid;
};

struct ClickHit {
    LONG left;
    LONG top;
    LONG right;
    LONG bottom;
    DWORD guidLo;
    DWORD guidHi;
};

/* Native client helpers confirmed for build 5875 and cross-checked with public 1.12.1 reversing. */
typedef int  (__thiscall *UnitReactionFn)(DWORD selfObj, DWORD targetObj);
typedef BYTE (__thiscall *CanAttackFn)(DWORD selfObj, DWORD targetObj);
typedef BYTE (__thiscall *UnitIsPvpFn)(DWORD unitObj);
typedef BOOL (__thiscall *WorldToScreenFn)(DWORD worldFrame, float* worldXYZ, float* outRawXY);
typedef void (__fastcall *DdcToNdcFn)(float* outX, float* outY, float rawX, float rawY);
typedef HWND (__fastcall *GetGameWindowFn)(int which);
typedef DWORD (__fastcall *GetActiveCameraFn)(void);
typedef void (__fastcall *TargetGuidFn)(QWORD* guid);
typedef DWORD (__fastcall *GetObjectByGuidFn)(QWORD guid);

__declspec(dllimport) HANDLE WINAPI CreateThread(LPVOID, SIZE_T, DWORD (WINAPI *)(LPVOID), LPVOID, DWORD, DWORD*);
__declspec(dllimport) void   WINAPI Sleep(DWORD);
__declspec(dllimport) HANDLE WINAPI CreateFileA(LPCSTR, DWORD, DWORD, LPVOID, DWORD, DWORD, HANDLE);
__declspec(dllimport) BOOL   WINAPI WriteFile(HANDLE, const void*, DWORD, DWORD*, LPVOID);
__declspec(dllimport) BOOL   WINAPI FlushFileBuffers(HANDLE);
__declspec(dllimport) BOOL   WINAPI CloseHandle(HANDLE);
__declspec(dllimport) DWORD  WINAPI SetFilePointer(HANDLE, int, int*, DWORD);
__declspec(dllimport) SIZE_T WINAPI VirtualQuery(const void*, struct MEMORY_BASIC_INFORMATION32*, SIZE_T);
__declspec(dllimport) DWORD  WINAPI GetModuleFileNameA(HMODULE, LPSTR, DWORD);
__declspec(dllimport) BOOL   WINAPI DisableThreadLibraryCalls(HMODULE);
__declspec(dllimport) BOOL   WINAPI GetClientRect(HWND, struct RECT32*);
__declspec(dllimport) BOOL   WINAPI ClientToScreen(HWND, struct POINT32*);
__declspec(dllimport) HWND   WINAPI CreateWindowExA(DWORD, LPCSTR, LPCSTR, DWORD, int, int, int, int, HWND, HANDLE, HMODULE, LPVOID);
__declspec(dllimport) BOOL   WINAPI DestroyWindow(HWND);
__declspec(dllimport) BOOL   WINAPI ShowWindow(HWND, int);
__declspec(dllimport) BOOL   WINAPI SetWindowPos(HWND, HWND, int, int, int, int, UINT);
__declspec(dllimport) BOOL   WINAPI SetLayeredWindowAttributes(HWND, COLORREF, BYTE, DWORD);
__declspec(dllimport) BOOL   WINAPI UpdateLayeredWindow(HWND, HDC, struct POINT32*, struct SIZE32*, HDC, struct POINT32*, COLORREF, struct BLENDFUNCTION32*, DWORD);
__declspec(dllimport) HDC    WINAPI GetDC(HWND);
__declspec(dllimport) int    WINAPI ReleaseDC(HWND, HDC);
__declspec(dllimport) HWND   WINAPI GetForegroundWindow(void);
__declspec(dllimport) BOOL   WINAPI IsWindow(HWND);
__declspec(dllimport) BOOL   WINAPI PeekMessageA(struct MSG32*, HWND, UINT, UINT, UINT);
__declspec(dllimport) BOOL   WINAPI TranslateMessage(const struct MSG32*);
__declspec(dllimport) LONG   WINAPI DispatchMessageA(const struct MSG32*);
__declspec(dllimport) LONG   WINAPI SetWindowLongA(HWND, int, LONG);
__declspec(dllimport) LONG   WINAPI CallWindowProcA(WNDPROC32, HWND, UINT, DWORD, LONG);

__declspec(dllimport) HDC      WINAPI CreateCompatibleDC(HDC);
__declspec(dllimport) BOOL     WINAPI DeleteDC(HDC);
__declspec(dllimport) HBITMAP  WINAPI CreateCompatibleBitmap(HDC, int, int);
__declspec(dllimport) HBITMAP  WINAPI CreateDIBSection(HDC, const struct BITMAPINFO32*, UINT, void**, HANDLE, DWORD);
__declspec(dllimport) HGDIOBJ  WINAPI SelectObject(HDC, HGDIOBJ);
__declspec(dllimport) BOOL     WINAPI DeleteObject(HGDIOBJ);
__declspec(dllimport) BOOL     WINAPI PatBlt(HDC, int, int, int, int, DWORD);
__declspec(dllimport) BOOL     WINAPI BitBlt(HDC, int, int, int, int, HDC, int, int, DWORD);
__declspec(dllimport) int      WINAPI SetBkMode(HDC, int);
__declspec(dllimport) COLORREF WINAPI SetTextColor(HDC, COLORREF);
__declspec(dllimport) BOOL     WINAPI TextOutA(HDC, int, int, LPCSTR, int);
__declspec(dllimport) BOOL     WINAPI GetTextExtentPoint32A(HDC, LPCSTR, int, struct SIZE32*);
__declspec(dllimport) HGDIOBJ  WINAPI GetStockObject(int);

/* Needed by MSVC ABI when floating point is used without CRT. */
int _fltused = 0;

static volatile LONG g_stop = 0;
static HMODULE g_self = NULL;
static HANDLE g_log = INVALID_HANDLE_VALUE;
static DWORD g_visited[MAX_OBJECTS];
static DWORD g_name_visited[MAX_NAME_NODES];
static float g_max_distance_sq = 0.0f;
static DWORD g_next_offset = OBJ_NEXT_EXPECTED;
static BOOL g_layout_logged = FALSE;
static BOOL g_name_cache_logged = FALSE;

static struct LabelOverlay g_labels[MAX_ESP_PLAYERS];
static HDC g_label_memdc = NULL;
static HBITMAP g_label_bitmap = NULL;
static HGDIOBJ g_label_old_bitmap = NULL;
static DWORD* g_label_pixels = NULL;
static BOOL g_overlay_logged = FALSE;
static DWORD g_render_frame = 0u;
static float g_max_hostile_distance_sq = 0.0f;
static struct EspCacheEntry g_esp_cache[MAX_ESP_PLAYERS];
static struct TrackedPlayer g_tracked[MAX_TRACKED_PLAYERS];
static DWORD g_esp_cache_count = 0u;
static DWORD g_cache_age_frames = 0xFFFFFFFFu;
static DWORD g_cached_local_obj = 0u;
static DWORD g_cached_local_guid_lo = 0u;
static DWORD g_cached_local_guid_hi = 0u;
static struct ClickHit g_click_hits[MAX_ESP_PLAYERS];
static volatile DWORD g_click_hit_count = 0u;
static HWND g_hooked_game_hwnd = NULL;
static WNDPROC32 g_old_game_wndproc = NULL;
static BOOL g_click_hook_logged = FALSE;
static float g_current_farthest_sq = 0.0f;
static DWORD g_current_over150 = 0u;
static DWORD g_current_over300 = 0u;

static volatile DWORD g_range_sweep_enabled = 0u;
static DWORD g_sweep_state = 0u;
static DWORD g_sweep_index = 0u;
static DWORD g_sweep_next_frame = 0u;
static DWORD g_sweep_anchor_obj = 0u;
static float g_sweep_anchor_x = 0.0f;
static float g_sweep_anchor_y = 0.0f;
static float g_sweep_anchor_z = 0.0f;
static float g_sweep_anchor_o = 0.0f;


static DWORD cstr_len(const char* s) {
    DWORD n = 0;
    while (s && s[n]) n++;
    return n;
}

static char* app_str(char* p, const char* s) {
    while (*s) *p++ = *s++;
    return p;
}


static char hex_digit(DWORD v) {
    v &= 0xFu;
    return (char)(v < 10u ? ('0' + v) : ('A' + (v - 10u)));
}

static char* app_hex8(char* p, DWORD v) {
    int i;
    for (i = 7; i >= 0; --i) {
        *p++ = hex_digit(v >> (i * 4));
    }
    return p;
}

static char* app_u32(char* p, DWORD v) {
    char tmp[16];
    int n = 0;
    if (v == 0u) {
        *p++ = '0';
        return p;
    }
    while (v && n < 15) {
        tmp[n++] = (char)('0' + (v % 10u));
        v /= 10u;
    }
    while (n > 0) *p++ = tmp[--n];
    return p;
}

static char* app_float2(char* p, float v) {
    DWORD ip, fp;
    if (v < 0.0f) {
        *p++ = '-';
        v = -v;
    }
    if (v > 4294960000.0f) return app_str(p, "inf");
    ip = (DWORD)v;
    fp = (DWORD)((v - (float)ip) * 100.0f + 0.5f);
    if (fp >= 100u) {
        ip++;
        fp -= 100u;
    }
    p = app_u32(p, ip);
    *p++ = '.';
    *p++ = (char)('0' + ((fp / 10u) % 10u));
    *p++ = (char)('0' + (fp % 10u));
    return p;
}

static float sqrt_local(float x) {
    float r;
    int i;
    if (x <= 0.0f) return 0.0f;
    r = (x > 1.0f) ? x : 1.0f;
    for (i = 0; i < 24; ++i) r = 0.5f * (r + x / r);
    return r;
}

static BOOL readable4(DWORD addr) {
    struct MEMORY_BASIC_INFORMATION32 mbi;
    DWORD base, end;
    SIZE_T got;
    if (addr < 0x00010000u || addr > 0x7FFFFFFBu) return FALSE;
    got = VirtualQuery((const void*)addr, &mbi, (SIZE_T)sizeof(mbi));
    if (got != sizeof(mbi)) return FALSE;
    if (mbi.State != MEM_COMMIT) return FALSE;
    if ((mbi.Protect & PAGE_GUARD) != 0u) return FALSE;
    if ((mbi.Protect & 0xFFu) == PAGE_NOACCESS) return FALSE;
    base = (DWORD)mbi.BaseAddress;
    if (mbi.RegionSize > (SIZE_T)(0xFFFFFFFFu - base)) return FALSE;
    end = base + (DWORD)mbi.RegionSize;
    if (addr < base || addr + 4u > end) return FALSE;
    return TRUE;
}

static BOOL rd_u32(DWORD addr, DWORD* out) {
    if (!out || !readable4(addr)) return FALSE;
    *out = *(volatile DWORD*)addr;
    return TRUE;
}

static BOOL rd_f32(DWORD addr, float* out) {
    if (!out || !readable4(addr)) return FALSE;
    *out = *(volatile float*)addr;
    return TRUE;
}

static BOOL rd_u8(DWORD addr, BYTE* out) {
    DWORD aligned;
    if (!out) return FALSE;
    aligned = addr & ~3u;
    if (!readable4(aligned)) return FALSE;
    *out = *(volatile BYTE*)addr;
    return TRUE;
}



static void log_line(const char* s);

static BOOL read_ascii_name(DWORD addr, char out[MAX_PLAYER_NAME + 1u]) {
    DWORD i;
    BYTE c;
    if (!out) return FALSE;
    out[0] = 0;
    for (i = 0u; i < MAX_PLAYER_NAME; ++i) {
        if (!rd_u8(addr + i, &c)) {
            out[0] = 0;
            return FALSE;
        }
        if (c == 0u) {
            out[i] = 0;
            return (i > 0u) ? TRUE : FALSE;
        }
        /* Vanilla names are normally alphabetic; allow basic printable bytes for custom realms. */
        if (c < 0x20u || c > 0x7Eu) {
            out[0] = 0;
            return FALSE;
        }
        out[i] = (char)c;
    }
    out[MAX_PLAYER_NAME] = 0;
    return TRUE;
}

static BOOL lookup_player_name(DWORD guidLo, DWORD guidHi,
                               char out[MAX_PLAYER_NAME + 1u], DWORD* nodesVisited,
                               const char** outReason) {
    DWORD node, next, lo, hi;
    DWORD count = 0u, i;
    if (out) out[0] = 0;
    if (nodesVisited) *nodesVisited = 0u;
    if (outReason) *outReason = "UNKNOWN";

    if (!rd_u32(PLAYER_NAME_CACHE_HEAD, &node)) {
        if (outReason) *outReason = "HEAD_UNREADABLE";
        return FALSE;
    }
    if (node == 0u || (node & 1u) != 0u) {
        if (outReason) *outReason = "HEAD_EMPTY";
        return FALSE;
    }

    while (count < MAX_NAME_NODES) {
        if (node == 0u) { if (outReason) *outReason = "NULL"; break; }
        if ((node & 1u) != 0u || node < 0x00010000u || node > 0x7FFF0000u) {
            if (outReason) *outReason = "BAD_NODE";
            break;
        }
        if (!readable4(node + NAME_NODE_NEXT) ||
            !readable4(node + NAME_NODE_GUID_LO) ||
            !readable4(node + NAME_NODE_GUID_HI)) {
            if (outReason) *outReason = "NODE_UNREADABLE";
            break;
        }
        for (i = 0u; i < count; ++i) {
            if (g_name_visited[i] == node) {
                if (outReason) *outReason = "CYCLE";
                if (nodesVisited) *nodesVisited = count;
                return FALSE;
            }
        }
        g_name_visited[count++] = node;

        if (!rd_u32(node + NAME_NODE_GUID_LO, &lo) || !rd_u32(node + NAME_NODE_GUID_HI, &hi)) {
            if (outReason) *outReason = "GUID_UNREADABLE";
            break;
        }
        /* Zzuk-style cache terminator: zero GUID means no more populated entries. */
        if (lo == 0u && hi == 0u) {
            if (outReason) *outReason = "END_GUID_ZERO";
            break;
        }
        if (lo == guidLo && hi == guidHi) {
            if (read_ascii_name(node + NAME_NODE_STRING, out)) {
                if (nodesVisited) *nodesVisited = count;
                if (outReason) *outReason = "FOUND";
                return TRUE;
            }
            if (outReason) *outReason = "NAME_UNREADABLE";
            break;
        }
        if (!rd_u32(node + NAME_NODE_NEXT, &next)) {
            if (outReason) *outReason = "NEXT_UNREADABLE";
            break;
        }
        if (next == node) {
            if (outReason) *outReason = "SELF_LOOP";
            break;
        }
        node = next;
    }
    if (count >= MAX_NAME_NODES && outReason) *outReason = "MAX_NODES";
    if (nodesVisited) *nodesVisited = count;
    return FALSE;
}

static void log_name(const char* prefix, DWORD obj, DWORD lo, DWORD hi,
                     const char* name, BOOL found, DWORD nodes, const char* reason) {
    char b[512]; char* p = b;
    p = app_str(p, prefix);
    p = app_str(p, " ptr=0x"); p = app_hex8(p, obj);
    p = app_str(p, " guid=0x"); p = app_hex8(p, hi); p = app_hex8(p, lo);
    p = app_str(p, " cache=0x"); p = app_hex8(p, PLAYER_NAME_CACHE_HEAD);
    p = app_str(p, " nodes="); p = app_u32(p, nodes);
    p = app_str(p, " status="); p = app_str(p, found ? "FOUND" : "MISS");
    p = app_str(p, " name=");
    if (found && name && name[0]) p = app_str(p, name); else p = app_str(p, "<none>");
    p = app_str(p, " reason="); p = app_str(p, reason ? reason : "UNKNOWN");
    *p = 0;
    log_line(b);
}

static BOOL read_unit_meta(DWORD obj, struct UnitMeta* m) {
    DWORD desc, uf;
    DWORD h2, mh2, lv2, f2, b2;
    if (!m) return FALSE;
    m->desc = 0u; m->unitFields = 0u;
    m->health = 0u; m->maxHealth = 0u; m->level = 0u;
    m->faction = 0u; m->bytes0 = 0u;
    m->raceId = 0u; m->classId = 0u; m->sexId = 0u;
    m->xcheckAvailable = FALSE; m->xcheckOk = FALSE;

    if (!rd_u32(obj + OBJ_DESC_PTR, &desc)) return FALSE;
    if (desc < 0x00010000u || desc > 0x7FFF0000u) return FALSE;
    if (!readable4(desc + DESC_BYTES0)) return FALSE;

    if (!rd_u32(desc + DESC_HEALTH, &m->health)) return FALSE;
    if (!rd_u32(desc + DESC_MAX_HEALTH, &m->maxHealth)) return FALSE;
    if (!rd_u32(desc + DESC_LEVEL, &m->level)) return FALSE;
    if (!rd_u32(desc + DESC_FACTION, &m->faction)) return FALSE;
    if (!rd_u32(desc + DESC_BYTES0, &m->bytes0)) return FALSE;
    m->desc = desc;
    m->raceId = (BYTE)(m->bytes0 & 0xFFu);
    m->classId = (BYTE)((m->bytes0 >> 8) & 0xFFu);
    m->sexId = (BYTE)((m->bytes0 >> 16) & 0xFFu);

    /* Cross-check against the client's shifted Unit-field view. */
    if (rd_u32(obj + OBJ_UNIT_FIELDS_PTR, &uf) &&
        uf >= 0x00010000u && uf <= 0x7FFF0000u &&
        readable4(uf + UF_BYTES0)) {
        m->unitFields = uf;
        m->xcheckAvailable = TRUE;
        if (rd_u32(uf + UF_HEALTH, &h2) &&
            rd_u32(uf + UF_MAX_HEALTH, &mh2) &&
            rd_u32(uf + UF_LEVEL, &lv2) &&
            rd_u32(uf + UF_FACTION, &f2) &&
            rd_u32(uf + UF_BYTES0, &b2)) {
            if (h2 == m->health && mh2 == m->maxHealth &&
                lv2 == m->level && f2 == m->faction && b2 == m->bytes0) {
                m->xcheckOk = TRUE;
            }
        }
    }
    return TRUE;
}

static const char* class_name(BYTE id) {
    switch (id) {
        case 1: return "Warrior";
        case 2: return "Paladin";
        case 3: return "Hunter";
        case 4: return "Rogue";
        case 5: return "Priest";
        case 7: return "Shaman";
        case 8: return "Mage";
        case 9: return "Warlock";
        case 11: return "Druid";
        default: return "Unknown";
    }
}

static const char* race_name(BYTE id) {
    switch (id) {
        case 1: return "Human";
        case 2: return "Orc";
        case 3: return "Dwarf";
        case 4: return "NightElf";
        case 5: return "Undead";
        case 6: return "Tauren";
        case 7: return "Gnome";
        case 8: return "Troll";
        default: return "Unknown";
    }
}

static const char* reaction_name(int r) {
    switch (r) {
        case 1: return "Hated";
        case 2: return "Hostile";
        case 3: return "Unfriendly";
        case 4: return "Neutral";
        case 5: return "Friendly";
        case 6: return "HonoredPlus";
        case 7: return "Revered";
        case 8: return "Exalted";
        default: return "Unknown";
    }
}

static int native_unit_reaction(DWORD selfObj, DWORD targetObj) {
    UnitReactionFn fn = (UnitReactionFn)FN_UNIT_REACTION;
    return fn(selfObj, targetObj);
}

static BYTE native_can_attack(DWORD selfObj, DWORD targetObj) {
    CanAttackFn fn = (CanAttackFn)FN_CAN_ATTACK;
    return fn(selfObj, targetObj);
}

static BYTE native_unit_is_pvp(DWORD unitObj) {
    UnitIsPvpFn fn = (UnitIsPvpFn)FN_UNIT_IS_PVP;
    return fn(unitObj);
}

static void log_relation(DWORD obj, DWORD lo, DWORD hi, int reaction, BYTE canAttack, BYTE pvpEnabled) {
    char b[448]; char* p = b;
    DWORD enemyRelation = (reaction >= 1 && reaction <= 3) ? 1u : 0u;
    p = app_str(p, "PLAYER_RELATION ptr=0x"); p = app_hex8(p, obj);
    p = app_str(p, " guid=0x"); p = app_hex8(p, hi); p = app_hex8(p, lo);
    p = app_str(p, " reaction=");
    if (reaction < 0) { *p++ = '-'; p = app_u32(p, (DWORD)(-reaction)); }
    else p = app_u32(p, (DWORD)reaction);
    p = app_str(p, "("); p = app_str(p, reaction_name(reaction)); p = app_str(p, ")");
    p = app_str(p, " enemy_relation="); p = app_u32(p, enemyRelation);
    p = app_str(p, " can_attack="); p = app_u32(p, (DWORD)(canAttack ? 1u : 0u));
    p = app_str(p, " attackable_now="); p = app_u32(p, (DWORD)(canAttack ? 1u : 0u));
    p = app_str(p, " pvp_enabled="); p = app_u32(p, (DWORD)(pvpEnabled ? 1u : 0u));
    *p = 0;
    log_line(b);
}

static BOOL init_projection_context(struct ProjectionContext* c, const char** outReason) {
    DWORD wf = 0u, cam = 0u;
    HWND hwnd = NULL;
    struct RECT32 r;
    GetGameWindowFn getWindow = (GetGameWindowFn)FN_GET_GAME_WINDOW;
    GetActiveCameraFn getCamera = (GetActiveCameraFn)FN_GET_ACTIVE_CAMERA;
    if (outReason) *outReason = "UNKNOWN";
    if (!c) return FALSE;
    c->worldFrame = 0u; c->camera = 0u; c->hwnd = NULL;
    c->width = 0u; c->height = 0u;
    c->camX = 0.0f; c->camY = 0.0f; c->camZ = 0.0f;
    c->cameraPosOk = FALSE; c->ready = FALSE;

    if (!rd_u32(WORLD_FRAME_GLOBAL, &wf) || wf == 0u || (wf & 1u) != 0u || !readable4(wf)) {
        if (outReason) *outReason = "WORLD_FRAME_BAD";
        return FALSE;
    }
    hwnd = getWindow(0);
    if (!hwnd) { if (outReason) *outReason = "HWND_NULL"; return FALSE; }
    r.left = r.top = r.right = r.bottom = 0;
    if (!GetClientRect(hwnd, &r)) { if (outReason) *outReason = "GETCLIENTRECT_FAIL"; return FALSE; }
    if (r.right <= r.left || r.bottom <= r.top) { if (outReason) *outReason = "CLIENTRECT_BAD"; return FALSE; }

    cam = getCamera();
    c->worldFrame = wf;
    c->camera = cam;
    c->hwnd = hwnd;
    c->width = (DWORD)(r.right - r.left);
    c->height = (DWORD)(r.bottom - r.top);
    if (cam != 0u && (cam & 1u) == 0u &&
        rd_f32(cam + CAMERA_POS_X, &c->camX) &&
        rd_f32(cam + CAMERA_POS_Y, &c->camY) &&
        rd_f32(cam + CAMERA_POS_Z, &c->camZ)) {
        c->cameraPosOk = TRUE;
    }
    c->ready = TRUE;
    if (outReason) *outReason = "OK";
    return TRUE;
}

static void log_projection_context(const struct ProjectionContext* c, const char* reason) {
    char b[512]; char* p = b;
    p = app_str(p, "W2S_CONTEXT status="); p = app_str(p, (c && c->ready) ? "OK" : "FAIL");
    p = app_str(p, " reason="); p = app_str(p, reason ? reason : "UNKNOWN");
    if (c) {
        p = app_str(p, " world_frame=0x"); p = app_hex8(p, c->worldFrame);
        p = app_str(p, " camera=0x"); p = app_hex8(p, c->camera);
        p = app_str(p, " hwnd=0x"); p = app_hex8(p, (DWORD)c->hwnd);
        p = app_str(p, " client="); p = app_u32(p, c->width); p = app_str(p, "x"); p = app_u32(p, c->height);
        if (c->cameraPosOk) {
            p = app_str(p, " cam_x="); p = app_float2(p, c->camX);
            p = app_str(p, " cam_y="); p = app_float2(p, c->camY);
            p = app_str(p, " cam_z="); p = app_float2(p, c->camZ);
        }
    }
    *p = 0; log_line(b);
}

static BOOL project_world(const struct ProjectionContext* c, float wx, float wy, float wz, struct ProjectionResult* out) {
    float world[3];
    float raw[3];
    float nx = -1.0f, ny = -1.0f;
    WorldToScreenFn w2s = (WorldToScreenFn)FN_WORLD_TO_SCREEN;
    DdcToNdcFn ddc = (DdcToNdcFn)FN_DDC_TO_NDC;
    if (!out) return FALSE;
    out->nativeOk = FALSE; out->rawX = 0.0f; out->rawY = 0.0f;
    out->ndcX = 0.0f; out->ndcY = 0.0f; out->screenX = 0.0f; out->screenY = 0.0f; out->onScreen = FALSE;
    if (!c || !c->ready || c->worldFrame == 0u || c->width == 0u || c->height == 0u) return FALSE;
    world[0] = wx; world[1] = wy; world[2] = wz;
    raw[0] = raw[1] = raw[2] = 0.0f;
    if (!w2s(c->worldFrame, world, raw)) return TRUE;
    out->nativeOk = TRUE;
    out->rawX = raw[0]; out->rawY = raw[1];
    ddc(&nx, &ny, raw[0], raw[1]);
    out->ndcX = nx; out->ndcY = ny;
    out->screenX = nx * (float)c->width;
    out->screenY = (float)c->height - (ny * (float)c->height);
    if (out->screenX >= 0.0f && out->screenX <= (float)c->width &&
        out->screenY >= 0.0f && out->screenY <= (float)c->height) out->onScreen = TRUE;
    return TRUE;
}

static void log_projection(const char* prefix, DWORD obj, DWORD lo, DWORD hi,
                           float wx, float wy, float wz, const struct ProjectionResult* r) {
    char b[768]; char* p = b;
    p = app_str(p, prefix);
    p = app_str(p, " ptr=0x"); p = app_hex8(p, obj);
    p = app_str(p, " guid=0x"); p = app_hex8(p, hi); p = app_hex8(p, lo);
    p = app_str(p, " world_x="); p = app_float2(p, wx);
    p = app_str(p, " world_y="); p = app_float2(p, wy);
    p = app_str(p, " world_z="); p = app_float2(p, wz);
    p = app_str(p, " status="); p = app_str(p, (r && r->nativeOk) ? "OK" : "NATIVE_FALSE");
    if (r && r->nativeOk) {
        p = app_str(p, " raw_x="); p = app_float2(p, r->rawX);
        p = app_str(p, " raw_y="); p = app_float2(p, r->rawY);
        p = app_str(p, " ndc_x="); p = app_float2(p, r->ndcX);
        p = app_str(p, " ndc_y="); p = app_float2(p, r->ndcY);
        p = app_str(p, " screen_x="); p = app_float2(p, r->screenX);
        p = app_str(p, " screen_y="); p = app_float2(p, r->screenY);
        p = app_str(p, " on_screen="); p = app_u32(p, (DWORD)(r->onScreen ? 1u : 0u));
    }
    *p = 0; log_line(b);
}

static BOOL bytes_match(DWORD addr, const BYTE* sig, DWORD n) {
    DWORD i;
    BYTE b;
    for (i = 0u; i < n; ++i) {
        if (!rd_u8(addr + i, &b) || b != sig[i]) return FALSE;
    }
    return TRUE;
}

static BOOL validate_exact_build(void) {
    static const BYTE sigEnum[] = {
        0xA1,0x14,0x14,0xB4,0x00,0x53,0x8B,0x98,0xAC,0x00,0x00,0x00,0xF6,0xC3,0x01
    };
    static const BYTE sigGetPtr[] = {
        0x55,0x8B,0xEC,0x8B,0x45,0x08,0x8B,0x4D,0x0C,0x8B,0xD0,0x0B,0xD1
    };
    static const BYTE sigActiveGuid[] = {
        0x8B,0x0D,0x14,0x14,0xB4,0x00,0x85,0xC9
    };
    static const BYTE sigReaction[] = {
        0x53,0x8B,0xDC,0x83,0xEC,0x08,0x83,0xE4,0xF8,0x83,0xC4,0x04,0x55
    };
    static const BYTE sigCanAttack[] = {
        0x55,0x8B,0xEC,0x56,0x8B,0x75,0x08,0x8B,0x46,0x08,0x57,0x8B,0xF9
    };
    static const BYTE sigTargetGuid[] = { 0x56,0x8B,0xF1,0x8B,0x46,0x04,0x8B,0x0E };
    static const BYTE sigUnitIsPvp[] = {
        0x56,0x8B,0xF1,0x8B,0x8E,0x10,0x01,0x00,0x00,0x8B,0x51,0x10
    };
    static const BYTE sigWorldToScreen[] = {
        0x55,0x8B,0xEC,0x83,0xEC,0x24,0x8B,0x45,0x08,0x8B,0x50,0x04,0x56,0x8B,0xF1,0x8B
    };
    static const BYTE sigDdcToNdc[] = {
        0x55,0x8B,0xEC,0x85,0xC9,0x74,0x0B,0xD9,0x45,0x08,0xD8,0x35,0x44,0x2A,0x83,0x00
    };
    static const BYTE sigGetGameWindow[] = {
        0x83,0xE9,0x00,0x74,0x15,0x49,0x74,0x0C,0x49,0x74,0x03,0x33,0xC0,0xC3
    };
    static const BYTE sigGetCamera[] = {
        0xA1,0xBC,0xB2,0xB4,0x00,0x8B,0x80,0xB8,0x65,0x00,0x00,0xC3
    };
    if (!bytes_match(FN_ENUM_VISIBLE, sigEnum, (DWORD)sizeof(sigEnum))) return FALSE;
    if (!bytes_match(FN_GETPTR_CORE, sigGetPtr, (DWORD)sizeof(sigGetPtr))) return FALSE;
    if (!bytes_match(FN_ACTIVE_GUID, sigActiveGuid, (DWORD)sizeof(sigActiveGuid))) return FALSE;
    if (!bytes_match(FN_UNIT_REACTION, sigReaction, (DWORD)sizeof(sigReaction))) return FALSE;
    if (!bytes_match(FN_CAN_ATTACK, sigCanAttack, (DWORD)sizeof(sigCanAttack))) return FALSE;
    if (!bytes_match(FN_TARGET_GUID, sigTargetGuid, (DWORD)sizeof(sigTargetGuid))) return FALSE;
    if (!bytes_match(FN_UNIT_IS_PVP, sigUnitIsPvp, (DWORD)sizeof(sigUnitIsPvp))) return FALSE;
    if (!bytes_match(FN_WORLD_TO_SCREEN, sigWorldToScreen, (DWORD)sizeof(sigWorldToScreen))) return FALSE;
    if (!bytes_match(FN_DDC_TO_NDC, sigDdcToNdc, (DWORD)sizeof(sigDdcToNdc))) return FALSE;
    if (!bytes_match(FN_GET_GAME_WINDOW, sigGetGameWindow, (DWORD)sizeof(sigGetGameWindow))) return FALSE;
    if (!bytes_match(FN_GET_ACTIVE_CAMERA, sigGetCamera, (DWORD)sizeof(sigGetCamera))) return FALSE;
    return TRUE;
}

static BOOL object_ptr_sane(DWORD p) {
    if (p == 0u) return FALSE;
    if ((p & 1u) != 0u) return FALSE; /* known list sentinel convention */
    if ((p & 3u) != 0u) return FALSE;
    if (p < 0x00010000u || p > 0x7FFF0000u) return FALSE;
    if (!readable4(p + OBJ_TYPE)) return FALSE;
    if (!readable4(p + g_next_offset)) return FALSE;
    return TRUE;
}

static BOOL seen_before(DWORD p, DWORD count) {
    DWORD i;
    for (i = 0; i < count; ++i) {
        if (g_visited[i] == p) return TRUE;
    }
    return FALSE;
}

static void log_raw(const char* s, DWORD n) {
    DWORD wrote = 0;
    if (g_log == INVALID_HANDLE_VALUE || !s || n == 0u) return;
    WriteFile(g_log, s, n, &wrote, NULL);
}

static void log_line(const char* s) {
    log_raw(s, cstr_len(s));
    log_raw("\r\n", 2u);
}

static void build_log_path(char out[260]) {
    DWORD n, i, last_sep = 0u;
    const char* name = "WoWPlayerESP_v1_2_range_sweep.log";
    n = GetModuleFileNameA(g_self, out, 259u);
    if (n == 0u || n >= 259u) {
        i = 0u;
        while (name[i] && i < 259u) { out[i] = name[i]; i++; }
        out[i] = 0;
        return;
    }
    out[n] = 0;
    for (i = 0u; i < n; ++i) {
        if (out[i] == '\\' || out[i] == '/') last_sep = i + 1u;
    }
    i = 0u;
    while (name[i] && last_sep + i < 259u) {
        out[last_sep + i] = name[i];
        i++;
    }
    out[last_sep + i] = 0;
}

static void log_scan_end(const char* reason, DWORD count) {
    char b[192]; char* p = b;
    p = app_str(p, "SCAN_END reason=");
    p = app_str(p, reason);
    p = app_str(p, " objects=");
    p = app_u32(p, count);
    *p = 0;
    log_line(b);
}

static BOOL find_local_player(DWORD manager, DWORD guidLo, DWORD guidHi,
                              DWORD* localObj, float* lx, float* ly, float* lz,
                              DWORD* outCount, const char** outReason) {
    DWORD obj, next, type, lo, hi, count = 0u;
    if (!rd_u32(manager + OM_FIRST_OBJECT, &obj)) {
        *outReason = "FIRST_OBJECT_UNREADABLE";
        return FALSE;
    }
    while (count < MAX_OBJECTS) {
        if (obj == 0u) { *outReason = "NULL"; break; }
        if ((obj & 1u) != 0u) { *outReason = "ODD_SENTINEL"; break; }
        if (!object_ptr_sane(obj)) { *outReason = "BAD_OBJECT_PTR"; break; }
        if (seen_before(obj, count)) { *outReason = "CYCLE"; break; }
        g_visited[count++] = obj;

        if (!rd_u32(obj + OBJ_TYPE, &type)) { *outReason = "TYPE_UNREADABLE"; break; }
        if (type == TYPEID_PLAYER) {
if (rd_u32(obj + OBJ_GUID_LO, &lo) && rd_u32(obj + OBJ_GUID_HI, &hi)) {
                if (lo == guidLo && hi == guidHi) {
                    if (rd_f32(obj + OBJ_POS_X, lx) && rd_f32(obj + OBJ_POS_Y, ly) && rd_f32(obj + OBJ_POS_Z, lz)) {
                        *localObj = obj;
                        *outCount = count;
                        *outReason = "LOCAL_FOUND";
                        return TRUE;
                    }
                    *outReason = "LOCAL_POS_UNREADABLE";
                    *outCount = count;
                    return FALSE;
                }
            }
        }
        if (!rd_u32(obj + g_next_offset, &next)) { *outReason = "NEXT_UNREADABLE"; break; }
        if (next == obj) { *outReason = "SELF_LOOP"; break; }
        if (next == manager) { *outReason = "MANAGER_SENTINEL"; break; }
        obj = next;
    }
    if (count >= MAX_OBJECTS) *outReason = "MAX_OBJECTS";
    *outCount = count;
    return FALSE;
}

static void log_player(DWORD obj, DWORD lo, DWORD hi, float x, float y, float z, float dist) {
    char b[512]; char* p = b;
    p = app_str(p, "PLAYER ptr=0x"); p = app_hex8(p, obj);
    p = app_str(p, " guid=0x"); p = app_hex8(p, hi); p = app_hex8(p, lo);
    p = app_str(p, " type=4 x="); p = app_float2(p, x);
    p = app_str(p, " y="); p = app_float2(p, y);
    p = app_str(p, " z="); p = app_float2(p, z);
    p = app_str(p, " distance="); p = app_float2(p, dist);
    *p = 0;
    log_line(b);
}


static void log_meta(const char* prefix, DWORD obj, DWORD lo, DWORD hi, const struct UnitMeta* m) {
    char b[768]; char* p = b;
    p = app_str(p, prefix);
    p = app_str(p, " ptr=0x"); p = app_hex8(p, obj);
    p = app_str(p, " guid=0x"); p = app_hex8(p, hi); p = app_hex8(p, lo);
    p = app_str(p, " desc=0x"); p = app_hex8(p, m->desc);
    p = app_str(p, " hp="); p = app_u32(p, m->health);
    p = app_str(p, " maxhp="); p = app_u32(p, m->maxHealth);
    p = app_str(p, " level="); p = app_u32(p, m->level);
    p = app_str(p, " faction="); p = app_u32(p, m->faction);
    p = app_str(p, " bytes0=0x"); p = app_hex8(p, m->bytes0);
    p = app_str(p, " race="); p = app_u32(p, (DWORD)m->raceId);
    p = app_str(p, "("); p = app_str(p, race_name(m->raceId)); p = app_str(p, ")");
    p = app_str(p, " class="); p = app_u32(p, (DWORD)m->classId);
    p = app_str(p, "("); p = app_str(p, class_name(m->classId)); p = app_str(p, ")");
    p = app_str(p, " sex="); p = app_u32(p, (DWORD)m->sexId);
    p = app_str(p, " unit_fields=0x"); p = app_hex8(p, m->unitFields);
    p = app_str(p, " xcheck=");
    if (!m->xcheckAvailable) p = app_str(p, "NA");
    else p = app_str(p, m->xcheckOk ? "OK" : "MISMATCH");
    *p = 0;
    log_line(b);
}

static void log_max_distance(DWORD obj, DWORD lo, DWORD hi, float dist) {
    char b[256]; char* p = b;
    p = app_str(p, "ESP_MAX_DISTANCE distance="); p = app_float2(p, dist);
    p = app_str(p, " ptr=0x"); p = app_hex8(p, obj);
    p = app_str(p, " guid=0x"); p = app_hex8(p, hi); p = app_hex8(p, lo);
    *p = 0;
    log_line(b);
}


static void pump_overlay_messages(void) {
    struct MSG32 msg;
    while (PeekMessageA(&msg, NULL, 0u, 0u, PM_REMOVE)) {
        TranslateMessage(&msg);
        DispatchMessageA(&msg);
    }
}

static void destroy_label_backbuffer(void) {
    if (g_label_memdc) {
        if (g_label_old_bitmap) SelectObject(g_label_memdc, g_label_old_bitmap);
        if (g_label_bitmap) DeleteObject((HGDIOBJ)g_label_bitmap);
        DeleteDC(g_label_memdc);
    }
    g_label_memdc = NULL;
    g_label_bitmap = NULL;
    g_label_old_bitmap = NULL;
    g_label_pixels = NULL;
}

static void hide_all_labels(void) {
    DWORD i;
    for (i = 0u; i < MAX_ESP_PLAYERS; ++i) {
        if (g_labels[i].hwnd && IsWindow(g_labels[i].hwnd) && g_labels[i].visible) {
            ShowWindow(g_labels[i].hwnd, SW_HIDE);
            g_labels[i].visible = FALSE;
        }
    }
}

static void destroy_overlay(void) {
    DWORD i;
    destroy_label_backbuffer();
    for (i = 0u; i < MAX_ESP_PLAYERS; ++i) {
        if (g_labels[i].hwnd && IsWindow(g_labels[i].hwnd)) DestroyWindow(g_labels[i].hwnd);
        g_labels[i].hwnd = NULL;
        g_labels[i].visible = FALSE;
        g_labels[i].x = g_labels[i].y = 0;
    }
}

static void overlay_hide(void) {
    g_click_hit_count = 0u;
    hide_all_labels();
}

static void clear_label_pixels(void) {
    DWORD i;
    if (!g_label_pixels) return;
    for (i = 0u; i < (DWORD)(LABEL_W * LABEL_H); ++i) g_label_pixels[i] = 0u;
}

static void finalize_label_alpha(void) {
    DWORD i;
    if (!g_label_pixels) return;
    for (i = 0u; i < (DWORD)(LABEL_W * LABEL_H); ++i) {
        DWORD rgb = g_label_pixels[i] & 0x00FFFFFFu;
        if (rgb != 0u) g_label_pixels[i] = rgb | 0xFF000000u;
        else g_label_pixels[i] = 0u;
    }
}

static BOOL ensure_label_backbuffer(HWND gameHwnd) {
    HDC dc;
    struct BITMAPINFO32 bmi;
    void* bits = NULL;
    if (g_label_memdc && g_label_bitmap && g_label_pixels) return TRUE;
    if (!gameHwnd) return FALSE;
    dc = GetDC(gameHwnd);
    if (!dc) return FALSE;
    g_label_memdc = CreateCompatibleDC(dc);
    if (g_label_memdc) {
        bmi.bmiHeader.biSize = (DWORD)sizeof(struct BITMAPINFOHEADER32);
        bmi.bmiHeader.biWidth = LABEL_W;
        bmi.bmiHeader.biHeight = -LABEL_H; /* top-down DIB */
        bmi.bmiHeader.biPlanes = 1u;
        bmi.bmiHeader.biBitCount = 32u;
        bmi.bmiHeader.biCompression = BI_RGB;
        bmi.bmiHeader.biSizeImage = 0u;
        bmi.bmiHeader.biXPelsPerMeter = 0;
        bmi.bmiHeader.biYPelsPerMeter = 0;
        bmi.bmiHeader.biClrUsed = 0u;
        bmi.bmiHeader.biClrImportant = 0u;
        bmi.bmiColors[0] = 0u;
        g_label_bitmap = CreateDIBSection(dc, &bmi, DIB_RGB_COLORS, &bits, NULL, 0u);
        if (g_label_bitmap && bits) {
            g_label_pixels = (DWORD*)bits;
            g_label_old_bitmap = SelectObject(g_label_memdc, (HGDIOBJ)g_label_bitmap);
            SelectObject(g_label_memdc, GetStockObject(DEFAULT_GUI_FONT_ID));
            clear_label_pixels();
        }
    }
    ReleaseDC(gameHwnd, dc);
    if (!g_label_memdc || !g_label_bitmap || !g_label_pixels) {
        destroy_label_backbuffer();
        return FALSE;
    }
    return TRUE;
}

static BOOL update_label_alpha(HWND hwnd, LONG absX, LONG absY) {
    struct POINT32 dst;
    struct POINT32 src;
    struct SIZE32 size;
    struct BLENDFUNCTION32 blend;
    dst.x = absX; dst.y = absY;
    src.x = 0; src.y = 0;
    size.cx = LABEL_W; size.cy = LABEL_H;
    blend.BlendOp = AC_SRC_OVER;
    blend.BlendFlags = 0u;
    blend.SourceConstantAlpha = 255u;
    blend.AlphaFormat = AC_SRC_ALPHA;
    return UpdateLayeredWindow(hwnd, NULL, &dst, &size, g_label_memdc, &src, 0u, &blend, ULW_ALPHA);
}

static BOOL ensure_label_window(DWORD index, LONG absX, LONG absY) {
    DWORD exStyle;
    if (index >= MAX_ESP_PLAYERS) return FALSE;
    if (!g_labels[index].hwnd || !IsWindow(g_labels[index].hwnd)) {
        exStyle = WS_EX_TOPMOST | WS_EX_TRANSPARENT | WS_EX_TOOLWINDOW | WS_EX_LAYERED | WS_EX_NOACTIVATE;
        g_labels[index].hwnd = CreateWindowExA(exStyle, "STATIC", "", WS_POPUP,
                                               (int)absX, (int)absY, LABEL_W, LABEL_H,
                                               NULL, NULL, g_self, NULL);
        if (!g_labels[index].hwnd) return FALSE;
        g_labels[index].x = absX;
        g_labels[index].y = absY;
        g_labels[index].visible = FALSE;
        g_labels[index].contentValid = FALSE;
        if (!g_overlay_logged) {
            log_line("OVERLAY_CREATE_OK method=PER_LABEL_ALPHA_WINDOWS pooled=1 full_screen_surface=0 cache=1 hostile_only=1");
            g_overlay_logged = TRUE;
        }
    }
    if (!g_labels[index].visible || g_labels[index].x != absX || g_labels[index].y != absY) {
        if (!SetWindowPos(g_labels[index].hwnd, (HWND)(-1), (int)absX, (int)absY,
                          LABEL_W, LABEL_H, SWP_NOACTIVATE)) return FALSE;
        g_labels[index].x = absX;
        g_labels[index].y = absY;
    }
    return TRUE;
}

static void hide_unused_labels(DWORD used) {
    DWORD i;
    for (i = used; i < MAX_ESP_PLAYERS; ++i) {
        if (g_labels[i].hwnd && IsWindow(g_labels[i].hwnd) && g_labels[i].visible) {
            ShowWindow(g_labels[i].hwnd, SW_HIDE);
            g_labels[i].visible = FALSE;
        }
    }
}

static BOOL game_client_screen_rect(HWND gameHwnd, LONG* sx, LONG* sy, DWORD* width, DWORD* height) {
    struct RECT32 r;
    struct POINT32 p0;
    if (!gameHwnd || !sx || !sy || !width || !height) return FALSE;
    r.left = r.top = r.right = r.bottom = 0;
    p0.x = 0; p0.y = 0;
    if (!GetClientRect(gameHwnd, &r)) return FALSE;
    if (r.right <= r.left || r.bottom <= r.top) return FALSE;
    if (!ClientToScreen(gameHwnd, &p0)) return FALSE;
    *sx = p0.x;
    *sy = p0.y;
    *width = (DWORD)(r.right - r.left);
    *height = (DWORD)(r.bottom - r.top);
    return TRUE;
}

static void draw_text_centered(HDC dc, int cx, int y, const char* text, COLORREF color) {
    struct SIZE32 sz;
    int len;
    int x;
    if (!dc || !text || !text[0]) return;
    len = (int)cstr_len(text);
    sz.cx = 0; sz.cy = 0;
    if (!GetTextExtentPoint32A(dc, text, len, &sz)) {
        sz.cx = len * 7;
        sz.cy = 14;
    }
    x = cx - (sz.cx / 2);
    SetBkMode(dc, TRANSPARENT_BK);
    SetTextColor(dc, COLOR_SHADOW);
    TextOutA(dc, x + 1, y + 1, text, len);
    SetTextColor(dc, color);
    TextOutA(dc, x, y, text, len);
}

static void draw_esp_label(HDC dc, const char* name,
                           DWORD hp, DWORD maxHp, float distance, BYTE pvpEnabled,
                           BYTE source, DWORD ageSec) {
    char line1[64], line2[96], line3[128];
    char* p;
    DWORD pct = 0u;
    DWORD yd = (DWORD)(distance + 0.5f);
    if (maxHp != 0u) pct = (hp * 100u) / maxHp;

    p = line1;
    p = app_str(p, (name && name[0]) ? name : "Unknown");
    *p = 0;

    p = line2;
    p = app_str(p, "HP ");
    p = app_u32(p, hp);
    p = app_str(p, "/");
    p = app_u32(p, maxHp);
    p = app_str(p, " ");
    p = app_u32(p, pct);
    p = app_str(p, "%");
    *p = 0;

    p = line3;
    p = app_u32(p, yd);
    p = app_str(p, " yd | PvP ");
    p = app_str(p, pvpEnabled ? "ON" : "OFF");
    if (source == SOURCE_GUID_LOOKUP) {
        p = app_str(p, " | MEM");
    } else if (source == SOURCE_STALE_CACHE) {
        p = app_str(p, " | LAST ");
        p = app_u32(p, ageSec);
        p = app_str(p, "s");
    } else {
        p = app_str(p, " | LIVE");
    }
    *p = 0;

    draw_text_centered(dc, LABEL_W / 2, 5, line1, COLOR_ENEMY);
    draw_text_centered(dc, LABEL_W / 2, 20, line2, COLOR_TEXT);
    draw_text_centered(dc, LABEL_W / 2, 35, line3,
                       source == SOURCE_STALE_CACHE ? COLOR_PVP_OFF :
                       (pvpEnabled ? COLOR_PVP_ON : COLOR_PVP_OFF));
}

static void log_render_summary(DWORD remotePlayers, DWORD hostilePlayers,
                               DWORD projected, DWORD drawn, DWORD width, DWORD height) {
    char b[384]; char* p = b;
    float maxd = sqrt_local(g_max_hostile_distance_sq);
    p = app_str(p, "RENDER_SUMMARY frame=");
    p = app_u32(p, g_render_frame);
    p = app_str(p, " remote_players="); p = app_u32(p, remotePlayers);
    p = app_str(p, " hostile="); p = app_u32(p, hostilePlayers);
    p = app_str(p, " projected="); p = app_u32(p, projected);
    p = app_str(p, " drawn="); p = app_u32(p, drawn);
    p = app_str(p, " client="); p = app_u32(p, width); p = app_str(p, "x"); p = app_u32(p, height);
    p = app_str(p, " max_hostile_distance="); p = app_float2(p, maxd);
    p = app_str(p, " current_farthest="); p = app_float2(p, sqrt_local(g_current_farthest_sq));
    p = app_str(p, " over150="); p = app_u32(p, g_current_over150);
    p = app_str(p, " over300="); p = app_u32(p, g_current_over300);
    *p = 0;
    log_line(b);
}

static void log_render_item(const char* name, DWORD hp, DWORD maxHp, float distance,
                            float screenX, float screenY, int reaction, BYTE canAttack, BYTE pvpEnabled) {
    char b[512]; char* p = b;
    p = app_str(p, "RENDER_ITEM name=");
    p = app_str(p, (name && name[0]) ? name : "Unknown");
    p = app_str(p, " hp="); p = app_u32(p, hp);
    p = app_str(p, "/"); p = app_u32(p, maxHp);
    p = app_str(p, " distance="); p = app_float2(p, distance);
    p = app_str(p, " screen_x="); p = app_float2(p, screenX);
    p = app_str(p, " screen_y="); p = app_float2(p, screenY);
    p = app_str(p, " reaction="); p = app_u32(p, (DWORD)reaction);
    p = app_str(p, " attackable_now="); p = app_u32(p, canAttack ? 1u : 0u);
    p = app_str(p, " pvp_enabled="); p = app_u32(p, pvpEnabled ? 1u : 0u);
    *p = 0;
    log_line(b);
}



static BOOL cached_object_matches(DWORD obj, DWORD lo, DWORD hi);
static BOOL refresh_esp_cache(DWORD manager, DWORD localObj, DWORD guidLo, DWORD guidHi, float lx, float ly, float lz);

__declspec(naked) static void WINAPI range_send_heartbeat_raw(DWORD unit) {
    __asm {
        mov ecx,[esp+4]
        test ecx,ecx
        je short range_hb_done
        push MSG_MOVE_HEARTBEAT
        mov eax,SEND_MOVEMENT_WRAPPER
        call eax
    range_hb_done:
        ret 4
    }
}

static void range_send_position_heartbeat(DWORD localObj, float sx, float sy, float sz, float so) {
    float px, py, pz, po;
    if (!localObj || !cached_object_matches(localObj, g_cached_local_guid_lo, g_cached_local_guid_hi)) return;
    if (!rd_f32(localObj + OBJ_POS_X, &px) || !rd_f32(localObj + OBJ_POS_Y, &py) ||
        !rd_f32(localObj + OBJ_POS_Z, &pz) || !rd_f32(localObj + OBJ_POS_O, &po)) return;
    *(float*)(localObj + OBJ_POS_X) = sx;
    *(float*)(localObj + OBJ_POS_Y) = sy;
    *(float*)(localObj + OBJ_POS_Z) = sz;
    *(float*)(localObj + OBJ_POS_O) = so;
    range_send_heartbeat_raw(localObj);
    *(float*)(localObj + OBJ_POS_X) = px;
    *(float*)(localObj + OBJ_POS_Y) = py;
    *(float*)(localObj + OBJ_POS_Z) = pz;
    *(float*)(localObj + OBJ_POS_O) = po;
}

static void sweep_offset(DWORD idx, float* ox, float* oy) {
    const float d = SWEEP_RADIUS;
    const float q = 84.8528137f; /* 120/sqrt(2) */
    *ox = 0.0f; *oy = 0.0f;
    if (idx == 0u) { *ox = d; }
    else if (idx == 1u) { *ox = -d; }
    else if (idx == 2u) { *oy = d; }
    else if (idx == 3u) { *oy = -d; }
    else if (idx == 4u) { *ox = q; *oy = q; }
    else if (idx == 5u) { *ox = q; *oy = -q; }
    else if (idx == 6u) { *ox = -q; *oy = q; }
    else { *ox = -q; *oy = -q; }
}

static void sweep_log(const char* tag, DWORD idx) {
    char b[192]; char* p = b;
    p = app_str(p, tag);
    p = app_str(p, " index="); p = app_u32(p, idx);
    p = app_str(p, " frame="); p = app_u32(p, g_render_frame);
    *p = 0; log_line(b);
}

static void sweep_restore(DWORD localObj, float lx, float ly, float lz) {
    float lo = 0.0f;
    rd_f32(localObj + OBJ_POS_O, &lo);
    range_send_position_heartbeat(localObj, lx, ly, lz, lo);
    g_sweep_state = 0u;
    g_sweep_index = 0u;
    g_sweep_anchor_obj = 0u;
    g_sweep_next_frame = g_render_frame + SWEEP_REST_FRAMES;
}

static void range_sweep_tick(DWORD manager, DWORD localObj, DWORD guidLo, DWORD guidHi,
                             float lx, float ly, float lz) {
    float ox, oy, mdx, mdy, o = 0.0f;

    if (!g_range_sweep_enabled) {
        if (g_sweep_state != 0u) {
            sweep_restore(localObj, lx, ly, lz);
            log_line("SWEEP_ABORT reason=disabled restore=1");
        }
        return;
    }

    if (g_sweep_state != 0u) {
        mdx = lx - g_sweep_anchor_x;
        mdy = ly - g_sweep_anchor_y;
        if (localObj != g_sweep_anchor_obj || (mdx*mdx + mdy*mdy) > SWEEP_MOVE_ABORT2) {
            sweep_restore(localObj, lx, ly, lz);
            log_line("SWEEP_ABORT reason=player_moved restore=1");
            return;
        }
    }

    if (g_sweep_state == 0u) {
        if (g_render_frame < g_sweep_next_frame) return;
        if (!rd_f32(localObj + OBJ_POS_O, &o)) o = 0.0f;
        g_sweep_anchor_obj = localObj;
        g_sweep_anchor_x = lx; g_sweep_anchor_y = ly; g_sweep_anchor_z = lz; g_sweep_anchor_o = o;
        g_sweep_index = 0u;
        sweep_offset(g_sweep_index, &ox, &oy);
        range_send_position_heartbeat(localObj, lx + ox, ly + oy, lz, o);
        g_sweep_state = 1u;
        g_sweep_next_frame = g_render_frame + SWEEP_DWELL_FRAMES;
        sweep_log("SWEEP_BEGIN", g_sweep_index);
        return;
    }

    if (g_sweep_state == 1u && g_render_frame >= g_sweep_next_frame) {
        /* Capture everything server/client loaded around current probe before moving the server-side center. */
        refresh_esp_cache(manager, localObj, guidLo, guidHi, lx, ly, lz);

        g_sweep_index++;
        if (g_sweep_index >= SWEEP_POINTS) {
            sweep_restore(localObj, lx, ly, lz);
            log_line("SWEEP_END restore=1 cache_retained=1");
            return;
        }

        sweep_offset(g_sweep_index, &ox, &oy);
        range_send_position_heartbeat(localObj, g_sweep_anchor_x + ox, g_sweep_anchor_y + oy,
                                      g_sweep_anchor_z, g_sweep_anchor_o);
        g_sweep_next_frame = g_render_frame + SWEEP_DWELL_FRAMES;
        sweep_log("SWEEP_PROBE", g_sweep_index);
    }
}

static void native_target_guid(DWORD lo, DWORD hi) {
    QWORD guid;
    TargetGuidFn fn = (TargetGuidFn)FN_TARGET_GUID;
    guid = ((QWORD)hi << 32) | (QWORD)lo;
    fn(&guid);
}

static LONG WINAPI esp_game_wndproc(HWND hwnd, UINT msg, DWORD wParam, LONG lParam) {
    if (msg == WM_KEYDOWN && wParam == VK_F8) {
        g_range_sweep_enabled = g_range_sweep_enabled ? 0u : 1u;
        if (g_range_sweep_enabled) {
            g_sweep_next_frame = g_render_frame + 1u;
            log_line("RANGE_SWEEP_TOGGLE enabled=1 radius=120 points=8 stand_still=1");
        } else {
            log_line("RANGE_SWEEP_TOGGLE enabled=0");
        }
        return 0;
    }
    if (msg == WM_LBUTTONDOWN) {
        int mx = (int)(short)(lParam & 0xFFFF);
        int my = (int)(short)((lParam >> 16) & 0xFFFF);
        DWORD i;
        DWORD count = g_click_hit_count;
        if (count > MAX_ESP_PLAYERS) count = MAX_ESP_PLAYERS;
        for (i = 0u; i < count; ++i) {
            struct ClickHit* h = &g_click_hits[i];
            if (mx >= h->left && mx < h->right && my >= h->top && my < h->bottom) {
                native_target_guid(h->guidLo, h->guidHi);
                if (g_log != INVALID_HANDLE_VALUE) {
                    char b[192]; char* p = b;
                    p = app_str(p, "CLICK_TARGET guid=0x"); p = app_hex8(p, h->guidHi); p = app_hex8(p, h->guidLo);
                    p = app_str(p, " x="); p = app_u32(p, (DWORD)(mx < 0 ? 0 : mx));
                    p = app_str(p, " y="); p = app_u32(p, (DWORD)(my < 0 ? 0 : my)); *p = 0;
                    log_line(b);
                }
                return 0;
            }
        }
    }
    if (g_old_game_wndproc) return CallWindowProcA(g_old_game_wndproc, hwnd, msg, wParam, lParam);
    return 0;
}

static BOOL ensure_game_click_hook(HWND hwnd) {
    LONG oldProc;
    if (!hwnd) return FALSE;
    if (g_hooked_game_hwnd == hwnd && g_old_game_wndproc) return TRUE;
    if (g_hooked_game_hwnd && g_old_game_wndproc && IsWindow(g_hooked_game_hwnd)) {
        SetWindowLongA(g_hooked_game_hwnd, GWL_WNDPROC, (LONG)(DWORD)g_old_game_wndproc);
    }
    g_hooked_game_hwnd = NULL;
    g_old_game_wndproc = NULL;
    oldProc = SetWindowLongA(hwnd, GWL_WNDPROC, (LONG)(DWORD)esp_game_wndproc);
    if (!oldProc) return FALSE;
    g_hooked_game_hwnd = hwnd;
    g_old_game_wndproc = (WNDPROC32)(DWORD)oldProc;
    if (!g_click_hook_logged) {
        log_line("CLICK_HOOK_OK mode=LEFT_CLICK_ON_ESP_LABEL native_target=0x00489A40 hotkey=F8_range_sweep");
        g_click_hook_logged = TRUE;
    }
    return TRUE;
}

static void remove_game_click_hook(void) {
    g_click_hit_count = 0u;
    if (g_hooked_game_hwnd && g_old_game_wndproc && IsWindow(g_hooked_game_hwnd)) {
        SetWindowLongA(g_hooked_game_hwnd, GWL_WNDPROC, (LONG)(DWORD)g_old_game_wndproc);
    }
    g_hooked_game_hwnd = NULL;
    g_old_game_wndproc = NULL;
}

static BOOL label_content_changed(DWORD index, DWORD lo, DWORD hi, DWORD hp, DWORD maxHp,
                                  DWORD yd, BYTE pvp, BYTE source, DWORD ageSec) {
    struct LabelOverlay* l;
    if (index >= MAX_ESP_PLAYERS) return TRUE;
    l = &g_labels[index];
    if (!l->contentValid || l->lastGuidLo != lo || l->lastGuidHi != hi ||
        l->lastHp != hp || l->lastMaxHp != maxHp || l->lastYd != yd || l->lastPvp != pvp ||
        l->lastSource != source || l->lastAgeSec != ageSec) {
        l->lastGuidLo = lo; l->lastGuidHi = hi; l->lastHp = hp; l->lastMaxHp = maxHp;
        l->lastYd = yd; l->lastPvp = pvp; l->lastSource = source; l->lastAgeSec = ageSec;
        l->contentValid = TRUE;
        return TRUE;
    }
    return FALSE;
}

static void copy_name_small(char* dst, const char* srcName) {
    DWORD i = 0u;
    if (!dst) return;
    if (!srcName) { dst[0] = 0; return; }
    while (srcName[i] && i < MAX_PLAYER_NAME) { dst[i] = srcName[i]; i++; }
    dst[i] = 0;
}

static BOOL cached_object_matches(DWORD obj, DWORD lo, DWORD hi) {
    DWORD t, rlo, rhi;
    if (!object_ptr_sane(obj)) return FALSE;
    if (!rd_u32(obj + OBJ_TYPE, &t) || t != TYPEID_PLAYER) return FALSE;
    if (!rd_u32(obj + OBJ_GUID_LO, &rlo) || !rd_u32(obj + OBJ_GUID_HI, &rhi)) return FALSE;
    return (rlo == lo && rhi == hi) ? TRUE : FALSE;
}


static DWORD native_get_object_by_guid(DWORD lo, DWORD hi) {
    QWORD guid = ((QWORD)hi << 32) | (QWORD)lo;
    GetObjectByGuidFn fn = (GetObjectByGuidFn)FN_GETPTR_CORE;
    return fn(guid);
}

static int find_tracked_index(DWORD lo, DWORD hi) {
    DWORD i;
    for (i = 0u; i < MAX_TRACKED_PLAYERS; ++i) {
        if (g_tracked[i].used && g_tracked[i].guidLo == lo && g_tracked[i].guidHi == hi)
            return (int)i;
    }
    return -1;
}

static int alloc_tracked_index(DWORD lo, DWORD hi) {
    DWORD i, oldest = 0u, oldestAge = 0u;
    int freeIdx = -1;
    for (i = 0u; i < MAX_TRACKED_PLAYERS; ++i) {
        if (!g_tracked[i].used) { freeIdx = (int)i; break; }
        {
            DWORD age = g_render_frame - g_tracked[i].lastSeenFrame;
            if (age >= oldestAge) { oldestAge = age; oldest = i; }
        }
    }
    if (freeIdx < 0) freeIdx = (int)oldest;
    g_tracked[freeIdx].used = 1u;
    g_tracked[freeIdx].seenThisRefresh = 0u;
    g_tracked[freeIdx].obj = 0u;
    g_tracked[freeIdx].guidLo = lo;
    g_tracked[freeIdx].guidHi = hi;
    g_tracked[freeIdx].reaction = 0;
    g_tracked[freeIdx].canAttack = 0u;
    g_tracked[freeIdx].pvpEnabled = 0u;
    g_tracked[freeIdx].lastSeenFrame = g_render_frame;
    g_tracked[freeIdx].x = g_tracked[freeIdx].y = g_tracked[freeIdx].z = 0.0f;
    g_tracked[freeIdx].health = g_tracked[freeIdx].maxHealth = 0u;
    g_tracked[freeIdx].name[0] = 0;
    return freeIdx;
}

static int get_or_create_tracked(DWORD lo, DWORD hi) {
    int idx = find_tracked_index(lo, hi);
    if (idx >= 0) return idx;
    return alloc_tracked_index(lo, hi);
}

static void update_tracked_from_object(int ti, DWORD obj, DWORD localObj, const char* knownName) {
    struct UnitMeta m;
    float x, y, z;
    if (ti < 0 || ti >= (int)MAX_TRACKED_PLAYERS) return;
    if (!cached_object_matches(obj, g_tracked[ti].guidLo, g_tracked[ti].guidHi)) return;
    if (!rd_f32(obj + OBJ_POS_X, &x) || !rd_f32(obj + OBJ_POS_Y, &y) || !rd_f32(obj + OBJ_POS_Z, &z)) return;
    g_tracked[ti].obj = obj;
    g_tracked[ti].x = x; g_tracked[ti].y = y; g_tracked[ti].z = z;
    g_tracked[ti].reaction = native_unit_reaction(localObj, obj);
    g_tracked[ti].canAttack = native_can_attack(localObj, obj);
    g_tracked[ti].pvpEnabled = native_unit_is_pvp(obj);
    if (read_unit_meta(obj, &m)) {
        g_tracked[ti].health = m.health;
        g_tracked[ti].maxHealth = m.maxHealth;
    }
    if (knownName && knownName[0]) copy_name_small(g_tracked[ti].name, knownName);
    g_tracked[ti].lastSeenFrame = g_render_frame;
}

static void expire_old_tracked(void) {
    DWORD i;
    for (i = 0u; i < MAX_TRACKED_PLAYERS; ++i) {
        if (g_tracked[i].used && (g_render_frame - g_tracked[i].lastSeenFrame) > HISTORY_TTL_FRAMES) {
            g_tracked[i].used = 0u;
            g_tracked[i].seenThisRefresh = 0u;
            g_tracked[i].obj = 0u;
            g_tracked[i].name[0] = 0;
        }
    }
}

static BOOL refresh_esp_cache(DWORD manager, DWORD localObj, DWORD guidLo, DWORD guidHi, float lx, float ly, float lz) {
    DWORD obj, next, type, lo, hi, visited = 0u;
    DWORD count = 0u, i;
    int reaction, ti;
    BYTE canAttack;
    char pname[MAX_PLAYER_NAME + 1u];
    DWORD nameNodes = 0u;
    const char* nameReason = "UNKNOWN";
    BOOL nameFound;
    float px, py, pz, dx, dy, dz, d2;
    struct UnitMeta meta;

    g_current_farthest_sq = 0.0f;
    g_current_over150 = 0u;
    g_current_over300 = 0u;

    if (!manager || !localObj) return FALSE;
    expire_old_tracked();

    for (i = 0u; i < MAX_TRACKED_PLAYERS; ++i) {
        if (g_tracked[i].used) g_tracked[i].seenThisRefresh = 0u;
    }

    if (!rd_u32(manager + OM_FIRST_OBJECT, &obj)) return FALSE;

    while (visited < MAX_OBJECTS) {
        if (obj == 0u || (obj & 1u) != 0u) break;
        if (!object_ptr_sane(obj)) break;
        if (seen_before(obj, visited)) break;
        g_visited[visited++] = obj;

        if (!rd_u32(obj + OBJ_TYPE, &type)) break;
        if (type == TYPEID_PLAYER &&
            rd_u32(obj + OBJ_GUID_LO, &lo) && rd_u32(obj + OBJ_GUID_HI, &hi) &&
            !(lo == guidLo && hi == guidHi)) {
            reaction = native_unit_reaction(localObj, obj);
            canAttack = native_can_attack(localObj, obj);
            if (reaction >= 1 && reaction <= 3) {
                pname[0] = 0;
                nameFound = lookup_player_name(lo, hi, pname, &nameNodes, &nameReason);
                if (!nameFound) copy_name_small(pname, "Unknown");

                ti = get_or_create_tracked(lo, hi);
                g_tracked[ti].seenThisRefresh = 1u;
                update_tracked_from_object(ti, obj, localObj, pname);
                g_tracked[ti].reaction = reaction;
                g_tracked[ti].canAttack = canAttack;

                if (rd_f32(obj + OBJ_POS_X, &px) && rd_f32(obj + OBJ_POS_Y, &py) && rd_f32(obj + OBJ_POS_Z, &pz)) {
                    dx = px - lx; dy = py - ly; dz = pz - lz; d2 = dx*dx + dy*dy + dz*dz;
                    if (d2 > g_current_farthest_sq) g_current_farthest_sq = d2;
                    if (d2 > (150.0f * 150.0f)) g_current_over150++;
                    if (d2 > (300.0f * 300.0f)) g_current_over300++;
                }
            }
        }
        if (!rd_u32(obj + g_next_offset, &next)) break;
        if (next == obj || next == manager) break;
        obj = next;
    }

    /*
      Build current render cache from persistent history.
      Priority:
        LIVE   - present in visible Object Manager this refresh.
        MEM    - absent from enumeration, but native GetObjectByGuid still resolves a valid Player object.
        LAST   - no live object; render last known position for HISTORY_TTL_FRAMES.
    */
    for (i = 0u; i < MAX_TRACKED_PLAYERS && count < MAX_ESP_PLAYERS; ++i) {
        struct TrackedPlayer* t;
        struct EspCacheEntry* e;
        DWORD resolved = 0u;
        BYTE source = SOURCE_STALE_CACHE;

        if (!g_tracked[i].used) continue;
        t = &g_tracked[i];

        if (t->seenThisRefresh && cached_object_matches(t->obj, t->guidLo, t->guidHi)) {
            source = SOURCE_LIVE_ENUM;
            resolved = t->obj;
        } else {
            resolved = native_get_object_by_guid(t->guidLo, t->guidHi);
            if (resolved && cached_object_matches(resolved, t->guidLo, t->guidHi)) {
                source = SOURCE_GUID_LOOKUP;
                update_tracked_from_object((int)i, resolved, localObj, NULL);
            } else {
                resolved = 0u;
                source = SOURCE_STALE_CACHE;
            }
        }

        /* Preserve only enemies learned as hostile. */
        if (!(t->reaction >= 1 && t->reaction <= 3)) continue;

        e = &g_esp_cache[count++];
        e->obj = resolved;
        e->guidLo = t->guidLo;
        e->guidHi = t->guidHi;
        e->reaction = t->reaction;
        e->canAttack = t->canAttack;
        e->pvpEnabled = t->pvpEnabled;
        e->source = source;
        e->lastSeenFrame = t->lastSeenFrame;
        e->x = t->x; e->y = t->y; e->z = t->z;
        e->health = t->health; e->maxHealth = t->maxHealth;
        copy_name_small(e->name, t->name);
    }

    g_esp_cache_count = count;
    g_cache_age_frames = 0u;
    g_cached_local_obj = localObj;
    g_cached_local_guid_lo = guidLo;
    g_cached_local_guid_hi = guidHi;
    return TRUE;
}

static void render_frame_fast(void) {
    DWORD manager, linkBase, guidLo, guidHi, localObj = 0u, dummyCount = 0u;
    DWORD i;
    float lx, ly, lz, x, y, z, dx, dy, dz, d2, d;
    const char* reason = "UNKNOWN";
    struct ProjectionContext projCtx;
    struct ProjectionResult proj;
    const char* projReason = "UNKNOWN";
    struct UnitMeta meta;
    LONG screenLeft = 0, screenTop = 0;
    DWORD width = 0u, height = 0u;
    DWORD drawn = 0u, projected = 0u;
    BOOL needRefresh = FALSE;
    DWORD loCheck, hiCheck;

    g_render_frame++;
    if (g_cache_age_frames != 0xFFFFFFFFu) g_cache_age_frames++;
    pump_overlay_messages();

    if (!rd_u32(OBJMGR_GLOBAL, &manager) ||
        manager < 0x00010000u || manager > 0x7FFF0000u ||
        !readable4(manager + OM_FIRST_OBJECT) ||
        !rd_u32(manager + OM_LINK_BASE, &linkBase) || linkBase != 0x38u) {
        overlay_hide();
        g_cache_age_frames = 0xFFFFFFFFu;
        return;
    }
    g_next_offset = linkBase + 4u;

    if (!rd_u32(manager + OM_LOCAL_GUID_LO, &guidLo) ||
        !rd_u32(manager + OM_LOCAL_GUID_HI, &guidHi) ||
        (guidLo == 0u && guidHi == 0u)) {
        overlay_hide();
        g_cache_age_frames = 0xFFFFFFFFu;
        return;
    }

    localObj = g_cached_local_obj;
    if (guidLo != g_cached_local_guid_lo || guidHi != g_cached_local_guid_hi ||
        !cached_object_matches(localObj, guidLo, guidHi)) {
        lx = ly = lz = 0.0f;
        if (!find_local_player(manager, guidLo, guidHi, &localObj, &lx, &ly, &lz, &dummyCount, &reason)) {
            overlay_hide();
            g_cache_age_frames = 0xFFFFFFFFu;
            return;
        }
        needRefresh = TRUE;
    } else {
        if (!rd_f32(localObj + OBJ_POS_X, &lx) || !rd_f32(localObj + OBJ_POS_Y, &ly) || !rd_f32(localObj + OBJ_POS_Z, &lz)) {
            overlay_hide();
            g_cache_age_frames = 0xFFFFFFFFu;
            return;
        }
    }

    if (g_cache_age_frames == 0xFFFFFFFFu || g_cache_age_frames >= CACHE_REFRESH_FRAMES || needRefresh) {
        refresh_esp_cache(manager, localObj, guidLo, guidHi, lx, ly, lz);
    }

    range_sweep_tick(manager, localObj, guidLo, guidHi, lx, ly, lz);

    if (!init_projection_context(&projCtx, &projReason) || !projCtx.ready) {
        overlay_hide();
        return;
    }
    if (!game_client_screen_rect(projCtx.hwnd, &screenLeft, &screenTop, &width, &height)) {
        overlay_hide();
        return;
    }
    if (GetForegroundWindow() != projCtx.hwnd) {
        g_click_hit_count = 0u;
        overlay_hide();
        return;
    }
    if (!ensure_game_click_hook(projCtx.hwnd)) {
        g_click_hit_count = 0u;
    }
    if (!ensure_label_backbuffer(projCtx.hwnd)) {
        overlay_hide();
        return;
    }

    SetBkMode(g_label_memdc, TRANSPARENT_BK);
    g_click_hit_count = 0u;

    for (i = 0u; i < g_esp_cache_count && drawn < MAX_ESP_PLAYERS; ++i) {
        struct EspCacheEntry* e = &g_esp_cache[i];
        LONG absX, absY;
        {
            DWORD hpNow = e->health;
            DWORD maxHpNow = e->maxHealth;
            DWORD ageFrames = g_render_frame - e->lastSeenFrame;
            DWORD ageSec = (ageFrames * RENDER_INTERVAL_MS) / 1000u;
            BOOL liveObject = FALSE;

            x = e->x; y = e->y; z = e->z;

            if (e->source != SOURCE_STALE_CACHE && e->obj &&
                cached_object_matches(e->obj, e->guidLo, e->guidHi) &&
                rd_u32(e->obj + OBJ_GUID_LO, &loCheck) && rd_u32(e->obj + OBJ_GUID_HI, &hiCheck) &&
                loCheck == e->guidLo && hiCheck == e->guidHi &&
                rd_f32(e->obj + OBJ_POS_X, &x) && rd_f32(e->obj + OBJ_POS_Y, &y) && rd_f32(e->obj + OBJ_POS_Z, &z)) {
                liveObject = TRUE;
                if (read_unit_meta(e->obj, &meta)) {
                    hpNow = meta.health;
                    maxHpNow = meta.maxHealth;
                    e->health = hpNow;
                    e->maxHealth = maxHpNow;
                    e->x = x; e->y = y; e->z = z;
                }
            }

            dx = x - lx; dy = y - ly; dz = z - lz;
            d2 = dx*dx + dy*dy + dz*dz;
            d = sqrt_local(d2);
            if (d2 > g_max_hostile_distance_sq) g_max_hostile_distance_sq = d2;

            if (project_world(&projCtx, x, y, z + HOSTILE_HEAD_Z, &proj) && proj.nativeOk) {
            projected++;
            if (proj.onScreen) {
                absX = screenLeft + (LONG)proj.screenX - (LABEL_W / 2);
                absY = screenTop + (LONG)proj.screenY - LABEL_TOP_PAD;
                if (!ensure_label_window(drawn, absX, absY)) continue;

                {
                    DWORD ydNow = (DWORD)(d + 0.5f);
                    if (label_content_changed(drawn, e->guidLo, e->guidHi, hpNow, maxHpNow, ydNow, e->pvpEnabled, e->source, ageSec)) {
                        clear_label_pixels();
                        draw_esp_label(g_label_memdc, e->name, hpNow, maxHpNow, d, e->pvpEnabled, e->source, ageSec);
                        finalize_label_alpha();
                        if (!update_label_alpha(g_labels[drawn].hwnd, absX, absY)) {
                            g_labels[drawn].contentValid = FALSE;
                            continue;
                        }
                    }
                    if (!g_labels[drawn].visible) {
                        ShowWindow(g_labels[drawn].hwnd, SW_SHOWNOACTIVATE);
                        g_labels[drawn].visible = TRUE;
                    }
                    if (liveObject && drawn < MAX_ESP_PLAYERS) {
                        g_click_hits[g_click_hit_count].left = (LONG)proj.screenX - (LABEL_W / 2);
                        g_click_hits[g_click_hit_count].top = (LONG)proj.screenY - LABEL_TOP_PAD;
                        g_click_hits[g_click_hit_count].right = g_click_hits[g_click_hit_count].left + LABEL_W;
                        g_click_hits[g_click_hit_count].bottom = g_click_hits[g_click_hit_count].top + LABEL_H;
                        g_click_hits[g_click_hit_count].guidLo = e->guidLo;
                        g_click_hits[g_click_hit_count].guidHi = e->guidHi;
                        g_click_hit_count++;
                    }
                    drawn++;
                }
            }
        }
    }
    }

    hide_unused_labels(drawn);

    if ((g_render_frame % DIAG_EVERY_FRAMES) == 0u) {
        log_render_summary(g_esp_cache_count, g_esp_cache_count, projected, drawn, width, height);
        FlushFileBuffers(g_log);
    }
}

static void run_snapshot(void) {
    DWORD manager, guidLo, guidHi, localObj = 0u, count = 0u, linkBase = 0u;
    float lx = 0.0f, ly = 0.0f, lz = 0.0f;
    const char* reason = "UNKNOWN";
    DWORD obj, next, type, lo, hi, visited = 0u, players = 0u, otherTypes = 0u;
    DWORD typeCounts[8] = {0u,0u,0u,0u,0u,0u,0u,0u};
    float x, y, z, dx, dy, dz, d2, d;
    struct UnitMeta meta;
    char pname[MAX_PLAYER_NAME + 1u];
    DWORD nameNodes = 0u;
    const char* nameReason = "UNKNOWN";
    BOOL nameFound = FALSE;
    struct ProjectionContext projCtx;
    struct ProjectionResult proj;
    const char* projReason = "UNKNOWN";
    BOOL projReady = FALSE;
    char b[256]; char* p;

    log_line("SCAN_BEGIN");

    if (!rd_u32(OBJMGR_GLOBAL, &manager)) {
        log_scan_end("OBJMGR_GLOBAL_UNREADABLE", 0u);
        return;
    }
    /* Object Manager itself is not a world object: validate only its address/ranges. */
    if (manager < 0x00010000u || manager > 0x7FFF0000u ||
        !readable4(manager + OM_FIRST_OBJECT) ||
        !readable4(manager + OM_LOCAL_GUID_LO) ||
        !readable4(manager + OM_LOCAL_GUID_HI)) {
        p = b; p = app_str(p, "OBJMGR_BAD manager=0x"); p = app_hex8(p, manager); *p = 0; log_line(b);
        log_scan_end("BAD_MANAGER", 0u);
        return;
    }
    if (!rd_u32(manager + OM_LINK_BASE, &linkBase)) {
        log_scan_end("OM_LINK_BASE_UNREADABLE", 0u);
        return;
    }
    if (linkBase != 0x38u) {
        p = b;
        p = app_str(p, "OM_LAYOUT_MISMATCH manager=0x"); p = app_hex8(p, manager);
        p = app_str(p, " link_base=0x"); p = app_hex8(p, linkBase);
        p = app_str(p, " expected=0x00000038");
        *p = 0; log_line(b);
        log_scan_end("OM_LINK_BASE_UNEXPECTED", 0u);
        return;
    }
    g_next_offset = linkBase + 4u;
    if (g_next_offset != OBJ_NEXT_EXPECTED) {
        log_scan_end("OM_NEXT_OFFSET_UNEXPECTED", 0u);
        return;
    }
    if (!g_layout_logged) {
        p = b;
        p = app_str(p, "OM_LAYOUT_OK manager=0x"); p = app_hex8(p, manager);
        p = app_str(p, " link_base=0x"); p = app_hex8(p, linkBase);
        p = app_str(p, " first=0x000000AC next=0x"); p = app_hex8(p, g_next_offset);
        p = app_str(p, " local_guid=0x000000C0/0x000000C4");
        *p = 0; log_line(b);
        g_layout_logged = TRUE;
    }

    if (!g_name_cache_logged) {
        DWORD head = 0u;
        p = b;
        p = app_str(p, "NAME_CACHE_HEAD addr=0x"); p = app_hex8(p, PLAYER_NAME_CACHE_HEAD);
        if (rd_u32(PLAYER_NAME_CACHE_HEAD, &head)) {
            p = app_str(p, " first=0x"); p = app_hex8(p, head);
        } else {
            p = app_str(p, " first=<unreadable>");
        }
        *p = 0; log_line(b);
        g_name_cache_logged = TRUE;
    }

    if (!rd_u32(manager + OM_LOCAL_GUID_LO, &guidLo) || !rd_u32(manager + OM_LOCAL_GUID_HI, &guidHi)) {
        log_scan_end("LOCAL_GUID_UNREADABLE", 0u);
        return;
    }
if (!find_local_player(manager, guidLo, guidHi, &localObj, &lx, &ly, &lz, &count, &reason)) {
        p = b;
        p = app_str(p, "LOCAL_NOT_FOUND manager=0x"); p = app_hex8(p, manager);
        p = app_str(p, " guid=0x"); p = app_hex8(p, guidHi); p = app_hex8(p, guidLo);
        p = app_str(p, " reason="); p = app_str(p, reason);
        *p = 0; log_line(b);
        log_scan_end(reason, count);
        return;
    }

    p = b;
    p = app_str(p, "LOCAL ptr=0x"); p = app_hex8(p, localObj);
    p = app_str(p, " guid=0x"); p = app_hex8(p, guidHi); p = app_hex8(p, guidLo);
    p = app_str(p, " x="); p = app_float2(p, lx);
    p = app_str(p, " y="); p = app_float2(p, ly);
    p = app_str(p, " z="); p = app_float2(p, lz);
    *p = 0; log_line(b);

    if (read_unit_meta(localObj, &meta)) {
        log_meta("LOCAL_META", localObj, guidLo, guidHi, &meta);
    } else {
        p = b; p = app_str(p, "LOCAL_META_UNREADABLE ptr=0x"); p = app_hex8(p, localObj); *p = 0; log_line(b);
    }

    pname[0] = 0; nameNodes = 0u; nameReason = "UNKNOWN";
    nameFound = lookup_player_name(guidLo, guidHi, pname, &nameNodes, &nameReason);
    log_name("LOCAL_NAME", localObj, guidLo, guidHi, pname, nameFound, nameNodes, nameReason);

    projReady = init_projection_context(&projCtx, &projReason);
    log_projection_context(&projCtx, projReason);
    if (projReady && project_world(&projCtx, lx, ly, lz, &proj)) {
        log_projection("LOCAL_W2S", localObj, guidLo, guidHi, lx, ly, lz, &proj);
    } else {
        p = b; p = app_str(p, "LOCAL_W2S_SKIPPED ptr=0x"); p = app_hex8(p, localObj);
        p = app_str(p, " reason="); p = app_str(p, projReason); *p = 0; log_line(b);
    }

    if (!rd_u32(manager + OM_FIRST_OBJECT, &obj)) {
        log_scan_end("FIRST_OBJECT_UNREADABLE_2", 0u);
        return;
    }
    visited = 0u;
    while (visited < MAX_OBJECTS) {
        if (obj == 0u) { reason = "NULL"; break; }
        if ((obj & 1u) != 0u) { reason = "ODD_SENTINEL"; break; }
        if (!object_ptr_sane(obj)) { reason = "BAD_OBJECT_PTR"; break; }
        if (seen_before(obj, visited)) { reason = "CYCLE"; break; }
        g_visited[visited++] = obj;

        if (!rd_u32(obj + OBJ_TYPE, &type)) { reason = "TYPE_UNREADABLE"; break; }
        if (type < 8u) typeCounts[type]++; else otherTypes++;
        if (type == TYPEID_PLAYER) {
            if (rd_u32(obj + OBJ_GUID_LO, &lo) && rd_u32(obj + OBJ_GUID_HI, &hi)) {
                if (!(lo == guidLo && hi == guidHi)) {
                    if (rd_f32(obj + OBJ_POS_X, &x) && rd_f32(obj + OBJ_POS_Y, &y) && rd_f32(obj + OBJ_POS_Z, &z)) {
                        dx = x - lx; dy = y - ly; dz = z - lz;
                        d2 = dx*dx + dy*dy + dz*dz;
                        d = sqrt_local(d2);
                        log_player(obj, lo, hi, x, y, z, d);
                        if (read_unit_meta(obj, &meta)) {
                            log_meta("PLAYER_META", obj, lo, hi, &meta);
                        } else {
                            p = b; p = app_str(p, "PLAYER_META_UNREADABLE ptr=0x"); p = app_hex8(p, obj); *p = 0; log_line(b);
                        }
                        pname[0] = 0; nameNodes = 0u; nameReason = "UNKNOWN";
                        nameFound = lookup_player_name(lo, hi, pname, &nameNodes, &nameReason);
                        log_name("PLAYER_NAME", obj, lo, hi, pname, nameFound, nameNodes, nameReason);

                        /* Re-check both objects immediately before entering native client relation code. */
                        if (object_ptr_sane(localObj) && object_ptr_sane(obj)) {
                            int reaction = native_unit_reaction(localObj, obj);
                            BYTE canAttack = native_can_attack(localObj, obj);
                            BYTE pvpEnabled = native_unit_is_pvp(obj);
                            log_relation(obj, lo, hi, reaction, canAttack, pvpEnabled);
                        } else {
                            p = b; p = app_str(p, "PLAYER_RELATION_SKIPPED ptr=0x"); p = app_hex8(p, obj);
                            p = app_str(p, " reason=OBJECT_CHANGED"); *p = 0; log_line(b);
                        }
                        if (projReady && project_world(&projCtx, x, y, z, &proj)) {
                            log_projection("PLAYER_W2S", obj, lo, hi, x, y, z, &proj);
                        } else {
                            p = b; p = app_str(p, "PLAYER_W2S_SKIPPED ptr=0x"); p = app_hex8(p, obj);
                            p = app_str(p, " reason="); p = app_str(p, projReason); *p = 0; log_line(b);
                        }
                        players++;
                        if (d2 > g_max_distance_sq) {
                            g_max_distance_sq = d2;
                            log_max_distance(obj, lo, hi, d);
                        }
                    } else {
                        p = b; p = app_str(p, "PLAYER_POS_UNREADABLE ptr=0x"); p = app_hex8(p, obj); *p = 0; log_line(b);
                    }
                }
            }
        }

        if (!rd_u32(obj + g_next_offset, &next)) { reason = "NEXT_UNREADABLE"; break; }
        if (next == obj) { reason = "SELF_LOOP"; break; }
        if (next == manager) { reason = "MANAGER_SENTINEL"; break; }
        obj = next;
    }
    if (visited >= MAX_OBJECTS) reason = "MAX_OBJECTS";

    p = b;
    p = app_str(p, "TYPE_SUMMARY none="); p = app_u32(p, typeCounts[0]);
    p = app_str(p, " item="); p = app_u32(p, typeCounts[1]);
    p = app_str(p, " container="); p = app_u32(p, typeCounts[2]);
    p = app_str(p, " unit="); p = app_u32(p, typeCounts[3]);
    p = app_str(p, " player="); p = app_u32(p, typeCounts[4]);
    p = app_str(p, " gameobject="); p = app_u32(p, typeCounts[5]);
    p = app_str(p, " dynamic="); p = app_u32(p, typeCounts[6]);
    p = app_str(p, " corpse="); p = app_u32(p, typeCounts[7]);
    p = app_str(p, " other="); p = app_u32(p, otherTypes);
    *p = 0; log_line(b);

    p = b;
    p = app_str(p, "SCAN_SUMMARY objects="); p = app_u32(p, visited);
    p = app_str(p, " remote_players="); p = app_u32(p, players);
    *p = 0; log_line(b);
    log_scan_end(reason, visited);
    FlushFileBuffers(g_log);
}

static DWORD WINAPI WorkerThread(LPVOID ignored) {
    char path[260];
    (void)ignored;
    build_log_path(path);
    g_log = CreateFileA(path, GENERIC_WRITE, FILE_SHARE_READ, NULL, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (g_log == INVALID_HANDLE_VALUE) return 0u;
    SetFilePointer(g_log, 0, NULL, FILE_END);
    log_line("LOAD WoWPlayerESP v1.2 range_sweep");
    log_line("TARGET WoW 1.12.1 build 5875 x86");
    log_line("PHASE 12: client-only active visibility sweep + GUID history cache + GetPtrForGuid retention + PvP + click-to-target");
    log_line("EXPECTED_SHA256 97ea82ab7a82ed88bc5a155ab9bbf7e0bcdb5b9f892a47c6f8edabe1496bfc75");
    if (!validate_exact_build()) {
        log_line("BUILD_SIGNATURE_FAIL - refusing to scan unknown/modified executable");
        FlushFileBuffers(g_log);
        CloseHandle(g_log);
        g_log = INVALID_HANDLE_VALUE;
        return 0u;
    }
    log_line("BUILD_SIGNATURE_OK enum=0x00468380 getptr_core=0x00464870 active_guid=0x00468550 reaction=0x006061E0 can_attack=0x00606980 unit_is_pvp=0x00605FF0 w2s=0x00483EE0 ddc=0x0041ADE0 hwnd=0x00435C30 camera=0x004818F0 target=0x00489A40");
    log_line("RANGE_CACHE_OK ttl_seconds=29 getptr_fallback=1 stale_labels=1 stale_click=0 passive_capture=1");
    log_line("RANGE_SWEEP_READY default=OFF hotkey=F8 radius=120 points=8 dwell_ms=264 rest_ms=11880 stand_still=1");
    FlushFileBuffers(g_log);

    while (!g_stop) {
        render_frame_fast();
        Sleep(RENDER_INTERVAL_MS);
    }

    remove_game_click_hook();
    destroy_overlay();
    log_line("UNLOAD WoWPlayerESP v1.2 range_sweep");
    FlushFileBuffers(g_log);
    CloseHandle(g_log);
    g_log = INVALID_HANDLE_VALUE;
    return 0u;
}

BOOL WINAPI DllMain(HMODULE hinst, DWORD reason, LPVOID reserved) {
    HANDLE th;
    (void)reserved;
    if (reason == DLL_PROCESS_ATTACH) {
        g_self = hinst;
        g_stop = 0;
        DisableThreadLibraryCalls(hinst);
        th = CreateThread(NULL, 0u, WorkerThread, NULL, 0u, NULL);
        if (th) CloseHandle(th);
    } else if (reason == DLL_PROCESS_DETACH) {
        g_stop = 1;
    }
    return TRUE;
}