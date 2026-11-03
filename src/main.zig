const std = @import("std");
const Renderer = @import("renderer.zig");
const Input = @import("input.zig");
const Config = @import("config.zig");
const Colors = @import("colors.zig");
const Pty = @import("pty.zig");
const Vt = @import("vt.zig");
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

    // libghostty-vt does not re-export its device attribute types.
    const DeviceAttributes = @typeInfo(@typeInfo(@typeInfo(
        @FieldType(ghosttyvt.TerminalStream.Handler.Effects, "device_attributes"),
    ).optional.child).pointer.child).@"fn".return_type.?;

    // Without a callback, CSI c queries go unanswered. Programs such as
    // Helix block at startup until their DA1 query is answered.
    fn deviceAttributes(_: *ghosttyvt.TerminalStream.Handler) DeviceAttributes {
        return .{};
    }

    fn init(pty: *Pty, stream: ghosttyvt.TerminalStream) Session {
        var session = Session{ .pty = pty, .stream = stream };
        session.stream.handler.effects.write_pty = &writePty;
        session.stream.handler.effects.device_attributes = &deviceAttributes;
        return session;
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

    var renderer = try Renderer.init(gpa);
    defer renderer.deinit();
    var font = try Renderer.Font.init(gpa, .{
        .directory = config.font_directory,
        .name = config.font_name,
        .pixel_size = config.font_size,
    });
    defer font.deinit();
    var input = try Input.init(.init(config.repeat_delay_ms, config.repeat_rate));
    defer input.deinit();

    const cols: u16 = @intCast(renderer.mode.hdisplay / font.cell_width);
    const rows: u16 = @intCast(renderer.mode.vdisplay / font.cell_height);
    if (cols == 0 or rows == 0) return error.DisplayTooSmall;
    var term = try ghosttyvt.Terminal.init(io, gpa, .{
        .cols = cols,
        .rows = rows,
        // Limit history by lines; a zero byte limit is what disables it.
        .max_scrollback_bytes = if (config.scrollback_lines == 0) 0 else null,
        .max_scrollback_lines = config.scrollback_lines,
    });
    defer term.deinit(gpa);
    try Colors.configure(&term, gpa);
    term.width_px = renderer.mode.hdisplay;
    term.height_px = renderer.mode.vdisplay;

    if (c.setenv("TERM", "xterm-256color", 1) != 0) return error.SetEnvironmentFailed;
    const shell = c.getenv("SHELL");
    const shell_path: [*:0]const u8 = if (shell != null and shell[0] != 0) @ptrCast(shell) else "/bin/sh";
    var pty = try Pty.init(gpa, shell_path, rows, cols);
    defer pty.deinit();
    var session = Session.init(&pty, .init(.{ .allocator = gpa, .handler = .init(&term) }));
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

    // With the console keyboard off, the kernel no longer handles Ctrl+Alt+Fn,
    // so switch VTs ourselves and hand over the display and input on request.
    var vt: ?Vt = if (has_display_mode) Vt.init(0) catch |err| blk: {
        std.log.warn("VT switching unavailable: {s}", .{@errorName(err)});
        break :blk null;
    } else null;
    defer if (vt) |*v| v.deinit();
    var display_retry = false;

    _ = try renderer.drawTerminal(&font, &term);
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
        if (vt) |*v| {
            while (v.next()) |event| switch (event) {
                .release => if (v.active) {
                    renderer.deactivate();
                    try input.deactivate();
                    v.release();
                },
                .acquire => if (!v.active) {
                    v.acquire();
                    try input.activate();
                    display_retry = false;
                },
            };
            // The previous VT's owner may still hold DRM master briefly.
            if (v.active and !renderer.active) {
                if (renderer.activate()) {
                    pacing.dirty = true;
                } else |err| if (!display_retry) {
                    std.log.warn("Cannot retake display, retrying: {s}", .{@errorName(err)});
                    display_retry = true;
                }
            }
        }

        if (!pty_closed) {
            input.keyboard.application_cursor = term.modes.get(.cursor_keys);
            input.keyboard.scrollback = term.screens.active_key == .primary and config.scrollback_lines != 0;
            const now = std.Io.Clock.awake.now(io).toNanoseconds();
            while (try input.next(now, &keys)) |event| switch (event) {
                .bytes => |bytes| {
                    // Typing returns to the live screen; new output does not.
                    if (!term.screens.active.viewportIsBottom()) {
                        term.scrollViewport(.bottom);
                        pacing.dirty = true;
                    }
                    try pty.queue(bytes);
                },
                .switch_vt => |number| if (vt) |*v| v.activate(number),
                .scroll => |scroll| {
                    term.scrollViewport(switch (scroll) {
                        .page_up => .{ .delta = -@as(isize, rows) },
                        .page_down => .{ .delta = rows },
                        .top => .top,
                        .bottom => .bottom,
                    });
                    pacing.dirty = true;
                },
            };
            try pty.flush();
        }

        var fds = [_]c.struct_pollfd{
            // A negative fd disables polling, including persistent POLLHUP.
            .{ .fd = if (pty_closed) -1 else pty.fd, .events = @intCast(c.POLLIN | (if (pty.wantsWrite()) c.POLLOUT else @as(c_int, 0))), .revents = 0 },
            .{ .fd = if (pty_closed) -1 else input.fd, .events = c.POLLIN, .revents = 0 },
            .{ .fd = if (renderer.flip_pending) renderer.fd else -1, .events = c.POLLIN, .revents = 0 },
            .{ .fd = if (vt) |v| v.fd else -1, .events = c.POLLIN, .revents = 0 },
        };
        // Drawing waits for both a free buffer and ownership of the display.
        const display_blocked = renderer.flip_pending or !renderer.active;
        const poll_now = std.Io.Clock.awake.now(io).toNanoseconds();
        var timeout = pacing.timeoutMs(poll_now, display_blocked);
        if (!pty_closed) {
            if (input.repeat.timeoutMs(poll_now)) |repeat_ms| timeout = @min(timeout, repeat_ms);
        }
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
        if (pacing.ready(std.Io.Clock.awake.now(io).toNanoseconds(), renderer.flip_pending or !renderer.active)) {
            if (try renderer.drawTerminal(&font, &term)) try renderer.present();
            pacing.presented(std.Io.Clock.awake.now(io).toNanoseconds());
        }
        // EOF must not discard updates coalesced behind a pending flip. Wait
        // for the final frame's completion before tearing down the renderer.
        // An explicit termination signal still cancels this graceful drain.
        // While switched away, nothing can be shown, so exit immediately.
        if (pty_closed and (!pacing.dirty or !renderer.active) and !renderer.flip_pending) break;
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
    var session = Session.init(&pty, .init(.{ .allocator = std.testing.allocator, .handler = .init(&term) }));
    defer session.stream.deinit();
    session.stream.nextSlice("hello\r\n\x1b[3");
    session.stream.nextSlice("1mred\x1b[0m\x1b[6n\x1b[c");
    try std.testing.expect(!session.stream.handler.semantic_failure);
    try std.testing.expect(session.write_error == null);
    try std.testing.expectEqual(@as(u16, 3), term.screens.active.cursor.x);
    try std.testing.expectEqual(@as(u16, 1), term.screens.active.cursor.y);
    try std.testing.expectEqualStrings("\x1b[2;4R\x1b[?62;22c", pty.pending.items);
    const pin = term.screens.active.pages.pin(.{ .active = .{ .x = 0, .y = 1 } }).?;
    try std.testing.expectEqual(@as(u21, 'r'), pin.rowAndCell().cell.codepoint());
}

test {
    _ = @import("input.zig");
    _ = @import("pty.zig");
    _ = @import("input/keyboard.zig");
    _ = @import("renderer.zig");
    _ = @import("vt.zig");
}
