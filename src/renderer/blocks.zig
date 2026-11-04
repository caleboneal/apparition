//! Block elements (U+2580..U+259F), rasterized to exact cell fractions so
//! halves, eighths, and quadrants tile seamlessly with any font.

const std = @import("std");

pub fn covers(codepoint: u21) bool {
    return codepoint >= 0x2580 and codepoint <= 0x259F;
}

const upper_left = 1;
const upper_right = 2;
const lower_left = 4;
const lower_right = 8;

/// Draw a coverage mask of width x height, owned by the caller.
pub fn draw(allocator: std.mem.Allocator, codepoint: u21, width: u32, height: u32) ![]u8 {
    std.debug.assert(covers(codepoint));
    const pixels = try allocator.alloc(u8, @as(usize, width) * height);
    @memset(pixels, 0);
    const canvas = Canvas{ .pixels = pixels, .width = width, .height = height };
    switch (codepoint) {
        // ▀ and ▔
        0x2580 => canvas.fill(0, width, 0, frac(height, 4), 255),
        0x2594 => canvas.fill(0, width, 0, frac(height, 1), 255),
        // ▁ through █, growing up from the bottom in eighths.
        0x2581...0x2588 => canvas.fill(0, width, frac(height, 8 - (codepoint - 0x2580)), height, 255),
        // ▉ through ▏, shrinking toward the left in eighths.
        0x2589...0x258F => canvas.fill(0, frac(width, 8 - (codepoint - 0x2588)), 0, height, 255),
        // ▐ and ▕
        0x2590 => canvas.fill(frac(width, 4), width, 0, height, 255),
        0x2595 => canvas.fill(frac(width, 7), width, 0, height, 255),
        // ░ ▒ ▓
        0x2591...0x2593 => canvas.fill(0, width, 0, height, @intCast(64 * (codepoint - 0x2590))),
        0x2596 => canvas.quadrants(lower_left),
        0x2597 => canvas.quadrants(lower_right),
        0x2598 => canvas.quadrants(upper_left),
        0x2599 => canvas.quadrants(upper_left | lower_left | lower_right),
        0x259A => canvas.quadrants(upper_left | lower_right),
        0x259B => canvas.quadrants(upper_left | upper_right | lower_left),
        0x259C => canvas.quadrants(upper_left | upper_right | lower_right),
        0x259D => canvas.quadrants(upper_right),
        0x259E => canvas.quadrants(upper_right | lower_left),
        0x259F => canvas.quadrants(upper_right | lower_left | lower_right),
        else => unreachable,
    }
    return pixels;
}

/// The pixel boundary `eighths`/8 of the way across size, rounded.
fn frac(size: u32, eighths: u32) u32 {
    return (size * eighths + 4) / 8;
}

const Canvas = struct {
    pixels: []u8,
    width: u32,
    height: u32,

    fn fill(self: Canvas, x0: u32, x1: u32, y0: u32, y1: u32, alpha: u8) void {
        for (y0..y1) |y| @memset(self.pixels[y * self.width ..][x0..x1], alpha);
    }

    fn quadrants(self: Canvas, mask: u4) void {
        const mid_x = frac(self.width, 4);
        const mid_y = frac(self.height, 4);
        if (mask & upper_left != 0) self.fill(0, mid_x, 0, mid_y, 255);
        if (mask & upper_right != 0) self.fill(mid_x, self.width, 0, mid_y, 255);
        if (mask & lower_left != 0) self.fill(0, mid_x, mid_y, self.height, 255);
        if (mask & lower_right != 0) self.fill(mid_x, self.width, mid_y, self.height, 255);
    }
};

fn testDraw(codepoint: u21, width: u32, height: u32) ![]u8 {
    return draw(std.testing.allocator, codepoint, width, height);
}

fn expectRows(pixels: []const u8, width: usize, rows: []const []const u8) !void {
    try std.testing.expectEqual(rows.len * width, pixels.len);
    for (rows, 0..) |row, y| {
        for (row, 0..) |char, x| {
            try std.testing.expectEqual(@as(u8, if (char == '#') 255 else 0), pixels[y * width + x]);
        }
    }
}

test "every block element draws something within its cell" {
    for (0x2580..0x25A0) |value| {
        const pixels = try testDraw(@intCast(value), 9, 17);
        defer std.testing.allocator.free(pixels);
        try std.testing.expect(std.mem.indexOfNone(u8, pixels, &.{0}) != null);
    }
}

test "complementary halves and eighths tile the cell exactly" {
    const width = 7;
    const height = 13;
    const pairs = [_][2]u21{ .{ 0x2580, 0x2584 }, .{ 0x258C, 0x2590 }, .{ 0x2594, 0x2587 }, .{ 0x2589, 0x2595 }, .{ 0x259A, 0x259E }, .{ 0x2596, 0x259C } };
    for (pairs) |pair| {
        const a = try testDraw(pair[0], width, height);
        defer std.testing.allocator.free(a);
        const b = try testDraw(pair[1], width, height);
        defer std.testing.allocator.free(b);
        for (a, b) |left, right| try std.testing.expectEqual(@as(u16, 255), @as(u16, left) + right);
    }
}

test "block elements fill exact fractions" {
    const lower_quarter = try testDraw(0x2582, 3, 8);
    defer std.testing.allocator.free(lower_quarter);
    try expectRows(lower_quarter, 3, &.{ "...", "...", "...", "...", "...", "...", "###", "###" });
    const left_three_eighths = try testDraw(0x258D, 8, 2);
    defer std.testing.allocator.free(left_three_eighths);
    try expectRows(left_three_eighths, 8, &.{ "###.....", "###....." });
    const quadrants = try testDraw(0x2599, 4, 4);
    defer std.testing.allocator.free(quadrants);
    try expectRows(quadrants, 4, &.{ "##..", "##..", "####", "####" });
    const full = try testDraw(0x2588, 2, 2);
    defer std.testing.allocator.free(full);
    try expectRows(full, 2, &.{ "##", "##" });
}

test "shades are uniform and increasingly dense" {
    var previous: u8 = 0;
    for ([_]u21{ 0x2591, 0x2592, 0x2593 }) |codepoint| {
        const pixels = try testDraw(codepoint, 3, 3);
        defer std.testing.allocator.free(pixels);
        try std.testing.expect(pixels[0] > previous and pixels[0] < 255);
        for (pixels) |pixel| try std.testing.expectEqual(pixels[0], pixel);
        previous = pixels[0];
    }
}
