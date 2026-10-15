"""MEASUREMENT ONLY (PKG-73b): no thread creation at discovery time.

usage: python -I apply_prespawn.py <repo-root>   (after apply_trigger.py)
NOCTTY_GLDIAG letter R: App.init (before any GL context exists) spawns one
parked worker; startProfileDiscovery hands it the job instead of spawning a
thread. PKG73_NOWSL=1 makes discovery skip wsl.exe (so no drain thread).
Span 173 marks a hand-off to the parked worker.
"""
import pathlib
import sys

root = pathlib.Path(sys.argv[1])


def patch(rel, edits):
    p = root / rel
    s = p.read_bytes().decode("utf-8")
    for old, new in edits:
        assert s.count(old) == 1, (rel, old[:70])
        s = s.replace(old, new)
    p.write_bytes(s.encode("utf-8"))


patch("src/apprt/win32.zig", [
    ("""        delivery.retain();
        const thread = std.Thread.spawn(.{}, profileDiscoveryThreadMain, .{""",
     """        delivery.retain();
        if (pkg73_glwarm.has('R') and pkg73_glwarm.park(delivery, self.config.@"ssh-config-hosts", self.profiles_generation)) {
            self.stopProfileDiscoveryWatchdog();
            const park_timer = sys.SetTimer(null, 0, @intCast(profile_discovery_abandon_ms + std.time.ms_per_s), null);
            if (park_timer != 0) self.profile_discovery_watchdog_id = park_timer;
            return;
        }
        const thread = std.Thread.spawn(.{}, profileDiscoveryThreadMain, .{"""),
    ("""    fn noop() void {}
""", """    fn noop() void {}

    var park_go: std.Thread.ResetEvent = .{};
    var park_busy = std.atomic.Value(bool).init(true);
    var park_delivery: *AppDelivery = undefined;
    var park_ssh: bool = false;
    var park_gen: u64 = 0;

    fn parked() void {
        park_busy.store(false, .release);
        while (true) {
            park_go.wait();
            park_go.reset();
            profileDiscoveryThreadMain(park_delivery, park_ssh, park_gen);
            park_busy.store(false, .release);
        }
    }

    fn park(delivery: *AppDelivery, ssh: bool, gen: u64) bool {
        if (park_busy.cmpxchgStrong(false, true, .acq_rel, .acquire) != null) return false;
        park_delivery = delivery;
        park_ssh = ssh;
        park_gen = gen;
        LT.note(.span, 0, 173);
        park_go.set();
        return true;
    }
"""),
    ("""        flags_len = @min(v.len, flags_buf.len);
        @memcpy(flags_buf[0..flags_len], v[0..flags_len]);
""", """        flags_len = @min(v.len, flags_buf.len);
        @memcpy(flags_buf[0..flags_len], v[0..flags_len]);
        if (has('R')) {
            if (std.Thread.spawn(.{}, parked, .{})) |th| th.detach() else |_| {}
        }
"""),
])
patch("src/config/windows_shell.zig", [
    ("""fn probeWslExecutableForProfiles(alloc: Allocator, exe_path: []const u8) !bool {
    if (builtin.os.tag != .windows) return true;
""", """fn probeWslExecutableForProfiles(alloc: Allocator, exe_path: []const u8) !bool {
    if (builtin.os.tag != .windows) return true;
    if (std.process.getEnvVarOwned(std.heap.page_allocator, "PKG73_NOWSL")) |v| {
        std.heap.page_allocator.free(v);
        return false; // MEASUREMENT ONLY
    } else |_| {}
"""),
])
print("ok")
