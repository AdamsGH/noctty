# JUMPLIST-02 / PKG-46 measurement harness (not for merge)

Runs on the LAT-01/PKG-38/PKG-73b relaunch probe (`test/windows/pkg73b-harness`).
Measurement builds take the trace patches (`apply_trace`, `apply_vsync`, `apply_lock`,
`apply_stall`), plus:

- `apply_aumid_isolate.py`: a separate AUMID (`io.github.amanthanvi.noctty.measure`) and no
  HKCU registration. A portable copy otherwise commits its jump list under the product AUMID,
  into the real `%APPDATA%\Microsoft\Windows\Recent\CustomDestinations`, replacing the
  maintainer's taskbar jump list until the real noctty starts again.
- `apply_jlspans.py` (main) / `apply_jlspans2.py` (this branch): spans inside `JumpList.flush`.
- `apply_pkg46spans.py`: spans around the startup picker, `rebuildPaletteList` and
  `Host.reloadProfiles` (the UI-thread discovery).
- `cdflood.c`: steady coloured output with an OSC 7 directory change every 700 ms.

`relaunch-matrix.ps1 -Case colour-focused-cd` runs `cdflood`; `PKG73_NEWTAB_MS=150` with
`PKG73_CMD=1901` opens the palette 150 ms in; `NOCTTY_WIN32_STARTUP_PROFILE_PICKER=1` opens the
picker at start-up; `PKG73_QUIET=1` runs an idle `cmd /k`. `F-results.txt` is the final batch
(main e32c6b3a6 as `mjl`, the branch at 81012ad7d as `mjl4`).
