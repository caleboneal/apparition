const std = @import("std");
const ghosttyvt = @import("ghostty-vt");

pub const foreground: ghosttyvt.color.RGB = .{ .r = 0xE5, .g = 0xE5, .b = 0xE5 };
pub const background: ghosttyvt.color.RGB = .{ .r = 0, .g = 0, .b = 0 };

// libghostty's first sixteen defaults are a theme, not xterm's ANSI palette.
// Keep its standard 6x6x6 cube and grayscale ramp for indices 16..255.
pub const palette: ghosttyvt.color.Palette = palette: {
    var result = ghosttyvt.color.default;
    const ansi = [_]u32{
        0x000000, 0xCD0000, 0x00CD00, 0xCDCD00,
        0x0000EE, 0xCD00CD, 0x00CDCD, 0xE5E5E5,
        0x7F7F7F, 0xFF0000, 0x00FF00, 0xFFFF00,
        0x5C5CFF, 0xFF00FF, 0x00FFFF, 0xFFFFFF,
    };
    for (ansi, 0..) |rgb, i| result[i] = .{
        .r = @intCast((rgb >> 16) & 0xFF),
        .g = @intCast((rgb >> 8) & 0xFF),
        .b = @intCast(rgb & 0xFF),
    };
    break :palette result;
};

/// Configure a newly initialized terminal, before feeding it any output.
/// changeDefault owns the palette copy so OSC resets restore our defaults.
pub fn configure(term: *ghosttyvt.Terminal, allocator: std.mem.Allocator) !void {
    try term.colors.palette.changeDefault(allocator, palette);
    term.colors.foreground = .init(foreground);
    term.colors.background = .init(background);
}

test "xterm palette includes ANSI colors, cube and grayscale" {
    try std.testing.expectEqual(ghosttyvt.color.RGB{ .r = 0xCD, .g = 0, .b = 0 }, palette[1]);
    try std.testing.expectEqual(ghosttyvt.color.RGB{ .r = 0, .g = 0, .b = 0xEE }, palette[4]);
    try std.testing.expectEqual(ghosttyvt.color.RGB{ .r = 255, .g = 0, .b = 0 }, palette[9]);
    try std.testing.expectEqual(ghosttyvt.color.RGB{ .r = 0, .g = 0, .b = 0 }, palette[16]);
    try std.testing.expectEqual(ghosttyvt.color.RGB{ .r = 255, .g = 255, .b = 255 }, palette[231]);
    try std.testing.expectEqual(ghosttyvt.color.RGB{ .r = 8, .g = 8, .b = 8 }, palette[232]);
    try std.testing.expectEqual(ghosttyvt.color.RGB{ .r = 238, .g = 238, .b = 238 }, palette[255]);
}

test "OSC palette and default-color overrides reset to configured colors" {
    var term = try ghosttyvt.Terminal.init(std.testing.io, std.testing.allocator, .{ .cols = 4, .rows = 1 });
    defer term.deinit(std.testing.allocator);
    try configure(&term, std.testing.allocator);
    var stream = ghosttyvt.TerminalStream.init(.{ .allocator = std.testing.allocator, .handler = .init(&term) });
    defer stream.deinit();
    stream.nextSlice("\x1b]4;1;#123456\x07\x1b]10;#abcdef\x07\x1b]11;#010203\x07");
    try std.testing.expectEqual(ghosttyvt.color.RGB{ .r = 0x12, .g = 0x34, .b = 0x56 }, term.colors.palette.current[1]);
    try std.testing.expectEqual(ghosttyvt.color.RGB{ .r = 0xAB, .g = 0xCD, .b = 0xEF }, term.colors.foreground.get().?);
    try std.testing.expectEqual(ghosttyvt.color.RGB{ .r = 1, .g = 2, .b = 3 }, term.colors.background.get().?);
    stream.nextSlice("\x1b]104;1\x07\x1b]110\x07\x1b]111\x07");
    try std.testing.expectEqual(palette[1], term.colors.palette.current[1]);
    try std.testing.expectEqual(foreground, term.colors.foreground.get().?);
    try std.testing.expectEqual(background, term.colors.background.get().?);
}
