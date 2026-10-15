"""MEASUREMENT ONLY (PKG-73b): thread starts (threadlog.txt) vs stall B.

usage: python -I thread_starts.py <run dir> [window_ms]
Prints the B stall(s) (UI iterations > 60 ms after the 3rd swap without a
jump-list flush) and every thread start/exit within window_ms (default 150)
before each B start, plus the first thread start after the first swap.
"""
import pathlib
import sys

run = pathlib.Path(sys.argv[1])
win = float(sys.argv[2]) if len(sys.argv) > 2 else 150
freq = None
ev = []
for line in (run / "latency.txt").read_text().splitlines():
    p = line.split(" ")
    if p[0] == "F":
        freq = int(p[1])
    elif p[0] == "E":
        ev.append((int(p[1]), int(p[2]), int(p[3]), int(p[4])))
lo = next(e[0] for e in ev if e[1] == 4)
ms = lambda d: d * 1000.0 / freq
at = lambda q: (q - lo) * 1000.0 / freq
swaps = sorted(e[0] for e in ev if e[1] == 10)
flush = [e for e in ev if e[1] == 15 and e[3] == 1 and ms(e[2]) > 5]
bs = [e for e in ev if e[1] == 16 and ms(e[2]) > 60 and e[0] - e[2] >= swaps[2]
      and not any(e[0] - e[2] <= f[0] <= e[0] for f in flush)]
rows = []
for line in (run / "threadlog.txt").read_text(errors="replace").splitlines():
    p = line.split(" ")
    if p[0] in ("N", "X"):
        rows.append((at(int(p[1])), p[0], p[2], p[3] if len(p) > 3 else ""))
print(f"{run.parent.name}: B stalls: " + ", ".join(f"{at(b[0] - b[2]):.0f}({ms(b[2]):.0f})" for b in bs))
after_first = [r for r in rows if r[0] > at(swaps[0]) and r[1] == "N"]
if after_first:
    r = after_first[0]
    print(f"  first thread start after first swap: {r[0]:.1f} tid={r[2]} {r[3]}")
for b in bs:
    s0 = at(b[0] - b[2])
    for r in rows:
        if s0 - win <= r[0] <= s0 + 20:
            print(f"  {r[0]:8.1f} {r[1]} tid={r[2]} {r[3]}")
print(f"  thread starts after first swap, first 3 s: {sum(1 for r in after_first if r[0] < 3000)}")
