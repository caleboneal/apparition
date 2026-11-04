//! Box Drawing (U+2500..U+257F), rasterized to fill whole cells so lines join
//! across neighboring cells whatever the font's own glyphs and metrics.

const std = @import("std");

pub fn covers(codepoint: u21) bool {
    return codepoint >= 0x2500 and codepoint <= 0x257F;
}

const Weight = enum { none, light, heavy, double };

/// The stroke from each edge of the cell to its center.
const Lines = struct {
    up: Weight,
    right: Weight,
    down: Weight,
    left: Weight,
};

/// Weights up, right, down, and left: ' ' none, 'l' light, 'h' heavy,
/// 'd' double. Blank entries are dashes, arcs, and diagonals.
const table = [128]*const [4]u8{
    " l l", " h h", "l l ", "h h ", "    ", "    ", "    ", "    ", // 2500 ─━│┃┄┅┆┇
    "    ", "    ", "    ", "    ", " ll ", " hl ", " lh ", " hh ", // 2508 ┈┉┊┋┌┍┎┏
    "  ll", "  lh", "  hl", "  hh", "ll  ", "lh  ", "hl  ", "hh  ", // 2510 ┐┑┒┓└┕┖┗
    "l  l", "l  h", "h  l", "h  h", "lll ", "lhl ", "hll ", "llh ", // 2518 ┘┙┚┛├┝┞┟
    "hlh ", "hhl ", "lhh ", "hhh ", "l ll", "l lh", "h ll", "l hl", // 2520 ┠┡┢┣┤┥┦┧
    "h hl", "h lh", "l hh", "h hh", " lll", " llh", " hll", " hlh", // 2528 ┨┩┪┫┬┭┮┯
    " lhl", " lhh", " hhl", " hhh", "ll l", "ll h", "lh l", "lh h", // 2530 ┰┱┲┳┴┵┶┷
    "hl l", "hl h", "hh l", "hh h", "llll", "lllh", "lhll", "lhlh", // 2538 ┸┹┺┻┼┽┾┿
    "hlll", "llhl", "hlhl", "hllh", "hhll", "llhh", "lhhl", "hhlh", // 2540 ╀╁╂╃╄╅╆╇
    "lhhh", "hlhh", "hhhl", "hhhh", "    ", "    ", "    ", "    ", // 2548 ╈╉╊╋╌╍╎╏
    " d d", "d d ", " dl ", " ld ", " dd ", "  ld", "  dl", "  dd", // 2550 ═║╒╓╔╕╖╗
    "ld  ", "dl  ", "dd  ", "l  d", "d  l", "d  d", "ldl ", "dld ", // 2558 ╘╙╚╛╜╝╞╟
    "ddd ", "l ld", "d dl", "d dd", " dld", " ldl", " ddd", "ld d", // 2560 ╠╡╢╣╤╥╦╧
    "dl l", "dd d", "ldld", "dldl", "dddd", "    ", "    ", "    ", // 2568 ╨╩╪╫╬╭╮╯
    "    ", "    ", "    ", "    ", "   l", "l   ", " l  ", "  l ", // 2570 ╰╱╲╳╴╵╶╷
    "   h", "h   ", " h  ", "  h ", " h l", "l h ", " l h", "h l ", // 2578 ╸╹╺╻╼╽╾╿
};

fn lines(codepoint: u21) ?Lines {
    const entry = table[codepoint - 0x2500];
    if (std.mem.eql(u8, entry, "    ")) return null;
    var weights: [4]Weight = undefined;
    for (entry, &weights) |char, *weight| weight.* = switch (char) {
        ' ' => .none,
        'l' => .light,
        'h' => .heavy,
        'd' => .double,
        else => unreachable,
    };
    return .{ .up = weights[0], .right = weights[1], .down = weights[2], .left = weights[3] };
}

/// Draw a coverage mask of width x height, owned by the caller. Light lines
/// are `thickness` pixels; heavy lines and double line spacing derive from it.
pub fn draw(allocator: std.mem.Allocator, codepoint: u21, width: u32, height: u32, thickness: u32) ![]u8 {
    std.debug.assert(covers(codepoint));
    const pixels = try allocator.alloc(u8, @as(usize, width) * height);
    @memset(pixels, 0);
    var canvas = Canvas.init(pixels, width, height, @max(1, thickness));
    if (lines(codepoint)) |spec| {
        canvas.lines(spec);
        return pixels;
    }
    const light = canvas.light;
    const heavy = 2 * light;
    switch (codepoint) {
        0x2504 => canvas.dashes(.horizontal, 3, light, @max(4, light)),
        0x2505 => canvas.dashes(.horizontal, 3, heavy, @max(4, light)),
        0x2506 => canvas.dashes(.vertical, 3, light, @max(4, light)),
        0x2507 => canvas.dashes(.vertical, 3, heavy, @max(4, light)),
        0x2508 => canvas.dashes(.horizontal, 4, light, @max(4, light)),
        0x2509 => canvas.dashes(.horizontal, 4, heavy, @max(4, light)),
        0x250A => canvas.dashes(.vertical, 4, light, @max(4, light)),
        0x250B => canvas.dashes(.vertical, 4, heavy, @max(4, light)),
        0x254C => canvas.dashes(.horizontal, 2, light, light),
        0x254D => canvas.dashes(.horizontal, 2, heavy, heavy),
        0x254E => canvas.dashes(.vertical, 2, light, light),
        0x254F => canvas.dashes(.vertical, 2, heavy, heavy),
        // ╭ ╮ ╯ ╰
        0x256D => canvas.arc(1, 1),
        0x256E => canvas.arc(-1, 1),
        0x256F => canvas.arc(-1, -1),
        0x2570 => canvas.arc(1, -1),
        0x2571 => canvas.diagonal(true),
        0x2572 => canvas.diagonal(false),
        0x2573 => {
            canvas.diagonal(true);
            canvas.diagonal(false);
        },
        else => unreachable,
    }
    return pixels;
}

/// Pixel bounds of centered strokes along one axis of the cell.
const Strokes = struct {
    light: [2]u32,
    heavy: [2]u32,
    /// Outer edges of a double line; its inner edges are the light stroke's.
    double: [2]u32,

    fn init(size: u32, light: u32) Strokes {
        const light_start = (size -| light) / 2;
        const heavy_start = (size -| 2 * light) / 2;
        return .{
            .light = .{ light_start, light_start + light },
            .heavy = .{ heavy_start, heavy_start + 2 * light },
            .double = .{ light_start -| light, light_start + 2 * light },
        };
    }

    /// The span a perpendicular arm overlaps at the center, given the two
    /// opposing arms there; `through` arms cross every stroke.
    fn junction(self: Strokes, a: Weight, b: Weight, through: bool) [2]u32 {
        if (a == .heavy or b == .heavy) return self.heavy;
        if (!through) return .{ self.light[1], self.light[0] };
        return if (a == .double or b == .double) self.double else self.light;
    }
};

const Canvas = struct {
    pixels: []u8,
    width: u32,
    height: u32,
    light: u32,
    /// Horizontal strokes, by y.
    rows: Strokes,
    /// Vertical strokes, by x.
    columns: Strokes,

    fn init(pixels: []u8, width: u32, height: u32, light: u32) Canvas {
        return .{
            .pixels = pixels,
            .width = width,
            .height = height,
            .light = light,
            .rows = .init(height, light),
            .columns = .init(width, light),
        };
    }

    /// Fill the half-open rectangle [x0, x1) x [y0, y1), clipped to the cell.
    fn rect(self: *Canvas, x0: u32, y0: u32, x1: u32, y1: u32) void {
        for (@min(y0, self.height)..@min(y1, self.height)) |y| {
            const start = @min(x0, self.width);
            @memset(self.pixels[y * self.width ..][start..@max(start, @min(x1, self.width))], 255);
        }
    }

    fn lines(self: *Canvas, spec: Lines) void {
        const rows = self.rows;
        const columns = self.columns;
        // A vertical arm stops at the near edge of a horizontal line that
        // passes straight through without it, and crosses it otherwise.
        const vertical_through = spec.left != spec.right or spec.up == spec.down or spec.left == .none;
        const horizontal_through = spec.up != spec.down or spec.left == spec.right or spec.up == .none;
        const across = rows.junction(spec.left, spec.right, vertical_through);
        const along = columns.junction(spec.up, spec.down, horizontal_through);
        // Up and left arms end at the far side of the junction; down and right
        // arms start at its near side.
        const up_end = across[1];
        const down_start = across[0];
        const left_end = along[1];
        const right_start = along[0];

        switch (spec.up) {
            .none => {},
            .light => self.rect(columns.light[0], 0, columns.light[1], up_end),
            .heavy => self.rect(columns.heavy[0], 0, columns.heavy[1], up_end),
            // Double lines turning into each other form nested corners.
            .double => {
                self.rect(columns.double[0], 0, columns.light[0], if (spec.left == .double) rows.light[0] else up_end);
                self.rect(columns.light[1], 0, columns.double[1], if (spec.right == .double) rows.light[0] else up_end);
            },
        }
        switch (spec.down) {
            .none => {},
            .light => self.rect(columns.light[0], down_start, columns.light[1], self.height),
            .heavy => self.rect(columns.heavy[0], down_start, columns.heavy[1], self.height),
            .double => {
                self.rect(columns.double[0], if (spec.left == .double) rows.light[1] else down_start, columns.light[0], self.height);
                self.rect(columns.light[1], if (spec.right == .double) rows.light[1] else down_start, columns.double[1], self.height);
            },
        }
        switch (spec.left) {
            .none => {},
            .light => self.rect(0, rows.light[0], left_end, rows.light[1]),
            .heavy => self.rect(0, rows.heavy[0], left_end, rows.heavy[1]),
            .double => {
                self.rect(0, rows.double[0], if (spec.up == .double) columns.light[0] else left_end, rows.light[0]);
                self.rect(0, rows.light[1], if (spec.down == .double) columns.light[0] else left_end, rows.double[1]);
            },
        }
        switch (spec.right) {
            .none => {},
            .light => self.rect(right_start, rows.light[0], self.width, rows.light[1]),
            .heavy => self.rect(right_start, rows.heavy[0], self.width, rows.heavy[1]),
            .double => {
                self.rect(if (spec.up == .double) columns.light[1] else right_start, rows.double[0], self.width, rows.light[0]);
                self.rect(if (spec.down == .double) columns.light[1] else right_start, rows.light[1], self.width, rows.double[1]);
            },
        }
    }

    /// Evenly sized dashes that tile into a uniform line. Horizontal dashes
    /// center with half gaps at each end; vertical dashes leave their gap at
    /// the bottom so they meet solid lines above.
    fn dashes(self: *Canvas, comptime axis: enum { horizontal, vertical }, count: u32, thickness: u32, desired_gap: u32) void {
        const length = if (axis == .horizontal) self.width else self.height;
        const across = if (axis == .horizontal) self.height else self.width;
        const offset = (across -| thickness) / 2;
        if (length < 2 * count) {
            if (axis == .horizontal) self.rect(0, offset, length, offset + thickness) else self.rect(offset, 0, offset + thickness, length);
            return;
        }
        const gap = @min(desired_gap, length / (2 * count));
        const dash_total = length - count * gap;
        var extra = dash_total % count;
        var position: u32 = if (axis == .horizontal) gap / 2 else 0;
        for (0..count) |_| {
            var end = position + dash_total / count;
            if (extra > 0) {
                extra -= 1;
                end += 1;
            }
            if (axis == .horizontal) self.rect(position, offset, end, offset + thickness) else self.rect(offset, position, offset + thickness, end);
            position = end + gap;
        }
    }

    /// A light rounded corner whose arms run toward the right (sx = 1) or
    /// left (sx = -1) edge and the bottom (sy = 1) or top (sy = -1) edge.
    fn arc(self: *Canvas, sx: f32, sy: f32) void {
        const light: f32 = @floatFromInt(self.light);
        const width: f32 = @floatFromInt(self.width);
        const height: f32 = @floatFromInt(self.height);
        const cx = @as(f32, @floatFromInt(self.columns.light[0])) + light / 2;
        const cy = @as(f32, @floatFromInt(self.rows.light[0])) + light / 2;
        const radius = @min(width, height) / 2;
        self.stroke(Arc{
            .cx = cx,
            .cy = cy,
            .radius = radius,
            .sx = sx,
            .sy = sy,
            .edge_x = if (sx > 0) width + 1 else -1,
            .edge_y = if (sy > 0) height + 1 else -1,
        }, light);
    }

    /// A light line between opposite corners, rising to the upper right or
    /// falling to the lower right.
    fn diagonal(self: *Canvas, rising: bool) void {
        const width: f32 = @floatFromInt(self.width);
        const height: f32 = @floatFromInt(self.height);
        self.stroke(Diagonal{
            .x0 = 0,
            .y0 = if (rising) height else 0,
            .x1 = width,
            .y1 = if (rising) 0 else height,
        }, @floatFromInt(self.light));
    }

    /// Antialias `shape` with 4x4 samples per pixel, covering samples within
    /// half the stroke width of it.
    fn stroke(self: *Canvas, shape: anytype, width: f32) void {
        const samples = 4;
        for (0..self.height) |y| {
            for (0..self.width) |x| {
                var hits: u32 = 0;
                for (0..samples) |sample_y| {
                    for (0..samples) |sample_x| {
                        const px = @as(f32, @floatFromInt(x)) + (@as(f32, @floatFromInt(sample_x)) + 0.5) / samples;
                        const py = @as(f32, @floatFromInt(y)) + (@as(f32, @floatFromInt(sample_y)) + 0.5) / samples;
                        if (shape.distance(px, py) <= width / 2) hits += 1;
                    }
                }
                const pixel = &self.pixels[y * self.width + x];
                pixel.* = @max(pixel.*, @as(u8, @intCast(hits * 255 / (samples * samples))));
            }
        }
    }
};

pub fn segmentDistance(x: f32, y: f32, ax: f32, ay: f32, bx: f32, by: f32) f32 {
    const dx = bx - ax;
    const dy = by - ay;
    const t = std.math.clamp(((x - ax) * dx + (y - ay) * dy) / (dx * dx + dy * dy), 0, 1);
    return std.math.hypot(x - (ax + t * dx), y - (ay + t * dy));
}

/// Two straight arms from the cell edges joined by a quarter circle.
const Arc = struct {
    cx: f32,
    cy: f32,
    radius: f32,
    sx: f32,
    sy: f32,
    edge_x: f32,
    edge_y: f32,

    fn distance(self: Arc, x: f32, y: f32) f32 {
        const center_x = self.cx + self.sx * self.radius;
        const center_y = self.cy + self.sy * self.radius;
        var nearest = @min(
            segmentDistance(x, y, self.cx, center_y, self.cx, self.edge_y),
            segmentDistance(x, y, center_x, self.cy, self.edge_x, self.cy),
        );
        const dx = x - center_x;
        const dy = y - center_y;
        // Only the quarter of the circle facing the cell's center is drawn.
        if (dx * self.sx <= 0 and dy * self.sy <= 0) nearest = @min(nearest, @abs(std.math.hypot(dx, dy) - self.radius));
        return nearest;
    }
};

/// A line through two points, extending past the cell's corners.
const Diagonal = struct {
    x0: f32,
    y0: f32,
    x1: f32,
    y1: f32,

    fn distance(self: Diagonal, x: f32, y: f32) f32 {
        const dx = self.x1 - self.x0;
        const dy = self.y1 - self.y0;
        return @abs((x - self.x0) * dy - (y - self.y0) * dx) / std.math.hypot(dx, dy);
    }
};

fn testDraw(codepoint: u21, width: u32, height: u32, thickness: u32) ![]u8 {
    return draw(std.testing.allocator, codepoint, width, height, thickness);
}

fn expectRows(pixels: []const u8, width: u32, expected: []const []const u8) !void {
    for (expected, 0..) |row, y| {
        for (row, 0..) |char, x| {
            try std.testing.expectEqual(@as(u8, if (char == '#') 255 else 0), pixels[y * width + x]);
        }
    }
}

test "light, heavy and double lines span the cell edge to edge" {
    const horizontal = try testDraw(0x2500, 5, 5, 1);
    defer std.testing.allocator.free(horizontal);
    try expectRows(horizontal, 5, &.{ ".....", ".....", "#####", ".....", "....." });
    const heavy = try testDraw(0x2503, 6, 3, 1);
    defer std.testing.allocator.free(heavy);
    try expectRows(heavy, 6, &.{ "..##..", "..##..", "..##.." });
    const double = try testDraw(0x2550, 3, 7, 1);
    defer std.testing.allocator.free(double);
    try expectRows(double, 3, &.{ "...", "...", "###", "...", "###", "...", "..." });
}

test "corners and junctions join at the center, and double corners nest" {
    const corner = try testDraw(0x250C, 5, 5, 1);
    defer std.testing.allocator.free(corner);
    try expectRows(corner, 5, &.{ ".....", ".....", "..###", "..#..", "..#.." });
    const cross = try testDraw(0x254B, 6, 6, 1);
    defer std.testing.allocator.free(cross);
    try expectRows(cross, 6, &.{ "..##..", "..##..", "######", "######", "..##..", "..##.." });
    const nested = try testDraw(0x2554, 7, 7, 1);
    defer std.testing.allocator.free(nested);
    try expectRows(nested, 7, &.{ ".......", ".......", "..#####", "..#....", "..#.###", "..#.#..", "..#.#.." });
    const double_cross = try testDraw(0x256C, 7, 7, 1);
    defer std.testing.allocator.free(double_cross);
    try expectRows(double_cross, 7, &.{ "..#.#..", "..#.#..", "###.###", ".......", "###.###", "..#.#..", "..#.#.." });
    // A light stub meets only the nearer stroke of a double line.
    const stub = try testDraw(0x2567, 7, 7, 1);
    defer std.testing.allocator.free(stub);
    try expectRows(stub, 7, &.{ "...#...", "...#...", "#######", ".......", "#######", ".......", "......." });
}

test "every character reaches the edges its lines point to" {
    const width = 9;
    const height = 17;
    for (0x2500..0x2580) |value| {
        const codepoint: u21 = @intCast(value);
        const pixels = try testDraw(codepoint, width, height, 1);
        defer std.testing.allocator.free(pixels);
        try std.testing.expect(std.mem.indexOfNone(u8, pixels, &.{0}) != null);
        const spec = lines(codepoint) orelse continue;
        const middle_x = width / 2;
        const middle_y = height / 2;
        const touches = struct {
            fn run(p: []const u8, x0: usize, y0: usize, dx: usize, dy: usize, span: usize) bool {
                for (0..span) |i| {
                    if (p[(y0 + i * dy) * width + x0 + i * dx] == 255) return true;
                }
                return false;
            }
        }.run;
        // Check a band around the center, wide enough for doubled strokes.
        if (spec.up != .none) try std.testing.expect(touches(pixels, middle_x - 2, 0, 1, 0, 5));
        if (spec.down != .none) try std.testing.expect(touches(pixels, middle_x - 2, height - 1, 1, 0, 5));
        if (spec.left != .none) try std.testing.expect(touches(pixels, 0, middle_y - 2, 0, 1, 5));
        if (spec.right != .none) try std.testing.expect(touches(pixels, width - 1, middle_y - 2, 0, 1, 5));
    }
}

test "dashes tile evenly and arcs meet straight lines at the edges" {
    const dashed = try testDraw(0x2504, 12, 3, 1);
    defer std.testing.allocator.free(dashed);
    try expectRows(dashed, 12, &.{ "............", ".##..##..##.", "............" });
    const vertical = try testDraw(0x254E, 3, 8, 1);
    defer std.testing.allocator.free(vertical);
    try expectRows(vertical, 3, &.{ ".#.", ".#.", ".#.", "...", ".#.", ".#.", ".#.", "..." });
    // ╭ must line up with │ below and ─ to the right.
    const arc = try testDraw(0x256D, 9, 17, 1);
    defer std.testing.allocator.free(arc);
    try std.testing.expectEqual(@as(u8, 255), arc[16 * 9 + 4]);
    try std.testing.expectEqual(@as(u8, 0), arc[16 * 9 + 3]);
    try std.testing.expectEqual(@as(u8, 255), arc[8 * 9 + 8]);
    try std.testing.expectEqual(@as(u8, 0), arc[7 * 9 + 8]);
    try std.testing.expectEqual(@as(u8, 0), arc[0]);
}
