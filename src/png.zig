const std = @import("std");
const ghosttyvt = @import("ghostty-vt");
const png = @import("libpng");
const sys = ghosttyvt.sys;

/// Decode PNG data to 8-bit straight-alpha RGBA. libpng's simplified API
/// expands palettes, grayscale, tRNS transparency, and 16-bit channels.
/// Matches sys.DecodePngFn, so install it as ghosttyvt.sys.decode_png.
pub fn decode(allocator: std.mem.Allocator, data: []const u8) sys.DecodeError!sys.Image {
    var image = std.mem.zeroes(png.png_image);
    image.version = png.PNG_IMAGE_VERSION;
    if (png.png_image_begin_read_from_memory(&image, data.ptr, data.len) == 0) return error.InvalidData;
    // Freeing is a no-op once finish_read has released libpng's state.
    defer png.png_image_free(&image);

    image.format = png.PNG_FORMAT_RGBA;
    const stride = std.math.mul(u32, image.width, 4) catch return error.InvalidData;
    const row_stride = std.math.cast(i32, stride) orelse return error.InvalidData;
    const size = std.math.mul(usize, stride, image.height) catch return error.InvalidData;
    const pixels = try allocator.alloc(u8, size);
    errdefer allocator.free(pixels);
    if (png.png_image_finish_read(&image, null, pixels.ptr, row_stride, null) == 0) return error.InvalidData;
    return .{ .width = image.width, .height = image.height, .data = pixels };
}

fn encodeForTest(format: u32, width: u32, height: u32, pixels: []const u8, buffer: []u8) ![]const u8 {
    var image = std.mem.zeroes(png.png_image);
    image.version = png.PNG_IMAGE_VERSION;
    image.width = width;
    image.height = height;
    image.format = format;
    var size: png.png_alloc_size_t = buffer.len;
    if (png.png_image_write_to_memory(&image, buffer.ptr, &size, 0, pixels.ptr, 0, null) == 0)
        return error.EncodeFailed;
    return buffer[0..size];
}

test "decodes RGBA and expands grayscale to opaque RGBA" {
    const allocator = std.testing.allocator;
    var buffer: [512]u8 = undefined;

    const rgba = [_]u8{ 255, 0, 0, 255, 0, 255, 0, 128, 0, 0, 255, 0, 10, 20, 30, 40 };
    const encoded = try encodeForTest(png.PNG_FORMAT_RGBA, 2, 2, &rgba, &buffer);
    const decoded = try decode(allocator, encoded);
    defer allocator.free(decoded.data);
    try std.testing.expectEqual(@as(u32, 2), decoded.width);
    try std.testing.expectEqual(@as(u32, 2), decoded.height);
    try std.testing.expectEqualSlices(u8, &rgba, decoded.data);

    const gray = [_]u8{ 0, 200 };
    const gray_png = try encodeForTest(png.PNG_FORMAT_GRAY, 2, 1, &gray, &buffer);
    const expanded = try decode(allocator, gray_png);
    defer allocator.free(expanded.data);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 255, 200, 200, 200, 255 }, expanded.data);
}

test "rejects malformed and truncated data" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.InvalidData, decode(allocator, ""));
    try std.testing.expectError(error.InvalidData, decode(allocator, "not a png"));

    var buffer: [512]u8 = undefined;
    const pixels = [_]u8{ 1, 2, 3, 4 } ** 16;
    const encoded = try encodeForTest(png.PNG_FORMAT_RGBA, 4, 4, &pixels, &buffer);
    try std.testing.expectError(error.InvalidData, decode(allocator, encoded[0 .. encoded.len - 20]));
}

var test_decodes: usize = 0;

fn countingDecode(allocator: std.mem.Allocator, data: []const u8) sys.DecodeError!sys.Image {
    test_decodes += 1;
    return decode(allocator, data);
}

test "kitty graphics PNG transmissions decode through libpng" {
    const allocator = std.testing.allocator;
    const saved = sys.decode_png;
    defer sys.decode_png = saved;
    sys.decode_png = &countingDecode;
    test_decodes = 0;

    var term = try ghosttyvt.Terminal.init(std.testing.io, allocator, .{ .cols = 10, .rows = 5 });
    defer term.deinit(allocator);
    var stream = ghosttyvt.TerminalStream.init(.{ .allocator = allocator, .handler = .init(&term) });
    defer stream.deinit();

    var buffer: [512]u8 = undefined;
    const rgba = [_]u8{ 255, 0, 0, 255, 0, 255, 0, 128, 0, 0, 255, 0, 10, 20, 30, 40 };
    const encoded = try encodeForTest(png.PNG_FORMAT_RGBA, 2, 2, &rgba, &buffer);
    var base64: [std.base64.standard.Encoder.calcSize(512)]u8 = undefined;
    stream.nextSlice("\x1b_Ga=t,f=100,i=7,q=2;");
    stream.nextSlice(std.base64.standard.Encoder.encode(&base64, encoded));
    stream.nextSlice("\x1b\\");

    try std.testing.expectEqual(@as(usize, 1), test_decodes);
    const image = term.screens.active.kitty_images.imageById(7) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, 2), image.width);
    try std.testing.expectEqual(@as(u32, 2), image.height);
    try std.testing.expect(image.format == .rgba);
    try std.testing.expectEqualSlices(u8, &rgba, image.data.complete);
}

test "allocation failures surface as OutOfMemory" {
    var buffer: [512]u8 = undefined;
    const pixels = [_]u8{ 1, 2, 3, 4 } ** 4;
    const encoded = try encodeForTest(png.PNG_FORMAT_RGBA, 2, 2, &pixels, &buffer);
    try std.testing.expectError(error.OutOfMemory, decode(std.testing.failing_allocator, encoded));
}
