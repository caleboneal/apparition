const std = @import("std");
const xkb = @cImport({
    @cInclude("xkbcommon/xkbcommon.h");
    @cInclude("xkbcommon/xkbcommon-keysyms.h");
});

const Self = @This();

context: *xkb.xkb_context,
keymap: *xkb.xkb_keymap,
state: *xkb.xkb_state,
application_cursor: bool = false,

/// Use XKB's default rules/layout, including XKB_DEFAULT_* environment settings.
pub fn init() !Self {
    return initWithNames(null);
}

fn initWithNames(names: ?*const xkb.xkb_rule_names) !Self {
    const context = xkb.xkb_context_new(xkb.XKB_CONTEXT_NO_FLAGS) orelse
        return error.XkbContextFailed;
    errdefer xkb.xkb_context_unref(context);
    const keymap = xkb.xkb_keymap_new_from_names(context, names, xkb.XKB_KEYMAP_COMPILE_NO_FLAGS) orelse
        return error.XkbKeymapFailed;
    errdefer xkb.xkb_keymap_unref(keymap);
    const state = xkb.xkb_state_new(keymap) orelse return error.XkbStateFailed;
    return .{ .context = context, .keymap = keymap, .state = state };
}

pub fn deinit(self: *Self) void {
    xkb.xkb_state_unref(self.state);
    xkb.xkb_keymap_unref(self.keymap);
    xkb.xkb_context_unref(self.context);
}

/// Accept an evdev keycode and update XKB on both press and release.
pub fn key(self: *Self, evdev_key: u32, pressed: bool, buffer: []u8) !?[]const u8 {
    // XKB's evdev keymap reserves the first eight keycodes.
    const code = evdev_key + 8;
    _ = xkb.xkb_state_update_key(self.state, code, if (pressed) xkb.XKB_KEY_DOWN else xkb.XKB_KEY_UP);
    if (!pressed) return null;

    return encode(
        xkb.xkb_state_key_get_one_sym(self.state, code),
        self.modActive(xkb.XKB_MOD_NAME_CTRL),
        self.modActive(xkb.XKB_MOD_NAME_ALT),
        self.modActive(xkb.XKB_MOD_NAME_SHIFT),
        self.application_cursor,
        buffer,
    );
}

fn modActive(self: *Self, name: [*:0]const u8) bool {
    return xkb.xkb_state_mod_name_is_active(self.state, name, xkb.XKB_STATE_MODS_EFFECTIVE) > 0;
}

fn encode(sym: xkb.xkb_keysym_t, ctrl: bool, alt: bool, shift: bool, application_cursor: bool, buffer: []u8) !?[]const u8 {
    var text: [4]u8 = undefined;
    const bytes: []const u8 = switch (sym) {
        xkb.XKB_KEY_Return, xkb.XKB_KEY_KP_Enter => "\r",
        xkb.XKB_KEY_BackSpace => "\x7f",
        xkb.XKB_KEY_Tab => if (shift) "\x1b[Z" else "\t",
        xkb.XKB_KEY_ISO_Left_Tab => "\x1b[Z",
        xkb.XKB_KEY_Escape => "\x1b",
        xkb.XKB_KEY_Up, xkb.XKB_KEY_KP_Up => if (application_cursor) "\x1bOA" else "\x1b[A",
        xkb.XKB_KEY_Down, xkb.XKB_KEY_KP_Down => if (application_cursor) "\x1bOB" else "\x1b[B",
        xkb.XKB_KEY_Right, xkb.XKB_KEY_KP_Right => if (application_cursor) "\x1bOC" else "\x1b[C",
        xkb.XKB_KEY_Left, xkb.XKB_KEY_KP_Left => if (application_cursor) "\x1bOD" else "\x1b[D",
        xkb.XKB_KEY_Home, xkb.XKB_KEY_KP_Home => if (application_cursor) "\x1bOH" else "\x1b[H",
        xkb.XKB_KEY_End, xkb.XKB_KEY_KP_End => if (application_cursor) "\x1bOF" else "\x1b[F",
        xkb.XKB_KEY_Delete, xkb.XKB_KEY_KP_Delete => "\x1b[3~",
        xkb.XKB_KEY_Page_Up, xkb.XKB_KEY_KP_Page_Up => "\x1b[5~",
        xkb.XKB_KEY_Page_Down, xkb.XKB_KEY_KP_Page_Down => "\x1b[6~",
        else => blk: {
            var codepoint = xkb.xkb_keysym_to_utf32(sym);
            if (codepoint == 0) return null;
            if (ctrl) {
                codepoint = switch (codepoint) {
                    'a'...'z' => codepoint - 'a' + 1,
                    '@'...'_' => codepoint & 0x1f,
                    ' ' => 0,
                    '?' => 0x7f,
                    else => codepoint,
                };
            }
            const len = try std.unicode.utf8Encode(@intCast(codepoint), &text);
            break :blk text[0..len];
        },
    };
    const prefix: usize = if (alt) 1 else 0;
    if (buffer.len < prefix + bytes.len) return error.BufferTooSmall;
    if (alt) buffer[0] = 0x1b;
    @memcpy(buffer[prefix..][0..bytes.len], bytes);
    return buffer[0 .. prefix + bytes.len];
}

test "terminal key encodings" {
    const Case = struct {
        sym: xkb.xkb_keysym_t,
        expected: []const u8,
        ctrl: bool = false,
        alt: bool = false,
        shift: bool = false,
    };
    const cases = [_]Case{
        .{ .sym = xkb.XKB_KEY_a, .expected = "a" },
        .{ .sym = xkb.XKB_KEY_eacute, .expected = "é" },
        .{ .sym = 0x0101f600, .expected = "\x1b😀", .alt = true },
        .{ .sym = xkb.XKB_KEY_c, .expected = "\x03", .ctrl = true },
        .{ .sym = xkb.XKB_KEY_D, .expected = "\x04", .ctrl = true },
        .{ .sym = xkb.XKB_KEY_c, .expected = "\x1b\x03", .ctrl = true, .alt = true },
        .{ .sym = xkb.XKB_KEY_space, .expected = "\x00", .ctrl = true },
        .{ .sym = xkb.XKB_KEY_bracketleft, .expected = "\x1b", .ctrl = true },
        .{ .sym = xkb.XKB_KEY_Return, .expected = "\r" },
        .{ .sym = xkb.XKB_KEY_BackSpace, .expected = "\x7f" },
        .{ .sym = xkb.XKB_KEY_Tab, .expected = "\t" },
        .{ .sym = xkb.XKB_KEY_Tab, .expected = "\x1b[Z", .shift = true },
        .{ .sym = xkb.XKB_KEY_ISO_Left_Tab, .expected = "\x1b[Z" },
        .{ .sym = xkb.XKB_KEY_Escape, .expected = "\x1b" },
        .{ .sym = xkb.XKB_KEY_Up, .expected = "\x1b[A" },
        .{ .sym = xkb.XKB_KEY_Down, .expected = "\x1b[B" },
        .{ .sym = xkb.XKB_KEY_Right, .expected = "\x1b[C" },
        .{ .sym = xkb.XKB_KEY_Left, .expected = "\x1b[D" },
        .{ .sym = xkb.XKB_KEY_Home, .expected = "\x1b[H" },
        .{ .sym = xkb.XKB_KEY_End, .expected = "\x1b[F" },
        .{ .sym = xkb.XKB_KEY_Delete, .expected = "\x1b[3~" },
        .{ .sym = xkb.XKB_KEY_Page_Up, .expected = "\x1b[5~" },
        .{ .sym = xkb.XKB_KEY_Page_Down, .expected = "\x1b[6~" },
    };
    var buffer: [5]u8 = undefined;
    for (cases) |case| {
        const result = (try encode(case.sym, case.ctrl, case.alt, case.shift, false, &buffer)).?;
        try std.testing.expectEqualStrings(case.expected, result);
    }
    try std.testing.expectEqual(@as(?[]const u8, null), try encode(xkb.XKB_KEY_Shift_L, false, false, false, false, &buffer));
    try std.testing.expectError(error.BufferTooSmall, encode(xkb.XKB_KEY_Delete, false, true, false, false, buffer[0..4]));
    try std.testing.expectError(error.BufferTooSmall, encode(xkb.XKB_KEY_a, false, false, false, false, buffer[0..0]));
}

test "application cursor mode toggles CSI and SS3" {
    var keyboard = try initWithNames(&.{ .layout = "us" });
    defer keyboard.deinit();
    try std.testing.expect(!keyboard.application_cursor);
    var buffer: [5]u8 = undefined;
    const cases = .{
        .{ 103, "\x1b[A", "\x1bOA" }, // Up
        .{ 108, "\x1b[B", "\x1bOB" }, // Down
        .{ 106, "\x1b[C", "\x1bOC" }, // Right
        .{ 105, "\x1b[D", "\x1bOD" }, // Left
        .{ 102, "\x1b[H", "\x1bOH" }, // Home
        .{ 107, "\x1b[F", "\x1bOF" }, // End
        .{ 111, "\x1b[3~", "\x1b[3~" }, // Delete is unaffected.
    };
    for ([_]bool{ false, true, false }) |application_cursor| {
        keyboard.application_cursor = application_cursor;
        inline for (cases) |case| {
            const expected = if (application_cursor) case[2] else case[1];
            try std.testing.expectEqualStrings(expected, (try keyboard.key(case[0], true, &buffer)).?);
            try std.testing.expectEqual(@as(?[]const u8, null), try keyboard.key(case[0], false, &buffer));
        }
    }
}

test "XKB tracks modifier presses and releases" {
    var keyboard = try initWithNames(&.{ .layout = "us" });
    defer keyboard.deinit();
    var buffer: [5]u8 = undefined;

    // Evdev: left shift = 42, A = 30, left ctrl = 29, left alt = 56.
    try std.testing.expectEqual(@as(?[]const u8, null), try keyboard.key(42, true, &buffer));
    try std.testing.expectEqualStrings("A", (try keyboard.key(30, true, &buffer)).?);
    try std.testing.expectEqual(@as(?[]const u8, null), try keyboard.key(30, false, &buffer));
    _ = try keyboard.key(42, false, &buffer);
    try std.testing.expectEqualStrings("a", (try keyboard.key(30, true, &buffer)).?);
    _ = try keyboard.key(30, false, &buffer);
    _ = try keyboard.key(29, true, &buffer);
    _ = try keyboard.key(56, true, &buffer);
    try std.testing.expectEqualStrings("\x1b\x01", (try keyboard.key(30, true, &buffer)).?);
    _ = try keyboard.key(30, false, &buffer);
    _ = try keyboard.key(29, false, &buffer);
    _ = try keyboard.key(56, false, &buffer);
    try std.testing.expectEqualStrings("a", (try keyboard.key(30, true, &buffer)).?);
}
