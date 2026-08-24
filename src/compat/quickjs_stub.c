#include "quickjs_bridge.h"

LnakoQuickJs *lnako_qjs_new(void) { return 0; }
void lnako_qjs_set_host(LnakoQuickJs *engine, void *opaque, LnakoQuickJsHostGet get, LnakoQuickJsHostSet set, LnakoQuickJsHostInvoke invoke, LnakoQuickJsHostExec exec) { (void)engine; (void)opaque; (void)get; (void)set; (void)invoke; (void)exec; }
int lnako_qjs_add_module_source(LnakoQuickJs *engine, const char *name, const char *source, size_t length) { (void)engine; (void)name; (void)source; (void)length; return -1; }
void lnako_qjs_retain(LnakoQuickJs *engine) { (void)engine; }
void lnako_qjs_release(LnakoQuickJs *engine) { (void)engine; }
char *lnako_qjs_take_error(LnakoQuickJs *engine) { (void)engine; return 0; }
void lnako_qjs_free_string(char *text) { (void)text; }
LnakoQuickJsValue *lnako_qjs_eval(LnakoQuickJs *engine, const char *source, size_t length, const char *filename) { (void)engine; (void)source; (void)length; (void)filename; return 0; }
LnakoQuickJsValue *lnako_qjs_eval_module(LnakoQuickJs *engine, const char *source, size_t length, const char *filename) { (void)engine; (void)source; (void)length; (void)filename; return 0; }
LnakoQuickJsValue *lnako_qjs_global(LnakoQuickJs *engine, const char *name) { (void)engine; (void)name; return 0; }
LnakoQuickJsValue *lnako_qjs_call(LnakoQuickJs *engine, const LnakoQuickJsValue *function, const LnakoQuickJsValue *const *arguments, size_t count) { (void)engine; (void)function; (void)arguments; (void)count; return 0; }
LnakoQuickJsValue *lnako_qjs_call_method(LnakoQuickJs *engine, const LnakoQuickJsValue *object, const char *name, const LnakoQuickJsValue *const *arguments, size_t count) { (void)engine; (void)object; (void)name; (void)arguments; (void)count; return 0; }
int lnako_qjs_drain_jobs(LnakoQuickJs *engine) { (void)engine; return -1; }
LnakoQuickJsValue *lnako_qjs_await(LnakoQuickJs *engine, const LnakoQuickJsValue *promise) { (void)engine; (void)promise; return 0; }
LnakoQuickJsValue *lnako_qjs_undefined(LnakoQuickJs *engine) { (void)engine; return 0; }
LnakoQuickJsValue *lnako_qjs_null(LnakoQuickJs *engine) { (void)engine; return 0; }
LnakoQuickJsValue *lnako_qjs_boolean(LnakoQuickJs *engine, int value) { (void)engine; (void)value; return 0; }
LnakoQuickJsValue *lnako_qjs_number(LnakoQuickJs *engine, double value) { (void)engine; (void)value; return 0; }
LnakoQuickJsValue *lnako_qjs_string(LnakoQuickJs *engine, const char *value, size_t length) { (void)engine; (void)value; (void)length; return 0; }
LnakoQuickJsValue *lnako_qjs_bigint(LnakoQuickJs *engine, const char *decimal, size_t length) { (void)engine; (void)decimal; (void)length; return 0; }
LnakoQuickJsValue *lnako_qjs_array(LnakoQuickJs *engine) { (void)engine; return 0; }
LnakoQuickJsValue *lnako_qjs_object(LnakoQuickJs *engine) { (void)engine; return 0; }
LnakoQuickJsValue *lnako_qjs_host_function(LnakoQuickJs *engine, uintptr_t function_id, const char *name) { (void)engine; (void)function_id; (void)name; return 0; }
LnakoQuickJsValue *lnako_qjs_dup(const LnakoQuickJsValue *value) { (void)value; return 0; }
LnakoQuickJs *lnako_qjs_value_engine(const LnakoQuickJsValue *value) { (void)value; return 0; }
void lnako_qjs_value_free(LnakoQuickJsValue *value) { (void)value; }
enum LnakoQuickJsKind lnako_qjs_kind(const LnakoQuickJsValue *value) { (void)value; return LNAKO_QJS_UNDEFINED; }
uintptr_t lnako_qjs_identity(const LnakoQuickJsValue *value) { (void)value; return 0; }
int lnako_qjs_to_boolean(const LnakoQuickJsValue *value) { (void)value; return 0; }
int lnako_qjs_to_number(const LnakoQuickJsValue *value, double *result) { (void)value; (void)result; return -1; }
char *lnako_qjs_to_string(const LnakoQuickJsValue *value, size_t *length) { (void)value; (void)length; return 0; }
char *lnako_qjs_json(const LnakoQuickJsValue *value, size_t *length) { (void)value; (void)length; return 0; }
uint32_t lnako_qjs_array_length(const LnakoQuickJsValue *value) { (void)value; return 0; }
LnakoQuickJsValue *lnako_qjs_get_index(const LnakoQuickJsValue *value, uint32_t index) { (void)value; (void)index; return 0; }
int lnako_qjs_set_index(LnakoQuickJsValue *value, uint32_t index, const LnakoQuickJsValue *item) { (void)value; (void)index; (void)item; return -1; }
int lnako_qjs_set_array_length(LnakoQuickJsValue *value, uint32_t length) { (void)value; (void)length; return -1; }
LnakoQuickJsValue *lnako_qjs_get_property(const LnakoQuickJsValue *value, const char *name) { (void)value; (void)name; return 0; }
int lnako_qjs_set_property(LnakoQuickJsValue *value, const char *name, const LnakoQuickJsValue *item) { (void)value; (void)name; (void)item; return -1; }
int lnako_qjs_clear_properties(LnakoQuickJsValue *value) { (void)value; return -1; }
LnakoQuickJsKeys *lnako_qjs_keys(const LnakoQuickJsValue *value) { (void)value; return 0; }
size_t lnako_qjs_keys_length(const LnakoQuickJsKeys *keys) { (void)keys; return 0; }
const char *lnako_qjs_key(const LnakoQuickJsKeys *keys, size_t index, size_t *length) { (void)keys; (void)index; (void)length; return 0; }
void lnako_qjs_keys_free(LnakoQuickJsKeys *keys) { (void)keys; }
