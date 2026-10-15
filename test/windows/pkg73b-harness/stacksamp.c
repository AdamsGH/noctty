/* MEASUREMENT ONLY (PKG-73b): sample the threads of one process.
 *
 * usage: stacksamp.exe <pid> <duration_ms> <interval_ms> <out file>
 *
 * Every interval: each thread's CPU time since the previous sample. The
 * process's main thread (earliest creation time) and every thread whose
 * start routine is in nvoglv64.dll are suspended briefly and their stacks
 * walked (StackWalk64 over the module unwind tables; no symbols). The
 * thread list is refreshed every 25 samples. Lines:
 *   Q <qpc freq>
 *   M <base> <size> <module name>              (modules, when they change)
 *   S <qpc> <tid> <main 0|1> <cpu_100ns> <start> | frame frame ...
 *   C <qpc> <tid> <cpu_100ns> <start>           (other threads with CPU)
 * Frames and starts are module+0xoffset.
 */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <tlhelp32.h>
#include <psapi.h>
#include <dbghelp.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <timeapi.h>

#pragma comment(lib, "dbghelp.lib")
#pragma comment(lib, "psapi.lib")

typedef LONG(NTAPI *NtQit)(HANDLE, ULONG, PVOID, ULONG, PULONG);

#define MAXT 512
static DWORD tids[MAXT];
static HANDLE th[MAXT];
static ULONGLONG cpu[MAXT];
static ULONGLONG created[MAXT];
static char starts[MAXT][96];
static int walk[MAXT];
static int nt;

static HMODULE mods[1024];
static MODULEINFO minfo[1024];
static char mname[1024][64];
static int nm;

static void refresh_modules(HANDLE p, FILE *o) {
    DWORD need = 0;
    if (!EnumProcessModulesEx(p, mods, sizeof(mods), &need, LIST_MODULES_ALL)) return;
    int n = (int)(need / sizeof(HMODULE));
    if (n > 1024) n = 1024;
    if (n == nm) return;
    nm = n;
    for (int i = 0; i < nm; i++) {
        GetModuleInformation(p, mods[i], &minfo[i], sizeof(minfo[i]));
        if (!GetModuleBaseNameA(p, mods[i], mname[i], sizeof(mname[i]))) strcpy_s(mname[i], sizeof(mname[i]), "?");
        fprintf(o, "M %llx %lx %s\n", (unsigned long long)(ULONG_PTR)minfo[i].lpBaseOfDll, minfo[i].SizeOfImage, mname[i]);
    }
    SymRefreshModuleList(p);
}

static void fmt_addr(DWORD64 a, char *buf, size_t len) {
    for (int i = 0; i < nm; i++) {
        DWORD64 b = (DWORD64)(ULONG_PTR)minfo[i].lpBaseOfDll;
        if (a >= b && a < b + minfo[i].SizeOfImage) {
            _snprintf_s(buf, len, _TRUNCATE, "%s+0x%llx", mname[i], a - b);
            return;
        }
    }
    _snprintf_s(buf, len, _TRUNCATE, "0x%llx", a);
}

static ULONGLONG ft(FILETIME f) { return ((ULONGLONG)f.dwHighDateTime << 32) | f.dwLowDateTime; }

int main(int argc, char **argv) {
    if (argc != 5) return 2;
    DWORD pid = (DWORD)atoi(argv[1]);
    int dur = atoi(argv[2]), iv = atoi(argv[3]);
    FILE *o = NULL;
    if (fopen_s(&o, argv[4], "w") || !o) return 3;
    HANDLE p = OpenProcess(PROCESS_QUERY_INFORMATION | PROCESS_VM_READ, FALSE, pid);
    if (!p) return 4;
    NtQit qit = (NtQit)GetProcAddress(GetModuleHandleA("ntdll.dll"), "NtQueryInformationThread");
    SymSetOptions(SYMOPT_DEFERRED_LOADS | SYMOPT_NO_PROMPTS);
    SymInitialize(p, "", FALSE);
    timeBeginPeriod(1);
    LARGE_INTEGER f, t0, now;
    QueryPerformanceFrequency(&f);
    QueryPerformanceCounter(&t0);
    fprintf(o, "Q %lld\n", f.QuadPart);
    DWORD main_tid = 0;
    ULONGLONG main_created = ~0ULL;
    for (int iter = 0;; iter++) {
        QueryPerformanceCounter(&now);
        if ((now.QuadPart - t0.QuadPart) * 1000 / f.QuadPart > dur) break;
        if (iter % 25 == 0) {
            refresh_modules(p, o);
            HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0);
            if (snap == INVALID_HANDLE_VALUE) break;
            THREADENTRY32 te = {sizeof(te)};
            for (BOOL ok = Thread32First(snap, &te); ok; ok = Thread32Next(snap, &te)) {
                if (te.th32OwnerProcessID != pid) continue;
                int known = 0;
                for (int i = 0; i < nt; i++) if (tids[i] == te.th32ThreadID) known = 1;
                if (known || nt >= MAXT) continue;
                HANDLE h = OpenThread(THREAD_SUSPEND_RESUME | THREAD_GET_CONTEXT | THREAD_QUERY_INFORMATION, FALSE, te.th32ThreadID);
                if (!h) continue;
                int s = nt++;
                tids[s] = te.th32ThreadID; th[s] = h; cpu[s] = 0; walk[s] = 0;
                FILETIME c, e, kt, ut;
                if (GetThreadTimes(h, &c, &e, &kt, &ut)) { created[s] = ft(c); cpu[s] = ft(kt) + ft(ut); }
                PVOID sa = NULL;
                strcpy_s(starts[s], sizeof(starts[s]), "?");
                if (qit && qit(h, 9, &sa, sizeof(sa), NULL) == 0) fmt_addr((DWORD64)(ULONG_PTR)sa, starts[s], sizeof(starts[s]));
                if (strstr(starts[s], "nvoglv64")) walk[s] = 1;
                if (created[s] && created[s] < main_created) { main_created = created[s]; main_tid = tids[s]; }
            }
            CloseHandle(snap);
        }
        LARGE_INTEGER ts;
        QueryPerformanceCounter(&ts);
        for (int s = 0; s < nt; s++) {
            HANDLE h = th[s];
            if (!h) continue;
            FILETIME c, e, kt, ut;
            if (!GetThreadTimes(h, &c, &e, &kt, &ut)) continue;
            if (ft(e) != 0) { CloseHandle(h); th[s] = NULL; continue; }
            ULONGLONG total = ft(kt) + ft(ut);
            ULONGLONG delta = total - cpu[s];
            cpu[s] = total;
            int is_main = tids[s] == main_tid;
            if (!is_main && !walk[s]) {
                if (delta) fprintf(o, "C %lld %lu %llu %s\n", ts.QuadPart, tids[s], delta, starts[s]);
                continue;
            }
            DWORD64 fr[32];
            int nf = 0;
            if (SuspendThread(h) != (DWORD)-1) {
                CONTEXT ctx;
                memset(&ctx, 0, sizeof(ctx));
                ctx.ContextFlags = CONTEXT_FULL;
                if (GetThreadContext(h, &ctx)) {
                    STACKFRAME64 sf;
                    memset(&sf, 0, sizeof(sf));
                    sf.AddrPC.Offset = ctx.Rip; sf.AddrPC.Mode = AddrModeFlat;
                    sf.AddrFrame.Offset = ctx.Rbp; sf.AddrFrame.Mode = AddrModeFlat;
                    sf.AddrStack.Offset = ctx.Rsp; sf.AddrStack.Mode = AddrModeFlat;
                    while (nf < 32) {
                        if (!StackWalk64(IMAGE_FILE_MACHINE_AMD64, p, h, &sf, &ctx, NULL, SymFunctionTableAccess64, SymGetModuleBase64, NULL)) break;
                        if (!sf.AddrPC.Offset) break;
                        fr[nf++] = sf.AddrPC.Offset;
                    }
                }
                ResumeThread(h);
            }
            char line[8192];
            int pos = _snprintf_s(line, sizeof(line), _TRUNCATE, "S %lld %lu %d %llu %s |", ts.QuadPart, tids[s], is_main, delta, starts[s]);
            for (int d = 0; d < nf; d++) {
                char fb[120];
                fmt_addr(fr[d], fb, sizeof(fb));
                if (pos > 0 && pos < (int)sizeof(line) - 130) pos += _snprintf_s(line + pos, sizeof(line) - pos, _TRUNCATE, " %s", fb);
            }
            fprintf(o, "%s\n", line);
        }
        Sleep(iv);
    }
    timeEndPeriod(1);
    fclose(o);
    SymCleanup(p);
    CloseHandle(p);
    return 0;
}
