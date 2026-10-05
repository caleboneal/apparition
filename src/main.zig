const std = @import("std");
const Context = @import("graphics/context.zig");

pub fn main(init: std.process.Init) !void {
    var context = try Context.init();
    defer context.deinit();

    context.clear(0x000000FF);
    try context.present();

    std.debug.print("Rendering to screen for 5 seconds...\n", .{});
    try init.io.sleep(std.Io.Duration.fromSeconds(5), .real);
}
