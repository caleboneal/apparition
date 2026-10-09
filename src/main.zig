const std = @import("std");
const Renderer = @import("renderer.zig");
const Input = @import("input.zig");

pub fn main(init: std.process.Init) !void {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    const font_path = args.next() orelse return error.MissingFontPath;

    var renderer = try Renderer.init();
    defer renderer.deinit();
    var input = try Input.init();
    defer input.deinit();

    var typed = std.mem.zeroes([512:0]u8);
    var typed_len: usize = 0;
    try renderDemo(&renderer, font_path, typed[0..typed_len :0]);

    std.debug.print("Type text; press Escape to quit.\n", .{});
    while (true) {
        try input.wait();

        var key_text: [8]u8 = undefined;
        var redraw = false;
        while (try input.next(&key_text)) |event| {
            switch (event) {
                .text => |text| {
                    if (typed_len + text.len <= typed.len) {
                        std.mem.copyForwards(u8, typed[typed_len..], text);
                        typed_len += text.len;
                        typed[typed_len] = 0;
                        redraw = true;
                    }
                },
                .backspace => {
                    if (typed_len > 0) {
                        typed_len -= 1;
                        while (typed_len > 0 and (typed[typed_len] & 0b1100_0000) == 0b1000_0000) {
                            typed_len -= 1;
                        }
                        typed[typed_len] = 0;
                        redraw = true;
                    }
                },
                .quit => return,
            }
        }

        if (redraw) try renderDemo(&renderer, font_path, typed[0..typed_len :0]);
    }
}

fn renderDemo(renderer: *Renderer, font_path: [*:0]const u8, typed: [:0]const u8) !void {
    renderer.clear(0x00000000);
    try renderer.drawText(font_path, "Apparition", 48, 48, 96, 0x00FFFFFF);
    try renderer.drawText(font_path, "Type below (Escape quits):", 24, 48, 150, 0x0000FF00);
    try renderer.drawText(font_path, typed.ptr, 32, 48, 210, 0x00FFFFFF);
    try renderer.present();
}
