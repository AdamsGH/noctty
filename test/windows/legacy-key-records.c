// Console-API observer for hidden-win11-legacy-keys.ps1. No terminal protocols
// are enabled or emitted: this observes ConPTY's legacy INPUT_RECORD parser.
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <share.h>

int wmain(int argc, wchar_t **argv) {
    HANDLE input = GetStdHandle(STD_INPUT_HANDLE);
    DWORD mode = 0, count = 0;
    FILE *records = NULL, *ready = NULL;
    ULONGLONG deadline = GetTickCount64() + 120000;
    if (argc != 4) return 2;
    if (!SetConsoleMode(input, 0x98) || !GetConsoleMode(input, &mode) || mode != 0x98) return 3;
    records = _wfsopen(argv[1], L"wb", _SH_DENYNO);
    if (!records) return 4;
    fprintf(records, "CodeUnit,VirtualKey,ControlState\n");
    fflush(records);
    if (_wfopen_s(&ready, argv[2], L"wb") || !ready) { fclose(records); return 5; }
    fprintf(ready, "%lu,%lu\n", GetCurrentProcessId(), mode);
    fclose(ready);
    while (GetTickCount64() < deadline && GetFileAttributesW(argv[3]) == INVALID_FILE_ATTRIBUTES) {
        INPUT_RECORD batch[64];
        if (WaitForSingleObject(input, 50) != WAIT_OBJECT_0) continue;
        if (!ReadConsoleInputW(input, batch, 64, &count)) { fclose(records); return 6; }
        for (DWORD i = 0; i < count; ++i) {
            if (batch[i].EventType != KEY_EVENT || !batch[i].Event.KeyEvent.bKeyDown) continue;
            KEY_EVENT_RECORD *key = &batch[i].Event.KeyEvent;
            for (WORD repeat = 0; repeat < key->wRepeatCount; ++repeat)
                fprintf(records, "%u,%u,%lu\n", (unsigned)key->uChar.UnicodeChar,
                    (unsigned)key->wVirtualKeyCode, key->dwControlKeyState);
        }
        fflush(records);
    }
    fclose(records);
    return 0;
}
