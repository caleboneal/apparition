const std = @import("std");
const Renderer = @import("renderer.zig");

pub fn main(init: std.process.Init) !void {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    const font_path = args.next() orelse return error.MissingFontPath;

    var renderer = try Renderer.init();
    defer renderer.deinit();

    renderer.clear(0x00000000);
    try renderer.drawText(font_path, "Apparition", 48, 48, 96, 0x00FFFFFF);
    try renderer.present();

    renderer.clear(0x00000000);
    try renderer.drawText(font_path, "Apparition", 48, 48, 96, 0x00FFFFFF);
    try renderer.drawText(font_path, "FreeType rendering", 28, 48, 148, 0x0000FF00);
    try renderer.drawText(font_path, "Vsync page swap complete", 20, 48, 190, 0x00FFFFFF);
    try renderer.present();

    std.debug.print("Rendering text for 5 seconds...\n", .{});
    try init.io.sleep(std.Io.Duration.fromSeconds(5), .real);
}
