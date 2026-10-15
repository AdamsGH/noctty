"""MEASUREMENT ONLY (PKG-73b): B stalls vs worker spawn and controls.

usage: python -I trig_summary.py <run dir> [more]
Per run (times in ms from first output, whole run): UI iterations over
60 ms that hold no jump-list flush over 5 ms (marked A before the 3rd swap),
worker discovery (span 10) starts, the deferred call (170), the no-op thread
spawn (171) and the cmd.exe launch (172).
"""
import pathlib
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
    swaps = sorted(e[0] for e in ev if e[1] == 10)
    third = swaps[2]
    flush = [e for e in ev if e[1] == 15 and e[3] == 1 and ms(e[2]) > 5]
    out = []
    for e in ev:
        if e[1] != 16 or ms(e[2]) <= 60:
            continue
        s0 = e[0] - e[2]
        if any(s0 <= f[0] <= e[0] for f in flush):
            continue
        out.append(f"{'A' if s0 < third else 'STALL'} {at(s0):.0f}({ms(e[2]):.0f})")
    for e in ev:
        if e[1] == 15 and e[3] in (10, 170, 171, 172, 173):
            name = {10: "worker", 170: "defer", 171: "noop_thread", 172: "cmd", 173: "park"}[e[3]]
            out.append(f"{name}@{at(e[0] - e[2]):.0f}")
    print(f"{run.parent.name:10s} " + " ".join(out))
