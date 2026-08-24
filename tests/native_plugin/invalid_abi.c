#include "lnako_plugin_v1.h"

static const lnako_plugin_descriptor_v1 descriptor = {
    sizeof(lnako_plugin_descriptor_v1),
    LNAKO_PLUGIN_ABI_VERSION + 1,
    "lnako invalid ABI fixture",
    "1.0.0",
    NULL,
    NULL,
    NULL,
};

LNAKO_PLUGIN_EXPORT const lnako_plugin_descriptor_v1 *lnako_plugin_v1(void) {
    return &descriptor;
}
