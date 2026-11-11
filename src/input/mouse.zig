const std = @import("std");
const ghosttyvt = @import("ghostty-vt");
const vt = ghosttyvt.input;

const Self = @This();

/// Display and grid geometry used to clamp the pointer and encode cells.
pub const Grid = struct {
    columns: u16,
    rows: u16,
    cell_width: u32,
    cell_height: u32,
    /// Full display, in pixels. The grid is anchored at the top-left.
    screen_width: u32,
    screen_height: u32,
};

/// Terminal modes that decide whether a pointer event is reported, scrolled,
/// or turned into cursor keys. Copied from the terminal before each poll.
pub const Modes = struct {
    tracking: @FieldType(vt.MouseEncodeOptions, "event") = .none,
    format: @FieldType(vt.MouseEncodeOptions, "format") = .x10,
    /// Alternate screen, mode 1007, and no mouse tracking: the wheel sends arrows.
    alternate_scroll: bool = false,
    cursor_application: bool = false,
    /// Primary screen with history. Without it, an untracked wheel does nothing.
    scrollback: bool = true,
};

pub const Effect = union(enum) {
    /// Encoded mouse or cursor-key bytes. Aliases the buffer passed to emit.
    bytes: []const u8,
    /// Viewport movement in lines. Positive moves toward newer lines.
    scroll_lines: isize,
};

const Report = struct {
    action: vt.MouseAction,
    button: ?vt.MouseButton,
};

grid: Grid = .{
    .columns = 0,
    .rows = 0,
    .cell_width = 0,
    .cell_height = 0,
    .screen_width = 0,
    .screen_height = 0,
},
tracking: @FieldType(vt.MouseEncodeOptions, "event") = .none,
format: @FieldType(vt.MouseEncodeOptions, "format") = .x10,
alternate_scroll: bool = false,
cursor_application: bool = false,
scrollback: bool = true,
/// False until the first motion, so the pointer stays hidden at startup.
placed: bool = false,
x: f64 = 0,
y: f64 = 0,
/// Indexed by the ghostty button value. Wheel buttons are never stored.
buttons: [12]bool = @splat(false),
/// One press or motion waiting to be encoded. Scroll clicks live in the accumulators.
report: ?Report = null,
/// High-resolution wheel motion in v120 units. Positive is down or right.
wheel: [2]f64 = @splat(0),
/// Touchpad and continuous scroll in pixels. Positive is down or right.
finger: [2]f64 = @splat(0),
/// Last cell the encoder reported, so motion inside that cell is not repeated.
last_cell: ?ghosttyvt.Coordinate = null,

pub fn configure(self: *Self, grid: Grid, modes: Modes) void {
    self.grid = grid;
    self.tracking = modes.tracking;
    self.format = modes.format;
    self.alternate_scroll = modes.alternate_scroll;
    self.cursor_application = modes.cursor_application;
    self.scrollback = modes.scrollback;
    // A later press must not be dropped as a duplicate of a cell from an old mode.
    if (self.tracking == .none) self.last_cell = null;
}

/// Drop button and scroll state. The pointer position is kept so the cursor
/// stays put across a VT switch. libinput also synthesizes button releases.
pub fn clear(self: *Self) void {
    self.buttons = @splat(false);
    self.report = null;
    self.wheel = @splat(0);
    self.finger = @splat(0);
    self.last_cell = null;
}

pub fn pixel(self: *const Self) ?struct { x: u32, y: u32 } {
    if (!self.placed) return null;
    return .{
        .x = @intFromFloat(self.x),
        .y = @intFromFloat(self.y),
    };
}

/// Relative motion, in pointer pixels. The first event appears at the screen center.
pub fn moveBy(self: *Self, dx: f64, dy: f64) void {
    if (dx == 0 and dy == 0) return;
    if (!self.placed) {
        self.placed = true;
        self.x = @as(f64, @floatFromInt(self.grid.screen_width)) / 2;
        self.y = @as(f64, @floatFromInt(self.grid.screen_height)) / 2;
    }
    self.x += dx;
    self.y += dy;
    self.clamp();
    self.noteMotion();
}

pub fn moveTo(self: *Self, x: f64, y: f64) void {
    const previous_x = self.x;
    const previous_y = self.y;
    const was_placed = self.placed;
    self.placed = true;
    self.x = x;
    self.y = y;
    self.clamp();
    if (was_placed and self.x == previous_x and self.y == previous_y) return;
    self.noteMotion();
}

pub fn setButton(self: *Self, button: vt.MouseButton, pressed: bool) void {
    switch (button) {
        .unknown, .four, .five, .six, .seven => return,
        else => {},
    }
    self.buttons[buttonSlot(button)] = pressed;
    if (self.tracking != .none) self.report = .{
        .action = if (pressed) .press else .release,
        .button = button,
    };
}

/// `vertical` and `horizontal` are v120 wheel units. Positive is down or right.
pub fn addWheel(self: *Self, vertical: f64, horizontal: f64) void {
    self.wheel[0] += vertical;
    self.wheel[1] += horizontal;
}

/// Touchpad or continuous scroll, in the same pixel units as pointer motion.
pub fn addPan(self: *Self, vertical: f64, horizontal: f64) void {
    self.finger[0] += vertical;
    self.finger[1] += horizontal;
}

/// Encode the next pointer effect into `buffer`, or null when this event
/// changes nothing the terminal or the viewport should see.
pub fn emit(self: *Self, mods: vt.KeyMods, buffer: []u8) !?Effect {
    if (self.hasScroll()) {
        if (self.tracking != .none) {
            const n = try self.writeScrollReports(mods, buffer);
            if (n > 0) return .{ .bytes = buffer[0..n] };
        } else if (self.alternate_scroll) {
            const n = try self.writeAlternateScroll(buffer);
            if (n > 0) return .{ .bytes = buffer[0..n] };
        } else if (self.scrollback) {
            const lines = self.takeVerticalClicks();
            if (lines != 0) return .{ .scroll_lines = lines };
        } else {
            self.discardScroll();
        }
    }
    if (self.report) |report| {
        self.report = null;
        const n = try self.writeAction(report.action, report.button, mods, buffer);
        if (n > 0) return .{ .bytes = buffer[0..n] };
    }
    return null;
}

fn noteMotion(self: *Self) void {
    if (self.tracking == .none) return;
    self.report = .{ .action = .motion, .button = self.heldButton() };
}

fn heldButton(self: *const Self) ?vt.MouseButton {
    // Lowest button number wins; the protocols have no chord encoding.
    const order = [_]vt.MouseButton{ .left, .right, .middle, .eight, .nine, .ten, .eleven };
    for (order) |button| {
        if (self.buttons[buttonSlot(button)]) return button;
    }
    return null;
}

fn anyPressed(self: *const Self) bool {
    return !std.mem.allEqual(bool, &self.buttons, false);
}

fn clamp(self: *Self) void {
    const max_x = @max(@as(f64, @floatFromInt(self.grid.screen_width)) - 1, 0);
    const max_y = @max(@as(f64, @floatFromInt(self.grid.screen_height)) - 1, 0);
    self.x = std.math.clamp(self.x, 0, max_x);
    self.y = std.math.clamp(self.y, 0, max_y);
}

fn hasScroll(self: *const Self) bool {
    const cell_h: f64 = @floatFromInt(self.grid.cell_height);
    const cell_w: f64 = @floatFromInt(self.grid.cell_width);
    return @abs(self.wheel[0]) >= 120 or @abs(self.wheel[1]) >= 120 or
        (cell_h > 0 and @abs(self.finger[0]) >= cell_h) or
        (cell_w > 0 and @abs(self.finger[1]) >= cell_w);
}

fn discardScroll(self: *Self) void {
    self.wheel = @splat(0);
    self.finger = @splat(0);
}

/// Whole vertical clicks from both scroll sources. Horizontal motion is dropped.
fn takeVerticalClicks(self: *Self) i32 {
    var lines: i32 = 0;
    lines += take(&self.wheel[0], 120, 100_000);
    if (self.grid.cell_height > 0)
        lines += take(&self.finger[0], @floatFromInt(self.grid.cell_height), 100_000);
    _ = take(&self.wheel[1], 120, 100_000);
    if (self.grid.cell_width > 0)
        _ = take(&self.finger[1], @floatFromInt(self.grid.cell_width), 100_000);
    return lines;
}

fn writeScrollReports(self: *Self, mods: vt.KeyMods, buffer: []u8) !usize {
    const cell_h: f64 = @floatFromInt(self.grid.cell_height);
    const cell_w: f64 = @floatFromInt(self.grid.cell_width);
    const sources = [_]*f64{ &self.wheel[0], &self.finger[0], &self.wheel[1], &self.finger[1] };
    const units = [_]f64{ 120, cell_h, 120, cell_w };
    const vertical = [_]bool{ true, true, false, false };
    var written: usize = 0;
    var progressed = true;
    while (progressed) {
        progressed = false;
        for (sources, units, vertical) |acc, unit, is_vertical| {
            const clicks = take(acc, unit, 1);
            if (clicks == 0) continue;
            const button: vt.MouseButton = if (is_vertical)
                (if (clicks > 0) .five else .four)
            else
                (if (clicks > 0) .seven else .six);
            const encoded = self.measureAction(.press, button, mods) catch |err| {
                acc.* += @as(f64, @floatFromInt(clicks)) * unit;
                return err;
            };
            if (encoded.len == 0) {
                // This protocol will not report the axis, so do not retry it.
                acc.* = 0;
                continue;
            }
            if (written + encoded.len > buffer.len) {
                acc.* += @as(f64, @floatFromInt(clicks)) * unit;
                if (written == 0) return error.BufferTooSmall;
                return written;
            }
            @memcpy(buffer[written..][0..encoded.len], encoded.bytes[0..encoded.len]);
            written += encoded.len;
            progressed = true;
        }
    }
    return written;
}

fn writeAlternateScroll(self: *Self, buffer: []u8) !usize {
    // Cursor keys only describe vertical movement.
    self.wheel[1] = 0;
    self.finger[1] = 0;
    const up = if (self.cursor_application) "\x1bOA" else "\x1b[A";
    const down = if (self.cursor_application) "\x1bOB" else "\x1b[B";
    const cell_h: f64 = @floatFromInt(self.grid.cell_height);
    var written: usize = 0;
    while (true) {
        const wheel_clicks = take(&self.wheel[0], 120, 1);
        const pan_clicks = if (wheel_clicks == 0 and cell_h > 0) take(&self.finger[0], cell_h, 1) else 0;
        const clicks = if (wheel_clicks != 0) wheel_clicks else pan_clicks;
        if (clicks == 0) return written;
        const seq = if (clicks > 0) down else up;
        if (written + seq.len > buffer.len) {
            if (wheel_clicks != 0) self.wheel[0] += @as(f64, @floatFromInt(clicks)) * 120 else self.finger[0] += @as(f64, @floatFromInt(clicks)) * cell_h;
            if (written == 0) return error.BufferTooSmall;
            return written;
        }
        @memcpy(buffer[written..][0..seq.len], seq);
        written += seq.len;
    }
}

const Encoded = struct { bytes: [64]u8 = undefined, len: usize = 0 };

fn writeAction(self: *Self, action: vt.MouseAction, button: ?vt.MouseButton, mods: vt.KeyMods, dest: []u8) !usize {
    const encoded = try self.measureAction(action, button, mods);
    if (encoded.len > dest.len) return error.BufferTooSmall;
    @memcpy(dest[0..encoded.len], encoded.bytes[0..encoded.len]);
    return encoded.len;
}

/// Encode one event into an owned buffer. Empty means the protocol ignores it.
fn measureAction(self: *Self, action: vt.MouseAction, button: ?vt.MouseButton, mods: vt.KeyMods) !Encoded {
    if (self.grid.cell_width == 0 or self.grid.cell_height == 0 or self.grid.columns == 0 or self.grid.rows == 0)
        return .{};
    var encoded = Encoded{};
    var writer = std.Io.Writer.fixed(&encoded.bytes);
    vt.encodeMouse(&writer, .{
        .action = action,
        .button = button,
        .mods = mods,
        .pos = self.encodePosition(),
    }, self.options()) catch return error.BufferTooSmall;
    encoded.len = writer.buffered().len;
    return encoded;
}

fn options(self: *Self) vt.MouseEncodeOptions {
    // Match the terminal grid exactly. Leftover display margin is clamped
    // onto the last cell instead of being reported as a different size.
    const width = @as(u32, self.grid.columns) * self.grid.cell_width;
    const height = @as(u32, self.grid.rows) * self.grid.cell_height;
    return .{
        .event = self.tracking,
        .format = self.format,
        .size = .{
            .screen = .{ .width = width, .height = height },
            .cell = .{ .width = self.grid.cell_width, .height = self.grid.cell_height },
            .padding = .{},
        },
        .any_button_pressed = self.anyPressed(),
        .last_cell = &self.last_cell,
    };
}

fn encodePosition(self: *const Self) vt.MouseEncodeEvent.Pos {
    const width = @as(f64, @floatFromInt(self.grid.columns)) * @as(f64, @floatFromInt(self.grid.cell_width));
    const height = @as(f64, @floatFromInt(self.grid.rows)) * @as(f64, @floatFromInt(self.grid.cell_height));
    return .{
        .x = @floatCast(std.math.clamp(self.x, 0, @max(width - 1, 0))),
        .y = @floatCast(std.math.clamp(self.y, 0, @max(height - 1, 0))),
    };
}

fn buttonSlot(button: vt.MouseButton) usize {
    return @intCast(@intFromEnum(button));
}

/// Remove up to `limit` whole units from acc. Positive results point down or right.
fn take(acc: *f64, unit: f64, limit: u32) i32 {
    if (!(unit > 0) or limit == 0 or !std.math.isFinite(acc.*)) {
        if (!std.math.isFinite(acc.*)) acc.* = 0;
        return 0;
    }
    var n = @trunc(acc.* / unit);
    if (!std.math.isFinite(n)) {
        acc.* = 0;
        return 0;
    }
    const cap: f64 = @floatFromInt(limit);
    n = std.math.clamp(n, -cap, cap);
    const clicks: i32 = @intFromFloat(n);
    if (clicks == 0) return 0;
    acc.* -= @as(f64, @floatFromInt(clicks)) * unit;
    return clicks;
}

const test_grid = Grid{
    .columns = 10,
    .rows = 5,
    .cell_width = 8,
    .cell_height = 16,
    .screen_width = 100,
    .screen_height = 80,
};

fn feed(term: *ghosttyvt.Terminal, seq: []const u8) void {
    var stream = ghosttyvt.TerminalStream.init(.{
        .allocator = std.testing.allocator,
        .handler = .init(term),
    });
    defer stream.deinit();
    stream.nextSlice(seq);
}

fn modesOf(term: *const ghosttyvt.Terminal, scrollback: bool) Modes {
    return .{
        .tracking = term.flags.mouse_event,
        .format = term.flags.mouse_format,
        .alternate_scroll = term.screens.active_key == .alternate and term.modes.get(.mouse_alternate_scroll),
        .cursor_application = term.modes.get(.cursor_keys),
        .scrollback = scrollback,
    };
}

fn expectBytes(effect: ?Effect, expected: []const u8) !void {
    const got = effect orelse return error.TestExpectedEqual;
    switch (got) {
        .bytes => |bytes| try std.testing.expectEqualStrings(expected, bytes),
        .scroll_lines => return error.TestUnexpectedResult,
    }
}

test "sgr tracking reports clicks, drags, wheels, and the display margin" {
    var term = try ghosttyvt.Terminal.init(std.testing.io, std.testing.allocator, .{ .cols = 10, .rows = 5 });
    defer term.deinit(std.testing.allocator);
    // Button-event tracking reports a held-button drag. SGR is the format.
    feed(&term, "\x1b[?1002h\x1b[?1006h");

    var mouse = Self{};
    mouse.configure(test_grid, modesOf(&term, true));
    var buffer: [128]u8 = undefined;

    mouse.moveTo(0, 0);
    try std.testing.expectEqual(@as(?Effect, null), try mouse.emit(.{}, &buffer));
    mouse.setButton(.left, true);
    try expectBytes(try mouse.emit(.{}, &buffer), "\x1b[<0;1;1M");
    // Motion inside the same cell is not reported again.
    mouse.moveTo(7, 15);
    try std.testing.expectEqual(@as(?Effect, null), try mouse.emit(.{}, &buffer));
    mouse.moveTo(8, 0);
    try expectBytes(try mouse.emit(.{}, &buffer), "\x1b[<32;2;1M");
    mouse.setButton(.left, false);
    try expectBytes(try mouse.emit(.{}, &buffer), "\x1b[<0;2;1m");

    mouse.moveTo(0, 0);
    _ = try mouse.emit(.{ .shift = true }, &buffer);
    mouse.setButton(.left, true);
    try expectBytes(try mouse.emit(.{ .shift = true }, &buffer), "\x1b[<4;1;1M");
    mouse.setButton(.left, false);
    _ = try mouse.emit(.{}, &buffer);

    // One logical wheel click is 120 v120 units, and two clicks share a report.
    mouse.addWheel(60, 0);
    try std.testing.expectEqual(@as(?Effect, null), try mouse.emit(.{}, &buffer));
    mouse.addWheel(180, 0);
    try expectBytes(try mouse.emit(.{}, &buffer), "\x1b[<65;1;1M\x1b[<65;1;1M");
    mouse.addWheel(0, -120);
    try expectBytes(try mouse.emit(.{}, &buffer), "\x1b[<66;1;1M");

    // Points in the margin past the grid land on the last cell.
    mouse.moveTo(90, 0);
    mouse.setButton(.right, true);
    try expectBytes(try mouse.emit(.{}, &buffer), "\x1b[<2;10;1M");
}

test "button and any-event modes report motion only as requested" {
    var term = try ghosttyvt.Terminal.init(std.testing.io, std.testing.allocator, .{ .cols = 10, .rows = 5 });
    defer term.deinit(std.testing.allocator);
    feed(&term, "\x1b[?1002h\x1b[?1006h");
    var mouse = Self{};
    mouse.configure(test_grid, modesOf(&term, true));
    var buffer: [64]u8 = undefined;
    mouse.moveTo(0, 0);
    try std.testing.expectEqual(@as(?Effect, null), try mouse.emit(.{}, &buffer));
    mouse.setButton(.left, true);
    _ = try mouse.emit(.{}, &buffer);
    mouse.moveTo(8, 0);
    try expectBytes(try mouse.emit(.{}, &buffer), "\x1b[<32;2;1M");

    feed(&term, "\x1b[?1003h");
    mouse.configure(test_grid, modesOf(&term, true));
    mouse.setButton(.left, false);
    _ = try mouse.emit(.{}, &buffer);
    mouse.moveTo(16, 16);
    try expectBytes(try mouse.emit(.{}, &buffer), "\x1b[<35;3;2M");
}

test "x10 reports the press and ignores the release and the wheel" {
    var term = try ghosttyvt.Terminal.init(std.testing.io, std.testing.allocator, .{ .cols = 10, .rows = 5 });
    defer term.deinit(std.testing.allocator);
    feed(&term, "\x1b[?9h");
    var mouse = Self{};
    mouse.configure(test_grid, modesOf(&term, true));
    var buffer: [32]u8 = undefined;
    mouse.moveTo(0, 0);
    mouse.setButton(.left, true);
    try expectBytes(try mouse.emit(.{}, &buffer), "\x1b[M !!");
    mouse.setButton(.left, false);
    try std.testing.expectEqual(@as(?Effect, null), try mouse.emit(.{}, &buffer));
    mouse.addWheel(-120, 0);
    try std.testing.expectEqual(@as(?Effect, null), try mouse.emit(.{}, &buffer));
}

test "untracked wheels scroll history, and the alternate screen sends arrows" {
    var term = try ghosttyvt.Terminal.init(std.testing.io, std.testing.allocator, .{ .cols = 10, .rows = 5 });
    defer term.deinit(std.testing.allocator);
    var mouse = Self{};
    mouse.configure(test_grid, modesOf(&term, true));
    var buffer: [32]u8 = undefined;
    mouse.addWheel(-120, 240);
    try std.testing.expectEqual(Effect{ .scroll_lines = -1 }, (try mouse.emit(.{}, &buffer)).?);
    mouse.addPan(8, 0);
    try std.testing.expectEqual(@as(?Effect, null), try mouse.emit(.{}, &buffer));
    mouse.addPan(8, 40);
    try std.testing.expectEqual(Effect{ .scroll_lines = 1 }, (try mouse.emit(.{}, &buffer)).?);

    mouse.configure(test_grid, modesOf(&term, false));
    mouse.addWheel(120, 0);
    try std.testing.expectEqual(@as(?Effect, null), try mouse.emit(.{}, &buffer));

    feed(&term, "\x1b[?1049h");
    mouse.configure(test_grid, modesOf(&term, false));
    mouse.addWheel(240, 120);
    try expectBytes(try mouse.emit(.{}, &buffer), "\x1b[B\x1b[B");
    feed(&term, "\x1b[?1h");
    mouse.configure(test_grid, modesOf(&term, false));
    mouse.addPan(-16, 0);
    try expectBytes(try mouse.emit(.{}, &buffer), "\x1bOA");
    feed(&term, "\x1b[?1007l");
    mouse.configure(test_grid, modesOf(&term, false));
    mouse.addWheel(120, 0);
    try std.testing.expectEqual(@as(?Effect, null), try mouse.emit(.{}, &buffer));
}

test "pointer motion starts at the center and stays on the display" {
    var mouse = Self{};
    mouse.configure(test_grid, .{});
    try std.testing.expect(mouse.pixel() == null);
    mouse.moveBy(10, -4);
    try std.testing.expectEqual(@as(u32, 60), mouse.pixel().?.x);
    try std.testing.expectEqual(@as(u32, 36), mouse.pixel().?.y);
    mouse.moveTo(1000, -20);
    try std.testing.expectEqual(@as(u32, 99), mouse.pixel().?.x);
    try std.testing.expectEqual(@as(u32, 0), mouse.pixel().?.y);
    mouse.moveTo(99, 0);
    try std.testing.expectEqual(@as(u32, 99), mouse.pixel().?.x);
}
