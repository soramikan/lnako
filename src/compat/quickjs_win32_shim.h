/*
 * Windows x86_64向け QuickJS 互換 shim。
 *
 * QuickJS の C ソースは MinGW の `libmingwex` / `libwinpthread` が提供する
 * 実装（`__isnan` 等の math 組込み、pthread、`gettimeofday`）を参照する。
 * MSVC の静的 CRT と `lld-link` でリンクする構成ではこれらのシンボルが
 * 無いか、DLL インポート前提になるため、ここで C ランタイム／Win32 API の
 * 実装へ置き換える。
 *
 * このヘッダは QuickJS と bridge の C ソースへ `-include` で先頭投入する。
 * 標準ヘッダをすべて読み込んだ後にマクロを定義し、ヘッダ自身の宣言を
 * 壊さないようにする。`printf` は `__attribute__((format(printf, ...)))` と
 * 衝突するため置換しない。
 */
#ifndef LNAKO_QJS_WIN32_SHIM_H
#define LNAKO_QJS_WIN32_SHIM_H

#if defined(_WIN32)

/* UCRT の stdio 実装が __local_stdio_printf_options を参照しないようにする。 */
#define _CRT_INTERNAL_LOCAL_PRINTF_OPTIONS 0ULL
#define _CRT_INTERNAL_LOCAL_SCANF_OPTIONS 0ULL

#include <stddef.h>
#include <stdarg.h>
#include <stdint.h>
#include <time.h>
#include <sys/time.h>
#include <math.h>
#include <stdio.h>
#include <assert.h>
#include <pthread.h>

#ifdef __cplusplus
extern "C" {
#endif

int lnako_qjs_win32_vsnprintf(char *buffer, size_t count, const char *format, va_list args);
int lnako_qjs_win32_snprintf(char *buffer, size_t count, const char *format, ...);
int lnako_qjs_win32_fprintf(FILE *stream, const char *format, ...);
void lnako_qjs_win32_assert(int expression, const char *expression_text, const char *file, unsigned line);

int lnako_qjs_win32_gettimeofday(struct timeval *tv, void *timezone);
int lnako_qjs_win32_clock_gettime(int clock_id, struct timespec *ts);

int lnako_qjs_win32_mutex_init(pthread_mutex_t *mutex, const void *attr);
int lnako_qjs_win32_mutex_destroy(pthread_mutex_t *mutex);
int lnako_qjs_win32_mutex_lock(pthread_mutex_t *mutex);
int lnako_qjs_win32_mutex_unlock(pthread_mutex_t *mutex);

int lnako_qjs_win32_cond_init(pthread_cond_t *cond, const void *attr);
int lnako_qjs_win32_cond_destroy(pthread_cond_t *cond);
int lnako_qjs_win32_cond_signal(pthread_cond_t *cond);
int lnako_qjs_win32_cond_broadcast(pthread_cond_t *cond);
int lnako_qjs_win32_cond_wait(pthread_cond_t *cond, pthread_mutex_t *mutex);
int lnako_qjs_win32_cond_timedwait(pthread_cond_t *cond, pthread_mutex_t *mutex, const struct timespec *abstime);

#ifdef __cplusplus
}
#endif

/* math.h のマクロは libmingwex の __isnan / __fpclassify / __signbit を
 * 参照するため、コンパイラ組込みへ置き換える。 */
#undef isnan
#undef isinf
#undef isfinite
#undef signbit
#undef fpclassify
#define isnan(value) __builtin_isnan(value)
#define isinf(value) __builtin_isinf(value)
#define isfinite(value) __builtin_isfinite(value)
#define signbit(value) __builtin_signbit(value)
#define fpclassify(value) __builtin_fpclassify(FP_NAN, FP_INFINITE, FP_NORMAL, FP_SUBNORMAL, FP_ZERO, (value))

/* MSVC の libucrt.lib には fprintf / snprintf / vsnprintf が非インラインで
 * 存在しない構成があるため、UCRT の __stdio_common_* を呼ぶ実装へ置換する。 */
#undef fprintf
#undef snprintf
#undef vsnprintf
#define fprintf lnako_qjs_win32_fprintf
#define snprintf lnako_qjs_win32_snprintf
#define vsnprintf lnako_qjs_win32_vsnprintf

/* MinGW の _assert は __mingw_* へ展開されるため、自前の abort 実装へ置換する。 */
#undef assert
#define assert(expression) lnako_qjs_win32_assert((expression) ? 1 : 0, #expression, __FILE__, __LINE__)

/* MinGW の gettimeofday / clock_gettime は libmingwex / libwinpthread を参照する。 */
#undef gettimeofday
#undef clock_gettime
#define gettimeofday(tv, timezone) lnako_qjs_win32_gettimeofday((tv), (timezone))
#define clock_gettime(clock_id, ts) lnako_qjs_win32_clock_gettime((clock_id), (ts))

/* pthread の init マクロは libwinpthread の SRWLOCK / CONDITION_VARIABLE と
 * 初期値が異なるため、Win32 のゼロ初期値へ揃える。 */
#undef PTHREAD_MUTEX_INITIALIZER
#undef PTHREAD_COND_INITIALIZER
#define PTHREAD_MUTEX_INITIALIZER 0
#define PTHREAD_COND_INITIALIZER 0

#undef pthread_mutex_init
#undef pthread_mutex_destroy
#undef pthread_mutex_lock
#undef pthread_mutex_unlock
#undef pthread_cond_init
#undef pthread_cond_destroy
#undef pthread_cond_signal
#undef pthread_cond_broadcast
#undef pthread_cond_wait
#undef pthread_cond_timedwait
#define pthread_mutex_init lnako_qjs_win32_mutex_init
#define pthread_mutex_destroy lnako_qjs_win32_mutex_destroy
#define pthread_mutex_lock lnako_qjs_win32_mutex_lock
#define pthread_mutex_unlock lnako_qjs_win32_mutex_unlock
#define pthread_cond_init lnako_qjs_win32_cond_init
#define pthread_cond_destroy lnako_qjs_win32_cond_destroy
#define pthread_cond_signal lnako_qjs_win32_cond_signal
#define pthread_cond_broadcast lnako_qjs_win32_cond_broadcast
#define pthread_cond_wait lnako_qjs_win32_cond_wait
#define pthread_cond_timedwait lnako_qjs_win32_cond_timedwait

#endif /* _WIN32 */

#endif /* LNAKO_QJS_WIN32_SHIM_H */
