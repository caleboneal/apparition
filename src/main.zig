const std = @import("std");
const Renderer = @import("renderer.zig");
const Input = @import("input.zig");
const Config = @import("config.zig");
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

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    for ([_]c_int{ c.SIGINT, c.SIGTERM, c.SIGHUP }) |sig| {
        _ = c.signal(sig, &stop);
    }
    _ = c.signal(c.SIGPIPE, c.SIG_IGN);

    var renderer = try Renderer.init();
    defer renderer.deinit();
    var font = try Renderer.Font.init(config.font_path, config.font_size);
    defer font.deinit();
    var input = try Input.init();
    defer input.deinit();

    const cols: u16 = @intCast(renderer.mode.hdisplay / font.cell_width);
    const rows: u16 = @intCast(renderer.mode.vdisplay / font.cell_height);
    if (cols == 0 or rows == 0) return error.DisplayTooSmall;
    var term = try ghosttyvt.Terminal.init(io, gpa, .{ .cols = cols, .rows = rows });
    defer term.deinit(gpa);
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

    var output: [4096]u8 = undefined;
    var keys: [64]u8 = undefined;
    while (!stopping.load(.monotonic)) {
        input.keyboard.application_cursor = term.modes.get(.cursor_keys);
        while (try input.next(&keys)) |bytes| try pty.queue(bytes);
        try pty.flush();

        var fds = [_]c.struct_pollfd{
            .{ .fd = pty.fd, .events = @intCast(c.POLLIN | (if (pty.wantsWrite()) c.POLLOUT else @as(c_int, 0))), .revents = 0 },
            .{ .fd = input.fd, .events = c.POLLIN, .revents = 0 },
        };
        // A timeout also detects shell exit if descendants keep the slave open.
        if (c.poll(&fds, fds.len, 100) < 0) {
            if (Pty.errno() == c.EINTR) continue;
            return error.PollFailed;
        }
        for (fds) |fd| {
            if (fd.revents & c.POLLNVAL != 0) return error.InvalidPollDescriptor;
        }
        if (fds[1].revents & (c.POLLERR | c.POLLHUP) != 0) return error.InputDisconnected;

        var dirty = false;
        var closed = false;
        var drained = false;
        // Bound each batch so a noisy process cannot starve keyboard input.
        for (0..16) |_| {
            const n = (try pty.read(&output)) orelse {
                drained = true;
                break;
            };
            if (n == 0) {
                closed = true;
                break;
            }
            session.stream.nextSlice(output[0..n]);
            if (session.write_error) |err| return err;
            if (session.stream.handler.semantic_failure) return error.TerminalUpdateFailed;
            dirty = true;
        }
        if (dirty) {
            try renderer.drawTerminal(&font, &term);
            try renderer.present();
        }
        if (closed or (pty.exited() and drained)) break;
    }
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
