# PKG-73(b) measurement harness (not for merge)

This harness investigates F028, the one-time 140–240 ms stall at the first GL call of a `drawFrame`. Everything here is measurement-only.

Everything runs on the LAT-01/PKG-38 harness: a portable copy on a private desktop, with `LOCALAPPDATA` and `APPDATA` redirected and `--copy-on-select=false`. The real `startup-attempts.json` hash, the PSReadLine history fingerprint and `GetClipboardSequenceNumber()` are logged before and after every batch. The clipboard sequence number stayed at 739 throughout.

## Build patches

Apply these on top of the PKG-37/38/STARTUP-STALL trace patches:

- `apply_gldiag.py`: env `NOCTTY_GLDIAG`.
  - `d`: a `GL_DEBUG_OUTPUT` callback that writes QPC- and thread-stamped lines to `NOCTTY_GLDIAG_FILE`.
  - `s` / `f`: `glFinish` spans 111 and 110.
- `apply_gldiag2.py`: spans for the render-pass steps (130+n), flush/present/swap (140–143), `initShaders` (150) and `prepareContext` (151).
- `apply_gldiag3.py`: `l` logs DLL loads with `LdrRegisterDllNotification`.
- `apply_glwarm.py`: `w` starts an off-UI-thread warm-up WGL context from `App.init`. It runs for `NOCTTY_GLWARM_MS` and is recorded as spans 160–162.

## Driver and tools

- `make_relaunch.py` generates `relaunch-probe.ps1` from `contend-probe.ps1`. Options:
  - `-Relaunch` reuses the same exe path.
  - `-Env` passes env switches.
  - `PKG73_SAMPLE_MS` starts `stacksamp.exe` with CREATE_NO_WINDOW on the private desktop.
  - `PKG73_NEWTAB_MS` opens new tabs.
  - `PKG73_QUIET` runs an idle `cmd /k` instead of the flood.
- `relaunch-matrix.ps1` runs the probe across builds and reps.
- `stacksamp.c` is an external sampler. It suspends the main thread and threads that started in nvoglv64 and walks their stacks.
- `thwalk.c` times a system-wide Toolhelp thread walk.
- `pe_exports.py` names system frames by their nearest export.
- Analyzers: `timeline.py`, `trigger.py`, `long_iters.py`, `ab_summary.py`, `gldiag_analyze.py`, `draw_ck.py`, `stacks_analyze.py`, `verify_timeline.py`.

## Results

- `P73b-ab.txt`: warm-up vs none, n=5 each.
- `P73b-trigger.txt`: when the stall lands.
- `P73b-newtab.txt`: no repeat on new tabs.
- `P73b-quiet.txt`: no B stall when idle.
- `P73b-timeline-B.txt`: UI thread and driver server thread during a B stall.
- `P73b-thwalk.txt`: Toolhelp walk cost on this machine.
