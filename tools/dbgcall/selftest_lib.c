// Test DLL for the harness self-test.
//
// Built with a preferred image base of 0x00400000 -- the same address the EXE
// occupies -- so the loader is forced to relocate it on every run, exactly
// like the game's own Eng3d.dll. An address taken from a static disassembly
// of this DLL is therefore meaningless until the debugger has watched it
// load, which is the whole point of the module resolver.

#include <windows.h>

__declspec(dllexport) int tl_mul(int a, int b)
{
    return a * 100 + b;
}

__declspec(dllexport) int __stdcall tl_std3(int a, int b, int c)
{
    return a * 10000 + b * 100 + c;
}

__declspec(dllexport) void tl_fill(unsigned char* out, int n, int seed)
{
    int i;

    for (i = 0; i < n; ++i)
        out[i] = (unsigned char)(seed + i);
}

__declspec(dllexport) int tl_sum(const unsigned char* in, int n)
{
    int i;
    int total = 0;

    for (i = 0; i < n; ++i)
        total += in[i];

    return total;
}

// Never returns, so the self-test can check that --call-timeout gives up
// instead of hanging the whole run.
__declspec(dllexport) void tl_spin(void)
{
    static volatile int guard = 1;

    while (guard)
        ;
}

// The self-test anchors a breakpoint here to prove that a breakpoint can be
// planted inside a module that did not exist when the process started.
__declspec(dllexport) void tl_ready(void)
{
    volatile int keep = 1;
    (void)keep;
}

BOOL WINAPI DllMain(HINSTANCE h, DWORD reason, LPVOID reserved)
{
    (void)h;
    (void)reason;
    (void)reserved;
    return TRUE;
}
