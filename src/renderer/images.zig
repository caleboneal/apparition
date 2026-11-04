const std = @import("std");
const ghosttyvt = @import("ghostty-vt");
const Storage = ghosttyvt.kitty.graphics.ImageStorage;

/// Kitty draws z below INT32_MIN/2 under cell backgrounds, other negative z
/// under text, and z >= 0 over text.
pub const Layer = enum { below_background, below_text, above_text };

pub fn layer(z: i32) Layer {
    if (z < std.math.minInt(i32) / 2) return .below_background;
    return if (z < 0) .below_text else .above_text;
}

/// Everything that decides which pixels a placement covers and what they show.
/// Two frames with equal geometry lists draw identical images.
pub const Geometry = struct {
    image_id: u32,
    placement_id: Storage.PlacementId,
    generation: u64,
    z: i32,
    /// Destination in display pixels; may extend past the grid on any side.
    x: i64,
    y: i64,
    width: u32,
    height: u32,
    source: Storage.Placement.SourceRect,
};

pub const Format = enum { rgb, rgba, gray, gray_alpha };

/// A placement resolved for one frame. data borrows the terminal's image
/// storage, so it is only valid until the terminal next processes output.
pub const Visible = struct {
    geometry: Geometry,
    format: Format,
    image_width: u32,
    data: []const u8,

    /// Straight-alpha RGBA of the source pixel shown at display pixel (x, y),
    /// which must lie inside the destination rectangle.
    pub fn sample(self: Visible, x: i64, y: i64) [4]u8 {
        return self.pixel(self.row(y), x);
    }

    /// The source row shown on display row y, for pixel.
    pub fn row(self: Visible, y: i64) []const u8 {
        const g = self.geometry;
        const sy = g.source.y + scale(y - g.y, g.source.height, g.height);
        return self.data[@as(usize, sy) * self.image_width * bytesPerPixel(self.format) ..];
    }

    /// Straight-alpha RGBA shown at display column x of a source row.
    pub fn pixel(self: Visible, source_row: []const u8, x: i64) [4]u8 {
        const g = self.geometry;
        const sx = g.source.x + scale(x - g.x, g.source.width, g.width);
        const p = source_row[@as(usize, sx) * bytesPerPixel(self.format) ..];
        return switch (self.format) {
            .rgb => .{ p[0], p[1], p[2], 255 },
            .rgba => .{ p[0], p[1], p[2], p[3] },
            .gray => .{ p[0], p[0], p[0], 255 },
            .gray_alpha => .{ p[0], p[0], p[0], p[1] },
        };
    }
};

/// Nearest-neighbor mapping of a destination offset onto the source extent.
fn scale(offset: i64, source: u32, destination: u32) u32 {
    return @intCast(@divFloor(@as(u64, @intCast(offset)) * source, destination));
}

fn bytesPerPixel(format: Format) usize {
    return switch (format) {
        .rgb => 3,
        .rgba => 4,
        .gray => 1,
        .gray_alpha => 2,
    };
}

fn lessThan(_: void, a: Visible, b: Visible) bool {
    const ga = a.geometry;
    const gb = b.geometry;
    if (ga.z != gb.z) return ga.z < gb.z;
    if (ga.image_id != gb.image_id) return ga.image_id < gb.image_id;
    return gb.placement_id.preferredOver(ga.placement_id);
}

/// Replace list with the placements that overlap the grid in the current
/// viewport, sorted bottom to top. Virtual (Unicode placeholder) placements
/// and chains rooted at them are not drawn.
pub fn collect(
    allocator: std.mem.Allocator,
    list: *std.ArrayList(Visible),
    term: *ghosttyvt.Terminal,
    cell_width: u32,
    cell_height: u32,
) !void {
    list.clearRetainingCapacity();
    const screen = term.screens.active;
    const storage = &screen.kitty_images;
    if (storage.placements.count() == 0) return;
    const pages = &screen.pages;
    const viewport = pages.pointFromPin(.screen, pages.getTopLeft(.viewport)) orelse return;
    const grid_width = @as(i64, term.cols) * cell_width;
    const grid_height = @as(i64, term.rows) * cell_height;

    var it = storage.placements.iterator();
    while (it.next()) |entry| {
        const placement = entry.value_ptr.*;
        const image = storage.images.get(entry.key_ptr.image_id) orelse continue;
        const format: Format = switch (image.format) {
            .rgb => .rgb,
            .rgba => .rgba,
            .gray => .gray,
            .gray_alpha => .gray_alpha,
            else => continue,
        };
        const data = image.renderData().bytes() orelse continue;
        const needed = @as(u64, image.width) * image.height * bytesPerPixel(format);
        if (data.len < needed) continue;

        var row_offset: i64 = 0;
        var col_offset: i64 = 0;
        const pin = switch (placement.location) {
            .pin => |pin| pin,
            .virtual => continue,
            .relative => |relative| pin: {
                const chain = storage.resolveChain(relative) orelse continue;
                row_offset = chain.vertical_offset;
                col_offset = chain.horizontal_offset;
                break :pin switch (chain.root.location) {
                    .pin => |pin| pin,
                    .virtual, .relative => continue,
                };
            },
        };
        if (pin.garbage) continue;
        const point = pages.pointFromPin(.screen, pin.*) orelse continue;
        const row = @as(i64, point.screen.y) - viewport.screen.y + row_offset;
        const col = @as(i64, point.screen.x) + col_offset;

        const size = placement.pixelSize(image, term);
        const offset = placement.cellOffset(term);
        const geometry: Geometry = .{
            .image_id = entry.key_ptr.image_id,
            .placement_id = entry.key_ptr.placement_id,
            .generation = image.generation,
            .z = placement.z,
            .x = col * cell_width + offset.x,
            .y = row * cell_height + offset.y,
            .width = size.width,
            .height = size.height,
            .source = placement.sourceRect(image),
        };
        if (geometry.width == 0 or geometry.height == 0 or
            geometry.source.width == 0 or geometry.source.height == 0) continue;
        if (geometry.x + geometry.width <= 0 or geometry.x >= grid_width or
            geometry.y + geometry.height <= 0 or geometry.y >= grid_height) continue;
        try list.append(allocator, .{
            .geometry = geometry,
            .format = format,
            .image_width = image.width,
            .data = data,
        });
    }
    std.mem.sort(Visible, list.items, {}, lessThan);
}

/// Whether two frames place the same images in the same places.
pub fn sameGeometry(a: []const Visible, b: []const Visible) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (!std.meta.eql(x.geometry, y.geometry)) return false;
    }
    return true;
}

test "z selects the kitty drawing layer" {
    try std.testing.expectEqual(Layer.below_background, layer(std.math.minInt(i32)));
    try std.testing.expectEqual(Layer.below_background, layer(std.math.minInt(i32) / 2 - 1));
    try std.testing.expectEqual(Layer.below_text, layer(std.math.minInt(i32) / 2));
    try std.testing.expectEqual(Layer.below_text, layer(-1));
    try std.testing.expectEqual(Layer.above_text, layer(0));
}

test "sampling scales the source rectangle with nearest neighbor" {
    // A 2x2 RGB image: red, green / blue, white.
    const data = [_]u8{ 255, 0, 0, 0, 255, 0, 0, 0, 255, 255, 255, 255 };
    const visible: Visible = .{
        .geometry = .{
            .image_id = 1,
            .placement_id = .{ .tag = .internal, .id = 0 },
            .generation = 1,
            .z = 0,
            .x = 10,
            .y = 20,
            .width = 4,
            .height = 4,
            .source = .{ .x = 0, .y = 0, .width = 2, .height = 2 },
        },
        .format = .rgb,
        .image_width = 2,
        .data = &data,
    };
    try std.testing.expectEqual([4]u8{ 255, 0, 0, 255 }, visible.sample(10, 20));
    try std.testing.expectEqual([4]u8{ 255, 0, 0, 255 }, visible.sample(11, 21));
    try std.testing.expectEqual([4]u8{ 0, 255, 0, 255 }, visible.sample(12, 20));
    try std.testing.expectEqual([4]u8{ 255, 255, 255, 255 }, visible.sample(13, 23));

    var cropped = visible;
    cropped.geometry.source = .{ .x = 1, .y = 1, .width = 1, .height = 1 };
    try std.testing.expectEqual([4]u8{ 255, 255, 255, 255 }, cropped.sample(10, 20));
}
