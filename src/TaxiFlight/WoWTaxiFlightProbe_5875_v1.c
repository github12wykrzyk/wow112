/*
 * TaxiFlightProbe V3 (hotkey telemetry) - WoW 1.12.1 build 5875, Windows x86.
 *
 * Taxi measurement plus opt-in, SINGLE early native CMSG_MOVE_SPLINE_DONE.
 * The early ACK is only an experiment: its return value never establishes
 * server acceptance, and this module never spoofs or teleports coordinates.
 *
 * Numpad 1: mark departure after choosing a Flight Master destination.
 * Numpad 2: send one EARLY spline-done attempt for this marked trip.
 * Numpad 3: mark arrival once the character is controllable.
 * Num Lock must be ON; these keys do not require Ctrl or Shift.
 * The instant attempt is DISABLED except for that explicit hotkey.
 * Only when the game window is in the foreground. Use a visible non-activating
 * status toast + two diagnostic files (.csv and .jsonl) in .wow112_debug.
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
/* Byte-audited from the exact active 5875 EXE, SHA256 9a735271...ffd42a2. */
#define PLAYER_MOVEMENT_THIS_OFF 0x09A8u
#define MOVE_SPLINE_PTR_OFF 0x00A4u
#define MOVE_PLAYER_PTR_OFF 0x015Cu
#define SPLINE_FLAGS_OFF 0x18u
#define SPLINE_ELAPSED_OFF 0x20u
#define SPLINE_DURATION_OFF 0x24u
#define SPLINE_ID_OFF 0x28u
#define FN_NATIVE_SPLINE_DONE 0x00600B10u
#define FN_NATIVE_SPLINE_TICK 0x00619D40u
#define FN_FRAMESCRIPT_EXECUTE 0x00704CD0u
#define FN_FRAME_GET_TEXT 0x00703BF0u

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
static char g_json_path[MAX_PATH];
static HWND g_statusToast = NULL;
static DWORD g_statusHideAt = 0;
static LONG g_keyEvents = 0;
static volatile LONG g_instantPending = 0;
static volatile LONG g_instantAttempted = 0;
static DWORD g_instantScheduledAt = 0;
static UINT_PTR g_instantTimer = 0;
static HWND g_instantWindow = NULL;


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
    if (g_json_path[0]) {
        char json[320];
        DWORD jsonLen = (DWORD)wsprintfA(json,
            "{\"tick_ms\":%lu,\"module\":\"TaxiFlight\",\"event\":\"%s\",\"valid\":%u,"
            "\"x100\":%ld,\"y100\":%ld,\"z100\":%ld,"
            "\"current100\":%ld,\"run100\":%ld}\r\n",
            (unsigned long)tick, event, (unsigned)valid,
            valid ? s->x100 : 0, valid ? s->y100 : 0,
            valid ? s->z100 : 0, valid ? s->current100 : 0,
            valid ? s->run100 : 0);
        HANDLE jsonFile = CreateFileA(g_json_path, FILE_APPEND_DATA,
            FILE_SHARE_READ | FILE_SHARE_WRITE, NULL, OPEN_ALWAYS,
            FILE_ATTRIBUTE_NORMAL, NULL);
        if (jsonFile != INVALID_HANDLE_VALUE) {
            WriteFile(jsonFile, json, jsonLen, &written, NULL);
            CloseHandle(jsonFile);
        }
    }
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
    {
        DWORD t = GetTickCount();
        DWORD pid = GetCurrentProcessId();
        wsprintfA(g_path, "%s\\taxi_probe_%lu_%lu.csv", folder, pid, t);
        wsprintfA(g_json_path, "%s\\taxi_probe_%lu_%lu.jsonl", folder, pid, t);
    }
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

/*
 * Exact EXE disassembly:
 * 0x619D50 operates on player+0x9A8; it reads the spline pointer at
 * movement+0xA4. 0x619DE0 reads the player owner at movement+0x15C,
 * the spline ID at spline+0x28 and sends through 0x600B10.
 * 0x619D40 returns the same movement timestamp used at the native callsite.
 * This is a one-shot protocol experiment, NEVER an asserted teleport.
 */
static DWORD LocalPlayerObject(void)
{
    DWORD mgr, node, localLo, localHi, lo, hi, type, next;
    DWORD count;
    if ((DWORD)(ULONG_PTR)GetModuleHandleA(NULL) != 0x00400000u ||
        !ReadU32(OBJMGR_GLOBAL, &mgr) || mgr < 0x10000u ||
        !ReadU32(mgr + OM_LOCAL_GUID_LO, &localLo) ||
        !ReadU32(mgr + OM_LOCAL_GUID_HI, &localHi) ||
        (!localLo && !localHi) ||
        !ReadU32(mgr + OM_FIRST_OBJECT, &node)) return 0;
    for (count = 0; count < MAX_OBJECTS && node >= 0x10000u; ++count) {
        if (!ReadU32(node + OBJ_TYPE, &type) ||
            !ReadU32(node + OBJ_GUID_LO, &lo) ||
            !ReadU32(node + OBJ_GUID_HI, &hi)) return 0;
        if (type == TYPEID_PLAYER && lo == localLo && hi == localHi)
            return node;
        if (!ReadU32(node + OBJ_NEXT, &next) || next == node) return 0;
        node = next;
    }
    return 0;
}
static int BytesEqual(const BYTE *a, const BYTE *b, unsigned len)
{
    unsigned i;
    for (i = 0; i < len; ++i) if (a[i] != b[i]) return 0;
    return 1;
}
static int NativeSignaturesMatch(void)
{
    static const BYTE prologue[] = {0x55,0x8B,0xEC,0x83,0xEC,0x18,0x53,0x8B,0x5D,0x08};
    static const BYTE opcode[] = {0x68,0xC9,0x02,0x00,0x00};
    static const BYTE tick[] = {0xE8,0xFB,0x6C,0x01,0x00,0x8B,0x80,0x2C,0x01};
    BYTE actual[sizeof(prologue)];
    if (!ReadBytes(FN_NATIVE_SPLINE_DONE, actual, sizeof(prologue))) return 0;
    if (!BytesEqual(actual, prologue, sizeof(prologue))) return 0;
    if (!ReadBytes(FN_NATIVE_SPLINE_DONE+0x14u, actual, sizeof(opcode))) return 0;
    if (!BytesEqual(actual, opcode, sizeof(opcode))) return 0;
    if (!ReadBytes(FN_NATIVE_SPLINE_TICK, actual, sizeof(tick))) return 0;
    return BytesEqual(actual, tick, sizeof(tick));
}
static void ExecuteLua(const char *script)
{
    DWORD fn = FN_FRAMESCRIPT_EXECUTE;
    if (!script) return;
    /* Exact calling pattern used in canonical MovementCore 5875 source. */
    __asm {
        push ebx
        mov ecx, script
        mov edx, script
        xor eax, eax
        mov ebx, fn
        call ebx
        pop ebx
    }
}
static int ServerTaxiStateReportedByLua(void)
{
    typedef const char *(__fastcall *GetLuaTextFn)(const char *, int, DWORD);
    const char *result;
    static const char script[] =
        "W112_TAXI_ON=(UnitOnTaxi and UnitOnTaxi('player')) and '1' or '0'";
    ExecuteLua(script);
    result = ((GetLuaTextFn)FN_FRAME_GET_TEXT)("W112_TAXI_ON", -1, 0u);
    return result && result[0] == '1' && result[1] == 0;
}
static void CALLBACK InstantTimerProc(HWND hwnd, UINT message, UINT_PTR id, DWORD ignored)
{
    DWORD player, movement, owner, spline, flags, elapsed, duration, splineId;
    DWORD timestamp;
    typedef DWORD (__cdecl *NativeTickFn)(void);
    typedef int (__thiscall *NativeDoneFn)(void *, DWORD, DWORD, float);
    int clientResult;
    (void)message; (void)ignored;
    KillTimer(hwnd, id);
    g_instantTimer = 0;
    if (InterlockedCompareExchange(&g_instantPending, 0, 1) != 1) return;
    if (g_stop || !IsGameForeground() || !g_recording ||
        (DWORD)(GetTickCount() - g_start_tick) < 2000u) {
        LogSample(GetTickCount(), "EARLY_ACK_ABORT_NOT_READY");
        return;
    }
    if (!NativeSignaturesMatch()) {
        LogSample(GetTickCount(), "EARLY_ACK_ABORT_EXE_SIGNATURE");
        return;
    }
    if (!ServerTaxiStateReportedByLua()) {
        LogSample(GetTickCount(), "EARLY_ACK_ABORT_NOT_ON_TAXI");
        return;
    }
    player = LocalPlayerObject();
    if (!player) {
        LogSample(GetTickCount(), "EARLY_ACK_ABORT_PLAYER_INVALID");
        return;
    }
    movement = player + PLAYER_MOVEMENT_THIS_OFF;
    if (!ReadU32(movement + MOVE_PLAYER_PTR_OFF, &owner) ||
        owner != player || !ReadU32(movement + MOVE_SPLINE_PTR_OFF, &spline) ||
        spline < 0x10000u || !ReadU32(spline + SPLINE_FLAGS_OFF, &flags) ||
        !ReadU32(spline + SPLINE_ELAPSED_OFF, &elapsed) ||
        !ReadU32(spline + SPLINE_DURATION_OFF, &duration) ||
        !ReadU32(spline + SPLINE_ID_OFF, &splineId) ||
        (flags & 4u) || duration < 2000u || duration > 1200000u ||
        elapsed < 1000u || elapsed >= duration || splineId == 0u) {
        LogSample(GetTickCount(), "EARLY_ACK_ABORT_SPLINE_INVALID");
        return;
    }
    /* Do NOT edit elapsed time, flight path, position, mount, or client flags.
     * Server behavior is unknown. One native packet only, with CURRENT
     * movementInfo and splineId. Caller must confirm whether server accepted. */
    LogSample(GetTickCount(), "EARLY_ACK_BEFORE_SEND");
    timestamp = ((NativeTickFn)FN_NATIVE_SPLINE_TICK)();
    clientResult = ((NativeDoneFn)FN_NATIVE_SPLINE_DONE)(
        (void *)(ULONG_PTR)player, timestamp, splineId, 1.0f);
    LogSample(GetTickCount(), clientResult ?
              "EARLY_ACK_CLIENT_SEND_OK_NOT_SERVER_ACK" :
              "EARLY_ACK_CLIENT_SEND_FAILED");
}


/* This is an auxiliary Windows status toast, not an in-engine UI overlay.
 * Exclusive fullscreen can hide it; CSV/JSONL diagnostics are authoritative.
 * Creating it on the probe thread avoids calling WoW UI functions off-thread. */
static void TaxiToast(const char *message, DWORD now)
{
    if (!g_statusToast) return;
    SetWindowTextA(g_statusToast, message);
    SetWindowPos(g_statusToast, HWND_TOPMOST, 24, 56, 550, 42,
                 SWP_NOACTIVATE | SWP_SHOWWINDOW);
    g_statusHideAt = now + 5500u;
}
static void TaxiToastInit(void)
{
    g_statusToast = CreateWindowExA(
        WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE,
        "STATIC", "TaxiFlight: gotowy", WS_POPUP | WS_BORDER | SS_CENTER,
        24, 56, 550, 42, NULL, NULL, GetModuleHandleA(NULL), NULL);
}
static void TaxiToastTick(DWORD now)
{
    MSG msg;
    if (!g_statusToast) return;
    while (PeekMessageA(&msg, g_statusToast, 0, 0, PM_REMOVE)) {
        TranslateMessage(&msg);
        DispatchMessageA(&msg);
    }
    if (g_statusHideAt && (LONG)(now - g_statusHideAt) >= 0) {
        ShowWindow(g_statusToast, SW_HIDE);
        g_statusHideAt = 0;
    }
}
static DWORD WINAPI ProbeThread(LPVOID unused)
{
    int lastStart = 0, lastEnd = 0, lastInstant = 0;
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
    TaxiToastInit();
    LogSample(GetTickCount(), "PROBE_READY");
    TaxiToast("TaxiFlight READY | Num1 START | Num2 TEST | Num3 END", GetTickCount());
    while (!g_stop) {
        DWORD now;
        int keyStart, keyEnd, keyInstant, startCombo, endCombo, instantCombo;
        Sleep(15);
        now = GetTickCount();
        TaxiToastTick(now);
        if (!IsGameForeground()) {
            lastStart = 0;
            lastEnd = 0;
            lastInstant = 0;
            continue;
        }
        now = GetTickCount();
        /* VK_NUMPADn requires Num Lock ON; no modifier key is necessary.
         * Record each physical key edge independently of whether a taxi trip
         * is marked, so reports distinguish hotkey detection from taxi logic. */
        keyStart = (GetAsyncKeyState(VK_NUMPAD1) & 0x8000) != 0;
        keyInstant = (GetAsyncKeyState(VK_NUMPAD2) & 0x8000) != 0;
        keyEnd = (GetAsyncKeyState(VK_NUMPAD3) & 0x8000) != 0;
        startCombo = keyStart;
        endCombo = keyEnd;
        instantCombo = keyInstant;
        if (startCombo && !lastStart) LogSample(now, "NUMPAD1_KEY_DETECTED");
        if (instantCombo && !lastInstant) LogSample(now, "NUMPAD2_KEY_DETECTED");
        if (endCombo && !lastEnd) LogSample(now, "NUMPAD3_KEY_DETECTED");
        if (startCombo && !lastStart && !g_recording) {
            InterlockedExchange(&g_instantAttempted, 0);
            g_start_tick = now;
            g_last_sample = now;
            InterlockedExchange(&g_recording, 1);
            InterlockedExchange(&g_status, 2);
            LogSample(now, "MARK_START");
            TaxiToast("TaxiFlight START | press Num2 after at least 2 sec", now);
            MessageBeep(MB_OK);
        } else if (startCombo && !lastStart) {
            LogSample(now, "MARK_START_IGNORED_ALREADY_RECORDING");
            TaxiToast("TaxiFlight already recording", now);
        }
        if (endCombo && !lastEnd && g_recording) {
            LogSample(now, "MARK_END");
            /* Duration is (MARK_END.tick_ms - MARK_START.tick_ms), modulo 2^32. */
            InterlockedExchange(&g_recording, 0);
            InterlockedExchange(&g_status, 1);
            TaxiToast("TaxiFlight END registered | flight measurement saved", now);
            MessageBeep(MB_OK);
        } else if (endCombo && !lastEnd) {
            LogSample(now, "MARK_END_IGNORED_NOT_RECORDING");
            TaxiToast("TaxiFlight end ignored: start first", now);
        }
        if (instantCombo && !lastInstant && !g_recording) {
            LogSample(now, "EARLY_ACK_IGNORED_NOT_RECORDING");
            TaxiToast("TaxiFlight instant ignored: start with Num1", now);
            MessageBeep(MB_ICONEXCLAMATION);
        } else if (instantCombo && !lastInstant &&
                   (DWORD)(now - g_start_tick) < 2000u) {
            LogSample(now, "EARLY_ACK_IGNORED_WAIT_TWO_SECONDS");
            TaxiToast("TaxiFlight instant: wait 2 seconds after start", now);
        }
        if (instantCombo && !lastInstant && g_recording &&
            (DWORD)(now - g_start_tick) >= 2000u &&
            InterlockedCompareExchange(&g_instantAttempted, 1, 0) == 0) {
            HWND hwnd = GetForegroundWindow();
            DWORD pid = 0;
            GetWindowThreadProcessId(hwnd, &pid);
            if (hwnd && pid == GetCurrentProcessId() &&
                InterlockedCompareExchange(&g_instantPending, 1, 0) == 0) {
                g_instantWindow = hwnd;
                g_instantScheduledAt = now;
                g_instantTimer = SetTimer(hwnd, 0u, 70u, InstantTimerProc);
                LogSample(now, g_instantTimer ?
                          "EARLY_ACK_SCHEDULED" : "EARLY_ACK_TIMER_FAILED");
                TaxiToast(g_instantTimer ?
                          "TaxiFlight hotkey OK | instant attempt scheduled" :
                          "TaxiFlight hotkey OK | native timer failed", now);
                MessageBeep(g_instantTimer ? MB_OK : MB_ICONEXCLAMATION);
                if (!g_instantTimer)
                    InterlockedExchange(&g_instantPending, 0);
            } else {
                LogSample(now, "EARLY_ACK_ABORT_NO_GAME_WINDOW");
                TaxiToast("TaxiFlight instant rejected: game window unavailable", now);
            }
        } else if (instantCombo && !lastInstant && g_recording &&
                   (DWORD)(now - g_start_tick) >= 2000u) {
            LogSample(now, "EARLY_ACK_IGNORED_ALREADY_ATTEMPTED");
            TaxiToast("TaxiFlight instant limited to one try per flight", now);
        }
        lastStart = startCombo;
        lastEnd = endCombo;
        lastInstant = instantCombo;
        if (g_instantPending && (DWORD)(now - g_instantScheduledAt) >= 2500u &&
            InterlockedCompareExchange(&g_instantPending, 0, 1) == 1) {
            if (g_instantTimer) KillTimer(g_instantWindow, g_instantTimer);
            g_instantTimer = 0;
            LogSample(now, "EARLY_ACK_TIMER_TIMEOUT");
            TaxiToast("TaxiFlight instant timer timed out; see report", now);
        }
        if (g_recording && (DWORD)(now - g_last_sample) >= 1000u) {
            g_last_sample = now;
            LogSample(now, "SAMPLE");
        }
    }
    if (g_statusToast) DestroyWindow(g_statusToast);
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
