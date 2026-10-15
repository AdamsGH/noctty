"""MEASUREMENT ONLY (PKG-73b): log DLL loads/unloads (QPC, thread, name).

usage: python -I apply_gldiag3.py <repo-root>   (after apply_gldiag.py)
With 'l' in NOCTTY_GLDIAG, LdrRegisterDllNotification appends
"L <qpc> tid=<id> reason=<1 load|2 unload> <name>" to NOCTTY_GLDIAG_FILE.
Registered from the first gldiag use (prepareContext), so loads before the
GL context exists are not seen.
"""
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
p = root / "src/renderer/OpenGL.zig"
s = p.read_bytes().decode("utf-8")


def rep(old, new):
    global s
    assert s.count(old) == 1, old[:70]
    s = s.replace(old, new)


rep("""        file = std.fs.createFileAbsolute(p, .{ .truncate = false }) catch null;
        if (file) |f| f.seekFromEnd(0) catch {};
    }
""", """        file = std.fs.createFileAbsolute(p, .{ .truncate = false }) catch null;
        if (file) |f| f.seekFromEnd(0) catch {};
        if (std.mem.indexOfScalar(u8, flags[0..flags_len], 'l') != null) {
            var cookie: ?*anyopaque = null;
            _ = LdrRegisterDllNotification(0, dllNote, null, &cookie);
        }
    }

    const DllData = extern struct {
        flags: u32,
        full_name: *const std.os.windows.UNICODE_STRING,
        base_name: *const std.os.windows.UNICODE_STRING,
        base: ?*anyopaque,
        size: u32,
    };
    extern "ntdll" fn LdrRegisterDllNotification(
        flags: u32,
        cb: *const fn (u32, *const DllData, ?*anyopaque) callconv(.winapi) void,
        ctx: ?*anyopaque,
        cookie: *?*anyopaque,
    ) callconv(.winapi) i32;

    fn dllNote(reason: u32, data: *const DllData, ctx: ?*anyopaque) callconv(.winapi) void {
        _ = ctx;
        const now = LT.qpcNow();
        const name = data.base_name;
        var buf: [96]u8 = undefined;
        var n: usize = 0;
        if (name.Buffer) |w| {
            for (w[0..@min(name.Length / 2, buf.len)]) |c| {
                buf[n] = if (c < 128) @intCast(c) else '?';
                n += 1;
            }
        }
        line("L {d} tid={d} reason={d} {s}", .{ now, std.Thread.getCurrentId(), reason, buf[0..n] });
    }
""")
p.write_bytes(s.encode("utf-8"))
print("ok")
