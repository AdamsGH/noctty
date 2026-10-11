// Console-API observer for hidden-win11-console-key-records.ps1 and
// hidden-win11-herdr-mouse.ps1. No terminal protocols are enabled or emitted:
// this records the INPUT_RECORDs a console client receives from ConPTY (or
// from a real console window, as the reference). Every KEY_EVENT is written,
// key up included, plus MOUSE_EVENT and FOCUS_EVENT rows, so the harness
// decides what matters per case.
//
//   observer <records.csv> <ready.txt> <stop.txt> [input mode, hex] [vt-mouse]
//
// With "vt-mouse" the observer also asks for SGR mouse reporting itself
// (CSI ?1003;1006h on its stdout), the request a VT application makes; without
// it the only mouse request is the one the console host derives from
// ENABLE_MOUSE_INPUT in the input mode (newer OpenConsole builds only).
//
// The input mode defaults to 0x98 (ENABLE_WINDOW_INPUT | ENABLE_MOUSE_INPUT |
// ENABLE_EXTENDED_FLAGS): the mode crossterm's EnableMouseCapture leaves
// behind, with no ENABLE_VIRTUAL_TERMINAL_INPUT, which is what herdr 0.8.2
// runs with. The ready file holds "pid,mode,consoleWindow,bufferWidth,
// bufferHeight,windowLeft,windowTop,windowRight,windowBottom".
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <share.h>
#include <string.h>

int wmain(int argc, wchar_t **argv) {
    HANDLE input = GetStdHandle(STD_INPUT_HANDLE);
    HANDLE output = GetStdHandle(STD_OUTPUT_HANDLE);
    DWORD mode = 0, wanted = 0x98, count = 0;
    CONSOLE_SCREEN_BUFFER_INFO info = {0};
    FILE *records = NULL, *ready = NULL;
    ULONGLONG deadline = GetTickCount64() + 120000;
    if (argc < 4 || argc > 6) return 2;
    if (argc >= 5) wanted = (DWORD)wcstoul(argv[4], NULL, 16);
    if (!SetConsoleMode(input, wanted) || !GetConsoleMode(input, &mode) || mode != wanted) return 3;
    records = _wfsopen(argv[1], L"wb", _SH_DENYNO);
    if (!records) return 4;
    fprintf(records, "Event,KeyDown,Repeat,VirtualKey,ScanCode,CodeUnit,ControlState,X,Y,ButtonState,EventFlags\n");
    fflush(records);
    if (_wfopen_s(&ready, argv[2], L"wb") || !ready) { fclose(records); return 5; }
    GetConsoleScreenBufferInfo(output, &info);
    if (argc == 6 && wcscmp(argv[5], L"vt-mouse") == 0) {
        DWORD written = 0, out_mode = 0;
        GetConsoleMode(output, &out_mode);
        SetConsoleMode(output, out_mode | 0x0004 /* ENABLE_VIRTUAL_TERMINAL_PROCESSING */);
        WriteConsoleW(output, L"\x1b[?1003;1006h", 12, &written, NULL);
    }
    fprintf(ready, "%lu,%lu,%llu,%d,%d,%d,%d,%d,%d\n", GetCurrentProcessId(), mode,
        (unsigned long long)(ULONG_PTR)GetConsoleWindow(), info.dwSize.X, info.dwSize.Y,
        info.srWindow.Left, info.srWindow.Top, info.srWindow.Right, info.srWindow.Bottom);
    fclose(ready);
    while (GetTickCount64() < deadline && GetFileAttributesW(argv[3]) == INVALID_FILE_ATTRIBUTES) {
        INPUT_RECORD batch[64];
        if (WaitForSingleObject(input, 50) != WAIT_OBJECT_0) continue;
        if (!ReadConsoleInputW(input, batch, 64, &count)) { fclose(records); return 6; }
        for (DWORD i = 0; i < count; ++i) {
            INPUT_RECORD *r = &batch[i];
            if (r->EventType == KEY_EVENT) {
                KEY_EVENT_RECORD *key = &r->Event.KeyEvent;
                fprintf(records, "KEY,%d,%u,%u,%u,%u,%lu,,,,\n", key->bKeyDown ? 1 : 0,
                    (unsigned)key->wRepeatCount, (unsigned)key->wVirtualKeyCode,
                    (unsigned)key->wVirtualScanCode, (unsigned)key->uChar.UnicodeChar,
                    key->dwControlKeyState);
            } else if (r->EventType == MOUSE_EVENT) {
                MOUSE_EVENT_RECORD *m = &r->Event.MouseEvent;
                fprintf(records, "MOUSE,,,,,,%lu,%d,%d,%lu,%lu\n", m->dwControlKeyState,
                    m->dwMousePosition.X, m->dwMousePosition.Y, m->dwButtonState, m->dwEventFlags);
            } else if (r->EventType == FOCUS_EVENT) {
                fprintf(records, "FOCUS,%d,,,,,,,,,\n", r->Event.FocusEvent.bSetFocus ? 1 : 0);
            } else if (r->EventType == WINDOW_BUFFER_SIZE_EVENT) {
                fprintf(records, "SIZE,,,,,,,%d,%d,,\n", r->Event.WindowBufferSizeEvent.dwSize.X,
                    r->Event.WindowBufferSizeEvent.dwSize.Y);
            }
        }
        fflush(records);
    }
    fclose(records);
    return 0;
}
