"""MEASUREMENT ONLY (PKG-46): spans around the picker and palette entry points.

usage: python -I apply_pkg46spans.py <repo-root>   (after apply_stall.py)
Span ids: 30 the startup picker's toggleProfileOverlay, 31 rebuildPaletteList.
"""
import pathlib
import sys

p = pathlib.Path(sys.argv[1]) / "src/apprt/win32.zig"
s = p.read_bytes().decode("utf-8")


def rep(old, new):
    global s
    assert s.count(old) == 1, old[:70]
    s = s.replace(old, new)


rep("""                    if (surface.host) |host| _ = host.toggleProfileOverlay();""",
    """                    if (surface.host) |host| {
                        const lt_pk = latency_trace.qpcNow();
                        _ = host.toggleProfileOverlay();
                        latency_trace.note(.span, latency_trace.qpcNow() -| lt_pk, 30);
                    }""")
rep("""    fn rebuildPaletteList(self: *Host) void {
""", """    fn rebuildPaletteList(self: *Host) void {
        const lt_pl = latency_trace.qpcNow();
        defer latency_trace.note(.span, latency_trace.qpcNow() -| lt_pl, 31);
""")
p.write_bytes(s.encode("utf-8"))
print("ok")
# Span 32: Host.reloadProfiles, the UI-thread discovery.
s = p.read_bytes().decode("utf-8")
old = """    fn reloadProfiles(self: *Host) !bool {
"""
assert s.count(old) == 1
s = s.replace(old, old + """        const lt_rp = latency_trace.qpcNow();
        defer latency_trace.note(.span, latency_trace.qpcNow() -| lt_rp, 32);
""")
p.write_bytes(s.encode("utf-8"))
print("ok 32")
