"""MEASUREMENT ONLY (PKG-73b): per drawFrame, the checkpoint spans 101-109.

usage: python -I draw_ck.py <run dir> [n]

Prints the first n draw bodies (span 9) with their start time (ms from the
first pty_output) and, for each checkpoint id, the ms since the draw body's
start, plus the slowest draw body in the trace.
"""
import pathlib
import sys

run = pathlib.Path(sys.argv[1])
n = int(sys.argv[2]) if len(sys.argv) > 2 else 6
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
at = lambda t: (t - lo) * 1000.0 / freq
bodies = [e for e in ev if e[1] == 15 and e[3] == 9]
cks = [e for e in ev if e[1] == 15 and 101 <= e[3] <= 120]


def show(b, tag=""):
    start = b[0] - b[2]
    inside = [c for c in cks if start <= c[0] <= b[0]]
    parts = " ".join(f"{c[3]}:{ms(c[0] - start):.1f}" for c in inside)
    print(f"{tag}draw at {at(start):8.1f} body {ms(b[2]):7.1f}  {parts}")


for b in bodies[:n]:
    show(b)
if bodies:
    show(max(bodies, key=lambda b: b[2]), "slowest ")
print(f"draw bodies={len(bodies)}")
