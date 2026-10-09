const std = @import("std");
const Renderer = @import("renderer.zig");
const Input = @import("input.zig");

pub fn main(init: std.process.Init) !void {
    _ = init;

    var input = try Input.init();
    defer input.deinit();

    while (true) {
        try input.wait();
        input.poll();
    }
}
