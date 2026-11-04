const std = @import("std");
const linux = std.os.linux;
const libseat = @import("libseat");
const log = std.log.scoped(.seat);

const Self = @This();

/// Seat state changes to apply. A disable must be acknowledged with disable
/// after giving up the display and input; an enable is applied with enable.
pub const Event = enum { disable, enable };

const Device = struct { fd: c_int, id: c_int };

const activate_timeout_ms = 10_000;

handle: *libseat.struct_libseat,
allocator: std.mem.Allocator,
/// libseat device IDs for the descriptors it opened.
devices: std.ArrayList(Device) = .empty,
/// Pollable libseat connection; call dispatch when it is readable.
fd: c_int,
/// Whether this process is currently using the seat's devices.
active: bool = false,
/// The latest state reported by the seat provider.
enabled: bool = false,
disable_pending: bool = false,

fn enableSeat(_: ?*libseat.struct_libseat, userdata: ?*anyopaque) callconv(.c) void {
    const self: *Self = @ptrCast(@alignCast(userdata.?));
    self.enabled = true;
}

fn disableSeat(_: ?*libseat.struct_libseat, userdata: ?*anyopaque) callconv(.c) void {
    const self: *Self = @ptrCast(@alignCast(userdata.?));
    self.enabled = false;
    self.disable_pending = true;
}

const listener = libseat.struct_libseat_seat_listener{
    .enable_seat = enableSeat,
    .disable_seat = disableSeat,
};

/// Take control of the session's seat through logind, seatd, or (as root) the
/// builtin backend, then wait briefly for the session to be active. The seat provider
/// owns the VT: it disables the console keyboard, and switches VTs on request.
/// Initializes in place, since libseat keeps a pointer to self.
pub fn init(self: *Self, allocator: std.mem.Allocator) !void {
    libseat.libseat_set_log_level(libseat.LIBSEAT_LOG_LEVEL_ERROR);
    self.* = .{ .handle = undefined, .allocator = allocator, .fd = -1 };
    self.handle = libseat.libseat_open_seat(&listener, self) orelse {
        log.err("Cannot open a seat; run from a local login session or start seatd", .{});
        return error.SeatOpenFailed;
    };
    errdefer _ = libseat.libseat_close_seat(self.handle);
    self.fd = libseat.libseat_get_fd(self.handle);
    if (self.fd < 0) return error.SeatOpenFailed;

    var idle_ms: u32 = 0;
    while (true) {
        if (self.disable_pending) self.disable();
        if (self.enabled) break;
        if (idle_ms >= activate_timeout_ms) {
            log.err("Session did not become active; run from the foreground VT", .{});
            return error.SeatInactive;
        }
        const dispatched = libseat.libseat_dispatch(self.handle, 100);
        if (dispatched < 0) return error.SeatDispatchFailed;
        if (dispatched == 0) idle_ms += 100;
    }
    self.active = true;
}

/// Close all devices first.
pub fn deinit(self: *Self) void {
    if (self.devices.items.len != 0) log.warn("Closing seat with {d} open devices", .{self.devices.items.len});
    self.devices.deinit(self.allocator);
    if (libseat.libseat_close_seat(self.handle) != 0) log.warn("Failed to close seat", .{});
    self.* = undefined;
}

pub fn name(self: *Self) [*:0]const u8 {
    return libseat.libseat_seat_name(self.handle);
}

/// Read and handle pending seat messages without blocking.
pub fn dispatch(self: *Self) !void {
    if (libseat.libseat_dispatch(self.handle, 0) < 0) return error.SeatDispatchFailed;
}

/// Return the next state change to apply, or null if none. A disable comes
/// first, so it is acknowledged even when the seat was enabled again since.
pub fn next(self: *const Self) ?Event {
    if (self.disable_pending) return .disable;
    if (self.enabled and !self.active) return .enable;
    return null;
}

/// Acknowledge a disable. Call only after giving up the display and input.
pub fn disable(self: *Self) void {
    if (libseat.libseat_disable_seat(self.handle) != 0)
        log.warn("Failed to acknowledge seat disable: errno {d}", .{std.c._errno().*});
    self.disable_pending = false;
    self.active = false;
}

/// Mark the seat usable again before reopening input and retaking the display.
pub fn enable(self: *Self) void {
    self.active = true;
}

/// Ask the seat provider to switch to VT number.
pub fn switchSession(self: *Self, number: u8) void {
    if (libseat.libseat_switch_session(self.handle, number) != 0)
        log.warn("Failed to switch to VT {d}: errno {d}", .{ number, std.c._errno().* });
}

/// Open a seat device such as a DRM card or evdev node. Close it with
/// closeDevice. On DeviceUnavailable, errno holds the cause.
pub fn openDevice(self: *Self, path: [*:0]const u8) error{ DeviceUnavailable, OutOfMemory }!c_int {
    var fd: c_int = -1;
    const id = libseat.libseat_open_device(self.handle, path, &fd);
    if (id < 0) return error.DeviceUnavailable;
    errdefer {
        _ = libseat.libseat_close_device(self.handle, id);
        _ = linux.close(fd);
    }
    // The seatd backend does not set close-on-exec, and the shell must not
    // inherit seat devices.
    _ = linux.fcntl(fd, linux.F.SETFD, linux.FD_CLOEXEC);
    try self.devices.append(self.allocator, .{ .fd = fd, .id = id });
    return fd;
}

pub fn closeDevice(self: *Self, fd: c_int) void {
    for (self.devices.items, 0..) |device, i| {
        if (device.fd != fd) continue;
        if (libseat.libseat_close_device(self.handle, device.id) != 0)
            log.warn("Failed to release device {d}: errno {d}", .{ fd, std.c._errno().* });
        _ = self.devices.swapRemove(i);
        break;
    }
    _ = linux.close(fd);
}

test "a disable is acknowledged before a later enable is applied" {
    var seat = Self{ .handle = undefined, .allocator = std.testing.allocator, .fd = -1 };
    try std.testing.expectEqual(@as(?Event, null), seat.next());

    enableSeat(null, &seat);
    try std.testing.expectEqual(@as(?Event, .enable), seat.next());
    seat.enable();
    try std.testing.expectEqual(@as(?Event, null), seat.next());

    // Both arrive in one dispatch while switching away and straight back.
    disableSeat(null, &seat);
    enableSeat(null, &seat);
    try std.testing.expectEqual(@as(?Event, .disable), seat.next());
    seat.disable_pending = false;
    seat.active = false;
    try std.testing.expectEqual(@as(?Event, .enable), seat.next());
}
