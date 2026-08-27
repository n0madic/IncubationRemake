#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

enum { BLOB_SIZE = 88 };

static unsigned long read_u32(const unsigned char *data, size_t offset) {
    unsigned long value;
    memcpy(&value, data + offset, sizeof(value));
    return value;
}

static void print_blob(const unsigned char *blob) {
    unsigned int i;
    printf("blob kind=%u life=%u class=%u delay=%u "
           "pos=(%ld,%ld,%ld) velocity=(%ld,%ld,%ld)\n",
           blob[0x44], blob[0x45], blob[0x56], blob[0x55],
           (long)read_u32(blob, 0x14), (long)read_u32(blob, 0x18),
           (long)read_u32(blob, 0x1c), (long)read_u32(blob, 0x48),
           (long)read_u32(blob, 0x4c), (long)read_u32(blob, 0x50));
    for (i = 0; i < BLOB_SIZE; ++i) {
        if ((i & 15) == 0) printf("blob+%02x:", i);
        printf(" %02x", blob[i]);
        if ((i & 15) == 15 || i + 1 == BLOB_SIZE) putchar('\n');
    }
}

static int build_command(char *command, size_t size, int argc, char **argv) {
    size_t used = 0;
    int i;
    for (i = 3; i < argc; ++i) {
        int written = snprintf(command + used, size - used, "%s\"%s\"",
                               i == 3 ? "" : " ", argv[i]);
        if (written < 0 || (size_t)written >= size - used) return 0;
        used += (size_t)written;
    }
    return 1;
}

static void close_debug_event_handles(const DEBUG_EVENT *event) {
    if (event->dwDebugEventCode == CREATE_PROCESS_DEBUG_EVENT) {
        if (event->u.CreateProcessInfo.hFile)
            CloseHandle(event->u.CreateProcessInfo.hFile);
    } else if (event->dwDebugEventCode == CREATE_THREAD_DEBUG_EVENT) {
        if (event->u.CreateThread.hThread)
            CloseHandle(event->u.CreateThread.hThread);
    } else if (event->dwDebugEventCode == LOAD_DLL_DEBUG_EVENT) {
        if (event->u.LoadDll.hFile) CloseHandle(event->u.LoadDll.hFile);
    }
}

int main(int argc, char **argv) {
    STARTUPINFOA startup = {.cb = sizeof(startup)};
    PROCESS_INFORMATION process = {0};
    DEBUG_EVENT event;
    char command[4096];
    unsigned long target;
    unsigned long original;
    int hit = 0;

    if (argc < 4) {
        fprintf(stderr, "usage: %s ADDRESS ORIGINAL_BYTE EXE [ARGS...]\n", argv[0]);
        return 2;
    }
    target = strtoul(argv[1], NULL, 0);
    original = strtoul(argv[2], NULL, 0);
    if (target == 0 || original > 0xff || !build_command(command, sizeof(command), argc, argv)) {
        fprintf(stderr, "invalid probe arguments\n");
        return 2;
    }

    printf("probe target=%08lx original=%02lx command=%s\n", target, original, command);
    fflush(stdout);
    if (!CreateProcessA(argv[3], command, NULL, NULL, FALSE,
                        DEBUG_ONLY_THIS_PROCESS, NULL, NULL, &startup, &process)) {
        fprintf(stderr, "CreateProcess failed error=%lu\n", GetLastError());
        return 3;
    }
    DebugSetProcessKillOnExit(FALSE);

    for (;;) {
        DWORD status = DBG_CONTINUE;
        if (!WaitForDebugEvent(&event, INFINITE)) {
            fprintf(stderr, "WaitForDebugEvent failed error=%lu\n", GetLastError());
            break;
        }
        close_debug_event_handles(&event);

        if (event.dwDebugEventCode == EXIT_PROCESS_DEBUG_EVENT) {
            fprintf(stderr, "process exited code=%lu before_target=%d\n",
                    event.u.ExitProcess.dwExitCode, !hit);
            ContinueDebugEvent(event.dwProcessId, event.dwThreadId, DBG_CONTINUE);
            CloseHandle(process.hThread);
            CloseHandle(process.hProcess);
            return hit ? 0 : 4;
        }

        if (event.dwDebugEventCode == EXCEPTION_DEBUG_EVENT) {
            DWORD code = event.u.Exception.ExceptionRecord.ExceptionCode;
            DWORD address = (DWORD)(ULONG_PTR)
                event.u.Exception.ExceptionRecord.ExceptionAddress;
            if (code == EXCEPTION_BREAKPOINT && address == target) {
                HANDLE thread = OpenThread(THREAD_GET_CONTEXT | THREAD_SET_CONTEXT,
                                           FALSE, event.dwThreadId);
                CONTEXT context = {.ContextFlags = CONTEXT_FULL};
                unsigned char blob[BLOB_SIZE];
                SIZE_T transferred = 0;
                unsigned char byte = (unsigned char)original;

                if (!thread || !GetThreadContext(thread, &context)) {
                    fprintf(stderr, "GetThreadContext failed error=%lu\n", GetLastError());
                    return 5;
                }
                printf("BREAK pid=%lu tid=%lu exception=%08lx "
                       "EIP=%08lx ESP=%08lx ESI=%08lx\n",
                       event.dwProcessId, event.dwThreadId, address,
                       context.Eip, context.Esp, context.Esi);
                if (!ReadProcessMemory(process.hProcess,
                                       (LPCVOID)(ULONG_PTR)context.Esi,
                                       blob, sizeof(blob), &transferred) ||
                    transferred != sizeof(blob)) {
                    fprintf(stderr, "ReadProcessMemory blob=%08lx read=%lu error=%lu\n",
                            context.Esi, (unsigned long)transferred, GetLastError());
                    return 6;
                }
                print_blob(blob);
                if (!WriteProcessMemory(process.hProcess,
                                        (LPVOID)(ULONG_PTR)target,
                                        &byte, 1, &transferred) || transferred != 1 ||
                    !FlushInstructionCache(process.hProcess,
                                           (LPCVOID)(ULONG_PTR)target, 1)) {
                    fprintf(stderr, "cannot restore target byte error=%lu\n", GetLastError());
                    return 7;
                }
                context.Eip = target;
                if (!SetThreadContext(thread, &context)) {
                    fprintf(stderr, "SetThreadContext failed error=%lu\n", GetLastError());
                    return 8;
                }
                CloseHandle(thread);
                hit = 1;
                fflush(stdout);
            } else if (code != EXCEPTION_BREAKPOINT) {
                status = DBG_EXCEPTION_NOT_HANDLED;
            }
        }

        if (!ContinueDebugEvent(event.dwProcessId, event.dwThreadId, status)) {
            fprintf(stderr, "ContinueDebugEvent failed error=%lu\n", GetLastError());
            break;
        }
        if (hit) {
            Sleep(250);
            {
                DWORD exit_code = 0;
                int alive = GetExitCodeProcess(process.hProcess, &exit_code) &&
                            exit_code == STILL_ACTIVE;
                int detached = DebugActiveProcessStop(process.dwProcessId);
                printf("CONTINUED alive=%d detached=%d detach_error=%lu\n",
                       alive, detached, detached ? 0 : GetLastError());
                fflush(stdout);
                CloseHandle(process.hThread);
                CloseHandle(process.hProcess);
                return alive ? 0 : 9;
            }
        }
    }

    CloseHandle(process.hThread);
    CloseHandle(process.hProcess);
    return 10;
}
