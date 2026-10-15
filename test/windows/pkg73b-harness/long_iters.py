"""MEASUREMENT ONLY (PKG-73b): every UI iteration over a threshold, whole run.

usage: python -I long_iters.py <run dir> [threshold_ms]
Times are ms from the first pty_output; shows the message id, the spans
(kind 15) inside each iteration over 1 ms, and the swaps before it.
"""
import pathlib
import sys

run = pathlib.Path(sys.argv[1])
thr = float(sys.argv[2]) if len(sys.argv) > 2 else 50
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
spans = [e for e in ev if e[1] == 15]
for e in ev:
    if e[1] != 16 or ms(e[2]) < thr:
        continue
    s = e[0] - e[2]
    inside = [x for x in spans if s <= x[0] <= e[0] and ms(x[2]) > 1 and x[3] < 100]
    swaps = sum(1 for x in ev if x[1] == 10 and x[0] < s)
    parts = ", ".join(f"{x[3]}={ms(x[2]):.0f}" for x in inside)
    print(f"  {ms(s - lo):8.1f} iter {ms(e[2]):6.1f} msg=0x{e[3]:x} swaps_before={swaps} {parts}")
