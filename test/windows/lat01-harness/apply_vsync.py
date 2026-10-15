"""MEASUREMENT ONLY: refresh latency_trace.zig and add the emulated-vsync hook.

usage: python -I apply_vsync.py <repo-root> <latency_trace.zig>
"""
import pathlib
import shutil
import sys

root = pathlib.Path(sys.argv[1])
shutil.copyfile(sys.argv[2], root / "src/apprt/win32/latency_trace.zig")
p = root / "src/apprt/win32.zig"
s = p.read_bytes().decode("utf-8")
old = "        latency_trace.note(.swap_begin, 0, 0);\n"
if "latency_trace.beforeSwap();" not in s:
    assert s.count(old) == 1
    s = s.replace(old, old + "        latency_trace.beforeSwap();\n")
p.write_bytes(s.encode("utf-8"))
print("vsync hook in", root)
