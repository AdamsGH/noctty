// MEASUREMENT ONLY (LAT-02): an animated full-screen TUI. Runs inside
// noctty's pseudo console and writes one full-screen frame every
// 1000/fps ms for `seconds`, each inside synchronized output (mode 2026),
// like an animated TUI. The log has one QPC-stamped line per frame written.
//
// usage: anim.exe <fps> <seconds> <log path> <ready path>
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <timeapi.h>
#include <stdio.h>
#include <stdlib.h>

int main(int argc, char **argv) {
    if (argc < 5) return 2;
    int fps = atoi(argv[1]);
    int seconds = atoi(argv[2]);
    if (fps <= 0 || seconds <= 0) return 2;
    LARGE_INTEGER f, t0, now;
    QueryPerformanceFrequency(&f);
    timeBeginPeriod(1);
    HANDLE out = GetStdHandle(STD_OUTPUT_HANDLE);
    SetConsoleMode(out, ENABLE_PROCESSED_OUTPUT | ENABLE_VIRTUAL_TERMINAL_PROCESSING | DISABLE_NEWLINE_AUTO_RETURN);
    FILE *log;
    if (fopen_s(&log, argv[3], "w") != 0) return 3;
    DWORD written = 0;
    const char alt[] = "\x1b[?1049h\x1b[?25l\x1b[H\x1b[2J";
    WriteFile(out, alt, sizeof(alt) - 1, &written, NULL);
    FILE *ready;
    if (fopen_s(&ready, argv[4], "w") == 0) { fprintf(ready, "ready\n"); fclose(ready); }
    Sleep(1500);
    static char buf[16384];
    int frames = fps * seconds;
    QueryPerformanceCounter(&t0);
    for (int i = 0; i < frames; i++) {
        LONGLONG due = t0.QuadPart + (LONGLONG)i * f.QuadPart / fps;
        for (;;) {
            QueryPerformanceCounter(&now);
            LONGLONG left = due - now.QuadPart;
            if (left <= 0) break;
            LONGLONG ms = left * 1000 / f.QuadPart;
            if (ms >= 2) Sleep((DWORD)(ms - 1)); else YieldProcessor();
        }
        int n = sprintf_s(buf, sizeof(buf), "\x1b[?2026h\x1b[H");
        for (int row = 0; row < 28; row++) {
            int col = (i + row * 3) % 80;
            n += sprintf_s(buf + n, sizeof(buf) - n, "\x1b[%d;1H\x1b[K\x1b[%d;%dH\x1b[38;5;%dm#### frame %06d ####\x1b[0m",
                row + 1, row + 1, col + 1, 16 + (i + row) % 200, i);
        }
        n += sprintf_s(buf + n, sizeof(buf) - n, "\x1b[?2026l");
        QueryPerformanceCounter(&now);
        fprintf(log, "W %lld %d\n", now.QuadPart, i);
        WriteFile(out, buf, (DWORD)n, &written, NULL);
    }
    fclose(log);
    const char done[] = "\x1b[?25h\x1b[?1049l";
    WriteFile(out, done, sizeof(done) - 1, &written, NULL);
    // Stay alive so the window stays open; the driver's job ends us.
    Sleep(60000);
    return 0;
}
