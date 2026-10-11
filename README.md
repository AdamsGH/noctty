# PKG-33 startup-cost evidence (not for merging)

Scratch evidence for the pull request "perf(win32): do not start the D3D11/DirectComposition shell compositor at launch (PKG-33, F003)".

- `pkg33/measure.ps1`: hidden-desktop A/B harness (portable copies, LOCALAPPDATA/APPDATA redirected, per-thread context switches from NtQuerySystemInformation, thread start modules, banner and layout probes). Run: `pwsh -NoProfile -File measure.ps1 -Side "base=<bin>,var=<bin>" -Run <new dir> -Runs 11 -IdleSeconds 10`.
- `pkg33/run-ab1`, `run-ab2`: 11 interleaved runs per side each (order flipped in run-ab2). `run-attr3`: thread start-module attribution. `run-layout2`: banner band clip probe per layout.
- `pkg33/test-prefix-pre-fix.log`, `test-fixed.log`: filtered `-Dtest-filter=compositor` runs before and after the change.
- Local profile paths are replaced by `%USERPROFILE%`.
