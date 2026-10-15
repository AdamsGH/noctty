"""MEASUREMENT ONLY (STARTUP-STALL A/B): profile discovery without wsl.exe.

usage: python -I apply_nowsl.py <repo-root>
Makes probeWslExecutableForProfiles answer false at once, so discovery
starts no wsl.exe (`--status`, `-l -q`) and lists no WSL profiles.
"""
import pathlib
import sys

path = pathlib.Path(sys.argv[1]) / "src/config/windows_shell.zig"
text = path.read_bytes().decode("utf-8")
old = """fn probeWslExecutableForProfiles(alloc: Allocator, exe_path: []const u8) !bool {
    if (builtin.os.tag != .windows) return true;
"""
assert text.count(old) == 1
text = text.replace(old, old + "    if (true) return false; // MEASUREMENT ONLY\n")
path.write_bytes(text.encode("utf-8"))
print("no wsl probe in", path)
