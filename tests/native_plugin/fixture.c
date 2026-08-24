#include "lnako_plugin_v1.h"

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#if defined(_WIN32)
#include <windows.h>
#else
#include <pthread.h>
#include <time.h>
#endif

typedef struct async_payload {
    const lnako_host_v1 *host;
    uint64_t token;
    lnako_value_v1 *value;
} async_payload;

typedef struct fixture_context {
#if defined(_WIN32)
    HANDLE worker;
#else
    pthread_t worker;
    int worker_started;
#endif
} fixture_context;

static fixture_context fixture = {0};

static void finish_async(async_payload *payload) {
    (void)payload->host->complete_async(payload->host->context, payload->token,
                                        LNAKO_STATUS_OK, payload->value);
    free(payload);
}

#if defined(_WIN32)
static DWORD WINAPI async_worker(LPVOID opaque) {
    Sleep(5);
    finish_async((async_payload *)opaque);
    return 0;
}
#else
static void *async_worker(void *opaque) {
    const struct timespec delay = {0, 5 * 1000 * 1000};
    nanosleep(&delay, NULL);
    finish_async((async_payload *)opaque);
    return NULL;
}
#endif

static int32_t add_numbers(void *context, const lnako_host_v1 *host,
                           const lnako_value_v1 *const *arguments, size_t count,
                           uint64_t token, lnako_value_v1 **result) {
    double left = 0;
    double right = 0;
    (void)context;
    (void)token;
    if (count != 2 || host->get_number(host->context, arguments[0], &left) != 0 ||
        host->get_number(host->context, arguments[1], &right) != 0)
        return LNAKO_STATUS_ERROR;
    *result = host->make_number(host->context, left + right);
    return *result ? LNAKO_STATUS_OK : LNAKO_STATUS_ERROR;
}

static int32_t make_array(void *context, const lnako_host_v1 *host,
                          const lnako_value_v1 *const *arguments, size_t count,
                          uint64_t token, lnako_value_v1 **result) {
    static const char suffix[] = "native";
    const char *source;
    size_t source_length = 0;
    size_t suffix_length = 0;
    lnako_value_v1 *array = NULL;
    lnako_value_v1 *input = NULL;
    lnako_value_v1 *text = NULL;
    lnako_value_v1 *first = NULL;
    lnako_value_v1 *second = NULL;
    int32_t status = LNAKO_STATUS_ERROR;
    (void)context;
    (void)token;
    if (count != 1) return LNAKO_STATUS_ERROR;
    source = host->get_utf8(host->context, (lnako_value_v1 *)arguments[0], &source_length);
    if (!source) return LNAKO_STATUS_ERROR;
    array = host->make_array(host->context);
    input = host->make_string(host->context, source, source_length);
    text = host->make_string(host->context, suffix, sizeof(suffix) - 1);
    if (!array || !input || !text ||
        host->value_kind(host->context, array) != LNAKO_VALUE_ARRAY ||
        host->array_push(host->context, array, input) != 0 ||
        host->array_push(host->context, array, text) != 0) {
        goto done;
    }
    host->value_retain(host->context, input);
    host->value_release(host->context, input);
    if (host->array_length(host->context, array) != 2) goto done;
    first = host->array_get(host->context, array, 0);
    second = host->array_get(host->context, array, 1);
    if (!first || !second || host->value_kind(host->context, first) != LNAKO_VALUE_STRING ||
        host->value_kind(host->context, second) != LNAKO_VALUE_STRING ||
        host->get_utf8(host->context, second, &suffix_length) == NULL ||
        suffix_length != sizeof(suffix) - 1) {
        goto done;
    }
    *result = array;
    array = NULL;
    status = LNAKO_STATUS_OK;
done:
    if (array) host->value_release(host->context, array);
    if (input) host->value_release(host->context, input);
    if (text) host->value_release(host->context, text);
    if (first) host->value_release(host->context, first);
    if (second) host->value_release(host->context, second);
    return status;
}

static int32_t call_json(void *context, const lnako_host_v1 *host,
                         const lnako_value_v1 *const *arguments, size_t count,
                         uint64_t token, lnako_value_v1 **result) {
    (void)context;
    (void)token;
    if (count != 1) return LNAKO_STATUS_ERROR;
    return host->call_command(host->context, "JSON変換", arguments, count, result);
}

static int32_t call_callback(void *context, const lnako_host_v1 *host,
                             const lnako_value_v1 *const *arguments, size_t count,
                             uint64_t token, lnako_value_v1 **result) {
    (void)context;
    (void)token;
    if (count != 2) return LNAKO_STATUS_ERROR;
    return host->call_function(host->context, arguments[0], arguments + 1, 1, result);
}

static int32_t complete_async(void *context, const lnako_host_v1 *host,
                              const lnako_value_v1 *const *arguments, size_t count,
                              uint64_t token, lnako_value_v1 **result) {
    lnako_value_v1 *value;
    async_payload *payload;
    (void)context;
    (void)arguments;
    (void)result;
    if (count != 0 || token == 0) return LNAKO_STATUS_ERROR;
    value = host->make_number(host->context, 42);
    payload = (async_payload *)malloc(sizeof(*payload));
    if (!value || !payload) {
        if (value) host->value_release(host->context, value);
        free(payload);
        return LNAKO_STATUS_ERROR;
    }
    payload->host = host;
    payload->token = token;
    payload->value = value;
#if defined(_WIN32)
    {
        if (fixture.worker) {
            host->value_release(host->context, value);
            free(payload);
            return LNAKO_STATUS_ERROR;
        }
        fixture.worker = CreateThread(NULL, 0, async_worker, payload, 0, NULL);
        if (!fixture.worker) {
            host->value_release(host->context, value);
            free(payload);
            return LNAKO_STATUS_ERROR;
        }
    }
#else
    {
        if (fixture.worker_started) {
            host->value_release(host->context, value);
            free(payload);
            return LNAKO_STATUS_ERROR;
        }
        if (pthread_create(&fixture.worker, NULL, async_worker, payload) != 0) {
            host->value_release(host->context, value);
            free(payload);
            return LNAKO_STATUS_ERROR;
        }
        fixture.worker_started = 1;
    }
#endif
    return LNAKO_STATUS_PENDING;
}

static int32_t complete_immediately(void *context, const lnako_host_v1 *host,
                                    const lnako_value_v1 *const *arguments, size_t count,
                                    uint64_t token, lnako_value_v1 **result) {
    lnako_value_v1 *value;
    (void)context;
    (void)arguments;
    (void)result;
    if (count != 0 || token == 0) return LNAKO_STATUS_ERROR;
    value = host->make_number(host->context, 43);
    if (!value) return LNAKO_STATUS_ERROR;
    if (host->complete_async(host->context, token, LNAKO_STATUS_OK, value) != 0) {
        host->value_release(host->context, value);
        return LNAKO_STATUS_ERROR;
    }
    return LNAKO_STATUS_PENDING;
}

static int32_t reject_immediately(void *context, const lnako_host_v1 *host,
                                  const lnako_value_v1 *const *arguments, size_t count,
                                  uint64_t token, lnako_value_v1 **result) {
    static const char message[] = "native failure";
    lnako_value_v1 *value;
    (void)context;
    (void)arguments;
    (void)result;
    if (count != 0 || token == 0) return LNAKO_STATUS_ERROR;
    value = host->make_string(host->context, message, sizeof(message) - 1);
    if (!value) return LNAKO_STATUS_ERROR;
    if (host->complete_async(host->context, token, LNAKO_STATUS_ERROR, value) != 0) {
        host->value_release(host->context, value);
        return LNAKO_STATUS_ERROR;
    }
    return LNAKO_STATUS_PENDING;
}

static int32_t make_values(void *context, const lnako_host_v1 *host,
                           const lnako_value_v1 *const *arguments, size_t count,
                           uint64_t token, lnako_value_v1 **result) {
    static const char bigint[] = "123456789012345678901234567890";
    static const uint8_t bytes[] = {65, 66, 67};
    const char *big_text;
    const uint8_t *byte_text;
    size_t big_length = 0;
    size_t byte_length = 0;
    int boolean_value = 0;
    lnako_value_v1 *dictionary = NULL;
    lnako_value_v1 *big = NULL;
    lnako_value_v1 *buffer = NULL;
    lnako_value_v1 *boolean = NULL;
    lnako_value_v1 *null_value = NULL;
    lnako_value_v1 *undefined = NULL;
    lnako_value_v1 *probe = NULL;
    int32_t status = LNAKO_STATUS_ERROR;
    (void)context;
    (void)arguments;
    (void)token;
    if (count != 0) return LNAKO_STATUS_ERROR;
    dictionary = host->make_dictionary(host->context);
    big = host->make_bigint(host->context, bigint, sizeof(bigint) - 1);
    buffer = host->make_bytes(host->context, bytes, sizeof(bytes));
    boolean = host->make_boolean(host->context, 1);
    null_value = host->make_null(host->context);
    undefined = host->make_undefined(host->context);
    if (!dictionary || !big || !buffer || !boolean || !null_value || !undefined ||
        host->value_kind(host->context, dictionary) != LNAKO_VALUE_DICTIONARY ||
        host->value_kind(host->context, big) != LNAKO_VALUE_BIGINT ||
        host->value_kind(host->context, buffer) != LNAKO_VALUE_BYTES ||
        host->value_kind(host->context, boolean) != LNAKO_VALUE_BOOLEAN ||
        host->value_kind(host->context, null_value) != LNAKO_VALUE_NULL ||
        host->value_kind(host->context, undefined) != LNAKO_VALUE_UNDEFINED ||
        host->get_boolean(host->context, boolean, &boolean_value) != 0 || !boolean_value ||
        host->dictionary_set(host->context, dictionary, "big", 3, big) != 0 ||
        host->dictionary_set(host->context, dictionary, "bytes", 5, buffer) != 0 ||
        host->dictionary_set(host->context, dictionary, "flag", 4, boolean) != 0 ||
        host->dictionary_set(host->context, dictionary, "null", 4, null_value) != 0 ||
        host->dictionary_set(host->context, dictionary, "undefined", 9, undefined) != 0) {
        goto done;
    }
    big_text = host->get_utf8(host->context, big, &big_length);
    byte_text = host->get_bytes(host->context, buffer, &byte_length);
    if (!big_text || big_length != sizeof(bigint) - 1 ||
        memcmp(big_text, bigint, big_length) != 0 || !byte_text ||
        byte_length != sizeof(bytes) || memcmp(byte_text, bytes, byte_length) != 0 ||
        host->get_utf8(host->context, dictionary, NULL) != NULL) {
        goto done;
    }
    probe = host->dictionary_get(host->context, dictionary, "flag", 4);
    if (!probe || host->get_boolean(host->context, probe, &boolean_value) != 0 || !boolean_value) goto done;
    *result = dictionary;
    dictionary = NULL;
    status = LNAKO_STATUS_OK;
done:
    if (dictionary) host->value_release(host->context, dictionary);
    if (big) host->value_release(host->context, big);
    if (buffer) host->value_release(host->context, buffer);
    if (boolean) host->value_release(host->context, boolean);
    if (null_value) host->value_release(host->context, null_value);
    if (undefined) host->value_release(host->context, undefined);
    if (probe) host->value_release(host->context, probe);
    return status;
}

#define COMMAND(NAME, PARTICLES, FLAGS, MINIMUM, MAXIMUM, INVOKE) \
    { sizeof(lnako_command_v1), LNAKO_PLUGIN_ABI_VERSION, FLAGS, NAME, PARTICLES, MINIMUM, MAXIMUM, NULL, INVOKE, NULL }

static const lnako_command_v1 commands[] = {
    COMMAND("ネイティブ加算", "AとBを", LNAKO_COMMAND_SYNC | LNAKO_COMMAND_PURE, 2, 2, add_numbers),
    COMMAND("ネイティブ配列", "Vを", LNAKO_COMMAND_SYNC, 1, 1, make_array),
    COMMAND("ネイティブホスト呼出", "Vを", LNAKO_COMMAND_SYNC, 1, 1, call_json),
    COMMAND("ネイティブ関数呼出", "FでVを", LNAKO_COMMAND_SYNC, 2, 2, call_callback),
    COMMAND("ネイティブ非同期", "", LNAKO_COMMAND_ASYNC, 0, 0, complete_async),
    COMMAND("ネイティブ即時非同期", "", LNAKO_COMMAND_ASYNC, 0, 0, complete_immediately),
    COMMAND("ネイティブ非同期失敗", "", LNAKO_COMMAND_ASYNC, 0, 0, reject_immediately),
    COMMAND("ネイティブ値生成", "", LNAKO_COMMAND_SYNC | LNAKO_COMMAND_PURE, 0, 0, make_values),
};

static int32_t initialize(void *context, const lnako_host_v1 *host,
                          const lnako_registry_v1 *registry) {
    size_t index;
    (void)context;
    if (!host || !registry || host->struct_size < sizeof(lnako_host_v1) ||
        registry->struct_size < sizeof(lnako_registry_v1) ||
        host->abi_version != LNAKO_PLUGIN_ABI_VERSION ||
        registry->abi_version != LNAKO_PLUGIN_ABI_VERSION)
        return LNAKO_STATUS_ERROR;
    for (index = 0; index < sizeof(commands) / sizeof(commands[0]); index++)
        if (registry->register_command(registry->context, &commands[index]) != 0)
            return LNAKO_STATUS_ERROR;
    return LNAKO_STATUS_OK;
}

static void deinitialize(void *context) {
    fixture_context *state = (fixture_context *)context;
#if defined(_WIN32)
    if (state->worker) {
        WaitForSingleObject(state->worker, INFINITE);
        CloseHandle(state->worker);
        state->worker = NULL;
    }
#else
    if (state->worker_started) {
        pthread_join(state->worker, NULL);
        state->worker_started = 0;
    }
#endif
}

static const lnako_plugin_descriptor_v1 descriptor = {
    sizeof(lnako_plugin_descriptor_v1),
    LNAKO_PLUGIN_ABI_VERSION,
    "lnako ABI fixture",
    "1.0.0",
    &fixture,
    initialize,
    deinitialize,
};

LNAKO_PLUGIN_EXPORT const lnako_plugin_descriptor_v1 *lnako_plugin_v1(void) {
    return &descriptor;
}
