#ifndef LNAKO_PLUGIN_V1_H
#define LNAKO_PLUGIN_V1_H

#include <stddef.h>
#include <stdint.h>

#if defined(_WIN32)
#define LNAKO_PLUGIN_EXPORT __declspec(dllexport)
#else
#define LNAKO_PLUGIN_EXPORT __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

#define LNAKO_PLUGIN_ABI_VERSION 1u

typedef struct lnako_value_v1 lnako_value_v1;
typedef struct lnako_host_v1 lnako_host_v1;
typedef struct lnako_registry_v1 lnako_registry_v1;

enum lnako_value_kind_v1 {
    LNAKO_VALUE_UNDEFINED = 0,
    LNAKO_VALUE_NULL = 1,
    LNAKO_VALUE_BOOLEAN = 2,
    LNAKO_VALUE_NUMBER = 3,
    LNAKO_VALUE_BIGINT = 4,
    LNAKO_VALUE_STRING = 5,
    LNAKO_VALUE_BYTES = 6,
    LNAKO_VALUE_ARRAY = 7,
    LNAKO_VALUE_DICTIONARY = 8,
    LNAKO_VALUE_FUNCTION = 9,
    LNAKO_VALUE_PROMISE = 10,
};

enum lnako_command_flags_v1 {
    LNAKO_COMMAND_SYNC = 1u << 0,
    LNAKO_COMMAND_ASYNC = 1u << 1,
    LNAKO_COMMAND_PURE = 1u << 2,
};

enum lnako_status_v1 {
    LNAKO_STATUS_OK = 0,
    LNAKO_STATUS_ERROR = 1,
    LNAKO_STATUS_PENDING = 2,
};

typedef int32_t (*lnako_command_invoke_v1)(
    void *command_context,
    const lnako_host_v1 *host,
    const lnako_value_v1 *const *arguments,
    size_t argument_count,
    uint64_t async_token,
    lnako_value_v1 **result);

typedef void (*lnako_command_destroy_v1)(void *command_context);

typedef struct lnako_command_v1 {
    uint32_t struct_size;
    uint32_t abi_version;
    uint32_t flags;
    const char *name;
    const char *particles;
    size_t minimum_arguments;
    size_t maximum_arguments;
    void *command_context;
    lnako_command_invoke_v1 invoke;
    lnako_command_destroy_v1 destroy;
} lnako_command_v1;

struct lnako_host_v1 {
    uint32_t struct_size;
    uint32_t abi_version;
    void *context;

    uint32_t (*value_kind)(void *context, const lnako_value_v1 *value);
    void (*value_retain)(void *context, lnako_value_v1 *value);
    void (*value_release)(void *context, lnako_value_v1 *value);

    lnako_value_v1 *(*make_undefined)(void *context);
    lnako_value_v1 *(*make_null)(void *context);
    lnako_value_v1 *(*make_boolean)(void *context, int value);
    lnako_value_v1 *(*make_number)(void *context, double value);
    lnako_value_v1 *(*make_bigint)(void *context, const char *decimal, size_t length);
    lnako_value_v1 *(*make_string)(void *context, const char *utf8, size_t length);
    lnako_value_v1 *(*make_bytes)(void *context, const uint8_t *bytes, size_t length);
    lnako_value_v1 *(*make_array)(void *context);
    lnako_value_v1 *(*make_dictionary)(void *context);

    int (*get_boolean)(void *context, const lnako_value_v1 *value, int *result);
    int (*get_number)(void *context, const lnako_value_v1 *value, double *result);
    /* STRING/BigInt only. The returned UTF-8 bytes live until value_release. */
    const char *(*get_utf8)(void *context, lnako_value_v1 *value, size_t *length);
    /* BYTES only. The returned bytes live until value_release. */
    const uint8_t *(*get_bytes)(void *context, const lnako_value_v1 *value, size_t *length);

    size_t (*array_length)(void *context, const lnako_value_v1 *array);
    lnako_value_v1 *(*array_get)(void *context, const lnako_value_v1 *array, size_t index);
    int (*array_push)(void *context, lnako_value_v1 *array, const lnako_value_v1 *value);
    lnako_value_v1 *(*dictionary_get)(void *context, const lnako_value_v1 *dictionary, const char *key, size_t key_length);
    int (*dictionary_set)(void *context, lnako_value_v1 *dictionary, const char *key, size_t key_length, const lnako_value_v1 *value);

    int32_t (*call_command)(void *context, const char *name, const lnako_value_v1 *const *arguments, size_t argument_count, lnako_value_v1 **result);
    int32_t (*call_function)(void *context, const lnako_value_v1 *function, const lnako_value_v1 *const *arguments, size_t argument_count, lnako_value_v1 **result);
    /* The only host callback that may be called from another thread. */
    int32_t (*complete_async)(void *context, uint64_t async_token, int32_t status, lnako_value_v1 *result);
};

struct lnako_registry_v1 {
    uint32_t struct_size;
    uint32_t abi_version;
    void *context;
    int32_t (*register_command)(void *context, const lnako_command_v1 *command);
};

typedef struct lnako_plugin_descriptor_v1 {
    uint32_t struct_size;
    uint32_t abi_version;
    const char *name;
    const char *version;
    void *plugin_context;
    int32_t (*initialize)(void *plugin_context, const lnako_host_v1 *host, const lnako_registry_v1 *registry);
    void (*deinitialize)(void *plugin_context);
} lnako_plugin_descriptor_v1;

typedef const lnako_plugin_descriptor_v1 *(*lnako_plugin_entry_v1)(void);

LNAKO_PLUGIN_EXPORT const lnako_plugin_descriptor_v1 *lnako_plugin_v1(void);

#ifdef __cplusplus
}
#endif

#endif
