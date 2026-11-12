/* private 共有ライブラリへ依存する native plugin の fixture（Issue #56）。
 *
 * `helper.c` の `lnako_dependency_double` を呼ぶ。plugin 単体では移動後に
 * 依存が解決できないため、`build --bundle-deps` が依存を payload へ複製し、
 * plugin を開く前に先読みすることで移動後も動くことを検証する。 */
#include "lnako_plugin_v1.h"

#include <stdint.h>
#include <string.h>

extern int32_t lnako_dependency_double(int32_t value);

static int32_t add_via_dependency(void *context, const lnako_host_v1 *host,
                                  const lnako_value_v1 *const *arguments, size_t count,
                                  uint64_t token, lnako_value_v1 **result) {
    double left = 0;
    double right = 0;
    (void)context;
    (void)token;
    if (count != 2 || host->get_number(host->context, arguments[0], &left) != 0 ||
        host->get_number(host->context, arguments[1], &right) != 0)
        return LNAKO_STATUS_ERROR;
    *result = host->make_number(host->context,
                                (double)lnako_dependency_double((int32_t)left) + right);
    return LNAKO_STATUS_OK;
}

static const lnako_command_v1 commands[] = {
    { sizeof(lnako_command_v1), LNAKO_PLUGIN_ABI_VERSION,
      LNAKO_COMMAND_SYNC | LNAKO_COMMAND_PURE, "依存経由加算", "AとBを",
      2, 2, NULL, add_via_dependency, NULL },
};

static int32_t initialize(void *context, const lnako_host_v1 *host,
                          const lnako_registry_v1 *registry) {
    (void)context;
    if (!host || !registry || host->struct_size < sizeof(lnako_host_v1) ||
        registry->struct_size < sizeof(lnako_registry_v1) ||
        host->abi_version != LNAKO_PLUGIN_ABI_VERSION ||
        registry->abi_version != LNAKO_PLUGIN_ABI_VERSION)
        return LNAKO_STATUS_ERROR;
    if (registry->register_command(registry->context, &commands[0]) != 0)
        return LNAKO_STATUS_ERROR;
    return LNAKO_STATUS_OK;
}

static void deinitialize(void *context) { (void)context; }

static const lnako_plugin_descriptor_v1 descriptor = {
    sizeof(lnako_plugin_descriptor_v1),
    LNAKO_PLUGIN_ABI_VERSION,
    "lnako dependency fixture",
    "1.0.0",
    NULL,
    initialize,
    deinitialize,
};

LNAKO_PLUGIN_EXPORT const lnako_plugin_descriptor_v1 *lnako_plugin_v1(void) {
    return &descriptor;
}
