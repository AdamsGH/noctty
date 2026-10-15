"""MEASUREMENT ONLY (PKG-73b): line up the F028 stall with GL debug messages,
glFinish spans and thread creation.

usage: python -I gldiag_analyze.py <run dir> [more]
Times are ms from the first pty_output.
"""
import pathlib
import sys


def load(run):
    freq = None
    ev = []
    for line in (run / "latency.txt").read_text().splitlines():
        p = line.split(" ")
        if p[0] == "F":
            freq = int(p[1])
        elif p[0] == "E":
            ev.append((int(p[1]), int(p[2]), int(p[3]), int(p[4])))
    return freq, ev


def analyze(run):
    run = pathlib.Path(run)
    freq, ev = load(run)
    lo = next(e[0] for e in ev if e[1] == 4)
    ms = lambda t: t * 1000.0 / freq
    at = lambda q: (q - lo) * 1000.0 / freq
    bodies = [e for e in ev if e[1] == 15 and e[3] == 9]
    slow = max(bodies, key=lambda b: b[2])
    s_start = at(slow[0] - slow[2])
    print(f"== {run}")
    print(f"  slowest draw body {ms(slow[2]):.1f} ms at {s_start:.1f}; first draw at {at(bodies[0][0] - bodies[0][2]):.1f}")
    fine = [e for e in ev if e[1] == 15 and e[3] >= 110]
    for e in fine:
        if e[3] in (150, 151):
            print(f"  span {e[3]} {ms(e[2]):.1f} ms ending at {at(e[0]):.1f}")
    msgs = [e for e in ev if e[1] == 16]

    def detail(b, tag):
        start = b[0] - b[2]
        it = next((m for m in msgs if m[0] - m[2] <= start <= m[0]), None)
        lo_t = it[0] - it[2] if it else start
        hi_t = it[0] if it else b[0]
        inside = [e for e in fine if lo_t <= e[0] <= hi_t and e[3] not in (150, 151)]
        parts = " ".join(f"{e[3]}={ms(e[2]):.1f}" for e in inside)
        itxt = f"iter {ms(it[2]):.1f} msg=0x{it[3]:x}" if it else "no iter"
        print(f"  {tag} body {ms(b[2]):.1f} at {at(start):.1f} ({itxt}): {parts}")

    for b in bodies[:2]:
        detail(b, "early")
    detail(slow, "slowest")
    for sid in (110, 111):
        sp = [e for e in ev if e[1] == 15 and e[3] == sid]
        if sp:
            top = sorted(sp, key=lambda e: -e[2])[:3]
            print(f"  glFinish span {sid}: n={len(sp)} top=" + ", ".join(f"{ms(e[2]):.1f}@{at(e[0] - e[2]):.0f}" for e in top))
    diag = run / "gldiag.txt"
    if diag.exists():
        for line in diag.read_text(errors="replace").splitlines():
            p = line.split(" ", 2)
            if p[0] in ("M", "C"):
                print(f"  {p[0]} {at(int(p[1])):9.1f} {p[2][:200]}")
    th = run / "threads.txt"
    if th.exists():
        rows = th.read_text().splitlines()
        q = next(r for r in rows if r.startswith("Q ")).split()
        qpc_now, utc_now, qf = int(q[1]), int(q[2]), int(q[3])
        # UTC ticks (100 ns) -> QPC
        to_q = lambda ticks: qpc_now - (utc_now - ticks) * qf // 10_000_000
        pstart = int(next(r for r in rows if r.startswith("P ")).split()[1])
        print(f"  process start at {at(to_q(pstart)):.1f}")
        for r in rows:
            if r.startswith("T "):
                _, ticks, where, tid = r.split()
                print(f"  thread {at(to_q(int(ticks))):9.1f} {where} {tid}")


for r in sys.argv[1:]:
    analyze(r)
