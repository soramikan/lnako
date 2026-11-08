#ifndef LNAKO_QUICKJS_BRIDGE_H
#define LNAKO_QUICKJS_BRIDGE_H

#include <stddef.h>
#include <stdint.h>

typedef struct LnakoQuickJs LnakoQuickJs;
typedef struct LnakoQuickJsValue LnakoQuickJsValue;
typedef struct LnakoQuickJsKeys LnakoQuickJsKeys;
typedef LnakoQuickJsValue *(*LnakoQuickJsHostGet)(void *opaque, const char *name, int find_variable);
typedef int (*LnakoQuickJsHostSet)(void *opaque, const char *name, const LnakoQuickJsValue *value);
typedef LnakoQuickJsValue *(*LnakoQuickJsHostInvoke)(void *opaque, uintptr_t function_id, const LnakoQuickJsValue *const *arguments, size_t count);
typedef LnakoQuickJsValue *(*LnakoQuickJsHostExec)(void *opaque, const char *name, const LnakoQuickJsValue *const *arguments, size_t count);

enum LnakoQuickJsKind {
    LNAKO_QJS_UNDEFINED,
    LNAKO_QJS_NULL,
    LNAKO_QJS_BOOLEAN,
    LNAKO_QJS_NUMBER,
    LNAKO_QJS_BIGINT,
    LNAKO_QJS_STRING,
    LNAKO_QJS_ARRAY,
    LNAKO_QJS_FUNCTION,
    LNAKO_QJS_PROMISE,
    LNAKO_QJS_OBJECT,
};

LnakoQuickJs *lnako_qjs_new(void);
void lnako_qjs_set_host(LnakoQuickJs *engine, void *opaque, LnakoQuickJsHostGet get, LnakoQuickJsHostSet set, LnakoQuickJsHostInvoke invoke, LnakoQuickJsHostExec exec);
/// 非0ならhost_getがNULLを返した直接読み取り（`sys.__getSysVar`）を
/// 未定義値ではなくJS例外にする。`sys.__findVar` の探索は従来どおり。
void lnako_qjs_set_host_strict(LnakoQuickJs *engine, int strict);
/// package_root: このmoduleを所有するpackageのroot。非NULLの場合、この
/// module（およびroot配下で読まれたmodule）からのimportはroot内への包含が
/// module_normalizeで強制され、root外へのFS fallbackを拒否する。
int lnako_qjs_add_module_source(LnakoQuickJs *engine, const char *name, const char *source, size_t length, const char *package_root);
/// bare specifier `alias` を登録済み module path `target` へ写す。
/// package 所有 module からの bare import を graph で解決済み path へ結ぶ。
int lnako_qjs_add_module_alias(LnakoQuickJs *engine, const char *alias, const char *target);
void lnako_qjs_retain(LnakoQuickJs *engine);
void lnako_qjs_release(LnakoQuickJs *engine);
char *lnako_qjs_take_error(LnakoQuickJs *engine);
void lnako_qjs_free_string(char *text);

LnakoQuickJsValue *lnako_qjs_eval(LnakoQuickJs *engine, const char *source, size_t length, const char *filename);
LnakoQuickJsValue *lnako_qjs_eval_module(LnakoQuickJs *engine, const char *source, size_t length, const char *filename);
LnakoQuickJsValue *lnako_qjs_global(LnakoQuickJs *engine, const char *name);
LnakoQuickJsValue *lnako_qjs_call(LnakoQuickJs *engine, const LnakoQuickJsValue *function, const LnakoQuickJsValue *const *arguments, size_t count);
LnakoQuickJsValue *lnako_qjs_call_method(LnakoQuickJs *engine, const LnakoQuickJsValue *object, const char *name, const LnakoQuickJsValue *const *arguments, size_t count);
int lnako_qjs_drain_jobs(LnakoQuickJs *engine);
LnakoQuickJsValue *lnako_qjs_await(LnakoQuickJs *engine, const LnakoQuickJsValue *promise);

LnakoQuickJsValue *lnako_qjs_undefined(LnakoQuickJs *engine);
LnakoQuickJsValue *lnako_qjs_null(LnakoQuickJs *engine);
LnakoQuickJsValue *lnako_qjs_boolean(LnakoQuickJs *engine, int value);
LnakoQuickJsValue *lnako_qjs_number(LnakoQuickJs *engine, double value);
LnakoQuickJsValue *lnako_qjs_string(LnakoQuickJs *engine, const char *value, size_t length);
LnakoQuickJsValue *lnako_qjs_bigint(LnakoQuickJs *engine, const char *decimal, size_t length);
LnakoQuickJsValue *lnako_qjs_array(LnakoQuickJs *engine);
LnakoQuickJsValue *lnako_qjs_object(LnakoQuickJs *engine);
LnakoQuickJsValue *lnako_qjs_host_function(LnakoQuickJs *engine, uintptr_t function_id, const char *name);
LnakoQuickJsValue *lnako_qjs_dup(const LnakoQuickJsValue *value);
LnakoQuickJs *lnako_qjs_value_engine(const LnakoQuickJsValue *value);
void lnako_qjs_value_free(LnakoQuickJsValue *value);

enum LnakoQuickJsKind lnako_qjs_kind(const LnakoQuickJsValue *value);
uintptr_t lnako_qjs_identity(const LnakoQuickJsValue *value);
/// Nakoのbytesに相当するTypedArray / ArrayBuffer / SharedArrayBuffer /
/// DataViewなら非0。
int lnako_qjs_is_bytes(const LnakoQuickJsValue *value);
int lnako_qjs_to_boolean(const LnakoQuickJsValue *value);
int lnako_qjs_to_number(const LnakoQuickJsValue *value, double *result);
char *lnako_qjs_to_string(const LnakoQuickJsValue *value, size_t *length);
char *lnako_qjs_json(const LnakoQuickJsValue *value, size_t *length);
uint32_t lnako_qjs_array_length(const LnakoQuickJsValue *value);
LnakoQuickJsValue *lnako_qjs_get_index(const LnakoQuickJsValue *value, uint32_t index);
int lnako_qjs_set_index(LnakoQuickJsValue *value, uint32_t index, const LnakoQuickJsValue *item);
int lnako_qjs_set_array_length(LnakoQuickJsValue *value, uint32_t length);
LnakoQuickJsValue *lnako_qjs_get_property(const LnakoQuickJsValue *value, const char *name);
/// own propertyのみを取得する（継承プロパティ/getterを辿らない）。存在しなければundefined。
LnakoQuickJsValue *lnako_qjs_get_own_property(const LnakoQuickJsValue *value, const char *name);
/// own propertyとして存在するか（1/0、例外は-1）。
int lnako_qjs_has_own_property(const LnakoQuickJsValue *value, const char *name);
int lnako_qjs_set_property(LnakoQuickJsValue *value, const char *name, const LnakoQuickJsValue *item);
int lnako_qjs_clear_properties(LnakoQuickJsValue *value);
/// 継承された setter を呼ばず、自身のデータプロパティとして名前を定義する。
int lnako_qjs_define_property(LnakoQuickJsValue *value, const char *name, const LnakoQuickJsValue *item);
/// 自身のプロパティを削除する（存在しなければ成功扱い）。
int lnako_qjs_delete_property(LnakoQuickJsValue *value, const char *name);
/// 配列インデックスの存在（穴でないこと）を返す。
int lnako_qjs_has_index(const LnakoQuickJsValue *value, uint32_t index);
/// 配列インデックスを削除して穴にする。
int lnako_qjs_delete_index(LnakoQuickJsValue *value, uint32_t index);
/// 2つのJS値が strict equal かどうか（1/0、例外は-1）。
int lnako_qjs_strict_equal(const LnakoQuickJsValue *left, const LnakoQuickJsValue *right);

LnakoQuickJsKeys *lnako_qjs_keys(const LnakoQuickJsValue *value);
size_t lnako_qjs_keys_length(const LnakoQuickJsKeys *keys);
const char *lnako_qjs_key(const LnakoQuickJsKeys *keys, size_t index, size_t *length);
void lnako_qjs_keys_free(LnakoQuickJsKeys *keys);

#endif
