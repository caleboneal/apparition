const std = @import("std");
const vt = @import("ghostty-vt").input;
const xkb = @import("xkbcommon");
const evdev = @import("evdev");

const Self = @This();

context: *xkb.xkb_context,
keymap: *xkb.xkb_keymap,
state: *xkb.xkb_state,
/// Terminal modes that shape encoding, such as application cursor keys and
/// the kitty keyboard protocol. Defaults match a freshly reset terminal.
options: vt.KeyEncodeOptions = .{ .alt_esc_prefix = true, .ignore_keypad_with_numlock = true },
/// Whether the active screen keeps history. Without it, scroll keys reach the application.
scrollback: bool = true,

pub const Scroll = enum { page_up, page_down, top, bottom };

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

/// Apply an evdev key press or release to XKB's modifier and layout state.
/// Encode presses after updating and releases before, so each event carries
/// the modifiers held while it happened.
pub fn update(self: *Self, evdev_key: u32, pressed: bool) void {
    _ = xkb.xkb_state_update_key(self.state, xkbCode(evdev_key), if (pressed) xkb.XKB_KEY_DOWN else xkb.XKB_KEY_UP);
}

/// Encode a key event with the current modifiers, or null when the
/// terminal sends nothing for it, as for releases outside the kitty protocol.
pub fn encode(self: *Self, evdev_key: u32, action: vt.KeyAction, buffer: []u8) !?[]const u8 {
    const code = xkbCode(evdev_key);
    const sym = xkb.xkb_state_key_get_one_sym(self.state, code);
    var text: [4]u8 = undefined;
    const event: vt.KeyEvent = .{
        .action = action,
        .key = remap(physicalKey(evdev_key), sym),
        .mods = .{
            .shift = self.modActive(xkb.XKB_MOD_NAME_SHIFT),
            .ctrl = self.modActive(xkb.XKB_MOD_NAME_CTRL),
            .alt = self.modActive(xkb.XKB_MOD_NAME_ALT),
            .super = self.modActive(xkb.XKB_MOD_NAME_LOGO),
            .caps_lock = self.modActive(xkb.XKB_MOD_NAME_CAPS),
            .num_lock = self.modActive(xkb.XKB_MOD_NAME_NUM),
        },
        .consumed_mods = .{
            .shift = self.modConsumed(code, xkb.XKB_MOD_NAME_SHIFT),
            .ctrl = self.modConsumed(code, xkb.XKB_MOD_NAME_CTRL),
            .alt = self.modConsumed(code, xkb.XKB_MOD_NAME_ALT),
            .super = self.modConsumed(code, xkb.XKB_MOD_NAME_LOGO),
        },
        // The encoder derives control characters itself.
        .utf8 = text[0..printable(xkb.xkb_keysym_to_utf32(sym), &text)],
        .unshifted_codepoint = self.unshifted(code),
    };
    var writer = std.Io.Writer.fixed(buffer);
    if (self.legacyControl(event)) |byte| {
        const mods = event.mods.binding();
        if (mods.alt) writer.writeByte(0x1b) catch return error.BufferTooSmall;
        writer.writeByte(byte) catch return error.BufferTooSmall;
        return writer.buffered();
    }
    vt.encodeKey(&writer, event, self.options) catch return error.BufferTooSmall;
    const bytes = writer.buffered();
    return if (bytes.len == 0) null else bytes;
}

/// The VT a pressed key requests, such as Ctrl+Alt+F2 in the default keymap.
pub fn switchTarget(self: *Self, evdev_key: u32) ?u8 {
    const sym = xkb.xkb_state_key_get_one_sym(self.state, xkbCode(evdev_key));
    if (sym < xkb.XKB_KEY_XF86Switch_VT_1 or sym > xkb.XKB_KEY_XF86Switch_VT_12) return null;
    return @intCast(sym - xkb.XKB_KEY_XF86Switch_VT_1 + 1);
}

/// Shift+PageUp/PageDown/Home/End scroll history instead of reaching the application.
pub fn scrollAction(self: *Self, evdev_key: u32) ?Scroll {
    if (!self.scrollback or !self.modActive(xkb.XKB_MOD_NAME_SHIFT) or
        self.modActive(xkb.XKB_MOD_NAME_CTRL) or self.modActive(xkb.XKB_MOD_NAME_ALT)) return null;
    return switch (xkb.xkb_state_key_get_one_sym(self.state, xkbCode(evdev_key))) {
        xkb.XKB_KEY_Page_Up => .page_up,
        xkb.XKB_KEY_Page_Down => .page_down,
        xkb.XKB_KEY_Home => .top,
        xkb.XKB_KEY_End => .bottom,
        else => null,
    };
}

/// Whether the keymap lets this key auto-repeat; modifiers and locks do not.
pub fn repeats(self: *Self, evdev_key: u32) bool {
    return xkb.xkb_keymap_key_repeats(self.keymap, xkbCode(evdev_key)) != 0;
}

fn xkbCode(evdev_key: u32) xkb.xkb_keycode_t {
    // XKB's evdev keymap reserves the first eight keycodes.
    return evdev_key + 8;
}

/// Modifiers held now, for mouse reports as well as key encoding.
pub fn heldModifiers(self: *const Self) vt.KeyMods {
    return .{
        .shift = self.modActive(xkb.XKB_MOD_NAME_SHIFT),
        .ctrl = self.modActive(xkb.XKB_MOD_NAME_CTRL),
        .alt = self.modActive(xkb.XKB_MOD_NAME_ALT),
        .super = self.modActive(xkb.XKB_MOD_NAME_LOGO),
        .caps_lock = self.modActive(xkb.XKB_MOD_NAME_CAPS),
        .num_lock = self.modActive(xkb.XKB_MOD_NAME_NUM),
    };
}

fn modActive(self: *const Self, name: [*:0]const u8) bool {
    return xkb.xkb_state_mod_name_is_active(self.state, name, xkb.XKB_STATE_MODS_EFFECTIVE) > 0;
}

fn modConsumed(self: *Self, code: xkb.xkb_keycode_t, name: [*:0]const u8) bool {
    const index = xkb.xkb_keymap_mod_get_index(self.keymap, name);
    if (index == xkb.XKB_MOD_INVALID) return false;
    return xkb.xkb_state_mod_index_is_consumed(self.state, code, index) > 0;
}

/// The key's character in the active layout without modifiers, which the
/// kitty protocol reports as the key's identity.
fn unshifted(self: *Self, code: xkb.xkb_keycode_t) u21 {
    const layout = xkb.xkb_state_key_get_layout(self.state, code);
    if (layout == xkb.XKB_LAYOUT_INVALID) return 0;
    var syms: [*c]const xkb.xkb_keysym_t = undefined;
    if (xkb.xkb_keymap_key_get_syms_by_level(self.keymap, code, layout, 0, &syms) != 1) return 0;
    return std.math.cast(u21, xkb.xkb_keysym_to_utf32(syms[0])) orelse 0;
}

/// Ghostty follows fixterms and reports Ctrl+[, Ctrl+I, and Ctrl+M as CSI u,
/// which shells without CSI u support misread. Outside the kitty protocol
/// and modifyOtherKeys, send ESC, Tab, and CR like the Linux console.
fn legacyControl(self: *const Self, event: vt.KeyEvent) ?u8 {
    if (self.options.kitty_flags.int() != 0 or self.options.modify_other_keys_state_2) return null;
    if (event.action == .release or event.utf8.len != 1) return null;
    const mods = event.mods.binding();
    if (!mods.ctrl or mods.shift or mods.super) return null;
    return switch (std.ascii.toLower(event.utf8[0])) {
        '[' => 0x1b,
        'i' => '\t',
        'm' => '\r',
        else => null,
    };
}

/// Encode a printable codepoint into text, returning its length, or 0 for
/// control characters and invalid codepoints.
fn printable(codepoint: u32, text: *[4]u8) usize {
    if (codepoint < 0x20 or codepoint == 0x7f) return 0;
    const scalar = std.math.cast(u21, codepoint) orelse return 0;
    return std.unicode.utf8Encode(scalar, text) catch 0;
}

/// Choose between the physical key and the layout's key like Ghostty's GTK
/// frontend: letters, digits, and punctuation keep their physical position
/// so Ctrl shortcuts work on any layout, while remaps such as Caps Lock to
/// Escape apply.
fn remap(physical: vt.Key, sym: xkb.xkb_keysym_t) vt.Key {
    if (keysymKey(sym)) |logical| {
        if (writingKey(physical) and writingKey(logical)) return physical;
        return logical;
    }
    return switch (sym) {
        // Level and group switches have no key of their own; reporting the
        // physical key would send an unrelated key.
        xkb.XKB_KEY_Shift_Lock,
        xkb.XKB_KEY_Meta_L,
        xkb.XKB_KEY_Meta_R,
        xkb.XKB_KEY_Hyper_L,
        xkb.XKB_KEY_Hyper_R,
        xkb.XKB_KEY_Mode_switch,
        xkb.XKB_KEY_ISO_Lock,
        xkb.XKB_KEY_ISO_Level2_Latch,
        xkb.XKB_KEY_ISO_Level3_Shift,
        xkb.XKB_KEY_ISO_Level3_Latch,
        xkb.XKB_KEY_ISO_Level3_Lock,
        xkb.XKB_KEY_ISO_Level5_Shift,
        xkb.XKB_KEY_ISO_Level5_Latch,
        xkb.XKB_KEY_ISO_Level5_Lock,
        xkb.XKB_KEY_ISO_Group_Latch,
        xkb.XKB_KEY_ISO_Group_Lock,
        => .unidentified,
        else => physical,
    };
}

/// The W3C "writing system keys", whose meaning depends on the layout.
fn writingKey(key: vt.Key) bool {
    return @intFromEnum(key) >= @intFromEnum(vt.Key.backquote) and @intFromEnum(key) <= @intFromEnum(vt.Key.slash);
}

fn offsetKey(first: vt.Key, offset: u32) vt.Key {
    return @enumFromInt(@intFromEnum(first) + @as(c_int, @intCast(offset)));
}

fn keysymKey(sym: xkb.xkb_keysym_t) ?vt.Key {
    return switch (sym) {
        xkb.XKB_KEY_a...xkb.XKB_KEY_z => offsetKey(.key_a, sym - xkb.XKB_KEY_a),
        xkb.XKB_KEY_0...xkb.XKB_KEY_9 => offsetKey(.digit_0, sym - xkb.XKB_KEY_0),
        xkb.XKB_KEY_F1...xkb.XKB_KEY_F25 => offsetKey(.f1, sym - xkb.XKB_KEY_F1),
        xkb.XKB_KEY_KP_0...xkb.XKB_KEY_KP_9 => offsetKey(.numpad_0, sym - xkb.XKB_KEY_KP_0),
        xkb.XKB_KEY_semicolon => .semicolon,
        xkb.XKB_KEY_space => .space,
        xkb.XKB_KEY_apostrophe => .quote,
        xkb.XKB_KEY_comma => .comma,
        xkb.XKB_KEY_grave => .backquote,
        xkb.XKB_KEY_period => .period,
        xkb.XKB_KEY_slash => .slash,
        xkb.XKB_KEY_minus => .minus,
        xkb.XKB_KEY_equal => .equal,
        xkb.XKB_KEY_bracketleft => .bracket_left,
        xkb.XKB_KEY_bracketright => .bracket_right,
        xkb.XKB_KEY_backslash => .backslash,
        xkb.XKB_KEY_Up => .arrow_up,
        xkb.XKB_KEY_Down => .arrow_down,
        xkb.XKB_KEY_Right => .arrow_right,
        xkb.XKB_KEY_Left => .arrow_left,
        xkb.XKB_KEY_Home => .home,
        xkb.XKB_KEY_End => .end,
        xkb.XKB_KEY_Insert => .insert,
        xkb.XKB_KEY_Delete => .delete,
        xkb.XKB_KEY_Caps_Lock => .caps_lock,
        xkb.XKB_KEY_Scroll_Lock => .scroll_lock,
        xkb.XKB_KEY_Num_Lock => .num_lock,
        xkb.XKB_KEY_Page_Up => .page_up,
        xkb.XKB_KEY_Page_Down => .page_down,
        xkb.XKB_KEY_Escape => .escape,
        xkb.XKB_KEY_Return => .enter,
        xkb.XKB_KEY_Tab => .tab,
        xkb.XKB_KEY_BackSpace => .backspace,
        xkb.XKB_KEY_Print => .print_screen,
        xkb.XKB_KEY_Pause => .pause,
        xkb.XKB_KEY_Menu => .context_menu,
        xkb.XKB_KEY_KP_Decimal => .numpad_decimal,
        xkb.XKB_KEY_KP_Divide => .numpad_divide,
        xkb.XKB_KEY_KP_Multiply => .numpad_multiply,
        xkb.XKB_KEY_KP_Subtract => .numpad_subtract,
        xkb.XKB_KEY_KP_Add => .numpad_add,
        xkb.XKB_KEY_KP_Enter => .numpad_enter,
        xkb.XKB_KEY_KP_Equal => .numpad_equal,
        xkb.XKB_KEY_KP_Separator => .numpad_separator,
        xkb.XKB_KEY_KP_Left => .numpad_left,
        xkb.XKB_KEY_KP_Right => .numpad_right,
        xkb.XKB_KEY_KP_Up => .numpad_up,
        xkb.XKB_KEY_KP_Down => .numpad_down,
        xkb.XKB_KEY_KP_Page_Up => .numpad_page_up,
        xkb.XKB_KEY_KP_Page_Down => .numpad_page_down,
        xkb.XKB_KEY_KP_Home => .numpad_home,
        xkb.XKB_KEY_KP_End => .numpad_end,
        xkb.XKB_KEY_KP_Insert => .numpad_insert,
        xkb.XKB_KEY_KP_Delete => .numpad_delete,
        xkb.XKB_KEY_KP_Begin => .numpad_begin,
        xkb.XKB_KEY_Shift_L => .shift_left,
        xkb.XKB_KEY_Control_L => .control_left,
        xkb.XKB_KEY_Alt_L => .alt_left,
        xkb.XKB_KEY_Super_L => .meta_left,
        xkb.XKB_KEY_Shift_R => .shift_right,
        xkb.XKB_KEY_Control_R => .control_right,
        xkb.XKB_KEY_Alt_R => .alt_right,
        xkb.XKB_KEY_Super_R => .meta_right,
        else => null,
    };
}

/// The key at an evdev code's position on a US keyboard.
fn physicalKey(code: u32) vt.Key {
    return switch (code) {
        evdev.KEY_GRAVE => .backquote,
        evdev.KEY_BACKSLASH => .backslash,
        evdev.KEY_LEFTBRACE => .bracket_left,
        evdev.KEY_RIGHTBRACE => .bracket_right,
        evdev.KEY_COMMA => .comma,
        evdev.KEY_0 => .digit_0,
        evdev.KEY_1...evdev.KEY_9 => offsetKey(.digit_1, code - evdev.KEY_1),
        evdev.KEY_EQUAL => .equal,
        evdev.KEY_102ND => .intl_backslash,
        evdev.KEY_RO => .intl_ro,
        evdev.KEY_YEN => .intl_yen,
        evdev.KEY_A => .key_a,
        evdev.KEY_B => .key_b,
        evdev.KEY_C => .key_c,
        evdev.KEY_D => .key_d,
        evdev.KEY_E => .key_e,
        evdev.KEY_F => .key_f,
        evdev.KEY_G => .key_g,
        evdev.KEY_H => .key_h,
        evdev.KEY_I => .key_i,
        evdev.KEY_J => .key_j,
        evdev.KEY_K => .key_k,
        evdev.KEY_L => .key_l,
        evdev.KEY_M => .key_m,
        evdev.KEY_N => .key_n,
        evdev.KEY_O => .key_o,
        evdev.KEY_P => .key_p,
        evdev.KEY_Q => .key_q,
        evdev.KEY_R => .key_r,
        evdev.KEY_S => .key_s,
        evdev.KEY_T => .key_t,
        evdev.KEY_U => .key_u,
        evdev.KEY_V => .key_v,
        evdev.KEY_W => .key_w,
        evdev.KEY_X => .key_x,
        evdev.KEY_Y => .key_y,
        evdev.KEY_Z => .key_z,
        evdev.KEY_MINUS => .minus,
        evdev.KEY_DOT => .period,
        evdev.KEY_APOSTROPHE => .quote,
        evdev.KEY_SEMICOLON => .semicolon,
        evdev.KEY_SLASH => .slash,
        evdev.KEY_LEFTALT => .alt_left,
        evdev.KEY_RIGHTALT => .alt_right,
        evdev.KEY_BACKSPACE => .backspace,
        evdev.KEY_CAPSLOCK => .caps_lock,
        evdev.KEY_COMPOSE => .context_menu,
        evdev.KEY_LEFTCTRL => .control_left,
        evdev.KEY_RIGHTCTRL => .control_right,
        evdev.KEY_ENTER => .enter,
        evdev.KEY_LEFTMETA => .meta_left,
        evdev.KEY_RIGHTMETA => .meta_right,
        evdev.KEY_LEFTSHIFT => .shift_left,
        evdev.KEY_RIGHTSHIFT => .shift_right,
        evdev.KEY_SPACE => .space,
        evdev.KEY_TAB => .tab,
        evdev.KEY_DELETE => .delete,
        evdev.KEY_END => .end,
        evdev.KEY_HOME => .home,
        evdev.KEY_INSERT => .insert,
        evdev.KEY_PAGEDOWN => .page_down,
        evdev.KEY_PAGEUP => .page_up,
        evdev.KEY_DOWN => .arrow_down,
        evdev.KEY_LEFT => .arrow_left,
        evdev.KEY_RIGHT => .arrow_right,
        evdev.KEY_UP => .arrow_up,
        evdev.KEY_NUMLOCK => .num_lock,
        evdev.KEY_KP0 => .numpad_0,
        evdev.KEY_KP1 => .numpad_1,
        evdev.KEY_KP2 => .numpad_2,
        evdev.KEY_KP3 => .numpad_3,
        evdev.KEY_KP4 => .numpad_4,
        evdev.KEY_KP5 => .numpad_5,
        evdev.KEY_KP6 => .numpad_6,
        evdev.KEY_KP7 => .numpad_7,
        evdev.KEY_KP8 => .numpad_8,
        evdev.KEY_KP9 => .numpad_9,
        evdev.KEY_KPPLUS => .numpad_add,
        evdev.KEY_KPCOMMA => .numpad_comma,
        evdev.KEY_KPDOT => .numpad_decimal,
        evdev.KEY_KPSLASH => .numpad_divide,
        evdev.KEY_KPENTER => .numpad_enter,
        evdev.KEY_KPEQUAL => .numpad_equal,
        evdev.KEY_KPASTERISK => .numpad_multiply,
        evdev.KEY_KPMINUS => .numpad_subtract,
        evdev.KEY_ESC => .escape,
        evdev.KEY_F1...evdev.KEY_F10 => offsetKey(.f1, code - evdev.KEY_F1),
        evdev.KEY_F11 => .f11,
        evdev.KEY_F12 => .f12,
        evdev.KEY_F13...evdev.KEY_F24 => offsetKey(.f13, code - evdev.KEY_F13),
        evdev.KEY_SYSRQ => .print_screen,
        evdev.KEY_SCROLLLOCK => .scroll_lock,
        evdev.KEY_PAUSE => .pause,
        else => .unidentified,
    };
}

// Evdev codes used by the tests below.
const KEY_A = evdev.KEY_A;
const KEY_C = evdev.KEY_C;
const KEY_LEFTSHIFT = evdev.KEY_LEFTSHIFT;
const KEY_LEFTCTRL = evdev.KEY_LEFTCTRL;
const KEY_LEFTALT = evdev.KEY_LEFTALT;

/// Press and release a key with modifiers held, returning the press's bytes.
fn testTap(keyboard: *Self, modifiers: []const u32, evdev_key: u32, buffer: []u8) !?[]const u8 {
    for (modifiers) |modifier| keyboard.update(modifier, true);
    defer for (modifiers) |modifier| keyboard.update(modifier, false);
    keyboard.update(evdev_key, true);
    defer keyboard.update(evdev_key, false);
    return keyboard.encode(evdev_key, .press, buffer);
}

test "legacy key encodings cover text, control, function, and modified keys" {
    var keyboard = try initWithNames(&.{ .layout = "us" });
    defer keyboard.deinit();
    const Case = struct { mods: []const u32 = &.{}, key: u32, expected: []const u8 };
    const shift = &[_]u32{KEY_LEFTSHIFT};
    const ctrl = &[_]u32{KEY_LEFTCTRL};
    const cases = [_]Case{
        .{ .key = KEY_A, .expected = "a" },
        .{ .mods = shift, .key = KEY_A, .expected = "A" },
        .{ .mods = ctrl, .key = KEY_C, .expected = "\x03" },
        .{ .mods = &.{ KEY_LEFTCTRL, KEY_LEFTALT }, .key = KEY_A, .expected = "\x1b\x01" },
        .{ .mods = &.{KEY_LEFTALT}, .key = KEY_A, .expected = "\x1ba" },
        .{ .mods = ctrl, .key = evdev.KEY_SPACE, .expected = "\x00" },
        .{ .mods = ctrl, .key = evdev.KEY_LEFTBRACE, .expected = "\x1b" },
        .{ .mods = ctrl, .key = evdev.KEY_I, .expected = "\t" },
        .{ .mods = &.{ KEY_LEFTCTRL, KEY_LEFTALT }, .key = evdev.KEY_M, .expected = "\x1b\r" },
        .{ .key = evdev.KEY_ENTER, .expected = "\r" },
        .{ .key = evdev.KEY_KPENTER, .expected = "\r" },
        .{ .key = evdev.KEY_BACKSPACE, .expected = "\x7f" },
        .{ .key = evdev.KEY_TAB, .expected = "\t" },
        .{ .mods = shift, .key = evdev.KEY_TAB, .expected = "\x1b[Z" },
        .{ .key = evdev.KEY_ESC, .expected = "\x1b" },
        .{ .key = evdev.KEY_UP, .expected = "\x1b[A" },
        .{ .key = evdev.KEY_HOME, .expected = "\x1b[H" },
        .{ .key = evdev.KEY_END, .expected = "\x1b[F" },
        .{ .key = evdev.KEY_INSERT, .expected = "\x1b[2~" },
        .{ .key = evdev.KEY_DELETE, .expected = "\x1b[3~" },
        .{ .key = evdev.KEY_PAGEUP, .expected = "\x1b[5~" },
        .{ .key = evdev.KEY_PAGEDOWN, .expected = "\x1b[6~" },
        .{ .key = evdev.KEY_F1, .expected = "\x1bOP" },
        .{ .key = evdev.KEY_F5, .expected = "\x1b[15~" },
        .{ .key = evdev.KEY_F12, .expected = "\x1b[24~" },
        .{ .mods = shift, .key = evdev.KEY_F1, .expected = "\x1b[1;2P" },
        .{ .mods = ctrl, .key = evdev.KEY_LEFT, .expected = "\x1b[1;5D" },
        .{ .mods = &.{KEY_LEFTALT}, .key = evdev.KEY_DELETE, .expected = "\x1b[3;3~" },
        // Keypad keys without Num Lock act as navigation keys.
        .{ .key = evdev.KEY_KP1, .expected = "\x1b[F" },
    };
    var buffer: [32]u8 = undefined;
    for (cases) |case| {
        const result = try testTap(&keyboard, case.mods, case.key, &buffer);
        std.testing.expectEqualStrings(case.expected, result orelse "") catch |err| {
            std.debug.print("evdev key {d} with {any}\n", .{ case.key, case.mods });
            return err;
        };
    }
    // Lone modifiers send nothing.
    try std.testing.expectEqual(@as(?[]const u8, null), try testTap(&keyboard, &.{}, KEY_LEFTSHIFT, &buffer));
    try std.testing.expectError(error.BufferTooSmall, testTap(&keyboard, &.{}, evdev.KEY_F5, buffer[0..4]));
}

test "terminal modes switch cursor, keypad, and backspace encodings" {
    var keyboard = try initWithNames(&.{ .layout = "us" });
    defer keyboard.deinit();
    var buffer: [32]u8 = undefined;
    keyboard.options.cursor_key_application = true;
    try std.testing.expectEqualStrings("\x1bOA", (try testTap(&keyboard, &.{}, evdev.KEY_UP, &buffer)).?);
    try std.testing.expectEqualStrings("\x1bOH", (try testTap(&keyboard, &.{}, evdev.KEY_HOME, &buffer)).?);
    try std.testing.expectEqualStrings("\x1b[3~", (try testTap(&keyboard, &.{}, evdev.KEY_DELETE, &buffer)).?);
    keyboard.options.backarrow_key_mode = true;
    try std.testing.expectEqualStrings("\x08", (try testTap(&keyboard, &.{}, evdev.KEY_BACKSPACE, &buffer)).?);

    // Num Lock types digits until the application asks for keypad codes.
    _ = try testTap(&keyboard, &.{}, evdev.KEY_NUMLOCK, &buffer);
    try std.testing.expectEqualStrings("1", (try testTap(&keyboard, &.{}, evdev.KEY_KP1, &buffer)).?);
    keyboard.options.keypad_key_application = true;
    keyboard.options.ignore_keypad_with_numlock = false;
    try std.testing.expectEqualStrings("\x1bOq", (try testTap(&keyboard, &.{}, evdev.KEY_KP1, &buffer)).?);
}

test "kitty keyboard protocol reports disambiguated keys and releases" {
    var keyboard = try initWithNames(&.{ .layout = "us" });
    defer keyboard.deinit();
    var buffer: [32]u8 = undefined;
    keyboard.options.kitty_flags = .{ .disambiguate = true };
    try std.testing.expectEqualStrings("a", (try testTap(&keyboard, &.{}, KEY_A, &buffer)).?);
    try std.testing.expectEqualStrings("\x1b[97;5u", (try testTap(&keyboard, &.{KEY_LEFTCTRL}, KEY_A, &buffer)).?);
    try std.testing.expectEqualStrings("\x1b[27u", (try testTap(&keyboard, &.{}, evdev.KEY_ESC, &buffer)).?);
    try std.testing.expectEqualStrings("\x1b[91;5u", (try testTap(&keyboard, &.{KEY_LEFTCTRL}, evdev.KEY_LEFTBRACE, &buffer)).?);
    // Legacy and plain disambiguation never report releases.
    try std.testing.expectEqual(@as(?[]const u8, null), try keyboard.encode(KEY_A, .release, &buffer));

    keyboard.options.kitty_flags.report_events = true;
    keyboard.update(KEY_A, true);
    // Held text keys keep typing; their releases are reported.
    try std.testing.expectEqualStrings("a", (try keyboard.encode(KEY_A, .repeat, &buffer)).?);
    try std.testing.expectEqualStrings("\x1b[97;1:3u", (try keyboard.encode(KEY_A, .release, &buffer)).?);
    keyboard.update(KEY_A, false);
    keyboard.update(evdev.KEY_ESC, true);
    try std.testing.expectEqualStrings("\x1b[27;1:2u", (try keyboard.encode(evdev.KEY_ESC, .repeat, &buffer)).?);
    keyboard.update(evdev.KEY_ESC, false);
}

test "Ctrl shortcuts use the physical key on non-Latin layouts" {
    var keyboard = initWithNames(&.{ .layout = "ru" }) catch return error.SkipZigTest;
    defer keyboard.deinit();
    var buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings("с", (try testTap(&keyboard, &.{}, KEY_C, &buffer)).?);
    try std.testing.expectEqualStrings("\x03", (try testTap(&keyboard, &.{KEY_LEFTCTRL}, KEY_C, &buffer)).?);
}

test "Ctrl+Alt+function keys request VT switches" {
    var keyboard = try initWithNames(&.{ .layout = "us" });
    defer keyboard.deinit();

    keyboard.update(evdev.KEY_F2, true);
    try std.testing.expectEqual(@as(?u8, null), keyboard.switchTarget(evdev.KEY_F2));
    keyboard.update(evdev.KEY_F2, false);
    keyboard.update(KEY_LEFTCTRL, true);
    keyboard.update(KEY_LEFTALT, true);
    for ([_]u32{ evdev.KEY_F1, evdev.KEY_F2, evdev.KEY_F12 }, [_]u8{ 1, 2, 12 }) |evdev_key, number| {
        keyboard.update(evdev_key, true);
        try std.testing.expectEqual(@as(?u8, number), keyboard.switchTarget(evdev_key));
        keyboard.update(evdev_key, false);
    }
    try std.testing.expectEqual(@as(?u8, null), keyboard.switchTarget(KEY_A));
}

test "Shift+navigation keys scroll only when the screen has scrollback" {
    var keyboard = try initWithNames(&.{ .layout = "us" });
    defer keyboard.deinit();

    try std.testing.expectEqual(@as(?Scroll, null), keyboard.scrollAction(evdev.KEY_PAGEUP));
    keyboard.update(KEY_LEFTSHIFT, true);
    const keys = [_]u32{ evdev.KEY_PAGEUP, evdev.KEY_PAGEDOWN, evdev.KEY_HOME, evdev.KEY_END };
    for (keys, [_]Scroll{ .page_up, .page_down, .top, .bottom }) |evdev_key, action| {
        try std.testing.expectEqual(@as(?Scroll, action), keyboard.scrollAction(evdev_key));
    }
    try std.testing.expectEqual(@as(?Scroll, null), keyboard.scrollAction(KEY_A));
    keyboard.scrollback = false;
    try std.testing.expectEqual(@as(?Scroll, null), keyboard.scrollAction(evdev.KEY_PAGEUP));
    keyboard.scrollback = true;
    keyboard.update(KEY_LEFTCTRL, true);
    try std.testing.expectEqual(@as(?Scroll, null), keyboard.scrollAction(evdev.KEY_PAGEUP));
}

test "repeats re-encode held keys with current modifiers" {
    var keyboard = try initWithNames(&.{ .layout = "us" });
    defer keyboard.deinit();
    var buffer: [32]u8 = undefined;

    try std.testing.expect(keyboard.repeats(KEY_A));
    try std.testing.expect(keyboard.repeats(evdev.KEY_UP));
    try std.testing.expect(!keyboard.repeats(KEY_LEFTSHIFT));

    keyboard.update(KEY_A, true);
    try std.testing.expectEqualStrings("a", (try keyboard.encode(KEY_A, .repeat, &buffer)).?);
    keyboard.update(KEY_LEFTSHIFT, true);
    try std.testing.expectEqualStrings("A", (try keyboard.encode(KEY_A, .repeat, &buffer)).?);
}
