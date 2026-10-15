"""MEASUREMENT ONLY (JUMPLIST-02): per-build medians for the A/B.

usage: python -I jl_ab.py <run dir> [more]   (build = run name before the first '-')
Per run: UI-thread flush cost (span 1) median/max, UI iterations over 30 ms
after the first 400 ms, the largest frame-update gap after the first 400 ms
and over the whole run, the worst UI probe, and process start to first
swap. Then per build: medians of those, and the max of the maxima.
"""
import json
import pathlib
import statistics
import sys
from collections import defaultdict

rows = defaultdict(list)
for arg in sys.argv[1:]:
    run = pathlib.Path(arg)
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
    fl = [ms(e[2]) for e in ev if e[1] == 15 and e[3] == 1]
    iters = sum(1 for e in ev if e[1] == 16 and ms(e[2]) > 30 and at(e[0] - e[2]) > 400)
    frames = [e[0] for e in ev if e[1] == 6]
    gaps = [(ms(b - a), at(a)) for a, b in zip(frames, frames[1:])]
    late = max((g[0] for g in gaps if g[1] > 400), default=0)
    whole = max((g[0] for g in gaps), default=0)
    pv = [float(x) for x in (run / "probes.txt").read_text().split()]
    ttff = json.loads((run / "render.json").read_text()).get("process_start_to_first_swap_ms", 0)
    r = (statistics.median(fl) if fl else 0, max(fl, default=0), iters, late, whole, max(pv), ttff)
    build = run.name.split("-")[0]
    rows[build].append(r)
    print(f"{run.parent.name:12s} {run.name:28s} flush_med={r[0]:5.1f} flush_max={r[1]:5.1f} iters>30={r[2]:2d} gap_after400={r[3]:6.1f} gap_all={r[4]:6.1f} probe_max={r[5]:6.1f} ttff={r[6]}")
for b, rs in rows.items():
    med = [statistics.median(c) for c in zip(*rs)]
    mx = [max(c) for c in zip(*rs)]
    print(f"{b:6s} n={len(rs)} median: flush {med[0]:.1f} (max {mx[1]:.1f}), iters>30 {med[2]:.0f}, gap_after400 {med[3]:.1f} (max {mx[3]:.1f}), gap_all {med[4]:.1f} (max {mx[4]:.1f}), probe {med[5]:.1f} (max {mx[5]:.1f}), ttff {med[6]:.0f}")
