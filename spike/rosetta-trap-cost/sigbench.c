/* sigbench.c: the floor under Wine's exception cost on Rosetta (2026-10-07, the Forza stall).
 * An x86_64 macOS program: ud2 caught by a SIGILL handler that steps over it (on an alternate signal
 * stack, with a signal mask like Wine's), int3 caught by SIGTRAP, and pthread_sigmask round trips.
 * A second argument starts that many threads spinning first, like a game keeping the cores busy (2026-10-08).
 * Build: clang -arch x86_64 -O2 -o sigbench sigbench.c ; run under Rosetta. */
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <sys/ucontext.h>
#include <mach/mach_time.h>

static double now_us(void) {
    static mach_timebase_info_data_t tb; if (!tb.denom) mach_timebase_info(&tb);
    return (double)mach_absolute_time() * tb.numer / tb.denom / 1000.0;
}

static void on_ill(int sig, siginfo_t *si, void *ctx) { ((ucontext_t *)ctx)->uc_mcontext->__ss.__rip += 2; }
static void on_trap(int sig, siginfo_t *si, void *ctx) { (void)ctx; }
static volatile int stop;
static void *spin(void *p) { volatile unsigned long x = 0; while (!stop) x++; return NULL; }

int main(int argc, char **argv) {
    int n = argc > 1 ? atoi(argv[1]) : 200000;
    int load = argc > 2 ? atoi(argv[2]) : 0;
    for (int i = 0; i < load; i++) { pthread_t t; pthread_create(&t, NULL, spin, NULL); }
    stack_t ss = { .ss_sp = malloc(1 << 16), .ss_size = 1 << 16, .ss_flags = 0 };
    sigaltstack(&ss, NULL);
    struct sigaction sa; memset(&sa, 0, sizeof sa);
    sa.sa_sigaction = on_ill; sa.sa_flags = SA_SIGINFO | SA_ONSTACK;
    sigemptyset(&sa.sa_mask); sigaddset(&sa.sa_mask, SIGUSR1); sigaddset(&sa.sa_mask, SIGUSR2); sigaddset(&sa.sa_mask, SIGALRM); sigaddset(&sa.sa_mask, SIGIO);
    sigaction(SIGILL, &sa, NULL);
    sa.sa_sigaction = on_trap; sigaction(SIGTRAP, &sa, NULL);

    double t = now_us();
    for (int i = 0; i < n; i++) __asm__ volatile("ud2");
    double ud = (now_us() - t) / n;

    t = now_us();
    for (int i = 0; i < n; i++) __asm__ volatile("int3");
    double bp = (now_us() - t) / n;

    sigset_t block, old; sigemptyset(&block); sigaddset(&block, SIGUSR1); sigaddset(&block, SIGIO);
    t = now_us();
    for (int i = 0; i < n; i++) { pthread_sigmask(SIG_BLOCK, &block, &old); pthread_sigmask(SIG_SETMASK, &old, NULL); }
    double sm = (now_us() - t) / n;

    sa.sa_sigaction = on_trap; sigaction(SIGUSR2, &sa, NULL);
    t = now_us();
    for (int i = 0; i < n; i++) pthread_kill(pthread_self(), SIGUSR2);
    double sw = (now_us() - t) / n;

    /* the same ud2 without the alternate stack */
    sa.sa_sigaction = on_ill; sa.sa_flags = SA_SIGINFO; sigaction(SIGILL, &sa, NULL);
    t = now_us();
    for (int i = 0; i < n; i++) __asm__ volatile("ud2");
    double ud2 = (now_us() - t) / n;

    stop = 1;
    printf("per signal: ud2/SIGILL %.2f us (no altstack %.2f), int3/SIGTRAP %.2f us, pthread_kill/SIGUSR2 %.2f us; pthread_sigmask block+restore %.2f us (n=%d, busy threads %d)\n", ud, ud2, bp, sw, sm, n, load);
    return 0;
}
