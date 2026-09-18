/*
 * WoWControlHub_v2.c
 * Central runtime GUI/config + health hub for World of Warcraft 1.12.1
 * build 5875, Windows x86.
 *
 * V2 goals:
 *   - keep the generic W112_CONTROL_API_V1 provider model;
 *   - use Insert directly in canonical source (no post-build hotkey patch);
 *   - page across more than four modules and more than four settings;
 *   - expose a compact Runtime Health section using already-existing,
 *     read-only diagnostic exports from active modules;
 *   - add keyboard-first navigation, precise +/- controls and one-click
 *     per-setting restore-to-default without changing provider ABI;
 *   - preserve the V1 Win32 layered-overlay / game-WndProc architecture.
 */

#if !defined(_M_IX86) && !defined(__i386__)
#error WoWControlHub is for 32-bit x86 only.
#endif

#include "../common/W112ControlAPI.h"

#define NULL ((void*)0)
typedef unsigned char BYTE;
typedef unsigned short WORD;
typedef unsigned int DWORD;
typedef signed int LONG;
typedef unsigned int UINT;
typedef unsigned int SIZE_T;
typedef void* HANDLE;
typedef void* HMODULE;
typedef void* HWND;
typedef void* HDC;
typedef void* HGDIOBJ;
typedef void* HBITMAP;
typedef void* LPVOID;
typedef const char* LPCSTR;
typedef unsigned int COLORREF;

#define WINAPI __stdcall
#define TRUE 1
#define FALSE 0
#define DLL_PROCESS_DETACH 0u
#define DLL_PROCESS_ATTACH 1u
#define INVALID_HANDLE_VALUE ((HANDLE)(-1))

typedef LONG (WINAPI *WNDPROC32)(HWND, UINT, DWORD, LONG);
typedef HWND (__fastcall *GetGameWindowFn)(int which);
typedef DWORD (WINAPI *GetU32Fn)(void);

#define FN_GET_GAME_WINDOW 0x00435C30u
#define WM_KEYDOWN         0x0100u
#define WM_LBUTTONDOWN     0x0201u
#define VK_RETURN          0x0Du
#define VK_TAB             0x09u
#define VK_SPACE           0x20u
#define VK_PRIOR           0x21u
#define VK_NEXT            0x22u
#define VK_LEFT            0x25u
#define VK_UP              0x26u
#define VK_RIGHT           0x27u
#define VK_DOWN            0x28u
#define VK_INSERT          0x2Du
#define VK_R               0x52u
#define GWL_WNDPROC        (-4)
#define PM_REMOVE          0x0001u

#define WS_POPUP           0x80000000u
#define WS_EX_TOPMOST      0x00000008u
#define WS_EX_TRANSPARENT  0x00000020u
#define WS_EX_TOOLWINDOW   0x00000080u
#define WS_EX_LAYERED      0x00080000u
#define WS_EX_NOACTIVATE   0x08000000u
#define SW_HIDE            0
#define SW_SHOWNOACTIVATE  4
#define SWP_NOACTIVATE     0x0010u
#define SWP_SHOWWINDOW     0x0040u
#define ULW_ALPHA          0x00000002u
#define AC_SRC_OVER        0x00u
#define AC_SRC_ALPHA       0x01u
#define BI_RGB             0u
#define DIB_RGB_COLORS     0u
#define TRANSPARENT_BK     1
#define DEFAULT_GUI_FONT_ID 17

#define TH32CS_SNAPMODULE   0x00000008u
#define TH32CS_SNAPMODULE32 0x00000010u

#define PANEL_W 620
#define PANEL_H 470
#define PANEL_X 20
#define PANEL_Y 20
#define HEADER_H 30

#define MOD_NAV_Y 34
#define MOD_NAV_H 27
#define MOD_PREV_X 12
#define MOD_NEXT_X 576
#define MOD_NAV_W 32
#define TAB_X 50
#define TAB_W 128
#define TAB_GAP 4
#define MODULES_PER_PAGE 4u

#define ROW_Y 72
#define ROW_H 42
#define SETTINGS_PER_PAGE 5u
#define SETTING_NAV_Y 286
#define SETTING_NAV_H 24

#define VALUE_X 300
#define STEP_MINUS_X 390
#define STEP_PLUS_X 544
#define STEP_W 24
#define RESET_X 574
#define RESET_W 34
#define SLIDER_X 420
#define SLIDER_W 118
#define SLIDER_YOFF 25

#define HEALTH_Y 342
#define HEALTH_ROW_H 18

#define MAX_MODULES 32u
#define DISCOVERY_MS 1000u
#define FRAME_MS 50u

#define COLOR_BG        0x00202020u
#define COLOR_HEADER    0x00303030u
#define COLOR_PANEL     0x00282828u
#define COLOR_SELECTED  0x00343434u
#define COLOR_BORDER    0x00606060u
#define COLOR_TAB       0x00383838u
#define COLOR_TAB_ON    0x00505050u
#define COLOR_TEXT      0x00FFFFFFu
#define COLOR_MUTED     0x00B0B0B0u
#define COLOR_ACCENT    0x00D0D0D0u
#define COLOR_TRACK     0x00505050u
#define COLOR_FILL      0x00C0C0C0u

struct RECT32 { LONG left; LONG top; LONG right; LONG bottom; };
struct POINT32 { LONG x; LONG y; };
struct SIZE32 { LONG cx; LONG cy; };
struct BITMAPINFOHEADER32 {
    DWORD biSize; LONG biWidth; LONG biHeight; WORD biPlanes; WORD biBitCount;
    DWORD biCompression; DWORD biSizeImage; LONG biXPelsPerMeter; LONG biYPelsPerMeter;
    DWORD biClrUsed; DWORD biClrImportant;
};
struct BITMAPINFO32 { struct BITMAPINFOHEADER32 bmiHeader; DWORD bmiColors[1]; };
struct BLENDFUNCTION32 { BYTE BlendOp; BYTE BlendFlags; BYTE SourceConstantAlpha; BYTE AlphaFormat; };
struct MSG32 { HWND hwnd; UINT message; DWORD wParam; LONG lParam; DWORD time; struct POINT32 pt; };

struct MODULEENTRY32A_LOCAL {
    DWORD dwSize;
    DWORD th32ModuleID;
    DWORD th32ProcessID;
    DWORD GlblcntUsage;
    DWORD ProccntUsage;
    BYTE *modBaseAddr;
    DWORD modBaseSize;
    HMODULE hModule;
    char szModule[256];
    char szExePath[260];
};

struct HubModule {
    HMODULE handle;
    const W112_ControlModuleV1 *api;
};

struct RuntimeHealth {
    DWORD providerCount;
    DWORD speedPresent;
    DWORD speedStatus;
    DWORD speedApplyCount;
    DWORD stealthPresent;
    DWORD stealthStatus;
    DWORD stealthLost;
    DWORD stealthRepairs;
    DWORD movementPresent;
    DWORD movementAltInstalled;
    DWORD movementAltStarts;
    DWORD movementPPBlocks;
    DWORD autoPoisonsPresent;
    DWORD autoPoisonsStatus;
    DWORD autoPoisonsTicks;
};

__declspec(dllimport) HANDLE WINAPI CreateThread(LPVOID, SIZE_T, DWORD (WINAPI *)(LPVOID), LPVOID, DWORD, DWORD*);
__declspec(dllimport) void   WINAPI Sleep(DWORD);
__declspec(dllimport) BOOL   WINAPI CloseHandle(HANDLE);
__declspec(dllimport) BOOL   WINAPI DisableThreadLibraryCalls(HMODULE);
__declspec(dllimport) DWORD  WINAPI GetCurrentProcessId(void);
__declspec(dllimport) HANDLE WINAPI CreateToolhelp32Snapshot(DWORD, DWORD);
__declspec(dllimport) BOOL   WINAPI Module32First(HANDLE, struct MODULEENTRY32A_LOCAL*);
__declspec(dllimport) BOOL   WINAPI Module32Next(HANDLE, struct MODULEENTRY32A_LOCAL*);
__declspec(dllimport) LPVOID WINAPI GetProcAddress(HMODULE, LPCSTR);

__declspec(dllimport) BOOL   WINAPI GetClientRect(HWND, struct RECT32*);
__declspec(dllimport) BOOL   WINAPI ClientToScreen(HWND, struct POINT32*);
__declspec(dllimport) HWND   WINAPI GetForegroundWindow(void);
__declspec(dllimport) BOOL   WINAPI IsWindow(HWND);
__declspec(dllimport) HWND   WINAPI CreateWindowExA(DWORD, LPCSTR, LPCSTR, DWORD, int, int, int, int, HWND, HANDLE, HMODULE, LPVOID);
__declspec(dllimport) BOOL   WINAPI DestroyWindow(HWND);
__declspec(dllimport) BOOL   WINAPI ShowWindow(HWND, int);
__declspec(dllimport) BOOL   WINAPI SetWindowPos(HWND, HWND, int, int, int, int, UINT);
__declspec(dllimport) BOOL   WINAPI UpdateLayeredWindow(HWND, HDC, struct POINT32*, struct SIZE32*, HDC, struct POINT32*, COLORREF, struct BLENDFUNCTION32*, DWORD);
__declspec(dllimport) LONG   WINAPI SetWindowLongA(HWND, int, LONG);
__declspec(dllimport) LONG   WINAPI GetWindowLongA(HWND, int);
__declspec(dllimport) LONG   WINAPI CallWindowProcA(WNDPROC32, HWND, UINT, DWORD, LONG);
__declspec(dllimport) BOOL   WINAPI PeekMessageA(struct MSG32*, HWND, UINT, UINT, UINT);
__declspec(dllimport) BOOL   WINAPI TranslateMessage(const struct MSG32*);
__declspec(dllimport) LONG   WINAPI DispatchMessageA(const struct MSG32*);

__declspec(dllimport) HDC      WINAPI GetDC(HWND);
__declspec(dllimport) int      WINAPI ReleaseDC(HWND, HDC);
__declspec(dllimport) HDC      WINAPI CreateCompatibleDC(HDC);
__declspec(dllimport) BOOL     WINAPI DeleteDC(HDC);
__declspec(dllimport) HBITMAP  WINAPI CreateDIBSection(HDC, const struct BITMAPINFO32*, UINT, void**, HANDLE, DWORD);
__declspec(dllimport) HGDIOBJ  WINAPI SelectObject(HDC, HGDIOBJ);
__declspec(dllimport) BOOL     WINAPI DeleteObject(HGDIOBJ);
__declspec(dllimport) int      WINAPI SetBkMode(HDC, int);
__declspec(dllimport) COLORREF WINAPI SetTextColor(HDC, COLORREF);
__declspec(dllimport) BOOL     WINAPI TextOutA(HDC, int, int, LPCSTR, int);
__declspec(dllimport) HGDIOBJ  WINAPI GetStockObject(int);

int _fltused = 0;

static volatile LONG g_stop = 0;
static HMODULE g_self = NULL;
static HWND g_gameHwnd = NULL;
static WNDPROC32 g_oldWndProc = NULL;
static HWND g_overlayHwnd = NULL;
static HDC g_memdc = NULL;
static HBITMAP g_bitmap = NULL;
static HGDIOBJ g_oldBitmap = NULL;
static DWORD *g_pixels = NULL;
static volatile DWORD g_visible = 0u;

static struct HubModule g_modules[MAX_MODULES];
static DWORD g_moduleCount = 0u;
static DWORD g_selectedModule = 0u;
static DWORD g_selectedSetting = 0u;
static DWORD g_modulePage = 0u;
static DWORD g_settingPage = 0u;
static DWORD g_lastDiscoveryTick = 0u;
static struct RuntimeHealth g_health;

static LONG WINAPI hub_game_wndproc(HWND hwnd, UINT msg, DWORD wParam, LONG lParam);

static DWORD cstr_len(const char *s)
{
    DWORD n = 0u;
    while (s && s[n]) ++n;
    return n;
}

static char *app_str(char *p, const char *s)
{
    if (!s) return p;
    while (*s) *p++ = *s++;
    return p;
}

static char *app_u32(char *p, DWORD value)
{
    char tmp[16];
    int n = 0;
    if (value == 0u) { *p++ = '0'; return p; }
    while (value && n < 15) {
        tmp[n++] = (char)('0' + (value % 10u));
        value /= 10u;
    }
    while (n > 0) *p++ = tmp[--n];
    return p;
}

static char *app_i32(char *p, LONG value)
{
    if (value < 0) { *p++ = '-'; value = -value; }
    return app_u32(p, (DWORD)value);
}

static char *app_hex32(char *p, DWORD value)
{
    static const char hex[] = "0123456789ABCDEF";
    int shift;
    *p++ = '0';
    *p++ = 'x';
    for (shift = 28; shift >= 0; shift -= 4)
        *p++ = hex[(value >> shift) & 0xFu];
    return p;
}

static char *app_float1(char *p, float value)
{
    DWORD ip, fp;
    if (value < 0.0f) { *p++ = '-'; value = -value; }
    if (value > 9999.0f) return app_str(p, "9999+");
    ip = (DWORD)value;
    fp = (DWORD)((value - (float)ip) * 10.0f + 0.5f);
    if (fp >= 10u) { ++ip; fp = 0u; }
    p = app_u32(p, ip);
    *p++ = '.';
    *p++ = (char)('0' + fp);
    return p;
}

static void clear_pixels(DWORD rgb)
{
    DWORD i;
    if (!g_pixels) return;
    for (i = 0u; i < (DWORD)(PANEL_W * PANEL_H); ++i) g_pixels[i] = rgb;
}

static void fill_rect(int x, int y, int w, int h, DWORD rgb)
{
    int yy, xx;
    if (!g_pixels || w <= 0 || h <= 0) return;
    if (x < 0) { w += x; x = 0; }
    if (y < 0) { h += y; y = 0; }
    if (x + w > PANEL_W) w = PANEL_W - x;
    if (y + h > PANEL_H) h = PANEL_H - y;
    if (w <= 0 || h <= 0) return;
    for (yy = y; yy < y + h; ++yy)
        for (xx = x; xx < x + w; ++xx)
            g_pixels[yy * PANEL_W + xx] = rgb;
}

static void frame_rect(int x, int y, int w, int h, DWORD rgb)
{
    fill_rect(x, y, w, 1, rgb);
    fill_rect(x, y + h - 1, w, 1, rgb);
    fill_rect(x, y, 1, h, rgb);
    fill_rect(x + w - 1, y, 1, h, rgb);
}

static void finalize_alpha(void)
{
    DWORD i;
    if (!g_pixels) return;
    for (i = 0u; i < (DWORD)(PANEL_W * PANEL_H); ++i) {
        DWORD rgb = g_pixels[i] & 0x00FFFFFFu;
        g_pixels[i] = rgb ? (rgb | 0xFF000000u) : 0u;
    }
}

static void draw_text(int x, int y, const char *text, COLORREF color)
{
    if (!g_memdc || !text) return;
    SetBkMode(g_memdc, TRANSPARENT_BK);
    SetTextColor(g_memdc, color);
    TextOutA(g_memdc, x, y, text, (int)cstr_len(text));
}

static void draw_button(int x, int y, int w, int h, const char *label, BOOL active)
{
    fill_rect(x, y, w, h, active ? COLOR_TAB_ON : COLOR_TAB);
    frame_rect(x, y, w, h, COLOR_BORDER);
    draw_text(x + 9, y + 6, label, active ? COLOR_TEXT : COLOR_MUTED);
}

static BOOL wow_game_window_signature_ok(void)
{
    static const BYTE sig[] = {
        0x83,0xE9,0x00,0x74,0x15,0x49,0x74,0x0C,0x49,0x74,0x03,0x33,0xC0,0xC3
    };
    DWORD i;
    volatile BYTE *p = (volatile BYTE *)(DWORD)FN_GET_GAME_WINDOW;
    for (i = 0u; i < (DWORD)sizeof(sig); ++i)
        if (p[i] != sig[i]) return FALSE;
    return TRUE;
}

static HWND get_game_window(void)
{
    GetGameWindowFn fn;
    if (!wow_game_window_signature_ok()) return NULL;
    fn = (GetGameWindowFn)(DWORD)FN_GET_GAME_WINDOW;
    return fn(0);
}

static void pump_messages(void)
{
    struct MSG32 msg;
    while (PeekMessageA(&msg, NULL, 0u, 0u, PM_REMOVE)) {
        TranslateMessage(&msg);
        DispatchMessageA(&msg);
    }
}

static void destroy_backbuffer(void)
{
    if (g_memdc) {
        if (g_oldBitmap) SelectObject(g_memdc, g_oldBitmap);
        if (g_bitmap) DeleteObject((HGDIOBJ)g_bitmap);
        DeleteDC(g_memdc);
    }
    g_memdc = NULL;
    g_bitmap = NULL;
    g_oldBitmap = NULL;
    g_pixels = NULL;
}

static void destroy_overlay(void)
{
    destroy_backbuffer();
    if (g_overlayHwnd && IsWindow(g_overlayHwnd)) DestroyWindow(g_overlayHwnd);
    g_overlayHwnd = NULL;
}

static BOOL ensure_overlay(HWND gameHwnd)
{
    HDC dc;
    struct BITMAPINFO32 bmi;
    void *bits = NULL;
    DWORD exStyle;

    if (g_overlayHwnd && IsWindow(g_overlayHwnd) && g_memdc && g_bitmap && g_pixels)
        return TRUE;
    destroy_overlay();
    if (!gameHwnd) return FALSE;

    exStyle = WS_EX_TOPMOST | WS_EX_TRANSPARENT | WS_EX_TOOLWINDOW | WS_EX_LAYERED | WS_EX_NOACTIVATE;
    g_overlayHwnd = CreateWindowExA(exStyle, "STATIC", "", WS_POPUP,
                                    0, 0, PANEL_W, PANEL_H,
                                    NULL, NULL, g_self, NULL);
    if (!g_overlayHwnd) return FALSE;

    dc = GetDC(gameHwnd);
    if (!dc) { destroy_overlay(); return FALSE; }
    g_memdc = CreateCompatibleDC(dc);

    bmi.bmiHeader.biSize = (DWORD)sizeof(struct BITMAPINFOHEADER32);
    bmi.bmiHeader.biWidth = PANEL_W;
    bmi.bmiHeader.biHeight = -PANEL_H;
    bmi.bmiHeader.biPlanes = 1u;
    bmi.bmiHeader.biBitCount = 32u;
    bmi.bmiHeader.biCompression = BI_RGB;
    bmi.bmiHeader.biSizeImage = 0u;
    bmi.bmiHeader.biXPelsPerMeter = 0;
    bmi.bmiHeader.biYPelsPerMeter = 0;
    bmi.bmiHeader.biClrUsed = 0u;
    bmi.bmiHeader.biClrImportant = 0u;
    bmi.bmiColors[0] = 0u;

    if (g_memdc)
        g_bitmap = CreateDIBSection(dc, &bmi, DIB_RGB_COLORS, &bits, NULL, 0u);
    ReleaseDC(gameHwnd, dc);

    if (!g_memdc || !g_bitmap || !bits) {
        destroy_overlay();
        return FALSE;
    }
    g_pixels = (DWORD *)bits;
    g_oldBitmap = SelectObject(g_memdc, (HGDIOBJ)g_bitmap);
    SelectObject(g_memdc, GetStockObject(DEFAULT_GUI_FONT_ID));
    clear_pixels(COLOR_BG);
    return TRUE;
}

static LPVOID find_export0(HMODULE module, const char *plain, const char *decorated, const char *underscored)
{
    LPVOID p = GetProcAddress(module, plain);
    if (!p && decorated) p = GetProcAddress(module, decorated);
    if (!p && underscored) p = GetProcAddress(module, underscored);
    return p;
}

static W112_ControlGetModuleV1Fn find_provider_export(HMODULE module)
{
    return (W112_ControlGetModuleV1Fn)find_export0(
        module,
        "W112_Control_GetModuleV1",
        "_W112_Control_GetModuleV1@0",
        "_W112_Control_GetModuleV1");
}

static BOOL valid_module_api(const W112_ControlModuleV1 *api)
{
    if (!api) return FALSE;
    if (api->abi_version != W112_CONTROL_API_V1) return FALSE;
    if (api->struct_size < (w112_u32)sizeof(W112_ControlModuleV1)) return FALSE;
    if (!api->module_id || !api->module_name) return FALSE;
    if (api->setting_count > 128u) return FALSE;
    if (api->setting_count && !api->settings) return FALSE;
    if (!api->get_value || !api->set_value) return FALSE;
    return TRUE;
}

static void probe_health_exports(HMODULE module)
{
    GetU32Fn f;

    f = (GetU32Fn)find_export0(module, "SpeedFloor_GetStatus", "_SpeedFloor_GetStatus@0", "_SpeedFloor_GetStatus");
    if (f) {
        g_health.speedPresent = 1u;
        g_health.speedStatus = f();
        f = (GetU32Fn)find_export0(module, "SpeedFloor_GetApplyCount", "_SpeedFloor_GetApplyCount@0", "_SpeedFloor_GetApplyCount");
        if (f) g_health.speedApplyCount = f();
    }

    f = (GetU32Fn)find_export0(module, "StealthCDGuardian_GetStatus", "_StealthCDGuardian_GetStatus@0", "_StealthCDGuardian_GetStatus");
    if (f) {
        g_health.stealthPresent = 1u;
        g_health.stealthStatus = f();
        f = (GetU32Fn)find_export0(module, "StealthCDGuardian_GetHookLost", "_StealthCDGuardian_GetHookLost@0", "_StealthCDGuardian_GetHookLost");
        if (f) g_health.stealthLost = f();
        f = (GetU32Fn)find_export0(module, "StealthCDGuardian_GetHookRepairs", "_StealthCDGuardian_GetHookRepairs@0", "_StealthCDGuardian_GetHookRepairs");
        if (f) g_health.stealthRepairs = f();
    }

    f = (GetU32Fn)find_export0(module, "MovementCore_GetAltPriorityInstalled", "_MovementCore_GetAltPriorityInstalled@0", "_MovementCore_GetAltPriorityInstalled");
    if (f) {
        g_health.movementPresent = 1u;
        g_health.movementAltInstalled = f();
        f = (GetU32Fn)find_export0(module, "MovementCore_GetAltPriorityStarts", "_MovementCore_GetAltPriorityStarts@0", "_MovementCore_GetAltPriorityStarts");
        if (f) g_health.movementAltStarts = f();
        f = (GetU32Fn)find_export0(module, "MovementCore_GetAltPriorityPPBlocks", "_MovementCore_GetAltPriorityPPBlocks@0", "_MovementCore_GetAltPriorityPPBlocks");
        if (f) g_health.movementPPBlocks = f();
    }

    f = (GetU32Fn)find_export0(module, "AutoPoisons_GetStatus", "_AutoPoisons_GetStatus@0", "_AutoPoisons_GetStatus");
    if (f) {
        g_health.autoPoisonsPresent = 1u;
        g_health.autoPoisonsStatus = f();
        f = (GetU32Fn)find_export0(module, "AutoPoisons_GetTickCount", "_AutoPoisons_GetTickCount@0", "_AutoPoisons_GetTickCount");
        if (f) g_health.autoPoisonsTicks = f();
    }
}

static void normalize_pages(void)
{
    DWORD pages;
    DWORD settingCount = 0u;

    if (g_moduleCount == 0u) {
        g_selectedModule = 0u;
        g_selectedSetting = 0u;
        g_modulePage = 0u;
        g_settingPage = 0u;
        return;
    }

    if (g_selectedModule >= g_moduleCount) g_selectedModule = g_moduleCount - 1u;
    pages = (g_moduleCount + MODULES_PER_PAGE - 1u) / MODULES_PER_PAGE;
    if (g_modulePage >= pages) g_modulePage = pages - 1u;

    if (g_selectedModule < g_modulePage * MODULES_PER_PAGE ||
        g_selectedModule >= (g_modulePage + 1u) * MODULES_PER_PAGE)
        g_modulePage = g_selectedModule / MODULES_PER_PAGE;

    settingCount = g_modules[g_selectedModule].api->setting_count;
    if (settingCount == 0u) {
        g_selectedSetting = 0u;
        g_settingPage = 0u;
        return;
    }

    if (g_selectedSetting >= settingCount) g_selectedSetting = settingCount - 1u;
    pages = (settingCount + SETTINGS_PER_PAGE - 1u) / SETTINGS_PER_PAGE;
    if (g_settingPage >= pages) g_settingPage = pages - 1u;

    if (g_selectedSetting < g_settingPage * SETTINGS_PER_PAGE ||
        g_selectedSetting >= (g_settingPage + 1u) * SETTINGS_PER_PAGE)
        g_settingPage = g_selectedSetting / SETTINGS_PER_PAGE;
}

static void refresh_modules(void)
{
    HANDLE snap;
    struct MODULEENTRY32A_LOCAL me;
    DWORD count = 0u;
    W112_ControlGetModuleV1Fn getApi;
    const W112_ControlModuleV1 *api;

    g_health.providerCount = 0u;
    g_health.speedPresent = 0u;
    g_health.speedStatus = 0u;
    g_health.speedApplyCount = 0u;
    g_health.stealthPresent = 0u;
    g_health.stealthStatus = 0u;
    g_health.stealthLost = 0u;
    g_health.stealthRepairs = 0u;
    g_health.movementPresent = 0u;
    g_health.movementAltInstalled = 0u;
    g_health.movementAltStarts = 0u;
    g_health.movementPPBlocks = 0u;
    g_health.autoPoisonsPresent = 0u;
    g_health.autoPoisonsStatus = 0u;
    g_health.autoPoisonsTicks = 0u;

    snap = CreateToolhelp32Snapshot(TH32CS_SNAPMODULE | TH32CS_SNAPMODULE32, GetCurrentProcessId());
    if (snap == INVALID_HANDLE_VALUE) return;

    me.dwSize = (DWORD)sizeof(me);
    if (Module32First(snap, &me)) {
        do {
            probe_health_exports(me.hModule);

            getApi = find_provider_export(me.hModule);
            if (getApi) {
                api = getApi();
                if (valid_module_api(api) && count < MAX_MODULES) {
                    g_modules[count].handle = me.hModule;
                    g_modules[count].api = api;
                    ++count;
                }
            }
            me.dwSize = (DWORD)sizeof(me);
        } while (Module32Next(snap, &me));
    }
    CloseHandle(snap);

    g_moduleCount = count;
    g_health.providerCount = count;
    normalize_pages();
}

static const char *enum_label(const W112_ControlSettingV1 *s, LONG value)
{
    DWORD i;
    if (!s || !s->enum_options) return NULL;
    for (i = 0u; i < s->enum_option_count; ++i)
        if (s->enum_options[i].value == value) return s->enum_options[i].label;
    return NULL;
}

static BOOL value_is_default(const W112_ControlSettingV1 *s, const W112_ControlValueV1 *v)
{
    if (!s || !v) return FALSE;
    if (s->type == W112_CTL_FLOAT) return v->f32 == s->default_value.f32;
    if (s->type == W112_CTL_BOOL) return v->u32 == s->default_value.u32;
    return v->i32 == s->default_value.i32;
}

static void build_value_text(char out[96], const W112_ControlSettingV1 *s, const W112_ControlValueV1 *v)
{
    char *p = out;
    const char *label;
    if (!s || !v) { out[0] = 0; return; }

    if (s->type == W112_CTL_BOOL) {
        p = app_str(p, v->u32 ? "ON" : "OFF");
    } else if (s->type == W112_CTL_FLOAT) {
        p = app_float1(p, v->f32);
    } else if (s->type == W112_CTL_ENUM) {
        label = enum_label(s, v->i32);
        if (label) p = app_str(p, label);
        else p = app_i32(p, v->i32);
    } else {
        p = app_i32(p, v->i32);
    }

    if (s->flags & W112_CTL_REQUIRES_RELOAD) p = app_str(p, " RELOAD");
    else if (s->flags & W112_CTL_LIVE) p = app_str(p, " LIVE");
    if (s->flags & W112_CTL_READ_ONLY) p = app_str(p, " RO");
    if (!value_is_default(s, v)) p = app_str(p, " *");
    *p = 0;
}

static float normalized_value(const W112_ControlSettingV1 *s, const W112_ControlValueV1 *v)
{
    float minv, maxv, cur;
    if (!s || !v) return 0.0f;

    if (s->type == W112_CTL_FLOAT) {
        minv = s->min_value.f32;
        maxv = s->max_value.f32;
        cur = v->f32;
    } else {
        minv = (float)s->min_value.i32;
        maxv = (float)s->max_value.i32;
        cur = (float)v->i32;
    }

    if (!(maxv > minv)) return 0.0f;
    cur = (cur - minv) / (maxv - minv);
    if (cur < 0.0f) cur = 0.0f;
    if (cur > 1.0f) cur = 1.0f;
    return cur;
}

static const char *speed_status_text(DWORD s)
{
    if (s == 1u) return "ACTIVE";
    if (s == 0u) return "DETACHED";
    if (s == 2u) return "NO TIMER";
    if (s == 3u) return "TIMER FAIL";
    return "STATUS ?";
}

static const char *stealth_status_text(DWORD s)
{
    if (s == 1u) return "PROTECTED";
    if (s == 0u) return "OFF";
    if (s == 2u) return "INIT FAIL";
    if (s == 3u) return "HOOK UNSAFE";
    return "STATUS ?";
}

static const char *autopoisons_status_text(DWORD s)
{
    if (s == 0u) return "DETACHED";
    if (s == 1u) return "WAITING WORLD";
    if (s == 2u) return "ACTIVE";
    if (s == 3u) return "SCRIPT MISMATCH";
    if (s == 4u) return "BOOTSTRAP FAIL";
    if (s == 5u) return "NO TIMER";
    if (s == 6u) return "TIMER FAIL";
    return "STATUS ?";
}

static void draw_runtime_health(void)
{
    char b[180];
    char *p;
    int y = HEALTH_Y + 20;

    fill_rect(12, HEALTH_Y, PANEL_W - 24, PANEL_H - HEALTH_Y - 12, COLOR_PANEL);
    frame_rect(12, HEALTH_Y, PANEL_W - 24, PANEL_H - HEALTH_Y - 12, COLOR_BORDER);
    draw_text(20, HEALTH_Y + 5, "Runtime Health", COLOR_TEXT);

    p = b;
    p = app_str(p, "Control providers: ");
    p = app_u32(p, g_health.providerCount);
    p = app_str(p, "   Hub WndProc: ");
    p = app_str(p, (g_gameHwnd && g_oldWndProc) ? "ATTACHED" : "WAITING");
    *p = 0;
    draw_text(28, y, b, COLOR_MUTED);
    y += HEALTH_ROW_H;

    p = b;
    p = app_str(p, "SpeedFloor: ");
    if (!g_health.speedPresent) {
        p = app_str(p, "NO HEALTH EXPORT");
    } else {
        p = app_str(p, speed_status_text(g_health.speedStatus));
        p = app_str(p, "   applies=");
        p = app_u32(p, g_health.speedApplyCount);
    }
    *p = 0;
    draw_text(28, y, b, COLOR_MUTED);
    y += HEALTH_ROW_H;

    p = b;
    p = app_str(p, "StealthGuardian: ");
    if (!g_health.stealthPresent) {
        p = app_str(p, "NO HEALTH EXPORT");
    } else {
        p = app_str(p, stealth_status_text(g_health.stealthStatus));
        p = app_str(p, "   lost=");
        p = app_u32(p, g_health.stealthLost);
        p = app_str(p, " repairs=");
        p = app_u32(p, g_health.stealthRepairs);
    }
    *p = 0;
    draw_text(28, y, b, COLOR_MUTED);
    y += HEALTH_ROW_H;

    p = b;
    p = app_str(p, "MovementCore Alt: ");
    if (!g_health.movementPresent) {
        p = app_str(p, "BASE/NO V21 HEALTH");
    } else {
        p = app_str(p, g_health.movementAltInstalled ? "READY" : "NOT INSTALLED");
        p = app_str(p, "   starts=");
        p = app_u32(p, g_health.movementAltStarts);
        p = app_str(p, " pp-blocks=");
        p = app_u32(p, g_health.movementPPBlocks);
    }
    *p = 0;
    draw_text(28, y, b, COLOR_MUTED);
    y += HEALTH_ROW_H;

    p = b;
    p = app_str(p, "AutoPoisons: ");
    if (!g_health.autoPoisonsPresent) {
        p = app_str(p, "NOT LOADED");
    } else {
        p = app_str(p, autopoisons_status_text(g_health.autoPoisonsStatus));
        p = app_str(p, "   ticks=");
        p = app_u32(p, g_health.autoPoisonsTicks);
    }
    *p = 0;
    draw_text(28, y, b, COLOR_MUTED);
}

static void reset_setting_to_default(const W112_ControlModuleV1 *api,
                                     const W112_ControlSettingV1 *s)
{
    W112_ControlValueV1 v;
    if (!api || !s || !api->set_value) return;
    if (s->flags & W112_CTL_READ_ONLY) return;
    v = s->default_value;
    api->set_value(s->setting_id, &v);
}

static void step_setting(const W112_ControlModuleV1 *api,
                         const W112_ControlSettingV1 *s,
                         LONG direction)
{
    W112_ControlValueV1 v;
    if (!api || !s || !api->get_value || !api->set_value || direction == 0) return;
    if (s->flags & W112_CTL_READ_ONLY) return;
    if (!api->get_value(s->setting_id, &v)) return;

    if (s->type == W112_CTL_BOOL) {
        v.u32 = direction > 0 ? 1u : 0u;
    } else if (s->type == W112_CTL_ENUM && s->enum_options && s->enum_option_count) {
        DWORD i;
        DWORD found = 0u;
        LONG next;
        for (i = 0u; i < s->enum_option_count; ++i) {
            if (s->enum_options[i].value == v.i32) {
                found = i + 1u;
                break;
            }
        }
        if (!found) return;
        next = (LONG)(found - 1u) + (direction > 0 ? 1 : -1);
        if (next < 0) next = 0;
        if ((DWORD)next >= s->enum_option_count) next = (LONG)s->enum_option_count - 1;
        v.i32 = s->enum_options[(DWORD)next].value;
    } else if (s->type == W112_CTL_FLOAT) {
        float step = s->step.f32;
        if (!(step > 0.0f)) step = 0.1f;
        v.f32 += direction > 0 ? step : -step;
        if (v.f32 < s->min_value.f32) v.f32 = s->min_value.f32;
        if (v.f32 > s->max_value.f32) v.f32 = s->max_value.f32;
    } else {
        LONG step = s->step.i32;
        if (step <= 0) step = 1;
        v.i32 += direction > 0 ? step : -step;
        if (v.i32 < s->min_value.i32) v.i32 = s->min_value.i32;
        if (v.i32 > s->max_value.i32) v.i32 = s->max_value.i32;
    }
    api->set_value(s->setting_id, &v);
}

static void toggle_or_advance_setting(const W112_ControlModuleV1 *api,
                                      const W112_ControlSettingV1 *s)
{
    W112_ControlValueV1 v;
    if (!api || !s || !api->get_value || !api->set_value) return;
    if (s->flags & W112_CTL_READ_ONLY) return;

    if (s->type != W112_CTL_BOOL) {
        step_setting(api, s, 1);
        return;
    }

    if (api->get_value(s->setting_id, &v)) {
        v.u32 = v.u32 ? 0u : 1u;
        api->set_value(s->setting_id, &v);
    }
}

static void select_module_relative(LONG direction)
{
    LONG next;
    if (!g_moduleCount || direction == 0) return;
    next = (LONG)g_selectedModule + (direction > 0 ? 1 : -1);
    if (next < 0) next = (LONG)g_moduleCount - 1;
    if ((DWORD)next >= g_moduleCount) next = 0;
    g_selectedModule = (DWORD)next;
    g_modulePage = g_selectedModule / MODULES_PER_PAGE;
    g_selectedSetting = 0u;
    g_settingPage = 0u;
    normalize_pages();
}

static BOOL handle_panel_key(DWORD key)
{
    const W112_ControlModuleV1 *api;
    DWORD settingCount;

    if (!g_visible) return FALSE;
    if (key == VK_TAB) {
        select_module_relative(1);
        return TRUE;
    }
    if (!g_moduleCount) return FALSE;

    api = g_modules[g_selectedModule].api;
    settingCount = api->setting_count;

    if (key == VK_PRIOR || key == VK_NEXT) {
        DWORD pages = settingCount ? ((settingCount + SETTINGS_PER_PAGE - 1u) / SETTINGS_PER_PAGE) : 1u;
        if (key == VK_PRIOR && g_settingPage > 0u) --g_settingPage;
        if (key == VK_NEXT && g_settingPage + 1u < pages) ++g_settingPage;
        g_selectedSetting = g_settingPage * SETTINGS_PER_PAGE;
        if (settingCount && g_selectedSetting >= settingCount) g_selectedSetting = settingCount - 1u;
        return TRUE;
    }

    if (!settingCount) return FALSE;

    if (key == VK_UP) {
        if (g_selectedSetting > 0u) --g_selectedSetting;
        g_settingPage = g_selectedSetting / SETTINGS_PER_PAGE;
        return TRUE;
    }
    if (key == VK_DOWN) {
        if (g_selectedSetting + 1u < settingCount) ++g_selectedSetting;
        g_settingPage = g_selectedSetting / SETTINGS_PER_PAGE;
        return TRUE;
    }

    if (key == VK_LEFT) {
        step_setting(api, &api->settings[g_selectedSetting], -1);
        return TRUE;
    }
    if (key == VK_RIGHT) {
        step_setting(api, &api->settings[g_selectedSetting], 1);
        return TRUE;
    }
    if (key == VK_RETURN || key == VK_SPACE) {
        toggle_or_advance_setting(api, &api->settings[g_selectedSetting]);
        return TRUE;
    }
    if (key == VK_R) {
        reset_setting_to_default(api, &api->settings[g_selectedSetting]);
        return TRUE;
    }
    return FALSE;
}

static void draw_panel(void)
{
    DWORD i, idx, start, end, settingCount, settingStart, settingEnd;
    DWORD modulePages, settingPages;
    const W112_ControlModuleV1 *api = NULL;
    char b[180];
    char *p;

    clear_pixels(COLOR_BG);
    fill_rect(0, 0, PANEL_W, HEADER_H, COLOR_HEADER);
    frame_rect(0, 0, PANEL_W, PANEL_H, COLOR_BORDER);
    draw_text(12, 7, "WoWControlHub V2.1   [Insert]", COLOR_TEXT);

    modulePages = g_moduleCount ? ((g_moduleCount + MODULES_PER_PAGE - 1u) / MODULES_PER_PAGE) : 1u;
    draw_button(MOD_PREV_X, MOD_NAV_Y, MOD_NAV_W, MOD_NAV_H, "<", g_modulePage > 0u);
    draw_button(MOD_NEXT_X, MOD_NAV_Y, MOD_NAV_W, MOD_NAV_H, ">", g_modulePage + 1u < modulePages);

    if (g_moduleCount == 0u) {
        draw_text(54, 42, "No W112_CONTROL_API_V1 modules found", COLOR_MUTED);
        draw_text(20, 90, "Runtime modules keep their compile-time defaults.", COLOR_MUTED);
        draw_runtime_health();
        return;
    }

    start = g_modulePage * MODULES_PER_PAGE;
    end = start + MODULES_PER_PAGE;
    if (end > g_moduleCount) end = g_moduleCount;
    for (i = 0u, idx = start; idx < end; ++i, ++idx) {
        int x = TAB_X + (int)i * (TAB_W + TAB_GAP);
        fill_rect(x, MOD_NAV_Y, TAB_W, MOD_NAV_H, idx == g_selectedModule ? COLOR_TAB_ON : COLOR_TAB);
        frame_rect(x, MOD_NAV_Y, TAB_W, MOD_NAV_H, COLOR_BORDER);
        draw_text(x + 7, MOD_NAV_Y + 6, g_modules[idx].api->module_name, COLOR_TEXT);
    }

    api = g_modules[g_selectedModule].api;
    settingCount = api->setting_count;
    settingPages = settingCount ? ((settingCount + SETTINGS_PER_PAGE - 1u) / SETTINGS_PER_PAGE) : 1u;
    settingStart = g_settingPage * SETTINGS_PER_PAGE;
    settingEnd = settingStart + SETTINGS_PER_PAGE;
    if (settingEnd > settingCount) settingEnd = settingCount;

    for (i = 0u, idx = settingStart; idx < settingEnd; ++i, ++idx) {
        const W112_ControlSettingV1 *s = &api->settings[idx];
        W112_ControlValueV1 v;
        int y = ROW_Y + (int)i * ROW_H;
        float norm;
        int fill;

        fill_rect(12, y, PANEL_W - 24, ROW_H - 4,
                  idx == g_selectedSetting ? COLOR_SELECTED : COLOR_PANEL);
        frame_rect(12, y, PANEL_W - 24, ROW_H - 4, COLOR_BORDER);
        if (idx == g_selectedSetting) fill_rect(13, y + 1, 3, ROW_H - 6, COLOR_ACCENT);
        draw_text(20, y + 6, s->label ? s->label : s->key, COLOR_TEXT);

        if (!api->get_value(s->setting_id, &v)) {
            draw_text(410, y + 6, "READ ERROR", COLOR_MUTED);
            continue;
        }

        build_value_text(b, s, &v);
        draw_text(VALUE_X, y + 6, b, COLOR_MUTED);

        if (s->type == W112_CTL_BOOL) {
            frame_rect(STEP_PLUS_X, y + 5, 18, 18, COLOR_ACCENT);
            if (v.u32) fill_rect(STEP_PLUS_X + 4, y + 9, 10, 10, COLOR_FILL);
        } else {
            if (!(s->flags & W112_CTL_READ_ONLY))
                draw_button(STEP_MINUS_X, y + 18, STEP_W, 18, "-", TRUE);
            fill_rect(SLIDER_X, y + SLIDER_YOFF, SLIDER_W, 6, COLOR_TRACK);
            norm = normalized_value(s, &v);
            fill = (int)(norm * (float)SLIDER_W);
            if (fill < 1) fill = 1;
            if (fill > SLIDER_W) fill = SLIDER_W;
            fill_rect(SLIDER_X, y + SLIDER_YOFF, fill, 6, COLOR_FILL);
            frame_rect(SLIDER_X, y + SLIDER_YOFF, SLIDER_W, 6, COLOR_BORDER);
            if (!(s->flags & W112_CTL_READ_ONLY))
                draw_button(STEP_PLUS_X, y + 18, STEP_W, 18, "+", TRUE);
        }

        if (!(s->flags & W112_CTL_READ_ONLY))
            draw_button(RESET_X, y + 18, RESET_W, 18, "RST", FALSE);
    }

    draw_button(12, SETTING_NAV_Y, 32, SETTING_NAV_H, "<", g_settingPage > 0u);
    draw_button(198, SETTING_NAV_Y, 32, SETTING_NAV_H, ">", g_settingPage + 1u < settingPages);
    p = b;
    p = app_str(p, "Settings ");
    p = app_u32(p, g_settingPage + 1u);
    p = app_str(p, "/");
    p = app_u32(p, settingPages);
    p = app_str(p, "   ");
    p = app_u32(p, settingCount);
    p = app_str(p, " total");
    *p = 0;
    draw_text(54, SETTING_NAV_Y + 5, b, COLOR_MUTED);

    p = b;
    p = app_str(p, "Module ");
    p = app_u32(p, g_selectedModule + 1u);
    p = app_str(p, "/");
    p = app_u32(p, g_moduleCount);
    p = app_str(p, "   ");
    p = app_str(p, api->module_id);
    p = app_str(p, "   ver=");
    p = app_hex32(p, api->module_version);
    *p = 0;
    draw_text(260, SETTING_NAV_Y + 5, b, COLOR_MUTED);

    draw_text(20, 318, "Keys: arrows select/adjust  Enter toggle/next  R default  Tab module", COLOR_MUTED);

    draw_runtime_health();
}

static BOOL present_panel(HWND gameHwnd)
{
    struct POINT32 client;
    struct POINT32 dst, src;
    struct SIZE32 size;
    struct BLENDFUNCTION32 blend;

    if (!g_visible || !gameHwnd || GetForegroundWindow() != gameHwnd) {
        if (g_overlayHwnd && IsWindow(g_overlayHwnd)) ShowWindow(g_overlayHwnd, SW_HIDE);
        return TRUE;
    }

    if (!ensure_overlay(gameHwnd)) return FALSE;
    client.x = 0;
    client.y = 0;
    if (!ClientToScreen(gameHwnd, &client)) return FALSE;

    draw_panel();
    finalize_alpha();

    dst.x = client.x + PANEL_X;
    dst.y = client.y + PANEL_Y;
    src.x = 0;
    src.y = 0;
    size.cx = PANEL_W;
    size.cy = PANEL_H;
    blend.BlendOp = AC_SRC_OVER;
    blend.BlendFlags = 0u;
    blend.SourceConstantAlpha = 255u;
    blend.AlphaFormat = AC_SRC_ALPHA;

    SetWindowPos(g_overlayHwnd, (HWND)(-1), dst.x, dst.y, PANEL_W, PANEL_H,
                 SWP_NOACTIVATE | SWP_SHOWWINDOW);
    if (!UpdateLayeredWindow(g_overlayHwnd, NULL, &dst, &size, g_memdc, &src, 0u, &blend, ULW_ALPHA))
        return FALSE;
    ShowWindow(g_overlayHwnd, SW_SHOWNOACTIVATE);
    return TRUE;
}

static void set_numeric_from_click(const W112_ControlModuleV1 *api,
                                   const W112_ControlSettingV1 *s,
                                   int localX)
{
    W112_ControlValueV1 v;
    float t;
    if (!api || !s || !api->set_value) return;
    if (localX < SLIDER_X) localX = SLIDER_X;
    if (localX > SLIDER_X + SLIDER_W) localX = SLIDER_X + SLIDER_W;
    t = (float)(localX - SLIDER_X) / (float)SLIDER_W;

    if (s->type == W112_CTL_FLOAT) {
        float minv = s->min_value.f32;
        float maxv = s->max_value.f32;
        float step = s->step.f32;
        float raw = minv + (maxv - minv) * t;
        if (step > 0.0f) {
            LONG steps = (LONG)(((raw - minv) / step) + 0.5f);
            raw = minv + (float)steps * step;
        }
        if (raw < minv) raw = minv;
        if (raw > maxv) raw = maxv;
        v.f32 = raw;
    } else {
        LONG minv = s->min_value.i32;
        LONG maxv = s->max_value.i32;
        LONG step = s->step.i32;
        LONG raw;
        if (step <= 0) step = 1;
        raw = minv + (LONG)(((float)(maxv - minv) * t) + 0.5f);
        raw = minv + ((raw - minv + step / 2) / step) * step;
        if (raw < minv) raw = minv;
        if (raw > maxv) raw = maxv;
        v.i32 = raw;
    }
    api->set_value(s->setting_id, &v);
}

static BOOL point_in(int x, int y, int rx, int ry, int rw, int rh)
{
    return x >= rx && x < rx + rw && y >= ry && y < ry + rh;
}

static BOOL handle_panel_click(int gameX, int gameY)
{
    int x, y;
    DWORD i, idx, start, end;
    DWORD modulePages, settingPages, settingCount;
    const W112_ControlModuleV1 *api;

    if (!g_visible) return FALSE;
    x = gameX - PANEL_X;
    y = gameY - PANEL_Y;
    if (x < 0 || y < 0 || x >= PANEL_W || y >= PANEL_H) return FALSE;

    modulePages = g_moduleCount ? ((g_moduleCount + MODULES_PER_PAGE - 1u) / MODULES_PER_PAGE) : 1u;

    if (point_in(x, y, MOD_PREV_X, MOD_NAV_Y, MOD_NAV_W, MOD_NAV_H)) {
        if (g_modulePage > 0u) {
            --g_modulePage;
            g_selectedModule = g_modulePage * MODULES_PER_PAGE;
            g_selectedSetting = 0u;
            g_settingPage = 0u;
        }
        return TRUE;
    }

    if (point_in(x, y, MOD_NEXT_X, MOD_NAV_Y, MOD_NAV_W, MOD_NAV_H)) {
        if (g_modulePage + 1u < modulePages) {
            ++g_modulePage;
            g_selectedModule = g_modulePage * MODULES_PER_PAGE;
            if (g_selectedModule >= g_moduleCount) g_selectedModule = g_moduleCount - 1u;
            g_selectedSetting = 0u;
            g_settingPage = 0u;
        }
        return TRUE;
    }

    if (g_moduleCount == 0u) return TRUE;

    start = g_modulePage * MODULES_PER_PAGE;
    end = start + MODULES_PER_PAGE;
    if (end > g_moduleCount) end = g_moduleCount;
    for (i = 0u, idx = start; idx < end; ++i, ++idx) {
        int tx = TAB_X + (int)i * (TAB_W + TAB_GAP);
        if (point_in(x, y, tx, MOD_NAV_Y, TAB_W, MOD_NAV_H)) {
            g_selectedModule = idx;
            g_selectedSetting = 0u;
            g_settingPage = 0u;
            return TRUE;
        }
    }

    api = g_modules[g_selectedModule].api;
    settingCount = api->setting_count;
    settingPages = settingCount ? ((settingCount + SETTINGS_PER_PAGE - 1u) / SETTINGS_PER_PAGE) : 1u;

    if (point_in(x, y, 12, SETTING_NAV_Y, 32, SETTING_NAV_H)) {
        if (g_settingPage > 0u) --g_settingPage;
        g_selectedSetting = g_settingPage * SETTINGS_PER_PAGE;
        return TRUE;
    }
    if (point_in(x, y, 198, SETTING_NAV_Y, 32, SETTING_NAV_H)) {
        if (g_settingPage + 1u < settingPages) ++g_settingPage;
        g_selectedSetting = g_settingPage * SETTINGS_PER_PAGE;
        if (settingCount && g_selectedSetting >= settingCount) g_selectedSetting = settingCount - 1u;
        return TRUE;
    }

    start = g_settingPage * SETTINGS_PER_PAGE;
    end = start + SETTINGS_PER_PAGE;
    if (end > settingCount) end = settingCount;

    for (i = 0u, idx = start; idx < end; ++i, ++idx) {
        const W112_ControlSettingV1 *s = &api->settings[idx];
        int ry = ROW_Y + (int)i * ROW_H;
        if (y >= ry && y < ry + ROW_H - 4) {
            g_selectedSetting = idx;
            if (s->flags & W112_CTL_READ_ONLY) return TRUE;

            if (point_in(x, y, RESET_X, ry + 18, RESET_W, 18)) {
                reset_setting_to_default(api, s);
                return TRUE;
            }

            if (s->type == W112_CTL_BOOL) {
                toggle_or_advance_setting(api, s);
                return TRUE;
            }

            if (point_in(x, y, STEP_MINUS_X, ry + 18, STEP_W, 18)) {
                step_setting(api, s, -1);
                return TRUE;
            }
            if (point_in(x, y, STEP_PLUS_X, ry + 18, STEP_W, 18)) {
                step_setting(api, s, 1);
                return TRUE;
            }
            if (x >= SLIDER_X - 6 && x <= SLIDER_X + SLIDER_W + 6) {
                set_numeric_from_click(api, s, x);
                return TRUE;
            }
            return TRUE;
        }
    }

    return TRUE;
}

static LONG WINAPI hub_game_wndproc(HWND hwnd, UINT msg, DWORD wParam, LONG lParam)
{
    if (msg == WM_KEYDOWN && wParam == VK_INSERT) {
        g_visible = g_visible ? 0u : 1u;
        return 0;
    }

    if (msg == WM_KEYDOWN && g_visible && handle_panel_key(wParam))
        return 0;

    if (msg == WM_LBUTTONDOWN && g_visible) {
        int mx = (int)(short)(lParam & 0xFFFF);
        int my = (int)(short)((lParam >> 16) & 0xFFFF);
        if (handle_panel_click(mx, my)) return 0;
    }

    if (g_oldWndProc) return CallWindowProcA(g_oldWndProc, hwnd, msg, wParam, lParam);
    return 0;
}

static void remove_game_hook(void)
{
    LONG current;
    if (g_gameHwnd && g_oldWndProc && IsWindow(g_gameHwnd)) {
        current = GetWindowLongA(g_gameHwnd, GWL_WNDPROC);
        if ((DWORD)current == (DWORD)hub_game_wndproc)
            SetWindowLongA(g_gameHwnd, GWL_WNDPROC, (LONG)(DWORD)g_oldWndProc);
    }
    g_gameHwnd = NULL;
    g_oldWndProc = NULL;
}

static BOOL ensure_game_hook(HWND hwnd)
{
    LONG oldProc;
    if (!hwnd) return FALSE;

    /* Do not reinstall merely because another legitimate module subclasses
       above us. If the game HWND is unchanged and we retained a predecessor,
       our node is still part of the chain. */
    if (g_gameHwnd == hwnd && g_oldWndProc) return TRUE;

    remove_game_hook();
    oldProc = SetWindowLongA(hwnd, GWL_WNDPROC, (LONG)(DWORD)hub_game_wndproc);
    if (!oldProc) return FALSE;
    g_gameHwnd = hwnd;
    g_oldWndProc = (WNDPROC32)(DWORD)oldProc;
    return TRUE;
}

static DWORD WINAPI WorkerThread(LPVOID ignored)
{
    DWORD now;
    HWND hwnd;
    (void)ignored;

    g_lastDiscoveryTick = 0u;

    while (!g_stop) {
        pump_messages();
        hwnd = get_game_window();
        if (hwnd) ensure_game_hook(hwnd);

        /* GetTickCount is not needed as a direct import: a monotonic-ish loop
           counter is enough for one-second discovery cadence at FRAME_MS. */
        now = ++g_lastDiscoveryTick;
        if (now == 1u || (now % (DISCOVERY_MS / FRAME_MS)) == 0u)
            refresh_modules();

        present_panel(hwnd);
        Sleep(FRAME_MS);
    }

    if (g_overlayHwnd && IsWindow(g_overlayHwnd)) ShowWindow(g_overlayHwnd, SW_HIDE);
    remove_game_hook();
    destroy_overlay();
    return 0u;
}

BOOL WINAPI DllMain(HMODULE hinst, DWORD reason, LPVOID reserved)
{
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
