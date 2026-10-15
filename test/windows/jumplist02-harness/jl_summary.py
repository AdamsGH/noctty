"""MEASUREMENT ONLY (JUMPLIST-02): jump-list work on the UI thread.

usage: python -I jl_summary.py <run dir> [more]
Per flush (span 1 = the jump-list timer's flush): when (ms from first
output), its total, and inside it: 20 rebuildCom, 21 persist, 22 create,
23 BeginList, 24 CommitList, 25 categories+commit. Then per run: flush
count, max/median flush, UI iterations over 30 ms, largest frame gap in the
first 3 s and over the whole run, and worst UI probe round trip.
"""
import pathlib
import statistics
import sys

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
    spans = [e for e in ev if e[1] == 15]
    flushes = [e for e in spans if e[3] == 1]
    print(f"== {run.parent.name}/{run.name}")
    for f in flushes:
        s0 = f[0] - f[2]
        parts = " ".join(f"{e[3]}={ms(e[2]):.1f}" for e in spans if 20 <= e[3] <= 25 and s0 <= e[0] <= f[0])
        print(f"  flush at {at(s0):8.1f} {ms(f[2]):6.1f} ms  {parts}")
    long_iters = [e for e in ev if e[1] == 16 and ms(e[2]) > 30]
    frames = [e[0] for e in ev if e[1] == 6]
    gaps = [(ms(b - a), at(a)) for a, b in zip(frames, frames[1:])]
    g3 = max((g for g in gaps if g[1] < 3000), default=(0, 0))
    gall = max(gaps, default=(0, 0))
    fl = [ms(f[2]) for f in flushes]
    probes = run / "probes.txt"
    pv = [float(x) for x in probes.read_text().split()] if probes.exists() else [0]
    for sid, name in ((26, "worker_commit"), (27, "ui_complete")):
        v = [ms(e[2]) for e in spans if e[3] == sid]
        if v:
            print(f"  {name}: n={len(v)} median={statistics.median(v):.1f} max={max(v):.1f}")
    print(f"  flushes={len(fl)} max={max(fl, default=0):.1f} median={statistics.median(fl) if fl else 0:.1f} "
          f"iters>30ms={len(long_iters)} gap3s={g3[0]:.1f}@{g3[1]:.0f} gap_all={gall[0]:.1f}@{gall[1]:.0f} probe_max={max(pv):.1f}")
