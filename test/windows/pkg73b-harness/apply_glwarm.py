"""MEASUREMENT ONLY (PKG-73b): an off-UI-thread GL warm-up.

usage: python -I apply_glwarm.py <repo-root>   (after the trace patches)
With 'w' in NOCTTY_GLDIAG, App.init starts a thread that creates a hidden
popup window with its own WGL context and clears + swaps it every 8 ms for
NOCTTY_GLWARM_MS (default 2000) ms, pumping its messages, then tears it
down. Spans: 160 the whole warm-up, 161 any single clear+swap over 20 ms,
162 context creation (ChoosePixelFormat .. wglMakeCurrent).
"""
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
p = root / "src/apprt/win32.zig"
s = p.read_bytes().decode("utf-8")


def rep(old, new):
    global s
    assert s.count(old) == 1, old[:70]
    s = s.replace(old, new)


rep("""        win32_aumid.setProcessAumid();
        win32_aumid.registerAumidDisplayName(core_app.alloc);
""", """        win32_aumid.setProcessAumid();
        win32_aumid.registerAumidDisplayName(core_app.alloc);
        pkg73_glwarm.start();
""")
s += r'''

/// MEASUREMENT ONLY (PKG-73b): see apply_glwarm.py.
const pkg73_glwarm = struct {
    const LT = @import("win32/latency_trace.zig");
    extern "opengl32" fn glClear(mask: u32) callconv(.winapi) void;
    extern "opengl32" fn glClearColor(r: f32, g: f32, b: f32, a: f32) callconv(.winapi) void;
    extern "opengl32" fn glFinish() callconv(.winapi) void;

    fn start() void {
        const v = std.process.getEnvVarOwned(std.heap.page_allocator, "NOCTTY_GLDIAG") catch return;
        defer std.heap.page_allocator.free(v);
        if (std.mem.indexOfScalar(u8, v, 'w') == null) return;
        var ms: u64 = 2000;
        if (std.process.getEnvVarOwned(std.heap.page_allocator, "NOCTTY_GLWARM_MS")) |m| {
            defer std.heap.page_allocator.free(m);
            ms = std.fmt.parseInt(u64, m, 10) catch ms;
        } else |_| {}
        const t = std.Thread.spawn(.{}, run, .{ms}) catch return;
        t.detach();
    }

    fn proc(hwnd: HWND, msg: UINT, wparam: WPARAM, lparam: LPARAM) callconv(.winapi) LRESULT {
        return sys.DefWindowProcW(hwnd, msg, wparam, lparam);
    }

    fn run(ms: u64) void {
        const t0 = LT.qpcNow();
        defer LT.note(.span, LT.qpcNow() -| t0, 160);
        const hinst = sys.GetModuleHandleW(null);
        const warm_class = std.unicode.utf8ToUtf16LeStringLiteral("noctty.pkg73.glwarm");
        var wc: sys.WNDCLASSEXW = std.mem.zeroes(sys.WNDCLASSEXW);
        wc.cbSize = @sizeOf(sys.WNDCLASSEXW);
        wc.style = 0x20; // CS_OWNDC
        wc.lpfnWndProc = &proc;
        wc.hInstance = hinst;
        wc.lpszClassName = warm_class;
        _ = sys.RegisterClassExW(&wc);
        const hwnd = sys.CreateWindowExW(0, warm_class, warm_class, 0x80000000, 0, 0, 64, 64, null, null, hinst, null) orelse return;
        defer _ = sys.DestroyWindow(hwnd);
        const hdc = sys.GetDC(hwnd) orelse return;
        defer _ = sys.ReleaseDC(hwnd, hdc);
        const tc = LT.qpcNow();
        var pfd: sys.PIXELFORMATDESCRIPTOR = std.mem.zeroes(sys.PIXELFORMATDESCRIPTOR);
        pfd.nSize = @sizeOf(sys.PIXELFORMATDESCRIPTOR);
        pfd.nVersion = 1;
        pfd.dwFlags = 0x4 | 0x20 | 0x1;
        pfd.cColorBits = 32;
        pfd.cAlphaBits = 8;
        const fmt = sys.ChoosePixelFormat(hdc, &pfd);
        if (fmt == 0 or sys.SetPixelFormat(hdc, fmt, &pfd) == 0) return;
        const ctx = sys.wglCreateContext(hdc) orelse return;
        defer _ = sys.wglDeleteContext(ctx);
        if (sys.wglMakeCurrent(hdc, ctx) == 0) return;
        defer _ = sys.wglMakeCurrent(null, null);
        LT.note(.span, LT.qpcNow() -| tc, 162);
        const freq = std.os.windows.QueryPerformanceFrequency();
        var msg: sys.MSG = undefined;
        while ((LT.qpcNow() -| t0) * 1000 / freq < ms) {
            while (sys.PeekMessageW(&msg, null, 0, 0, 1) != 0) {
                _ = sys.TranslateMessage(&msg);
                _ = sys.DispatchMessageW(&msg);
            }
            const ts = LT.qpcNow();
            glClearColor(0, 0, 0, 1);
            glClear(0x4000);
            _ = sys.SwapBuffers(hdc);
            const d = LT.qpcNow() -| ts;
            if (d * 1000 / freq > 20) LT.note(.span, d, 161);
            std.Thread.sleep(8 * std.time.ns_per_ms);
        }
        glFinish();
    }
};
'''
p.write_bytes(s.encode("utf-8"))
print("ok")
