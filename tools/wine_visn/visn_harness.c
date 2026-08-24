/*
 * visn_harness.c - run the shipped Eng3d.dll VISN decoder and dump its output.
 *
 * This is a 32-bit Windows console program (built with i686-w64-mingw32-gcc,
 * run under Wine) whose only job is to be a thin, honest shim around the
 * game's own decoder so its RGB565 output can be compared byte-for-byte
 * against our from-scratch Python implementation.
 *
 * ABI, recovered from the export thunks in Eng3d.dll:
 *
 *   _E3D_init_vision      @ 0x4023d8  push ebx/esi/edi
 *                                     mov eax,[esp+0x10]   ; arg1
 *                                     call 0x413bb6
 *                                     pop/pop/pop; ret     ; -> plain cdecl
 *
 *   _E3D_decode_picture   @ 0x4023e8  mov eax,[esp+0x18]   ; arg3 -> EAX
 *                                     mov edi,[esp+0x14]   ; arg2 -> EDI
 *                                     mov esi,[esp+0x10]   ; arg1 -> ESI
 *                                     call 0x41263c
 *
 * i.e. the exports really are ordinary cdecl functions; only the *internal*
 * routines use the register convention.  arg1 = pointer to the VISN record
 * (0x41264 9 does `cmp dword [esi], 'VISN'`), arg2 = destination pixel buffer,
 * arg3 = destination stride in pixels (compared against [0x41a988], whose
 * initial value is 256).
 *
 * The callee wraps its whole body in pushal/popal, so EAX on return is just
 * the stride echoed back - there is NO usable return code.  Success is
 * therefore detected structurally: the destination buffer is pre-filled with
 * a poison byte and the harness reports exactly which bytes changed.
 *
 * Job file format (little-endian), produced by the Python drivers:
 *
 *   "VJOB"                4
 *   u32 count
 *   u32 op                0 = _E3D_decode_picture
 *                         1 = _E3D_decode_picture_halve_size
 *                         2 = _E3D_convert_picblock_from_64kcolor_to_32kcolor
 *   u32 stride            destination stride in pixels (arg3)
 *   u32 pixel_format      _E3D_init_vision argument: 0x565 or 0x555
 *   u32 out_bytes         destination buffer size, i.e. bytes captured per record
 *   count x { u32 rec_off, u32 rec_len }     offsets are from the file start
 *   ... record bytes ...
 *
 * For op 2 the "record" is not a VISN record but a raw packed-pixel buffer;
 * rec_len/2 is passed as the routine's element count.
 *
 * Result file format:
 *
 *   "VOUT"                4
 *   u32 count
 *   u32 out_bytes         payload bytes captured per record
 *   u32 op
 *   count x { u32 touched, u32 first_diff, u32 last_diff, u32 guard_dirty }
 *       touched      : bytes in [0, out_bytes) that differ from the poison
 *       first_diff   : lowest such byte offset, 0xFFFFFFFF if none
 *       last_diff    : highest such byte offset, 0xFFFFFFFF if none
 *       guard_dirty  : bytes past out_bytes that were overwritten (must be 0)
 *   count x out_bytes payload
 */

#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define POISON      0xA5
/* Default destination: 128 KiB, one full 256x256 RGB565 page. The job file may
 * ask for more, which is what lets pictures larger than the game's texture page
 * be tested at all. */
#define DEFAULT_OUT_BYTES (256 * 256 * 2)
#define MAX_OUT_BYTES     (64u * 1024u * 1024u)
#define GUARD_BYTES (256 * 1024)      /* generous overrun canary */

typedef void (__cdecl *pfn_init_vision)(int fmt);
typedef void (__cdecl *pfn_decode)(const void *src, void *dst, int stride);
typedef void (__cdecl *pfn_convert)(const void *src, void *dst, int count);
typedef int  (__cdecl *pfn_version)(void);
typedef void (__cdecl *pfn_void)(void);

/* The engine caches the destination stride in [0x41a988] (initial value 256) and,
 * whenever a decode asks for a different one, calls 0x413570 -- which PATCHES ITS
 * OWN CODE, storing 2*stride into the immediate operands of four instructions
 * inside the mode-0 colour stage. Eng3d.dll's BEGTEXT section is not writable, so
 * that store faults on any modern loader. Making the code pages writable lets the
 * stride path run, which is the only way to exercise a pitch other than 256. */
static void unprotect_code(HMODULE h)
{
    IMAGE_DOS_HEADER *dos = (IMAGE_DOS_HEADER *)h;
    IMAGE_NT_HEADERS32 *nt;
    IMAGE_SECTION_HEADER *sec;
    unsigned i;
    DWORD old;

    nt = (IMAGE_NT_HEADERS32 *)((char *)h + dos->e_lfanew);
    sec = IMAGE_FIRST_SECTION(nt);
    for (i = 0; i < nt->FileHeader.NumberOfSections; i++) {
        if (!(sec[i].Characteristics & IMAGE_SCN_MEM_EXECUTE)) continue;
        if (VirtualProtect((char *)h + sec[i].VirtualAddress,
                           sec[i].Misc.VirtualSize, PAGE_EXECUTE_READWRITE, &old))
            fprintf(stderr, "harness: made section %.8s writable\n", sec[i].Name);
        else
            fprintf(stderr, "harness: VirtualProtect on %.8s failed\n", sec[i].Name);
    }
}

static void die(const char *what)
{
    fprintf(stderr, "harness: %s (GetLastError=%lu)\n", what, GetLastError());
    exit(2);
}

static void *slurp(const char *path, size_t *out_len)
{
    FILE *f = fopen(path, "rb");
    long n;
    void *buf;
    if (!f) { fprintf(stderr, "harness: cannot open %s\n", path); exit(2); }
    fseek(f, 0, SEEK_END);
    n = ftell(f);
    fseek(f, 0, SEEK_SET);
    buf = malloc((size_t)n);
    if (!buf) { fprintf(stderr, "harness: out of memory\n"); exit(2); }
    if (fread(buf, 1, (size_t)n, f) != (size_t)n) {
        fprintf(stderr, "harness: short read on %s\n", path); exit(2);
    }
    fclose(f);
    *out_len = (size_t)n;
    return buf;
}

static unsigned rd32(const unsigned char *p) 
{
    return (unsigned)p[0] | ((unsigned)p[1] << 8)
         | ((unsigned)p[2] << 16) | ((unsigned)p[3] << 24);
}

static void wr32(FILE *f, unsigned v)
{
    unsigned char b[4];
    b[0] = (unsigned char)(v);       b[1] = (unsigned char)(v >> 8);
    b[2] = (unsigned char)(v >> 16); b[3] = (unsigned char)(v >> 24);
    fwrite(b, 1, 4, f);
}

int main(int argc, char **argv)
{
    HMODULE h;
    pfn_init_vision init_vision;
    pfn_decode decode = NULL;
    pfn_convert convert = NULL;
    pfn_version version;
    pfn_void error_box_off;
    const char *dll_path, *job_path, *out_path;
    unsigned char *job, *dst;
    size_t job_len;
    unsigned count, op, stride, pixel_format, out_bytes, i;
    const unsigned char *index;
    FILE *out;
    unsigned *stats;

    if (argc < 2) {
        fprintf(stderr,
            "usage: %s <Eng3d.dll> [job.bin out.bin]\n"
            "  with no job file, runs the load/liveness self-test only\n"
            "  set VISN_WRITABLE_TEXT=1 to allow the DLL's self-modifying\n"
            "  stride patch (needed for any stride other than 256)\n"
            "  set VISN_POKE_STRIDE=N to seed the stride cache instead\n"
            "  set VISN_PIXEL_FORMAT=0x555 to override the job's format\n", argv[0]);
        return 2;
    }
    dll_path = argv[1];

    h = LoadLibraryA(dll_path);
    if (!h) die("LoadLibraryA failed");
    /* Printed so that a fault EIP reported by Wine can be mapped back to the
       0x400000-based addresses used throughout the analysis. */
    fprintf(stderr, "harness: Eng3d.dll loaded at 0x%08lX (preferred base 0x00400000)\n",
            (unsigned long)(UINT_PTR)h);

    /* Exports carry the leading underscore of the original .def file. */
    version       = (pfn_version)     GetProcAddress(h, "_E3D_get_engine_version");
    init_vision   = (pfn_init_vision) GetProcAddress(h, "_E3D_init_vision");
    error_box_off = (pfn_void)        GetProcAddress(h, "_E3D_error_box_off");
    if (!version || !init_vision) die("GetProcAddress failed");

    /* Liveness probe: this one is `mov eax,0x64; ret`, so it proves the whole
       load + GetProcAddress + call path works before we blame the decoder. */
    {
        int v = version();
        fprintf(stderr, "harness: E3D_get_engine_version() = %d (expect 100)\n", v);
        if (v != 100) { fprintf(stderr, "harness: liveness probe FAILED\n"); return 3; }
    }

    /* Eng3d imports MessageBoxA; suppress any modal error box so a failure
       cannot hang us headless. */
    if (error_box_off) error_box_off();

    if (getenv("VISN_WRITABLE_TEXT")) unprotect_code(h);

    /* The stride cache lives at 0x0041a988 (initial value 256) in the writable
     * DGROUP section. Pre-seeding it makes _E3D_decode_picture skip the
     * self-modifying patch at 0x413570, which is the only thing that stops a
     * non-256 stride from working on a loader that honours page protection.
     * Only the mode-0 colour stage reads the patched immediates, so mode 2
     * decodes correctly at any stride once the call is skipped. */
    {
        const char *poke = getenv("VISN_POKE_STRIDE");
        if (poke) {
            int *cache = (int *)((char *)h + 0x1a988);
            fprintf(stderr, "harness: stride cache at 0x0041a988 was %d, seeding %d\n",
                    *cache, atoi(poke));
            *cache = atoi(poke);
        }
    }

    if (argc < 4) {
        /* Self-test: the format only decides which colour tables get built, so
           the liveness path uses the one the game itself uses. */
        init_vision(0x565);
        fprintf(stderr, "harness: E3D_init_vision(0x565) returned\n");
        fprintf(stderr, "harness: self-test OK\n");
        return 0;
    }
    job_path = argv[2];
    out_path = argv[3];

    job = (unsigned char *) slurp(job_path, &job_len);
    if (job_len < 24 || memcmp(job, "VJOB", 4) != 0) {
        fprintf(stderr, "harness: bad job file magic\n"); return 2;
    }
    count        = rd32(job + 4);
    op           = rd32(job + 8);
    stride       = rd32(job + 12);
    pixel_format = rd32(job + 16);
    out_bytes    = rd32(job + 20);
    index        = job + 24;

    if (!pixel_format) pixel_format = 0x565;
    {
        const char *forced = getenv("VISN_PIXEL_FORMAT");
        if (forced) pixel_format = (unsigned) strtoul(forced, NULL, 0);
    }
    if (!out_bytes) out_bytes = DEFAULT_OUT_BYTES;
    if (out_bytes > MAX_OUT_BYTES) {
        fprintf(stderr, "harness: out_bytes %u exceeds the %u cap\n",
                out_bytes, MAX_OUT_BYTES);
        return 2;
    }

    /* 0x565 -> the nibbles 5,6,5 are split out at 0x413a2d as the B/G/R field
       widths, so this selects the RGB565 colour tables; 0x555 selects RGB555.
       This only rebuilds the three channel tables, so calling it once per job
       is enough. */
    init_vision((int) pixel_format);
    fprintf(stderr, "harness: E3D_init_vision(0x%03X) returned\n", pixel_format);

    if (op == 2) {
        convert = (pfn_convert) GetProcAddress(h,
            "_E3D_convert_picblock_from_64kcolor_to_32kcolor");
        if (!convert)
            die("GetProcAddress(_E3D_convert_picblock_from_64kcolor_to_32kcolor) failed");
    } else {
        decode = (pfn_decode) GetProcAddress(h, op == 1
            ? "_E3D_decode_picture_halve_size" : "_E3D_decode_picture");
        if (!decode) die("GetProcAddress on the decode entry point failed");
    }
    fprintf(stderr, "harness: count=%u op=%u stride=%u out_bytes=%u\n",
            count, op, stride, out_bytes);

    dst = (unsigned char *) VirtualAlloc(NULL, out_bytes + GUARD_BYTES,
                                         MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
    if (!dst) die("VirtualAlloc failed");

    stats = (unsigned *) calloc(count, 4 * sizeof(unsigned));
    if (!stats) { fprintf(stderr, "harness: out of memory\n"); return 2; }

    out = fopen(out_path, "wb");
    if (!out) { fprintf(stderr, "harness: cannot create %s\n", out_path); return 2; }

    /* Header, then a stats block, then the payloads.  The stats block is
       rewritten at the end once every record has run. */
    fwrite("VOUT", 1, 4, out);
    wr32(out, count);
    wr32(out, out_bytes);
    wr32(out, op);
    fwrite(stats, 4 * sizeof(unsigned), count, out);

    for (i = 0; i < count; i++) {
        unsigned rec_off = rd32(index + i * 8);
        unsigned rec_len = rd32(index + i * 8 + 4);
        unsigned touched = 0, guard_dirty = 0;
        unsigned first = 0xFFFFFFFFu, last = 0xFFFFFFFFu;
        unsigned j;

        if ((size_t)rec_off + rec_len > job_len) {
            fprintf(stderr, "harness: record %u out of range\n", i); return 2;
        }

        memset(dst, POISON, out_bytes + GUARD_BYTES);
        if (op == 2) {
            /* The routine's counter is `sar ecx,1` feeding a dec/jne do-while,
               so a count of 0 or 1 wraps ecx to 2**32-1 and runs away through
               memory. Refuse those rather than take the process down. */
            unsigned n = rec_len / 2;
            if (n < 2) {
                fprintf(stderr, "harness: record %u has count %u; the routine's "
                        "do-while underflows below 2, refusing\n", i, n);
                return 2;
            }
            convert(job + rec_off, dst, (int) n);
        } else {
            decode(job + rec_off, dst, (int)stride);
        }

        for (j = 0; j < out_bytes; j++) {
            if (dst[j] != POISON) {
                touched++;
                if (first == 0xFFFFFFFFu) first = j;
                last = j;
            }
        }
        for (j = out_bytes; j < out_bytes + GUARD_BYTES; j++)
            if (dst[j] != POISON) guard_dirty++;

        stats[i * 4 + 0] = touched;
        stats[i * 4 + 1] = first;
        stats[i * 4 + 2] = last;
        stats[i * 4 + 3] = guard_dirty;

        fwrite(dst, 1, out_bytes, out);
    }

    fseek(out, 16, SEEK_SET);
    fwrite(stats, 4 * sizeof(unsigned), count, out);
    fclose(out);
    fprintf(stderr, "harness: wrote %s\n", out_path);
    return 0;
}
