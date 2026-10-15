"""MEASUREMENT ONLY (PKG-73b): per-run startup stall summary.

usage: python -I ab_summary.py <run dir> [more]
Per run: A = the longest UI iteration before the 3rd swap; B = the longest
UI iteration after it within 3 s of the first output, both skipping
iterations that contain a jump-list flush (span 1 > 5 ms); gap = the largest
frame-update gap in the first 3 s; ttff = render.json
process_start_to_first_swap_ms; first = first_swap_at_ms.
Then medians per group (the run name minus its -r<n> suffix and parent).
"""
import json
import pathlib
import statistics
import sys
from collections import defaultdict


def one(run):
    freq = None
    ev = []
    for line in (run / "latency.txt").read_text().splitlines():
        p = line.split(" ")
        if p[0] == "F":
            freq = int(p[1])
        elif p[0] == "E":
            ev.append((int(p[1]), int(p[2]), int(p[3]), int(p[4])))
    lo = next(e[0] for e in ev if e[1] == 4)
    ms = lambda t: t * 1000.0 / freq
    swaps = sorted(e[0] for e in ev if e[1] == 10)
    third = swaps[2] if len(swaps) > 2 else lo
    flush = [e for e in ev if e[1] == 15 and e[3] == 1 and ms(e[2]) > 5]
    a = b = 0.0
    for e in ev:
        if e[1] != 16:
            continue
        s = e[0] - e[2]
        if ms(s - lo) > 3000 or any(s <= f[0] <= e[0] for f in flush):
            continue
        if s < third:
            a = max(a, ms(e[2]))
        else:
            b = max(b, ms(e[2]))
    frames = [e[0] for e in ev if e[1] == 6 and ms(e[0] - lo) < 3000]
    gap = max((ms(y - x) for x, y in zip(frames, frames[1:])), default=0)
    r = json.loads((run / "render.json").read_text())
    return a, b, gap, r.get("process_start_to_first_swap_ms", 0), r.get("first_swap_at_ms", 0)


groups = defaultdict(list)
for arg in sys.argv[1:]:
    run = pathlib.Path(arg)
    a, b, gap, ttff, first = one(run)
    g = run.parent.name.rstrip("0123456789")
    groups[g].append((a, b, gap, ttff, first))
    print(f"{run.parent.name:14s} A={a:6.1f} B={b:6.1f} gap={gap:6.1f} ttff={ttff:4d} first_swap={first:4d}")
for g, rows in groups.items():
    med = [statistics.median(c) for c in zip(*rows)]
    mx = [max(c) for c in zip(*rows)]
    print(f"{g:14s} n={len(rows)} median A={med[0]:.0f} B={med[1]:.0f} gap={med[2]:.0f} ttff={med[3]:.0f} first_swap={med[4]:.0f} | max A={mx[0]:.0f} B={mx[1]:.0f} gap={mx[2]:.0f}")
