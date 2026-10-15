# PKG-37 measurement additions (measurement only, not for merge)

These extend LAT-01/LAT-02's harness (`test/windows/lat01-harness`,
`test/windows/lat02-harness`, same branch history) for PKG-37 (#362,
renderer pacing). Like those scripts they hard-code the investigation's
scratch paths (`_scratch-pkg37`, `wt-pkg37-<build>`) and are not part of the
product or of CI. Every launch goes through LAT-02's `anim-probe.ps1` outer
half: portable copy, private desktop named explicitly for every child,
LOCALAPPDATA and APPDATA redirected, the real `startup-attempts.json` checked
against the adopted baseline before and after each run.

- `held.c`: a TUI that holds synchronized output (mode 2026) for `hold_ms`
  across four writes, then ESU, for `cycles` cycles; logs QPC-stamped BSU and
  ESU writes. `held_analyze.py`: presents inside the holds and cycles shown.
- `anim-probe.ps1`: LAT-02's, plus `$Extra` passed to noctty (for
  `--power-saver-rendering=on`) and `-InvalidateMs`, which calls
  `RedrawWindow(RDW_INVALIDATE)` on the terminal child every N ms, as an
  expose would.
- `probe-matrix.ps1`: anim.exe or held.exe across builds, interleaved.
- `gaps.py`: present-to-present interval distribution during a probe.
- `lowprio.sh`: runs a `.cmd` at below-normal priority without `start`
  (which hung in this agent shell).
- `final2.sh`, `summarize.sh`: the final before/after run and its pooling;
  `results-G.txt` is its output (main 7171995da vs ce0dcfc2f, the code of
  #362's head before two rebases onto unrelated PRs).
