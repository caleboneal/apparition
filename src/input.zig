const std = @import("std");
const linux = std.os.linux;
const libinput = @import("libinput");
const udev = @cImport({
    @cInclude("libudev.h");
});

pub const Keyboard = @import("input/keyboard.zig");

const Self = @This();

context: *libinput.libinput,
keyboard: Keyboard,
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

pub fn init() !Self {
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
        .fd = libinput.libinput_get_fd(context),
    };
}

pub fn deinit(self: *Self) void {
    self.keyboard.deinit();
    _ = libinput.libinput_unref(self.context);
}

/// Dispatch and drain events until a key produces bytes, or return null if empty.
/// The returned slice aliases buffer. Five bytes suffice for every supported key.
/// BufferTooSmall consumes the key event, but still updates its modifier state.
pub fn next(self: *Self, buffer: []u8) !?[]const u8 {
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
        if (try self.keyboard.key(key, pressed, buffer)) |bytes| return bytes;
    }
    return null;
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
