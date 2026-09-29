#include "quickjs_bridge.h"
#include "quickjs.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if defined(_WIN32)
#include <windows.h>
#endif

struct LnakoQuickJs {
    JSRuntime *runtime;
    JSContext *context;
    size_t references;
    char *last_error;
    void *host_opaque;
    LnakoQuickJsHostGet host_get;
    LnakoQuickJsHostSet host_set;
    LnakoQuickJsHostInvoke host_invoke;
    LnakoQuickJsHostExec host_exec;
    struct LnakoQuickJsModuleSource *module_sources;
};

struct LnakoQuickJsModuleSource {
    char *name;
    char *source;
    size_t length;
    /// このmoduleを所有するpackageのcanonical root（`/`区切り、末尾`/`無し）。
    /// NULLはpackage外module。登録名がこのroot配下のmoduleのimportは
    /// module_normalizeでroot内への包含を強制される。
    char *package_root;
    struct LnakoQuickJsModuleSource *next;
};

struct LnakoQuickJsValue {
    LnakoQuickJs *engine;
    JSValue value;
};

struct LnakoQuickJsKeys {
    LnakoQuickJs *engine;
    size_t length;
    char **items;
    size_t *item_lengths;
};

static char *copy_bytes(const char *source, size_t length) {
    char *result = malloc(length + 1);
    if (!result) return NULL;
    if (length) memcpy(result, source, length);
    result[length] = '\0';
    return result;
}

static void set_error(LnakoQuickJs *engine) {
    if (!engine) return;
    free(engine->last_error);
    engine->last_error = NULL;
    JSValue exception = JS_GetException(engine->context);
    size_t length = 0;
    const char *text = JS_ToCStringLen(engine->context, &length, exception);
    if (text) {
        engine->last_error = copy_bytes(text, length);
        JS_FreeCString(engine->context, text);
    }
    JS_FreeValue(engine->context, exception);
    if (!engine->last_error) engine->last_error = copy_bytes("QuickJS error", 13);
}

static void set_error_value(LnakoQuickJs *engine, JSValueConst value) {
    free(engine->last_error);
    engine->last_error = NULL;
    size_t length = 0;
    const char *text = JS_ToCStringLen(engine->context, &length, value);
    if (text) {
        engine->last_error = copy_bytes(text, length);
        JS_FreeCString(engine->context, text);
    }
    if (!engine->last_error) engine->last_error = copy_bytes("QuickJS promise rejected", 24);
}

static LnakoQuickJsValue *wrap_owned(LnakoQuickJs *engine, JSValue value) {
    if (JS_IsException(value)) {
        set_error(engine);
        return NULL;
    }
    LnakoQuickJsValue *result = malloc(sizeof(*result));
    if (!result) {
        JS_FreeValue(engine->context, value);
        return NULL;
    }
    lnako_qjs_retain(engine);
    result->engine = engine;
    result->value = value;
    return result;
}

static JSValue *copy_arguments(LnakoQuickJs *engine, const LnakoQuickJsValue *const *arguments, size_t count) {
    if (!count) return NULL;
    JSValue *result = malloc(sizeof(*result) * count);
    if (!result) return NULL;
    for (size_t index = 0; index < count; index++) {
        if (!arguments[index] || arguments[index]->engine != engine) {
            for (size_t previous = 0; previous < index; previous++) JS_FreeValue(engine->context, result[previous]);
            free(result);
            return NULL;
        }
        result[index] = JS_DupValue(engine->context, arguments[index]->value);
    }
    return result;
}

static void free_arguments(LnakoQuickJs *engine, JSValue *arguments, size_t count) {
    if (!arguments) return;
    for (size_t index = 0; index < count; index++) JS_FreeValue(engine->context, arguments[index]);
    free(arguments);
}

static JSValue take_host_result(JSContext *context, LnakoQuickJs *engine, LnakoQuickJsValue *result) {
    if (!result) return JS_ThrowInternalError(context, "lnako host callback failed");
    if (result->engine != engine) {
        lnako_qjs_value_free(result);
        return JS_ThrowInternalError(context, "lnako host returned a value from another QuickJS runtime");
    }
    JSValue value = JS_DupValue(context, result->value);
    lnako_qjs_value_free(result);
    return value;
}

static LnakoQuickJsValue **borrow_host_arguments(LnakoQuickJs *engine, int argc, JSValueConst *argv) {
    if (argc <= 0) return NULL;
    LnakoQuickJsValue **arguments = malloc(sizeof(*arguments) * (size_t)argc);
    LnakoQuickJsValue *values = malloc(sizeof(*values) * (size_t)argc);
    if (!arguments || !values) {
        free(arguments);
        free(values);
        return NULL;
    }
    for (int index = 0; index < argc; index++) {
        values[index].engine = engine;
        values[index].value = argv[index];
        arguments[index] = &values[index];
    }
    return arguments;
}

static void free_borrowed_host_arguments(LnakoQuickJsValue **arguments) {
    if (!arguments) return;
    free(arguments[0]);
    free(arguments);
}

static JSValue host_get_common(JSContext *context, int argc, JSValueConst *argv, int find_variable) {
    LnakoQuickJs *engine = JS_GetContextOpaque(context);
    if (!engine || !engine->host_get || argc < 1) return argc >= 2 ? JS_DupValue(context, argv[1]) : JS_UNDEFINED;
    const char *name = JS_ToCString(context, argv[0]);
    if (!name) return JS_EXCEPTION;
    LnakoQuickJsValue *result = engine->host_get(engine->host_opaque, name, find_variable);
    JS_FreeCString(context, name);
    if (!result) return argc >= 2 ? JS_DupValue(context, argv[1]) : JS_UNDEFINED;
    JSValue value = take_host_result(context, engine, result);
    if (JS_IsUndefined(value) && argc >= 2) {
        JS_FreeValue(context, value);
        return JS_DupValue(context, argv[1]);
    }
    return value;
}

static JSValue host_get_sys_var(JSContext *context, JSValueConst this_value, int argc, JSValueConst *argv) {
    (void)this_value;
    return host_get_common(context, argc, argv, 0);
}

static JSValue host_find_var(JSContext *context, JSValueConst this_value, int argc, JSValueConst *argv) {
    (void)this_value;
    return host_get_common(context, argc, argv, 1);
}

static JSValue host_set_sys_var(JSContext *context, JSValueConst this_value, int argc, JSValueConst *argv) {
    (void)this_value;
    LnakoQuickJs *engine = JS_GetContextOpaque(context);
    if (!engine || !engine->host_set || argc < 2) return JS_UNDEFINED;
    const char *name = JS_ToCString(context, argv[0]);
    if (!name) return JS_EXCEPTION;
    LnakoQuickJsValue borrowed = { engine, argv[1] };
    int result = engine->host_set(engine->host_opaque, name, &borrowed);
    JS_FreeCString(context, name);
    if (result < 0) return JS_ThrowInternalError(context, "lnako host variable update failed");
    return JS_UNDEFINED;
}

static JSValue host_exec(JSContext *context, JSValueConst this_value, int argc, JSValueConst *argv) {
    (void)this_value;
    LnakoQuickJs *engine = JS_GetContextOpaque(context);
    if (!engine || !engine->host_exec || argc < 1) return JS_ThrowInternalError(context, "lnako host command bridge is unavailable");
    const char *name = JS_ToCString(context, argv[0]);
    if (!name) return JS_EXCEPTION;
    LnakoQuickJsValue **arguments = borrow_host_arguments(engine, argc - 1, argv + 1);
    if (argc > 1 && !arguments) {
        JS_FreeCString(context, name);
        return JS_ThrowOutOfMemory(context);
    }
    LnakoQuickJsValue *result = engine->host_exec(engine->host_opaque, name, (const LnakoQuickJsValue *const *)arguments, (size_t)(argc - 1));
    free_borrowed_host_arguments(arguments);
    JS_FreeCString(context, name);
    return take_host_result(context, engine, result);
}

static JSValue host_invoke(JSContext *context, JSValueConst this_value, int argc, JSValueConst *argv, int magic, JSValue *function_data) {
    (void)this_value;
    (void)magic;
    LnakoQuickJs *engine = JS_GetContextOpaque(context);
    if (!engine || !engine->host_invoke) return JS_ThrowInternalError(context, "lnako function bridge is unavailable");
    int64_t function_id = 0;
    if (JS_ToInt64(context, &function_id, function_data[0]) < 0 || function_id < 0) return JS_EXCEPTION;
    LnakoQuickJsValue **arguments = borrow_host_arguments(engine, argc, argv);
    if (argc > 0 && !arguments) return JS_ThrowOutOfMemory(context);
    LnakoQuickJsValue *result = engine->host_invoke(engine->host_opaque, (uintptr_t)function_id, (const LnakoQuickJsValue *const *)arguments, (size_t)argc);
    free_borrowed_host_arguments(arguments);
    return take_host_result(context, engine, result);
}

static int install_host_bridge(LnakoQuickJs *engine) {
    JSContext *context = engine->context;
    JSValue global = JS_GetGlobalObject(context);
    JSValue sys = JS_NewObject(context);
    if (JS_IsException(global) || JS_IsException(sys)) {
        JS_FreeValue(context, global);
        JS_FreeValue(context, sys);
        return -1;
    }
    JS_SetPropertyStr(context, sys, "__getSysVar", JS_NewCFunction(context, host_get_sys_var, "__getSysVar", 2));
    JS_SetPropertyStr(context, sys, "__setSysVar", JS_NewCFunction(context, host_set_sys_var, "__setSysVar", 2));
    JS_SetPropertyStr(context, sys, "__findVar", JS_NewCFunction(context, host_find_var, "__findVar", 2));
    JS_SetPropertyStr(context, global, "sys", sys);
    JS_SetPropertyStr(context, global, "__lnako_hostExec", JS_NewCFunction(context, host_exec, "__lnako_hostExec", 1));
    JS_FreeValue(context, global);
    return 0;
}

#if defined(_WIN32)
static wchar_t *utf8_to_wide(const char *text) {
    int length = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text, -1, NULL, 0);
    if (length <= 0) return NULL;
    wchar_t *wide = malloc(sizeof(*wide) * (size_t)length);
    if (!wide) return NULL;
    if (!MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text, -1, wide, length)) {
        free(wide);
        return NULL;
    }
    return wide;
}
#endif

static FILE *open_module_file(const char *path) {
#if defined(_WIN32)
    wchar_t *wide_path = utf8_to_wide(path);
    if (!wide_path) return NULL;
    FILE *file = _wfopen(wide_path, L"rb");
    free(wide_path);
    return file;
#else
    return fopen(path, "rb");
#endif
}

/// `root` の直下（strictに内側）に `path` があるかをlexicalに判定する。
/// 両側とも `/` 区切りへ正規化済みであること（module名・登録rootともに
/// 登録時に `\`→`/` 変換される）。
static int path_within_root(const char *root, const char *path) {
    size_t root_length = strlen(root);
    size_t path_length = strlen(path);
    return path_length > root_length && !strncmp(path, root, root_length) && path[root_length] == '/';
}

/// quickjs.c の js_default_module_normalize_name と同等の正規化 —
/// 先頭の `./`・`../` 列をbase名のdir部分へ畳み込む。defaultとは異なり
/// js_mallocで確保した結果を返す（呼出し側がjs_freeする）。
static char *lnako_normalize_module_name(JSContext *context, const char *base_name, const char *name) {
    char *filename;
    const char *r;
    size_t length;
    if (name[0] != '.') {
        size_t name_length = strlen(name);
        filename = js_malloc(context, name_length + 1);
        if (!filename) return NULL;
        memcpy(filename, name, name_length + 1);
        return filename;
    }
    const char *p = base_name ? strrchr(base_name, '/') : NULL;
    length = p ? (size_t)(p - base_name) : 0;
    size_t capacity = length + strlen(name) + 2;
    filename = js_malloc(context, capacity);
    if (!filename) return NULL;
    memcpy(filename, base_name, length);
    filename[length] = '\0';
    r = name;
    for (;;) {
        if (r[0] == '.' && r[1] == '/') {
            r += 2;
        } else if (r[0] == '.' && r[1] == '.' && r[2] == '/') {
            /* remove the last path element of filename, except if "." or ".." */
            if (filename[0] == '\0') break;
            char *q = strrchr(filename, '/');
            if (!q)
                q = filename;
            else
                q++;
            if (!strcmp(q, ".") || !strcmp(q, "..")) break;
            if (q > filename) q--;
            *q = '\0';
            r += 3;
        } else {
            break;
        }
    }
    if (filename[0] != '\0') {
        size_t used = strlen(filename);
        filename[used] = '/';
        filename[used + 1] = '\0';
    }
    strcat(filename, r);
    return filename;
}

/// `/` 区切りpath中の `.`/`..` 要素をlexicalに畳み込む。default正規化は
/// 先頭要素のみ処理するため `./a/../x` のような途中の `..` が残り、包含
/// 検査をlexical prefixだけで行うと `root/../外` の形で脱出できてしまう。
/// rootを遡り切る `..` は落とす（包含検査が必ず失敗する＝fail closed）。
static char *collapse_dot_segments(JSContext *context, const char *path) {
    size_t length = strlen(path);
    char *copy = js_malloc(context, length + 1);
    if (!copy) return NULL;
    memcpy(copy, path, length + 1);
    size_t capacity = length / 2 + 2;
    char **segments = js_malloc(context, sizeof(*segments) * capacity);
    if (!segments) {
        js_free(context, copy);
        return NULL;
    }
    const int absolute = copy[0] == '/';
    size_t count = 0;
    char *cursor = copy + (absolute ? 1 : 0);
    while (*cursor) {
        char *slash = strchr(cursor, '/');
        if (slash) *slash = '\0';
        if (!strcmp(cursor, "..")) {
            if (count > 0)
                count--;
            else if (!absolute)
                segments[count++] = cursor;
        } else if (cursor[0] != '\0' && strcmp(cursor, ".")) {
            segments[count++] = cursor;
        }
        cursor = slash ? slash + 1 : cursor + strlen(cursor);
    }
    char *output = js_malloc(context, length + 2);
    if (!output) {
        js_free(context, segments);
        js_free(context, copy);
        return NULL;
    }
    size_t used = 0;
    if (absolute) output[used++] = '/';
    for (size_t index = 0; index < count; index++) {
        size_t segment_length = strlen(segments[index]);
        memcpy(output + used, segments[index], segment_length);
        used += segment_length;
        output[used++] = '/';
    }
    if (used > (absolute ? 2u : 1u)) used--;
    output[used] = '\0';
    js_free(context, segments);
    js_free(context, copy);
    return output;
}

/// FS上で解決可能なら実体pathを返す。symlinkを辿るため、登録名のlexical
/// 包含をすり抜ける in-root symlink 経由のroot外読取りを検出できる。
/// 実在しないpath（embedded payloadや不存在file）ではNULL — その場合は
/// lexical包含のみで判定し、不在fileはfopen側が失敗させる。
static char *canonical_module_path(const char *path) {
#if defined(_WIN32)
    wchar_t *wide_path = utf8_to_wide(path);
    if (!wide_path) return NULL;
    wchar_t *absolute = _wfullpath(NULL, wide_path, 0);
    free(wide_path);
    if (!absolute) return NULL;
    int length = WideCharToMultiByte(CP_UTF8, 0, absolute, -1, NULL, 0, NULL, NULL);
    if (length <= 0) {
        free(absolute);
        return NULL;
    }
    char *result = malloc((size_t)length);
    if (result && !WideCharToMultiByte(CP_UTF8, 0, absolute, -1, result, length, NULL, NULL)) {
        free(result);
        result = NULL;
    }
    free(absolute);
    return result;
#else
    return realpath(path, NULL);
#endif
}

/// referrer（base）がpackage所有かを判定し、所有していればそのrootを返す。
/// 登録moduleは登録時のroot、その場でFS fallbackから読まれたroot内fileも
/// 「base名がroot配下」であることから同じ境界へ拘束する（graphで未収集の
/// in-root moduleが更にroot外へ逃げる連鎖を止める）。
static const char *package_root_for_base(LnakoQuickJs *engine, const char *base_name) {
    if (!engine) return NULL;
    for (struct LnakoQuickJsModuleSource *item = engine->module_sources; item; item = item->next) {
        if (item->package_root && !strcmp(item->name, base_name)) return item->package_root;
    }
    for (struct LnakoQuickJsModuleSource *item = engine->module_sources; item; item = item->next) {
        if (item->package_root && path_within_root(item->package_root, base_name)) return item->package_root;
    }
    return NULL;
}

/// package所有moduleのimport解決でpackage root外へのFS fallbackを拒否する
/// loader境界。graph側の収集が漏らしたimport形でも、referrerがpackage所有
/// なら実行時にここで止まる。default正規化と同等の結果を返すが、`..`/`.`
/// 要素はlexicalに畳み込んでから判定・返却する（`root/../外` 形式のprefix
/// すり抜けを塞ぐ）。
static char *module_normalize(JSContext *context, const char *base_name, const char *name, void *opaque) {
    LnakoQuickJs *engine = opaque;
    char *resolved = lnako_normalize_module_name(context, base_name, name);
    if (!resolved) return NULL;
    char *collapsed = collapse_dot_segments(context, resolved);
    js_free(context, resolved);
    if (!collapsed) {
        JS_ThrowOutOfMemory(context);
        return NULL;
    }
    // referrer名は登録時に `\`→`/`・collapse済みだが、host側evalのfilename等
    // では未正規化の場合があるため比較前に畳み込む。失敗時は包含検査を
    // 素通りさせないようOOMとして扱う（package所有判定不能でfail closed）。
    char *collapsed_base = NULL;
    if (base_name) {
        collapsed_base = collapse_dot_segments(context, base_name);
        if (!collapsed_base) {
            js_free(context, collapsed);
            JS_ThrowOutOfMemory(context);
            return NULL;
        }
    }
    const char *root = collapsed_base ? package_root_for_base(engine, collapsed_base) : NULL;
    if (root) {
        int inside = path_within_root(root, collapsed);
        if (inside) {
            char *canonical = canonical_module_path(collapsed);
            if (canonical) {
                for (char *p = canonical; *p; p++)
                    if (*p == '\\') *p = '/';
                inside = path_within_root(root, canonical);
                free(canonical);
            }
        }
        if (!inside) {
            js_free(context, collapsed_base);
            js_free(context, collapsed);
            JS_ThrowInternalError(context, "module import '%s' escapes the package root", name);
            return NULL;
        }
    }
    js_free(context, collapsed_base);
    return collapsed;
}

static JSModuleDef *module_loader(JSContext *context, const char *module_name, void *opaque) {
    LnakoQuickJs *engine = opaque;
    const char *source = NULL;
    size_t actual = 0;
    char *owned_source = NULL;
    for (struct LnakoQuickJsModuleSource *item = engine ? engine->module_sources : NULL; item; item = item->next) {
        if (!strcmp(item->name, module_name)) {
            source = item->source;
            actual = item->length;
            break;
        }
    }
    if (!source) {
        FILE *file = open_module_file(module_name);
        if (!file) {
            JS_ThrowReferenceError(context, "could not load module '%s'", module_name);
            return NULL;
        }
        if (fseek(file, 0, SEEK_END) != 0) {
            fclose(file);
            JS_ThrowInternalError(context, "could not seek module '%s'", module_name);
            return NULL;
        }
        long size = ftell(file);
        if (size < 0 || fseek(file, 0, SEEK_SET) != 0) {
            fclose(file);
            JS_ThrowInternalError(context, "could not size module '%s'", module_name);
            return NULL;
        }
        owned_source = malloc((size_t)size + 1);
        if (!owned_source) {
            fclose(file);
            JS_ThrowOutOfMemory(context);
            return NULL;
        }
        actual = fread(owned_source, 1, (size_t)size, file);
        fclose(file);
        if (actual != (size_t)size) {
            free(owned_source);
            JS_ThrowInternalError(context, "could not read module '%s'", module_name);
            return NULL;
        }
        owned_source[actual] = '\0';
        source = owned_source;
    }
    JSValue compiled = JS_Eval(context, source, actual, module_name, JS_EVAL_TYPE_MODULE | JS_EVAL_FLAG_COMPILE_ONLY);
    free(owned_source);
    if (JS_IsException(compiled)) return NULL;
    JSModuleDef *module = JS_VALUE_GET_PTR(compiled);
    JS_FreeValue(context, compiled);
    return module;
}

LnakoQuickJs *lnako_qjs_new(void) {
    LnakoQuickJs *engine = calloc(1, sizeof(*engine));
    if (!engine) return NULL;
    engine->runtime = JS_NewRuntime();
    if (!engine->runtime) {
        free(engine);
        return NULL;
    }
    engine->context = JS_NewContext(engine->runtime);
    if (!engine->context) {
        JS_FreeRuntime(engine->runtime);
        free(engine);
        return NULL;
    }
    JS_SetContextOpaque(engine->context, engine);
    JS_SetModuleLoaderFunc(engine->runtime, module_normalize, module_loader, engine);
    if (install_host_bridge(engine) < 0) {
        JS_FreeContext(engine->context);
        JS_FreeRuntime(engine->runtime);
        free(engine);
        return NULL;
    }
    engine->references = 1;
    return engine;
}

void lnako_qjs_set_host(LnakoQuickJs *engine, void *opaque, LnakoQuickJsHostGet get, LnakoQuickJsHostSet set, LnakoQuickJsHostInvoke invoke, LnakoQuickJsHostExec exec) {
    if (!engine) return;
    engine->host_opaque = opaque;
    engine->host_get = get;
    engine->host_set = set;
    engine->host_invoke = invoke;
    engine->host_exec = exec;
}

void lnako_qjs_retain(LnakoQuickJs *engine) {
    if (engine) engine->references++;
}

void lnako_qjs_release(LnakoQuickJs *engine) {
    if (!engine || --engine->references) return;
    while (engine->module_sources) {
        struct LnakoQuickJsModuleSource *item = engine->module_sources;
        engine->module_sources = item->next;
        free(item->name);
        free(item->source);
        free(item->package_root);
        free(item);
    }
    free(engine->last_error);
    JS_FreeContext(engine->context);
    JS_FreeRuntime(engine->runtime);
    free(engine);
}

/// package rootの登録用文字列を正規化する。module名と同じく `\`→`/` に
/// 揃え、包含検査が `path_within_root` のprefix一致で正しく働くよう
/// 末尾の `/` は落とす。
static char *normalize_package_root(const char *package_root) {
    char *root = copy_bytes(package_root, strlen(package_root));
    if (!root) return NULL;
    for (char *p = root; *p; p++)
        if (*p == '\\') *p = '/';
    size_t length = strlen(root);
    while (length > 1 && root[length - 1] == '/') root[--length] = '\0';
    return root;
}

int lnako_qjs_add_module_source(LnakoQuickJs *engine, const char *name, const char *source, size_t length, const char *package_root) {
    if (!engine || !name || !source) return -1;
    for (struct LnakoQuickJsModuleSource *item = engine->module_sources; item; item = item->next) {
        if (!strcmp(item->name, name)) {
            // 同名moduleの再登録ではrootが未設定の場合のみ補完する
            // （IR側で同一pathがscopeを併合したentryを再送り得る）。
            if (!item->package_root && package_root && package_root[0]) item->package_root = normalize_package_root(package_root);
            return 0;
        }
    }
    struct LnakoQuickJsModuleSource *item = calloc(1, sizeof(*item));
    if (!item) return -1;
    item->name = copy_bytes(name, strlen(name));
    item->source = copy_bytes(source, length);
    item->package_root = (package_root && package_root[0]) ? normalize_package_root(package_root) : NULL;
    if (!item->name || !item->source || (package_root && package_root[0] && !item->package_root)) {
        free(item->name);
        free(item->source);
        free(item->package_root);
        free(item);
        return -1;
    }
    item->length = length;
    item->next = engine->module_sources;
    engine->module_sources = item;
    return 0;
}

char *lnako_qjs_take_error(LnakoQuickJs *engine) {
    if (!engine) return NULL;
    char *result = engine->last_error;
    engine->last_error = NULL;
    return result;
}

void lnako_qjs_free_string(char *text) {
    free(text);
}

LnakoQuickJsValue *lnako_qjs_eval(LnakoQuickJs *engine, const char *source, size_t length, const char *filename) {
    if (!engine || !source) return NULL;
    char *terminated = copy_bytes(source, length);
    if (!terminated) return NULL;
    JSValue value = JS_Eval(engine->context, terminated, length, filename ? filename : "<eval>", JS_EVAL_TYPE_GLOBAL);
    free(terminated);
    return wrap_owned(engine, value);
}

LnakoQuickJsValue *lnako_qjs_eval_module(LnakoQuickJs *engine, const char *source, size_t length, const char *filename) {
    if (!engine || !source || !filename) return NULL;
    char *terminated = copy_bytes(source, length);
    if (!terminated) return NULL;
    JSValue compiled = JS_Eval(engine->context, terminated, length, filename, JS_EVAL_TYPE_MODULE | JS_EVAL_FLAG_COMPILE_ONLY);
    free(terminated);
    if (JS_IsException(compiled)) {
        set_error(engine);
        return NULL;
    }
    JSModuleDef *module = JS_VALUE_GET_PTR(compiled);
    JSValue evaluated = JS_EvalFunction(engine->context, compiled);
    if (JS_IsException(evaluated)) {
        set_error(engine);
        return NULL;
    }
    if (lnako_qjs_drain_jobs(engine) < 0) {
        JS_FreeValue(engine->context, evaluated);
        return NULL;
    }
    if (JS_PromiseState(engine->context, evaluated) == JS_PROMISE_REJECTED) {
        JSValue reason = JS_PromiseResult(engine->context, evaluated);
        set_error_value(engine, reason);
        JS_FreeValue(engine->context, reason);
        JS_FreeValue(engine->context, evaluated);
        return NULL;
    }
    JS_FreeValue(engine->context, evaluated);
    JSValue namespace_value = JS_GetModuleNamespace(engine->context, module);
    if (JS_IsException(namespace_value)) {
        set_error(engine);
        return NULL;
    }
    JSValue default_value = JS_GetPropertyStr(engine->context, namespace_value, "default");
    JS_FreeValue(engine->context, namespace_value);
    return wrap_owned(engine, default_value);
}

LnakoQuickJsValue *lnako_qjs_global(LnakoQuickJs *engine, const char *name) {
    if (!engine || !name) return NULL;
    JSValue global = JS_GetGlobalObject(engine->context);
    JSValue result = JS_GetPropertyStr(engine->context, global, name);
    JS_FreeValue(engine->context, global);
    return wrap_owned(engine, result);
}

LnakoQuickJsValue *lnako_qjs_call(LnakoQuickJs *engine, const LnakoQuickJsValue *function, const LnakoQuickJsValue *const *arguments, size_t count) {
    if (!engine || !function || function->engine != engine) return NULL;
    JSValue *values = copy_arguments(engine, arguments, count);
    if (count && !values) return NULL;
    JSValue result = JS_Call(engine->context, function->value, JS_UNDEFINED, (int)count, values);
    free_arguments(engine, values, count);
    return wrap_owned(engine, result);
}

LnakoQuickJsValue *lnako_qjs_call_method(LnakoQuickJs *engine, const LnakoQuickJsValue *object, const char *name, const LnakoQuickJsValue *const *arguments, size_t count) {
    if (!engine || !object || object->engine != engine || !name) return NULL;
    JSValue function = JS_GetPropertyStr(engine->context, object->value, name);
    if (JS_IsException(function)) {
        set_error(engine);
        return NULL;
    }
    JSValue *values = copy_arguments(engine, arguments, count);
    if (count && !values) {
        JS_FreeValue(engine->context, function);
        return NULL;
    }
    JSValue result = JS_Call(engine->context, function, object->value, (int)count, values);
    free_arguments(engine, values, count);
    JS_FreeValue(engine->context, function);
    return wrap_owned(engine, result);
}

int lnako_qjs_drain_jobs(LnakoQuickJs *engine) {
    if (!engine) return -1;
    JSContext *context = NULL;
    int result;
    while ((result = JS_ExecutePendingJob(engine->runtime, &context)) > 0) {}
    if (result < 0) set_error(engine);
    return result;
}

LnakoQuickJsValue *lnako_qjs_await(LnakoQuickJs *engine, const LnakoQuickJsValue *promise) {
    if (!engine || !promise || promise->engine != engine) return NULL;
    if (lnako_qjs_drain_jobs(engine) < 0) return NULL;
    JSPromiseStateEnum state = JS_PromiseState(engine->context, promise->value);
    if (state == JS_PROMISE_FULFILLED) return wrap_owned(engine, JS_DupValue(engine->context, JS_PromiseResult(engine->context, promise->value)));
    if (state == JS_PROMISE_REJECTED) {
        JSValue reason = JS_PromiseResult(engine->context, promise->value);
        set_error_value(engine, reason);
        JS_FreeValue(engine->context, reason);
    }
    else {
        free(engine->last_error);
        engine->last_error = copy_bytes("QuickJS promise is still pending", sizeof("QuickJS promise is still pending") - 1);
    }
    return NULL;
}

LnakoQuickJsValue *lnako_qjs_undefined(LnakoQuickJs *engine) { return engine ? wrap_owned(engine, JS_UNDEFINED) : NULL; }
LnakoQuickJsValue *lnako_qjs_null(LnakoQuickJs *engine) { return engine ? wrap_owned(engine, JS_NULL) : NULL; }
LnakoQuickJsValue *lnako_qjs_boolean(LnakoQuickJs *engine, int value) { return engine ? wrap_owned(engine, JS_NewBool(engine->context, value)) : NULL; }
LnakoQuickJsValue *lnako_qjs_number(LnakoQuickJs *engine, double value) { return engine ? wrap_owned(engine, JS_NewFloat64(engine->context, value)) : NULL; }
LnakoQuickJsValue *lnako_qjs_string(LnakoQuickJs *engine, const char *value, size_t length) { return engine ? wrap_owned(engine, JS_NewStringLen(engine->context, value, length)) : NULL; }

LnakoQuickJsValue *lnako_qjs_bigint(LnakoQuickJs *engine, const char *decimal, size_t length) {
    if (!engine || !decimal) return NULL;
    char *source = malloc(length + 4);
    if (!source) return NULL;
    source[0] = '(';
    memcpy(source + 1, decimal, length);
    source[length + 1] = 'n';
    source[length + 2] = ')';
    source[length + 3] = '\0';
    LnakoQuickJsValue *result = lnako_qjs_eval(engine, source, length + 3, "<bigint>");
    free(source);
    return result;
}

LnakoQuickJsValue *lnako_qjs_array(LnakoQuickJs *engine) { return engine ? wrap_owned(engine, JS_NewArray(engine->context)) : NULL; }
LnakoQuickJsValue *lnako_qjs_object(LnakoQuickJs *engine) { return engine ? wrap_owned(engine, JS_NewObject(engine->context)) : NULL; }

LnakoQuickJsValue *lnako_qjs_host_function(LnakoQuickJs *engine, uintptr_t function_id, const char *name) {
    if (!engine) return NULL;
    JSValue data = JS_NewInt64(engine->context, (int64_t)function_id);
    JSValue function = JS_NewCFunctionData(engine->context, host_invoke, 0, 0, 1, &data);
    JS_FreeValue(engine->context, data);
    if (JS_IsException(function)) return wrap_owned(engine, function);
    if (name) JS_DefinePropertyValueStr(engine->context, function, "name", JS_NewString(engine->context, name), JS_PROP_CONFIGURABLE);
    return wrap_owned(engine, function);
}

LnakoQuickJsValue *lnako_qjs_dup(const LnakoQuickJsValue *value) {
    if (!value) return NULL;
    return wrap_owned(value->engine, JS_DupValue(value->engine->context, value->value));
}

LnakoQuickJs *lnako_qjs_value_engine(const LnakoQuickJsValue *value) {
    return value ? value->engine : NULL;
}

void lnako_qjs_value_free(LnakoQuickJsValue *value) {
    if (!value) return;
    LnakoQuickJs *engine = value->engine;
    JS_FreeValue(engine->context, value->value);
    free(value);
    lnako_qjs_release(engine);
}

enum LnakoQuickJsKind lnako_qjs_kind(const LnakoQuickJsValue *value) {
    if (!value) return LNAKO_QJS_UNDEFINED;
    JSContext *context = value->engine->context;
    if (JS_IsUndefined(value->value)) return LNAKO_QJS_UNDEFINED;
    if (JS_IsNull(value->value)) return LNAKO_QJS_NULL;
    if (JS_IsBool(value->value)) return LNAKO_QJS_BOOLEAN;
    if (JS_IsNumber(value->value)) return LNAKO_QJS_NUMBER;
    if (JS_IsBigInt(context, value->value)) return LNAKO_QJS_BIGINT;
    if (JS_IsString(value->value)) return LNAKO_QJS_STRING;
    if (JS_IsArray(context, value->value)) return LNAKO_QJS_ARRAY;
    if (JS_IsFunction(context, value->value)) return LNAKO_QJS_FUNCTION;
    if (JS_IsObject(value->value)) {
        JSValue promise = JS_GetPropertyStr(context, value->value, "then");
        int is_promise = JS_IsFunction(context, promise);
        JS_FreeValue(context, promise);
        return is_promise ? LNAKO_QJS_PROMISE : LNAKO_QJS_OBJECT;
    }
    return LNAKO_QJS_UNDEFINED;
}

uintptr_t lnako_qjs_identity(const LnakoQuickJsValue *value) {
    if (!value || !JS_IsObject(value->value)) return 0;
    return (uintptr_t)JS_VALUE_GET_PTR(value->value);
}

int lnako_qjs_to_boolean(const LnakoQuickJsValue *value) {
    return value ? JS_ToBool(value->engine->context, value->value) : 0;
}

int lnako_qjs_to_number(const LnakoQuickJsValue *value, double *result) {
    return value && result ? JS_ToFloat64(value->engine->context, result, value->value) : -1;
}

char *lnako_qjs_to_string(const LnakoQuickJsValue *value, size_t *length) {
    if (!value) return NULL;
    size_t actual_length = 0;
    const char *text = JS_ToCStringLen(value->engine->context, &actual_length, value->value);
    if (!text) {
        set_error(value->engine);
        return NULL;
    }
    char *result = copy_bytes(text, actual_length);
    JS_FreeCString(value->engine->context, text);
    if (length) *length = actual_length;
    return result;
}

char *lnako_qjs_json(const LnakoQuickJsValue *value, size_t *length) {
    if (!value) return NULL;
    JSValue json = JS_JSONStringify(value->engine->context, value->value, JS_UNDEFINED, JS_UNDEFINED);
    if (JS_IsException(json)) {
        set_error(value->engine);
        return NULL;
    }
    if (JS_IsUndefined(json)) {
        JS_FreeValue(value->engine->context, json);
        return NULL;
    }
    LnakoQuickJsValue temporary = { value->engine, json };
    char *result = lnako_qjs_to_string(&temporary, length);
    JS_FreeValue(value->engine->context, json);
    return result;
}

uint32_t lnako_qjs_array_length(const LnakoQuickJsValue *value) {
    if (!value) return 0;
    JSValue length = JS_GetPropertyStr(value->engine->context, value->value, "length");
    uint32_t result = 0;
    JS_ToUint32(value->engine->context, &result, length);
    JS_FreeValue(value->engine->context, length);
    return result;
}

LnakoQuickJsValue *lnako_qjs_get_index(const LnakoQuickJsValue *value, uint32_t index) {
    return value ? wrap_owned(value->engine, JS_GetPropertyUint32(value->engine->context, value->value, index)) : NULL;
}

int lnako_qjs_set_index(LnakoQuickJsValue *value, uint32_t index, const LnakoQuickJsValue *item) {
    if (!value || !item || value->engine != item->engine) return -1;
    return JS_SetPropertyUint32(value->engine->context, value->value, index, JS_DupValue(value->engine->context, item->value));
}

int lnako_qjs_set_array_length(LnakoQuickJsValue *value, uint32_t length) {
    if (!value) return -1;
    int result = JS_SetPropertyStr(value->engine->context, value->value, "length", JS_NewUint32(value->engine->context, length));
    if (result < 0) set_error(value->engine);
    return result;
}

LnakoQuickJsValue *lnako_qjs_get_property(const LnakoQuickJsValue *value, const char *name) {
    return value && name ? wrap_owned(value->engine, JS_GetPropertyStr(value->engine->context, value->value, name)) : NULL;
}

int lnako_qjs_set_property(LnakoQuickJsValue *value, const char *name, const LnakoQuickJsValue *item) {
    if (!value || !item || value->engine != item->engine || !name) return -1;
    return JS_SetPropertyStr(value->engine->context, value->value, name, JS_DupValue(value->engine->context, item->value));
}

int lnako_qjs_clear_properties(LnakoQuickJsValue *value) {
    if (!value) return -1;
    JSPropertyEnum *properties = NULL;
    uint32_t length = 0;
    if (JS_GetOwnPropertyNames(value->engine->context, &properties, &length, value->value, JS_GPN_STRING_MASK | JS_GPN_ENUM_ONLY) < 0) {
        set_error(value->engine);
        return -1;
    }
    int result = 0;
    for (uint32_t index = 0; index < length; index++) {
        if (JS_DeleteProperty(value->engine->context, value->value, properties[index].atom, 0) < 0) result = -1;
        JS_FreeAtom(value->engine->context, properties[index].atom);
    }
    js_free(value->engine->context, properties);
    if (result < 0) set_error(value->engine);
    return result;
}

LnakoQuickJsKeys *lnako_qjs_keys(const LnakoQuickJsValue *value) {
    if (!value) return NULL;
    JSPropertyEnum *properties = NULL;
    uint32_t count = 0;
    if (JS_GetOwnPropertyNames(value->engine->context, &properties, &count, value->value, JS_GPN_STRING_MASK | JS_GPN_ENUM_ONLY) < 0) {
        set_error(value->engine);
        return NULL;
    }
    LnakoQuickJsKeys *keys = calloc(1, sizeof(*keys));
    if (!keys) {
        JS_FreePropertyEnum(value->engine->context, properties, count);
        return NULL;
    }
    keys->items = calloc(count, sizeof(*keys->items));
    keys->item_lengths = calloc(count, sizeof(*keys->item_lengths));
    if (count && (!keys->items || !keys->item_lengths)) {
        free(keys->items);
        free(keys->item_lengths);
        free(keys);
        JS_FreePropertyEnum(value->engine->context, properties, count);
        return NULL;
    }
    keys->engine = value->engine;
    keys->length = count;
    lnako_qjs_retain(keys->engine);
    for (uint32_t index = 0; index < count; index++) {
        size_t length = 0;
        const char *name = JS_AtomToCStringLen(value->engine->context, &length, properties[index].atom);
        if (name) {
            keys->items[index] = copy_bytes(name, length);
            keys->item_lengths[index] = length;
            JS_FreeCString(value->engine->context, name);
        }
    }
    JS_FreePropertyEnum(value->engine->context, properties, count);
    return keys;
}

size_t lnako_qjs_keys_length(const LnakoQuickJsKeys *keys) { return keys ? keys->length : 0; }

const char *lnako_qjs_key(const LnakoQuickJsKeys *keys, size_t index, size_t *length) {
    if (!keys || index >= keys->length) return NULL;
    if (length) *length = keys->item_lengths[index];
    return keys->items[index];
}

void lnako_qjs_keys_free(LnakoQuickJsKeys *keys) {
    if (!keys) return;
    for (size_t index = 0; index < keys->length; index++) free(keys->items[index]);
    free(keys->items);
    free(keys->item_lengths);
    LnakoQuickJs *engine = keys->engine;
    free(keys);
    lnako_qjs_release(engine);
}
