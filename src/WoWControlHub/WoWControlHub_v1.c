/*
 * WoWControlHub_v1.c
 * Central runtime GUI/config hub for World of Warcraft 1.12.1 build 5875 x86.
 *
 * Rendering/input deliberately reuses the active PlayerESP pattern:
 *   - game HWND from the build-5875 native helper at 0x00435C30
 *   - transparent topmost Win32 layered overlay
 *   - game WndProc subclass for F10 and mouse clicks
 * No DirectX hook is introduced in this pilot.
 *
 * Provider discovery is generic. Loaded modules are enumerated and queried for
 * W112_Control_GetModuleV1; the hub never knows private variable offsets.
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
typedef char* LPSTR;
typedef unsigned int COLORREF;

#define WINAPI __stdcall
#define TRUE 1
#define FALSE 0
#define DLL_PROCESS_DETACH 0u
#define DLL_PROCESS_ATTACH 1u
#define INVALID_HANDLE_VALUE ((HANDLE)(-1))

typedef LONG (WINAPI *WNDPROC32)(HWND, UINT, DWORD, LONG);
typedef HWND (__fastcall *GetGameWindowFn)(int which);

#define FN_GET_GAME_WINDOW 0x00435C30u
#define WM_KEYDOWN         0x0100u
#define WM_LBUTTONDOWN     0x0201u
#define VK_F10             0x79u
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

#define PANEL_W 440
#define PANEL_H 260
#define PANEL_X 20
#define PANEL_Y 20
#define HEADER_H 30
#define TAB_Y 34
#define TAB_H 26
#define TAB_X 12
#define TAB_W 132
#define TAB_GAP 4
#define ROW_Y 72
#define ROW_H 44
#define SLIDER_X 238
#define SLIDER_W 172
#define SLIDER_YOFF 25
#define MAX_MODULES 16u
#define MAX_VISIBLE_SETTINGS 4u
#define DISCOVERY_MS 1000u
#define FRAME_MS 50u

#define COLOR_BG        0x00202020u
#define COLOR_HEADER    0x00303030u
#define COLOR_PANEL     0x00282828u
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

__declspec(dllimport) HANDLE WINAPI CreateThread(LPVOID, SIZE_T, DWORD (WINAPI *)(LPVOID), LPVOID, DWORD, DWORD*);
__declspec(dllimport) void   WINAPI Sleep(DWORD);
__declspec(dllimport) BOOL   WINAPI CloseHandle(HANDLE);
__declspec(dllimport) BOOL   WINAPI DisableThreadLibraryCalls(HMODULE);
__declspec(dllimport) DWORD  WINAPI GetTickCount(void);
__declspec(dllimport) DWORD  WINAPI GetCurrentProcessId(void);
__declspec(dllimport) HANDLE WINAPI CreateToolhelp32Snapshot(DWORD, DWORD);
__declspec(dllimport) BOOL   WINAPI Module32FirstA(HANDLE, struct MODULEENTRY32A_LOCAL*);
__declspec(dllimport) BOOL   WINAPI Module32NextA(HANDLE, struct MODULEENTRY32A_LOCAL*);
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
static DWORD g_lastDiscoveryTick = 0u;

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

static W112_ControlGetModuleV1Fn find_provider_export(HMODULE module)
{
    LPVOID p;
    p = GetProcAddress(module, "W112_Control_GetModuleV1");
    if (!p) p = GetProcAddress(module, "_W112_Control_GetModuleV1@0");
    if (!p) p = GetProcAddress(module, "_W112_Control_GetModuleV1");
    return (W112_ControlGetModuleV1Fn)p;
}

static BOOL valid_module_api(const W112_ControlModuleV1 *api)
{
    if (!api) return FALSE;
    if (api->abi_version != W112_CONTROL_API_V1) return FALSE;
    if (api->struct_size < (w112_u32)sizeof(W112_ControlModuleV1)) return FALSE;
    if (!api->module_id || !api->module_name) return FALSE;
    if (api->setting_count > 64u) return FALSE;
    if (api->setting_count && !api->settings) return FALSE;
    if (!api->get_value || !api->set_value) return FALSE;
    return TRUE;
}

static void refresh_modules(void)
{
    HANDLE snap;
    struct MODULEENTRY32A_LOCAL me;
    DWORD count = 0u;
    W112_ControlGetModuleV1Fn getApi;
    const W112_ControlModuleV1 *api;

    snap = CreateToolhelp32Snapshot(TH32CS_SNAPMODULE | TH32CS_SNAPMODULE32, GetCurrentProcessId());
    if (snap == INVALID_HANDLE_VALUE) return;

    me.dwSize = (DWORD)sizeof(me);
    if (Module32FirstA(snap, &me)) {
        do {
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
        } while (count < MAX_MODULES && Module32NextA(snap, &me));
    }
    CloseHandle(snap);
    g_moduleCount = count;
    if (g_moduleCount == 0u) g_selectedModule = 0u;
    else if (g_selectedModule >= g_moduleCount) g_selectedModule = g_moduleCount - 1u;
}

static const char *enum_label(const W112_ControlSettingV1 *s, LONG value)
{
    DWORD i;
    if (!s || !s->enum_options) return NULL;
    for (i = 0u; i < s->enum_option_count; ++i)
        if (s->enum_options[i].value == value) return s->enum_options[i].label;
    return NULL;
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
    if (s->flags & W112_CTL_REQUIRES_RELOAD) p = app_str(p, "  RELOAD");
    else if (s->flags & W112_CTL_LIVE) p = app_str(p, "  LIVE");
    *p = 0;
}

static float normalized_value(const W112_ControlSettingV1 *s, const W112_ControlValueV1 *v)
{
    float minv, maxv, cur;
    if (!s || !v) return 0.0f;
    if (s->type == W112_CTL_FLOAT) {
        minv = s->min_value.f32; maxv = s->max_value.f32; cur = v->f32;
    } else {
        minv = (float)s->min_value.i32; maxv = (float)s->max_value.i32; cur = (float)v->i32;
    }
    if (!(maxv > minv)) return 0.0f;
    cur = (cur - minv) / (maxv - minv);
    if (cur < 0.0f) cur = 0.0f;
    if (cur > 1.0f) cur = 1.0f;
    return cur;
}

static void draw_panel(void)
{
    DWORD i, visibleTabs, tabIndex, settingCount;
    const W112_ControlModuleV1 *api = NULL;
    char b[160];
    char *p;

    clear_pixels(COLOR_BG);
    fill_rect(0, 0, PANEL_W, HEADER_H, COLOR_HEADER);
    frame_rect(0, 0, PANEL_W, PANEL_H, COLOR_BORDER);
    draw_text(12, 7, "WoWControlHub V1   [F10]", COLOR_TEXT);

    if (g_moduleCount == 0u) {
        draw_text(18, 52, "No W112_CONTROL_API_V1 modules found", COLOR_MUTED);
        draw_text(18, 76, "SpeedFloor remains on compile-time defaults.", COLOR_MUTED);
        return;
    }

    visibleTabs = g_moduleCount;
    if (visibleTabs > 3u) visibleTabs = 3u;
    for (i = 0u; i < visibleTabs; ++i) {
        tabIndex = i;
        fill_rect(TAB_X + (int)i * (TAB_W + TAB_GAP), TAB_Y, TAB_W, TAB_H,
                  tabIndex == g_selectedModule ? COLOR_TAB_ON : COLOR_TAB);
        frame_rect(TAB_X + (int)i * (TAB_W + TAB_GAP), TAB_Y, TAB_W, TAB_H, COLOR_BORDER);
        draw_text(TAB_X + 8 + (int)i * (TAB_W + TAB_GAP), TAB_Y + 6,
                  g_modules[tabIndex].api->module_name, COLOR_TEXT);
    }

    api = g_modules[g_selectedModule].api;
    settingCount = api->setting_count;
    if (settingCount > MAX_VISIBLE_SETTINGS) settingCount = MAX_VISIBLE_SETTINGS;

    for (i = 0u; i < settingCount; ++i) {
        const W112_ControlSettingV1 *s = &api->settings[i];
        W112_ControlValueV1 v;
        int y = ROW_Y + (int)i * ROW_H;
        float norm;
        int fill;

        fill_rect(12, y, PANEL_W - 24, ROW_H - 4, COLOR_PANEL);
        frame_rect(12, y, PANEL_W - 24, ROW_H - 4, COLOR_BORDER);
        draw_text(20, y + 6, s->label ? s->label : s->key, COLOR_TEXT);

        if (!api->get_value(s->setting_id, &v)) {
            draw_text(255, y + 6, "READ ERROR", COLOR_MUTED);
            continue;
        }
        build_value_text(b, s, &v);
        draw_text(255, y + 6, b, COLOR_MUTED);

        if (s->type == W112_CTL_BOOL) {
            frame_rect(382, y + 5, 18, 18, COLOR_ACCENT);
            if (v.u32) fill_rect(386, y + 9, 10, 10, COLOR_FILL);
        } else {
            fill_rect(SLIDER_X, y + SLIDER_YOFF, SLIDER_W, 6, COLOR_TRACK);
            norm = normalized_value(s, &v);
            fill = (int)(norm * (float)SLIDER_W);
            if (fill < 1) fill = 1;
            if (fill > SLIDER_W) fill = SLIDER_W;
            fill_rect(SLIDER_X, y + SLIDER_YOFF, fill, 6, COLOR_FILL);
            frame_rect(SLIDER_X, y + SLIDER_YOFF, SLIDER_W, 6, COLOR_BORDER);
        }
    }

    if (api->setting_count > MAX_VISIBLE_SETTINGS) {
        p = b;
        p = app_str(p, "+ ");
        p = app_u32(p, api->setting_count - MAX_VISIBLE_SETTINGS);
        p = app_str(p, " more settings (V1 viewport limit)");
        *p = 0;
        draw_text(20, PANEL_H - 20, b, COLOR_MUTED);
    }
}

static BOOL present_panel(HWND gameHwnd)
{
    struct RECT32 r;
    struct POINT32 client;
    struct POINT32 dst, src;
    struct SIZE32 size;
    struct BLENDFUNCTION32 blend;

    if (!g_visible || !gameHwnd || GetForegroundWindow() != gameHwnd) {
        if (g_overlayHwnd && IsWindow(g_overlayHwnd)) ShowWindow(g_overlayHwnd, SW_HIDE);
        return TRUE;
    }
    if (!ensure_overlay(gameHwnd)) return FALSE;
    if (!GetClientRect(gameHwnd, &r)) return FALSE;
    client.x = 0; client.y = 0;
    if (!ClientToScreen(gameHwnd, &client)) return FALSE;

    draw_panel();
    finalize_alpha();

    dst.x = client.x + PANEL_X;
    dst.y = client.y + PANEL_Y;
    src.x = 0; src.y = 0;
    size.cx = PANEL_W; size.cy = PANEL_H;
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

static BOOL handle_panel_click(int gameX, int gameY)
{
    int x, y;
    DWORD i;
    const W112_ControlModuleV1 *api;
    if (!g_visible) return FALSE;
    x = gameX - PANEL_X;
    y = gameY - PANEL_Y;
    if (x < 0 || y < 0 || x >= PANEL_W || y >= PANEL_H) return FALSE;

    if (y >= TAB_Y && y < TAB_Y + TAB_H) {
        DWORD visibleTabs = g_moduleCount > 3u ? 3u : g_moduleCount;
        for (i = 0u; i < visibleTabs; ++i) {
            int tx = TAB_X + (int)i * (TAB_W + TAB_GAP);
            if (x >= tx && x < tx + TAB_W) {
                g_selectedModule = i;
                return TRUE;
            }
        }
    }

    if (g_moduleCount == 0u || g_selectedModule >= g_moduleCount) return TRUE;
    api = g_modules[g_selectedModule].api;
    for (i = 0u; i < api->setting_count && i < MAX_VISIBLE_SETTINGS; ++i) {
        const W112_ControlSettingV1 *s = &api->settings[i];
        int ry = ROW_Y + (int)i * ROW_H;
        if (y >= ry && y < ry + ROW_H - 4) {
            if (s->flags & W112_CTL_READ_ONLY) return TRUE;
            if (s->type == W112_CTL_BOOL) {
                W112_ControlValueV1 v;
                if (api->get_value(s->setting_id, &v)) {
                    v.u32 = v.u32 ? 0u : 1u;
                    api->set_value(s->setting_id, &v);
                }
                return TRUE;
            }
            if (x >= SLIDER_X - 8 && x <= SLIDER_X + SLIDER_W + 8) {
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
    if (msg == WM_KEYDOWN && wParam == VK_F10) {
        g_visible = g_visible ? 0u : 1u;
        return 0;
    }
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

        now = GetTickCount();
        if (g_lastDiscoveryTick == 0u || (DWORD)(now - g_lastDiscoveryTick) >= DISCOVERY_MS) {
            refresh_modules();
            g_lastDiscoveryTick = now;
        }
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
