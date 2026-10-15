// MEASUREMENT ONLY (PKG-37): a TUI that holds synchronized output (mode 2026)
// across several writes. Runs inside noctty's pseudo console. Each cycle
// writes BSU, then four rows `hold_ms / 4` apart, then ESU, then idles
// 100 ms. While the hold lasts the terminal is dirty but must not present.
// The log has QPC-stamped `B <qpc> <i>` (BSU written) and `E <qpc> <i>` (ESU
// written) lines.
//
// usage: held.exe <hold_ms> <cycles> <log path> <ready path>
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <timeapi.h>
#include <stdio.h>
#include <stdlib.h>

static void put(HANDLE out, const char *s, int n) {
    DWORD written = 0;
    WriteFile(out, s, (DWORD)n, &written, NULL);
}

int main(int argc, char **argv) {
    if (argc < 5) return 2;
    int hold_ms = atoi(argv[1]);
    int cycles = atoi(argv[2]);
    if (hold_ms < 4 || cycles <= 0) return 2;
    LARGE_INTEGER now;
    timeBeginPeriod(1);
    HANDLE out = GetStdHandle(STD_OUTPUT_HANDLE);
    SetConsoleMode(out, ENABLE_PROCESSED_OUTPUT | ENABLE_VIRTUAL_TERMINAL_PROCESSING | DISABLE_NEWLINE_AUTO_RETURN);
    FILE *log;
    if (fopen_s(&log, argv[3], "w") != 0) return 3;
    const char alt[] = "\x1b[?1049h\x1b[?25l\x1b[H\x1b[2J";
    put(out, alt, sizeof(alt) - 1);
    FILE *ready;
    if (fopen_s(&ready, argv[4], "w") == 0) { fprintf(ready, "ready\n"); fclose(ready); }
    Sleep(1500);
    char buf[256];
    for (int i = 0; i < cycles; i++) {
        QueryPerformanceCounter(&now);
        fprintf(log, "B %lld %d\n", now.QuadPart, i);
        put(out, "\x1b[?2026h", 8);
        for (int row = 0; row < 4; row++) {
            int n = sprintf_s(buf, sizeof(buf), "\x1b[%d;1H\x1b[Kcycle %06d row %d", row + 1, i, row);
            put(out, buf, n);
            Sleep(hold_ms / 4);
        }
        QueryPerformanceCounter(&now);
        fprintf(log, "E %lld %d\n", now.QuadPart, i);
        put(out, "\x1b[?2026l", 8);
        Sleep(100);
    }
    fclose(log);
    const char done[] = "\x1b[?25h\x1b[?1049l";
    put(out, done, sizeof(done) - 1);
    // Stay alive so the window stays open; the driver's job ends us.
    Sleep(60000);
    return 0;
}
