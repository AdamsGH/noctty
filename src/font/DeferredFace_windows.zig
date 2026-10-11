const std = @import("std");
const Allocator = std.mem.Allocator;
const freetype = @import("freetype");
const font = @import("main.zig");
const Library = @import("main.zig").Library;
const Face = @import("main.zig").Face;
const Presentation = @import("main.zig").Presentation;

const log = std.log.scoped(.deferred_face);

const DeferredFace = @This();

win: Windows,

pub const Windows = struct {
    alloc: Allocator,
    path: [:0]const u8,
    face_index: i32,
    family_name: [:0]const u8,
    style_name: [:0]const u8,
    full_name: [:0]const u8,
    /// Typographic family (OpenType name ID 16) when the font has one and
    /// it differs from the legacy family. This is the name Nerd Fonts and
    /// the Windows Fonts UI tell users to configure, so `+list-fonts`
    /// shows it alongside the legacy family.
    typographic_family: ?[:0]const u8,
    variations: []const font.face.Variation,
    color: bool,
    coverage: []const CodepointRange,

    pub fn deinit(self: *Windows) void {
        if (self.typographic_family) |typographic| self.alloc.free(typographic);
        self.alloc.free(self.coverage);
        self.alloc.free(self.path);
        self.alloc.free(self.family_name);
        self.alloc.free(self.style_name);
        self.alloc.free(self.full_name);
        self.alloc.free(self.variations);
        self.* = undefined;
    }
};

pub fn deinit(self: *DeferredFace) void {
    self.win.deinit();
    self.* = undefined;
}

pub fn familyName(self: DeferredFace, buf: []u8) ![]const u8 {
    _ = buf;
    return self.win.family_name;
}

pub fn name(self: DeferredFace, buf: []u8) ![]const u8 {
    _ = buf;
    return self.win.full_name;
}

/// The typographic family (OpenType name ID 16), or null when the font
/// has none. Both this and `familyName` are accepted by `font-family`.
pub fn typographicFamilyName(self: DeferredFace, buf: []u8) !?[]const u8 {
    _ = buf;
    return self.win.typographic_family;
}

pub fn load(
    self: *DeferredFace,
    lib: Library,
    opts: font.face.Options,
) !Face {
    var face = try Face.initFile(lib, self.win.path, self.win.face_index, opts);
    errdefer face.deinit();
    try face.setVariations(self.win.variations, opts);
    return face;
}

/// Check if a codepoint exists in this font using the coverage font
/// discovery read from its Unicode cmap, without opening the face.
pub fn hasCodepoint(self: DeferredFace, cp: u32, p: ?Presentation) bool {
    if (p) |desired| {
        const actual: Presentation = if (self.win.color) .emoji else .text;
        if (actual != desired) return false;
    }
    return coverageContains(self.win.coverage, cp);
}

/// A run of consecutive codepoints that a face maps to glyphs, both ends
/// inclusive. A face's coverage is a sorted list of disjoint runs, which is
/// far smaller than a list of codepoints: the 568 faces installed on the
/// machine this was measured on map 3.1 million codepoints in 126,000 runs.
pub const CodepointRange = struct {
    first: u32,
    last: u32,
};

/// Whether `cp` is in `coverage`, a sorted list of disjoint runs.
pub fn coverageContains(coverage: []const CodepointRange, cp: u32) bool {
    const result = std.sort.binarySearch(CodepointRange, coverage, cp, struct {
        fn order(target: u32, range: CodepointRange) std.math.Order {
            if (target < range.first) return .lt;
            if (target > range.last) return .gt;
            return .eq;
        }
    }.order);
    return result != null;
}

test "coverageContains" {
    const coverage = [_]CodepointRange{
        .{ .first = 'A', .last = 'Z' },
        .{ .first = 0x4E00, .last = 0x4E00 },
        .{ .first = 0x1F600, .last = 0x1F64F },
    };
    try std.testing.expect(coverageContains(&coverage, 'A'));
    try std.testing.expect(coverageContains(&coverage, 'M'));
    try std.testing.expect(coverageContains(&coverage, 'Z'));
    try std.testing.expect(coverageContains(&coverage, 0x4E00));
    try std.testing.expect(coverageContains(&coverage, 0x1F64F));
    try std.testing.expect(!coverageContains(&coverage, '@'));
    try std.testing.expect(!coverageContains(&coverage, '['));
    try std.testing.expect(!coverageContains(&coverage, 0x4E01));
    try std.testing.expect(!coverageContains(&coverage, 0x10FFFF));
    try std.testing.expect(!coverageContains(&.{}, 'A'));
}
