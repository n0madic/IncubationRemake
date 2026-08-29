#include <windows.h>

#include <stdio.h>
#include <string.h>

/* cdecl: no arguments at all */
int __attribute__((noinline, cdecl)) t_zero(void)
{
    return 0;
}

/* cdecl: returns a byte in AL, leaving the rest of EAX dirty on purpose --
   the shape of the engine's `mov al, [g_x]; ret` accessors. */
unsigned char __attribute__((noinline, cdecl)) t_byte(int dirty)
{
    volatile int keep = dirty;   /* so EAX is not already the answer */
    (void)keep;
    return (unsigned char)0xFE;
}

/* cdecl: two ints */
int __attribute__((noinline, cdecl)) t_add(int a, int b)
{
    return a * 1000 + b;
}

/* cdecl: float in, float out (ST0) */
float __attribute__((noinline, cdecl)) t_fmul(float a, float b)
{
    return a * b;
}

/* cdecl: double in, double out (ST0) */
double __attribute__((noinline, cdecl)) t_dmul(double a, double b)
{
    return a * b;
}

/* cdecl: 64-bit in and out (EDX:EAX) */
long long __attribute__((noinline, cdecl)) t_add64(long long a, long long b)
{
    return a + b;
}

/* cdecl: a struct by value -- 12 bytes, three whole stack slots */
struct Vec3 { int x, y, z; };

int __attribute__((noinline, cdecl)) t_vec(struct Vec3 v, int k)
{
    return v.x * 1000000 + v.y * 10000 + v.z * 100 + k;
}

/* cdecl: a struct whose size is not a multiple of 4 */
struct Odd { unsigned char a, b, c, d, e; };

int __attribute__((noinline, cdecl)) t_odd(struct Odd o)
{
    return o.a + o.b * 2 + o.c * 3 + o.d * 4 + o.e * 5;
}

/* cdecl: a 4-byte struct by value, for reading one out of live memory */
struct Four { unsigned char a, b, c, d; };

int __attribute__((noinline, cdecl)) t_odd4(struct Four f)
{
    return f.a + f.b * 2 + f.c * 3 + f.d * 4;
}

/* cdecl: string argument */
int __attribute__((noinline, cdecl)) t_slen(const char* s)
{
    return s ? (int)strlen(s) : -1;
}

/* stdcall: callee pops */
int __attribute__((noinline, stdcall)) t_stdsub(int a, int b)
{
    return a - b;
}

/* fastcall: ECX, EDX, then stack */
int __attribute__((noinline, fastcall)) t_fast3(int a, int b, int c)
{
    return a * 100 + b * 10 + c;
}

/* fastcall with a non-register-eligible argument in the middle:
   MSVC scans left to right, so a -> ECX, c -> EDX, d on the stack. */
int __attribute__((noinline, fastcall)) t_fastmix(int a, double b, int c, int d)
{
    return a * 1000 + (int)b * 100 + c * 10 + d;
}

/* thiscall: this in ECX, rest on the stack, callee pops */
struct Obj { int base; };

int __attribute__((noinline, thiscall)) t_method(struct Obj* self, int k)
{
    return self->base + k;
}

struct Obj g_obj = { 7000 };

/* Stands in for an import thunk's slot or a vtable entry: a function address
   that only the running process knows. */
int (__attribute__((cdecl)) *g_addptr)(int, int) = t_add;

void __attribute__((noinline)) t_ready(void)
{
    /* Breakpoint lands here, after the CRT is fully up. */
    printf("[target] ready\n");
    fflush(stdout);
}

int main(int argc, char **argv)
{
    HMODULE lib;
    void (*ready)(void);

    printf("[target] g_obj = %p\n", (void*)&g_obj);
    fflush(stdout);

    /* Wedge before ever reaching the anchor, so the self-test can check that
       --anchor-timeout gives up instead of waiting forever.  This is the shape
       of a start-up fault under Wine: the process is alive, produces no
       further debug event, and no plan line has run. */
    if (argc > 1 && strcmp(argv[1], "--wedge") == 0)
    {
        for (;;)
            Sleep(1000);
    }

    /* Loaded dynamically, like the game's Eng3d.dll: it is in no import
       table, so the debugger only learns its base from the load event. */
    lib = LoadLibraryA("selftest_lib.dll");

    if (!lib)
    {
        printf("[target] LoadLibrary failed\n");
        fflush(stdout);
        return 1;
    }

    ready = (void (*)(void))GetProcAddress(lib, "tl_ready");

    if (ready)
        ready();

    t_ready();

    /* Keep the results alive so nothing is optimized away. */
    {
        struct Vec3 v = { 1, 2, 3 };
        struct Odd o = { 1, 1, 1, 1, 1 };
        struct Four f = { 1, 1, 1, 1 };
        printf("[target] %d %d %d %u\n", t_vec(v, 4), t_odd(o), t_odd4(f),
               (unsigned)t_byte(1));
    }

    printf("[target] %d %f %f %lld %d %d %d %d %d %d\n",
        t_add(1, 2), (double)t_fmul(1.f, 2.f), t_dmul(1.0, 2.0),
        t_add64(1, 2), t_slen("x"), t_stdsub(3, 1),
        t_fast3(1, 2, 3), t_fastmix(1, 2.0, 3, 4), t_method(&g_obj, 1),
        t_zero());
    fflush(stdout);

    return 0;
}
