"""MEASUREMENT ONLY (PKG-73b): merged timeline around the F028 stall.

usage: python -I timeline.py <run dir> [before_ms] [after_ms] [frames]
Times are ms from the first pty_output. Merges: the slowest draw body,
DLL loads (gldiag L lines), nvoglv64 thread stacks and the main thread's
stack (stacks.txt S lines, CPU in ms since the previous sample), and other
threads that used more than 2 ms CPU in a sample (C lines).
"""
import pathlib
import sys

run = pathlib.Path(sys.argv[1])
before = float(sys.argv[2]) if len(sys.argv) > 2 else 300
after = float(sys.argv[3]) if len(sys.argv) > 3 else 50
depth = int(sys.argv[4]) if len(sys.argv) > 4 else 6
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
s0, s1 = at(slow[0] - slow[2]), at(slow[0])
out = [(s0, f"=== STALL START (draw body {s1 - s0:.1f} ms)"), (s1, "=== STALL END")]
diag = run / "gldiag.txt"
if diag.exists():
    for line in diag.read_text(errors="replace").splitlines():
        p = line.split(" ", 2)
        if p[0] == "L":
            out.append((at(int(p[1])), "DLL " + p[2]))
st = run / "stacks.txt"
if st.exists():
    for line in st.read_text(errors="replace").splitlines():
        if line.startswith("S "):
            head, _, frames = line.partition(" | ")
            h = head.split(" ", 5)
            fr = [f for f in frames.split(" ") if not f.startswith("0x")][:depth]
            who = "MAIN" if h[3] == "1" else f"nv {h[2]}"
            out.append((at(int(h[1])), f"{who:9s} cpu={int(h[4]) / 10000:5.1f} " + " < ".join(fr)))
        elif line.startswith("C "):
            h = line.split(" ")
            c = int(h[3]) / 10000
            if c > 2:
                out.append((at(int(h[1])), f"cpu tid {h[2]} {c:.1f} ms start={h[4]}"))
for t, text in sorted(out, key=lambda x: x[0]):
    if s0 - before <= t <= s1 + after:
        print(f"{t:9.1f} {text[:260]}")
