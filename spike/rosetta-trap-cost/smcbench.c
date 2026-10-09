/* smcbench.c: what code written at run time costs under Rosetta (2026-10-07, the Forza stall).
 * An RWX page holds "mov eax, imm32; ret". Per iteration: (a) call only, (b) write a data byte elsewhere in
 * the same page then call, (c) rewrite the function's immediate then call, (d) write a byte in another page
 * then call, (e) rewrite a fresh 4 KB of code (64 functions) then call one.
 * clang -arch x86_64 -O2 -o smcbench smcbench.c */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <mach/mach_time.h>
static double now_us(void) { static mach_timebase_info_data_t tb; if (!tb.denom) mach_timebase_info(&tb); return (double)mach_absolute_time() * tb.numer / tb.denom / 1000.0; }
typedef int (*fn)(void);
static void emit(unsigned char *p, int v) { p[0] = 0xb8; memcpy(p + 1, &v, 4); p[5] = 0xc3; }
int main(int argc, char **argv) {
    int n = argc > 1 ? atoi(argv[1]) : 20000;
    int jit = argc > 2 && atoi(argv[2]);
    unsigned char *code = mmap(NULL, 1 << 16, PROT_READ | PROT_WRITE | PROT_EXEC, MAP_PRIVATE | MAP_ANON | (jit ? MAP_JIT : 0), -1, 0);
    printf("%s\n", jit ? "MAP_JIT" : "plain RWX");
    unsigned char *other = code + 0x8000;
    if (code == MAP_FAILED) { perror("mmap"); return 1; }
    emit(code, 1); fn f = (fn)code; volatile int sink = 0;
    double t = now_us(); for (int i = 0; i < n; i++) sink += f(); double a = (now_us() - t) / n;
    t = now_us(); for (int i = 0; i < n; i++) { code[2048] = (unsigned char)i; sink += f(); } double b = (now_us() - t) / n;
    t = now_us(); for (int i = 0; i < n; i++) { memcpy(code + 1, &i, 4); sink += f(); } double c = (now_us() - t) / n;
    t = now_us(); for (int i = 0; i < n; i++) { other[0] = (unsigned char)i; sink += f(); } double d = (now_us() - t) / n;
    /* the region is 16 KB aligned (mmap on Apple silicon): code at +0, writes at +0x1000, +0x2000, +0x3000 (other 4 KB pages, same
       16 KB host page) and +0x4000 (the next host page) */
    double w4[5]; int offs[5] = { 0x800, 0x1000, 0x2000, 0x3000, 0x4000 };
    for (int k = 0; k < 5; k++) { t = now_us(); for (int i = 0; i < n; i++) { code[offs[k]] = (unsigned char)i; sink += f(); } w4[k] = (now_us() - t) / n; }
    printf("write then call, by write offset from the code: +0x800 %.2f, +0x1000 %.2f, +0x2000 %.2f, +0x3000 %.2f, +0x4000 %.2f us\n", w4[0], w4[1], w4[2], w4[3], w4[4]);
    unsigned char *big = code + 0x4000;
    t = now_us(); for (int i = 0; i < n / 10; i++) { for (int k = 0; k < 64; k++) emit(big + k * 64, i + k); sink += ((fn)(big + (i % 64) * 64))(); } double e = (now_us() - t) / (n / 10);
    printf("per iteration: call %.2f us, data write in the code page + call %.2f us, code rewrite + call %.2f us, write in another page + call %.2f us, rewrite 64 functions + call one %.2f us (sink %d)\n", a, b, c, d, e, sink);
    return 0;
}
