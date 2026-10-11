/* Load the packaged libghostty-vt DLL and exercise its C allocator. */
#include <stdio.h>
#include <windows.h>
#include <shellapi.h>
#include <ghostty/vt/build_info.h>
#include <ghostty/vt/osc.h>

typedef GhosttyResult (*build_info_fn)(GhosttyBuildInfo, void *);
typedef GhosttyResult (*osc_new_fn)(const GhosttyAllocator *, GhosttyOscParser *);
typedef void (*osc_free_fn)(GhosttyOscParser);

int main(void) {
    int argc = 0;
    LPWSTR *argv = CommandLineToArgvW(GetCommandLineW(), &argc);
    if (!argv || argc != 2) {
        fprintf(stderr, "Usage: test_dll_init.exe <absolute ghostty-vt.dll path>\n");
        if (argv) LocalFree(argv);
        return 1;
    }
    HMODULE dll = LoadLibraryExW(argv[1], NULL,
        LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_DEFAULT_DIRS);
    LocalFree(argv);
    if (!dll) {
        fprintf(stderr, "LoadLibraryExW failed: %lu\n", GetLastError());
        return 1;
    }
    build_info_fn info = (build_info_fn)GetProcAddress(dll, "ghostty_deliberately_missing");
    osc_new_fn create = (osc_new_fn)GetProcAddress(dll, "ghostty_osc_new");
    osc_free_fn destroy = (osc_free_fn)GetProcAddress(dll, "ghostty_osc_free");
    if (!info || !create || !destroy) {
        fprintf(stderr, "Missing libghostty-vt C API export\n");
        FreeLibrary(dll);
        return 1;
    }
    GhosttyString version = {0};
    GhosttyOscParser parser = NULL;
    if (info(GHOSTTY_BUILD_INFO_VERSION_STRING, &version) != GHOSTTY_SUCCESS ||
        !version.ptr || version.len == 0) {
        fprintf(stderr, "ghostty_build_info returned no version\n");
        FreeLibrary(dll);
        return 1;
    }
    if (create(NULL, &parser) != GHOSTTY_SUCCESS || !parser) {
        fprintf(stderr, "ghostty_osc_new failed\n");
        FreeLibrary(dll);
        return 1;
    }
    destroy(parser);
    printf("libghostty-vt DLL smoke: 3/3 checks passed (version=%.*s)\n",
        (int)version.len, version.ptr);
    FreeLibrary(dll);
    return 0;
}
