"""MEASUREMENT ONLY (PKG-73b): when the driver's verify thread runs vs the stall.

usage: python -I verify_timeline.py <run dir> [start-routine substring]
Prints the stall (slowest draw body), then the time range and CPU of samples
from threads whose start routine contains the substring (default
nvoglv64.dll+0xa1ec80), and the distinct modules in their stacks.
"""
import collections
import pathlib
import sys

run = pathlib.Path(sys.argv[1])
key = sys.argv[2] if len(sys.argv) > 2 else "nvoglv64.dll+0xa1ec80"
freq = None
ev = []
for line in (run / "latency.txt").read_text().splitlines():
    p = line.split(" ")
    if p[0] == "F":
        freq = int(p[1])
    elif p[0] == "E":
        ev.append((int(p[1]), int(p[2]), int(p[3]), int(p[4])))
lo = next(e[0] for e in ev if e[1] == 4)
at = lambda q: (q - lo) * 1000.0 / freq
bodies = [e for e in ev if e[1] == 15 and e[3] == 9]
slow = max(bodies, key=lambda b: b[2])
print(f"{run.name}: stall {slow[2] * 1000 / freq:.1f} ms from {at(slow[0] - slow[2]):.1f} to {at(slow[0]):.1f}")
rows = []
for line in (run / "stacks.txt").read_text(errors="replace").splitlines():
    if line.startswith("S "):
        head, _, frames = line.partition(" | ")
        h = head.split(" ", 5)
        rows.append((int(h[1]), int(h[2]), h[3] == "1", int(h[4]), h[5], frames.split(" ")))
v = [r for r in rows if key in r[4]]
if not v:
    print("  no samples of that thread")
    sys.exit()
cpu = sum(r[3] for r in v if r[3] < 10**10) / 10000
mods = collections.Counter(f.split("+")[0] for r in v for f in r[5])
print(f"  verify thread tid={v[0][1]} busy samples={len(v)} from {at(v[0][0]):.1f} to {at(v[-1][0]):.1f}, cpu~{cpu:.1f} ms")
print("  modules:", ", ".join(f"{m}:{n}" for m, n in mods.most_common(10)))
main = [r for r in rows if r[2] and at(slow[0] - slow[2]) <= at(r[0]) <= at(slow[0])]
for r in main[:2]:
    print("  main in stall:", " < ".join(r[5][:8]))
for r in v:
    print(f"  {at(r[0]):8.1f} cpu={r[3] / 10000:.1f} " + " < ".join(f for f in r[5][:7] if not f.startswith("0x")))
