//! AppUserModelID (AUMID) registration for noctty.
//!
//! AUMID is the Windows identity that drives:
//!   * Taskbar grouping (duplicates collapse under one icon).
//!   * Action Center toast attribution (toasts fired by this process
//!     show up with our display name + icon, not "Application Host").
//!   * Cold-start toast activation (Windows launches the Start Menu
//!     shortcut; the shortcut's AUMID property routes the click back
//!     to us instead of spawning a generic new process).
//!
//! Two-part registration:
//!   1. Per-process: `SetCurrentProcessExplicitAppUserModelID` — must
//!      run BEFORE any window creation. Cheap, no disk I/O.
//!   2. Per-user registry: `HKCU\Software\Classes\AppUserModelId\<aumid>`
//!      with `DisplayName` + `IconUri` + `ShowInSettings=1`. Written
//!      on non-portable launches; portable launches only fill a missing or
//!      broken icon registration. Kept out of the Start Menu-shortcut writer
//!      because some corporate lockdowns block shortcut creation but
//!      allow HKCU writes, and the registry entry alone is enough for
//!      warm-start toast attribution to look correct.
//!
//!      `IconUri` must name an image file (`.ico` / `.png`). The
//!      notification platform does not extract the icon resource from
//!      an exe path: the toast header renders without an icon, and the
//!      "no icon" resolution is then cached per AUMID, so a later
//!      registry fix is not picked up by the running session (a reboot
//!      cleared it in testing; sign-out alone was not measured). We
//!      point it at the `noctty.ico` that the installer, the portable
//!      ZIP and `zig build` all stage next to the exe. When that file is
//!      missing the value is left as it was: the key is per user, not
//!      per install, so a bare copy of the exe writing its own path
//!      would strip the icon from every other noctty on the machine.
//!
//! The AUMID string `io.github.amanthanvi.noctty` lives in a namespace
//! we own (matching the instance/bundle id) rather than any
//! Ghostty-owned reverse-DNS prefix, so it cannot collide with — or
//! imply affiliation with — an upstream Ghostty install.
//!
//! Start Menu shortcut creation is intentionally NOT here — it's
//! installer-side work that belongs in `scripts/package-windows.ps1`,
//! not in our runtime init path. A packaged build writes the shortcut
//! once with the correct AUMID property via Inno Setup; dev builds
//! run without a shortcut and fall back to explicit-AUMID-only toast
//! attribution (still works for warm-start, fails for cold-start).

const std = @import("std");
const windows = std.os.windows;
const win32_types = @import("win32_types.zig");
const sys = @import("win32/sys.zig");

const HRESULT = windows.HRESULT;
const LPCWSTR = win32_types.LPCWSTR;
const HKEY = sys.HKEY;
const REGSAM = u32;
const DWORD = win32_types.DWORD;

const HKEY_CURRENT_USER: HKEY = @ptrFromInt(0x80000001);
const KEY_WRITE: REGSAM = 0x20006;
const KEY_QUERY_VALUE: REGSAM = 0x0001;
const REG_OPTION_NON_VOLATILE: DWORD = 0;
const REG_SZ: DWORD = 1;
const REG_DWORD: DWORD = 4;
const ERROR_SUCCESS: i32 = 0;

const aumid_wide: [*:0]const u16 = std.unicode.utf8ToUtf16LeStringLiteral("io.github.amanthanvi.noctty");
pub const aumid_utf8 = "io.github.amanthanvi.noctty";

/// Set the AUMID for the current process. Must run before any HWND is
/// created; Windows copies the identity into the process's taskbar-
/// integration state at first window-creation time. Return value is
/// advisory — we log and proceed on failure rather than abort, since
/// toasts are not essential for the app to function.
pub fn setProcessAumid() void {
    const hr = sys.SetCurrentProcessExplicitAppUserModelID(aumid_wide);
    if (hr < 0) {
        std.log.warn("AUMID: SetCurrentProcessExplicitAppUserModelID failed hr=0x{x:0>8}", .{@as(u32, @bitCast(hr))});
    }
}

/// Write `HKCU\Software\Classes\AppUserModelId\io.github.amanthanvi.noctty`
/// with DisplayName + IconUri + ShowInSettings. Portable launches only
/// fill a missing or broken registration, keeping the shared toast identity.
pub fn registerAumidDisplayName(alloc: std.mem.Allocator) void {
    const portable_root = @import("../os/main.zig").xdg.portableRoot(alloc) catch return;
    defer if (portable_root) |root| alloc.free(root);
    const exe_path = std.fs.selfExePathAlloc(alloc) catch return;
    defer alloc.free(exe_path);
    const subkey = std.unicode.utf8ToUtf16LeStringLiteral(
        "Software\\Classes\\AppUserModelId\\io.github.amanthanvi.noctty",
    );
    registerForExe(alloc, subkey, exe_path, portable_root != null);
}

fn registerForExe(alloc: std.mem.Allocator, subkey: LPCWSTR, exe_path: []const u8, portable: bool) void {
    // Both launch modes serialize the portable check and all writes. Global
    // scope covers simultaneous sessions of the same HKCU user; the SID keeps
    // unrelated users apart. Failure/timeout leaves the registration untouched.
    const lock = RegistrationLock.acquire(alloc, subkey) catch return;
    defer lock.release();
    var hkey: HKEY = undefined;
    const open_rc = sys.RegCreateKeyExW(
        HKEY_CURRENT_USER,
        subkey,
        0,
        null,
        REG_OPTION_NON_VOLATILE,
        KEY_WRITE | (if (portable) KEY_QUERY_VALUE else @as(REGSAM, 0)),
        null,
        &hkey,
        null,
    );
    if (open_rc != ERROR_SUCCESS) {
        std.log.warn("AUMID: RegCreateKeyExW failed rc={d}", .{open_rc});
        return;
    }
    defer _ = sys.RegCloseKey(hkey);

    if (portable) {
        const existing = readIconUri(alloc, hkey) catch return;
        defer if (existing) |path| alloc.free(path);
        if (preserveRegistration(portable, existing)) return;
    }

    const display_name = std.unicode.utf8ToUtf16LeStringLiteral("noctty");
    const set_rc = writeRegSz(hkey, std.unicode.utf8ToUtf16LeStringLiteral("DisplayName"), display_name);
    if (set_rc != ERROR_SUCCESS) {
        std.log.warn("AUMID: write DisplayName failed rc={d}", .{set_rc});
    }

    {
        const icon_path = iconUriPath(alloc, exe_path) catch |err| blk: {
            std.log.warn("AUMID: sibling icon path unavailable err={}; leaving IconUri unchanged", .{err});
            break :blk null;
        };
        defer if (icon_path) |path| alloc.free(path);

        // No sibling icon (a cached dev artifact, or a bare exe copied
        // somewhere on its own): keep whatever `IconUri` already holds.
        // Writing this exe's path instead would register a value the
        // notification platform cannot render, and because the key is
        // shared by every noctty the user runs, it would take the icon
        // away from the installed build too.
        if (icon_path) |icon_source| {
            if (std.unicode.utf8ToUtf16LeAllocZ(alloc, icon_source)) |icon_uri| {
                defer alloc.free(icon_uri);

                const icon_rc = writeRegSz(hkey, std.unicode.utf8ToUtf16LeStringLiteral("IconUri"), icon_uri);
                if (icon_rc != ERROR_SUCCESS) {
                    std.log.warn("AUMID: write IconUri failed rc={d}", .{icon_rc});
                }
            } else |err| {
                std.log.warn("AUMID: IconUri utf16 conversion failed err={}", .{err});
            }
        }
    }

    var show_in_settings: u32 = 1;
    const show_rc = sys.RegSetValueExW(
        hkey,
        std.unicode.utf8ToUtf16LeStringLiteral("ShowInSettings"),
        0,
        REG_DWORD,
        @ptrCast(&show_in_settings),
        @sizeOf(u32),
    );
    if (show_rc != ERROR_SUCCESS) {
        std.log.warn("AUMID: write ShowInSettings failed rc={d}", .{show_rc});
    }
}

const RegistrationLock = struct {
    handle: windows.HANDLE,

    extern "kernel32" fn CreateMutexExW(?*const windows.SECURITY_ATTRIBUTES, LPCWSTR, DWORD, DWORD) callconv(.winapi) ?windows.HANDLE;
    extern "kernel32" fn ReleaseMutex(windows.HANDLE) callconv(.winapi) windows.BOOL;

    fn acquire(alloc: std.mem.Allocator, subkey: LPCWSTR) !RegistrationLock {
        const sid = try @import("win32_elevation.zig").allocCurrentUserSidString(alloc);
        defer alloc.free(sid);
        const name = try std.fmt.allocPrint(alloc, "Global\\noctty-aumid-{s}-{x}", .{
            sid, std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(std.mem.span(subkey))),
        });
        defer alloc.free(name);
        const wide = try std.unicode.utf8ToUtf16LeAllocZ(alloc, name);
        defer alloc.free(wide);
        // An elevated creator's default label would prevent a normal launcher
        // from opening the same lock. This mutex protects only HKCU metadata:
        // grant the same user wait/release rights and explicitly label it medium.
        const sddl = try std.fmt.allocPrint(alloc, "O:{s}D:P(A;;0x00100001;;;{s})S:(ML;;NW;;;ME)", .{ sid, sid });
        defer alloc.free(sddl);
        const sddl_wide = try std.unicode.utf8ToUtf16LeAllocZ(alloc, sddl);
        defer alloc.free(sddl_wide);
        var descriptor: ?*anyopaque = null;
        if (sys.ConvertStringSecurityDescriptorToSecurityDescriptorW(sddl_wide, 1, &descriptor, null) == 0) return error.LockUnavailable;
        defer _ = sys.LocalFree(descriptor);
        var attributes: windows.SECURITY_ATTRIBUTES = .{
            .nLength = @sizeOf(windows.SECURITY_ATTRIBUTES),
            .lpSecurityDescriptor = descriptor orelse return error.LockUnavailable,
            .bInheritHandle = 0,
        };
        const handle = CreateMutexExW(&attributes, wide, 0, 0x00100001) orelse return error.LockUnavailable;
        errdefer windows.CloseHandle(handle);
        const result = windows.kernel32.WaitForSingleObject(handle, 250);
        // An abandoned mutex grants ownership too; re-read registry state.
        if (result != 0 and result != 0x80) return error.LockUnavailable;
        return .{ .handle = handle };
    }

    fn release(self: RegistrationLock) void {
        _ = ReleaseMutex(self.handle);
        windows.CloseHandle(self.handle);
    }
};

/// Unknown/unreachable registrations are preserved too: never contact a
/// network server from startup just to replace its icon with a portable one.
fn preserveRegistration(portable: bool, icon: ?[]const u8) bool {
    if (!portable) return false;
    const path = icon orelse return false;
    if (@import("../os/main.zig").path.isNetworkOrDevicePath(path)) return true;
    if (!std.fs.path.isAbsolute(path)) return false;
    if (path.len >= 2 and path[1] == ':' and
        @import("../os/main.zig").windows.driveTypeForLetter(path[0]) == @import("../os/main.zig").windows.DRIVE_REMOTE) return true;
    const stat = std.fs.cwd().statFile(path) catch |err| return err != error.FileNotFound and err != error.NotDir;
    return stat.kind == .file;
}

fn readIconUri(alloc: std.mem.Allocator, hkey: HKEY) !?[]u8 {
    const name = std.unicode.utf8ToUtf16LeStringLiteral("IconUri");
    var kind: DWORD = 0;
    var bytes: DWORD = 0;
    const size_rc = sys.RegQueryValueExW(hkey, name, null, &kind, null, &bytes);
    if (size_rc == 2) return null; // ERROR_FILE_NOT_FOUND
    if (size_rc != ERROR_SUCCESS) return error.RegistryReadFailed;
    if (kind != REG_SZ or bytes < 2 or bytes % 2 != 0 or bytes > 65536) return null;
    const wide = try alloc.alloc(u16, bytes / 2);
    defer alloc.free(wide);
    if (sys.RegQueryValueExW(hkey, name, null, &kind, @ptrCast(wide.ptr), &bytes) != ERROR_SUCCESS) return error.RegistryReadFailed;
    if (kind != REG_SZ or bytes < 2 or bytes % 2 != 0 or bytes / 2 > wide.len) return null;
    const value = wide[0 .. bytes / 2];
    if (value[value.len - 1] != 0) return null;
    if (std.mem.indexOfScalar(u16, value[0 .. value.len - 1], 0) != null) return null;
    return std.unicode.utf16LeToUtf8Alloc(alloc, value[0 .. value.len - 1]) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return null,
    };
}

fn writeRegSz(hkey: HKEY, value_name: LPCWSTR, value: [:0]const u16) i32 {
    return sys.RegSetValueExW(
        hkey,
        value_name,
        0,
        REG_SZ,
        @ptrCast(value.ptr),
        @intCast((value.len + 1) * @sizeOf(u16)),
    );
}

/// The icon file staged next to `noctty.exe` by `scripts/package-windows.ps1`
/// (installer + portable ZIP) and by the `zig build` install step.
pub const icon_file_name = "noctty.ico";

/// `<dir of exe_path>\noctty.ico`. Caller owns the returned slice.
fn siblingIconPath(alloc: std.mem.Allocator, exe_path: []const u8) ![]u8 {
    const dir = std.fs.path.dirname(exe_path) orelse ".";
    return try std.fs.path.join(alloc, &.{ dir, icon_file_name });
}

/// Resolve the value to write into `IconUri`: the sibling `noctty.ico`
/// when it exists on disk, otherwise `null` so the caller leaves the
/// registry value alone (a dev tree that never ran the install step, or
/// a bare copy of the exe). Caller owns a non-null result.
fn iconUriPath(alloc: std.mem.Allocator, exe_path: []const u8) !?[]u8 {
    const icon_path = try siblingIconPath(alloc, exe_path);
    errdefer alloc.free(icon_path);
    // A stat, not an access check: `IconUri` has to name an image file,
    // and a directory that happens to be called `noctty.ico` passes
    // `accessAbsolute` just the same.
    const stat = std.fs.cwd().statFile(icon_path) catch |err| {
        std.log.info("AUMID: {s} not found next to exe ({}); leaving IconUri unchanged", .{ icon_file_name, err });
        alloc.free(icon_path);
        return null;
    };
    if (stat.kind != .file) {
        std.log.info("AUMID: {s} next to exe is not a regular file ({s}); leaving IconUri unchanged", .{ icon_file_name, @tagName(stat.kind) });
        alloc.free(icon_path);
        return null;
    }
    return icon_path;
}

test "aumid sibling icon path sits next to the exe" {
    const testing = std.testing;
    const sep = std.fs.path.sep_str;

    const exe_path = try std.mem.join(testing.allocator, sep, &.{ "C:", "Program Files", "noctty", "noctty.exe" });
    defer testing.allocator.free(exe_path);
    const expected = try std.mem.join(testing.allocator, sep, &.{ "C:", "Program Files", "noctty", "noctty.ico" });
    defer testing.allocator.free(expected);

    const actual = try siblingIconPath(testing.allocator, exe_path);
    defer testing.allocator.free(actual);
    try testing.expectEqualStrings(expected, actual);
}

test "aumid icon uri is absent when the sibling icon is missing" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(dir);
    const exe_path = try std.fs.path.join(testing.allocator, &.{ dir, "noctty.exe" });
    defer testing.allocator.free(exe_path);

    // No noctty.ico yet: the caller must leave IconUri as it is.
    try testing.expectEqual(@as(?[]u8, null), try iconUriPath(testing.allocator, exe_path));

    // A directory of that name is not an icon either.
    try tmp.dir.makeDir(icon_file_name);
    try testing.expectEqual(@as(?[]u8, null), try iconUriPath(testing.allocator, exe_path));
    try tmp.dir.deleteDir(icon_file_name);

    // Once the icon is staged next to the exe it is preferred.
    try tmp.dir.writeFile(.{ .sub_path = icon_file_name, .data = "ico" });
    const resolved = (try iconUriPath(testing.allocator, exe_path)) orelse return error.TestUnexpectedResult;
    defer testing.allocator.free(resolved);
    try testing.expect(std.mem.endsWith(u8, resolved, icon_file_name));
    try testing.expectEqualStrings(dir, std.fs.path.dirname(resolved).?);
}

test "aumid string shape" {
    const testing = std.testing;
    try testing.expectEqualStrings("io.github.amanthanvi.noctty", aumid_utf8);
}

test "aumid portable registration preserves a working icon and repairs a broken one" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makeDir("installed");
    try tmp.dir.makeDir("portable");
    try tmp.dir.writeFile(.{ .sub_path = "installed/noctty.ico", .data = "installed icon" });
    try tmp.dir.writeFile(.{ .sub_path = "portable/noctty.ico", .data = "portable icon" });
    const root = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(root);
    const installed = try std.fs.path.join(alloc, &.{ root, "installed", "noctty.ico" });
    defer alloc.free(installed);
    const portable_exe = try std.fs.path.join(alloc, &.{ root, "portable", "noctty.exe" });
    defer alloc.free(portable_exe);
    const portable_icon = try siblingIconPath(alloc, portable_exe);
    defer alloc.free(portable_icon);
    try std.testing.expect(preserveRegistration(true, installed));
    try std.testing.expect(!preserveRegistration(false, installed));
    try std.testing.expect(!preserveRegistration(true, null));
    try std.testing.expect(preserveRegistration(true, "\\\\server\\share\\noctty.ico"));

    // Exercise the actual registry writer, only under a unique scratch key.
    var random: [16]u8 = undefined;
    std.crypto.random.bytes(&random);
    const subkey_utf8 = try std.fmt.allocPrint(alloc, "Software\\noctty-aumid-test-{x}", .{random});
    defer alloc.free(subkey_utf8);
    const subkey = try std.unicode.utf8ToUtf16LeAllocZ(alloc, subkey_utf8);
    defer alloc.free(subkey);
    const Cleanup = struct {
        extern "advapi32" fn RegDeleteKeyW(key: HKEY, name: LPCWSTR) callconv(.winapi) i32;
    };
    defer _ = Cleanup.RegDeleteKeyW(HKEY_CURRENT_USER, subkey);
    var key: HKEY = undefined;
    try std.testing.expectEqual(ERROR_SUCCESS, sys.RegCreateKeyExW(HKEY_CURRENT_USER, subkey, 0, null, 0, KEY_WRITE | KEY_QUERY_VALUE, null, &key, null));
    defer _ = sys.RegCloseKey(key);
    registerForExe(alloc, subkey, portable_exe, true);
    const initial = (try readIconUri(alloc, key)) orelse return error.TestUnexpectedResult;
    defer alloc.free(initial);
    try std.testing.expectEqualStrings(portable_icon, initial);
    const installed_wide = try std.unicode.utf8ToUtf16LeAllocZ(alloc, installed);
    defer alloc.free(installed_wide);
    const icon_name = std.unicode.utf8ToUtf16LeStringLiteral("IconUri");
    try std.testing.expectEqual(ERROR_SUCCESS, writeRegSz(key, icon_name, installed_wide));
    const display_name = std.unicode.utf8ToUtf16LeStringLiteral("DisplayName");
    try std.testing.expectEqual(ERROR_SUCCESS, writeRegSz(key, display_name, std.unicode.utf8ToUtf16LeStringLiteral("custom")));
    // A second launcher cannot write while another registration transaction
    // owns the mutex. Use a separate thread (mutexes are recursive per thread)
    // and a separately opened handle, as a second process would use.
    {
        const held = try RegistrationLock.acquire(alloc, subkey);
        defer held.release();
        const Writer = struct {
            fn run(a: std.mem.Allocator, k: LPCWSTR, exe: []const u8) void {
                registerForExe(a, k, exe, false);
            }
        };
        const writer = try std.Thread.spawn(.{}, Writer.run, .{ alloc, subkey.ptr, portable_exe });
        writer.join();
        const unchanged = (try readIconUri(alloc, key)) orelse return error.TestUnexpectedResult;
        defer alloc.free(unchanged);
        try std.testing.expectEqualStrings(installed, unchanged);
    }
    registerForExe(alloc, subkey, portable_exe, true);
    const preserved = (try readIconUri(alloc, key)) orelse return error.TestUnexpectedResult;
    defer alloc.free(preserved);
    try std.testing.expectEqualStrings(installed, preserved);
    var display: [16]u16 = undefined;
    var display_bytes: DWORD = @sizeOf(@TypeOf(display));
    try std.testing.expectEqual(ERROR_SUCCESS, sys.RegQueryValueExW(key, display_name, null, null, @ptrCast(&display), &display_bytes));
    try std.testing.expectEqualSlices(u16, std.unicode.utf8ToUtf16LeStringLiteral("custom"), display[0 .. display_bytes / 2 - 1]);

    try tmp.dir.deleteFile("installed/noctty.ico");
    try std.testing.expect(!preserveRegistration(true, installed));
    registerForExe(alloc, subkey, portable_exe, true);
    const repaired = (try readIconUri(alloc, key)) orelse return error.TestUnexpectedResult;
    defer alloc.free(repaired);
    try std.testing.expectEqualStrings(portable_icon, repaired);

    // A missing registration still acquires the shared identity for toasts.
    try std.testing.expectEqual(ERROR_SUCCESS, writeRegSz(key, icon_name, &.{}));
    registerForExe(alloc, subkey, portable_exe, true);
    const filled = (try readIconUri(alloc, key)) orelse return error.TestUnexpectedResult;
    defer alloc.free(filled);
    try std.testing.expectEqualStrings(portable_icon, filled);

    // A wrong type and malformed REG_SZ bytes are known broken values,
    // unlike a read denied by registry policy, which must stay untouched.
    const malformed = [_][]const u8{ &.{}, &.{1}, &.{ 0x00, 0xd8, 0, 0 }, &.{ 65, 0 } };
    for (malformed) |bytes| {
        try std.testing.expectEqual(ERROR_SUCCESS, sys.RegSetValueExW(key, icon_name, 0, REG_SZ, bytes.ptr, @intCast(bytes.len)));
        registerForExe(alloc, subkey, portable_exe, true);
        const restored = (try readIconUri(alloc, key)) orelse return error.TestUnexpectedResult;
        defer alloc.free(restored);
        try std.testing.expectEqualStrings(portable_icon, restored);
    }
    var wrong_type: DWORD = 7;
    try std.testing.expectEqual(ERROR_SUCCESS, sys.RegSetValueExW(key, icon_name, 0, REG_DWORD, @ptrCast(&wrong_type), @sizeOf(DWORD)));
    registerForExe(alloc, subkey, portable_exe, true);
    const restored = (try readIconUri(alloc, key)) orelse return error.TestUnexpectedResult;
    defer alloc.free(restored);
    try std.testing.expectEqualStrings(portable_icon, restored);
}
