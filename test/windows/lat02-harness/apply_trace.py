"""MEASUREMENT ONLY: apply the LAT-01 latency trace hooks to a noctty tree.

Usage: python -I apply_trace.py <repo-root> <latency_trace.zig>
Every anchor must match exactly once; the script refuses partial patches.
"""
import pathlib
import shutil
import sys

root = pathlib.Path(sys.argv[1])
module = pathlib.Path(sys.argv[2])
shutil.copyfile(module, root / "src/apprt/win32/latency_trace.zig")

def patch(rel, edits):
    path = root / rel
    text = path.read_bytes().decode("utf-8")
    for old, new in edits:
        n = text.count(old)
        if n != 1:
            raise SystemExit(f"{rel}: anchor matched {n} times: {old[:80]!r}")
        text = text.replace(old, new)
    path.write_bytes(text.encode("utf-8"))

LT = 'const latency_trace = @import("../apprt/win32/latency_trace.zig");\n'

patch("src/apprt/win32.zig", [
    ('const render_trace = @import("win32/render_trace.zig");\n',
     'const render_trace = @import("win32/render_trace.zig");\nconst latency_trace = @import("win32/latency_trace.zig");\n'),
    ("            .render_trace = RenderTrace.init(app.core_app.alloc),\n",
     "            .render_trace = blk: {\n                latency_trace.init();\n                break :blk RenderTrace.init(app.core_app.alloc);\n            },\n"),
    # LAT-02: main moved WAKE delivery to the App message window (PKG-19);
    # note core-app ticks instead.
    ("    fn tickCoreApp(self: *App) !void {\n",
     "    fn tickCoreApp(self: *App) !void {\n        latency_trace.note(.app_wake, 0, 0);\n"),
    ("        c.WM_WINHOSTTY_RENDER_TRACE_SNAPSHOT => {\n            if (surface) |v| v.render_trace.requestSnapshot();\n",
     "        c.WM_WINHOSTTY_RENDER_TRACE_SNAPSHOT => {\n            latency_trace.dump();\n            if (surface) |v| v.render_trace.requestSnapshot();\n"),
    ("                    v.render_trace.notePaintDraw();\n",
     "                    latency_trace.note(.paint_begin, 0, 0);\n                    v.render_trace.notePaintDraw();\n"),
    ("        if (sys.SwapBuffers(hdc) == 0) {\n",
     "        latency_trace.note(.swap_begin, 0, 0);\n        if (sys.SwapBuffers(hdc) == 0) {\n"),
    ("        self.render_trace.noteSwapBuffers();\n",
     "        latency_trace.noteSwapEnd();\n        self.render_trace.noteSwapBuffers();\n"),
    ("        self.render_trace.noteRendererWakeupCallback(wake_sources);\n",
     "        latency_trace.note(.renderer_wake, wake_sources, 0);\n        self.render_trace.noteRendererWakeupCallback(wake_sources);\n"),
    ("        self.render_trace.noteRendererUpdateFrame(\n",
     "        if (progress) |value| latency_trace.noteFrameUpdate(value.bytes, value.generation);\n        self.render_trace.noteRendererUpdateFrame(\n"),
])

# The surface window proc's key arm and the .render action arm: patch only the
# occurrence inside windowProc / the .surface render arm.
path = root / "src/apprt/win32.zig"
text = path.read_bytes().decode("utf-8")
wp = text.index("fn windowProc(hwnd: HWND, msg: UINT, wParam: WPARAM, lParam: LPARAM) callconv(.winapi) LRESULT {")
key_anchor = "        c.WM_KEYDOWN, c.WM_SYSKEYDOWN, c.WM_KEYUP, c.WM_SYSKEYUP => {\n"
k = text.index(key_anchor, wp)
text = text[:k + len(key_anchor)] + "            latency_trace.note(.key_msg, msg, wParam);\n" + text[k + len(key_anchor):]
char_anchors = ["        c.WM_CHAR, c.WM_DEADCHAR, c.WM_SYSDEADCHAR => {\n", "        c.WM_CHAR => {\n"]
for anchor in char_anchors:
    ci = text.find(anchor, wp)
    if ci != -1 and ci - wp < 20000:
        text = text[:ci + len(anchor)] + "            latency_trace.note(.char_msg, msg, wParam);\n" + text[ci + len(anchor):]
        break
else:
    raise SystemExit("no WM_CHAR arm in windowProc")
render_anchor = "                    .surface => if (self.findSurfaceForTarget(target)) |surface| blk: {\n                        try surface.requestRepaintWithMode("
ri = text.index(".render => {")
r = text.index(render_anchor, ri)
text = text[:r] + "                    .surface => if (self.findSurfaceForTarget(target)) |surface| blk: {\n                        latency_trace.note(.render_action, 0, 0);\n                        try surface.requestRepaintWithMode(" + text[r + len(render_anchor):]
path.write_bytes(text.encode("utf-8"))

patch("src/termio/Termio.zig", [
    ("        self.renderer_state.noteProcessOutput(buf.len, processOutputTickMs());\n",
     "        self.renderer_state.noteProcessOutput(buf.len, processOutputTickMs());\n        @import(\"../apprt/win32/latency_trace.zig\").noteOutput(self.renderer_state.process_output_bytes, buf);\n"),
])
patch("src/termio/Exec.zig", [
    ("    // If our process is exited then we don't send any more writes.\n    if (exec.exited) return;\n",
     "    // If our process is exited then we don't send any more writes.\n    if (exec.exited) return;\n    @import(\"../apprt/win32/latency_trace.zig\").note(.pty_write, data.len, if (data.len > 0) data[0] else 0);\n"),
])
print("patched", root)
