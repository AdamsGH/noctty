"""MEASUREMENT ONLY: give a measurement build its own AUMID.

usage: python -I apply_aumid_isolate.py <repo-root>
The Shell keys a jump list (and its CustomDestinations file under the real
%APPDATA%, which APPDATA redirection does not move) by AUMID, so a harness
copy with the product AUMID replaces the maintainer's real noctty jump list
on every launch. This build uses `io.github.amanthanvi.noctty.measure` and
skips the HKCU AppUserModelId registration entirely.
"""
import pathlib
import sys

p = pathlib.Path(sys.argv[1]) / "src/apprt/win32_aumid.zig"
s = p.read_bytes().decode("utf-8")
old = 'pub const aumid_utf8 = "io.github.amanthanvi.noctty";'
assert s.count(old) == 1
s = s.replace(old, 'pub const aumid_utf8 = "io.github.amanthanvi.noctty.measure";')
old_w = 'utf8ToUtf16LeStringLiteral("io.github.amanthanvi.noctty");'
assert s.count(old_w) == 1
s = s.replace(old_w, 'utf8ToUtf16LeStringLiteral("io.github.amanthanvi.noctty.measure");')
old2 = "pub fn registerAumidDisplayName(alloc: std.mem.Allocator) void {\n"
assert s.count(old2) == 1
s = s.replace(old2, old2 + "    if (true) return; // MEASUREMENT ONLY\n")
p.write_bytes(s.encode("utf-8"))
print("ok")
