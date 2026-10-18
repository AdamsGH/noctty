# Self-Correction Log: Zig, PowerShell and Win32 FFI traps; git, gh and agent tooling

Part of the Self-Correction Log; [AGENTS.md](../../../AGENTS.md) indexes the area files and says how to add an entry. Newest first.

- 2026-05-02: Lowercasing Zig type aliases to satisfy naming review can collide with same-named declarations or locals in Zig's shared declaration namespace; check for helper/local name conflicts before committing mechanical renames.
- 2026-05-01: In this fork, with both `origin` and `upstream` remotes configured, bare `gh pr view <n>` can resolve the upstream Ghostty PR number; use `-R amanthanvi/noctty` for fork-local PR review/checks.
- 2026-05-01: In Zig Win32 FFI, `std.os.windows.HANDLE` is non-null; APIs like `CreateJobObjectW` that signal failure with `NULL` must use `?HANDLE` in extern declarations or future callers cannot model failure correctly.
- 2026-05-01: On Win32 x64, `JOBOBJECT_BASIC_LIMIT_INFORMATION` is 64 bytes, not 56; `SIZE_T`/`Affinity` padding also shifts `JOBOBJECT_EXTENDED_LIMIT_INFORMATION` to 144 bytes with `JobMemoryLimit` at offset 120. Keep ABI tests on real offsets before wiring Job Object FFI.
- 2026-05-01: In this repo's worktrees, plain `gh repo` / `gh pr` commands can resolve to upstream `ghostty-org/ghostty` despite `origin=amanthanvi/noctty`; pin review ops with `--repo amanthanvi/noctty`.
- 2026-05-01: In this fork, plain `gh pr view <n>` can resolve the upstream Ghostty repo instead of `amanthanvi/noctty`; pass `--repo amanthanvi/noctty` or verify the target before trusting PR metadata.
- 2026-05-01: In Zig `union(enum)` tests, `Type.tag` names the tag enum, not a union value; cast to `Type` before calling union methods in assertions.
- 2026-04-30: Cross-thread ChatGPT URLs can stall behind Cloudflare verify-human; use `codex exec resume <thread-id> <prompt>` for coordination, and do not discard a completed streamed answer just because Codex ends with a trailing `thread ... not found` rollout-record error.
- 2026-04-22: Zig sentinel slices exclude the trailing sentinel from `.len`; never pass `len - 1` to Win32 `TextOutW` / `DrawTextW` for `[:0]u16` UI caches. Empty overlay strings then underflow in Safe builds, and non-empty strings lose their final character.
- 2026-04-20: Publish branches and PRs for this fork against `origin` / `amanthanvi/noctty`, never `upstream` / `ghostty-org/ghostty`. Verify the target repo explicitly before `git push` and `gh pr create`.
- 2026-04-18: In PowerShell interpolated strings, wrap a variable in `${...}` before a literal colon (`:`); `"$path: $value"` parses `$path:` as a scoped variable and fails.
- 2026-04-18: In Win32 `WM_COMMAND`, `lParam == 0` is valid for menu/accelerator dispatch. Never `@ptrFromInt(lParam)` unconditionally there; decode to `?HWND` first or command actions like search toggle can panic with "cast causes pointer to be null".
- 2026-04-12: GDI brush handles (HBRUSH) returned from `WM_CTLCOLOR*` handlers must use `@bitCast` not `@intCast` to convert to LRESULT; GDI handles can have the high bit set on x64, causing `@intCast` to panic.
