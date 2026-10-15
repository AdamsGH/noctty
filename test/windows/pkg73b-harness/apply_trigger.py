"""MEASUREMENT ONLY (PKG-73b): what triggers stall B.

usage: python -I apply_trigger.py <repo-root>   (after apply_glwarm.py)
NOCTTY_GLDIAG letters, read once in App.init:
  D  startProfileDiscovery does nothing until NOCTTY_DISC_DELAY_MS (default
     5000) after App.init; the first call before then re-arms the watchdog
     timer for the remainder, which starts the worker at that time.
  T  with D, the first deferred call spawns a thread that exits at once.
  P  with D, the first deferred call starts `cmd.exe /d /c exit` with
     CREATE_NO_WINDOW from the UI thread (no thread of ours created).
Span 170 marks the deferred call (a = 0), 171 the T spawn, 172 the P spawn.
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


rep("""    fn startProfileDiscovery(self: *App) void {
        const delivery = self.delivery orelse return self.discoverStartupProfilesNow();
        const now_ms = sys.GetTickCount64();
""", """    fn startProfileDiscovery(self: *App) void {
        const delivery = self.delivery orelse return self.discoverStartupProfilesNow();
        const now_ms = sys.GetTickCount64();
        if (pkg73_glwarm.has('D') and now_ms -| pkg73_glwarm.t_init < pkg73_glwarm.disc_delay_ms) {
            pkg73_glwarm.deferred(self, now_ms);
            return;
        }
""")
rep("""    fn start() void {
        const v = std.process.getEnvVarOwned(std.heap.page_allocator, "NOCTTY_GLDIAG") catch return;
        defer std.heap.page_allocator.free(v);
        if (std.mem.indexOfScalar(u8, v, 'w') == null) return;
""", """    var t_init: u64 = 0;
    var disc_delay_ms: u64 = 5000;
    var flags_buf: [16]u8 = .{0} ** 16;
    var flags_len: usize = 0;
    var deferred_once = false;

    fn has(flag: u8) bool {
        return std.mem.indexOfScalar(u8, flags_buf[0..flags_len], flag) != null;
    }

    fn noop() void {}

    fn deferred(app: *App, now_ms: u64) void {
        LT.note(.span, 0, 170);
        app.stopProfileDiscoveryWatchdog();
        const left = disc_delay_ms -| (now_ms -| t_init);
        const timer_id = sys.SetTimer(null, 0, @intCast(@max(left, 10)), null);
        if (timer_id != 0) app.profile_discovery_watchdog_id = timer_id;
        if (deferred_once) return;
        deferred_once = true;
        if (has('T')) {
            const t = LT.qpcNow();
            if (std.Thread.spawn(.{}, noop, .{})) |th| th.detach() else |_| {}
            LT.note(.span, LT.qpcNow() -| t, 171);
        }
        if (has('P')) {
            const t = LT.qpcNow();
            var child = std.process.Child.init(&.{ "cmd.exe", "/d", "/c", "exit" }, std.heap.page_allocator);
            child.stdin_behavior = .Ignore;
            child.stdout_behavior = .Ignore;
            child.stderr_behavior = .Ignore;
            child.create_no_window = true;
            if (child.spawn()) |_| {
                _ = child.wait() catch {};
            } else |_| {}
            LT.note(.span, LT.qpcNow() -| t, 172);
        }
    }

    fn start() void {
        t_init = sys.GetTickCount64();
        const v = std.process.getEnvVarOwned(std.heap.page_allocator, "NOCTTY_GLDIAG") catch return;
        defer std.heap.page_allocator.free(v);
        flags_len = @min(v.len, flags_buf.len);
        @memcpy(flags_buf[0..flags_len], v[0..flags_len]);
        if (std.process.getEnvVarOwned(std.heap.page_allocator, "NOCTTY_DISC_DELAY_MS")) |m| {
            defer std.heap.page_allocator.free(m);
            disc_delay_ms = std.fmt.parseInt(u64, m, 10) catch disc_delay_ms;
        } else |_| {}
        if (std.mem.indexOfScalar(u8, v, 'w') == null) return;
""")
p.write_bytes(s.encode("utf-8"))
print("ok")
