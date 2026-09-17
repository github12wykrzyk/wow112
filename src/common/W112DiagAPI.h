#ifndef W112_DIAG_API_H
#define W112_DIAG_API_H

#include <windows.h>

#define W112_DIAG_API_VERSION 1u
#define W112_DIAG_LEVEL_TRACE 0u
#define W112_DIAG_LEVEL_INFO  1u
#define W112_DIAG_LEVEL_WARN  2u
#define W112_DIAG_LEVEL_ERROR 3u

typedef int (__cdecl *W112DiagWriteEventFn)(
    const char *module,
    const char *event_name,
    unsigned level,
    long value_a,
    long value_b,
    const char *text);

typedef int (__cdecl *W112DiagSnapshotFn)(const char *reason);
typedef int (__cdecl *W112DiagGetSessionPathFn)(char *out_path, unsigned out_size);

typedef struct W112DiagApiV1 {
    unsigned cb_size;
    unsigned api_version;
    W112DiagWriteEventFn write_event;
    W112DiagSnapshotFn snapshot;
    W112DiagGetSessionPathFn get_session_path;
} W112DiagApiV1;

typedef const W112DiagApiV1 *(__cdecl *W112DiagGetApiV1Fn)(void);

static __inline const W112DiagApiV1 *W112DiagResolveV1(void)
{
    HMODULE module = GetModuleHandleA("WoWDiagHub.dll");
    W112DiagGetApiV1Fn get_api;
    if (!module) return 0;
    get_api = (W112DiagGetApiV1Fn)GetProcAddress(module, "W112_DIAG_API_V1_Get");
    if (!get_api) return 0;
    return get_api();
}

#endif
