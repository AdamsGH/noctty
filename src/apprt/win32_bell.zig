//! What the terminal bell does on Windows: the plan that turns `bell-features`
//! and the state of the alerted window into actions, and the three actions
//! that need Win32 (the taskbar flash, the custom sound and the title glyph).
//!
//! `bell-features` defaults to `attention` and `title` and not `system`, so a
//! BEL flashes the taskbar button of a window that is not in front and puts a
//! bell glyph on the alerted terminal's tab and the window caption, and plays
//! nothing. Before PKG-60 every BEL played `MessageBeep` and no key of the
//! `bell-*` family was read.
//!
//! - `system`: `MessageBeep`, the sound set in Windows' Sound settings.
//! - `audio`: `bell-audio-path` through MCI on a short-lived thread, at
//!   `bell-audio-volume`; see `playFile`.
//! - `attention`: `FlashWindowEx` on the host window until it is in front.
//! - `title`: "🔔 " in front of the tab label and the window caption until
//!   the terminal is focused or typed into. The stored title is never
//!   changed, so `title-report`, sessions and automation still see the real
//!   one.
//! - `border` is not implemented on Windows.

const std = @import("std");
const Allocator = std.mem.Allocator;
const windows = std.os.windows;
const configpkg = @import("../config.zig");
const internal_os = @import("../os/main.zig");

const log = std.log.scoped(.win32_bell);

/// What a bell does for one alerted terminal.
pub const Plan = struct {
    /// Play the Windows system sound.
    system: bool = false,
    /// Play `bell-audio-path`.
    audio: bool = false,
    /// Flash the window's taskbar button until it is brought to the front.
    flash: bool = false,
    /// Mark the terminal's tab and the window caption with the bell glyph.
    glyph: bool = false,
    /// Tell a screen reader "Bell" (a UI Automation notification). The sound
    /// that earlier releases played on every bell was the only cue for a
    /// listener, and the default is silent now; a notification is no sound, so
    /// it goes out whenever the user has not turned every bell feature off,
    /// for a terminal in view or not.
    announce: bool = false,
};

/// What the bell's target looks like at the moment it rings.
pub const Context = struct {
    /// The window is the foreground window and is not minimized.
    window_active: bool,
    /// The window is on screen (a hidden quick terminal is not), so the
    /// system can show a flash for it.
    window_visible: bool,
    /// The terminal is the one the user is typing into: the focused pane of
    /// the active tab of the foreground window.
    in_view: bool,
};

/// The actions for a bell. `has_audio_file` is whether `bell-audio-path` is
/// set to something playable. Pure, so each flag combination is tested.
pub fn plan(features: configpkg.Config.BellFeatures, has_audio_file: bool, ctx: Context) Plan {
    return .{
        .system = features.system,
        .audio = features.audio and has_audio_file,
        // `attention` is documented as "when unfocused". A window that is
        // in front has nothing to flash for.
        .flash = features.attention and ctx.window_visible and !ctx.window_active,
        // A terminal the user is typing into has been "re-focused or
        // interacted with" already: the glyph would only appear and clear
        // again on the next key, rewriting the caption and the tab for every
        // failed tab completion.
        .glyph = features.title and !ctx.in_view,
        .announce = features.system or features.audio or features.attention or features.title,
    };
}

/// The glyph in front of an alerted title, with the space that separates it.
pub const title_glyph = "\u{1F514} ";

/// What a screen reader is told about an alerted tab (UIA `ItemStatus`): the
/// glyph is a picture, and the silent default bell is otherwise heard by no
/// one who does not see the tab strip.
pub const uia_item_status = "Bell";

/// `title` with the glyph in front. Caller frees.
pub fn withTitleGlyph(alloc: Allocator, title: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, title_glyph ++ "{s}", .{title});
}

/// MCI volume for `bell-audio-volume`: 0 to 1000. A volume the config could
/// not hold sensibly (NaN) is the documented default, 0.5.
pub fn mciVolume(volume: f64) u32 {
    const v = if (std.math.isNan(volume)) 0.5 else std.math.clamp(volume, 0.0, 1.0);
    return @intFromFloat(@round(v * 1000.0));
}

/// Whether `path` is a file name MCI may be handed: no quote (a file name
/// cannot hold one, and one would end the quoted argument early) and no
/// control character. A network or device shape is refused as everywhere a
/// path reaches an open (AGENTS.md 2026-10-06): the open would otherwise
/// contact the server or the device. `onRemoteDrive` covers a mapped drive.
pub fn playablePath(path: []const u8) bool {
    if (path.len == 0) return false;
    for (path) |ch| if (ch < 0x20 or ch == '"') return false;
    return !internal_os.path.isNetworkOrDevicePath(path);
}

/// A path on a drive letter that maps a network share. `GetDriveTypeW` reads
/// the local drive table and does not contact the server, so asking costs
/// nothing even for a disconnected share. A path through a link to a share is
/// not detected.
fn onRemoteDrive(path: []const u8) bool {
    if (path.len < 2 or path[1] != ':' or !std.ascii.isAlphabetic(path[0])) return false;
    const root = [_:0]u16{ path[0], ':', '\\' };
    return GetDriveTypeW(&root) == DRIVE_REMOTE;
}

const alias = "noctty_bell";

/// `open "<path>" [type mpegvideo] alias noctty_bell`, UTF-16, for
/// `mciSendStringW`. Only the `mpegvideo` device (Windows Media, which plays
/// WAV, MP3, WMA and more) takes `setaudio ... volume`: the `waveaudio` device
/// MCI picks for a .wav answers it with "driver cannot recognize the command".
fn openCommand(alloc: Allocator, path: []const u8, with_volume: bool) ![:0]u16 {
    const utf8 = try std.fmt.allocPrint(
        alloc,
        "open \"{s}\"{s} alias " ++ alias,
        .{ path, if (with_volume) " type mpegvideo" else "" },
    );
    defer alloc.free(utf8);
    return std.unicode.utf8ToUtf16LeAllocZ(alloc, utf8);
}

fn command(alloc: Allocator, comptime fmt: []const u8, args: anytype) ![:0]u16 {
    const utf8 = try std.fmt.allocPrint(alloc, fmt, args);
    defer alloc.free(utf8);
    return std.unicode.utf8ToUtf16LeAllocZ(alloc, utf8);
}

// ---- Win32 -----------------------------------------------------------------

const FLASHW_TRAY: u32 = 0x00000002;
const FLASHW_TIMERNOFG: u32 = 0x0000000C;

const FLASHWINFO = extern struct {
    cbSize: u32,
    hwnd: windows.HWND,
    dwFlags: u32,
    uCount: u32,
    dwTimeout: u32,
};

const DRIVE_REMOTE: u32 = 4;

extern "user32" fn FlashWindowEx(pfwi: *FLASHWINFO) callconv(.winapi) windows.BOOL;
extern "kernel32" fn GetDriveTypeW(lpRootPathName: [*:0]const u16) callconv(.winapi) u32;
extern "winmm" fn mciSendStringW(
    lpstrCommand: [*:0]const u16,
    lpstrReturnString: ?[*]u16,
    uReturnLength: u32,
    hwndCallback: ?windows.HWND,
) callconv(.winapi) u32;
extern "winmm" fn mciGetErrorStringW(
    fdwError: u32,
    pszText: [*]u16,
    cchText: u32,
) callconv(.winapi) windows.BOOL;

/// Flash `hwnd`'s taskbar button until the window comes to the front. The
/// caption is left alone (`FLASHW_TRAY` only), as the title glyph already
/// marks it.
pub fn flashTaskbar(hwnd: windows.HWND) void {
    var info: FLASHWINFO = .{
        .cbSize = @sizeOf(FLASHWINFO),
        .hwnd = hwnd,
        .dwFlags = FLASHW_TRAY | FLASHW_TIMERNOFG,
        .uCount = std.math.maxInt(u32),
        .dwTimeout = 0,
    };
    _ = FlashWindowEx(&info);
    log.debug("bell: flashed taskbar button hwnd={*}", .{hwnd});
}

/// One bell sound plays at a time; a bell that rings meanwhile is dropped,
/// as overlapping copies of the same sound are noise rather than information.
var busy: std.atomic.Value(bool) = .init(false);
var warned: std.atomic.Value(bool) = .init(false);

const Job = struct {
    path: []u8,
    volume: u32,
};

/// Play `path` at `volume` (0.0 to 1.0, relative to the system volume) and
/// return at once. MCI plays whatever Windows Media can (WAV, MP3, WMA,
/// MIDI) and, unlike `PlaySound`, takes a volume. The open, play and close
/// run on their own thread because `play ... wait` blocks until the sound
/// ends, and the UI thread must not.
pub fn playFile(path: []const u8, volume: f64) void {
    if (!playablePath(path) or onRemoteDrive(path)) {
        warnOnce("bell-audio-path is not a local file name; no sound played", .{});
        return;
    }
    if (busy.cmpxchgStrong(false, true, .acq_rel, .acquire) != null) return;
    const alloc = std.heap.page_allocator;
    const job = alloc.create(Job) catch {
        busy.store(false, .release);
        return;
    };
    job.* = .{ .path = alloc.dupe(u8, path) catch {
        alloc.destroy(job);
        busy.store(false, .release);
        return;
    }, .volume = mciVolume(volume) };
    const thread = std.Thread.spawn(.{}, playThread, .{job}) catch |err| {
        log.warn("bell: sound thread failed to start err={}", .{err});
        alloc.free(job.path);
        alloc.destroy(job);
        busy.store(false, .release);
        return;
    };
    thread.detach();
}

fn playThread(job: *Job) void {
    const alloc = std.heap.page_allocator;
    defer {
        alloc.free(job.path);
        alloc.destroy(job);
        busy.store(false, .release);
    }
    playBlocking(alloc, job.path, job.volume) catch |err| {
        warnOnce("bell sound failed err={}", .{err});
    };
}

fn playBlocking(alloc: Allocator, path: []const u8, volume: u32) !void {
    // The volume-capable device first. Where Windows Media is not installed
    // (an N edition) it is not there, and the file still plays on whatever
    // device MCI picks for it, at the system volume.
    const typed = try openCommand(alloc, path, true);
    defer alloc.free(typed);
    const with_volume = mciSendStringW(typed.ptr, null, 0, null) == 0;
    if (!with_volume) {
        const untyped = try openCommand(alloc, path, false);
        defer alloc.free(untyped);
        try check(mciSendStringW(untyped.ptr, null, 0, null));
    }
    defer send(alloc, "close " ++ alias, .{});

    if (with_volume) send(alloc, "setaudio " ++ alias ++ " volume to {d}", .{volume});
    const play = try command(alloc, "play " ++ alias ++ " wait", .{});
    defer alloc.free(play);
    try check(mciSendStringW(play.ptr, null, 0, null));
}

fn send(alloc: Allocator, comptime fmt: []const u8, args: anytype) void {
    const cmd = command(alloc, fmt, args) catch return;
    defer alloc.free(cmd);
    const code = mciSendStringW(cmd.ptr, null, 0, null);
    if (code != 0) log.debug("bell: mci command failed code={d}", .{code});
}

fn check(code: u32) !void {
    if (code == 0) return;
    var text: [128]u16 = undefined;
    if (mciGetErrorStringW(code, &text, text.len) != 0) {
        var out: [256]u8 = undefined;
        const len = std.mem.indexOfScalar(u16, &text, 0) orelse text.len;
        const n = std.unicode.utf16LeToUtf8(&out, text[0..len]) catch 0;
        log.debug("bell: mci error {d}: {s}", .{ code, out[0..n] });
    }
    return error.MciFailed;
}

fn warnOnce(comptime fmt: []const u8, args: anytype) void {
    if (warned.cmpxchgStrong(false, true, .acq_rel, .acquire) != null) return;
    log.warn(fmt, args);
}

// ---- Tests -----------------------------------------------------------------

const testing = std.testing;
const Features = configpkg.Config.BellFeatures;

const away: Context = .{ .window_active = false, .window_visible = true, .in_view = false };
const watching: Context = .{ .window_active = true, .window_visible = true, .in_view = true };
const other_tab: Context = .{ .window_active = true, .window_visible = true, .in_view = false };

test "win32 bell defaults: no sound, flash and glyph when away" {
    const p = plan(.{}, false, away);
    try testing.expect(!p.system);
    try testing.expect(!p.audio);
    try testing.expect(p.flash);
    try testing.expect(p.glyph);
}

test "win32 bell defaults: a terminal being watched does nothing" {
    // Only the screen reader hears of a bell in the terminal being typed into.
    try testing.expectEqual(Plan{ .announce = true }, plan(.{}, false, watching));
}

test "win32 bell defaults: another tab of the foreground window gets only the glyph" {
    const p = plan(.{}, false, other_tab);
    try testing.expect(!p.flash);
    try testing.expect(p.glyph);
}

test "win32 bell system plays whatever the window state" {
    for ([_]Context{ away, watching, other_tab }) |ctx| {
        try testing.expect(plan(.{ .system = true }, false, ctx).system);
        try testing.expect(!plan(.{ .system = false }, false, ctx).system);
    }
}

test "win32 bell audio needs the feature and a file" {
    try testing.expect(plan(.{ .audio = true }, true, watching).audio);
    try testing.expect(!plan(.{ .audio = true }, false, watching).audio);
    try testing.expect(!plan(.{ .audio = false }, true, watching).audio);
}

test "win32 bell attention flashes only a visible window that is not in front" {
    const on: Features = .{ .attention = true };
    const off: Features = .{ .attention = false };
    try testing.expect(plan(on, false, away).flash);
    try testing.expect(!plan(off, false, away).flash);
    try testing.expect(!plan(on, false, other_tab).flash);
    try testing.expect(!plan(on, false, .{ .window_active = false, .window_visible = false, .in_view = false }).flash);
}

test "win32 bell title marks every terminal that is not in view" {
    const on: Features = .{ .title = true };
    const off: Features = .{ .title = false };
    try testing.expect(plan(on, false, away).glyph);
    try testing.expect(plan(on, false, other_tab).glyph);
    try testing.expect(!plan(on, false, watching).glyph);
    try testing.expect(!plan(off, false, away).glyph);
}

test "win32 bell plan covers every feature combination" {
    // 5 flags x 3 situations, checked against the rules written out.
    var bits: u32 = 0;
    while (bits < 32) : (bits += 1) {
        const features: Features = .{
            .system = bits & 1 != 0,
            .audio = bits & 2 != 0,
            .attention = bits & 4 != 0,
            .title = bits & 8 != 0,
            .border = bits & 16 != 0,
        };
        for ([_]Context{ away, watching, other_tab }) |ctx| {
            const p = plan(features, true, ctx);
            try testing.expectEqual(features.system, p.system);
            try testing.expectEqual(features.audio, p.audio);
            try testing.expectEqual(features.attention and !ctx.window_active, p.flash);
            try testing.expectEqual(features.title and !ctx.in_view, p.glyph);
        }
    }
}

test "win32 bell title glyph goes in front and leaves the title alone" {
    const alerted = try withTitleGlyph(testing.allocator, "pwsh");
    defer testing.allocator.free(alerted);
    try testing.expectEqualStrings("\u{1F514} pwsh", alerted);
    const empty = try withTitleGlyph(testing.allocator, "");
    defer testing.allocator.free(empty);
    try testing.expectEqualStrings("\u{1F514} ", empty);
}

test "win32 bell volume maps 0.0..1.0 onto MCI's 0..1000" {
    try testing.expectEqual(@as(u32, 0), mciVolume(0.0));
    try testing.expectEqual(@as(u32, 500), mciVolume(0.5));
    try testing.expectEqual(@as(u32, 1000), mciVolume(1.0));
    try testing.expectEqual(@as(u32, 0), mciVolume(-3.0));
    try testing.expectEqual(@as(u32, 1000), mciVolume(7.0));
    try testing.expectEqual(@as(u32, 500), mciVolume(std.math.nan(f64)));
    try testing.expectEqual(@as(u32, 1000), mciVolume(std.math.inf(f64)));
}

test "win32 bell sound path: local files only" {
    try testing.expect(playablePath("C:\\Windows\\Media\\Ding.wav"));
    try testing.expect(playablePath("C:\\My Sounds\\bell \u{00e9}.mp3"));
    try testing.expect(playablePath("relative\\bell.wav"));
    try testing.expect(!playablePath(""));
    try testing.expect(!playablePath("C:\\a\"b.wav"));
    try testing.expect(!playablePath("C:\\a\nb.wav"));
    try testing.expect(!playablePath("\\\\server\\share\\bell.wav"));
    try testing.expect(!playablePath("//server/share/bell.wav"));
    try testing.expect(!playablePath("\\\\.\\pipe\\bell"));
    try testing.expect(!playablePath("\\\\?\\UNC\\server\\share\\bell.wav"));
}

test "win32 bell announces to a screen reader unless every feature is off" {
    try testing.expect(plan(.{}, false, watching).announce);
    try testing.expect(plan(.{ .system = true, .attention = false, .title = false }, false, watching).announce);
    try testing.expect(plan(.{ .audio = true, .attention = false, .title = false }, false, away).announce);
    try testing.expect(plan(.{ .attention = false }, false, watching).announce);
    try testing.expect(!plan(.{ .attention = false, .title = false }, false, away).announce);
    try testing.expect(!plan(.{ .system = false, .audio = false, .attention = false, .title = false, .border = true }, false, away).announce);
}

test "win32 bell sound path: a drive letter is local unless it maps a share" {
    try testing.expect(!onRemoteDrive("C:\\Windows\\Media\\Ding.wav"));
    try testing.expect(!onRemoteDrive("relative\\bell.wav"));
    try testing.expect(!onRemoteDrive(""));
    try testing.expect(!onRemoteDrive("1:\\x"));
}

test "win32 bell open command quotes the path and names the alias" {
    const path = "C:\\My Sounds\\bell \u{00e9}.wav";
    inline for (.{
        .{ true, "open \"" ++ path ++ "\" type mpegvideo alias noctty_bell" },
        .{ false, "open \"" ++ path ++ "\" alias noctty_bell" },
    }) |case| {
        const cmd = try openCommand(testing.allocator, path, case[0]);
        defer testing.allocator.free(cmd);
        const utf8 = try std.unicode.utf16LeToUtf8Alloc(testing.allocator, cmd);
        defer testing.allocator.free(utf8);
        try testing.expectEqualStrings(case[1], utf8);
    }
}
