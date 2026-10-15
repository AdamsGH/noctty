/* MEASUREMENT ONLY (JUMPLIST-02): steady output with directory changes.
 *
 * usage: cdflood.exe [ignored]
 * For 20 s writes coloured log lines continuously (a few hundred KB/s) and,
 * every 700 ms, an OSC 7 reporting the next of a few local directories, so
 * the terminal records a new recent directory and its jump list rebuilds
 * while output is streaming. Writes only to stdout.
 */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>

int main(void) {
    static const char *dirs[] = {"C:/Windows", "C:/Users", "C:/Program%20Files", "C:/Windows/System32", "C:/ProgramData"};
    char host[MAX_COMPUTERNAME_LENGTH + 1];
    DWORD hl = sizeof(host);
    if (!GetComputerNameA(host, &hl)) host[0] = 0;
    HANDLE out = GetStdHandle(STD_OUTPUT_HANDLE);
    ULONGLONG start = GetTickCount64(), last_cd = 0;
    unsigned i = 0, d = 0;
    char buf[512];
    DWORD w;
    while (GetTickCount64() - start < 20000) {
        ULONGLONG now = GetTickCount64();
        if (now - last_cd >= 700) {
            last_cd = now;
            int n = _snprintf_s(buf, sizeof(buf), _TRUNCATE, "\x1b]7;file://%s/%s\x07", host, dirs[d++ % 5]);
            WriteFile(out, buf, (DWORD)n, &w, NULL);
        }
        int n = _snprintf_s(buf, sizeof(buf), _TRUNCATE,
                            "\x1b[2m%08u\x1b[0m \x1b[38;5;%um INFO\x1b[0m request handled path=/api/v1/items status=200 bytes=%u\r\n",
                            i, 16 + (i % 200), i * 7);
        WriteFile(out, buf, (DWORD)n, &w, NULL);
        i++;
        if (i % 64 == 0) Sleep(1);
    }
    return 0;
}
