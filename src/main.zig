const std = @import("std");

const ghostty_vt = @import("ghostty-vt");

const GraphicsContext = @import("graphics.zig").GraphicsContext;

pub fn main() !void {
    var graphics_ctx = try GraphicsContext.init();
    defer graphics_ctx.deinit();
}
