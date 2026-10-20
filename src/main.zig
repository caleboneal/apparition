const std = @import("std");
const Renderer = @import("renderer.zig");
const Input = @import("input.zig");
const Config = @import("config.zig");

const ghosttyvt = @import("ghostty-vt");

const config = Config{};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var renderer = try Renderer.init();
    defer renderer.deinit();

    const rows = 80;
    const cols = 24;

    var term = try ghosttyvt.Terminal.init(io, gpa, .{ .cols = cols, .rows = rows });
    defer term.deinit(gpa);

    var buf: [1920]u8 = undefined;
    @memset(&buf, 0);

    _ = try term.printAttributes(&buf);
}
