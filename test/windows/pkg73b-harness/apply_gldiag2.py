"""MEASUREMENT ONLY (PKG-73b): finer spans around the GL work.

usage: python -I apply_gldiag2.py <repo-root>   (after apply_gldiag.py)
Span ids: 130+n RenderPass step n, 140 RenderPass.complete (glFlush),
141 Frame.complete's flush+glGetError, 142 present, 143 swapGLBuffers
inside present, 150 generic initShaders, 151 prepareContext.
"""
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
LT = '@import("../../apprt/win32/latency_trace.zig")'


def patch(rel, edits):
    p = root / rel
    s = p.read_bytes().decode("utf-8")
    for old, new in edits:
        assert s.count(old) == 1, (rel, old[:70])
        s = s.replace(old, new)
    p.write_bytes(s.encode("utf-8"))


patch("src/renderer/opengl/RenderPass.zig", [
    ("""    if (s.draw.instance_count == 0) return;
""", f"""    if (s.draw.instance_count == 0) return;
    const lt_step = {LT}.qpcNow();
    const lt_n = self.step_number;
    defer {LT}.note(.span, {LT}.qpcNow() -| lt_step, 130 + @as(u64, @intCast(lt_n)));
"""),
    ("""    _ = self;
    gl.flush();
}""", f"""    _ = self;
    const lt_c = {LT}.qpcNow();
    gl.flush();
    {LT}.note(.span, {LT}.qpcNow() -| lt_c, 140);
}}"""),
])
patch("src/renderer/opengl/Frame.zig", [
    ("""    _ = sync;
    gl.flush();
    var health""", f"""    _ = sync;
    const lt_c = {LT}.qpcNow();
    gl.flush();
    defer {LT}.note(.span, {LT}.qpcNow() -| lt_c, 141);
    var health"""),
])
LT1 = '@import("../apprt/win32/latency_trace.zig")'
patch("src/renderer/OpenGL.zig", [
    ("""pub fn present(self: *OpenGL, target: Target) !void {
    if (target.width == 0 or target.height == 0) return;
""", f"""pub fn present(self: *OpenGL, target: Target) !void {{
    if (target.width == 0 or target.height == 0) return;
    const lt_p = {LT1}.qpcNow();
    defer {LT1}.note(.span, {LT1}.qpcNow() -| lt_p, 142);
"""),
    ("""    if (apprt.runtime == apprt.win32) {
        try self.rt_surface.swapGLBuffers();
    }""", f"""    if (apprt.runtime == apprt.win32) {{
        const lt_s = {LT1}.qpcNow();
        defer {LT1}.note(.span, {LT1}.qpcNow() -| lt_s, 143);
        try self.rt_surface.swapGLBuffers();
    }}"""),
    ("""fn prepareContext(getProcAddress: anytype) !void {
""", f"""fn prepareContext(getProcAddress: anytype) !void {{
    const lt_pc = {LT1}.qpcNow();
    defer {LT1}.note(.span, {LT1}.qpcNow() -| lt_pc, 151);
"""),
])
patch("src/renderer/generic.zig", [
    ("""        fn initShaders(self: *Self) !void {
""", f"""        fn initShaders(self: *Self) !void {{
            const lt_is = {LT1}.qpcNow();
            defer {LT1}.note(.span, {LT1}.qpcNow() -| lt_is, 150);
"""),
])
print("ok")
