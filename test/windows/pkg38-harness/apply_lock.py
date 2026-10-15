"""MEASUREMENT ONLY (PKG-38): record renderer_state.mutex wait and hold.

usage: python -I apply_lock.py <repo-root>
Run after apply_trace.py and apply_vsync.py. Adds two latency_trace event
kinds, `update_lock` (12: the renderer's updateFrame critical section) and
`io_lock` (13: termio's processOutput), each with a = wait and b = hold in
QPC ticks, noted at unlock. Every anchor must match exactly once.
"""
import pathlib
import sys

root = pathlib.Path(sys.argv[1])


def patch(rel, edits):
    path = root / rel
    text = path.read_bytes().decode("utf-8")
    for old, new in edits:
        n = text.count(old)
        if n != 1:
            raise SystemExit(f"{rel}: anchor matched {n} times: {old[:80]!r}")
        text = text.replace(old, new)
    path.write_bytes(text.encode("utf-8"))


patch("src/apprt/win32/latency_trace.zig", [
    ("    app_wake = 11,\n", "    app_wake = 11,\n    update_lock = 12,\n    io_lock = 13,\n"),
    ("fn qpc() u64 {\n", "pub fn qpcNow() u64 {\n    return qpc();\n}\n\nfn qpc() u64 {\n"),
    # termio locks once per read, about 19,000 times a second under a flood.
    ("const event_capacity = 1 << 17;\n", "const event_capacity = 1 << 22;\n"),
])

LT = '@import("../apprt/win32/latency_trace.zig")'

patch("src/renderer/generic.zig", [
    ("""                state.mutex.lock();
                defer state.mutex.unlock();

                const cursor_blinking = state.terminal.modes.get(.cursor_blinking);
""", f"""                const lt_wait_start = {LT}.qpcNow();
                state.mutex.lock();
                const lt_locked = {LT}.qpcNow();
                defer {{
                    {LT}.note(.update_lock, lt_locked -| lt_wait_start, {LT}.qpcNow() -| lt_locked);
                    state.mutex.unlock();
                }}

                const cursor_blinking = state.terminal.modes.get(.cursor_blinking);
"""),
])

patch("src/termio/Termio.zig", [
    ("""        self.renderer_state.mutex.lock();
        if (trace_lock) lock_acquired = std.time.Instant.now() catch null;
        defer self.renderer_state.mutex.unlock();
""", f"""        const lt_wait_start = {LT}.qpcNow();
        self.renderer_state.mutex.lock();
        const lt_locked = {LT}.qpcNow();
        if (trace_lock) lock_acquired = std.time.Instant.now() catch null;
        defer {{
            {LT}.note(.io_lock, lt_locked -| lt_wait_start, {LT}.qpcNow() -| lt_locked);
            self.renderer_state.mutex.unlock();
        }}
"""),
])
# The app (UI) thread's own locks: kind 14 `ui_lock`, a = wait in QPC ticks.
patch("src/apprt/win32/latency_trace.zig", [
    ("    io_lock = 13,\n", "    io_lock = 13,\n    ui_lock = 14,\n"),
    ("pub fn qpcNow() u64 {\n", """pub fn lockTimed(m: anytype) void {
    // `renderer.State.mutex` is a pointer, so callers pass `**Mutex`.
    const mutex: *std.Thread.Mutex = if (@TypeOf(m) == *std.Thread.Mutex) m else m.*;
    if (!enabled()) return mutex.lock();
    const start = qpc();
    mutex.lock();
    note(.ui_lock, qpc() -| start, 0);
}

pub fn qpcNow() u64 {
"""),
])
import re

pattern = re.compile(r"([A-Za-z_][A-Za-z0-9_.()]*)\.renderer_state\.mutex\.lock\(\);")
for rel, imp in (("src/Surface.zig", '@import("apprt/win32/latency_trace.zig")'),
                 ("src/apprt/win32.zig", "latency_trace")):
    path = root / rel
    text = path.read_bytes().decode("utf-8")
    text, n = pattern.subn(lambda m: f"{imp}.lockTimed(&{m.group(1)}.renderer_state.mutex);", text)
    assert n > 0, rel
    path.write_bytes(text.encode("utf-8"))
    print(rel, "ui lock sites", n)
print("lock trace in", root)
