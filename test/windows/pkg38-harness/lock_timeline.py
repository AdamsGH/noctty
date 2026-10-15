"""MEASUREMENT ONLY (PKG-38): per-frame timeline around the largest gaps.

usage: python -I lock_timeline.py <run dir> [top_n]

For the top_n largest gaps between consecutive frame updates, prints what
the trace holds inside the gap: renderer wakes, update_lock waits, io_lock
count and total hold, swaps, all in ms from the first pty_output.
"""
import pathlib
import sys

run = pathlib.Path(sys.argv[1])
top = int(sys.argv[2]) if len(sys.argv) > 2 else 5
freq = None
ev = []
for line in (run / "latency.txt").read_text().splitlines():
    p = line.split(" ")
    if p[0] == "F":
        freq = int(p[1])
    elif p[0] == "E":
        ev.append((int(p[1]), int(p[2]), int(p[3]), int(p[4])))
out = [e for e in ev if e[1] == 4]
lo, hi = out[0][0], out[-1][0]
ms = lambda t: (t - lo) * 1000.0 / freq
d = lambda t: t * 1000.0 / freq
frames = [e for e in ev if e[1] == 6 and lo <= e[0] <= hi]
gaps = sorted(((b[0] - a[0], a, b) for a, b in zip(frames, frames[1:])), reverse=True)[:top]
for g, a, b in gaps:
    inside = [e for e in ev if a[0] < e[0] < b[0]]
    io = [e for e in inside if e[1] == 13]
    upd = [e for e in inside if e[1] == 12]
    wakes = [e for e in inside if e[1] == 5]
    ui = [e for e in inside if e[1] == 14]
    swaps = [e for e in inside if e[1] in (9, 10)]
    print(f"gap {d(g):7.1f} ms at {ms(a[0]):8.1f}: io_locks={len(io)} io_hold={sum(d(e[3]) for e in io):.1f} ms "
          f"io_wait={sum(d(e[2]) for e in io):.1f} ms upd_locks={len(upd)} upd_wait={sum(d(e[2]) for e in upd):.2f} ms "
          f"wakes={len(wakes)} swap_events={len(swaps)} ui_locks={len(ui)} ui_wait_max={max((d(e[2]) for e in ui), default=0):.1f} ms")
print(f"frames={len(frames)} window={d(hi - lo):.1f} ms")
