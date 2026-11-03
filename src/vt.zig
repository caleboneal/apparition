const std = @import("std");
const linux = std.os.linux;
const c = @cImport({
    @cInclude("linux/vt.h");
    @cInclude("sys/ioctl.h");
});
const log = std.log.scoped(.vt);

const Self = @This();

/// Kernel requests delivered while this VT is in VT_PROCESS mode. Each must be
/// acknowledged with release or acquire before the switch completes.
pub const Event = enum(u8) { release = 'r', acquire = 'a' };

const release_signal = std.posix.SIG.USR1;
const acquire_signal = std.posix.SIG.USR2;

// Signal handlers have no userdata, so they reach the wake pipe through a global.
var wake_fd = std.atomic.Value(c_int).init(-1);

tty: c_int,
saved_mode: c.struct_vt_mode,
/// Nonblocking read end of the wake pipe; poll it for readability.
fd: c_int,
wake_write: c_int,
active: bool = true,

fn signalHandler(sig: std.posix.SIG) callconv(.c) void {
    const event: Event = if (sig == release_signal) .release else .acquire;
    const byte = [1]u8{@intFromEnum(event)};
    // Raw syscalls leave errno untouched, as a signal handler must.
    _ = linux.write(wake_fd.load(.monotonic), &byte, 1);
}

fn setHandler(sig: std.posix.SIG, handler: ?std.posix.Sigaction.handler_fn) void {
    std.posix.sigaction(sig, &.{
        .handler = .{ .handler = handler },
        .mask = std.posix.sigemptyset(),
        .flags = std.posix.SA.RESTART,
    }, null);
}

/// Take over VT switching on tty, which must be a virtual console. Until
/// deinit, switches away wait for release and switches back report acquire.
pub fn init(tty: c_int) !Self {
    var saved_mode: c.struct_vt_mode = undefined;
    if (c.ioctl(tty, c.VT_GETMODE, &saved_mode) != 0) return error.NotAVirtualTerminal;

    var pipe: [2]i32 = undefined;
    if (linux.errno(linux.pipe2(&pipe, .{ .NONBLOCK = true, .CLOEXEC = true })) != .SUCCESS)
        return error.PipeFailed;
    errdefer for (pipe) |fd| {
        _ = linux.close(fd);
    };
    wake_fd.store(pipe[1], .monotonic);

    // Install handlers first: the default action for SIGUSR1/2 terminates.
    setHandler(release_signal, &signalHandler);
    setHandler(acquire_signal, &signalHandler);
    errdefer {
        setHandler(release_signal, std.posix.SIG.DFL);
        setHandler(acquire_signal, std.posix.SIG.DFL);
    }

    var mode = saved_mode;
    mode.mode = c.VT_PROCESS;
    mode.relsig = @intCast(@intFromEnum(release_signal));
    mode.acqsig = @intCast(@intFromEnum(acquire_signal));
    mode.frsig = 0;
    if (c.ioctl(tty, c.VT_SETMODE, &mode) != 0) return error.SetVtModeFailed;

    return .{ .tty = tty, .saved_mode = saved_mode, .fd = pipe[0], .wake_write = pipe[1] };
}

pub fn deinit(self: *Self) void {
    if (c.ioctl(self.tty, c.VT_SETMODE, &self.saved_mode) != 0)
        log.warn("Failed to restore VT switching mode", .{});
    setHandler(release_signal, std.posix.SIG.DFL);
    setHandler(acquire_signal, std.posix.SIG.DFL);
    wake_fd.store(-1, .monotonic);
    _ = linux.close(self.fd);
    _ = linux.close(self.wake_write);
}

/// Return the next pending kernel request in arrival order, or null if none.
pub fn next(self: *Self) ?Event {
    var byte: [1]u8 = undefined;
    const result = linux.read(self.fd, &byte, 1);
    if (linux.errno(result) != .SUCCESS or result == 0) return null;
    return std.enums.fromInt(Event, byte[0]);
}

/// Allow a requested switch away. Call only after giving up the display and input.
pub fn release(self: *Self) void {
    if (c.ioctl(self.tty, c.VT_RELDISP, @as(c_int, 1)) != 0)
        log.warn("Failed to release VT: errno {d}", .{std.c._errno().*});
    self.active = false;
}

/// Acknowledge a switch back to this VT before retaking the display and input.
pub fn acquire(self: *Self) void {
    if (c.ioctl(self.tty, c.VT_RELDISP, @as(c_int, c.VT_ACKACQ)) != 0)
        log.warn("Failed to acknowledge VT acquire: errno {d}", .{std.c._errno().*});
    self.active = true;
}

/// Ask the kernel to switch to VT number. Completion arrives as a release event.
pub fn activate(self: *Self, number: u8) void {
    if (c.ioctl(self.tty, c.VT_ACTIVATE, @as(c_int, number)) != 0)
        log.warn("Failed to switch to VT {d}: errno {d}", .{ number, std.c._errno().* });
}

test "signals queue VT requests in arrival order" {
    var pipe: [2]i32 = undefined;
    try std.testing.expect(linux.errno(linux.pipe2(&pipe, .{ .NONBLOCK = true, .CLOEXEC = true })) == .SUCCESS);
    var vt = Self{ .tty = -1, .saved_mode = undefined, .fd = pipe[0], .wake_write = pipe[1] };
    defer {
        _ = linux.close(pipe[0]);
        _ = linux.close(pipe[1]);
        wake_fd.store(-1, .monotonic);
    }
    wake_fd.store(pipe[1], .monotonic);

    try std.testing.expectEqual(@as(?Event, null), vt.next());
    signalHandler(release_signal);
    signalHandler(acquire_signal);
    try std.testing.expectEqual(@as(?Event, .release), vt.next());
    try std.testing.expectEqual(@as(?Event, .acquire), vt.next());
    try std.testing.expectEqual(@as(?Event, null), vt.next());
}
