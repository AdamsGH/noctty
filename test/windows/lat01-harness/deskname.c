// MEASUREMENT ONLY (LAT-01): write the calling thread's desktop name to argv[1].
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
int main(int argc, char **argv) {
    if (argc < 2) return 2;
    wchar_t name[256] = {0};
    DWORD needed = 0;
    GetUserObjectInformationW(GetThreadDesktop(GetCurrentThreadId()), UOI_NAME, name, sizeof(name), &needed);
    STARTUPINFOW si;
    GetStartupInfoW(&si);
    FILE *f;
    if (fopen_s(&f, argv[1], "w") != 0) return 3;
    fwprintf(f, L"thread=%ls startup=%ls\n", name, si.lpDesktop ? si.lpDesktop : L"(null)");
    fclose(f);
    return 0;
}
