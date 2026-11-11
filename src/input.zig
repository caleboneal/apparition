const std = @import("std");
const linux = std.os.linux;
const libinput = @import("libinput");
const udev = @import("libudev");
const evdev = @import("evdev");
const vt = @import("ghostty-vt").input;

pub const Keyboard = @import("input/keyboard.zig");
pub const Mouse = @import("input/mouse.zig");
const Seat = @import("seat.zig");

const Self = @This();

/// Software autorepeat, since libinput reports only physical presses and releases.
pub const Repeat = struct {
    delay_ns: u64,
    /// Zero disables autorepeat.
    interval_ns: u64,
    key: ?u32 = null,
    next_ns: i96 = 0,

    pub fn init(delay_ms: u32, rate_hz: u32) Repeat {
        return .{
            .delay_ns = @as(u64, delay_ms) * std.time.ns_per_ms,
            .interval_ns = if (rate_hz == 0) 0 else std.time.ns_per_s / rate_hz,
        };
    }

    /// A new repeating key replaces any key already repeating.
    fn press(self: *Repeat, key: u32, now_ns: i96) void {
        if (self.interval_ns == 0) return;
        self.key = key;
        self.next_ns = now_ns + self.delay_ns;
    }

    fn release(self: *Repeat, key: u32) void {
        if (self.key == key) self.key = null;
    }

    /// Return the held key once per elapsed interval, without bursting to catch up.
    fn due(self: *Repeat, now_ns: i96) ?u32 {
        const key = self.key orelse return null;
        if (now_ns < self.next_ns) return null;
        self.next_ns += self.interval_ns;
        if (self.next_ns <= now_ns) self.next_ns = now_ns + self.interval_ns;
        return key;
    }

    /// Milliseconds until the next repeat, or null when no key is repeating.
    pub fn timeoutMs(self: Repeat, now_ns: i96) ?c_int {
        if (self.key == null) return null;
        const remaining = self.next_ns - now_ns;
        if (remaining <= 0) return 0;
        // Round up so sub-millisecond waits do not become busy polling.
        const ms = @divTrunc(remaining + std.time.ns_per_ms - 1, std.time.ns_per_ms);
        return @intCast(@min(std.math.maxInt(c_int), ms));
    }
};

context: *libinput.libinput,
keyboard: Keyboard,
mouse: Mouse = .{},
repeat: Repeat,
/// Held keys whose press scrolled or switched VTs, so their releases are
/// not reported to the application either.
claimed: std.StaticBitSet(key_count) = .empty,
/// Borrowed libinput descriptor; poll for readability, but do not read or close it.
fd: c_int,

/// Evdev key codes run through KEY_MAX (0x2ff).
const key_count = 0x300;

/// libinput returns -errno on failure.
fn openRestricted(path: [*c]const u8, flags: c_int, user_data: ?*anyopaque) callconv(.c) c_int {
    const seat: *Seat = @ptrCast(@alignCast(user_data.?));
    const fd = seat.openDevice(path) catch |err| return switch (err) {
        error.OutOfMemory => -@as(c_int, @intFromEnum(linux.E.NOMEM)),
        error.DeviceUnavailable => if (std.c._errno().* > 0) -std.c._errno().* else -@as(c_int, @intFromEnum(linux.E.IO)),
    };
    // Seat providers do not apply open flags, and libinput reads nonblocking.
    const requested: linux.O = @bitCast(flags);
    if (requested.NONBLOCK) {
        const status = linux.fcntl(fd, linux.F.GETFL, 0);
        if (linux.errno(status) == .SUCCESS)
            _ = linux.fcntl(fd, linux.F.SETFL, status | @as(u32, @bitCast(linux.O{ .NONBLOCK = true })));
    }
    return fd;
}

fn closeRestricted(fd: c_int, user_data: ?*anyopaque) callconv(.c) void {
    const seat: *Seat = @ptrCast(@alignCast(user_data.?));
    seat.closeDevice(fd);
}

const interface = libinput.libinput_interface{
    .open_restricted = openRestricted,
    .close_restricted = closeRestricted,
};

/// The seat must outlive the returned input.
pub fn init(seat: *Seat, repeat: Repeat) !Self {
    const ud = udev.udev_new() orelse return error.UdevInitFailed;
    defer _ = udev.udev_unref(ud);

    const context = libinput.libinput_udev_create_context(&interface, seat, @ptrCast(ud)) orelse
        return error.LibinputInitFailed;
    errdefer _ = libinput.libinput_unref(context);

    if (libinput.libinput_udev_assign_seat(context, seat.name()) != 0)
        return error.SeatAssignmentFailed;

    return .{
        .context = context,
        .keyboard = try Keyboard.init(),
        .repeat = repeat,
        .fd = libinput.libinput_get_fd(context),
    };
}

pub fn deinit(self: *Self) void {
    self.keyboard.deinit();
    _ = libinput.libinput_unref(self.context);
}

/// Close input devices while another VT owns the seat. libinput synthesizes
/// releases for held keys and buttons, which are applied now so they do not stick.
pub fn deactivate(self: *Self) !void {
    libinput.libinput_suspend(self.context);
    var discard: [max_key_bytes]u8 = undefined;
    while (try self.next(0, &discard)) |_| {}
    self.repeat.key = null;
    self.claimed = .empty;
    self.mouse.clear();
}

/// Reopen input devices after returning to this VT.
pub fn activate(self: *Self) !void {
    if (libinput.libinput_resume(self.context) != 0) return error.LibinputResumeFailed;
}

pub const Event = union(enum) {
    /// Aliases the buffer passed to next.
    bytes: []const u8,
    /// A key combination such as Ctrl+Alt+F2 requested this VT number.
    switch_vt: u8,
    /// A key combination such as Shift+PageUp requested moving the viewport.
    scroll: Keyboard.Scroll,
    /// Wheel or touchpad movement of the viewport, in lines. Positive moves
    /// toward newer lines.
    scroll_lines: isize,
};

/// A buffer this large holds any single key's encoding, including kitty
/// protocol reports with associated text, and several mouse reports.
pub const max_key_bytes = 128;

/// Dispatch and drain events until a key or pointer produces bytes or an
/// action, then emit a due autorepeat, or return null if none. now_ns uses
/// the awake clock. BufferTooSmall consumes the key or pointer event, but
/// still updates its modifier or button state.
pub fn next(self: *Self, now_ns: i96, buffer: []u8) !?Event {
    // Finish a scroll that did not fit in the previous buffer before reading
    // anything newer, so clicks stay in order.
    if (try self.mouseEffect(buffer)) |effect| return effect;

    if (libinput.libinput_dispatch(self.context) != 0)
        return error.LibinputDispatchFailed;

    while (libinput.libinput_get_event(self.context)) |event| {
        defer libinput.libinput_event_destroy(event);
        const kind: c_int = @intCast(libinput.libinput_event_get_type(event));
        if (kind == libinput.LIBINPUT_EVENT_KEYBOARD_KEY) {
            if (try self.handleKey(event, now_ns, buffer)) |effect| return effect;
        } else if (isPointer(kind)) {
            self.handlePointer(event, kind);
            if (try self.mouseEffect(buffer)) |effect| return effect;
        }
    }
    if (self.repeat.due(now_ns)) |key| {
        if (self.keyboard.scrollAction(key)) |scroll| return .{ .scroll = scroll };
        if (self.isClaimed(key)) return null;
        if (try self.keyboard.encode(key, .repeat, buffer)) |bytes| return .{ .bytes = bytes };
    }
    return null;
}

fn mouseEffect(self: *Self, buffer: []u8) !?Event {
    const effect = (try self.mouse.emit(self.keyboard.heldModifiers(), buffer)) orelse return null;
    return switch (effect) {
        .bytes => |bytes| .{ .bytes = bytes },
        .scroll_lines => |lines| .{ .scroll_lines = lines },
    };
}

fn handleKey(self: *Self, event: *libinput.struct_libinput_event, now_ns: i96, buffer: []u8) !?Event {
    const key_event = libinput.libinput_event_get_keyboard_event(event);
    const pressed = libinput.libinput_event_keyboard_get_key_state(key_event) == libinput.LIBINPUT_KEY_STATE_PRESSED;
    const count = libinput.libinput_event_keyboard_get_seat_key_count(key_event);
    // XKB sees one logical keyboard, even when the seat has several devices.
    if ((pressed and count != 1) or (!pressed and count != 0)) return null;

    const key = libinput.libinput_event_keyboard_get_key(key_event);
    const claimable = key < key_count;
    if (!pressed) {
        self.repeat.release(key);
        if (self.isClaimed(key)) {
            self.claimed.unset(key);
            self.keyboard.update(key, false);
            return null;
        }
        const bytes = self.keyboard.encode(key, .release, buffer);
        self.keyboard.update(key, false);
        if (try bytes) |b| return .{ .bytes = b };
        return null;
    }
    self.keyboard.update(key, true);
    if (self.keyboard.switchTarget(key)) |number| {
        self.repeat.key = null;
        if (claimable) self.claimed.set(key);
        return .{ .switch_vt = number };
    }
    if (self.keyboard.repeats(key)) self.repeat.press(key, now_ns);
    if (self.keyboard.scrollAction(key)) |scroll| {
        if (claimable) self.claimed.set(key);
        return .{ .scroll = scroll };
    }
    if (try self.keyboard.encode(key, .press, buffer)) |b| return .{ .bytes = b };
    return null;
}

fn isPointer(kind: c_int) bool {
    return kind == libinput.LIBINPUT_EVENT_POINTER_MOTION or
        kind == libinput.LIBINPUT_EVENT_POINTER_MOTION_ABSOLUTE or
        kind == libinput.LIBINPUT_EVENT_POINTER_BUTTON or
        kind == libinput.LIBINPUT_EVENT_POINTER_SCROLL_WHEEL or
        kind == libinput.LIBINPUT_EVENT_POINTER_SCROLL_FINGER or
        kind == libinput.LIBINPUT_EVENT_POINTER_SCROLL_CONTINUOUS;
}

fn handlePointer(self: *Self, event: *libinput.struct_libinput_event, kind: c_int) void {
    const pointer = libinput.libinput_event_get_pointer_event(event) orelse return;
    switch (kind) {
        libinput.LIBINPUT_EVENT_POINTER_MOTION => self.mouse.moveBy(
            libinput.libinput_event_pointer_get_dx(pointer),
            libinput.libinput_event_pointer_get_dy(pointer),
        ),
        libinput.LIBINPUT_EVENT_POINTER_MOTION_ABSOLUTE => {
            const width = self.mouse.grid.screen_width;
            const height = self.mouse.grid.screen_height;
            if (width == 0 or height == 0) return;
            self.mouse.moveTo(
                libinput.libinput_event_pointer_get_absolute_x_transformed(pointer, width),
                libinput.libinput_event_pointer_get_absolute_y_transformed(pointer, height),
            );
        },
        libinput.LIBINPUT_EVENT_POINTER_BUTTON => {
            const pressed = libinput.libinput_event_pointer_get_button_state(pointer) == libinput.LIBINPUT_BUTTON_STATE_PRESSED;
            const count = libinput.libinput_event_pointer_get_seat_button_count(pointer);
            // One logical button, even when several devices share the seat.
            if ((pressed and count != 1) or (!pressed and count != 0)) return;
            const button = pointerButton(libinput.libinput_event_pointer_get_button(pointer)) orelse return;
            self.mouse.setButton(button, pressed);
        },
        libinput.LIBINPUT_EVENT_POINTER_SCROLL_WHEEL => self.mouse.addWheel(
            scrollAmount(pointer, libinput.LIBINPUT_POINTER_AXIS_SCROLL_VERTICAL, true),
            scrollAmount(pointer, libinput.LIBINPUT_POINTER_AXIS_SCROLL_HORIZONTAL, true),
        ),
        libinput.LIBINPUT_EVENT_POINTER_SCROLL_FINGER,
        libinput.LIBINPUT_EVENT_POINTER_SCROLL_CONTINUOUS,
        => self.mouse.addPan(
            scrollAmount(pointer, libinput.LIBINPUT_POINTER_AXIS_SCROLL_VERTICAL, false),
            scrollAmount(pointer, libinput.LIBINPUT_POINTER_AXIS_SCROLL_HORIZONTAL, false),
        ),
        else => {},
    }
}

fn scrollAmount(event: *libinput.struct_libinput_event_pointer, axis: c_int, wheel: bool) f64 {
    const which: libinput.libinput_pointer_axis = @intCast(axis);
    if (libinput.libinput_event_pointer_has_axis(event, which) == 0) return 0;
    // v120 is one logical wheel click per 120 units. Finger and continuous
    // scrolls use the same pixel scale as pointer motion.
    return if (wheel)
        libinput.libinput_event_pointer_get_scroll_value_v120(event, which)
    else
        libinput.libinput_event_pointer_get_scroll_value(event, which);
}

fn pointerButton(code: u32) ?vt.MouseButton {
    return switch (code) {
        @as(u32, @intCast(evdev.BTN_LEFT)) => .left,
        @as(u32, @intCast(evdev.BTN_RIGHT)) => .right,
        @as(u32, @intCast(evdev.BTN_MIDDLE)) => .middle,
        @as(u32, @intCast(evdev.BTN_SIDE)), @as(u32, @intCast(evdev.BTN_BACK)) => .eight,
        @as(u32, @intCast(evdev.BTN_EXTRA)), @as(u32, @intCast(evdev.BTN_FORWARD)) => .nine,
        @as(u32, @intCast(evdev.BTN_TASK)) => .ten,
        else => null,
    };
}

fn isClaimed(self: *const Self, key: u32) bool {
    return key < key_count and self.claimed.isSet(key);
}

test "repeat waits for the delay, then follows the rate without bursting" {
    const ms = std.time.ns_per_ms;
    var repeat = Repeat.init(600, 25);
    try std.testing.expectEqual(@as(u64, 40 * ms), repeat.interval_ns);
    try std.testing.expectEqual(@as(?c_int, null), repeat.timeoutMs(0));
    try std.testing.expectEqual(@as(?u32, null), repeat.due(0));

    repeat.press(30, 0);
    try std.testing.expectEqual(@as(?c_int, 600), repeat.timeoutMs(0));
    try std.testing.expectEqual(@as(?c_int, 1), repeat.timeoutMs(600 * ms - 1));
    try std.testing.expectEqual(@as(?u32, null), repeat.due(600 * ms - 1));
    try std.testing.expectEqual(@as(?u32, 30), repeat.due(600 * ms + 5 * ms));
    // Late wakeups keep the original cadence.
    try std.testing.expectEqual(@as(?c_int, 35), repeat.timeoutMs(605 * ms));
    try std.testing.expectEqual(@as(?u32, null), repeat.due(605 * ms));
    try std.testing.expectEqual(@as(?u32, 30), repeat.due(640 * ms));

    // A stall emits one repeat and schedules from now.
    try std.testing.expectEqual(@as(?u32, 30), repeat.due(2000 * ms));
    try std.testing.expectEqual(@as(?u32, null), repeat.due(2000 * ms));
    try std.testing.expectEqual(@as(?c_int, 40), repeat.timeoutMs(2000 * ms));

    // Releasing another key does not stop the newest repeating key.
    repeat.press(31, 2000 * ms);
    repeat.release(30);
    try std.testing.expectEqual(@as(?c_int, 600), repeat.timeoutMs(2000 * ms));
    repeat.release(31);
    try std.testing.expectEqual(@as(?c_int, null), repeat.timeoutMs(2000 * ms));
    try std.testing.expectEqual(@as(?u32, null), repeat.due(9000 * ms));
}

test "zero repeat rate disables autorepeat" {
    var repeat = Repeat.init(600, 0);
    repeat.press(30, 0);
    try std.testing.expectEqual(@as(?c_int, null), repeat.timeoutMs(0));
    try std.testing.expectEqual(@as(?u32, null), repeat.due(std.time.ns_per_s));
}

test "input API compiles" {
    std.testing.refAllDecls(Self);
}
