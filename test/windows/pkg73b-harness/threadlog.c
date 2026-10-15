/* MEASUREMENT ONLY (PKG-73b): log every thread that starts in the process.
 *
 * Loaded by an instrumented noctty (NOCTTY_GLDIAG letter L). On each
 * DLL_THREAD_ATTACH it appends "N <qpc> <tid> <start module>+0x<off>" to the
 * file named by PKG73_THREADLOG; DLL_THREAD_DETACH appends "X <qpc> <tid>".
 */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>

typedef LONG(NTAPI *NtQit)(HANDLE, ULONG, PVOID, ULONG, PULONG);
static HANDLE out = INVALID_HANDLE_VALUE;
static NtQit qit;

static void put(const char *s, int n) {
    DWORD w;
    if (out != INVALID_HANDLE_VALUE) WriteFile(out, s, (DWORD)n, &w, NULL);
}

BOOL WINAPI DllMain(HINSTANCE inst, DWORD reason, LPVOID reserved) {
    (void)inst; (void)reserved;
    char line[400];
    LARGE_INTEGER q;
    QueryPerformanceCounter(&q);
    if (reason == DLL_PROCESS_ATTACH) {
        wchar_t path[600];
        DWORD n = GetEnvironmentVariableW(L"PKG73_THREADLOG", path, 600);
        if (n == 0 || n >= 600) return TRUE;
        out = CreateFileW(path, FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE, NULL, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
        qit = (NtQit)GetProcAddress(GetModuleHandleA("ntdll.dll"), "NtQueryInformationThread");
        int k = _snprintf_s(line, sizeof(line), _TRUNCATE, "A %lld %lu\n", q.QuadPart, GetCurrentThreadId());
        put(line, k);
    } else if (reason == DLL_THREAD_ATTACH) {
        PVOID sa = NULL;
        if (qit) qit(GetCurrentThread(), 9, &sa, sizeof(sa), NULL);
        HMODULE m = NULL;
        char name[MAX_PATH] = "?";
        if (sa && GetModuleHandleExA(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT, (LPCSTR)sa, &m)) {
            char full[MAX_PATH];
            if (GetModuleFileNameA(m, full, MAX_PATH)) {
                const char *b = strrchr(full, '\\');
                strcpy_s(name, sizeof(name), b ? b + 1 : full);
            }
        }
        int k = _snprintf_s(line, sizeof(line), _TRUNCATE, "N %lld %lu %s+0x%llx\n", q.QuadPart, GetCurrentThreadId(), name,
                            (unsigned long long)((ULONG_PTR)sa - (ULONG_PTR)m));
        put(line, k);
    } else if (reason == DLL_THREAD_DETACH) {
        int k = _snprintf_s(line, sizeof(line), _TRUNCATE, "X %lld %lu\n", q.QuadPart, GetCurrentThreadId());
        put(line, k);
    }
    return TRUE;
}
