//! Shared OLE drag-drop ABI types used by Win32 apprt modules.

const std = @import("std");
const win32_types = @import("win32_types.zig");
const sys = @import("win32/sys.zig");
const drop = @import("win32_surface_drop.zig");

// Accessed only on the UI thread, as are the clipboard and OLE consumers.
var cf_html_format: win32_types.UINT = 0;

pub fn htmlFormat() win32_types.UINT {
    if (cf_html_format == 0) {
        cf_html_format = sys.RegisterClipboardFormatW(std.unicode.utf8ToUtf16LeStringLiteral("HTML Format"));
    }
    return cf_html_format;
}

/// Borrow an HDROP; its caller retains ownership (DragFinish for WM_DROPFILES,
/// ReleaseStgMedium for OLE). Paths are converted and formatted identically.
pub fn extractHdrop(alloc: std.mem.Allocator, handle: *anyopaque, mods: drop.Modifiers) ![]u8 {
    const count = sys.DragQueryFileW(handle, 0xFFFFFFFF, null, 0);
    var paths: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (paths.items) |path| alloc.free(path);
        paths.deinit(alloc);
    }
    for (0..count) |index| {
        const i: win32_types.UINT = @intCast(index);
        const len = sys.DragQueryFileW(handle, i, null, 0);
        if (len == 0 or len == std.math.maxInt(win32_types.UINT)) continue;
        const wide = try alloc.alloc(u16, @as(usize, len) + 1);
        defer alloc.free(wide);
        const copied = sys.DragQueryFileW(handle, i, wide.ptr, len + 1);
        if (copied == 0 or copied > len) continue;
        const path = std.unicode.utf16LeToUtf8Alloc(alloc, wide[0..copied]) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => continue,
        };
        errdefer alloc.free(path);
        try paths.append(alloc, path);
    }
    return drop.formatFilePayload(alloc, paths.items, mods);
}

test "HDROP extraction preserves UTF-16 CJK and surrogate-pair paths and modifiers" {
    const Header = extern struct {
        pFiles: u32 = @sizeOf(@This()),
        point: win32_types.POINT = .{ .x = 0, .y = 0 },
        fNC: i32 = 0,
        fWide: i32 = 1,
    };
    const names = std.unicode.utf8ToUtf16LeStringLiteral("C:\\中\\😀.txt\x00C:\\Program Files\\é.txt\x00");
    const name_bytes = std.mem.sliceAsBytes(names[0 .. names.len + 1]);
    const header: Header = .{};
    const handle = sys.GlobalAlloc(2, @sizeOf(Header) + name_bytes.len) orelse return error.OutOfMemory;
    defer _ = sys.GlobalFree(handle);
    const locked: [*]u8 = @ptrCast(sys.GlobalLock(handle) orelse return error.OutOfMemory);
    @memcpy(locked[0..@sizeOf(Header)], std.mem.asBytes(&header));
    @memcpy(locked[@sizeOf(Header)..][0..name_bytes.len], name_bytes);
    _ = sys.GlobalUnlock(handle);

    const alloc = std.testing.allocator;
    const plain = try extractHdrop(alloc, handle, .{});
    defer alloc.free(plain);
    try std.testing.expectEqualStrings("C:\\中\\😀.txt \"C:\\Program Files\\é.txt\"", plain);
    const parent = try extractHdrop(alloc, handle, .{ .shift = true });
    defer alloc.free(parent);
    try std.testing.expectEqualStrings("C:\\中 \"C:\\Program Files\"", parent);
    const raw = try extractHdrop(alloc, handle, .{ .ctrl = true });
    defer alloc.free(raw);
    try std.testing.expectEqualStrings("C:\\中\\😀.txt C:\\Program Files\\é.txt", raw);
    // Extraction borrows the handle, so it remains available to its owner.
    try std.testing.expectEqual(@as(win32_types.UINT, 2), sys.DragQueryFileW(handle, 0xFFFFFFFF, null, 0));
}

pub const HRESULT = win32_types.HRESULT;
pub const GUID = win32_types.GUID;
pub const BOOL = win32_types.BOOL;
pub const DWORD = win32_types.DWORD;
pub const ULONG = win32_types.ULONG;
pub const WORD = win32_types.WORD;

pub const IID_IUnknown = GUID.parse("{00000000-0000-0000-C000-000000000046}");
pub const IID_IDropSource = GUID.parse("{00000121-0000-0000-C000-000000000046}");
pub const IID_IDropTarget = GUID.parse("{00000122-0000-0000-C000-000000000046}");
pub const IID_IDataObject = GUID.parse("{0000010E-0000-0000-C000-000000000046}");
pub const IID_IEnumFORMATETC = GUID.parse("{00000103-0000-0000-C000-000000000046}");

pub const FORMATETC = extern struct {
    cfFormat: WORD,
    ptd: ?*anyopaque,
    dwAspect: DWORD,
    lindex: i32,
    tymed: DWORD,
};

pub const STGMEDIUM = extern struct {
    tymed: DWORD,
    u: extern union {
        hGlobal: ?*anyopaque,
        raw: ?*anyopaque,
    },
    pUnkForRelease: ?*anyopaque,
};

pub const IDataObject = extern struct {
    vtbl: *const IDataObjectVtbl,
};

pub const IEnumFORMATETC = extern struct {
    vtbl: *const IEnumFORMATETCVtbl,
};

pub const IDataObjectVtbl = extern struct {
    QueryInterface: *const fn (*IDataObject, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*IDataObject) callconv(.winapi) ULONG,
    Release: *const fn (*IDataObject) callconv(.winapi) ULONG,
    GetData: *const fn (*IDataObject, *const FORMATETC, *STGMEDIUM) callconv(.winapi) HRESULT,
    GetDataHere: *const fn (*IDataObject, *const FORMATETC, *STGMEDIUM) callconv(.winapi) HRESULT,
    QueryGetData: *const fn (*IDataObject, *const FORMATETC) callconv(.winapi) HRESULT,
    GetCanonicalFormatEtc: *const fn (*IDataObject, *const FORMATETC, *FORMATETC) callconv(.winapi) HRESULT,
    SetData: *const fn (*IDataObject, *const FORMATETC, *STGMEDIUM, BOOL) callconv(.winapi) HRESULT,
    EnumFormatEtc: *const fn (*IDataObject, DWORD, *?*IEnumFORMATETC) callconv(.winapi) HRESULT,
    DAdvise: *const fn (*IDataObject, *const FORMATETC, DWORD, ?*anyopaque, *DWORD) callconv(.winapi) HRESULT,
    DUnadvise: *const fn (*IDataObject, DWORD) callconv(.winapi) HRESULT,
    EnumDAdvise: *const fn (*IDataObject, *?*anyopaque) callconv(.winapi) HRESULT,
};

pub const IEnumFORMATETCVtbl = extern struct {
    QueryInterface: *const fn (*IEnumFORMATETC, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*IEnumFORMATETC) callconv(.winapi) ULONG,
    Release: *const fn (*IEnumFORMATETC) callconv(.winapi) ULONG,
    Next: *const fn (*IEnumFORMATETC, ULONG, [*]FORMATETC, ?*ULONG) callconv(.winapi) HRESULT,
    Skip: *const fn (*IEnumFORMATETC, ULONG) callconv(.winapi) HRESULT,
    Reset: *const fn (*IEnumFORMATETC) callconv(.winapi) HRESULT,
    Clone: *const fn (*IEnumFORMATETC, *?*IEnumFORMATETC) callconv(.winapi) HRESULT,
};

const formatetc_size = 32;
const formatetc_cf_format_offset = 0;
const formatetc_ptd_offset = 8;
const formatetc_tymed_offset = 24;

const stgmedium_size = 24;
const stgmedium_tymed_offset = 0;
const stgmedium_u_offset = 8;
const stgmedium_release_offset = 16;

comptime {
    if (@sizeOf(FORMATETC) != formatetc_size or
        @offsetOf(FORMATETC, "cfFormat") != formatetc_cf_format_offset or
        @offsetOf(FORMATETC, "ptd") != formatetc_ptd_offset or
        @offsetOf(FORMATETC, "tymed") != formatetc_tymed_offset)
    {
        @compileError("FORMATETC layout mismatch");
    }

    if (@sizeOf(STGMEDIUM) != stgmedium_size or
        @offsetOf(STGMEDIUM, "tymed") != stgmedium_tymed_offset or
        @offsetOf(STGMEDIUM, "u") != stgmedium_u_offset or
        @offsetOf(STGMEDIUM, "pUnkForRelease") != stgmedium_release_offset)
    {
        @compileError("STGMEDIUM layout mismatch");
    }

    const data_object_expected = 12 * @sizeOf(*anyopaque);
    if (@sizeOf(IDataObjectVtbl) != data_object_expected) {
        @compileError(std.fmt.comptimePrint(
            "IDataObjectVtbl size mismatch: got {d}, expected {d}",
            .{ @sizeOf(IDataObjectVtbl), data_object_expected },
        ));
    }

    const enum_format_expected = 7 * @sizeOf(*anyopaque);
    if (@sizeOf(IEnumFORMATETCVtbl) != enum_format_expected) {
        @compileError(std.fmt.comptimePrint(
            "IEnumFORMATETCVtbl size mismatch: got {d}, expected {d}",
            .{ @sizeOf(IEnumFORMATETCVtbl), enum_format_expected },
        ));
    }
}

test "shared OLE vtable layouts match COM slot counts" {
    const testing = std.testing;

    try testing.expectEqual(12 * @sizeOf(*anyopaque), @sizeOf(IDataObjectVtbl));
    try testing.expectEqual(7 * @sizeOf(*anyopaque), @sizeOf(IEnumFORMATETCVtbl));
}

test "shared OLE payload layouts match Win32 ABI" {
    const testing = std.testing;

    try testing.expectEqual(@as(usize, formatetc_size), @sizeOf(FORMATETC));
    try testing.expectEqual(@as(usize, formatetc_cf_format_offset), @offsetOf(FORMATETC, "cfFormat"));
    try testing.expectEqual(@as(usize, formatetc_ptd_offset), @offsetOf(FORMATETC, "ptd"));
    try testing.expectEqual(@as(usize, formatetc_tymed_offset), @offsetOf(FORMATETC, "tymed"));

    try testing.expectEqual(@as(usize, stgmedium_size), @sizeOf(STGMEDIUM));
    try testing.expectEqual(@as(usize, stgmedium_tymed_offset), @offsetOf(STGMEDIUM, "tymed"));
    try testing.expectEqual(@as(usize, stgmedium_u_offset), @offsetOf(STGMEDIUM, "u"));
    try testing.expectEqual(@as(usize, stgmedium_release_offset), @offsetOf(STGMEDIUM, "pUnkForRelease"));
}
