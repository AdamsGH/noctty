"""MEASUREMENT ONLY (LAT-02): summarize one #310 flood-probe run.

usage: python -I flood_summary.py <run dir> [more run dirs]

probes.txt holds one WM_NULL round trip (ms) per probe; the prober sleeps
7 ms between probes, so a probe's start time is approximated as the sum of
the earlier round trips plus 7 ms each. The resize is posted 1.5 s in.
"""
import pathlib
import sys

SLEEP_MS = 7.0


def summarize(run):
    vals = [float(x) for x in (pathlib.Path(run) / "probes.txt").read_text().split()]
    t = 0.0
    window, after = [], []
    for v in vals:
        if 1500.0 <= t < 2500.0:
            window.append(v)
        elif t >= 2500.0:
            after.append(v)
        t += v + SLEEP_MS
    after.sort()

    def pct(p):
        return after[min(len(after) - 1, int(round(p * (len(after) - 1))))]

    return (f"{pathlib.Path(run).name:12s} n={len(vals)} resize-second max={max(window) if window else float('nan'):.1f} ms"
            f"  after 2.5 s: n={len(after)} p50={pct(.5):.1f} p99={pct(.99):.1f} max={after[-1]:.1f}"
            f"  over100ms={sum(1 for v in vals if v > 100)} total={t / 1000:.1f}s")


for run in sys.argv[1:]:
    print(summarize(run))
