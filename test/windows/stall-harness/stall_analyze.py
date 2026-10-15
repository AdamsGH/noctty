"""MEASUREMENT ONLY (STARTUP-STALL): the UI thread's long iterations.

usage: python -I stall_analyze.py <run dir> [more run dirs]

Times are ms from the first pty_output. Lists message-loop iterations
(kind 16 `ui_msg`) longer than 20 ms with their message id and the spans
(kind 15) that ended inside them: 1 jump-list flush, 2 deferred profile
discovery, 3 tickCoreApp, 4 discoverProfiles. Then a summary line: the
largest frame-update gap in the first 3 s, the longest iteration, the
spans' durations, and the UI probe's worst round trip.
"""
import pathlib
import sys

MSG = {0x000F: "WM_PAINT", 0x0113: "WM_TIMER", 0x8001: "WM_APP+1"}
SPAN = {1: "jumplist_flush", 2: "jumplist_discovery", 3: "tick", 4: "discoverProfiles", 10: "worker_discovery", 7: "rebuild_hold", 8: "draw_wait", 9: "draw_body"}


def analyze(run, verbose=True):
    run = pathlib.Path(run)
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
    iters = [e for e in ev if e[1] == 16]
    spans = [e for e in ev if e[1] == 15]
    long_iters = [e for e in iters if ms(e[2]) > 20]
    if verbose:
        for e in long_iters:
            start = e[0] - e[2]
            inside = [s for s in spans if start <= s[0] <= e[0] and ms(s[2]) > 1]
            name = MSG.get(e[3], hex(e[3]))
            parts = ", ".join(f"{SPAN.get(s[3], s[3])}={ms(s[2]):.1f}" for s in inside)
            print(f"  iter {ms(e[2]):7.1f} ms at {at(start):8.1f} {name:9s} {parts}")
    frames = [e[0] for e in ev if e[1] == 6 and at(e[0]) < 3000]
    gaps = [(ms(b - a), at(a)) for a, b in zip(frames, frames[1:])]
    g = max(gaps, default=(0, 0))
    sp = {}
    for s in spans:
        if s[3] in (1, 2, 4, 10):
            sp.setdefault(SPAN[s[3]], []).append(round(ms(s[2]), 1))
    probes = run / "probes.txt"
    pmax = max((float(x) for x in probes.read_text().split()), default=0) if probes.exists() else 0
    pv = [float(x) for x in probes.read_text().split()] if probes.exists() else []
    t, early = 0.0, 0.0
    for v in pv:
        if t >= 300:  # skip the very first probe window (window creation)
            early = max(early, v) if t < 3000 else early
        t += v + 7
    print(f"{run.name:34s} frame_gap_max={g[0]:.1f} at={g[1]:.0f} iter_max={max((ms(e[2]) for e in iters), default=0):.1f} "
          f"long_iters={len(long_iters)} spans={sp} probe_max={pmax:.1f} probe_max_0.3-3s={early:.1f}")


for run in sys.argv[1:]:
    analyze(run)
