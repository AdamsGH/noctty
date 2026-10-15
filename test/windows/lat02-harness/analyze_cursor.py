"""MEASUREMENT ONLY (LAT-02): latency of echoes that only move the cursor.

usage: python -I analyze_cursor.py <matrix dir> [--per-key]

For lat-driver3 `cursor` runs: keys 0-39 type letters, every later key is
Left or Right, whose echo (ESC[D / ESC[C, written byte by byte by lat-echo)
only moves the cursor. For each arrow key: the last byte of its echo is the
k-th 'D'/'C' lat-echo wrote after the letters; the echo is drawn by the first
SwapBuffers whose frame update counted the pty output chunk holding that
byte. Reports post -> that swap and -> its emulated display, pooled per
build x scenario.
"""
import bisect
import pathlib
import statistics
import sys

sys.path.insert(0, str(pathlib.Path(__file__).parent))
from analyze import load  # noqa: E402


def arrow_rows(run):
    freq, ev, _blob, kd, _ku, _recv, _sent = load(run)
    ms = lambda d: d * 1000.0 / freq
    writes = []
    for line in (pathlib.Path(run) / "echo.txt").read_text().splitlines():
        p = line.split()
        if len(p) == 3 and p[0] == "W":
            writes.append((int(p[1]), int(p[2])))
    writes.sort()
    finals = [w for w in writes if w[1] in (67, 68)]  # 'C', 'D'
    outputs = ev["pty_output"]
    frames = ev["frame_update"]
    swaps = ev["swap_end"]
    rows = []
    arrow_keys = sorted(k for k in kd if kd[k][1] in (0x25, 0x27))
    for n, k in enumerate(arrow_keys):
        if n >= len(finals):
            break
        post = kd[k][0]
        oi = bisect.bisect_left(outputs, (finals[n][0], -1, -1))
        if oi >= len(outputs):
            continue
        need = outputs[oi][1]
        row = {"k": k, "pty_output": ms(outputs[oi][0] - post)}
        fi = next((j for j in range(len(frames)) if frames[j][1] >= need), None)
        if fi is not None:
            row["frame_update"] = ms(frames[fi][0] - post)
            si = bisect.bisect_left(swaps, (frames[fi][0], -1, -1))
            while si < len(swaps) and swaps[si][1] < need:
                si += 1
            if si < len(swaps):
                row["swap"] = ms(swaps[si][0] - post)
                if swaps[si][2]:
                    row["display"] = ms(swaps[si][2] - post)
        rows.append(row)
    return rows


def pct(v, p):
    v = sorted(v)
    return v[min(len(v) - 1, int(round(p * (len(v) - 1))))]


root = pathlib.Path(sys.argv[1])
groups = {}
for d in sorted(root.iterdir()):
    if not (d / "latency.txt").exists():
        continue
    build, rest = d.name.split("-", 1)
    scen = rest.rsplit("-r", 1)[0]
    rows = arrow_rows(d)
    groups.setdefault((scen, build), []).extend(rows)
    if "--per-key" in sys.argv:
        for r in rows:
            print(d.name, {k: round(v, 2) if isinstance(v, float) else v for k, v in r.items()})
for field in ("pty_output", "frame_update", "swap", "display"):
    print(f"== {field} (ms; arrow keys whose echo only moves the cursor)")
    print(f"{'scenario':38s} {'build':6s} {'n':>5s} {'median':>8s} {'p95':>8s} {'p99':>8s} {'max':>8s}")
    for (scen, build), rows in sorted(groups.items()):
        vals = [r[field] for r in rows if field in r]
        if not vals:
            continue
        miss = len(rows) - len(vals)
        print(f"{scen:38s} {build:6s} {len(vals):5d} {statistics.median(vals):8.2f} {pct(vals, .95):8.2f} {pct(vals, .99):8.2f} {max(vals):8.2f}" + (f"  missing={miss}" if miss else ""))
