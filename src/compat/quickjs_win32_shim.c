/*
 * QuickJS Windows x86_64 shim の実装。詳細は quickjs_win32_shim.h を参照。
 *
 * MSVC 静的 CRT 構成では次のシンボルが無い（または DllImport 前提になる）
 * ため、UCRT の __stdio_common_* と Win32 API で置き換える:
 *   - fprintf / snprintf / vsnprintf / assert
 *   - gettimeofday / clock_gettime
 *   - pthread_mutex_* / pthread_cond_*
 */
#if defined(_WIN32)

#include <windows.h>

#include <errno.h>
#include <limits.h>
#include <stdlib.h>

#include "quickjs_win32_shim.h"

_Static_assert(sizeof(pthread_mutex_t) >= sizeof(SRWLOCK), "pthread_mutex_t must hold SRWLOCK");
_Static_assert(sizeof(pthread_cond_t) >= sizeof(CONDITION_VARIABLE), "pthread_cond_t must hold CONDITION_VARIABLE");

int lnako_qjs_win32_vsnprintf(char *buffer, size_t count, const char *format, va_list args) {
    return __stdio_common_vsprintf(_CRT_INTERNAL_PRINTF_STANDARD_SNPRINTF_BEHAVIOR, buffer, count, format, NULL, args);
}

int lnako_qjs_win32_snprintf(char *buffer, size_t count, const char *format, ...) {
    va_list args;
    va_start(args, format);
    const int result = lnako_qjs_win32_vsnprintf(buffer, count, format, args);
    va_end(args);
    return result;
}

int lnako_qjs_win32_fprintf(FILE *stream, const char *format, ...) {
    va_list args;
    va_start(args, format);
    const int result = __stdio_common_vfprintf(0ULL, stream, format, NULL, args);
    va_end(args);
    return result;
}

void lnako_qjs_win32_assert(int expression, const char *expression_text, const char *file, unsigned line) {
    if (expression) return;
    char message[512];
    lnako_qjs_win32_snprintf(message, sizeof(message), "%s:%u: assertion failed: %s\n", file, line, expression_text);
    lnako_qjs_win32_fprintf(stderr, "%s", message);
    abort();
}

/* QuickJS 側のソースが後から <assert.h> を再 include すると、assert マクロが
 * MinGW の _assert 呼び出しへ戻る。MSVC 静的 CRT には _assert が無いため、
 * 実体も shim 側から提供する。 */
void __cdecl _assert(const char *message, const char *file, unsigned line) {
    lnako_qjs_win32_assert(0, message ? message : "", file ? file : "", line);
}

/* 1601-01-01 から 1970-01-01 までの 100ns 単位数。 */
#define LNAKO_QJS_WIN32_UNIX_EPOCH_OFFSET 116444736000000000ULL

static uint64_t lnako_qjs_win32_filetime_ticks(void) {
    FILETIME filetime;
    GetSystemTimeAsFileTime(&filetime);
    return ((uint64_t)filetime.dwHighDateTime << 32) | (uint64_t)filetime.dwLowDateTime;
}

int lnako_qjs_win32_gettimeofday(struct timeval *tv, void *timezone) {
    (void)timezone;
    if (!tv) return -1;
    const uint64_t ticks = lnako_qjs_win32_filetime_ticks() - LNAKO_QJS_WIN32_UNIX_EPOCH_OFFSET;
    tv->tv_sec = (long)(ticks / 10000000ULL);
    tv->tv_usec = (long)((ticks % 10000000ULL) / 10ULL);
    return 0;
}

int lnako_qjs_win32_clock_gettime(int clock_id, struct timespec *ts) {
    (void)clock_id;
    if (!ts) return EINVAL;
    const uint64_t ticks = lnako_qjs_win32_filetime_ticks() - LNAKO_QJS_WIN32_UNIX_EPOCH_OFFSET;
    ts->tv_sec = (time_t)(ticks / 10000000ULL);
    ts->tv_nsec = (long)((ticks % 10000000ULL) * 100ULL);
    return 0;
}

int lnako_qjs_win32_mutex_init(pthread_mutex_t *mutex, const void *attr) {
    (void)attr;
    if (!mutex) return EINVAL;
    InitializeSRWLock((PSRWLOCK)(void *)mutex);
    return 0;
}

int lnako_qjs_win32_mutex_destroy(pthread_mutex_t *mutex) {
    (void)mutex;
    return 0;
}

int lnako_qjs_win32_mutex_lock(pthread_mutex_t *mutex) {
    if (!mutex) return EINVAL;
    AcquireSRWLockExclusive((PSRWLOCK)(void *)mutex);
    return 0;
}

int lnako_qjs_win32_mutex_unlock(pthread_mutex_t *mutex) {
    if (!mutex) return EINVAL;
    ReleaseSRWLockExclusive((PSRWLOCK)(void *)mutex);
    return 0;
}

int lnako_qjs_win32_cond_init(pthread_cond_t *cond, const void *attr) {
    (void)attr;
    if (!cond) return EINVAL;
    InitializeConditionVariable((PCONDITION_VARIABLE)(void *)cond);
    return 0;
}

int lnako_qjs_win32_cond_destroy(pthread_cond_t *cond) {
    (void)cond;
    return 0;
}

int lnako_qjs_win32_cond_signal(pthread_cond_t *cond) {
    if (!cond) return EINVAL;
    WakeConditionVariable((PCONDITION_VARIABLE)(void *)cond);
    return 0;
}

int lnako_qjs_win32_cond_broadcast(pthread_cond_t *cond) {
    if (!cond) return EINVAL;
    WakeAllConditionVariable((PCONDITION_VARIABLE)(void *)cond);
    return 0;
}

int lnako_qjs_win32_cond_wait(pthread_cond_t *cond, pthread_mutex_t *mutex) {
    if (!cond || !mutex) return EINVAL;
    if (!SleepConditionVariableSRW((PCONDITION_VARIABLE)(void *)cond, (PSRWLOCK)(void *)mutex, INFINITE, 0)) return EINVAL;
    return 0;
}

int lnako_qjs_win32_cond_timedwait(pthread_cond_t *cond, pthread_mutex_t *mutex, const struct timespec *abstime) {
    if (!cond || !mutex || !abstime) return EINVAL;
    struct timespec now;
    lnako_qjs_win32_clock_gettime(0, &now);
    const int64_t delta_ns = ((int64_t)abstime->tv_sec - (int64_t)now.tv_sec) * 1000000000LL +
        ((int64_t)abstime->tv_nsec - (int64_t)now.tv_nsec);
    int64_t delta_ms = 0;
    if (delta_ns > 0) delta_ms = (delta_ns + 999999LL) / 1000000LL;
    // 負の差分は 0（即時タイムアウト）、INFINITE 以上は到達不能な上限へ
    // クランプする。SleepConditionVariableSRW の DWORD 引数へ安全に渡す。
    if (delta_ms < 0) delta_ms = 0;
    if (delta_ms >= (int64_t)INFINITE) delta_ms = (int64_t)INFINITE - 1;
    if (!SleepConditionVariableSRW((PCONDITION_VARIABLE)(void *)cond, (PSRWLOCK)(void *)mutex, (DWORD)delta_ms, 0)) {
        const DWORD error = GetLastError();
        if (error == ERROR_TIMEOUT) return ETIMEDOUT;
        return EINVAL;
    }
    return 0;
}

#endif /* _WIN32 */
