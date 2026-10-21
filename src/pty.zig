const std = @import("std");

pub const c = @cImport({
    @cDefine("_GNU_SOURCE", "1");
    @cInclude("errno.h");
    @cInclude("fcntl.h");
    @cInclude("poll.h");
    @cInclude("pty.h");
    @cInclude("signal.h");
    @cInclude("stdlib.h");
    @cInclude("sys/wait.h");
    @cInclude("unistd.h");
});

const Self = @This();

fd: c_int,
pid: c.pid_t,
reaped: bool = false,
pending: std.ArrayList(u8) = .empty,
written: usize = 0,
allocator: std.mem.Allocator,

pub fn init(allocator: std.mem.Allocator, shell: [*:0]const u8, rows: u16, cols: u16) !Self {
    var exec_pipe: [2]c_int = undefined;
    if (c.pipe2(&exec_pipe, c.O_CLOEXEC) != 0) return error.PipeFailed;
    defer _ = c.close(exec_pipe[0]);
    var write_pipe_open = true;
    defer if (write_pipe_open) {
        _ = c.close(exec_pipe[1]);
    };

    var size = std.mem.zeroes(c.struct_winsize);
    size.ws_row = rows;
    size.ws_col = cols;
    var master: c_int = undefined;
    const pid = c.forkpty(&master, null, null, &size);
    if (pid < 0) return error.ForkPtyFailed;
    if (pid == 0) {
        _ = c.close(exec_pipe[0]);
        // The shell must receive normal job-control signals, even if our
        // launcher inherited ignored dispositions from its own parent.
        for ([_]c_int{ c.SIGINT, c.SIGQUIT, c.SIGTERM, c.SIGHUP, c.SIGPIPE, c.SIGCHLD }) |sig| {
            _ = c.signal(sig, c.SIG_DFL);
        }
        _ = c.execl(shell, shell, @as([*:0]const u8, "-i"), @as(?*anyopaque, null));
        _ = c.write(exec_pipe[1], "!", 1);
        c._exit(127);
    }

    _ = c.close(exec_pipe[1]);
    write_pipe_open = false;
    var self = Self{ .fd = master, .pid = pid, .allocator = allocator };
    errdefer self.deinit();

    var failure: [1]u8 = undefined;
    while (true) {
        const n = c.read(exec_pipe[0], &failure, failure.len);
        if (n == 0) break;
        if (n > 0) return error.ShellExecFailed;
        if (errno() != c.EINTR) return error.ShellExecFailed;
    }

    if (c.fcntl(master, c.F_SETFD, @as(c_int, c.FD_CLOEXEC)) < 0) return error.FcntlFailed;
    const flags = c.fcntl(master, c.F_GETFL);
    if (flags < 0 or c.fcntl(master, c.F_SETFL, flags | c.O_NONBLOCK) < 0) return error.FcntlFailed;
    return self;
}

pub fn deinit(self: *Self) void {
    _ = c.close(self.fd);
    self.pending.deinit(self.allocator);
    if (self.reaped) return;

    // Closing the master normally sends SIGHUP. Bound shutdown even when a
    // shell ignores it, and always reap the child to avoid zombies.
    _ = c.kill(-self.pid, c.SIGHUP);
    for (0..10) |_| {
        if (self.exited()) return;
        _ = c.poll(null, 0, 10);
    }
    _ = c.kill(-self.pid, c.SIGKILL);
    _ = c.kill(self.pid, c.SIGKILL);
    while (c.waitpid(self.pid, null, 0) < 0) {
        if (errno() != c.EINTR) break;
    }
    self.reaped = true;
}

pub fn exited(self: *Self) bool {
    if (self.reaped) return true;
    const result = c.waitpid(self.pid, null, c.WNOHANG);
    if (result == self.pid or (result < 0 and errno() == c.ECHILD)) self.reaped = true;
    return self.reaped;
}

/// null means no data is available yet; zero means the slave has closed.
pub fn read(self: *Self, buffer: []u8) !?usize {
    while (true) {
        const n = c.read(self.fd, buffer.ptr, buffer.len);
        if (n >= 0) return @intCast(n);
        switch (errno()) {
            c.EINTR => continue,
            c.EAGAIN => return null,
            // Linux reports EIO when the final slave descriptor closes.
            c.EIO => return 0,
            else => return error.PtyReadFailed,
        }
    }
}

pub fn queue(self: *Self, bytes: []const u8) !void {
    // Compact only before appending, keeping partially written input intact.
    if (self.written > 0) {
        const remaining = self.pending.items.len - self.written;
        std.mem.copyForwards(u8, self.pending.items[0..remaining], self.pending.items[self.written..]);
        self.pending.items.len = remaining;
        self.written = 0;
    }
    if (bytes.len > 1024 * 1024 - self.pending.items.len) return error.PtyInputQueueFull;
    try self.pending.appendSlice(self.allocator, bytes);
}

pub fn wantsWrite(self: *const Self) bool {
    return self.written < self.pending.items.len;
}

pub fn flush(self: *Self) !void {
    while (self.wantsWrite()) {
        const bytes = self.pending.items[self.written..];
        const n = c.write(self.fd, bytes.ptr, bytes.len);
        if (n > 0) {
            self.written += @intCast(n);
            continue;
        }
        if (n < 0) switch (errno()) {
            c.EINTR => continue,
            c.EAGAIN => return,
            else => {},
        };
        return error.PtyWriteFailed;
    }
    self.pending.clearRetainingCapacity();
    self.written = 0;
}

pub fn errno() c_int {
    return c.__errno_location().*;
}

test "PTY starts an interactive shell with a controlling terminal and window size" {
    var pty = try Self.init(std.testing.allocator, "/bin/sh", 31, 97);
    defer pty.deinit();
    try pty.queue("test -t 0 && test -t 1 && test -t 2 && stty size; printf 'pty-%s\\n' ready; exit\r");
    try pty.flush();

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(std.testing.allocator);
    var buffer: [4096]u8 = undefined;
    var closed = false;
    for (0..100) |_| {
        var fd = c.struct_pollfd{ .fd = pty.fd, .events = c.POLLIN, .revents = 0 };
        _ = c.poll(&fd, 1, 50);
        if (try pty.read(&buffer)) |n| {
            if (n == 0) {
                closed = true;
                break;
            }
            try output.appendSlice(std.testing.allocator, buffer[0..n]);
        }
    }
    try std.testing.expect(closed);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "31 97\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output.items, "pty-ready\r\n") != null);
}

test "PTY reports a shell exec failure" {
    try std.testing.expectError(error.ShellExecFailed, Self.init(std.testing.allocator, "/nonexistent-apparition-shell", 24, 80));
}

test "PTY preserves queued bytes across a partial write" {
    var pty = Self{ .fd = -1, .pid = -1, .allocator = std.testing.allocator };
    defer pty.pending.deinit(std.testing.allocator);
    try pty.queue("abc");
    pty.written = 2;
    try pty.queue("def");
    try std.testing.expectEqualStrings("cdef", pty.pending.items);
    try std.testing.expectEqual(@as(usize, 0), pty.written);
}
