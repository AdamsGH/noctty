/* MEASUREMENT ONLY (PKG-73b): time a system-wide Toolhelp thread walk, the
 * work the NVIDIA GL driver's server thread does during the F028 stall.
 * usage: thwalk.exe [reps]   prints threads seen and ms per walk.
 */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <tlhelp32.h>
#include <stdio.h>
#include <stdlib.h>

int main(int argc, char **argv) {
    int reps = argc > 1 ? atoi(argv[1]) : 5;
    LARGE_INTEGER f, a, b, c;
    QueryPerformanceFrequency(&f);
    for (int r = 0; r < reps; r++) {
        QueryPerformanceCounter(&a);
        HANDLE s = CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0);
        QueryPerformanceCounter(&b);
        if (s == INVALID_HANDLE_VALUE) return 1;
        THREADENTRY32 te = {sizeof(te)};
        int n = 0, mine = 0;
        DWORD pid = GetCurrentProcessId();
        for (BOOL ok = Thread32First(s, &te); ok; ok = Thread32Next(s, &te)) {
            n++;
            if (te.th32OwnerProcessID == pid) mine++;
        }
        QueryPerformanceCounter(&c);
        CloseHandle(s);
        printf("threads=%d own=%d snapshot_ms=%.1f walk_ms=%.1f total_ms=%.1f\n", n, mine,
               (b.QuadPart - a.QuadPart) * 1000.0 / f.QuadPart, (c.QuadPart - b.QuadPart) * 1000.0 / f.QuadPart,
               (c.QuadPart - a.QuadPart) * 1000.0 / f.QuadPart);
    }
    return 0;
}
