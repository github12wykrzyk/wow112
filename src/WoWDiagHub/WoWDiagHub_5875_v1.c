#include <windows.h>
#include "../common/W112DiagAPI.h"

#define W112_DIAG_RING_CAP 256
#define W112_DIAG_TEXT_CAP 160
#define W112_DIAG_MODULE_CAP 32
#define W112_DIAG_EVENT_CAP 48

#pragma comment(linker, "/EXPORT:W112_DIAG_API_V1_Get=_W112_DIAG_API_V1_Get")
#pragma comment(linker, "/EXPORT:W112DiagWriteEvent=_W112DiagWriteEvent")
#pragma comment(linker, "/EXPORT:W112DiagSnapshot=_W112DiagSnapshot")
#pragma comment(linker, "/EXPORT:W112DiagGetSessionPath=_W112DiagGetSessionPath")

typedef struct DiagEvent {
    DWORD tick_ms;
    DWORD pid;
    DWORD tid;
    unsigned level;
    long value_a;
    long value_b;
    char module[W112_DIAG_MODULE_CAP];
    char event_name[W112_DIAG_EVENT_CAP];
    char text[W112_DIAG_TEXT_CAP];
} DiagEvent;

static CRITICAL_SECTION g_lock;
static volatile LONG g_ready = 0;
static LONG g_seq = 0;
static DiagEvent g_ring[W112_DIAG_RING_CAP];
static char g_session_path[MAX_PATH];
static char g_debug_dir[MAX_PATH];

static void CopyText(char *dst, unsigned cap, const char *src)
{
    unsigned i = 0;
    if (!dst || cap == 0) return;
    if (!src) src = "";
    while (i + 1 < cap && src[i]) {
        dst[i] = src[i];
        ++i;
    }
    dst[i] = 0;
}

static void CopyEvent(DiagEvent *dst, const DiagEvent *src)
{
    if (!dst || !src) return;
    dst->tick_ms = src->tick_ms;
    dst->pid = src->pid;
    dst->tid = src->tid;
    dst->level = src->level;
    dst->value_a = src->value_a;
    dst->value_b = src->value_b;
    CopyText(dst->module, sizeof(dst->module), src->module);
    CopyText(dst->event_name, sizeof(dst->event_name), src->event_name);
    CopyText(dst->text, sizeof(dst->text), src->text);
}

static void AppendChar(char *dst, unsigned cap, unsigned *pos, char c)
{
    if (*pos + 1 >= cap) return;
    dst[*pos] = c;
    ++(*pos);
    dst[*pos] = 0;
}

static void AppendText(char *dst, unsigned cap, unsigned *pos, const char *src)
{
    if (!src) return;
    while (*src) {
        AppendChar(dst, cap, pos, *src);
        ++src;
    }
}

static void AppendUnsigned(char *dst, unsigned cap, unsigned *pos, DWORD value)
{
    char tmp[16];
    unsigned n = 0;
    if (value == 0) {
        AppendChar(dst, cap, pos, '0');
        return;
    }
    while (value && n < sizeof(tmp)) {
        tmp[n++] = (char)('0' + (value % 10));
        value /= 10;
    }
    while (n) AppendChar(dst, cap, pos, tmp[--n]);
}

static void AppendSigned(char *dst, unsigned cap, unsigned *pos, long value)
{
    DWORD magnitude;
    if (value < 0) {
        AppendChar(dst, cap, pos, '-');
        magnitude = (DWORD)(-(value + 1));
        ++magnitude;
    } else {
        magnitude = (DWORD)value;
    }
    AppendUnsigned(dst, cap, pos, magnitude);
}

static void AppendJsonEscaped(char *dst, unsigned cap, unsigned *pos, const char *src)
{
    unsigned char c;
    static const char hex[] = "0123456789abcdef";
    if (!src) return;
    while (*src) {
        c = (unsigned char)*src++;
        if (c == '"' || c == '\\') {
            AppendChar(dst, cap, pos, '\\');
            AppendChar(dst, cap, pos, (char)c);
        } else if (c == '\n') {
            AppendText(dst, cap, pos, "\\n");
        } else if (c == '\r') {
            AppendText(dst, cap, pos, "\\r");
        } else if (c == '\t') {
            AppendText(dst, cap, pos, "\\t");
        } else if (c < 0x20) {
            AppendText(dst, cap, pos, "\\u00");
            AppendChar(dst, cap, pos, hex[(c >> 4) & 0x0F]);
            AppendChar(dst, cap, pos, hex[c & 0x0F]);
        } else {
            AppendChar(dst, cap, pos, (char)c);
        }
    }
}

static int PreparePaths(void)
{
    char exe[MAX_PATH];
    DWORD len;
    int i;
    if (g_session_path[0]) return 1;
    len = GetModuleFileNameA(NULL, exe, MAX_PATH);
    if (!len || len >= MAX_PATH) return 0;
    i = (int)len - 1;
    while (i >= 0 && exe[i] != '\\' && exe[i] != '/') --i;
    if (i < 1) return 0;
    exe[i] = 0;
    if ((DWORD)lstrlenA(exe) + 18 >= MAX_PATH) return 0;
    lstrcpyA(g_debug_dir, exe);
    lstrcatA(g_debug_dir, "\\.wow112_debug");
    CreateDirectoryA(g_debug_dir, NULL);
    if ((DWORD)lstrlenA(g_debug_dir) + 64 >= MAX_PATH) return 0;
    wsprintfA(g_session_path, "%s\\session_%lu_%lu.jsonl", g_debug_dir, GetCurrentProcessId(), GetTickCount());
    return 1;
}

static unsigned FormatEventLine(const DiagEvent *ev, char *out, unsigned cap)
{
    unsigned p = 0;
    if (!ev || !out || cap < 32) return 0;
    out[0] = 0;
    AppendText(out, cap, &p, "{\"tick_ms\":");
    AppendUnsigned(out, cap, &p, ev->tick_ms);
    AppendText(out, cap, &p, ",\"pid\":");
    AppendUnsigned(out, cap, &p, ev->pid);
    AppendText(out, cap, &p, ",\"tid\":");
    AppendUnsigned(out, cap, &p, ev->tid);
    AppendText(out, cap, &p, ",\"level\":");
    AppendUnsigned(out, cap, &p, ev->level);
    AppendText(out, cap, &p, ",\"module\":\"");
    AppendJsonEscaped(out, cap, &p, ev->module);
    AppendText(out, cap, &p, "\",\"event\":\"");
    AppendJsonEscaped(out, cap, &p, ev->event_name);
    AppendText(out, cap, &p, "\",\"a\":");
    AppendSigned(out, cap, &p, ev->value_a);
    AppendText(out, cap, &p, ",\"b\":");
    AppendSigned(out, cap, &p, ev->value_b);
    AppendText(out, cap, &p, ",\"text\":\"");
    AppendJsonEscaped(out, cap, &p, ev->text);
    AppendText(out, cap, &p, "\"}\r\n");
    return p;
}

static int AppendEventToFile(const char *path, const DiagEvent *ev)
{
    HANDLE file;
    DWORD wrote = 0;
    char line[640];
    unsigned len;
    if (!path || !path[0] || !ev) return 0;
    len = FormatEventLine(ev, line, sizeof(line));
    if (!len) return 0;
    file = CreateFileA(path, FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE, NULL, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (file == INVALID_HANDLE_VALUE) return 0;
    WriteFile(file, line, len, &wrote, NULL);
    FlushFileBuffers(file);
    CloseHandle(file);
    return wrote == len;
}

static void FillEvent(DiagEvent *ev, const char *module, const char *event_name, unsigned level, long a, long b, const char *text)
{
    ev->tick_ms = GetTickCount();
    ev->pid = GetCurrentProcessId();
    ev->tid = GetCurrentThreadId();
    ev->level = level;
    ev->value_a = a;
    ev->value_b = b;
    CopyText(ev->module, sizeof(ev->module), module);
    CopyText(ev->event_name, sizeof(ev->event_name), event_name);
    CopyText(ev->text, sizeof(ev->text), text);
}

__declspec(dllexport) int __cdecl W112DiagWriteEvent(const char *module, const char *event_name, unsigned level, long value_a, long value_b, const char *text)
{
    DiagEvent ev;
    LONG idx;
    int ok;
    if (!g_ready) return 0;
    FillEvent(&ev, module, event_name, level, value_a, value_b, text);
    EnterCriticalSection(&g_lock);
    if (!PreparePaths()) {
        LeaveCriticalSection(&g_lock);
        return 0;
    }
    idx = g_seq++;
    CopyEvent(&g_ring[idx % W112_DIAG_RING_CAP], &ev);
    ok = AppendEventToFile(g_session_path, &ev);
    LeaveCriticalSection(&g_lock);
    return ok;
}

__declspec(dllexport) int __cdecl W112DiagGetSessionPath(char *out_path, unsigned out_size)
{
    int ok = 0;
    if (!g_ready || !out_path || out_size == 0) return 0;
    EnterCriticalSection(&g_lock);
    if (PreparePaths()) {
        CopyText(out_path, out_size, g_session_path);
        ok = 1;
    }
    LeaveCriticalSection(&g_lock);
    return ok;
}

__declspec(dllexport) int __cdecl W112DiagSnapshot(const char *reason)
{
    char path[MAX_PATH];
    DiagEvent marker;
    LONG count;
    LONG start;
    LONG i;
    int ok = 1;
    if (!g_ready) return 0;
    EnterCriticalSection(&g_lock);
    if (!PreparePaths()) {
        LeaveCriticalSection(&g_lock);
        return 0;
    }
    wsprintfA(path, "%s\\snapshot_%lu_%lu.jsonl", g_debug_dir, GetCurrentProcessId(), GetTickCount());
    FillEvent(&marker, "diag", "snapshot", W112_DIAG_LEVEL_INFO, g_seq, 0, reason ? reason : "manual");
    ok = AppendEventToFile(path, &marker);
    count = g_seq < W112_DIAG_RING_CAP ? g_seq : W112_DIAG_RING_CAP;
    start = g_seq - count;
    for (i = 0; i < count; ++i) {
        if (!AppendEventToFile(path, &g_ring[(start + i) % W112_DIAG_RING_CAP])) ok = 0;
    }
    LeaveCriticalSection(&g_lock);
    return ok;
}

static const W112DiagApiV1 g_api = {
    sizeof(W112DiagApiV1),
    W112_DIAG_API_VERSION,
    W112DiagWriteEvent,
    W112DiagSnapshot,
    W112DiagGetSessionPath
};

__declspec(dllexport) const W112DiagApiV1 *__cdecl W112_DIAG_API_V1_Get(void)
{
    return &g_api;
}

static DWORD WINAPI BootstrapThread(LPVOID unused)
{
    (void)unused;
    Sleep(250);
    W112DiagWriteEvent("WoWDiagHub", "loaded", W112_DIAG_LEVEL_INFO, 5875, 1, "observer-only diagnostics online");
    return 0;
}

BOOL WINAPI DllMain(HINSTANCE instance, DWORD reason, LPVOID reserved)
{
    HANDLE thread;
    (void)instance;
    (void)reserved;
    if (reason == DLL_PROCESS_ATTACH) {
        InitializeCriticalSection(&g_lock);
        g_ready = 1;
        DisableThreadLibraryCalls(instance);
        thread = CreateThread(NULL, 0, BootstrapThread, NULL, 0, NULL);
        if (thread) CloseHandle(thread);
    } else if (reason == DLL_PROCESS_DETACH) {
        g_ready = 0;
        DeleteCriticalSection(&g_lock);
    }
    return TRUE;
}
