"""MEASUREMENT ONLY (PKG-73b): what each thread did during the F028 stall.

usage: python -I stacks_analyze.py <run dir> [frames]
Finds the slowest draw body in latency.txt, then summarises stacks.txt
samples inside it: the main thread's stack (top frames, counted) and every
other thread that used CPU (CPU ms, start routine, top frames, counted).
"""
import collections
import pathlib
import sys

run = pathlib.Path(sys.argv[1])
depth = int(sys.argv[2]) if len(sys.argv) > 2 else 8
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
s0, s1 = slow[0] - slow[2], slow[0]
print(f"stall body {(s1 - s0) * 1000 / freq:.1f} ms at {at(s0):.1f}")

samples = []
for line in (run / "stacks.txt").read_text(errors="replace").splitlines():
    if not line.startswith("S "):
        continue
    head, _, frames = line.partition(" | ")
    h = head.split(" ", 5)
    samples.append((int(h[1]), int(h[2]), h[3] == "1", int(h[4]), h[5] if len(h) > 5 else "?", frames.split(" ")))
inside = [s for s in samples if s0 <= s[0] <= s1]
before = [s for s in samples if s[0] < s0]
print(f"samples total={len(samples)} inside={len(inside)} first_sample_at={at(samples[0][0]):.1f}" if samples else "no samples")

main = collections.Counter(" < ".join(s[5][:depth]) for s in inside if s[2])
print("main thread stacks inside the stall:")
for k, n in main.most_common(6):
    print(f"  {n:3d}  {k}")
busy = collections.defaultdict(lambda: [0, collections.Counter(), ""])
for s in inside:
    if s[2]:
        continue
    b = busy[s[1]]
    b[0] += s[3]
    b[1][" < ".join(s[5][:depth])] += 1
    b[2] = s[4]
print("other threads with CPU inside the stall:")
for tid, (cpu, ctr, start) in sorted(busy.items(), key=lambda kv: -kv[1][0]):
    print(f"  tid {tid} cpu={cpu / 10000:.1f} ms start={start}")
    for k, n in ctr.most_common(3):
        print(f"     {n:3d}  {k}")
