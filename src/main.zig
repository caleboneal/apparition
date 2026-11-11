const std = @import("std");

const ghosttyvt = @import("ghostty-vt");

const Colors = @import("colors.zig");
const Config = @import("config.zig");
const Input = @import("input.zig");
const Png = @import("png.zig");
const Pty = @import("pty.zig");
const c = Pty.c;
const Renderer = @import("renderer.zig");
const Seat = @import("seat.zig");

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

    // Answers CSI 14/16/18 t, which image tools use to learn the cell size.
    fn size(handler: *ghosttyvt.TerminalStream.Handler) ?ghosttyvt.size_report.Size {
        const term = handler.terminal;
        if (term.cols == 0 or term.rows == 0) return null;
        return .{
            .rows = term.rows,
            .columns = term.cols,
            .cell_width = term.width_px / term.cols,
            .cell_height = term.height_px / term.rows,
        };
    }

    fn init(pty: *Pty, stream: ghosttyvt.TerminalStream) Session {
        var session = Session{ .pty = pty, .stream = stream };
        session.stream.handler.effects.write_pty = &writePty;
        session.stream.handler.effects.device_attributes = &deviceAttributes;
        session.stream.handler.effects.size = &size;
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

    /// Milliseconds until the next frame may be drawn, or null when nothing
    /// is waiting on the clock.
    fn timeoutMs(self: FramePacer, now_ns: i96, flip_pending: bool) ?c_int {
        if (!self.dirty or flip_pending) return null;
        const remaining = self.next_frame_ns - now_ns;
        if (remaining <= 0) return 0;
        // Round up so sub-millisecond waits do not become busy polling.
        return @intCast(@min(std.math.maxInt(c_int), @divTrunc(remaining + std.time.ns_per_ms - 1, std.time.ns_per_ms)));
    }

    fn presented(self: *FramePacer, now_ns: i96) void {
        self.dirty = false;
        // Schedule from this submission, not an old deadline: never catch up
        // missed intervals with a burst of frames.
        self.next_frame_ns = now_ns + self.interval_ns;
    }
};

/// Holds frames while a program redraws under synchronized output (mode
/// 2026), so half-finished screens are not shown. Like Ghostty, it gives
/// up after a timeout in case the program never ends the update.
const SyncHold = struct {
    since_ns: ?i96 = null,

    const timeout_ns = std.time.ns_per_s;

    /// Whether drawing must wait. Resets the mode once the timeout passes.
    fn active(self: *SyncHold, term: *ghosttyvt.Terminal, now_ns: i96) bool {
        if (!term.modes.get(.synchronized_output)) {
            self.since_ns = null;
            return false;
        }
        const since = self.since_ns orelse now_ns;
        if (now_ns - since < timeout_ns) {
            self.since_ns = since;
            return true;
        }
        term.modes.set(.synchronized_output, false);
        self.since_ns = null;
        return false;
    }

    /// Milliseconds until a held frame is released anyway, or null when
    /// nothing is held.
    fn timeoutMs(self: SyncHold, now_ns: i96) ?c_int {
        const since = self.since_ns orelse return null;
        const remaining = since + timeout_ns - now_ns;
        if (remaining <= 0) return 0;
        return @intCast(@divTrunc(remaining + std.time.ns_per_ms - 1, std.time.ns_per_ms));
    }
};

/// The sooner of two poll timeouts, where null waits indefinitely.
fn earliest(a: ?c_int, b: ?c_int) ?c_int {
    const x = a orelse return b;
    const y = b orelse return a;
    return @min(x, y);
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const config = try Config.load(init.arena.allocator(), io, init.environ_map);

    Pty.initSignalHandler(&stop);

    // The seat provider owns the VT: it disables the console keyboard, grants
    // and revokes device access, and switches VTs on our behalf.
    var seat: Seat = undefined;
    try seat.init(gpa);
    defer seat.deinit();

    var renderer = try Renderer.init(gpa, &seat);
    defer renderer.deinit();
    var font = try Renderer.Font.init(gpa, .{
        .directory = config.font_directory,
        .name = config.font_name,
        .pixel_size = config.font_size,
    });
    defer font.deinit();
    var input = try Input.init(&seat, .init(config.repeat_delay_ms, config.repeat_rate));
    defer input.deinit();

    const cols: u16 = @intCast(renderer.mode.hdisplay / font.cell_width);
    const rows: u16 = @intCast(renderer.mode.vdisplay / font.cell_height);
    if (cols == 0 or rows == 0) return error.DisplayTooSmall;
    ghosttyvt.sys.decode_png = &Png.decode;
    var term = try ghosttyvt.Terminal.init(io, gpa, .{
        .cols = cols,
        .rows = rows,
        // Limit history by lines; a zero byte limit is what disables it.
        .max_scrollback_bytes = if (config.scrollback_lines == 0) 0 else null,
        .max_scrollback_lines = config.scrollback_lines,
        .kitty_image_storage_limit = config.image_storage_limit,
        .default_modes = .{ .grapheme_cluster = config.grapheme_clustering },
    });
    defer term.deinit(gpa);
    try Colors.configure(&term, gpa, config.background);
    // Kitty placements derive the cell size from these, so cover exactly the
    // grid; the display's leftover margin is not part of any cell.
    term.width_px = @as(u32, cols) * font.cell_width;
    term.height_px = @as(u32, rows) * font.cell_height;
    // Let local programs send images by path, as kitty and Ghostty do.
    const tmpdir = c.getenv("TMPDIR");
    term.setKittyGraphicsLoadingLimits(.allWithTempDir(if (tmpdir != null and tmpdir[0] != 0) std.mem.span(tmpdir) else "/tmp"));

    if (c.setenv("TERM", "xterm-256color", 1) != 0) return error.SetEnvironmentFailed;
    if (c.setenv("COLORTERM", "truecolor", 1) != 0) return error.SetEnvironmentFailed;
    const shell = c.getenv("SHELL");
    const shell_path: [*:0]const u8 = if (shell != null and shell[0] != 0) @ptrCast(shell) else "/bin/sh";
    var pty = try Pty.init(gpa, shell_path, .{
        .rows = rows,
        .cols = cols,
        .width_px = std.math.cast(u16, term.width_px) orelse std.math.maxInt(u16),
        .height_px = std.math.cast(u16, term.height_px) orelse std.math.maxInt(u16),
    });
    defer pty.deinit();
    var session = Session.init(&pty, .init(.{ .allocator = gpa, .handler = .init(&term) }));
    defer session.stream.deinit();

    var display_retry = false;

    _ = try renderer.drawTerminal(&font, &term);
    try renderer.present();

    var pacing = FramePacer{
        .interval_ns = renderer.frameIntervalNs(),
        .next_frame_ns = 0,
    };
    pacing.presented(std.Io.Clock.awake.now(io).toNanoseconds());
    var sync: SyncHold = .{};
    var pty_closed = false;
    var output: [4096]u8 = undefined;
    var keys: [Input.max_key_bytes]u8 = undefined;
    while (!stopping.load(.monotonic)) {
        while (seat.next()) |event| switch (event) {
            .disable => {
                if (seat.active) {
                    renderer.deactivate();
                    try input.deactivate();
                }
                seat.disable();
            },
            .enable => {
                seat.enable();
                try input.activate();
                display_retry = false;
            },
        };
        // The previous session's owner may still hold DRM master briefly.
        if (seat.active and !renderer.active) {
            if (renderer.activate()) {
                pacing.dirty = true;
            } else |err| if (!display_retry) {
                std.log.warn("Cannot retake display, retrying: {s}", .{@errorName(err)});
                display_retry = true;
            }
        }

        if (!pty_closed) {
            input.keyboard.options = .fromTerminal(&term);
            input.keyboard.scrollback = term.screens.active_key == .primary and config.scrollback_lines != 0;
            input.mouse.configure(.{
                .columns = cols,
                .rows = rows,
                .cell_width = font.cell_width,
                .cell_height = font.cell_height,
                .screen_width = renderer.mode.hdisplay,
                .screen_height = renderer.mode.vdisplay,
            }, .{
                .tracking = term.flags.mouse_event,
                .format = term.flags.mouse_format,
                .alternate_scroll = term.screens.active_key == .alternate and term.modes.get(.mouse_alternate_scroll),
                .cursor_application = term.modes.get(.cursor_keys),
                .scrollback = term.screens.active_key == .primary and config.scrollback_lines != 0,
            });
            const now = std.Io.Clock.awake.now(io).toNanoseconds();
            while (try input.next(now, &keys)) |event| switch (event) {
                .bytes => |bytes| {
                    // Typing or a mouse report returns to the live screen; new output does not.
                    if (!term.screens.active.viewportIsBottom()) {
                        term.scrollViewport(.bottom);
                        pacing.dirty = true;
                    }
                    try pty.queue(bytes);
                },
                .switch_vt => |number| seat.switchSession(number),
                .scroll => |scroll| {
                    term.scrollViewport(switch (scroll) {
                        .page_up => .{ .delta = -@as(isize, rows) },
                        .page_down => .{ .delta = rows },
                        .top => .top,
                        .bottom => .bottom,
                    });
                    pacing.dirty = true;
                },
                .scroll_lines => |lines| {
                    term.scrollViewport(.{ .delta = lines });
                    pacing.dirty = true;
                },
            };
            if (input.mouse.pixel()) |pos| {
                const moved = if (renderer.pointer) |old| old.x != pos.x or old.y != pos.y else true;
                if (moved) {
                    renderer.pointer = .{ .x = pos.x, .y = pos.y };
                    pacing.dirty = true;
                }
            }
            try pty.flush();
        }

        var fds = [_]c.struct_pollfd{
            // A negative fd disables polling, including persistent POLLHUP.
            .{ .fd = if (pty_closed) -1 else pty.fd, .events = @intCast(c.POLLIN | (if (pty.wantsWrite()) c.POLLOUT else @as(c_int, 0))), .revents = 0 },
            .{ .fd = if (pty_closed) -1 else input.fd, .events = c.POLLIN, .revents = 0 },
            .{ .fd = if (renderer.flip_pending) renderer.fd else -1, .events = c.POLLIN, .revents = 0 },
            .{ .fd = seat.fd, .events = c.POLLIN, .revents = 0 },
            // Wakes the loop to notice shell exit; pty.exited() then reaps it.
            .{ .fd = if (pty_closed) -1 else pty.pidfd, .events = c.POLLIN, .revents = 0 },
        };
        // Drawing waits for both a free buffer and ownership of the display.
        const display_blocked = renderer.flip_pending or !renderer.active;
        const poll_now = std.Io.Clock.awake.now(io).toNanoseconds();
        // Advance animated kitty images while visible; a new frame bumps the
        // storage generation.
        var animation_delay_ms: ?u64 = null;
        if (renderer.active) {
            const images = &term.screens.active.kitty_images;
            const generation = images.generation;
            animation_delay_ms = images.animationTick(io, @intCast(@divTrunc(poll_now, std.time.ns_per_ms)));
            if (images.generation != generation) pacing.dirty = true;
        }
        var timeout = if (!sync.active(&term, poll_now))
            pacing.timeoutMs(poll_now, display_blocked)
        else if (pacing.dirty)
            sync.timeoutMs(poll_now)
        else
            null;
        if (animation_delay_ms) |delay| timeout = earliest(timeout, std.math.cast(c_int, delay));
        if (!pty_closed) timeout = earliest(timeout, input.repeat.timeoutMs(poll_now));
        // Retaking the display has no event to wait for, so retry periodically.
        if (seat.active and !renderer.active) timeout = earliest(timeout, 100);
        if (c.poll(&fds, fds.len, timeout orelse -1) < 0) {
            if (Pty.errno() == c.EINTR) continue;
            return error.PollFailed;
        }
        for (fds) |fd| {
            if (fd.revents & c.POLLNVAL != 0) return error.InvalidPollDescriptor;
        }
        if (fds[1].revents & (c.POLLERR | c.POLLHUP) != 0) return error.InputDisconnected;

        if (fds[2].revents & (c.POLLERR | c.POLLHUP) != 0) return error.DisplayDisconnected;
        if (fds[2].revents & c.POLLIN != 0) try renderer.handleEvents();
        if (fds[3].revents & (c.POLLIN | c.POLLERR | c.POLLHUP) != 0) try seat.dispatch();

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
        const draw_now = std.Io.Clock.awake.now(io).toNanoseconds();
        if (!sync.active(&term, draw_now) and pacing.ready(draw_now, renderer.flip_pending or !renderer.active)) {
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
    try std.testing.expectEqual(@as(?c_int, null), pacing.timeoutMs(interval, false));
    try std.testing.expect(!pacing.ready(interval, false));

    pacing.dirty = true;
    try std.testing.expect(!pacing.ready(interval - 1, false));
    try std.testing.expect(!pacing.ready(interval, true));
    try std.testing.expectEqual(@as(?c_int, null), pacing.timeoutMs(interval, true));
    try std.testing.expect(pacing.dirty);
    try std.testing.expect(pacing.ready(interval, false));
    try std.testing.expectEqual(@as(?c_int, 0), pacing.timeoutMs(interval, false));

    // A delayed submission starts a new interval instead of catching up.
    pacing.presented(10 * interval);
    try std.testing.expect(!pacing.dirty);
    pacing.dirty = true;
    try std.testing.expect(!pacing.ready(10 * interval, false));
    try std.testing.expect(pacing.ready(11 * interval, false));
}

test "frame pacing rounds waits up and only sets a deadline while dirty" {
    var pacing = FramePacer{ .interval_ns = std.time.ns_per_s, .next_frame_ns = std.time.ns_per_s, .dirty = true };
    try std.testing.expectEqual(@as(?c_int, 1000), pacing.timeoutMs(0, false));
    try std.testing.expectEqual(@as(?c_int, 2), pacing.timeoutMs(std.time.ns_per_s - std.time.ns_per_ms - 1, false));
    try std.testing.expectEqual(@as(?c_int, 1), pacing.timeoutMs(std.time.ns_per_s - 1, false));
    try std.testing.expectEqual(@as(?c_int, 0), pacing.timeoutMs(std.time.ns_per_s, false));
    try std.testing.expectEqual(@as(?c_int, 0), pacing.timeoutMs(2 * std.time.ns_per_s, false));
    pacing.dirty = false;
    try std.testing.expectEqual(@as(?c_int, null), pacing.timeoutMs(2 * std.time.ns_per_s, false));
}

test "synchronized output holds frames until it ends or times out" {
    var term = try ghosttyvt.Terminal.init(std.testing.io, std.testing.allocator, .{ .cols = 4, .rows = 1 });
    defer term.deinit(std.testing.allocator);
    var sync: SyncHold = .{};
    try std.testing.expect(!sync.active(&term, 0));
    try std.testing.expectEqual(@as(?c_int, null), sync.timeoutMs(0));

    term.modes.set(.synchronized_output, true);
    try std.testing.expect(sync.active(&term, 10 * std.time.ns_per_ms));
    try std.testing.expectEqual(@as(?c_int, 1000), sync.timeoutMs(10 * std.time.ns_per_ms));
    try std.testing.expect(sync.active(&term, 500 * std.time.ns_per_ms));
    try std.testing.expectEqual(@as(?c_int, 510), sync.timeoutMs(500 * std.time.ns_per_ms));
    // Ending the update releases the frame and restarts the clock.
    term.modes.set(.synchronized_output, false);
    try std.testing.expect(!sync.active(&term, 600 * std.time.ns_per_ms));
    term.modes.set(.synchronized_output, true);
    try std.testing.expect(sync.active(&term, 700 * std.time.ns_per_ms));
    try std.testing.expect(sync.active(&term, 1699 * std.time.ns_per_ms));
    // An update that never ends is abandoned, clearing the mode.
    try std.testing.expect(!sync.active(&term, 1700 * std.time.ns_per_ms));
    try std.testing.expect(!term.modes.get(.synchronized_output));
}

test "earliest poll timeout treats null as no deadline" {
    try std.testing.expectEqual(@as(?c_int, null), earliest(null, null));
    try std.testing.expectEqual(@as(?c_int, 5), earliest(null, 5));
    try std.testing.expectEqual(@as(?c_int, 5), earliest(5, null));
    try std.testing.expectEqual(@as(?c_int, 0), earliest(5, 0));
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
    _ = @import("config.zig");
    _ = @import("input.zig");
    _ = @import("pty.zig");
    _ = @import("input/keyboard.zig");
    _ = @import("input/mouse.zig");
    _ = @import("renderer.zig");
    _ = @import("renderer/box.zig");
    _ = @import("renderer/blocks.zig");
    _ = @import("renderer/powerline.zig");
    _ = @import("seat.zig");
    _ = @import("png.zig");
}
