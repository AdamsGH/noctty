"""MEASUREMENT ONLY (PKG-46): UI-thread cost of the picker and the palette.

usage: python -I pkg46_summary.py <run dir> [more]
Per run: the longest WM_COMMAND (0x111) iteration (the palette opened by a
posted 1901), every UI iteration over 30 ms before the first swap, the
longest iteration overall, process start to first swap, and the worker's
discovery span (10) count.
"""
import json
import pathlib
import statistics
import sys
from collections import defaultdict

rows = defaultdict(list)
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
    ms = lambda d: d * 1000.0 / freq
    swaps = sorted(e[0] for e in ev if e[1] == 10)
    iters = [e for e in ev if e[1] == 16]
    cmd = max((ms(e[2]) for e in iters if e[3] == 0x111), default=0)
    pre = [ms(e[2]) for e in iters if e[0] < swaps[0] and ms(e[2]) > 30]
    top = max(ms(e[2]) for e in iters)
    workers = sum(1 for e in ev if e[1] == 15 and e[3] == 10)
    picker = max((ms(e[2]) for e in ev if e[1] == 15 and e[3] == 30), default=0)
    ui_disc = [ms(e[2]) for e in ev if e[1] == 15 and e[3] == 32]
    palette = max((ms(e[2]) for e in ev if e[1] == 15 and e[3] == 31), default=0)
    frames = [e[0] for e in ev if e[1] == 6]
    gap1s = max((ms(b - a) for a, b in zip(frames, frames[1:]) if ms(a - frames[0]) < 1000), default=0)
    ttff = json.loads((run / "render.json").read_text()).get("process_start_to_first_swap_ms", 0)
    build = run.name.split("-")[0]
    rows[build].append((cmd, max(pre, default=0), top, ttff, picker, palette, gap1s))
    print(f"{run.parent.name:12s} {run.name:28s} wm_command_max={cmd:6.1f} pre_first_swap={[round(x) for x in pre]} iter_max={top:6.1f} ttff={ttff} worker_discoveries={workers} picker_span={picker:.1f} palette_rebuild_max={palette:.1f} gap_first_1s={gap1s:.1f} ui_discoveries={len(ui_disc)} ui_discovery_ms={[round(x) for x in ui_disc]}")
for b, rs in rows.items():
    med = [statistics.median(c) for c in zip(*rs)]
    mx = [max(c) for c in zip(*rs)]
    print(f"{b:6s} n={len(rs)} median wm_command {med[0]:.1f} (max {mx[0]:.1f}), pre-first-swap iter {med[1]:.1f} (max {mx[1]:.1f}), iter_max {med[2]:.1f}, ttff {med[3]:.0f} (max {mx[3]:.0f}), picker {med[4]:.1f} (max {mx[4]:.1f}), palette rebuild max {med[5]:.1f} (max {mx[5]:.1f}), gap first 1 s {med[6]:.1f} (max {mx[6]:.1f})")
