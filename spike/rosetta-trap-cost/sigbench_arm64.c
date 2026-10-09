/* sigbench_arm64.c: the same SIGILL round trip as sigbench.c, natively on arm64, for comparison.
 * udf #0 caught by a SIGILL handler that steps over it (pc += 4), on an alternate signal stack.
 * A second argument starts that many threads spinning first (2026-10-08).
 * Build: clang -arch arm64 -O2 -o sigbench_arm64 sigbench_arm64.c */
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ucontext.h>
#include <mach/mach_time.h>
#include <pthread.h>
static volatile int stop;
static void *spin(void *p) { volatile unsigned long x = 0; while (!stop) x++; return NULL; }
static double now_us(void) { static mach_timebase_info_data_t tb; if (!tb.denom) mach_timebase_info(&tb); return (double)mach_absolute_time() * tb.numer / tb.denom / 1000.0; }
static void on_ill(int sig, siginfo_t *si, void *ctx) { ((ucontext_t *)ctx)->uc_mcontext->__ss.__pc += 4; }
int main(int argc, char **argv) {
    int n = argc > 1 ? atoi(argv[1]) : 200000;
    int load = argc > 2 ? atoi(argv[2]) : 0;
    for (int i = 0; i < load; i++) { pthread_t th; pthread_create(&th, NULL, spin, NULL); }
    stack_t ss = { .ss_sp = malloc(1 << 16), .ss_size = 1 << 16, .ss_flags = 0 }; sigaltstack(&ss, NULL);
    struct sigaction sa; memset(&sa, 0, sizeof sa); sa.sa_sigaction = on_ill; sa.sa_flags = SA_SIGINFO | SA_ONSTACK; sigaction(SIGILL, &sa, NULL);
    for (int i = 0; i < 1000; i++) __asm__ volatile("udf #0");
    double t = now_us(); for (int i = 0; i < n; i++) __asm__ volatile("udf #0");
    double us = (now_us() - t) / n; stop = 1;
    printf("arm64 native: %.2f us per udf trapped by SIGILL (%d traps, busy threads %d)\n", us, n, load);
    return 0;
}
