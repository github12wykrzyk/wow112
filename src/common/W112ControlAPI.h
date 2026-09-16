#ifndef W112_CONTROL_API_V1_H
#define W112_CONTROL_API_V1_H

/*
 * Shared configuration ABI for WoW 1.12.1 build 5875 x86 modules.
 * The hub never writes module-private memory directly. Every runtime read/write
 * goes through the module's explicit get/set callbacks.
 */

#if defined(_MSC_VER)
#define W112_CTL_STDCALL __stdcall
#define W112_CTL_EXPORT __declspec(dllexport)
#else
#define W112_CTL_STDCALL __attribute__((stdcall))
#define W112_CTL_EXPORT __attribute__((dllexport))
#endif

typedef unsigned int w112_u32;
typedef signed int   w112_i32;
typedef int          BOOL;

#define W112_CONTROL_API_V1 0x00010000u

enum W112_ControlSettingTypeV1 {
    W112_CTL_BOOL  = 1u,
    W112_CTL_INT   = 2u,
    W112_CTL_FLOAT = 3u,
    W112_CTL_ENUM  = 4u
};

enum W112_ControlSettingFlagsV1 {
    W112_CTL_LIVE            = 0x00000001u,
    W112_CTL_REQUIRES_RELOAD = 0x00000002u,
    W112_CTL_READ_ONLY       = 0x00000004u
};

typedef union W112_ControlValueV1 {
    w112_i32 i32;
    w112_u32 u32;
    float    f32;
} W112_ControlValueV1;

typedef struct W112_ControlEnumOptionV1 {
    w112_i32 value;
    const char *label;
} W112_ControlEnumOptionV1;

typedef struct W112_ControlSettingV1 {
    w112_u32 struct_size;
    w112_u32 setting_id;
    const char *key;
    const char *label;
    w112_u32 type;
    W112_ControlValueV1 default_value;
    W112_ControlValueV1 min_value;
    W112_ControlValueV1 max_value;
    W112_ControlValueV1 step;
    w112_u32 flags;
    const W112_ControlEnumOptionV1 *enum_options;
    w112_u32 enum_option_count;
} W112_ControlSettingV1;

typedef int (W112_CTL_STDCALL *W112_ControlGetValueV1)(
    w112_u32 setting_id,
    W112_ControlValueV1 *out_value);

typedef int (W112_CTL_STDCALL *W112_ControlSetValueV1)(
    w112_u32 setting_id,
    const W112_ControlValueV1 *value);

typedef struct W112_ControlModuleV1 {
    w112_u32 abi_version;
    w112_u32 struct_size;
    const char *module_id;
    const char *module_name;
    w112_u32 module_version;
    w112_u32 setting_count;
    const W112_ControlSettingV1 *settings;
    W112_ControlGetValueV1 get_value;
    W112_ControlSetValueV1 set_value;
} W112_ControlModuleV1;

typedef const W112_ControlModuleV1 *
    (W112_CTL_STDCALL *W112_ControlGetModuleV1Fn)(void);

#endif /* W112_CONTROL_API_V1_H */
