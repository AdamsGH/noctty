"""MEASUREMENT ONLY (PKG-73b): GL-level diagnostics for the F028 stall.

usage: python -I apply_gldiag.py <repo-root>
Run after the apply_*.py trace patches. Everything is gated by the env var
NOCTTY_GLDIAG (a set of letters), read once:
  d  GL_DEBUG_OUTPUT with a callback that appends each message, QPC-stamped
     with the calling thread id, to NOCTTY_GLDIAG_FILE (notifications: the
     first 200 only)
  y  also GL_DEBUG_OUTPUT_SYNCHRONOUS
  s  glFinish at drawFrameStart, timed as span 111
  f  glFinish at drawFrameEnd, timed as span 110
"""
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
path = root / "src/renderer/OpenGL.zig"
s = path.read_bytes().decode("utf-8")


def rep(old, new):
    global s
    assert s.count(old) == 1, old[:70]
    s = s.replace(old, new)


rep("""/// Prepares the provided GL context, loading it with glad.
fn prepareContext(""", """const gldiag = struct {
    const LT = @import("../apprt/win32/latency_trace.zig");
    var flags_once = std.once(readFlags);
    var flags: [8]u8 = .{0} ** 8;
    var flags_len: usize = 0;
    var file_mutex: std.Thread.Mutex = .{};
    var file: ?std.fs.File = null;
    var notifications: u32 = 0;

    fn readFlags() void {
        const v = std.process.getEnvVarOwned(std.heap.page_allocator, "NOCTTY_GLDIAG") catch return;
        defer std.heap.page_allocator.free(v);
        flags_len = @min(v.len, flags.len);
        @memcpy(flags[0..flags_len], v[0..flags_len]);
        const p = std.process.getEnvVarOwned(std.heap.page_allocator, "NOCTTY_GLDIAG_FILE") catch return;
        defer std.heap.page_allocator.free(p);
        file = std.fs.createFileAbsolute(p, .{ .truncate = false }) catch null;
        if (file) |f| f.seekFromEnd(0) catch {};
    }

    fn has(c: u8) bool {
        flags_once.call();
        return std.mem.indexOfScalar(u8, flags[0..flags_len], c) != null;
    }

    fn line(comptime fmt: []const u8, args: anytype) void {
        flags_once.call();
        file_mutex.lock();
        defer file_mutex.unlock();
        const f = file orelse return;
        var buf: [1024]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, fmt ++ "\\n", args) catch return;
        f.writeAll(text) catch {};
    }

    fn callback(
        src: gl.c.GLenum,
        typ: gl.c.GLenum,
        id: gl.c.GLuint,
        severity: gl.c.GLenum,
        len: gl.c.GLsizei,
        msg: [*c]const gl.c.GLchar,
        user_param: ?*const anyopaque,
    ) callconv(gl_debug_proc_callconv) void {
        _ = user_param;
        const now = LT.qpcNow();
        if (severity == gl.c.GL_DEBUG_SEVERITY_NOTIFICATION) {
            const n = @atomicRmw(u32, &notifications, .Add, 1, .monotonic);
            if (n >= 200) return;
        }
        const n: usize = @intCast(@max(len, 0));
        const text = msg[0..@min(n, 700)];
        line("M {d} tid={d} id={d} src=0x{x} type=0x{x} sev=0x{x} {s}", .{ now, std.Thread.getCurrentId(), id, src, typ, severity, text });
    }

    fn finish(span_id: u64) void {
        const t = LT.qpcNow();
        gl.glad.context.Finish.?();
        LT.note(.span, LT.qpcNow() -| t, span_id);
    }
};

/// Prepares the provided GL context, loading it with glad.
fn prepareContext(""")
rep("""        gl.glad.context.DebugMessageCallback.?(glDebugMessageCallback, null);
    }
""", """        gl.glad.context.DebugMessageCallback.?(glDebugMessageCallback, null);
    }
    if (gldiag.has('d')) {
        try gl.enable(gl.c.GL_DEBUG_OUTPUT);
        if (gldiag.has('y')) try gl.enable(gl.c.GL_DEBUG_OUTPUT_SYNCHRONOUS);
        gl.glad.context.DebugMessageCallback.?(gldiag.callback, null);
        var flags: gl.c.GLint = 0;
        gl.glad.context.GetIntegerv.?(gl.c.GL_CONTEXT_FLAGS, &flags);
        gldiag.line("C {d} tid={d} context_flags=0x{x} version={d}.{d}", .{ gldiag.LT.qpcNow(), std.Thread.getCurrentId(), flags, major, minor });
    }
""")
rep("""pub fn drawFrameStart(self: *OpenGL) void {
    _ = self;
}""", """pub fn drawFrameStart(self: *OpenGL) void {
    _ = self;
    if (gldiag.has('s')) gldiag.finish(111);
}""")
rep("""pub fn drawFrameEnd(self: *OpenGL) void {
    _ = self;
}""", """pub fn drawFrameEnd(self: *OpenGL) void {
    _ = self;
    if (gldiag.has('f')) gldiag.finish(110);
}""")
path.write_bytes(s.encode("utf-8"))
print("ok")
