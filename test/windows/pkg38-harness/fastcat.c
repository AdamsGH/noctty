// MEASUREMENT ONLY (PKG-38): a fast `cat`. Runs inside noctty's pseudo
// console, reads the whole file, then writes it to stdout in 64 KiB
// WriteFile calls as fast as the console takes them (VT processing on), so
// output reaches the terminal at the console's full rate rather than
// cmd `type`'s pace. Stays alive afterwards; the driver's job ends it.
//
// usage: fastcat.exe <file> [seconds]
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>

int main(int argc, char **argv) {
    if (argc < 2) return 2;
    HANDLE out = GetStdHandle(STD_OUTPUT_HANDLE);
    SetConsoleMode(out, ENABLE_PROCESSED_OUTPUT | ENABLE_VIRTUAL_TERMINAL_PROCESSING | DISABLE_NEWLINE_AUTO_RETURN);
    HANDLE f = CreateFileA(argv[1], GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING, 0, NULL);
    if (f == INVALID_HANDLE_VALUE) return 3;
    LARGE_INTEGER size;
    if (!GetFileSizeEx(f, &size)) return 4;
    char *buf = (char *)malloc((size_t)size.QuadPart);
    if (!buf) return 5;
    DWORD got = 0;
    if (!ReadFile(f, buf, (DWORD)size.QuadPart, &got, NULL)) return 6;
    CloseHandle(f);
    // Repeat the file for `seconds` (default 10) so the flood outlasts the
    // driver's 12 s probe window minus start-up.
    int seconds = argc > 2 ? atoi(argv[2]) : 10;
    ULONGLONG until = GetTickCount64() + (ULONGLONG)seconds * 1000;
    const DWORD chunk = 64 * 1024;
    do {
        for (DWORD off = 0; off < got; off += chunk) {
            DWORD n = got - off < chunk ? got - off : chunk;
            DWORD written = 0;
            WriteFile(out, buf + off, n, &written, NULL);
        }
    } while (GetTickCount64() < until);
    Sleep(120000);
    return 0;
}
