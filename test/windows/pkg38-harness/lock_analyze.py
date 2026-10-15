"""MEASUREMENT ONLY (PKG-38): renderer_state.mutex contention during output.

usage: python -I lock_analyze.py <run dir> [more run dirs]

Reads latency.txt (LAT-01 trace plus apply_lock.py's events): kind 12
`update_lock` (renderer updateFrame) and 13 `io_lock` (termio processOutput),
a = wait and b = hold in QPC ticks, stamped at unlock; 4 `pty_output`;
6 `frame_update`; 10 `swap_end`. The window is the first to the last
pty_output event. Prints, in ms: the renderer's wait for the mutex
(percentiles, max, counts over 1/8/16 ms), the app thread's waits (kind
14 `ui_lock`), termio's wait and hold, termio's
share of wall time holding the mutex, frame updates and presents per
second, the largest gap between frame updates, and UI probe round trips.
"""
import pathlib
import sys


def pct(v, p):
    if not v:
        return float("nan")
    v = sorted(v)
    return v[min(len(v) - 1, int(round(p * (len(v) - 1))))]


def analyze(run):
    run = pathlib.Path(run)
    freq = None
    ev = []
    for line in (run / "latency.txt").read_text().splitlines():
        p = line.split(" ")
        if p[0] == "F":
            freq = int(p[1])
        elif p[0] == "E":
            ev.append((int(p[1]), int(p[2]), int(p[3]), int(p[4]) if len(p) > 4 else 0))
    ms = lambda t: t * 1000.0 / freq
    out = [e for e in ev if e[1] == 4]
    lo, hi = out[0][0], out[-1][0]
    win = [e for e in ev if lo <= e[0] <= hi]
    upd = [e for e in win if e[1] == 12]
    io = [e for e in win if e[1] == 13]
    ui = [ms(e[2]) for e in win if e[1] == 14]
    frames = [e[0] for e in win if e[1] == 6]
    swaps = [e[0] for e in win if e[1] == 10]
    uw = [ms(e[2]) for e in upd]
    uh = [ms(e[3]) for e in upd]
    iw = [ms(e[2]) for e in io]
    ih = [ms(e[3]) for e in io]
    secs = ms(hi - lo) / 1000.0
    gaps = [ms(b - a) for a, b in zip(frames, frames[1:])]
    r = {
        "secs": round(secs, 2),
        "upd_n": len(upd),
        "upd_wait_p50": pct(uw, .5), "upd_wait_p99": pct(uw, .99), "upd_wait_max": max(uw, default=0),
        "upd_wait_gt1": sum(1 for w in uw if w > 1), "upd_wait_gt8": sum(1 for w in uw if w > 8), "upd_wait_gt16": sum(1 for w in uw if w > 16),
        "upd_hold_p50": pct(uh, .5), "upd_hold_max": max(uh, default=0),
        "ui_n": len(ui), "ui_wait_p99": pct(ui, .99), "ui_wait_max": max(ui, default=0),
        "ui_wait_gt8": sum(1 for w in ui if w > 8), "ui_wait_gt16": sum(1 for w in ui if w > 16),
        "io_n": len(io), "io_wait_p99": pct(iw, .99), "io_wait_max": max(iw, default=0),
        "io_hold_p50": pct(ih, .5), "io_hold_p99": pct(ih, .99), "io_hold_max": max(ih, default=0),
        "io_hold_share": sum(ih) / (secs * 1000.0) if secs else float("nan"),
        "frames_per_s": len(frames) / secs if secs else 0, "presents_per_s": len(swaps) / secs if secs else 0,
        "frame_gap_max": max(gaps, default=0), "frame_gap_p99": pct(gaps, .99),
        "frame_gap_max_at_s": (ms(frames[gaps.index(max(gaps))] - lo) / 1000.0) if gaps else 0.0,
        "read_p50": pct([e[3] for e in out], .5), "read_max": max(e[3] for e in out),
        "mb_per_s": (out[-1][2] - out[0][2]) / 1e6 / secs if secs else 0.0,
    }
    probes = run / "probes.txt"
    if probes.exists():
        pv = [float(x) for x in probes.read_text().split()]
        r["probe_p99"] = pct(pv, .99)
        r["probe_max"] = max(pv)
    return r


def fmt(v):
    return f"{v:.2f}" if isinstance(v, float) else str(v)


for run in sys.argv[1:]:
    r = analyze(run)
    print(f"{pathlib.Path(run).name:34s} " + " ".join(f"{k}={fmt(v)}" for k, v in r.items()))
