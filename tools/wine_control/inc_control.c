#include <windows.h>
#include <tlhelp32.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static HDESK control_desktop;

static BOOL enum_top(WNDENUMPROC callback, LPARAM opaque) {
    return control_desktop ? EnumDesktopWindows(control_desktop, callback, opaque)
                           : EnumWindows(callback, opaque);
}

static DWORD find_process(const char *name) {
    PROCESSENTRY32 entry = {.dwSize = sizeof(entry)};
    HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    DWORD pid = 0;
    if (snapshot == INVALID_HANDLE_VALUE) return 0;
    if (Process32First(snapshot, &entry)) {
        do {
            if (_stricmp(entry.szExeFile, name) == 0) {
                pid = entry.th32ProcessID;
                break;
            }
        } while (Process32Next(snapshot, &entry));
    }
    CloseHandle(snapshot);
    return pid;
}

struct window_search { DWORD pid; HWND hwnd; };

static BOOL CALLBACK list_window(HWND hwnd, LPARAM unused) {
    DWORD pid = 0;
    RECT rect;
    char title[256] = {0};
    char class_name[128] = {0};
    (void)unused;
    GetWindowThreadProcessId(hwnd, &pid);
    GetClientRect(hwnd, &rect);
    GetWindowTextA(hwnd, title, sizeof(title));
    GetClassNameA(hwnd, class_name, sizeof(class_name));
    printf("pid=%lu hwnd=%p visible=%d client=%ldx%ld class=%s title=%s\n",
           pid, hwnd, IsWindowVisible(hwnd), rect.right, rect.bottom,
           class_name, title);
    return TRUE;
}

static BOOL CALLBACK find_window(HWND hwnd, LPARAM opaque) {
    struct window_search *search = (struct window_search *)opaque;
    DWORD pid = 0;
    GetWindowThreadProcessId(hwnd, &pid);
    if (pid == search->pid) {
        search->hwnd = hwnd;
        if (IsWindowVisible(hwnd)) return FALSE;
    }
    return TRUE;
}

static int capture(HWND hwnd, const char *path) {
    RECT rect;
    BITMAPINFOHEADER header = {0};
    BITMAPFILEHEADER file = {0};
    HDC source = NULL, memory = NULL;
    HBITMAP bitmap = NULL, previous = NULL;
    unsigned char *pixels = NULL;
    FILE *out = NULL;
    int width, height, stride, ok = 0;

    if (!GetClientRect(hwnd, &rect)) goto done;
    width = rect.right;
    height = rect.bottom;
    stride = (width * 3 + 3) & ~3;
    source = GetDC(hwnd);
    memory = CreateCompatibleDC(source);
    bitmap = CreateCompatibleBitmap(source, width, height);
    if (!source || !memory || !bitmap) goto done;
    previous = SelectObject(memory, bitmap);
    if (!BitBlt(memory, 0, 0, width, height, source, 0, 0, SRCCOPY)) goto done;

    pixels = (unsigned char *)malloc((size_t)stride * height);
    if (!pixels) goto done;
    header.biSize = sizeof(header);
    header.biWidth = width;
    header.biHeight = height;
    header.biPlanes = 1;
    header.biBitCount = 24;
    header.biCompression = BI_RGB;
    header.biSizeImage = stride * height;
    if (!GetDIBits(memory, bitmap, 0, height, pixels,
                   (BITMAPINFO *)&header, DIB_RGB_COLORS)) goto done;

    file.bfType = 0x4d42;
    file.bfOffBits = sizeof(file) + sizeof(header);
    file.bfSize = file.bfOffBits + header.biSizeImage;
    out = fopen(path, "wb");
    if (!out) goto done;
    ok = fwrite(&file, sizeof(file), 1, out) == 1 &&
         fwrite(&header, sizeof(header), 1, out) == 1 &&
         fwrite(pixels, header.biSizeImage, 1, out) == 1;

done:
    if (out) fclose(out);
    free(pixels);
    if (previous) SelectObject(memory, previous);
    if (bitmap) DeleteObject(bitmap);
    if (memory) DeleteDC(memory);
    if (source) ReleaseDC(hwnd, source);
    return ok;
}

static void usage(const char *program) {
    fprintf(stderr, "usage: %s [--desktop NAME] PROCESS|hwnd:HANDLE info|capture PATH|enter|space|command TEXT|click X Y|watchmem ADDRESS MS|readmem ADDRESS LENGTH\n", program);
}

static int launch_on_desktop(const char *desktop, int argc, char **argv) {
    STARTUPINFOA startup = {.cb = sizeof(startup), .lpDesktop = (char *)desktop};
    PROCESS_INFORMATION process = {0};
    char executable[MAX_PATH];
    char command[2048];
    size_t used;
    DWORD exit_code = 1;
    int i;

    if (!GetModuleFileNameA(NULL, executable, sizeof(executable))) return 7;
    used = (size_t)snprintf(command, sizeof(command), "\"%s\"", executable);
    for (i = 3; i < argc && used < sizeof(command); ++i)
        used += (size_t)snprintf(command + used, sizeof(command) - used, " \"%s\"", argv[i]);
    if (used >= sizeof(command)) return 7;
    if (!CreateProcessA(executable, command, NULL, NULL, FALSE, 0, NULL, NULL,
                        &startup, &process)) {
        fprintf(stderr, "cannot launch on desktop: %s error=%lu\n", desktop, GetLastError());
        return 7;
    }
    WaitForSingleObject(process.hProcess, INFINITE);
    GetExitCodeProcess(process.hProcess, &exit_code);
    CloseHandle(process.hThread);
    CloseHandle(process.hProcess);
    return (int)exit_code;
}

static int watch_memory(DWORD pid, const char *address_text, const char *duration_text) {
    HANDLE process;
    DWORD address = (DWORD)strtoul(address_text, NULL, 0);
    DWORD duration = (DWORD)strtoul(duration_text, NULL, 0);
    DWORD started = GetTickCount();
    DWORD value = 0, previous = 0;
    SIZE_T read = 0;
    int have_previous = 0;

    process = OpenProcess(PROCESS_VM_READ | PROCESS_QUERY_INFORMATION, FALSE, pid);
    if (!process) {
        fprintf(stderr, "cannot open process %lu error=%lu\n", pid, GetLastError());
        return 8;
    }
    while (GetTickCount() - started < duration) {
        if (!ReadProcessMemory(process, (LPCVOID)(ULONG_PTR)address,
                               &value, sizeof(value), &read) || read != sizeof(value)) {
            fprintf(stderr, "cannot read %08lx error=%lu\n", address, GetLastError());
            CloseHandle(process);
            return 8;
        }
        if (!have_previous || value != previous) {
            printf("t=%lu address=%08lx value=%08lx\n",
                   GetTickCount() - started, address, value);
            fflush(stdout);
            previous = value;
            have_previous = 1;
        }
        Sleep(1);
    }
    CloseHandle(process);
    return 0;
}

static int read_memory(DWORD pid, const char *address_text, const char *length_text) {
    HANDLE process;
    DWORD address = (DWORD)strtoul(address_text, NULL, 0);
    size_t length = (size_t)strtoul(length_text, NULL, 0);
    unsigned char *data;
    SIZE_T read = 0;
    size_t i;

    if (!address || !length || length > 4096) {
        fprintf(stderr, "invalid address or length\n");
        return 8;
    }
    process = OpenProcess(PROCESS_VM_READ | PROCESS_QUERY_INFORMATION, FALSE, pid);
    if (!process) {
        fprintf(stderr, "cannot open process %lu error=%lu\n", pid, GetLastError());
        return 8;
    }
    data = (unsigned char *)malloc(length);
    if (!data) {
        CloseHandle(process);
        return 8;
    }
    if (!ReadProcessMemory(process, (LPCVOID)(ULONG_PTR)address,
                           data, length, &read) || read != length) {
        fprintf(stderr, "cannot read %08lx length=%lu read=%lu error=%lu\n",
                address, (unsigned long)length, (unsigned long)read, GetLastError());
        free(data);
        CloseHandle(process);
        return 8;
    }
    for (i = 0; i < length; ++i) {
        if ((i & 15) == 0) printf("%08lx:", address + (DWORD)i);
        printf(" %02x", data[i]);
        if ((i & 15) == 15 || i + 1 == length) putchar('\n');
    }
    free(data);
    CloseHandle(process);
    return 0;
}

static int dump_console(DWORD pid) {
    HANDLE output = GetStdHandle(STD_OUTPUT_HANDLE);
    HANDLE console;
    CONSOLE_SCREEN_BUFFER_INFO info;
    char *line;
    DWORD y, read;

    FreeConsole();
    if (!AttachConsole(pid)) {
        char error[96];
        int length = snprintf(error, sizeof(error),
                              "cannot attach console %lu error=%lu\n",
                              pid, GetLastError());
        WriteFile(output, error, (DWORD)length, &read, NULL);
        return 9;
    }
    console = CreateFileA("CONOUT$", GENERIC_READ | GENERIC_WRITE,
                          FILE_SHARE_READ | FILE_SHARE_WRITE,
                          NULL, OPEN_EXISTING, 0, NULL);
    if (console == INVALID_HANDLE_VALUE || !GetConsoleScreenBufferInfo(console, &info))
        return 9;
    line = (char *)malloc((size_t)info.dwSize.X + 2);
    if (!line) return 9;
    for (y = 0; y < (DWORD)info.dwSize.Y; ++y) {
        COORD origin = {0, (SHORT)y};
        DWORD length = 0;
        if (!ReadConsoleOutputCharacterA(console, line, info.dwSize.X,
                                         origin, &length))
            continue;
        while (length && line[length - 1] == ' ') --length;
        if (!length) continue;
        line[length++] = '\n';
        WriteFile(output, line, length, &read, NULL);
    }
    free(line);
    CloseHandle(console);
    return 0;
}

static int break_process(DWORD pid) {
    HANDLE process = OpenProcess(PROCESS_SUSPEND_RESUME | PROCESS_QUERY_INFORMATION,
                                 FALSE, pid);
    int ok;
    if (!process) {
        fprintf(stderr, "cannot open process %lu error=%lu\n", pid, GetLastError());
        return 10;
    }
    ok = DebugBreakProcess(process);
    if (!ok)
        fprintf(stderr, "DebugBreakProcess %lu failed error=%lu\n",
                pid, GetLastError());
    CloseHandle(process);
    return ok ? 0 : 10;
}

int main(int argc, char **argv) {
    struct window_search search = {0};
    RECT rect;
    char title[256] = {0};
    LPARAM point;
    char desktop_name[128] = {0};

    if (argc >= 4 && strcmp(argv[1], "--desktop") == 0)
        return launch_on_desktop(argv[2], argc, argv);

    if (GetEnvironmentVariableA("INC_DESKTOP", desktop_name, sizeof(desktop_name))) {
        control_desktop = OpenDesktopA(desktop_name, 0, FALSE,
            DESKTOP_READOBJECTS | DESKTOP_WRITEOBJECTS | DESKTOP_SWITCHDESKTOP);
        if (!control_desktop || !SetThreadDesktop(control_desktop)) {
            fprintf(stderr, "cannot open desktop: %s error=%lu\n",
                    desktop_name, GetLastError());
            return 6;
        }
    }

    if (argc < 3) { usage(argv[0]); return 2; }
    if (strcmp(argv[1], "all") == 0 && strcmp(argv[2], "info") == 0) {
        enum_top(list_window, 0);
        return 0;
    }
    if (strncmp(argv[1], "hwnd:", 5) == 0) {
        search.hwnd = (HWND)(ULONG_PTR)strtoul(argv[1] + 5, NULL, 0);
        if (!IsWindow(search.hwnd)) {
            fprintf(stderr, "window not found: %s\n", argv[1] + 5);
            return 4;
        }
        GetWindowThreadProcessId(search.hwnd, &search.pid);
    } else {
        search.pid = (DWORD)strtoul(argv[1], NULL, 0);
        if (!search.pid) search.pid = find_process(argv[1]);
        if (!search.pid) { fprintf(stderr, "process not found: %s\n", argv[1]); return 3; }
        if (strcmp(argv[2], "debugbreak") == 0)
            return break_process(search.pid);
        if (strcmp(argv[2], "console") == 0)
            return dump_console(search.pid);
        if (strcmp(argv[2], "watchmem") == 0 && argc == 5)
            return watch_memory(search.pid, argv[3], argv[4]);
        if (strcmp(argv[2], "readmem") == 0 && argc == 5)
            return read_memory(search.pid, argv[3], argv[4]);
        enum_top(find_window, (LPARAM)&search);
    }
    if (!search.hwnd) { fprintf(stderr, "visible window not found for pid %lu\n", search.pid); return 4; }

    GetClientRect(search.hwnd, &rect);
    GetWindowTextA(search.hwnd, title, sizeof(title));
    printf("pid=%lu hwnd=%p visible=%d client=%ldx%ld title=%s\n",
           search.pid, search.hwnd, IsWindowVisible(search.hwnd),
           rect.right, rect.bottom, title);

    if (strcmp(argv[2], "info") == 0) return 0;
    if (strcmp(argv[2], "capture") == 0 && argc == 4)
        return capture(search.hwnd, argv[3]) ? 0 : 5;
    if (strcmp(argv[2], "enter") == 0 || strcmp(argv[2], "space") == 0) {
        WPARAM key = strcmp(argv[2], "enter") == 0 ? VK_RETURN : VK_SPACE;
        PostMessageA(search.hwnd, WM_KEYDOWN, key, 0);
        PostMessageA(search.hwnd, WM_KEYUP, key, 0);
        return 0;
    }
    if (strcmp(argv[2], "command") == 0 && argc == 4) {
        const unsigned char *text = (const unsigned char *)argv[3];
        while (*text) {
            PostMessageA(search.hwnd, WM_CHAR, *text, 1);
            ++text;
        }
        PostMessageA(search.hwnd, WM_KEYDOWN, VK_RETURN, 0);
        PostMessageA(search.hwnd, WM_CHAR, '\r', 1);
        PostMessageA(search.hwnd, WM_KEYUP, VK_RETURN, 0);
        return 0;
    }
    if (strcmp(argv[2], "click") == 0 && argc == 5) {
        point = MAKELPARAM(atoi(argv[3]), atoi(argv[4]));
        PostMessageA(search.hwnd, WM_MOUSEMOVE, 0, point);
        PostMessageA(search.hwnd, WM_LBUTTONDOWN, MK_LBUTTON, point);
        PostMessageA(search.hwnd, WM_LBUTTONUP, 0, point);
        return 0;
    }
    usage(argv[0]);
    return 2;
}
