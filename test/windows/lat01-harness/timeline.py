"""MEASUREMENT ONLY (LAT-01): print the event timeline around keystrokes.

usage: python -I timeline.py <run dir> <first key> <last key>
"""
import pathlib
import sys

KIND = {1: "key_msg", 2: "char_msg", 3: "pty_write", 4: "pty_output", 5: "renderer_wake",
        6: "frame_update", 7: "render_action", 8: "paint_begin", 9: "swap_begin", 10: "swap_end",
        11: "app_wake"}
WAKE = ["thread_start", "core_surface", "mailbox", "io_output", "cursor_blink", "repaint_retry",
        "resize_settle", "paint_retry", "health_recovery", "paint_pending", "first_show", "inspector"]
MSG = {0x100: "WM_KEYDOWN", 0x101: "WM_KEYUP", 0x102: "WM_CHAR", 0x104: "WM_SYSKEYDOWN", 0x105: "WM_SYSKEYUP"}

run = pathlib.Path(sys.argv[1])
k0, k1 = int(sys.argv[2]), int(sys.argv[3])
freq = 10_000_000
events = []
for line in (run / "latency.txt").read_text().splitlines():
    p = line.split()
    if p[0] == "F":
        freq = int(p[1])
    elif p[0] == "E":
        events.append((int(p[1]), KIND[int(p[2])], int(p[3]), int(p[4])))
for line in (run / "keys.txt").read_text().splitlines():
    t, i, q, vk = line.split()
    events.append((int(q), "POST_" + ("DOWN" if t == "D" else "UP"), int(i), int(vk)))
echo = run / "echo.txt"
if echo.exists():
    for line in echo.read_text().splitlines():
        p = line.split()
        if len(p) == 3:
            events.append((int(p[1]), "echo_" + ("recv" if p[0] == "R" else "write"), int(p[2]), 0))
events.sort()
posts = {e[2]: e[0] for e in events if e[1] == "POST_DOWN"}
start = posts[k0]
end = posts.get(k1 + 1, events[-1][0])
for q, kind, a, b in events:
    if q < start or q >= end:
        continue
    extra = ""
    if kind == "renderer_wake":
        extra = "+".join(WAKE[i] for i in range(len(WAKE)) if a & (1 << i)) or "none"
    elif kind == "key_msg" or kind == "char_msg":
        extra = f"{MSG.get(a, hex(a))} w={b}"
    elif kind in ("pty_write",):
        extra = f"len={a} first={b}"
    elif kind == "pty_output":
        extra = f"end={a} len={b}"
    elif kind in ("frame_update", "swap_end"):
        extra = f"bytes={a}"
    elif kind.startswith("POST"):
        extra = f"key={a}"
    elif kind.startswith("echo"):
        extra = chr(a) if 32 <= a < 127 else str(a)
    print(f"{(q - start) * 1000 / freq:9.3f} ms  {kind:14s} {extra}")
