const std = @import("std");
const Renderer = @import("renderer.zig");
const Input = @import("input.zig");
const Config = @import("config.zig");
const Colors = @import("colors.zig");
const Pty = @import("pty.zig");
const c = Pty.c;
const ghosttyvt = @import("ghostty-vt");

const console = @cImport({
    @cInclude("linux/kd.h");
    @cInclude("sys/ioctl.h");
});
const config = Config{};
var stopping = std.atomic.Value(bool).init(false);

fn stop(_: c_int) callconv(.c) void {
    stopping.store(true, .monotonic);
}

// The effect callback has no userdata, so recover the owning session from
// its embedded stream rather than keeping a global PTY pointer.
const Session = struct {
    pty: *Pty,
    stream: ghosttyvt.TerminalStream,
    write_error: ?anyerror = null,

    fn writePty(handler: *ghosttyvt.TerminalStream.Handler, bytes: []const u8) void {
        const stream: *ghosttyvt.TerminalStream = @fieldParentPtr("handler", handler);
        const self: *Session = @fieldParentPtr("stream", stream);
        self.pty.queue(bytes) catch |err| {
            self.write_error = err;
        };
    }
};

const FramePacer = struct {
    interval_ns: u64,
    next_frame_ns: i96,
    dirty: bool = false,

    fn ready(self: FramePacer, now_ns: i96, flip_pending: bool) bool {
        return self.dirty and !flip_pending and now_ns >= self.next_frame_ns;
    }

    fn timeoutMs(self: FramePacer, now_ns: i96, flip_pending: bool) c_int {
        // Keep checking for shell exit even when descendants hold the PTY open.
        if (!self.dirty or flip_pending) return 100;
        const remaining = self.next_frame_ns - now_ns;
        if (remaining <= 0) return 0;
        // Round up so sub-millisecond waits do not become busy polling.
        return @intCast(@min(100, @divTrunc(remaining + std.time.ns_per_ms - 1, std.time.ns_per_ms)));
    }

    fn presented(self: *FramePacer, now_ns: i96) void {
        self.dirty = false;
        // Schedule from this submission, not an old deadline: never catch up
        // missed intervals with a burst of frames.
        self.next_frame_ns = now_ns + self.interval_ns;
    }
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    for ([_]c_int{ c.SIGINT, c.SIGTERM, c.SIGHUP }) |sig| {
        _ = c.signal(sig, &stop);
    }
    // C's SIG_IGN is address 1, not an aligned ARM function pointer.
    std.posix.sigaction(.PIPE, &.{
        .handler = .{ .handler = std.posix.SIG.IGN },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    }, null);

    var renderer = try Renderer.init();
    defer renderer.deinit();
    var font = try Renderer.Font.init(gpa, config.font_path, config.font_size);
    defer font.deinit();
    var input = try Input.init();
    defer input.deinit();

    const cols: u16 = @intCast(renderer.mode.hdisplay / font.cell_width);
    const rows: u16 = @intCast(renderer.mode.vdisplay / font.cell_height);
    if (cols == 0 or rows == 0) return error.DisplayTooSmall;
    var term = try ghosttyvt.Terminal.init(io, gpa, .{ .cols = cols, .rows = rows });
    defer term.deinit(gpa);
    try Colors.configure(&term, gpa);
    term.width_px = renderer.mode.hdisplay;
    term.height_px = renderer.mode.vdisplay;

    if (c.setenv("TERM", "xterm-256color", 1) != 0) return error.SetEnvironmentFailed;
    const shell = c.getenv("SHELL");
    const shell_path: [*:0]const u8 = if (shell != null and shell[0] != 0) @ptrCast(shell) else "/bin/sh";
    var pty = try Pty.init(gpa, shell_path, rows, cols);
    defer pty.deinit();
    var session = Session{
        .pty = &pty,
        .stream = .init(.{ .allocator = gpa, .handler = .init(&term) }),
    };
    session.stream.handler.effects.write_pty = &Session.writePty;
    defer session.stream.deinit();

    // When launched from a Linux VT, libinput owns keyboard input while we
    // draw. Do not also deliver those keys to the launching console.
    var keyboard_mode: c_int = 0;
    const on_console = console.ioctl(0, console.KDGKBMODE, &keyboard_mode) == 0;
    if (on_console and console.ioctl(0, console.KDSKBMODE, @as(c_int, console.K_OFF)) != 0)
        return error.DisableConsoleKeyboardFailed;
    defer if (on_console) {
        _ = console.ioctl(0, console.KDSKBMODE, keyboard_mode);
    };

    var display_mode: c_int = 0;
    const has_display_mode = on_console and console.ioctl(0, console.KDGETMODE, &display_mode) == 0;
    if (has_display_mode and console.ioctl(0, console.KDSETMODE, @as(c_int, console.KD_GRAPHICS)) != 0)
        return error.SetConsoleGraphicsFailed;
    defer if (has_display_mode) {
        _ = console.ioctl(0, console.KDSETMODE, display_mode);
    };

    try renderer.drawTerminal(&font, &term);
    try renderer.present();

    var pacing = FramePacer{
        .interval_ns = renderer.frameIntervalNs(),
        .next_frame_ns = 0,
    };
    pacing.presented(std.Io.Clock.awake.now(io).toNanoseconds());
    var pty_closed = false;
    var output: [4096]u8 = undefined;
    var keys: [64]u8 = undefined;
    while (!stopping.load(.monotonic)) {
        if (!pty_closed) {
            input.keyboard.application_cursor = term.modes.get(.cursor_keys);
            while (try input.next(&keys)) |bytes| try pty.queue(bytes);
            try pty.flush();
        }

        var fds = [_]c.struct_pollfd{
            // A negative fd disables polling, including persistent POLLHUP.
            .{ .fd = if (pty_closed) -1 else pty.fd, .events = @intCast(c.POLLIN | (if (pty.wantsWrite()) c.POLLOUT else @as(c_int, 0))), .revents = 0 },
            .{ .fd = if (pty_closed) -1 else input.fd, .events = c.POLLIN, .revents = 0 },
            .{ .fd = if (renderer.flip_pending) renderer.fd else -1, .events = c.POLLIN, .revents = 0 },
        };
        const timeout = pacing.timeoutMs(std.Io.Clock.awake.now(io).toNanoseconds(), renderer.flip_pending);
        if (c.poll(&fds, fds.len, timeout) < 0) {
            if (Pty.errno() == c.EINTR) continue;
            return error.PollFailed;
        }
        for (fds) |fd| {
            if (fd.revents & c.POLLNVAL != 0) return error.InvalidPollDescriptor;
        }
        if (fds[1].revents & (c.POLLERR | c.POLLHUP) != 0) return error.InputDisconnected;

        if (fds[2].revents & (c.POLLERR | c.POLLHUP) != 0) return error.DisplayDisconnected;
        if (fds[2].revents & c.POLLIN != 0) try renderer.handleEvents();

        if (!pty_closed) {
            var drained = false;
            // Bound each batch so a noisy process cannot starve keyboard input
            // or DRM events: at most 16 reads of 4096 bytes per iteration.
            for (0..16) |_| {
                const n = (try pty.read(&output)) orelse {
                    drained = true;
                    break;
                };
                if (n == 0) {
                    pty_closed = true;
                    break;
                }
                session.stream.nextSlice(output[0..n]);
                if (session.write_error) |err| return err;
                if (session.stream.handler.semantic_failure) return error.TerminalUpdateFailed;
                pacing.dirty = true;
            }
            if (drained and pty.exited()) pty_closed = true;
        }
        if (pacing.ready(std.Io.Clock.awake.now(io).toNanoseconds(), renderer.flip_pending)) {
            try renderer.drawTerminal(&font, &term);
            try renderer.present();
            pacing.presented(std.Io.Clock.awake.now(io).toNanoseconds());
        }
        // EOF must not discard updates coalesced behind a pending flip. Wait
        // for the final frame's completion before tearing down the renderer.
        // An explicit termination signal still cancels this graceful drain.
        if (pty_closed and !pacing.dirty and !renderer.flip_pending) break;
    }
}

test "frame pacing coalesces updates and preserves dirty while a flip is pending" {
    const interval = std.time.ns_per_s / 60;
    var pacing = FramePacer{ .interval_ns = interval, .next_frame_ns = 0 };
    pacing.presented(0);
    try std.testing.expectEqual(@as(c_int, 100), pacing.timeoutMs(interval, false));
    try std.testing.expect(!pacing.ready(interval, false));

    pacing.dirty = true;
    try std.testing.expect(!pacing.ready(interval - 1, false));
    try std.testing.expect(!pacing.ready(interval, true));
    try std.testing.expectEqual(@as(c_int, 100), pacing.timeoutMs(interval, true));
    try std.testing.expect(pacing.dirty);
    try std.testing.expect(pacing.ready(interval, false));
    try std.testing.expectEqual(@as(c_int, 0), pacing.timeoutMs(interval, false));

    // A delayed submission starts a new interval instead of catching up.
    pacing.presented(10 * interval);
    try std.testing.expect(!pacing.dirty);
    pacing.dirty = true;
    try std.testing.expect(!pacing.ready(10 * interval, false));
    try std.testing.expect(pacing.ready(11 * interval, false));
}

test "frame pacing rounds waits up and caps shell exit checks at 100ms" {
    var pacing = FramePacer{ .interval_ns = std.time.ns_per_s, .next_frame_ns = std.time.ns_per_s, .dirty = true };
    try std.testing.expectEqual(@as(c_int, 100), pacing.timeoutMs(0, false));
    try std.testing.expectEqual(@as(c_int, 2), pacing.timeoutMs(std.time.ns_per_s - std.time.ns_per_ms - 1, false));
    try std.testing.expectEqual(@as(c_int, 1), pacing.timeoutMs(std.time.ns_per_s - 1, false));
    try std.testing.expectEqual(@as(c_int, 0), pacing.timeoutMs(std.time.ns_per_s, false));
    try std.testing.expectEqual(@as(c_int, 0), pacing.timeoutMs(2 * std.time.ns_per_s, false));
    pacing.dirty = false;
    try std.testing.expectEqual(@as(c_int, 100), pacing.timeoutMs(2 * std.time.ns_per_s, false));
}

test "terminal stream parses split output and queues cursor reports" {
    var term = try ghosttyvt.Terminal.init(std.testing.io, std.testing.allocator, .{ .cols = 80, .rows = 24 });
    defer term.deinit(std.testing.allocator);
    var pty = Pty{ .fd = -1, .pid = -1, .allocator = std.testing.allocator };
    defer pty.pending.deinit(std.testing.allocator);
    var session = Session{
        .pty = &pty,
        .stream = .init(.{ .allocator = std.testing.allocator, .handler = .init(&term) }),
    };
    defer session.stream.deinit();
    session.stream.handler.effects.write_pty = &Session.writePty;
    session.stream.nextSlice("hello\r\n\x1b[3");
    session.stream.nextSlice("1mred\x1b[0m\x1b[6n");
    try std.testing.expect(!session.stream.handler.semantic_failure);
    try std.testing.expect(session.write_error == null);
    try std.testing.expectEqual(@as(u16, 3), term.screens.active.cursor.x);
    try std.testing.expectEqual(@as(u16, 1), term.screens.active.cursor.y);
    try std.testing.expectEqualStrings("\x1b[2;4R", pty.pending.items);
    const pin = term.screens.active.pages.pin(.{ .active = .{ .x = 0, .y = 1 } }).?;
    try std.testing.expectEqual(@as(u21, 'r'), pin.rowAndCell().cell.codepoint());
}

test {
    _ = @import("input.zig");
    _ = @import("pty.zig");
    _ = @import("input/keyboard.zig");
    _ = @import("renderer.zig");
}
