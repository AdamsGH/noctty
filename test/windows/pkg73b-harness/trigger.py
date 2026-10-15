"""MEASUREMENT ONLY (PKG-73b): what precedes the F028 stall.

usage: python -I trigger.py <run dir> [more]
For each run: the longest UI message-loop iteration in the first 3 s that
did not contain a jump-list flush (span 1), its start relative to the GL
context's prepareContext (span 151) end, the number of swaps (swap_end)
and frame updates before it, and the message id.
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
    ms = lambda t: t * 1000.0 / freq
    ctx = [e for e in ev if e[1] == 15 and e[3] == 151]
    base = ctx[0][0] if ctx else lo
    flush = [e for e in ev if e[1] == 15 and e[3] == 1]
    iters = []
    for e in ev:
        if e[1] != 16 or ms(e[0] - lo) > 3000:
            continue
        s = e[0] - e[2]
        if any(s <= f[0] <= e[0] and ms(f[2]) > 5 for f in flush):
            continue
        iters.append(e)
    top = max(iters, key=lambda e: e[2])
    s = top[0] - top[2]
    swaps = sum(1 for e in ev if e[1] == 10 and e[0] < s)
    ups = sum(1 for e in ev if e[1] == 6 and e[0] < s)
    print(f"{run.parent.name}/{run.name:32s} stall {ms(top[2]):6.1f} ms msg=0x{top[3]:x} at {ms(s - lo):7.1f} from output, "
          f"{ms(s - base):7.1f} from context, swaps_before={swaps} updates_before={ups}")
