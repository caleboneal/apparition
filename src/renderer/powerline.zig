//! Powerline separators (U+E0B0..U+E0BF), rasterized to fill whole cells so
//! filled shapes meet neighboring cell backgrounds exactly with any font.

const std = @import("std");
const segmentDistance = @import("box.zig").segmentDistance;

pub fn covers(codepoint: u21) bool {
    return codepoint >= 0xE0B0 and codepoint <= 0xE0BF;
}

/// Draw a coverage mask of width x height, owned by the caller. Thin
/// separators are `thickness` pixels wide.
pub fn draw(allocator: std.mem.Allocator, codepoint: u21, width: u32, height: u32, thickness: u32) ![]u8 {
    std.debug.assert(covers(codepoint));
    const pixels = try allocator.alloc(u8, @as(usize, width) * height);
    @memset(pixels, 0);
    const w: f32 = @floatFromInt(width);
    const h: f32 = @floatFromInt(height);
    const t: f32 = @floatFromInt(@max(1, thickness));
    const canvas = Canvas{ .pixels = pixels, .width = width, .height = height };
    switch (codepoint) {
        // Solid arrows pointing right and left.
        0xE0B0 => canvas.fill(Triangle{ .points = .{ .{ 0, 0 }, .{ w, h / 2 }, .{ 0, h } } }),
        0xE0B2 => canvas.fill(Triangle{ .points = .{ .{ w, 0 }, .{ 0, h / 2 }, .{ w, h } } }),
        // Thin arrows.
        0xE0B1 => canvas.fill(Chevron{ .tip = .{ w, h / 2 }, .back = 0, .height = h, .thickness = t }),
        0xE0B3 => canvas.fill(Chevron{ .tip = .{ 0, h / 2 }, .back = w, .height = h, .thickness = t }),
        // Solid and outlined half circles bulging right and left.
        0xE0B4 => canvas.fill(HalfEllipse{ .cx = 0, .rx = w, .ry = h / 2, .thickness = null }),
        0xE0B6 => canvas.fill(HalfEllipse{ .cx = w, .rx = w, .ry = h / 2, .thickness = null }),
        0xE0B5 => canvas.fill(HalfEllipse{ .cx = 0, .rx = w, .ry = h / 2, .thickness = t }),
        0xE0B7 => canvas.fill(HalfEllipse{ .cx = w, .rx = w, .ry = h / 2, .thickness = t }),
        // Lower-left, lower-right, upper-left, and upper-right triangles.
        0xE0B8 => canvas.fill(Triangle{ .points = .{ .{ 0, 0 }, .{ 0, h }, .{ w, h } } }),
        0xE0BA => canvas.fill(Triangle{ .points = .{ .{ w, 0 }, .{ w, h }, .{ 0, h } } }),
        0xE0BC => canvas.fill(Triangle{ .points = .{ .{ 0, 0 }, .{ w, 0 }, .{ 0, h } } }),
        0xE0BE => canvas.fill(Triangle{ .points = .{ .{ 0, 0 }, .{ w, 0 }, .{ w, h } } }),
        // Backslash and forward slash separators.
        0xE0B9, 0xE0BF => canvas.fill(Line{ .a = .{ 0, 0 }, .b = .{ w, h }, .thickness = t }),
        0xE0BB, 0xE0BD => canvas.fill(Line{ .a = .{ 0, h }, .b = .{ w, 0 }, .thickness = t }),
        else => unreachable,
    }
    return pixels;
}

const Point = [2]f32;

const Canvas = struct {
    pixels: []u8,
    width: u32,
    height: u32,

    /// Antialias `shape` with 4x4 samples per pixel.
    fn fill(self: Canvas, shape: anytype) void {
        const samples = 4;
        for (0..self.height) |y| {
            for (0..self.width) |x| {
                var hits: u32 = 0;
                for (0..samples) |sample_y| {
                    for (0..samples) |sample_x| {
                        const px = @as(f32, @floatFromInt(x)) + (@as(f32, @floatFromInt(sample_x)) + 0.5) / samples;
                        const py = @as(f32, @floatFromInt(y)) + (@as(f32, @floatFromInt(sample_y)) + 0.5) / samples;
                        if (shape.contains(px, py)) hits += 1;
                    }
                }
                self.pixels[y * self.width + x] = @intCast(hits * 255 / (samples * samples));
            }
        }
    }
};

const Triangle = struct {
    points: [3]Point,

    fn contains(self: Triangle, x: f32, y: f32) bool {
        var negative = false;
        var positive = false;
        for (0..3) |i| {
            const a = self.points[i];
            const b = self.points[(i + 1) % 3];
            const cross = (b[0] - a[0]) * (y - a[1]) - (b[1] - a[1]) * (x - a[0]);
            if (cross < 0) negative = true;
            if (cross > 0) positive = true;
        }
        return !(negative and positive);
    }
};

/// Two strokes from the corners on the `back` edge meeting at `tip`.
const Chevron = struct {
    tip: Point,
    back: f32,
    height: f32,
    thickness: f32,

    fn contains(self: Chevron, x: f32, y: f32) bool {
        const top = segmentDistance(x, y, self.back, 0, self.tip[0], self.tip[1]);
        const bottom = segmentDistance(x, y, self.back, self.height, self.tip[0], self.tip[1]);
        return @min(top, bottom) <= self.thickness / 2;
    }
};

const Line = struct {
    a: Point,
    b: Point,
    thickness: f32,

    fn contains(self: Line, x: f32, y: f32) bool {
        return segmentDistance(x, y, self.a[0], self.a[1], self.b[0], self.b[1]) <= self.thickness / 2;
    }
};

/// Half of an ellipse centered on the left (cx = 0) or right (cx = width)
/// edge at mid-height, filled or outlined `thickness` pixels inside its rim.
const HalfEllipse = struct {
    cx: f32,
    rx: f32,
    ry: f32,
    thickness: ?f32,

    fn inside(x: f32, y: f32, rx: f32, ry: f32) bool {
        if (rx <= 0 or ry <= 0) return false;
        return (x / rx) * (x / rx) + (y / ry) * (y / ry) <= 1;
    }

    fn contains(self: HalfEllipse, x: f32, y: f32) bool {
        const dx = x - self.cx;
        const dy = y - self.ry;
        if (!inside(dx, dy, self.rx, self.ry)) return false;
        const t = self.thickness orelse return true;
        return !inside(dx, dy, self.rx - t, self.ry - t);
    }
};

fn testDraw(codepoint: u21, width: u32, height: u32, thickness: u32) ![]u8 {
    return draw(std.testing.allocator, codepoint, width, height, thickness);
}

test "every separator draws within its cell" {
    for (0xE0B0..0xE0C0) |value| {
        const pixels = try testDraw(@intCast(value), 9, 17, 1);
        defer std.testing.allocator.free(pixels);
        try std.testing.expect(std.mem.indexOfNone(u8, pixels, &.{0}) != null);
        try std.testing.expect(std.mem.indexOfNone(u8, pixels, &.{255}) != null);
    }
}

test "left and right separators mirror each other" {
    const width = 9;
    const height = 17;
    const pairs = [_][2]u21{ .{ 0xE0B0, 0xE0B2 }, .{ 0xE0B1, 0xE0B3 }, .{ 0xE0B4, 0xE0B6 }, .{ 0xE0B5, 0xE0B7 }, .{ 0xE0B8, 0xE0BA }, .{ 0xE0BC, 0xE0BE } };
    for (pairs) |pair| {
        const right = try testDraw(pair[0], width, height, 1);
        defer std.testing.allocator.free(right);
        const left = try testDraw(pair[1], width, height, 1);
        defer std.testing.allocator.free(left);
        for (0..height) |y| {
            for (0..width) |x| try std.testing.expectEqual(right[y * width + x], left[y * width + width - 1 - x]);
        }
    }
}

test "filled separators cover their flat edge so they meet cell backgrounds" {
    const width = 9;
    const height = 17;
    for ([_]u21{ 0xE0B0, 0xE0B4 }) |codepoint| {
        const pixels = try testDraw(codepoint, width, height, 1);
        defer std.testing.allocator.free(pixels);
        for (1..height - 1) |y| try std.testing.expectEqual(@as(u8, 255), pixels[y * width]);
        // The far corners stay empty while the middle reaches the far edge.
        try std.testing.expectEqual(@as(u8, 0), pixels[width - 1]);
        try std.testing.expectEqual(@as(u8, 0), pixels[(height - 1) * width + width - 1]);
        try std.testing.expect(pixels[(height / 2) * width + width - 1] > 0);
    }
    const corner = try testDraw(0xE0BC, width, height, 1);
    defer std.testing.allocator.free(corner);
    // Pixels next to the tips are only partly covered.
    for (0..width - 2) |x| try std.testing.expectEqual(@as(u8, 255), corner[x]);
    for (0..height - 2) |y| try std.testing.expectEqual(@as(u8, 255), corner[y * width]);
    try std.testing.expectEqual(@as(u8, 0), corner[(height - 1) * width + width - 1]);
}

test "outlined half circle leaves its interior empty" {
    const width = 9;
    const height = 17;
    const pixels = try testDraw(0xE0B5, width, height, 1);
    defer std.testing.allocator.free(pixels);
    try std.testing.expectEqual(@as(u8, 0), pixels[(height / 2) * width + width / 2]);
    try std.testing.expect(pixels[(height / 2) * width + width - 1] > 0);
    try std.testing.expect(pixels[0] > 0);
}
