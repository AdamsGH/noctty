# Agent Development Guide

A file for [guiding coding agents](https://agents.md/) working in this
Windows-only Ghostty fork.

## Commands

- **Build:** `zig build` (also stages the pinned `conpty.dll` and
  `OpenConsole.exe` beside the exe; see the 2026-10-10 bundled ConPTY entry
  in `docs/agents/log/conpty.md`)
- **Test (Zig):** `zig build test -Demit-test-exe=true --summary all`
  (full suite, ~4.5k tests, about a minute). This is the only invocation that
  is trustworthy on its own, and `--summary all` is part of it: the count is
  the evidence.
  - Bare `zig build test` errors in this fork.
  - `-Dtest-filter=<token>` runs the tests whose fully qualified name (file
    path, `.test.`, test name) contains the token, for quick iteration; it is
    not evidence on its own. Read the count: the `N/M tests passed` line
    counts the matching tests plus about 70 unnamed `test { ... }` blocks that
    no filter excludes, so a token that matches nothing still reports about
    70 passes, not zero. Use `ConPTY` to reach the probe tests in
    `src/pty_transport_probe.zig`. A filtered build compiles the whole tree,
    about a minute. `Build Summary: 41/41 steps succeeded` counts build
    steps, not tests. See the 2026-10-06 filter entry in
    `docs/agents/log/test-harnesses.md`.
- **Formatting (Zig):** `zig fmt .`
- **Formatting (other):** `prettier -w .`

## libghostty-vt

- Build: `zig build -Demit-lib-vt`
- Build WASM: `zig build -Demit-lib-vt -Dtarget=wasm32-freestanding -Doptimize=ReleaseSmall`

## Directory Structure

- Shared Zig core: `src/`
- Win32 application runtime: `src/apprt/win32.zig` coordinates App, Host, and
  Surface behavior; `src/apprt/win32_theme.zig` owns theme policy; focused
  support modules under `src/apprt/win32/` own Win32 constants/externs,
  labels/input, startup/render tracing, chrome rectangle math, and GDI paint
  primitives.
- Windows packaging: `dist/windows/` + `scripts/package-windows.ps1`
- libghostty-vt headers: `include/ghostty/`

This fork removed the upstream `macos/` Xcode app and the `src/apprt/gtk`
runtime. Do not reintroduce them.

## Issue and PR Guidelines

- Never create an issue.
- Never create a PR to the upstream Ghostty repo; only work against this
  fork, `amanthanvi/noctty`.
- If the user asks you to create an issue or PR, confirm the target is this
  fork and refuse any upstream publish request. If publishing is still
  disallowed by the active task contract, offer a local patch summary or
  handoff instead.

## Self-Correction Log

The log is this fork's dated record of measured traps. It lives in
[`docs/agents/log/`](docs/agents/log/), one file per area of the code, each
newest first. A code comment or doc that cites "AGENTS.md <date>" means an
entry there: find it with `git grep -n "^- <date>:" docs/agents/log/` and the
subject it names (several entries share a date). Older comments cite an
AGENTS.md line number (`AGENTS.md:75`) from a layout that no longer exists;
search the log for the symbol they mention instead.

Before a change, read the file for each area whose trigger below matches it:

- [conpty.md](docs/agents/log/conpty.md): `src/pty.zig`, the pty reader and
  write pool in `termio/Exec.zig`, `ResizePseudoConsole`, the bundled
  `conpty.dll`/`OpenConsole.exe` (`scripts/stage-conpty-redist.ps1`), in-box
  conhost versus bundled ConPTY, what ConPTY's buffer holds after a resize,
  minimize, clear or undo.
- [shell-integration.md](docs/agents/log/shell-integration.md): scripts under
  `src/shell-integration/` (PowerShell `integration.ps1`, cmd/Clink) and their
  injection (`termio/shell_integration.zig` argv analysis,
  `win32_powershell_install.zig`): the OSC 133 and OSC 7 marks a shell emits,
  PSReadLine hooks, execution policy.
- [terminal-core.md](docs/agents/log/terminal-core.md): `src/terminal/` (VT
  parser limits, `PageList`, OSC parsers, OSC 133 exit codes, prompt typeahead
  in `semantic_command.zig`, the scrollback search thread,
  `TerminalFormatter`/`ScreenFormatter` output for undo snapshots and Copy as
  HTML), OSC 7 and OSC 9;9 cwd reports (`termio/stream_handler.zig`,
  `os.hostname.isLocal`), `src/Surface.zig` locking around links.
- [renderer.md](docs/agents/log/renderer.md): `src/renderer/` (OpenGL/WGL,
  the D3D11 beta and GL-to-D3D11 fallback, `Thread.zig` pacing and follow-up
  timers, synchronized output, vsync, `RenderPass` viewport, cursor sprites,
  search highlights after a resize), `win32/pixel_format.zig`, font fallback,
  renderer wakeups from `termio` and typing latency, repaint during live
  resize. `font-thicken` is in the 2026-10-17 PKG-66 entry in
  app-lifecycle.md; showing and hiding pane surfaces is in tabs-panes.md.
- [window-frame.md](docs/agents/log/window-frame.md): the top-level window:
  `WM_NCCALCSIZE`/`WM_NCHITTEST` (`win32_nc_layout.zig`), integrated titlebar
  and caption buttons, `window-decoration = none`, resize bands, maximize,
  fullscreen and restore placement, `WM_DPICHANGED` and mixed-DPI moves,
  `window-width`/`window-height`, `background-opacity` and DWM backdrop, the
  window menu, the quick terminal (`win32_quick_terminal.zig`).
- [chrome-tabs-paint.md](docs/agents/log/chrome-tabs-paint.md): tab buttons
  (`tabButtonProc`, `drawButton`, labels, tooltips, close X, underline,
  `win32_tab_visual.zig`), `window-show-tab-bar`, chrome theme and system
  accent (`win32_theme.zig`), focus cues (`win32/focus_cue.zig`),
  `win32_icons.zig`, chrome child z-order, host paint and invalidation scopes
  and text caches (`paintChrome`, `invalidateChrome*`, `repaintTopChrome`,
  `appendOwnedString`), tweens.
- [chrome-overlays.md](docs/agents/log/chrome-overlays.md): the command
  palette (`win32_palette.zig`, ranking, MRU, palette list), the confirm
  overlay (`showConfirm`, `invokeConfirmAccept`/`Cancel` lifetime), the
  profile overlay, host banners and the update notice, overlay EDIT writes
  (`setOverlayEditText`).
- [search-scrollbar.md](docs/agents/log/search-scrollbar.md): the docked
  search bar (`win32_search_bar.zig`, `searchEditProc`, visible Up/Down versus
  core `.next`/`.previous`, debounce) and the layered overlay scrollbar
  (`win32_scrollbar_geometry.zig`, heartbeat, alpha, markers).
- [tabs-panes.md](docs/agents/log/tabs-panes.md): tabs, splits and windows as
  a structure: `Surface.init` ordering, `activateSurface`, showing and hiding
  pane surfaces (occlusion, overlapping WGL children), `windowDestroyed`,
  close and close-confirm flows, focus after a close, shell reducer effects,
  local and structural undo/redo (`win32_undo.zig`,
  `win32_structural_history.zig`, `undo-timeout`; the snapshot formatter is in
  terminal-core.md).
- [input.md](docs/agents/log/input.md): `win32/input.zig` and key messages
  (`WM_KEYDOWN`/`WM_CHAR`/`WM_SYSCHAR`, dead keys, `ToUnicode`, non-Latin
  layouts), default Windows keybindings, Win32 input mode (DEC 9001), IME,
  mouse buttons, wheel and context-menu input.
- [launch-and-paths.md](docs/agents/log/launch-and-paths.md): which process a
  terminal starts and with what environment: the default `command` and
  profile discovery (`src/config/windows_shell.zig`), safe mode's
  `cmd.exe /D`, `CreateProcessW` name resolution, Git Bash discovery, WSL
  (`wsl_env.zig`, terminfo probe, `TERM`), the terminfo install
  (`win32_terminfo.zig`); path safety (`os.path.isNetworkOrDevicePath`,
  `OBJ_DONT_REPARSE`) and link and quick-select path detection and opening.
- [clipboard.md](docs/agents/log/clipboard.md): clipboard reads and writes,
  CF_HTML (`win32_clipboard_html.zig`), open retries, OSC 52 prompts and
  replies, paste protection (`win32_paste_protection.zig`), drag-and-drop
  (`win32_surface_drop*.zig`), pending clipboard confirmations.
- [settings.md](docs/agents/log/settings.md): the Settings window
  (`win32_settings.zig`, `win32_settings_fields.zig`): its controls, dialog
  manager, viewport, live preview, its own UIA patterns, and the save path
  (`settingsSaveAndReload`, `patchOrAppendEdits`, save target, masked values).
- [accessibility.md](docs/agents/log/accessibility.md): UIA providers under
  `src/apprt/win32_uia/` (COM identity and refcounts, BSTR and VARIANT
  ownership, `events.zig`), terminal text (`win32_terminal_accessibility.zig`,
  TextPattern, ScrollIntoView, the echo queue), palette and tab-list UIA. The
  Settings window's controls are in settings.md.
- [config.md](docs/agents/log/config.md): config loading and reload outside
  the Settings window: `--config-file` and `startup_cwd` on reload,
  diagnostics shown in the GUI, conditional replay, `newConfig` shallow
  clones, `+edit-config` and opening the config file, adding config keys.
- [app-lifecycle.md](docs/agents/log/app-lifecycle.md): process-level
  behaviour: `App.init` and startup stalls, startup attempts and safe mode,
  session state and state-file schemas, IPC and single instance
  (`win32/ipc_server.zig`), AUMID and portable identity, the jump list,
  toasts and desktop notifications, the bell, taskbar progress and icon, crash
  minidumps and Sentry, the COM apartment, default-terminal handoff, the CLI
  and the `noctty.com` wrapper.
- [build-release-ci.md](docs/agents/log/build-release-ci.md): `build.zig`
  and resources, packaging (`scripts/package-windows.ps1`,
  `dist/windows/noctty.iss`), signing, the updater, release workflows and
  package managers (WinGet, Scoop, Chocolatey), GitHub Actions CI (path
  filter, caching, runners), line endings.
- [docs.md](docs/agents/log/docs.md): changing what README.md, PRIVACY.md,
  `docs/*.md`, `site/` or install copy claims about behaviour.
- [test-harnesses.md](docs/agents/log/test-harnesses.md): running and reading
  tests (`scripts/dev-windows.cmd`, filters, counts), and writing or running
  `test/windows/` harnesses: hidden desktops, the foreground, sandboxes, the
  interactive composite, the flagship contracts.
- [tooling.md](docs/agents/log/tooling.md): Zig language and Win32 FFI
  declaration traps, PowerShell language traps, `gh`, git and codex tooling.

### Rules from the log that apply everywhere

- Run the Commands above through `scripts/dev-windows.cmd` (or an equivalent
  VS-dev + Zig 0.15.2 shell), with a one-token `-Dtest-filter`; verify through
  `zig build test`, since a direct `zig test <file>` misses the build graph's
  generated modules. (test-harnesses.md: 2026-04-18, 2026-05-01; the count
  rules come from its 2026-10-06 and 2026-09-21 entries.)
- `gh` can resolve upstream `ghostty-org/ghostty` here: pass
  `--repo amanthanvi/noctty` to `gh pr`, `gh repo` and the other commands that
  take it, and push and open PRs against `origin`. (tooling.md: 2026-05-01,
  2026-04-20.)
- Win32 FFI: an API that returns a `HANDLE` and fails with NULL returns
  `?HANDLE` (`std.os.windows.HANDLE` is non-null). Before mirroring an SDK
  struct, check its packing (`pshpack*.h`) and pin its size and offsets in a
  test. (tooling.md: 2026-05-01; app-lifecycle.md: 2026-10-09 minidump;
  accessibility.md: 2026-04-16 VARIANT.)
- Never show noctty on the user's desktop or take the foreground: run it on a
  private desktop and pass `lpDesktop = WinSta0\<desktop>` to every process
  you start (a null one from a driver on a private desktop lands on the
  visible desktop); `SendInput` reaches whatever window is in front.
  (window-frame.md: 2026-09-24, 2026-09-23; renderer.md: 2026-10-14;
  input.md: 2026-09-19.)
- Keep runs off the real profile: launch a portable copy (`noctty.portable`
  beside the exe) with `--window-save-state=never` and a redirected
  `LOCALAPPDATA`; a test that reached the real `%LOCALAPPDATA%\noctty` once
  put the user's launches into safe mode. (window-frame.md: 2026-09-23;
  test-harnesses.md: 2026-09-23.)
- The clipboard belongs to the window station, so a hidden desktop shares the
  user's: nothing that can copy (or falls back to a copy) runs there, nothing
  reads it, and a run logs `GetClipboardSequenceNumber()` before and after;
  use a unit seam or a private window station. (launch-and-paths.md:
  2026-10-15; clipboard.md: 2026-10-15.)
- A null result needs a positive control before it becomes a causal claim.
  (window-frame.md: 2026-09-14 `background-blur`.)
- Later entries correct earlier ones, sometimes in another area file, and a
  function an entry calls load-bearing may have lost its callers since:
  re-verify call sites before relying on one. (chrome-overlays.md:
  2026-08-20, 2026-09-10.)

### How to add a Self-Correction Log entry

Add one bullet, `- YYYY-MM-DD: ...`, at the top of the area file for the code
the change touches (one file per entry; continuation lines indented, no blank
lines inside the list). Record what a later agent could not cheaply
rediscover: the trap (what looked true and was not), the evidence (what was
measured, on what, with what result, and what is only inferred), and the rule
(what to do now, naming the files and symbols). Name an earlier entry it
corrects by date. If no area fits, add a file with the same heading and
pointer line, give it a line in the index above with a precise trigger, and
list it in `.greptile/files.json`.
