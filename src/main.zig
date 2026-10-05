const std = @import("std");
const Renderer = @import("renderer.zig");

pub fn main(init: std.process.Init) !void {
    var renderer = try Renderer.init();
    defer renderer.deinit();

    renderer.clear(0x000000FF);
    renderer.fill_rect(0x0000FF00, Renderer.Rect{ .x = 0, .y = 0, .width = 20, .height = 20 });
    try renderer.present();

    std.debug.print("Rendering to screen for 5 seconds...\n", .{});
    try init.io.sleep(std.Io.Duration.fromSeconds(5), .real);
}
