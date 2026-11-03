const std = @import("std");
const linux = std.os.linux;
const libinput = @import("libinput");
const udev = @cImport({
    @cInclude("libudev.h");
});

pub const Keyboard = @import("input/keyboard.zig");

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
repeat: Repeat,
/// Borrowed libinput descriptor; poll for readability, but do not read or close it.
fd: c_int,

fn openRestricted(path: [*c]const u8, flags: c_int, user_data: ?*anyopaque) callconv(.c) c_int {
    _ = user_data;
    var open_flags: linux.O = @bitCast(flags);
    open_flags.CLOEXEC = true;
    const result = linux.open(@ptrCast(path), open_flags, 0);
    const err = linux.errno(result);
    // Linux syscalls return an unsigned representation of -errno on failure.
    if (err != .SUCCESS) return -@as(c_int, @intCast(@intFromEnum(err)));
    return @intCast(result);
}

fn closeRestricted(fd: c_int, user_data: ?*anyopaque) callconv(.c) void {
    _ = user_data;
    _ = linux.close(fd);
}

const interface = libinput.libinput_interface{
    .open_restricted = openRestricted,
    .close_restricted = closeRestricted,
};

pub fn init(repeat: Repeat) !Self {
    const ud = udev.udev_new() orelse return error.UdevInitFailed;
    defer _ = udev.udev_unref(ud);

    const context = libinput.libinput_udev_create_context(&interface, null, @ptrCast(ud)) orelse
        return error.LibinputInitFailed;
    errdefer _ = libinput.libinput_unref(context);

    if (libinput.libinput_udev_assign_seat(context, "seat0") != 0)
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

/// Dispatch and drain events until a key produces bytes, then emit a due
/// autorepeat, or return null if neither. now_ns uses the awake clock.
/// The returned slice aliases buffer. Five bytes suffice for every supported key.
/// BufferTooSmall consumes the key event, but still updates its modifier state.
pub fn next(self: *Self, now_ns: i96, buffer: []u8) !?[]const u8 {
    if (libinput.libinput_dispatch(self.context) != 0)
        return error.LibinputDispatchFailed;

    while (libinput.libinput_get_event(self.context)) |event| {
        defer libinput.libinput_event_destroy(event);
        if (libinput.libinput_event_get_type(event) != libinput.LIBINPUT_EVENT_KEYBOARD_KEY)
            continue;

        const key_event = libinput.libinput_event_get_keyboard_event(event);
        const pressed = libinput.libinput_event_keyboard_get_key_state(key_event) == libinput.LIBINPUT_KEY_STATE_PRESSED;
        const count = libinput.libinput_event_keyboard_get_seat_key_count(key_event);
        // XKB sees one logical keyboard, even when the seat has several devices.
        if ((pressed and count != 1) or (!pressed and count != 0)) continue;

        const key = libinput.libinput_event_keyboard_get_key(key_event);
        if (!pressed) {
            self.repeat.release(key);
        } else if (self.keyboard.repeats(key)) {
            self.repeat.press(key, now_ns);
        }
        if (try self.keyboard.key(key, pressed, buffer)) |bytes| return bytes;
    }
    if (self.repeat.due(now_ns)) |key| return self.keyboard.repeat(key, buffer);
    return null;
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

test "restricted open reports negative errno and sets CLOEXEC" {
    try std.testing.expectEqual(-@as(c_int, @intFromEnum(linux.E.NOENT)), openRestricted("/dev/apparition-nonexistent-input-device", 0, null));
    const device = openRestricted("/dev/null", 0, null);
    try std.testing.expect(device >= 0);
    defer closeRestricted(device, null);
    const flags = linux.fcntl(device, linux.F.GETFD, 0);
    try std.testing.expect(linux.errno(flags) == .SUCCESS);
    try std.testing.expect(flags & 1 != 0); // FD_CLOEXEC
}

test "input API compiles" {
    std.testing.refAllDecls(Self);
}
