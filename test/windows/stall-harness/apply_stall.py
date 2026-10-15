"""MEASUREMENT ONLY (STARTUP-STALL): time the UI thread's work.

usage: python -I apply_stall.py <repo-root>
Run after apply_trace.py, apply_vsync.py and apply_lock.py. Adds latency_trace
kinds 15 `span` (a = duration, b = span id) and 16 `ui_msg` (a = duration of
one message-loop iteration after GetMessageW returned, b = msg.message).
Span ids: 1 jump-list flush from its debounce timer, 2 the jump-list
branch's deferred profile discovery, 3 tickCoreApp after a dispatch,
4 windows_shell.discoverProfiles in Host.reloadProfiles.
"""
import pathlib
import sys

root = pathlib.Path(sys.argv[1])


# Anchors that exist only on main (the synchronous discovery) or only on the
# fix (the worker); an absent optional anchor is skipped.
OPTIONAL = ("if (host.profiles == null or !host.profiles_complete) {",
            "const discovery = try windows_shell.discoverProfiles(",
            ".result = windows_shell.discoverProfiles(alloc, include_ssh_hosts),",
            "completion.result = windows_shell.discoverProfiles(completion.arena.allocator(), include_ssh_hosts);")


def patch(rel, edits):
    path = root / rel
    text = path.read_bytes().decode("utf-8")
    for old, new in edits:
        n = text.count(old)
        if n == 0 and any(o in old for o in OPTIONAL):
            print(f"{rel}: optional anchor absent: {old.strip()[:60]!r}")
            continue
        if n != 1:
            raise SystemExit(f"{rel}: anchor matched {n} times: {old[:80]!r}")
        text = text.replace(old, new)
    path.write_bytes(text.encode("utf-8"))


patch("src/apprt/win32/latency_trace.zig", [
    ("    ui_lock = 14,\n", "    ui_lock = 14,\n    span = 15,\n    ui_msg = 16,\n"),
])

LT = "latency_trace"
patch("src/apprt/win32.zig", [
    ("""            const result = sys.GetMessageW(&msg, null, 0, 0);
            if (result == -1) return lastError();
            if (result == 0) break;
""", f"""            const result = sys.GetMessageW(&msg, null, 0, 0);
            if (result == -1) return lastError();
            if (result == 0) break;
            const lt_iter = {LT}.qpcNow();
            defer {LT}.note(.ui_msg, {LT}.qpcNow() -| lt_iter, msg.message);
"""),
    ("""                            const host = self.hosts.items[0];
                            if (host.profiles == null or !host.profiles_complete) {""",
     f"""                            const host = self.hosts.items[0];
                            const lt_jl = {LT}.qpcNow();
                            defer {LT}.note(.span, {LT}.qpcNow() -| lt_jl, 2);
                            if (host.profiles == null or !host.profiles_complete) {{"""),
    ("""            _ = sys.DispatchMessageW(&msg);

            self.syncDirtyGlobalHotkeys();
            try self.tickCoreApp();
""", f"""            _ = sys.DispatchMessageW(&msg);

            self.syncDirtyGlobalHotkeys();
            const lt_tick = {LT}.qpcNow();
            try self.tickCoreApp();
            {LT}.note(.span, {LT}.qpcNow() -| lt_tick, 3);
"""),
    ("""    completion.result = windows_shell.discoverProfiles(completion.arena.allocator(), include_ssh_hosts);""",
     f"""    const lt_w = {LT}.qpcNow();
    completion.result = windows_shell.discoverProfiles(completion.arena.allocator(), include_ssh_hosts);
    {LT}.note(.span, {LT}.qpcNow() -| lt_w, 10);"""),
    ("""        .result = windows_shell.discoverProfiles(alloc, include_ssh_hosts),""",
     f"""        .result = blk: {{
            const lt_w = {LT}.qpcNow();
            const r = windows_shell.discoverProfiles(alloc, include_ssh_hosts);
            {LT}.note(.span, {LT}.qpcNow() -| lt_w, 10);
            break :blk r;
        }},"""),
    ("""        const discovery = try windows_shell.discoverProfiles(
            self.app.core_app.alloc,
            self.app.config.@"ssh-config-hosts",
        );""", f"""        const lt_disc = {LT}.qpcNow();
        const discovery = try windows_shell.discoverProfiles(
            self.app.core_app.alloc,
            self.app.config.@"ssh-config-hosts",
        );
        {LT}.note(.span, {LT}.qpcNow() -| lt_disc, 4);"""),
])

patch("src/apprt/win32_jump_list.zig", [
    ("""        if (self.timer_id == null or timer_id != self.timer_id.?) return false;
        self.stopTimer();
        self.flush();
        return true;""", """        if (self.timer_id == null or timer_id != self.timer_id.?) return false;
        self.stopTimer();
        const lt = @import("win32/latency_trace.zig");
        const lt_flush = lt.qpcNow();
        self.flush();
        lt.note(.span, lt.qpcNow() -| lt_flush, 1);
        return true;"""),
])
# Span ids 7 (renderer thread: updateFrame's draw_mutex section, rebuildCells),
# 8 (drawFrame's wait for draw_mutex), 9 (drawFrame after the lock).
LTR = '@import("../apprt/win32/latency_trace.zig")'
patch("src/renderer/generic.zig", [
    ("""            {
                self.draw_mutex.lock();
                defer self.draw_mutex.unlock();

                // Build our GPU cells""", f"""            {{
                self.draw_mutex.lock();
                const lt_rebuild = {LTR}.qpcNow();
                defer {{
                    {LTR}.note(.span, {LTR}.qpcNow() -| lt_rebuild, 7);
                    self.draw_mutex.unlock();
                }}

                // Build our GPU cells"""),
    ("""            // We hold a the draw mutex to prevent changes to any
            // data we access while we're in the middle of drawing.
            self.draw_mutex.lock();
            defer self.draw_mutex.unlock();
""", f"""            // We hold a the draw mutex to prevent changes to any
            // data we access while we're in the middle of drawing.
            const lt_dwait = {LTR}.qpcNow();
            self.draw_mutex.lock();
            const lt_dlocked = {LTR}.qpcNow();
            {LTR}.note(.span, lt_dlocked -| lt_dwait, 8);
            defer {{
                {LTR}.note(.span, {LTR}.qpcNow() -| lt_dlocked, 9);
                self.draw_mutex.unlock();
            }}
"""),
    # 104 after the shader check, 105 after the image/bg/uniform uploads,
    # 106 after the cell buffer sync, 107 after the grayscale atlas sync.
    ("""            // Our shaders should not be defunct at this point.
            assert(!self.shaders.defunct);
""", f"""            // Our shaders should not be defunct at this point.
            assert(!self.shaders.defunct);
            {LTR}.note(.span, {LTR}.qpcNow() -| lt_dlocked, 104);
"""),
    ("""            // Setup our frame data
            try frame.uniforms.sync(&.{self.uniforms});
""", f"""            // Setup our frame data
            {LTR}.note(.span, {LTR}.qpcNow() -| lt_dlocked, 105);
            try frame.uniforms.sync(&.{{self.uniforms}});
            {LTR}.note(.span, {LTR}.qpcNow() -| lt_dlocked, 108);
"""),
    # 109 after the bg cells sync, with the fg sync still to come.
    ("""                    if (self.fg_cells_dirty_from) |start| {
                        self.fg_cell_count = try frame.cells.syncFromArrayListsStart(""", f"""                    {LTR}.note(.span, {LTR}.qpcNow() -| lt_dlocked, 109);
                    if (self.fg_cells_dirty_from) |start| {{
                        self.fg_cell_count = try frame.cells.syncFromArrayListsStart("""),
    ("""            // If our background image buffer has changed, sync it.
            if (frame.bg_image_buffer_modified != self.bg_image_buffer_modified) {""", f"""            // If our background image buffer has changed, sync it.
            {LTR}.note(.span, {LTR}.qpcNow() -| lt_dlocked, 106);
            if (frame.bg_image_buffer_modified != self.bg_image_buffer_modified) {{"""),
    ("""            texture: {
                const modified = self.font_grid.atlas_color.modified.load(.monotonic);""", f"""            {LTR}.note(.span, {LTR}.qpcNow() -| lt_dlocked, 107);
            texture: {{
                const modified = self.font_grid.atlas_color.modified.load(.monotonic);"""),
    # Checkpoints inside drawFrame, as span ids 101-103 measured from the lock:
    # after nextFrame, before beginFrame (uploads and atlas sync done), after beginFrame.
    ("""            const frame = try self.swap_chain.nextFrame();
            var frame_owned_by_ctx = false;
""", f"""            const frame = try self.swap_chain.nextFrame();
            {LTR}.note(.span, {LTR}.qpcNow() -| lt_dlocked, 101);
            var frame_owned_by_ctx = false;
"""),
    ("""            // Get a frame context from the graphics API.
            var frame_ctx = try self.api.beginFrame(self, &frame.target);
            frame_owned_by_ctx = true;
""", f"""            // Get a frame context from the graphics API.
            {LTR}.note(.span, {LTR}.qpcNow() -| lt_dlocked, 102);
            var frame_ctx = try self.api.beginFrame(self, &frame.target);
            {LTR}.note(.span, {LTR}.qpcNow() -| lt_dlocked, 103);
            frame_owned_by_ctx = true;
"""),
])
print("stall trace in", root)
