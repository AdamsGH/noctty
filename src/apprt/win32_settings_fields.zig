//! Technology-neutral Settings ownership and typed field behavior.
//! Native HWNDs, layout and UIA providers stay in win32_settings.zig. The
//! persistence allowlist is checked independently there; this model neither
//! expands ownership nor changes the config-file patch contract.
const std = @import("std");
const Config = @import("../config/Config.zig");
const formatter = @import("../config/formatter.zig");

pub const Section = enum { appearance, terminal, shell, privacy, updates };
/// When a saved edit reaches its consumer, independently of draft preview.
pub const ApplyPolicy = enum { live, new_terminals, restart };
pub const PreviewEffect = enum { none, theme, opacity };
pub const Kind = enum { integer, number, padding, boolean, choice, blur, notifications, font_families, theme, command };
pub const DefaultDisplay = enum { value, inherited, automatic };
pub const Validation = union(enum) {
    typed,
    unsigned_integer,
    finite_range: struct { min: f64, max: f64 },
    padding_max: u8,
    font_families,
    theme,
    command,
};

pub const SettingField = enum {
    scrollback_limit,
    font_size,
    background_opacity,
    window_padding_x,
    window_padding_y,
    trim_trailing_spaces,
    desktop_notifications,
    app_notify_clipboard,
    app_notify_config,
    confirm_close,
    copy_on_select,
    clipboard_read,
    clipboard_write,
    link_url,
    link_previews,
    window_theme,
    shell_integration,
    cursor_style,
    background_blur,
    padding_balance,
    auto_update,
    auto_update_channel,
    accent_follow_system,

    pub fn label(self: SettingField) []const u8 {
        if (projection(self)) |part| return part.label;
        return descriptor(self).label;
    }
    pub fn configKey(self: SettingField) []const u8 {
        return @tagName(descriptor(self).key);
    }
    pub fn paletteKeywords(self: SettingField) []const u8 {
        if (projection(self)) |part| return part.keywords;
        return descriptor(self).keywords;
    }
};

/// The transaction keeps its stable tags; each payload type comes from its
/// descriptor's Config key, with explicit bool projections for notifications.
pub const SettingValue = value: {
    @setEvalBranchQuota(10000);
    const tags = std.meta.fields(SettingField);
    var fields: [tags.len]std.builtin.Type.UnionField = undefined;
    for (tags, 0..) |tag, i| {
        const field: SettingField = @enumFromInt(tag.value);
        const spec = descriptor(field);
        const T = if (projection(field)) |part| @FieldType(spec.Value(), part.member) else spec.Value();
        fields[i] = .{ .name = tag.name, .type = T, .alignment = @alignOf(T) };
    }
    break :value @Type(.{ .@"union" = .{
        .layout = .auto,
        .tag_type = SettingField,
        .fields = &fields,
        .decls = &.{},
    } });
};

/// One descriptor per persisted Config key. `app-notifications` has two scalar
/// projections, not two independently saved keys. The three owned fields stay
/// out of SettingValue so replacing a Config arena cannot invalidate a draft.
/// These are the current form and UIA names, which intentionally differ from
/// palette/conflict labels. Later native generation must preserve all three.
pub const NativeNames = struct { form_label: ?[]const u8 = null, accessible_name: []const u8 };
/// A composite Config key can expose multiple typed scalar controls without
/// claiming that key twice in the persistence allowlist.
pub const Projection = struct {
    field: SettingField,
    member: []const u8,
    label: []const u8,
    keywords: []const u8,
    default_label: []const u8,
    native: NativeNames,
};

pub const Descriptor = struct {
    key: Config.Key,
    field: ?SettingField = null,
    projections: []const Projection = &.{},
    native: ?NativeNames = null,
    label: []const u8,
    section: Section,
    kind: Kind,
    apply: ApplyPolicy,
    supported: bool = true,
    validation: Validation = .typed,
    keywords: []const u8,
    default_display: DefaultDisplay = .value,
    preview: PreviewEffect = .none,
    /// Historical transaction preview into app.config, including fields with
    /// no consumer on an open surface. Do not mistake this for ApplyPolicy.
    preview_draft: bool = false,

    pub fn Value(comptime self: Descriptor) type {
        return Config.Value(self.key);
    }
    pub fn read(comptime self: Descriptor, config: *const Config) self.Value() {
        return @field(config, @tagName(self.key));
    }
    /// Owned/composite keys require their explicit adapters; never borrow an
    /// owned value from another Config arena through this scalar seam.
    pub fn write(comptime self: Descriptor, config: *Config, value: self.Value()) void {
        if (self.field == null) @compileError("Owned and composite Settings keys require an explicit adapter");
        @field(config, @tagName(self.key)) = value;
    }
    pub fn writeConfig(comptime self: Descriptor, writer: *std.Io.Writer, config: *const Config) !void {
        try formatter.formatEntry(self.Value(), @tagName(self.key), self.read(config), writer);
    }
    /// Defaults come from Config.default for this platform/build, never from
    /// a second hard-coded set. No native widget or reset behavior is added.
    pub fn writeDefault(comptime self: Descriptor, writer: *std.Io.Writer, defaults: *const Config) !void {
        if (self.field) |field| return writeSettingValue(writer, settingValue(defaults, field));
        switch (self.default_display) {
            .inherited, .automatic => return writeOwnedSettingValue(self.key, writer, defaults),
            .value => {},
        }
        inline for (self.projections, 0..) |part, i| {
            if (i != 0) try writer.writeAll(", ");
            try writer.print("{s}: ", .{part.default_label});
            try writeOnOff(writer, @field(self.read(defaults), part.member));
        }
    }
};

// Padding X/Y are documented as new-terminal settings. Balance can take
// effect while enabling it but turning it off does not restore plain padding;
// new_terminals is the guaranteed policy for every value, not an overpromise.
pub const descriptors = [_]Descriptor{
    .{ .key = .@"scrollback-limit", .native = .{ .form_label = "Scrollback limit (bytes; 0 = off; new terminals only)", .accessible_name = "Scrollback limit" }, .field = .scrollback_limit, .label = "Scrollback limit", .section = .terminal, .kind = .integer, .apply = .new_terminals, .validation = .unsigned_integer, .keywords = "settings preferences configuration scrollback-limit history lines buffer", .preview = .none, .preview_draft = false },
    .{ .key = .@"font-size", .native = .{ .form_label = "Font size (pt)", .accessible_name = "Font size" }, .field = .font_size, .label = "Font size", .section = .appearance, .kind = .number, .apply = .live, .validation = .{ .finite_range = .{ .min = 6, .max = 72 } }, .keywords = "settings preferences configuration font-size text zoom", .preview = .none, .preview_draft = true },
    .{ .key = .@"background-opacity", .native = .{ .form_label = "Background opacity (0.0 .. 1.0)", .accessible_name = "Background opacity" }, .field = .background_opacity, .label = "Background opacity", .section = .appearance, .kind = .number, .apply = .live, .validation = .{ .finite_range = .{ .min = 0, .max = 1 } }, .keywords = "settings preferences configuration background-opacity transparency transparent", .preview = .opacity, .preview_draft = true },
    .{ .key = .@"window-padding-x", .native = .{ .form_label = "Window padding X (left/right or single value)", .accessible_name = "Window padding X" }, .field = .window_padding_x, .label = "Window padding X", .section = .appearance, .kind = .padding, .apply = .new_terminals, .validation = .{ .padding_max = 200 }, .keywords = "settings preferences configuration window-padding-x margin", .preview = .none, .preview_draft = true },
    .{ .key = .@"window-padding-y", .native = .{ .form_label = "Window padding Y (top/bottom or single value)", .accessible_name = "Window padding Y" }, .field = .window_padding_y, .label = "Window padding Y", .section = .appearance, .kind = .padding, .apply = .new_terminals, .validation = .{ .padding_max = 200 }, .keywords = "settings preferences configuration window-padding-y margin", .preview = .none, .preview_draft = true },
    .{ .key = .@"clipboard-trim-trailing-spaces", .native = .{ .accessible_name = "Clipboard trimming" }, .field = .trim_trailing_spaces, .label = "Trim trailing spaces on copy", .section = .terminal, .kind = .boolean, .apply = .live, .validation = .typed, .keywords = "settings preferences configuration clipboard-trim-trailing-spaces whitespace copy", .preview = .none, .preview_draft = false },
    .{ .key = .@"desktop-notifications", .native = .{ .accessible_name = "Terminal notifications" }, .field = .desktop_notifications, .label = "Terminal desktop notifications", .section = .privacy, .kind = .boolean, .apply = .live, .validation = .typed, .keywords = "settings preferences configuration desktop-notifications alerts", .preview = .none, .preview_draft = false },
    .{ .key = .@"app-notifications", .projections = &.{
        .{ .field = .app_notify_clipboard, .member = "clipboard-copy", .label = "Clipboard copy notification", .keywords = "settings preferences configuration app-notifications clipboard-copy toast", .default_label = "Clipboard copy", .native = .{ .accessible_name = "Clipboard-copy notification" } },
        .{ .field = .app_notify_config, .member = "config-reload", .label = "Config reload notification", .keywords = "settings preferences configuration app-notifications config-reload toast", .default_label = "config reload", .native = .{ .accessible_name = "Config-reload notification" } },
    }, .label = "App notifications", .section = .privacy, .kind = .notifications, .apply = .live, .keywords = "settings preferences configuration app-notifications clipboard-copy config-reload toast" },
    .{ .key = .@"confirm-close-surface", .native = .{ .form_label = "Close confirmation", .accessible_name = "Close confirmation" }, .field = .confirm_close, .label = "Close confirmation", .section = .terminal, .kind = .choice, .apply = .live, .validation = .typed, .keywords = "settings preferences configuration confirm-close-surface quit exit running", .preview = .none, .preview_draft = false },
    .{ .key = .@"copy-on-select", .native = .{ .form_label = "Copy on select", .accessible_name = "Copy on select" }, .field = .copy_on_select, .label = "Copy on select", .section = .terminal, .kind = .choice, .apply = .live, .validation = .typed, .keywords = "settings preferences configuration copy-on-select selection clipboard", .preview = .none, .preview_draft = false },
    .{ .key = .@"clipboard-read", .native = .{ .form_label = "OSC 52 clipboard read requests", .accessible_name = "OSC 52 clipboard read requests" }, .field = .clipboard_read, .label = "Clipboard read requests (OSC 52)", .section = .privacy, .kind = .choice, .apply = .live, .validation = .typed, .keywords = "settings preferences configuration clipboard-read osc 52 paste", .preview = .none, .preview_draft = false },
    .{ .key = .@"clipboard-write", .native = .{ .form_label = "OSC 52 clipboard write requests", .accessible_name = "OSC 52 clipboard write requests" }, .field = .clipboard_write, .label = "Clipboard write requests (OSC 52)", .section = .privacy, .kind = .choice, .apply = .live, .validation = .typed, .keywords = "settings preferences configuration clipboard-write osc 52 copy", .preview = .none, .preview_draft = false },
    .{ .key = .@"link-url", .native = .{ .form_label = "Clickable URL opening", .accessible_name = "Clickable URL opening" }, .field = .link_url, .label = "Clickable URL opening", .section = .privacy, .kind = .choice, .apply = .live, .validation = .typed, .keywords = "settings preferences configuration link-url url hyperlink", .preview = .none, .preview_draft = false },
    .{ .key = .@"link-previews", .native = .{ .form_label = "Link preview popups", .accessible_name = "Link preview popups" }, .field = .link_previews, .label = "Link preview popups", .section = .privacy, .kind = .choice, .apply = .live, .validation = .typed, .keywords = "settings preferences configuration link-previews url hyperlink tooltip", .preview = .none, .preview_draft = false },
    .{ .key = .@"window-theme", .native = .{ .form_label = "Window theme", .accessible_name = "Window theme" }, .field = .window_theme, .label = "Window theme", .section = .appearance, .kind = .choice, .apply = .live, .validation = .typed, .keywords = "settings preferences configuration window-theme dark light mode", .preview = .theme, .preview_draft = true },
    .{ .key = .@"shell-integration", .native = .{ .form_label = "Shell integration", .accessible_name = "Shell integration" }, .field = .shell_integration, .label = "Shell integration", .section = .shell, .kind = .choice, .apply = .new_terminals, .validation = .typed, .keywords = "settings preferences configuration shell-integration powershell bash prompt", .preview = .none, .preview_draft = false },
    .{ .key = .@"cursor-style", .native = .{ .form_label = "Cursor style", .accessible_name = "Cursor style" }, .field = .cursor_style, .label = "Cursor style", .section = .appearance, .kind = .choice, .apply = .live, .validation = .typed, .keywords = "settings preferences configuration cursor-style caret block bar underline", .preview = .none, .preview_draft = true },
    .{ .key = .@"background-blur", .native = .{ .accessible_name = "Background blur" }, .field = .background_blur, .label = "Background blur", .section = .appearance, .kind = .blur, .apply = .live, .supported = false, .validation = .typed, .keywords = "settings preferences configuration background-blur", .preview = .none, .preview_draft = true },
    .{ .key = .@"window-padding-balance", .native = .{ .form_label = "Window padding balance", .accessible_name = "Window padding balance" }, .field = .padding_balance, .label = "Window padding balance", .section = .appearance, .kind = .choice, .apply = .new_terminals, .validation = .typed, .keywords = "settings preferences configuration window-padding-balance margin", .preview = .none, .preview_draft = true },
    .{ .key = .@"auto-update", .native = .{ .form_label = "Auto-update mode", .accessible_name = "Auto-update mode" }, .field = .auto_update, .label = "Auto-update mode", .section = .updates, .kind = .choice, .apply = .live, .validation = .typed, .keywords = "settings preferences configuration auto-update upgrade", .preview = .none, .preview_draft = false },
    .{ .key = .@"auto-update-channel", .native = .{ .form_label = "Auto-update channel", .accessible_name = "Auto-update channel" }, .field = .auto_update_channel, .label = "Auto-update channel", .section = .updates, .kind = .choice, .apply = .live, .validation = .typed, .keywords = "settings preferences configuration auto-update-channel stable tip release", .preview = .none, .preview_draft = false },
    .{ .key = .@"accent-follow-system", .native = .{ .accessible_name = "Follow Windows accent color" }, .field = .accent_follow_system, .label = "Follow Windows accent color", .section = .appearance, .kind = .boolean, .apply = .live, .validation = .typed, .keywords = "settings preferences configuration accent-follow-system accent color highlight tab windows personalization", .preview = .theme, .preview_draft = true },
    .{ .key = .@"font-family", .native = .{ .form_label = "Font family fallbacks (comma-separated)", .accessible_name = "Font family fallbacks" }, .label = "Font family", .section = .appearance, .kind = .font_families, .apply = .live, .validation = .font_families, .keywords = "settings preferences configuration font-family", .default_display = .inherited },
    .{ .key = .theme, .native = .{ .form_label = "Terminal theme name, absolute path, or light/dark pair", .accessible_name = "Terminal theme" }, .label = "Terminal theme", .section = .appearance, .kind = .theme, .apply = .live, .validation = .theme, .keywords = "settings preferences configuration theme", .default_display = .inherited },
    .{ .key = .command, .native = .{ .form_label = "Default command (blank = auto-detect)", .accessible_name = "Default command" }, .label = "Default command", .section = .shell, .kind = .command, .apply = .new_terminals, .validation = .command, .keywords = "settings preferences configuration command", .default_display = .automatic },
};

pub fn forKey(key: Config.Key) ?Descriptor {
    for (descriptors) |spec| if (spec.key == key) return spec;
    return null;
}
pub fn descriptor(field: SettingField) Descriptor {
    for (descriptors) |spec| {
        if (spec.field == field) return spec;
        for (spec.projections) |part| if (part.field == field) return spec;
    }
    unreachable;
}
pub fn projection(field: SettingField) ?Projection {
    for (descriptors) |spec| for (spec.projections) |part| {
        if (part.field == field) return part;
    };
    return null;
}

pub fn assertCoverage(comptime owned_keys: anytype) void {
    @setEvalBranchQuota(10000);
    if (descriptors.len != owned_keys.len) @compileError("Settings descriptor count differs from ownership allowlist");
    for (owned_keys) |key| {
        var count: usize = 0;
        for (descriptors) |spec| {
            if (spec.key == key) {
                count += 1;
            }
        }
        if (count != 1) @compileError("Settings key needs exactly one descriptor: " ++ @tagName(key));
    }
    for (descriptors) |spec| {
        var count: usize = 0;
        for (owned_keys) |key| {
            if (spec.key == key) count += 1;
        }
        if (count != 1) @compileError("Settings descriptor must own exactly one allowlisted key: " ++ @tagName(spec.key));
        const T = spec.Value();
        const type_matches = switch (spec.kind) {
            .integer => T == usize,
            .number => @typeInfo(T) == .float,
            .padding => T == Config.WindowPadding,
            .boolean => T == bool,
            .choice => @typeInfo(T) == .@"enum" or T == bool or
                (@typeInfo(T) == .optional and @typeInfo(@typeInfo(T).optional.child) == .@"enum"),
            .blur => T == Config.BackgroundBlur,
            .notifications => T == Config.AppNotifications,
            .font_families => T == Config.RepeatableString,
            .theme => T == ?Config.Theme,
            .command => T == ?Config.Command,
        };
        if (!type_matches) @compileError("Settings editor kind differs from Config type: " ++ @tagName(spec.key));
        if (spec.label.len == 0 or spec.keywords.len == 0) @compileError("Settings metadata must be named");
        if (std.mem.indexOf(u8, spec.keywords, @tagName(spec.key)) == null) @compileError("Settings keywords must contain the config key");
        if (spec.kind != .notifications and spec.native == null) @compileError("Missing native Settings names");
        if (spec.field != null and spec.projections.len != 0) @compileError("Scalar Settings descriptor also has projections");
        for (spec.projections) |part| {
            if (@FieldType(SettingValue, @tagName(part.field)) != @FieldType(T, part.member)) @compileError("Settings projection type differs from Config");
            if (part.label.len == 0 or part.native.accessible_name.len == 0 or std.mem.indexOf(u8, part.keywords, @tagName(spec.key)) == null) @compileError("Missing Settings projection names");
        }
        if (spec.field) |field| {
            if (@FieldType(SettingValue, @tagName(field)) != spec.Value()) @compileError("Settings value type differs from Config");
        }
    }
    for (std.enums.values(SettingField)) |field| {
        var count: usize = 0;
        for (descriptors) |spec| {
            if (spec.field == field) count += 1;
            for (spec.projections) |part| {
                if (part.field == field) count += 1;
            }
        }
        if (count != 1) @compileError("Settings projection needs exactly one descriptor: " ++ @tagName(field));
    }
}

pub fn settingValue(config: *const Config, field: SettingField) SettingValue {
    inline for (std.meta.fields(SettingValue)) |tag| {
        const candidate: SettingField = @field(SettingField, tag.name);
        const spec = comptime descriptor(candidate);
        if (field == candidate) {
            const value = if (comptime projection(candidate)) |part| @field(spec.read(config), part.member) else spec.read(config);
            return @unionInit(SettingValue, tag.name, value);
        }
    }
    unreachable;
}
pub fn setSettingValue(config: *Config, value: SettingValue) void {
    switch (value) {
        inline else => |payload, field| {
            const spec = comptime descriptor(field);
            if (comptime projection(field)) |part| {
                @field(@field(config, @tagName(spec.key)), part.member) = payload;
            } else spec.write(config, payload);
        },
    }
}

/// Curated option order and wording are part of the existing form contract.
/// The typed pairs drive both directions and check new Config variants.
pub fn Combo(comptime field: SettingField) type {
    @setEvalBranchQuota(10000);
    const T = @FieldType(SettingValue, @tagName(field));
    const Option = struct { value: T, label: []const u8 };
    const options: []const Option = switch (field) {
        // true means unless at a prompt; shell integration supplies prompt state.
        .confirm_close => &.{
            .{ .value = .false, .label = "Never" },
            .{ .value = .true, .label = "Unless at a shell prompt" },
            .{ .value = .always, .label = "Always" },
        },
        // Windows has one clipboard, so true and clipboard have the same effect.
        .copy_on_select => &.{
            .{ .value = .false, .label = "Off" },
            .{ .value = .true, .label = "On" },
            .{ .value = .clipboard, .label = "On (same as On on Windows)" },
        },
        .clipboard_read, .clipboard_write => &.{
            .{ .value = .ask, .label = "Ask each time" },
            .{ .value = .allow, .label = "Always allow" },
            .{ .value = .deny, .label = "Never allow" },
        },
        .link_url => &.{
            .{ .value = true, .label = "On" },
            .{ .value = false, .label = "Off" },
        },
        .link_previews => &.{
            .{ .value = .true, .label = "All links" },
            .{ .value = .osc8, .label = "Only links the program sets" },
            .{ .value = .false, .label = "Off" },
        },
        // auto and system both follow Windows; ghostty uses custom titlebar colors.
        .window_theme => &.{
            .{ .value = .auto, .label = "Match Windows (auto, default)" },
            .{ .value = .system, .label = "Match Windows (system)" },
            .{ .value = .light, .label = "Light" },
            .{ .value = .dark, .label = "Dark" },
            .{ .value = .ghostty, .label = "Dark, custom title bar colors" },
        },
        // detect includes PowerShell and cmd on Windows.
        .shell_integration => &.{
            .{ .value = .none, .label = "Off" },
            .{ .value = .detect, .label = "Automatic (includes PowerShell and cmd)" },
            .{ .value = .bash, .label = "Bash" },
            .{ .value = .elvish, .label = "Elvish" },
            .{ .value = .fish, .label = "Fish" },
            .{ .value = .nushell, .label = "Nushell" },
            .{ .value = .zsh, .label = "Zsh" },
        },
        .cursor_style => &.{
            .{ .value = .bar, .label = "Bar" },
            .{ .value = .block, .label = "Block" },
            .{ .value = .underline, .label = "Underline" },
            .{ .value = .block_hollow, .label = "Hollow block" },
        },
        .padding_balance => &.{
            .{ .value = .false, .label = "Off" },
            .{ .value = .true, .label = "On (top padding capped)" },
            .{ .value = .equal, .label = "On (equal on all sides)" },
        },
        // An unset auto-update behaves as check.
        .auto_update => &.{
            .{ .value = null, .label = "Default (check for updates)" },
            .{ .value = .off, .label = "Off" },
            .{ .value = .check, .label = "Check for updates" },
            .{ .value = .download, .label = "Check and download updates" },
        },
        // The Windows updater checks stable automatically; tip is manual.
        .auto_update_channel => &.{
            .{ .value = null, .label = "Default (matches this build)" },
            .{ .value = .stable, .label = "Stable" },
            .{ .value = .tip, .label = "Tip (no automatic checks)" },
        },
        else => @compileError("Not a Settings dropdown"),
    };
    comptime {
        for (options, 0..) |option, i| {
            if (option.label.len == 0) @compileError("Empty Settings option label");
            for (options[i + 1 ..]) |other| if (std.meta.eql(option.value, other.value)) @compileError("Duplicate Settings option");
        }
        const E = if (@typeInfo(T) == .optional) @typeInfo(T).optional.child else T;
        const count: usize = if (@typeInfo(E) == .@"enum") @typeInfo(E).@"enum".fields.len else 2;
        if (options.len != count + @intFromBool(@typeInfo(T) == .optional)) @compileError("Settings dropdown must cover every Config variant");
    }
    return struct {
        pub const labels = labels: {
            var result: [options.len][]const u8 = undefined;
            for (options, 0..) |option, i| result[i] = option.label;
            break :labels result;
        };
        pub fn fromIndex(index: isize) ?T {
            if (index < 0 or index >= options.len) return null;
            // Explicit wrapping preserves a valid 'default' (inner null).
            return @as(?T, options[@intCast(index)].value);
        }
        pub fn toIndex(value: T) usize {
            for (options, 0..) |option, i| if (std.meta.eql(value, option.value)) return i;
            unreachable;
        }
    };
}

pub fn parseScalar(comptime field: SettingField, input: []const u8) !@FieldType(SettingValue, @tagName(field)) {
    const T = @FieldType(SettingValue, @tagName(field));
    const text = std.mem.trim(u8, input, " \t");
    const spec = comptime descriptor(field);
    return switch (comptime spec.validation) {
        .unsigned_integer => std.fmt.parseInt(T, text, 10) catch error.InvalidNumber,
        .finite_range => |range| value: {
            const parsed = std.fmt.parseFloat(T, text) catch return error.InvalidNumber;
            if (!std.math.isFinite(parsed) or parsed < range.min or parsed > range.max) return error.OutOfRange;
            break :value parsed;
        },
        .padding_max => |max| value: {
            const parsed = Config.WindowPadding.parseCLI(text) catch return error.InvalidNumber;
            if (parsed.top_left > max or parsed.bottom_right > max) return error.OutOfRange;
            break :value parsed;
        },
        else => @compileError("Not a Settings scalar edit"),
    };
}

/// Keep the existing user-facing wording tied to the same bounds as parsing.
pub fn scalarValidationMessage(comptime field: SettingField, out_of_range: bool) []const u8 {
    const spec = comptime descriptor(field);
    return switch (comptime spec.validation) {
        .finite_range => |range| if (out_of_range)
            std.fmt.comptimePrint("{s} must be from {d} through {d}{s}.", .{ spec.label, range.min, range.max, if (field == .font_size) " points" else "" })
        else
            std.fmt.comptimePrint("{s} must be a number from {d} through {d}.", .{ spec.label, range.min, range.max }),
        .padding_max => |max| if (out_of_range)
            std.fmt.comptimePrint("Window padding must be from 0 through {d} logical pixels.", .{max})
        else
            std.fmt.comptimePrint("{s} must be one number or a comma-separated pair.", .{spec.label}),
        else => @compileError("Not a ranged Settings edit"),
    };
}

pub fn parseFontFamilyEditText(alloc: std.mem.Allocator, text: []const u8) !Config.RepeatableString {
    const trimmed = std.mem.trim(u8, text, " \t");
    if (trimmed.len == 0) return .{};

    var next: Config.RepeatableString = .{};
    var parts = std.mem.splitScalar(u8, trimmed, ',');
    while (parts.next()) |part| {
        const family = std.mem.trim(u8, part, " \t");
        if (family.len == 0) continue;
        try next.parseCLI(alloc, family);
    }
    return next;
}

pub fn writeCommandForEdit(writer: *std.Io.Writer, value: Config.Command) !void {
    switch (value) {
        .shell => |v| try writer.writeAll(v),
        .direct => |v| {
            try writer.writeAll("direct:");
            for (v, 0..) |arg, i| {
                if (i != 0) try writer.writeByte(' ');
                try Config.Command.writeDirectArg(writer, arg);
            }
        },
    }
}

pub fn writeOwnedSettingValue(comptime key: Config.Key, writer: *std.Io.Writer, config: *const Config) !void {
    switch (key) {
        .@"font-family" => {
            if (config.@"font-family".list.items.len == 0) return writer.writeAll("(default)");
            for (config.@"font-family".list.items, 0..) |family, i| {
                if (i != 0) try writer.writeAll(", ");
                try writer.writeAll(family);
            }
        },
        .theme => if (config.theme) |theme| {
            try theme.formatValue(writer);
        } else try writer.writeAll("(default)"),
        .command => if (config.command) |command| {
            try writeCommandForEdit(writer, command);
        } else try writer.writeAll("(automatic)"),
        else => @compileError("Not an owned Settings edit"),
    }
}

fn writePaddingValue(writer: *std.Io.Writer, padding: @FieldType(Config, "window-padding-x")) !void {
    if (padding.top_left == padding.bottom_right) {
        try writer.print("{d}", .{padding.top_left});
    } else {
        try writer.print("{d},{d}", .{ padding.top_left, padding.bottom_right });
    }
}

fn writeOnOff(writer: *std.Io.Writer, on: bool) !void {
    try writer.writeAll(if (on) "On" else "Off");
}

/// A setting's value the way the form shows it: the dropdown's text for a
/// dropdown, "on" and "off" for a checkbox, the number for a number. Never the
/// Zig debug rendering of the transaction's union.
pub fn writeSettingValue(writer: *std.Io.Writer, value: SettingValue) !void {
    // Never display internal enum tags; use the curated form labels.
    switch (value) {
        inline else => |payload, field| switch (comptime descriptor(field).kind) {
            .integer => try writer.print("{d}", .{payload}),
            .number => if (comptime field == .font_size) try writer.print("{d} pt", .{payload}) else try writer.print("{d}", .{payload}),
            .padding => try writePaddingValue(writer, payload),
            .boolean, .notifications => try writeOnOff(writer, payload),
            .choice => try writer.writeAll(Combo(field).labels[Combo(field).toIndex(payload)]),
            .blur => try writeOnOff(writer, payload.win32BlurRequested()),
            else => unreachable,
        },
    }
}

/// Behavioral round trips use Config's real grammar and formatter, including
/// composite/owned keys, rather than checking source text or pointer equality.
pub fn testRoundTrips(alloc: std.mem.Allocator) !void {
    var source = try Config.default(alloc);
    defer source.deinit();
    var defaults = try Config.default(alloc);
    defer defaults.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const text =
        \\scrollback-limit = 123456
        \\font-size = 13.25
        \\background-opacity = 0.875
        \\window-padding-x = 5,7
        \\window-padding-y = 9,11
        \\clipboard-trim-trailing-spaces = false
        \\desktop-notifications = false
        \\app-notifications = no-clipboard-copy,no-config-reload
        \\confirm-close-surface = always
        \\copy-on-select = clipboard
        \\clipboard-read = deny
        \\clipboard-write = deny
        \\link-url = false
        \\link-previews = osc8
        \\window-theme = dark
        \\shell-integration = none
        \\cursor-style = bar
        \\background-blur = true
        \\window-padding-balance = equal
        \\auto-update = off
        \\auto-update-channel = tip
        \\accent-follow-system = false
        \\font-family = Font #; 🚀
        \\font-family = Second Font
        \\theme = light:Light,dark:Dark
        \\command = direct:pwsh.exe -NoLogo -Command "echo #; literal"
    ;
    try tmp.dir.writeFile(.{ .sub_path = "source", .data = text });
    const path = try tmp.dir.realpathAlloc(alloc, "source");
    defer alloc.free(path);
    try source.loadFile(alloc, path);
    try std.testing.expect(source._diagnostics.empty());
    inline for (descriptors) |spec| {
        try std.testing.expect(defaults.changed(&source, spec.key));
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();
        try spec.writeConfig(&out.writer, &source);
        try tmp.dir.writeFile(.{ .sub_path = "source", .data = out.written() });
        var loaded = try Config.default(alloc);
        defer loaded.deinit();
        try loaded.loadFile(alloc, path);
        try std.testing.expect(loaded._diagnostics.empty());
        try std.testing.expect(!loaded.changed(&source, spec.key));
        var again: std.Io.Writer.Allocating = .init(alloc);
        defer again.deinit();
        try spec.writeConfig(&again.writer, &loaded);
        try std.testing.expectEqualStrings(out.written(), again.written());
        out.clearRetainingCapacity();
        try spec.writeDefault(&out.writer, &defaults);
        try std.testing.expect(out.written().len > 0);
        if (spec.field) |field| {
            setSettingValue(&loaded, settingValue(&source, field));
            try std.testing.expect(std.meta.eql(settingValue(&source, field), settingValue(&loaded, field)));
            if (spec.kind == .choice) {
                for (Combo(field).labels, 0..) |_, i| {
                    const value = Combo(field).fromIndex(@intCast(i)).?;
                    try std.testing.expectEqual(i, Combo(field).toIndex(value));
                    const projected = @unionInit(SettingValue, @tagName(field), value);
                    setSettingValue(&loaded, projected);
                    try std.testing.expect(std.meta.eql(projected, settingValue(&loaded, field)));
                }
                try std.testing.expect(Combo(field).fromIndex(-1) == null);
                try std.testing.expect(Combo(field).fromIndex(Combo(field).labels.len) == null);
            }
        }
    }
}

test "settings model validates scalar ranges with the form's exact types" {
    try std.testing.expectEqual(@as(usize, 0), try parseScalar(.scrollback_limit, " 0 "));
    try std.testing.expectError(error.InvalidNumber, parseScalar(.scrollback_limit, "-1"));
    try std.testing.expectError(error.InvalidNumber, parseScalar(.scrollback_limit, "1.5"));
    try std.testing.expectError(error.InvalidNumber, parseScalar(.scrollback_limit, ""));
    inline for (.{ SettingField.font_size, SettingField.background_opacity }) |field| {
        const range = comptime descriptor(field).validation.finite_range;
        const T = @FieldType(SettingValue, @tagName(field));
        var buf: [64]u8 = undefined;
        inline for (.{ range.min, range.max }) |bound| {
            const text = try std.fmt.bufPrint(&buf, "{d}", .{bound});
            try std.testing.expectEqual(@as(T, @floatCast(bound)), try parseScalar(field, text));
        }
        for ([_][]const u8{ "nan", "inf", "-inf", "-1", "73" }) |invalid| {
            try std.testing.expectError(error.OutOfRange, parseScalar(field, invalid));
        }
        try std.testing.expectError(error.InvalidNumber, parseScalar(field, "not a number"));
    }
    inline for (.{ SettingField.window_padding_x, SettingField.window_padding_y }) |field| {
        const parsed = try parseScalar(field, " 0,200 ");
        try std.testing.expectEqual(@as(u8, 0), parsed.top_left);
        try std.testing.expectEqual(@as(u8, 200), parsed.bottom_right);
        try std.testing.expectError(error.OutOfRange, parseScalar(field, "201"));
        try std.testing.expectError(error.InvalidNumber, parseScalar(field, "1,2,3"));
    }
}

test "settings model separates saved apply timing from edit previews and Windows support" {
    for (descriptors) |spec| {
        const new_terminal = spec.key == .@"scrollback-limit" or spec.key == .command or spec.key == .@"shell-integration" or spec.key == .@"window-padding-x" or spec.key == .@"window-padding-y" or spec.key == .@"window-padding-balance";
        try std.testing.expectEqual(if (new_terminal) ApplyPolicy.new_terminals else ApplyPolicy.live, spec.apply);
        try std.testing.expectEqual(spec.key != .@"background-blur", spec.supported);
    }
    try std.testing.expect(descriptor(.font_size).preview_draft);
    try std.testing.expectEqual(PreviewEffect.none, descriptor(.font_size).preview);
    try std.testing.expectEqual(PreviewEffect.opacity, descriptor(.background_opacity).preview);
    try std.testing.expectEqual(PreviewEffect.theme, descriptor(.window_theme).preview);
    try std.testing.expectEqual(PreviewEffect.theme, descriptor(.accent_follow_system).preview);
}

test "settings model notification projections preserve their sibling" {
    var config = try Config.default(std.testing.allocator);
    defer config.deinit();
    inline for (.{ false, true }) |clipboard| {
        inline for (.{ false, true }) |reload| {
            setSettingValue(&config, .{ .app_notify_clipboard = clipboard });
            setSettingValue(&config, .{ .app_notify_config = reload });
            try std.testing.expectEqual(clipboard, settingValue(&config, .app_notify_clipboard).app_notify_clipboard);
            try std.testing.expectEqual(reload, settingValue(&config, .app_notify_config).app_notify_config);
            setSettingValue(&config, .{ .app_notify_clipboard = !clipboard });
            try std.testing.expectEqual(reload, config.@"app-notifications".@"config-reload");
            setSettingValue(&config, .{ .app_notify_config = !reload });
            try std.testing.expectEqual(!clipboard, config.@"app-notifications".@"clipboard-copy");
        }
    }
}
