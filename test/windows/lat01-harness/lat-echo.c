// MEASUREMENT ONLY (LAT-01): a console program that echoes what it reads,
// each byte `delay_ms` after it arrived, like a remote shell behind a
// network round trip. Runs inside noctty's pseudo console.
//
// usage: lat-echo.exe <delay_ms> <vt|records|ssh> <log path> <ready path> [plain|line|tui]
//   plain : echo the byte
//   line  : redraw the whole input line with colours and a grey suggestion,
//           like zsh with syntax highlighting and autosuggestions
//   tui   : alternate screen; rewrite the input row and a status bar
//   vt      : ENABLE_VIRTUAL_TERMINAL_INPUT, ReadFile bytes (ssh.exe, WSL)
//   records : ReadConsoleInputW key-down characters (console-API readers)
//   ssh     : what Win32-OpenSSH's ReadConsoleForTermEmulModern does: VT input
//             mode, alertable wait, ReadConsoleInputW, key-down (or VK_MENU)
//             records with a character or a zero scan code
// After every 60 echoed characters it writes CR LF, so a line never wraps.
// The log has one line per received byte (R) and per written byte (W),
// QPC-stamped, written at exit or every 256 entries.
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <timeapi.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define QCAP 65536
typedef struct { LONGLONG due; unsigned char ch; } Item;
static Item queue_items[QCAP];
static volatile LONG q_head = 0, q_tail = 0;
static CRITICAL_SECTION q_lock;
static HANDLE q_event;
static HANDLE out_handle;
static LONGLONG freq;
static LONGLONG delay_ticks;
static FILE *log_file;
static int style; // 0 plain, 1 line, 2 tui
static unsigned long long echo_count;
static CRITICAL_SECTION log_lock;

static LONGLONG now_qpc(void) {
    LARGE_INTEGER v;
    QueryPerformanceCounter(&v);
    return v.QuadPart;
}

static void log_event(char kind, LONGLONG t, unsigned ch) {
    EnterCriticalSection(&log_lock);
    fprintf(log_file, "%c %lld %u\n", kind, t, ch);
    LeaveCriticalSection(&log_lock);
}

static void enqueue(unsigned char ch) {
    LONGLONG t = now_qpc();
    log_event('R', t, ch);
    EnterCriticalSection(&q_lock);
    LONG tail = q_tail;
    if (((tail + 1) % QCAP) != q_head) {
        queue_items[tail].due = t + delay_ticks;
        queue_items[tail].ch = ch;
        q_tail = (tail + 1) % QCAP;
    }
    LeaveCriticalSection(&q_lock);
    SetEvent(q_event);
}

static DWORD WINAPI writer(LPVOID unused) {
    (void)unused;
    unsigned column = 0;
    for (;;) {
        Item item = {0, 0};
        BOOL have = FALSE;
        EnterCriticalSection(&q_lock);
        if (q_head != q_tail) {
            item = queue_items[q_head];
            have = TRUE;
        }
        LeaveCriticalSection(&q_lock);
        if (!have) {
            WaitForSingleObject(q_event, INFINITE);
            continue;
        }
        for (;;) {
            LONGLONG remaining = item.due - now_qpc();
            if (remaining <= 0) break;
            LONGLONG ms = remaining * 1000 / freq;
            if (ms >= 2) Sleep((DWORD)(ms - 1));
            else YieldProcessor();
        }
        EnterCriticalSection(&q_lock);
        q_head = (q_head + 1) % QCAP;
        LeaveCriticalSection(&q_lock);

        char out[512];
        DWORD n = 0;
        if (style != 0 && item.ch != '\r') {
            static char line[64];
            static int len;
            if (len >= 60) len = 0;
            line[len++] = (char)item.ch;
            echo_count++;
            int m;
            if (style == 1) {
                m = sprintf_s(out, sizeof(out),
                    "\x1b[?25l\r\x1b[38;5;39m> \x1b[1;32m%.*s\x1b[0;90m%s\x1b[0m\x1b[K\r\x1b[%dC\x1b[?25h",
                    len, line, "-suggested-completion", 2 + len);
            } else {
                m = sprintf_s(out, sizeof(out),
                    "\x1b[?25l\x1b[10;1H\x1b[1;33m%.*s\x1b[0m\x1b[K\x1b[30;1H\x1b[7m NORMAL  keys=%llu  col=%d  lat01 \x1b[0m\x1b[K\x1b[10;%dH\x1b[?25h",
                    len, line, echo_count, len, len + 1);
            }
            if (m > 0) n = (DWORD)m;
        } else if (item.ch == '\r') {
            out[n++] = '\r';
            out[n++] = '\n';
            column = 0;
        } else {
            out[n++] = (char)item.ch;
            column++;
            if (column >= 60) {
                out[n++] = '\r';
                out[n++] = '\n';
                column = 0;
            }
        }
        DWORD written = 0;
        log_event('W', now_qpc(), item.ch);
        WriteFile(out_handle, out, n, &written, NULL);
    }
}

int main(int argc, char **argv) {
    if (argc < 5) return 2;
    int delay_ms = atoi(argv[1]);
    BOOL ssh = strcmp(argv[2], "ssh") == 0;
    if (argc > 5) style = strcmp(argv[5], "line") == 0 ? 1 : strcmp(argv[5], "tui") == 0 ? 2 : 0;
    BOOL records = ssh || strcmp(argv[2], "records") == 0;
    LARGE_INTEGER f;
    QueryPerformanceFrequency(&f);
    freq = f.QuadPart;
    delay_ticks = (LONGLONG)delay_ms * freq / 1000;
    timeBeginPeriod(1);
    InitializeCriticalSection(&q_lock);
    InitializeCriticalSection(&log_lock);
    q_event = CreateEventW(NULL, FALSE, FALSE, NULL);
    if (fopen_s(&log_file, argv[3], "w") != 0) return 3;
    setvbuf(log_file, NULL, _IOFBF, 1 << 20);

    HANDLE in = GetStdHandle(STD_INPUT_HANDLE);
    out_handle = GetStdHandle(STD_OUTPUT_HANDLE);
    DWORD out_mode = ENABLE_PROCESSED_OUTPUT | ENABLE_VIRTUAL_TERMINAL_PROCESSING | DISABLE_NEWLINE_AUTO_RETURN;
    SetConsoleMode(out_handle, out_mode);
    DWORD in_mode = (records && !ssh) ? ENABLE_WINDOW_INPUT : (ENABLE_VIRTUAL_TERMINAL_INPUT | ENABLE_WINDOW_INPUT);
    SetConsoleMode(in, in_mode);

    HANDLE thread = CreateThread(NULL, 0, writer, NULL, 0, NULL);
    if (!thread) return 4;
    SetThreadPriority(thread, THREAD_PRIORITY_ABOVE_NORMAL);

    const char banner[] = "lat-echo ready\r\n";
    DWORD written = 0;
    WriteFile(out_handle, banner, sizeof(banner) - 1, &written, NULL);
    if (style == 2) {
        const char alt[] = "\x1b[?1049h\x1b[H\x1b[2J";
        WriteFile(out_handle, alt, sizeof(alt) - 1, &written, NULL);
    }
    FILE *ready;
    if (fopen_s(&ready, argv[4], "w") == 0) {
        fprintf(ready, "%lld\n", now_qpc());
        fclose(ready);
    }

    for (;;) {
        if (records) {
            INPUT_RECORD rec[64];
            DWORD count = 0;
            if (ssh && WaitForSingleObjectEx(in, INFINITE, TRUE) != WAIT_OBJECT_0) break;
            if (!ReadConsoleInputW(in, rec, 64, &count)) break;
            for (DWORD i = 0; i < count; i++) {
                if (rec[i].EventType != KEY_EVENT) continue;
                const KEY_EVENT_RECORD *k = &rec[i].Event.KeyEvent;
                if (ssh) {
                    if (!((k->bKeyDown || k->wVirtualKeyCode == VK_MENU) &&
                          (k->uChar.UnicodeChar != 0 || k->wVirtualScanCode == 0))) continue;
                } else if (!k->bKeyDown || k->uChar.UnicodeChar == 0) continue;
                if (k->uChar.UnicodeChar == 0x04) goto done;
                for (WORD r = 0; r < (k->wRepeatCount ? k->wRepeatCount : 1); r++)
                    enqueue((unsigned char)k->uChar.UnicodeChar);
            }
        } else {
            unsigned char buf[256];
            DWORD n = 0;
            if (!ReadFile(in, buf, sizeof(buf), &n, NULL) || n == 0) break;
            for (DWORD i = 0; i < n; i++) {
                if (buf[i] == 0x04) goto done;
                enqueue(buf[i]);
            }
        }
        EnterCriticalSection(&log_lock);
        fflush(log_file);
        LeaveCriticalSection(&log_lock);
    }
done:
    Sleep(delay_ms + 200);
    EnterCriticalSection(&log_lock);
    fflush(log_file);
    LeaveCriticalSection(&log_lock);
    return 0;
}
