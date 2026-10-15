"""MEASUREMENT ONLY (PKG-73b): load threadlog.dll at App.init.

usage: python -I apply_threadlog.py <repo-root>   (after apply_prespawn.py)
NOCTTY_GLDIAG letter L: LoadLibraryW(PKG73_THREADLOG_DLL) as the first thing
pkg73_glwarm.start does, so every later thread start is logged.
"""
import pathlib
import sys

p = pathlib.Path(sys.argv[1]) / "src/apprt/win32.zig"
s = p.read_bytes().decode("utf-8")
old = """        flags_len = @min(v.len, flags_buf.len);
        @memcpy(flags_buf[0..flags_len], v[0..flags_len]);
"""
new = old + """        if (has('L')) {
            if (std.process.getEnvVarOwned(std.heap.page_allocator, "PKG73_THREADLOG_DLL")) |dll| {
                defer std.heap.page_allocator.free(dll);
                const w = std.unicode.utf8ToUtf16LeAllocZ(std.heap.page_allocator, dll) catch return;
                defer std.heap.page_allocator.free(w);
                _ = LoadLibraryW(w.ptr);
            } else |_| {}
        }
"""
assert s.count(old) == 1
s = s.replace(old, new)
old2 = "    fn noop() void {}\n"
assert s.count(old2) == 1
s = s.replace(old2, old2 + '    extern "kernel32" fn LoadLibraryW(name: [*:0]const u16) callconv(.winapi) ?*anyopaque;\n')
p.write_bytes(s.encode("utf-8"))
print("ok")
