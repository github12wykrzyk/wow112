/*
 * TaxiFlightProbe V1 - WoW 1.12.1 build 5875, Windows x86.
 *
 * Read-only flight-path measurement. This is NOT an instant-flight hack:
 * the server controls actual taxi travel and no taxi opcode or ABI has
 * been verified for this executable. Do not alter movement or packet state.
 *
 * Ctrl+Shift+F8: mark departure after choosing a Flight Master destination.
 * Ctrl+Shift+F9: mark arrival once the character is controllable.
 * Only when the game window is in the foreground. Output is written to
 * <game folder>\.wow112_debug\taxi_probe_<pid>_<tick>.csv.
 */
#if !defined(_M_IX86) && !defined(__i386__)
#error TaxiFlightProbe requires a 32-bit x86 target.
#endif
#include <windows.h>
/* CRT-less /NODEFAULTLIB x86 builds need the compiler's floating-point marker. */
int _fltused = 0;

#define OBJMGR_GLOBAL 0x00B41414u
#define OM_FIRST_OBJECT 0x00ACu
#define OM_LOCAL_GUID_LO 0x00C0u
#define OM_LOCAL_GUID_HI 0x00C4u
#define OBJ_TYPE 0x0014u
#define OBJ_GUID_LO 0x0030u
#define OBJ_GUID_HI 0x0034u
#define OBJ_NEXT 0x003Cu
#define TYPEID_PLAYER 4u
#define OBJ_X 0x09B8u
#define OBJ_Y 0x09BCu
#define OBJ_Z 0x09C0u
#define PLAYER_CURRENT_SPEED 0x0A2Cu
#define PLAYER_RUN_SPEED 0x0A34u
#define MAX_OBJECTS 1536u

typedef struct TaxiSample {
    LONG x100, y100, z100;
    LONG current100, run100;
} TaxiSample;

static volatile LONG g_stop = 0;
static volatile LONG g_recording = 0;
static volatile LONG g_status = 0; /* 0=detached, 1=idle, 2=recording */
static DWORD g_start_tick = 0;
static DWORD g_last_sample = 0;
static char g_path[MAX_PATH];

static int ReadBytes(DWORD addr, void *out, SIZE_T n)
{
    SIZE_T count = 0;
    if (!addr || !out || !n) return 0;
    return ReadProcessMemory(GetCurrentProcess(), (LPCVOID)(ULONG_PTR)addr,
                             out, n, &count) && count == n;
}
static int ReadU32(DWORD addr, DWORD *out)
{
    return ReadBytes(addr, out, sizeof(*out));
}
static int AsHundredths(float value, LONG *out)
{
    /* Reject NaN, infinities, and implausible pointer-derived data. */
    if (!(value > -1000000.0f && value < 1000000.0f)) return 0;
    *out = (LONG)(value * 100.0f);
    return 1;
}
static int SamplePlayer(TaxiSample *out)
{
    DWORD mgr, node, localLo, localHi, lo, hi, type, next;
    DWORD count;
    float coords[3], currentSpeed, runSpeed;
    if (!out || (DWORD)(ULONG_PTR)GetModuleHandleA(NULL) != 0x00400000u)
        return 0; /* hard-coded addresses are valid only at vanilla image base */
    if (!ReadU32(OBJMGR_GLOBAL, &mgr) || mgr < 0x10000u ||
        !ReadU32(mgr + OM_LOCAL_GUID_LO, &localLo) ||
        !ReadU32(mgr + OM_LOCAL_GUID_HI, &localHi) ||
        (!localLo && !localHi) ||
        !ReadU32(mgr + OM_FIRST_OBJECT, &node))
        return 0;
    for (count = 0; count < MAX_OBJECTS && node >= 0x10000u; ++count) {
        if (!ReadU32(node + OBJ_TYPE, &type) ||
            !ReadU32(node + OBJ_GUID_LO, &lo) ||
            !ReadU32(node + OBJ_GUID_HI, &hi)) return 0;
        if (type == TYPEID_PLAYER && lo == localLo && hi == localHi) {
            if (!ReadBytes(node + OBJ_X, coords, sizeof(coords)) ||
                !ReadBytes(node + PLAYER_CURRENT_SPEED, &currentSpeed, sizeof(currentSpeed)) ||
                !ReadBytes(node + PLAYER_RUN_SPEED, &runSpeed, sizeof(runSpeed)))
                return 0;
            return AsHundredths(coords[0], &out->x100) &&
                   AsHundredths(coords[1], &out->y100) &&
                   AsHundredths(coords[2], &out->z100) &&
                   AsHundredths(currentSpeed, &out->current100) &&
                   AsHundredths(runSpeed, &out->run100);
        }
        if (!ReadU32(node + OBJ_NEXT, &next) || next == node) return 0;
        node = next;
    }
    return 0;
}
static void AppendRow(DWORD tick, const char *event, int valid, const TaxiSample *s)
{
    HANDLE h;
    DWORD written, len;
    char line[256];
    if (!g_path[0]) return;
    len = (DWORD)wsprintfA(line, "%lu,%s,%u,%ld,%ld,%ld,%ld,%ld\r\n",
                          (unsigned long)tick, event, (unsigned)valid,
                          valid ? s->x100 : 0, valid ? s->y100 : 0,
                          valid ? s->z100 : 0, valid ? s->current100 : 0,
                          valid ? s->run100 : 0);
    h = CreateFileA(g_path, FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE,
                    NULL, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (h == INVALID_HANDLE_VALUE) return;
    WriteFile(h, line, len, &written, NULL);
    CloseHandle(h);
}
static void LogSample(DWORD now, const char *event)
{
    TaxiSample s = {0, 0, 0, 0, 0};
    int valid = SamplePlayer(&s);
    AppendRow(now, event, valid, &s);
}
static int PreparePath(void)
{
    char exe[MAX_PATH];
    char folder[MAX_PATH];
    DWORD size = GetModuleFileNameA(NULL, exe, MAX_PATH);
    int i;
    if (size == 0 || size >= MAX_PATH) return 0;
    i = (int)size - 1;
    while (i >= 0 && exe[i] != '\\' && exe[i] != '/') --i;
    if (i < 2 || i + 90 >= MAX_PATH) return 0;
    exe[i] = 0;
    lstrcpyA(folder, exe);
    lstrcatA(folder, "\\.wow112_debug");
    CreateDirectoryA(folder, NULL);
    wsprintfA(g_path, "%s\\taxi_probe_%lu_%lu.csv", folder,
              GetCurrentProcessId(), GetTickCount());
    return 1;
}
static int IsGameForeground(void)
{
    DWORD pid = 0;
    HWND hwnd = GetForegroundWindow();
    if (!hwnd) return 0;
    GetWindowThreadProcessId(hwnd, &pid);
    return pid == GetCurrentProcessId();
}
static DWORD WINAPI ProbeThread(LPVOID unused)
{
    int lastF8 = 0, lastF9 = 0;
    (void)unused;
    if (!PreparePath()) {
        InterlockedExchange(&g_status, 0);
        return 0;
    }
    {
        HANDLE h = CreateFileA(g_path, GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE,
                               NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
        if (h != INVALID_HANDLE_VALUE) {
            static const char header[] =
                "tick_ms,event,player_valid,x100,y100,z100,current_speed_x100,run_speed_x100\r\n";
            DWORD wrote;
            WriteFile(h, header, sizeof(header)-1, &wrote, NULL);
            CloseHandle(h);
        }
    }
    InterlockedExchange(&g_status, 1);
    LogSample(GetTickCount(), "PROBE_READY");
    while (!g_stop) {
        DWORD now;
        int f8, f9, modifiers;
        Sleep(80);
        if (!IsGameForeground()) {
            lastF8 = 0;
            lastF9 = 0;
            continue;
        }
        now = GetTickCount();
        f8 = (GetAsyncKeyState(VK_F8) & 0x8000) != 0;
        f9 = (GetAsyncKeyState(VK_F9) & 0x8000) != 0;
        modifiers = ((GetAsyncKeyState(VK_CONTROL) & 0x8000) != 0) &&
                    ((GetAsyncKeyState(VK_SHIFT) & 0x8000) != 0);
        if (modifiers && f8 && !lastF8 && !g_recording) {
            g_start_tick = now;
            g_last_sample = now;
            InterlockedExchange(&g_recording, 1);
            InterlockedExchange(&g_status, 2);
            LogSample(now, "MARK_START");
        }
        if (modifiers && f9 && !lastF9 && g_recording) {
            LogSample(now, "MARK_END");
            /* Duration is (MARK_END.tick_ms - MARK_START.tick_ms), modulo 2^32. */
            InterlockedExchange(&g_recording, 0);
            InterlockedExchange(&g_status, 1);
        }
        lastF8 = f8;
        lastF9 = f9;
        if (g_recording && (DWORD)(now - g_last_sample) >= 1000u) {
            g_last_sample = now;
            LogSample(now, "SAMPLE");
        }
    }
    InterlockedExchange(&g_status, 0);
    return 0;
}
__declspec(dllexport) DWORD __stdcall TaxiProbe_GetStatus(void)
{
    return (DWORD)g_status;
}
__declspec(dllexport) DWORD __stdcall TaxiProbe_GetStartTick(void)
{
    return g_start_tick;
}
BOOL WINAPI DllMain(HINSTANCE instance, DWORD reason, LPVOID reserved)
{
    (void)reserved;
    if (reason == DLL_PROCESS_ATTACH) {
        HANDLE thread;
        DisableThreadLibraryCalls(instance);
        InterlockedExchange(&g_stop, 0);
        thread = CreateThread(NULL, 0, ProbeThread, NULL, 0, NULL);
        if (!thread) return FALSE;
        CloseHandle(thread);
    } else if (reason == DLL_PROCESS_DETACH) {
        InterlockedExchange(&g_stop, 1);
        /* The game normally unloads this DLL during process teardown. */
    }
    return TRUE;
}
