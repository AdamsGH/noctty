# LAT-02 measurement additions (measurement only, not for merge)

These extend LAT-01's harness (`test/windows/lat01-harness`, same branch
history) for the LAT-02 change ("a typed key presents its echo, not a frame of
its own"). Like LAT-01's scripts they hard-code the investigation's scratch
paths (`_scratch-lat02`, `wt-lat02-<build>`) and are not part of the product
or of CI. Every launch goes through LAT-01's `lat-driver2.ps1` outer half:
portable copy, private desktop named explicitly for every child, LOCALAPPDATA
and APPDATA redirected, the real `startup-attempts.json` checked against the
adopted baseline before and after each run.

- `apply_trace.py`: LAT-01's trace patcher with one anchor moved. #345 moved
  `WM_WINHOSTTY_WAKE` delivery to the App message window, so the `app_wake`
  event is now noted in `tickCoreApp` (diagnostic only; no analysis uses it).
- `matrix.ps1`: LAT-01's `matrix2.ps1` with paths for this task, a
  `-DriverScript` choice and an `-Extra` pass-through for noctty flags
  (`--power-saver-rendering=on`).
- `lat-driver3.ps1`: `lat-driver2.ps1` plus a `cursor` pattern (40 letters,
  then Left/Right alternating; each arrow's echo `ESC[D`/`ESC[C` only moves
  the cursor) and the extended-key bit on arrow keys.
- `analyze_cursor.py`: per-arrow-key latency to the first present whose
  frame update counted the pty chunk holding the echo's final byte.
  Artifacts in its tail: `lat-echo` writes each byte separately and inserts
  CR LF after 60 echoed bytes, escape bytes included, so an echo can arrive
  in three reads, with CR LF inside the CSI.
- `counts.py`: presents (SwapBuffers), presents whose frame carried new pty
  output, frame updates and renderer wakes by `WakeSource` between the first
  key and 1 s after the last.
- `anim.c`, `make_anim.py` (writes `anim-probe.ps1`), `anim-matrix.ps1`,
  `anim_analyze.py`: a 60 fps full-screen TUI, each frame in synchronized
  output; reports which frames reached a present.
- `flood-matrix.ps1`, `flood_summary.py`: #310's flood case (LAT-01's
  `flood-probe.ps1`) and a summary of its WM_NULL probes.
- `final.sh`: the final before/after run. `results.txt`: its pooled output.
