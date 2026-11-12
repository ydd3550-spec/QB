// ساعة النواة (Rust).
//
// في النسخة 7 النواة طاحت على الجهاز في std/src/sys/pal/unix/time.rs:107
//   cvt(clock_gettime(CLOCK_UPTIME_RAW, ..)).unwrap()
// الدالة رجّعت -1 بدون ما تضبط errno، فالخطأ طلع بآخر قيمة قديمة في errno
// (17 File exists من mkdir اللي قبله، أو 2 No such file). moka وtokio يستدعون Instant::now
// أول ما ينبنى الكاش، عشان كذا طاح حتى وضع الذاكرة.
//
// التعريف هذا داخل ملف التطبيق نفسه، فالـ linker يربط استدعاءات Rust في التطبيق فيه
// بدل libSystem. الساعات اللي تحتاجها Rust نحسبها مباشرة من mach_absolute_time
// وmach_continuous_time وgettimeofday (ما تفشل)، والباقي يروح للدالة الأصلية.
// المكتبات الخارجية (Foundation, AVKit, VLC) ما تتأثر.

#include <time.h>
#include <errno.h>
#include <dlfcn.h>
#include <stdint.h>
#include <sys/time.h>
#include <mach/mach_time.h>

static mach_timebase_info_data_t qb_timebase;

static void qb_set_ns(struct timespec *tp, uint64_t ticks) {
    if (qb_timebase.denom == 0) {
        mach_timebase_info_data_t tb;
        if (mach_timebase_info(&tb) != KERN_SUCCESS || tb.denom == 0) { tb.numer = 1; tb.denom = 1; }
        qb_timebase = tb;
    }
    __uint128_t ns = (__uint128_t)ticks * qb_timebase.numer / qb_timebase.denom;
    tp->tv_sec = (time_t)(ns / 1000000000u);
    tp->tv_nsec = (long)(ns % 1000000000u);
}

typedef int (*qb_clock_fn)(clockid_t, struct timespec *);

int clock_gettime(clockid_t clk, struct timespec *tp) {
    if (tp == NULL) { errno = EFAULT; return -1; }
    switch (clk) {
    case CLOCK_REALTIME: {
        struct timeval tv;
        if (gettimeofday(&tv, NULL) != 0) break;
        tp->tv_sec = tv.tv_sec;
        tp->tv_nsec = (long)tv.tv_usec * 1000;
        return 0;
    }
    case CLOCK_UPTIME_RAW:
        qb_set_ns(tp, mach_absolute_time());
        return 0;
    case CLOCK_UPTIME_RAW_APPROX:
        qb_set_ns(tp, mach_approximate_time());
        return 0;
    case CLOCK_MONOTONIC:
    case CLOCK_MONOTONIC_RAW:
        qb_set_ns(tp, mach_continuous_time());
        return 0;
    case CLOCK_MONOTONIC_RAW_APPROX:
        qb_set_ns(tp, mach_continuous_approximate_time());
        return 0;
    default:
        break;
    }
    static qb_clock_fn real = NULL;
    if (real == NULL) {
        void *h = dlopen("/usr/lib/libSystem.B.dylib", RTLD_LAZY | RTLD_NOLOAD);
        if (h != NULL) real = (qb_clock_fn)dlsym(h, "clock_gettime");
    }
    if (real != NULL && real != clock_gettime) {
        int r = real(clk, tp);
        if (r == 0) return 0;
        if (errno == 0) errno = EINVAL;
        return r;
    }
    errno = EINVAL;
    return -1;
}
