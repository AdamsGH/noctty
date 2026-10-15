"""MEASUREMENT ONLY (PKG-38): one row per case, pooled over reps.

usage: python -I lock_summary.py <matrix dir> [more matrix dirs]
"""
import pathlib
import re
import sys

sys.path.insert(0, str(pathlib.Path(__file__).parent))
import importlib.util

spec = importlib.util.spec_from_file_location("la", pathlib.Path(__file__).parent / "lock_analyze.py")
la = importlib.util.module_from_spec(spec)
sys.argv, argv = sys.argv[:1], sys.argv[1:]
spec.loader.exec_module(la)

print(f"{'case':38s} {'reps':>4s} {'MB/s':>6s} {'io_hold':>7s} {'frames/s':>8s} {'upd p50':>7s} {'upd p99':>7s} {'upd max':>7s} {'>8ms':>5s} {'>16ms':>5s} {'ui max':>6s}")
for d in argv:
    groups = {}
    for run in sorted(pathlib.Path(d).iterdir()):
        if not (run / "latency.txt").exists():
            continue
        case = re.sub(r"-r\d+$", "", run.name)
        groups.setdefault(case, []).append(la.analyze(run))
    for case, rs in groups.items():
        f = lambda k, agg: agg(r[k] for r in rs)
        print(f"{case:38s} {len(rs):4d} {f('mb_per_s', min):6.1f} {f('io_hold_share', max):7.2f} {f('frames_per_s', min):8.1f} "
              f"{f('upd_wait_p50', max):7.2f} {f('upd_wait_p99', max):7.2f} {f('upd_wait_max', max):7.2f} "
              f"{f('upd_wait_gt8', sum):5d} {f('upd_wait_gt16', sum):5d} {f('ui_wait_max', max):6.2f}")
