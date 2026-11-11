const std = @import("std");
const linux = std.os.linux;

const libdrm = @import("libdrm");
const freetype = @import("freetype");
const harfbuzz = @import("harfbuzz");
const ghosttyvt = @import("ghostty-vt");
const Drm = @import("drm.zig");
const Seat = @import("seat.zig");
const Colors = @import("colors.zig");
const Images = @import("renderer/images.zig");
const Box = @import("renderer/box.zig");
const Blocks = @import("renderer/blocks.zig");
const Powerline = @import("renderer/powerline.zig");

const Self = @This();

const Glyph = struct {
    /// One coverage byte per pixel, or premultiplied BGRA when `color`.
    pixels: []u8,
    color: bool = false,
    width: usize,
    rows: usize,
    left: i32,
    top: i32,

    fn copy(allocator: std.mem.Allocator, bitmap: freetype.FT_Bitmap, left: i32, top: i32) !Glyph {
        const color = switch (bitmap.pixel_mode) {
            freetype.FT_PIXEL_MODE_GRAY, freetype.FT_PIXEL_MODE_MONO => false,
            freetype.FT_PIXEL_MODE_BGRA => true,
            else => return error.UnsupportedGlyphPixelMode,
        };
        const row_bytes = @as(usize, bitmap.width) * @as(usize, if (color) 4 else 1);
        const pixels = try allocator.alloc(u8, row_bytes * bitmap.rows);
        for (0..bitmap.rows) |row| {
            // FreeType pitch is signed and may include padding between rows.
            const address = @as(i128, @intCast(@intFromPtr(bitmap.buffer))) + @as(i128, @intCast(row)) * bitmap.pitch;
            const source: [*]const u8 = @ptrFromInt(@as(usize, @intCast(address)));
            const dest = pixels[row * row_bytes ..][0..row_bytes];
            if (bitmap.pixel_mode == freetype.FT_PIXEL_MODE_MONO) {
                for (dest, 0..) |*value, column| {
                    value.* = if (source[column / 8] & (@as(u8, 0x80) >> @as(u3, @intCast(column % 8))) != 0) 255 else 0;
                }
            } else {
                @memcpy(dest, source[0..row_bytes]);
            }
        }
        return .{ .pixels = pixels, .color = color, .width = bitmap.width, .rows = bitmap.rows, .left = left, .top = top };
    }

    /// Area-average onto a width x rows grid. Coverage and premultiplied
    /// color both average linearly.
    fn resample(self: Glyph, allocator: std.mem.Allocator, width: usize, rows: usize) !Glyph {
        const channels: usize = if (self.color) 4 else 1;
        const pixels = try allocator.alloc(u8, width * rows * channels);
        const step_x = @as(f32, @floatFromInt(self.width)) / @as(f32, @floatFromInt(width));
        const step_y = @as(f32, @floatFromInt(self.rows)) / @as(f32, @floatFromInt(rows));
        for (0..rows) |y| {
            const y0 = @as(f32, @floatFromInt(y)) * step_y;
            const y1 = y0 + step_y;
            for (0..width) |x| {
                const x0 = @as(f32, @floatFromInt(x)) * step_x;
                const x1 = x0 + step_x;
                var sum: [4]f32 = @splat(0);
                var source_y: usize = @intFromFloat(y0);
                while (source_y < self.rows and @as(f32, @floatFromInt(source_y)) < y1) : (source_y += 1) {
                    const top: f32 = @floatFromInt(source_y);
                    const weight_y = @min(y1, top + 1) - @max(y0, top);
                    var source_x: usize = @intFromFloat(x0);
                    while (source_x < self.width and @as(f32, @floatFromInt(source_x)) < x1) : (source_x += 1) {
                        const left: f32 = @floatFromInt(source_x);
                        const weight = weight_y * (@min(x1, left + 1) - @max(x0, left));
                        const source = self.pixels[(source_y * self.width + source_x) * channels ..][0..channels];
                        for (source, 0..) |value, channel| sum[channel] += weight * @as(f32, @floatFromInt(value));
                    }
                }
                const dest = pixels[(y * width + x) * channels ..][0..channels];
                for (dest, 0..) |*value, channel| value.* = @intFromFloat(@min(255, @round(sum[channel] / (step_x * step_y))));
            }
        }
        return .{ .pixels = pixels, .color = self.color, .width = width, .rows = rows, .left = self.left, .top = self.top };
    }
};

const FontStyle = enum(u2) {
    regular,
    bold,
    italic,
    bold_italic,

    fn fromCell(style: ghosttyvt.Style) FontStyle {
        const index = @as(u2, @intFromBool(style.flags.bold)) | (@as(u2, @intFromBool(style.flags.italic)) << 1);
        return @enumFromInt(index);
    }
};

/// Text faces use FontStyle's indices; the emoji face follows them.
const emoji_face: u3 = 4;

/// Cache key for a codepoint drawn in a style across one or two cells.
fn glyphKey(codepoint: u21, style: FontStyle, cells: u2) u64 {
    return @as(u64, codepoint) | (@as(u64, @intFromEnum(style)) << 32) | (@as(u64, cells) << 36);
}

/// Cache key for a shaped glyph index within a face.
fn indexKey(face: u3, index: u32, cells: u2) u64 {
    return @as(u64, index) | (@as(u64, face) << 32) | (1 << 35) | (@as(u64, cells) << 36);
}

/// A shaped glyph, offset in pixels from the cell's origin and baseline.
const Placed = struct { key: u64, x: i32, y: i32 };

/// Owns the text faces, the emoji face, and glyphs and shaped grapheme
/// clusters at one fixed size.
/// Not thread-safe: loading a glyph mutates a face's glyph slot.
pub const Font = struct {
    allocator: std.mem.Allocator,
    glyphs: std.AutoHashMapUnmanaged(u64, Glyph) = .empty,
    /// Keyed by the bytes of `cluster_key`: style and cells, then codepoints.
    clusters: std.StringHashMapUnmanaged([]const Placed) = .empty,
    cluster_key: std.ArrayList(u32) = .empty,
    library: freetype.FT_Library,
    faces: [5]freetype.FT_Face = @splat(null),
    shapers: [5]?*harfbuzz.hb_font_t = @splat(null),
    buffer: ?*harfbuzz.hb_buffer_t = null,
    cell_width: u32,
    cell_height: u32,
    ascender: i32,

    underline_position: u32 = 0,
    underline_thickness: u32 = 1,
    /// Top of the strikethrough, in pixels below the cell's top.
    strikethrough_position: u32 = 0,
    strikethrough_thickness: u32 = 1,

    pub const Options = struct {
        /// Null uses the embedded JetBrains Mono family.
        directory: ?[]const u8 = null,
        name: []const u8 = "JetBrainsMono",
        pixel_size: u32 = 16,
    };

    pub fn init(allocator: std.mem.Allocator, options: Options) !Font {
        if (options.pixel_size == 0) return error.InvalidPixelSize;
        var library: freetype.FT_Library = undefined;
        if (freetype.FT_Init_FreeType(&library) != 0) return error.FailedToInitializeFreeType;
        errdefer _ = freetype.FT_Done_FreeType(library);

        var faces: [5]freetype.FT_Face = @splat(null);
        errdefer for (faces) |face| {
            if (face != null) _ = freetype.FT_Done_Face(face);
        };
        const bundled = [_][]const u8{
            @embedFile("fonts/JetBrainsMono-Regular.ttf"),
            @embedFile("fonts/JetBrainsMono-Bold.ttf"),
            @embedFile("fonts/JetBrainsMono-Italic.ttf"),
            @embedFile("fonts/JetBrainsMono-BoldItalic.ttf"),
        };
        const suffixes = [_][]const u8{ "Regular", "Bold", "Italic", "BoldItalic" };
        for (faces[0..4], suffixes, bundled) |*face, suffix, data| {
            if (options.directory) |directory| {
                const path = try std.fmt.allocPrintSentinel(allocator, "{s}/{s}-{s}.ttf", .{ directory, options.name, suffix }, 0);
                defer allocator.free(path);
                if (freetype.FT_New_Face(library, path.ptr, 0, face) != 0) {
                    std.log.warn("Cannot load font face: {s}", .{path});
                    return error.FailedToLoadTypeface;
                }
            } else {
                if (freetype.FT_New_Memory_Face(library, data.ptr, @intCast(data.len), 0, face) != 0)
                    return error.FailedToLoadTypeface;
            }
            if (freetype.FT_Set_Pixel_Sizes(face.*, 0, options.pixel_size) != 0) return error.FailedToSetPixelSizes;
        }
        const emoji = @embedFile("fonts/NotoColorEmoji.ttf");
        if (freetype.FT_New_Memory_Face(library, emoji.ptr, emoji.len, 0, &faces[emoji_face]) != 0)
            return error.FailedToLoadTypeface;
        // Noto Color Emoji has one bitmap strike; glyphs are scaled to cells.
        if (freetype.FT_Select_Size(faces[emoji_face], 0) != 0) return error.FailedToSetPixelSizes;

        // Keep every style on the regular face's cell grid and baseline.
        const face = faces[0];
        const metrics = face.*.size.*.metrics;
        const width = @max(1, @divFloor(metrics.max_advance + 63, 64));
        const ascender = @max(0, @divFloor(metrics.ascender + 63, 64));
        const height = @max(1, @max(@divFloor(metrics.height + 63, 64), ascender - @divFloor(metrics.descender, 64)));
        // Coordinates below use signed pixel offsets, including glyph bearings.
        if (width > std.math.maxInt(i32) or height > std.math.maxInt(i32)) return error.InvalidFontMetrics;
        const underline_thickness = std.math.clamp(@divFloor(freetype.FT_MulFix(face.*.underline_thickness, metrics.y_scale) + 63, 64), 1, height);
        // The OS/2 table gives the stroke's top above the baseline; without
        // one, center a stroke near the middle of lowercase letters.
        var strike_thickness = underline_thickness;
        var strike_top = @divFloor(ascender * 3, 10) + @divFloor(strike_thickness + 1, 2);
        const os2: ?*const freetype.TT_OS2 = @ptrCast(@alignCast(freetype.FT_Get_Sfnt_Table(face, freetype.FT_SFNT_OS2)));
        if (os2) |table| if (table.yStrikeoutSize > 0) {
            strike_thickness = std.math.clamp(@divFloor(freetype.FT_MulFix(table.yStrikeoutSize, metrics.y_scale) + 63, 64), 1, height);
            strike_top = @divFloor(freetype.FT_MulFix(table.yStrikeoutPosition, metrics.y_scale) + 32, 64);
        };
        return .{
            .allocator = allocator,
            .library = library,
            .faces = faces,
            .cell_width = @intCast(width),
            .cell_height = @intCast(height),
            .ascender = @intCast(ascender),
            .underline_position = @intCast(std.math.clamp(ascender - @divFloor(freetype.FT_MulFix(face.*.underline_position, metrics.y_scale), 64), 0, height - 1)),
            .underline_thickness = @intCast(underline_thickness),
            .strikethrough_position = @intCast(std.math.clamp(ascender - strike_top, 0, height - 1)),
            .strikethrough_thickness = @intCast(strike_thickness),
        };
    }

    /// Look up a glyphKey or indexKey, rendering it on first use.
    fn glyph(self: *Font, key: u64) !*const Glyph {
        if (self.glyphs.getPtr(key)) |cached| return cached;
        const rendered = try self.renderKey(key);
        errdefer self.allocator.free(rendered.pixels);
        try self.glyphs.put(self.allocator, key, rendered);
        return self.glyphs.getPtr(key).?;
    }

    fn renderKey(self: *Font, key: u64) !Glyph {
        const cells: u2 = @truncate(key >> 36);
        const face: u3 = @truncate(key >> 32);
        const index: u32 = @truncate(key);
        if (key & (1 << 35) != 0) return self.render(face, index, cells);
        const codepoint: u21 = @intCast(index);
        const width = self.cell_width * cells;
        const drawn = if (Box.covers(codepoint))
            try Box.draw(self.allocator, codepoint, width, self.cell_height, self.underline_thickness)
        else if (Blocks.covers(codepoint))
            try Blocks.draw(self.allocator, codepoint, width, self.cell_height)
        else if (Powerline.covers(codepoint))
            try Powerline.draw(self.allocator, codepoint, width, self.cell_height, self.underline_thickness)
        else
            null;
        if (drawn) |pixels| {
            return .{
                .pixels = pixels,
                .width = width,
                .rows = self.cell_height,
                .left = 0,
                .top = self.ascender,
            };
        }
        const resolved = self.faceFor(codepoint, &.{}, @enumFromInt(@as(u2, @intCast(face))), cells);
        return self.render(resolved, freetype.FT_Get_Char_Index(self.faces[resolved], codepoint), cells);
    }

    fn render(self: *Font, face_index: u3, index: u32, cells: u2) !Glyph {
        const face = self.faces[face_index];
        if (face == null) return error.GlyphLoadFailed;
        const emoji = face_index == emoji_face;
        const flags: freetype.FT_Int32 = @intCast(freetype.FT_LOAD_RENDER | if (emoji) freetype.FT_LOAD_COLOR else freetype.FT_LOAD_TARGET_NORMAL);
        if (freetype.FT_Load_Glyph(face, index, flags) != 0) return error.GlyphLoadFailed;
        const slot = face.*.glyph.*;
        const rendered = try Glyph.copy(self.allocator, slot.bitmap, slot.bitmap_left, slot.bitmap_top);
        if (!emoji) return rendered;
        defer self.allocator.free(rendered.pixels);
        return self.fit(rendered, face.*.size.*.metrics, slot.advance.x, cells);
    }

    /// Scale an emoji's advance and line box to fit within its cells, centered.
    fn fit(self: *const Font, rendered: Glyph, metrics: freetype.FT_Size_Metrics, advance: freetype.FT_Pos, cells: u2) !Glyph {
        if (rendered.width == 0 or rendered.rows == 0) {
            return .{ .pixels = try self.allocator.alloc(u8, 0), .width = 0, .rows = 0, .left = 0, .top = 0 };
        }
        const box_width: f32 = @floatFromInt(self.cell_width * cells);
        const box_height: f32 = @floatFromInt(self.cell_height);
        const ascender = @as(f32, @floatFromInt(metrics.ascender)) / 64;
        const line = @max(1, ascender - @as(f32, @floatFromInt(metrics.descender)) / 64);
        const width = if (advance > 0) @as(f32, @floatFromInt(advance)) / 64 else @as(f32, @floatFromInt(rendered.width));
        const scale = @min(box_width / width, box_height / line);
        var scaled = try rendered.resample(
            self.allocator,
            @max(1, @as(usize, @intFromFloat(@round(@as(f32, @floatFromInt(rendered.width)) * scale)))),
            @max(1, @as(usize, @intFromFloat(@round(@as(f32, @floatFromInt(rendered.rows)) * scale)))),
        );
        const x = (box_width - width * scale) / 2 + @as(f32, @floatFromInt(rendered.left)) * scale;
        const y = (box_height - line * scale) / 2 + (ascender - @as(f32, @floatFromInt(rendered.top))) * scale;
        scaled.left = @intFromFloat(@round(x));
        scaled.top = self.ascender - @as(i32, @intFromFloat(@round(y)));
        return scaled;
    }

    /// Choose the emoji face for emoji presentation, otherwise the style's
    /// text face, falling back to whichever face covers the base codepoint.
    fn faceFor(self: *const Font, base: u21, extra: []const u21, style: FontStyle, cells: u2) u3 {
        const text: u3 = @intFromEnum(style);
        if (freetype.FT_Get_Char_Index(self.faces[emoji_face], base) == 0) return text;
        var text_presentation = false;
        for (extra) |codepoint| switch (codepoint) {
            // VS16, ZWJ, keycaps, skin tones, and tag sequences form emoji.
            0xFE0F, 0x200D, 0x20E3, 0x1F3FB...0x1F3FF, 0xE0020...0xE007F => return emoji_face,
            0xFE0E => text_presentation = true,
            else => {},
        };
        // The terminal's width tables make emoji-presentation codepoints wide.
        if (freetype.FT_Get_Char_Index(self.faces[text], base) != 0 and (text_presentation or cells == 1)) return text;
        return emoji_face;
    }

    /// Shape a multi-codepoint grapheme cluster once and cache its glyphs.
    /// The result stays valid until deinit.
    fn shape(self: *Font, base: u21, extra: []const u21, style: FontStyle, cells: u2) ![]const Placed {
        self.cluster_key.clearRetainingCapacity();
        try self.cluster_key.ensureUnusedCapacity(self.allocator, extra.len + 2);
        self.cluster_key.appendAssumeCapacity(@intFromEnum(style) | (@as(u32, cells) << 2));
        self.cluster_key.appendAssumeCapacity(base);
        for (extra) |codepoint| self.cluster_key.appendAssumeCapacity(codepoint);
        const key = std.mem.sliceAsBytes(self.cluster_key.items);
        if (self.clusters.get(key)) |placed| return placed;

        const placed = try self.shapeUncached(self.faceFor(base, extra, style, cells), self.cluster_key.items[1..], cells);
        errdefer self.allocator.free(placed);
        const owned_key = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(owned_key);
        try self.clusters.put(self.allocator, owned_key, placed);
        return placed;
    }

    fn shapeUncached(self: *Font, face: u3, codepoints: []const u32, cells: u2) ![]const Placed {
        if (self.faces[face] == null) return error.GlyphLoadFailed;
        const shaper = self.shapers[face] orelse shaper: {
            self.shapers[face] = harfbuzz.hb_ft_font_create_referenced(@ptrCast(self.faces[face]));
            break :shaper self.shapers[face].?;
        };
        const buffer = self.buffer orelse buffer: {
            self.buffer = harfbuzz.hb_buffer_create();
            break :buffer self.buffer.?;
        };
        harfbuzz.hb_buffer_reset(buffer);
        harfbuzz.hb_buffer_set_flags(buffer, harfbuzz.HB_BUFFER_FLAG_REMOVE_DEFAULT_IGNORABLES);
        harfbuzz.hb_buffer_add_utf32(buffer, codepoints.ptr, @intCast(codepoints.len), 0, @intCast(codepoints.len));
        harfbuzz.hb_buffer_guess_segment_properties(buffer);
        harfbuzz.hb_shape(shaper, buffer, null, 0);
        var count: c_uint = 0;
        const infos = harfbuzz.hb_buffer_get_glyph_infos(buffer, &count);
        const positions = harfbuzz.hb_buffer_get_glyph_positions(buffer, &count);

        var placed: std.ArrayList(Placed) = .empty;
        errdefer placed.deinit(self.allocator);
        if (count == 0) return placed.toOwnedSlice(self.allocator);
        var pen: i32 = 0;
        for (infos[0..count], positions[0..count], 0..) |info, position, i| {
            defer pen += position.x_advance;
            // Omit marks the face lacks rather than boxing over the base.
            if (info.codepoint == 0 and i > 0) continue;
            if (face == emoji_face) {
                // One emoji per cell: an unknown sequence shows its first emoji.
                try placed.append(self.allocator, .{ .key = indexKey(face, info.codepoint, cells), .x = 0, .y = 0 });
                break;
            }
            // HarfBuzz positions are 26.6 fixed point with y pointing up.
            try placed.append(self.allocator, .{
                .key = indexKey(face, info.codepoint, cells),
                .x = @divFloor(pen + position.x_offset + 32, 64),
                .y = -@divFloor(position.y_offset + 32, 64),
            });
        }
        return placed.toOwnedSlice(self.allocator);
    }

    pub fn deinit(self: *Font) void {
        var values = self.glyphs.valueIterator();
        while (values.next()) |cached| self.allocator.free(cached.pixels);
        self.glyphs.deinit(self.allocator);
        var clusters = self.clusters.iterator();
        while (clusters.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.clusters.deinit(self.allocator);
        self.cluster_key.deinit(self.allocator);
        if (self.buffer) |buffer| harfbuzz.hb_buffer_destroy(buffer);
        // Shapers hold face references, so release them before the faces.
        for (self.shapers) |shaper| {
            if (shaper) |font| harfbuzz.hb_font_destroy(font);
        }
        for (self.faces) |face| {
            if (face != null) _ = freetype.FT_Done_Face(face);
        }
        _ = freetype.FT_Done_FreeType(self.library);
        self.* = undefined;
    }
};

const Framebuffer = struct {
    id: u32,
    handle: u32,
    map: *anyopaque,
    size: usize,
    stride: usize,
};

const RowDamage = struct {
    node: usize = 0,
    serial: u64 = 0,
    page_y: u16 = 0,
    /// The shadow buffer's copy of the row is out of date.
    stale: bool = true,
    /// Framebuffers whose copy of the row is out of date.
    pending: [2]bool = .{ true, true },
};

const RenderKey = struct {
    screen: usize,
    cols: u16,
    width: u16,
    height: u16,
    font: *Font,
    cell_width: u32,
    cell_height: u32,
    ascender: i32,
    fg: u32,
    bg: u32,
};

const CursorState = struct {
    x: u16,
    y: u16,
    visible: bool,
    style: u8,
    color: ?ghosttyvt.color.RGB,
};

const Damage = struct {
    rows: std.ArrayList(RowDamage) = .empty,
    /// Repaint the whole shadow buffer, display margins included.
    clear: bool = true,
    /// Framebuffers to copy whole from the shadow buffer.
    full: [2]bool = .{ true, true },
    key: ?RenderKey = null,
    cursor: ?CursorState = null,

    fn deinit(self: *Damage, allocator: std.mem.Allocator) void {
        self.rows.deinit(allocator);
    }

    fn invalidate(self: *Damage) void {
        self.clear = true;
        self.full = .{ true, true };
        for (self.rows.items) |*row| {
            row.stale = true;
            row.pending = .{ true, true };
        }
    }

    fn mark(self: *Damage, y: usize) void {
        if (y >= self.rows.items.len) return;
        self.rows.items[y].stale = true;
        self.rows.items[y].pending = .{ true, true };
    }
};

allocator: std.mem.Allocator,
damage: Damage = .{},
device: Drm.Device,
fd: c_int,
mode: libdrm.drmModeModeInfo,
framebuffers: [2]Framebuffer,
/// Frames are drawn here, then damaged rows are copied to the back buffer:
/// blending reads pixels back, and dumb buffers are often uncached memory.
/// Shares the framebuffers' stride.
shadow: Canvas,
display_index: ?usize = null,
render_index: usize = 0,
flip_pending: bool = false,
saved_crtc: ?*libdrm.drmModeCrtc,
is_modeset: bool = false,
/// False while another VT owns the display; do not present until activate.
active: bool = true,
/// Kitty placements drawn by the latest frame, and by the frame before it
/// (only its geometry is meaningful), to find rows whose images changed.
images: std.ArrayList(Images.Visible) = .empty,
previous_images: std.ArrayList(Images.Visible) = .empty,

pub fn init(allocator: std.mem.Allocator, seat: *Seat) !Self {
    var device = try Drm.Device.init(seat);
    errdefer device.deinit();
    const fd = device.fd;
    const mode = device.mode;
    const saved_crtc = libdrm.drmModeGetCrtc(
        fd,
        device.crtc_id,
    ) orelse return error.FailedToSaveCrtc;
    errdefer libdrm.drmModeFreeCrtc(saved_crtc);
    var framebuffers: [2]Framebuffer = undefined;
    var framebuffer_count: usize = 0;
    errdefer for (framebuffers[0..framebuffer_count]) |framebuffer| {
        destroyFramebuffer(fd, framebuffer);
    };

    for (&framebuffers) |*framebuffer| {
        framebuffer.* = try createFramebuffer(fd, mode);
        framebuffer_count += 1;
    }
    const stride = framebuffers[0].stride;
    const shadow = try allocator.alloc(u32, stride * mode.vdisplay);

    return .{
        .allocator = allocator,
        .device = device,
        .fd = fd,
        .mode = mode,
        .framebuffers = framebuffers,
        .shadow = .{ .pixels = shadow, .width = mode.hdisplay, .height = mode.vdisplay, .stride = stride },
        .saved_crtc = saved_crtc,
    };
}

pub const Rect = struct {
    x: u32,
    y: u32,
    width: u32,
    height: u32,

    pub fn clip(self: Rect, rect: Rect) Rect {
        const x = @max(self.x, rect.x);
        const y = @max(self.y, rect.y);
        const right = @min(self.x +| self.width, rect.x +| rect.width);
        const bottom = @min(self.y +| self.height, rect.y +| rect.height);
        return .{
            .x = x,
            .y = y,
            .width = right -| x,
            .height = bottom -| y,
        };
    }
};

test "Rect.clip intersects edges and handles disjoint and overflowing bounds" {
    const bounds: Rect = .{ .x = 0, .y = 0, .width = 100, .height = 60 };
    try std.testing.expectEqual(
        Rect{ .x = 90, .y = 50, .width = 10, .height = 10 },
        (Rect{ .x = 90, .y = 50, .width = 30, .height = 20 }).clip(bounds),
    );
    const disjoint = (Rect{ .x = 101, .y = 61, .width = 10, .height = 10 }).clip(bounds);
    try std.testing.expectEqual(@as(u32, 0), disjoint.width);
    try std.testing.expectEqual(@as(u32, 0), disjoint.height);
    const overflowing = (Rect{
        .x = 90,
        .y = 50,
        .width = std.math.maxInt(u32),
        .height = std.math.maxInt(u32),
    }).clip(bounds);
    try std.testing.expectEqual(@as(u32, 10), overflowing.width);
    try std.testing.expectEqual(@as(u32, 10), overflowing.height);
}

/// The offsets in [0, size) that land within [start, start + len) when
/// counted from origin.
fn span(origin: i64, start: u32, len: u32, size: usize) [2]usize {
    const limit: i64 = @intCast(size);
    const first = std.math.clamp(@as(i64, start) - origin, 0, limit);
    const end = std.math.clamp(@as(i64, start) + len - origin, first, limit);
    return .{ @intCast(first), @intCast(end) };
}

/// XRGB8888 pixels in rows of `stride`, drawn within width x height.
const Canvas = struct {
    pixels: []u32,
    width: u32,
    height: u32,
    stride: usize,

    fn bounds(self: Canvas) Rect {
        return .{ .x = 0, .y = 0, .width = self.width, .height = self.height };
    }

    fn fillRect(self: Canvas, color: u32, rect: Rect) void {
        const clipped = rect.clip(self.bounds());
        if (clipped.width == 0 or clipped.height == 0) return;
        for (clipped.y..clipped.y + clipped.height) |y| {
            @memset(self.pixels[y * self.stride + clipped.x ..][0..clipped.width], color);
        }
    }

    fn clear(self: Canvas, color: u32) void {
        @memset(self.pixels, color);
    }

    /// Coverage glyphs take `color`; color glyphs keep their own pixels.
    fn drawGlyph(self: Canvas, font: *const Font, glyph: *const Glyph, rect: Rect, offset_x: i32, offset_y: i32, color: u32) void {
        const clipped = rect.clip(self.bounds());
        const left = @as(i64, rect.x) + glyph.left + offset_x;
        const top = @as(i64, rect.y) + font.ascender - glyph.top + offset_y;
        const rows = span(top, clipped.y, clipped.height, glyph.rows);
        const columns = span(left, clipped.x, clipped.width, glyph.width);
        const count = columns[1] - columns[0];
        if (count == 0) return;
        for (rows[0]..rows[1]) |row| {
            const y: usize = @intCast(top + @as(i64, @intCast(row)));
            const x: usize = @intCast(left + @as(i64, @intCast(columns[0])));
            const dest = self.pixels[y * self.stride + x ..][0..count];
            const source = row * glyph.width + columns[0];
            if (glyph.color) {
                const bgras = std.mem.bytesAsSlice(
                    [4]u8,
                    glyph.pixels[source * 4 ..][0 .. count * 4],
                );
                for (dest, bgras) |*pixel, *bgra| {
                    if (bgra[3] != 0) pixel.* = blendPremultiplied(pixel.*, bgra);
                }
            } else {
                for (dest, glyph.pixels[source..][0..count]) |*pixel, alpha| {
                    if (alpha == 0) continue;
                    pixel.* = if (alpha == 255) color else blendPixel(pixel.*, color, alpha);
                }
            }
        }
    }

    /// Draw the underline, strikethrough, and overline that style requests.
    fn drawDecorations(self: Canvas, font: *const Font, style: ghosttyvt.Style, rect: Rect, color: u32, underline_color: u32) void {
        self.drawUnderline(font, style, rect, underline_color);
        if (rect.height == 0) return;
        if (style.flags.strikethrough) {
            const thickness = @min(font.strikethrough_thickness, rect.height);
            const offset = @min(font.strikethrough_position, rect.height - thickness);
            self.fillRect(
                color,
                .{ .x = rect.x, .y = rect.y + offset, .width = rect.width, .height = thickness },
            );
        }
        if (style.flags.overline)
            self.fillRect(
                color,
                .{ .x = rect.x, .y = rect.y, .width = rect.width, .height = @min(font.underline_thickness, rect.height) },
            );
    }

    fn drawUnderline(self: Canvas, font: *const Font, style: ghosttyvt.Style, rect: Rect, color: u32) void {
        if (style.flags.underline == .none or rect.height == 0) return;
        const thickness = @min(font.underline_thickness, rect.height);
        const offset = @min(font.underline_position, rect.height - thickness);
        const y = rect.y + offset;
        switch (style.flags.underline) {
            .none => unreachable,
            .single => self.fillRect(
                color,
                .{ .x = rect.x, .y = y, .width = rect.width, .height = thickness },
            ),
            .double => {
                self.fillRect(color, .{ .x = rect.x, .y = y, .width = rect.width, .height = thickness });
                self.fillRect(color, .{ .x = rect.x, .y = rect.y + (offset -| (2 * thickness)), .width = rect.width, .height = thickness });
            },
            .dotted, .dashed, .curly => {
                // Use screen coordinates to keep patterns continuous between cells.
                for (0..rect.width) |column| {
                    const x = rect.x + @as(u32, @intCast(column));
                    var line_y = y;
                    switch (style.flags.underline) {
                        .dotted => if (x % (2 * thickness) >= thickness) continue,
                        .dashed => if (x % (6 * thickness) >= 4 * thickness) continue,
                        .curly => {
                            const amplitude = @min(2 * thickness, offset);
                            const phase = x % (4 * thickness);
                            const wave = if (phase <= 2 * thickness) phase else 4 * thickness - phase;
                            line_y -= @min(wave, amplitude);
                        },
                        else => unreachable,
                    }
                    self.fillRect(color, .{ .x = x, .y = line_y, .width = 1, .height = thickness });
                }
            },
        }
    }

    /// Draw the part of a placement inside clip, blending straight alpha.
    fn drawImage(self: Canvas, image: Images.Visible, clip: Rect) void {
        const g = image.geometry;
        const x0 = @max(g.x, clip.x);
        const x1 = @min(g.x + g.width, @as(i64, clip.x) + clip.width, self.width);
        const y0 = @max(g.y, clip.y);
        const y1 = @min(g.y + g.height, @as(i64, clip.y) + clip.height, self.height);
        var y = y0;
        while (y < y1) : (y += 1) {
            const row = self.pixels[@as(usize, @intCast(y)) * self.stride ..];
            const source = image.row(y);
            var x = x0;
            while (x < x1) : (x += 1) {
                const rgba = image.pixel(source, x);
                if (rgba[3] == 0) continue;
                const color = (@as(u32, rgba[0]) << 16) | (@as(u32, rgba[1]) << 8) | rgba[2];
                const pixel = &row[@intCast(x)];
                pixel.* = if (rgba[3] == 255) color else blendPixel(pixel.*, color, rgba[3]);
            }
        }
    }
};

fn blendPixel(bg: u32, fg: u32, alpha: u8) u32 {
    const inverse_alpha = 255 - alpha;
    const red = (((fg >> 16) & 0xFF) * alpha + ((bg >> 16) & 0xFF) * inverse_alpha) / 255;
    const green = (((fg >> 8) & 0xFF) * alpha + ((bg >> 8) & 0xFF) * inverse_alpha) / 255;
    const blue = ((fg & 0xFF) * alpha + (bg & 0xFF) * inverse_alpha) / 255;
    return (red << 16) | (green << 8) | blue;
}

test "blendPixel blends RGB channels independently" {
    try std.testing.expectEqual(@as(u32, 0x123456), blendPixel(0x123456, 0xABCDEF, 0));
    try std.testing.expectEqual(@as(u32, 0xABCDEF), blendPixel(0x123456, 0xABCDEF, 255));
    try std.testing.expectEqual(@as(u32, 0x808080), blendPixel(0x000000, 0xFFFFFF, 128));
    try std.testing.expectEqual(@as(u32, 0x7F0080), blendPixel(0xFF0000, 0x0000FF, 128));
    try std.testing.expectEqual(@as(u32, 0x123456), blendPixel(0x123456, 0x123456, 128));
    try std.testing.expectEqual(@as(u32, 0xFFFFFF), blendPixel(0xFFFFFFFF, 0xFFFFFFFF, 128));
}

fn rgbPixel(rgb: ghosttyvt.color.RGB) u32 {
    return (@as(u32, rgb.r) << 16) | (@as(u32, rgb.g) << 8) | rgb.b;
}

const CellColors = struct { fg: u32, bg: u32 };

/// The default colors and palette that cell colors resolve against.
const Theme = struct {
    fg: ghosttyvt.color.RGB,
    bg: ghosttyvt.color.RGB,
    palette: *const ghosttyvt.color.Palette,

    fn of(term: *const ghosttyvt.Terminal) Theme {
        var fg = term.colors.foreground.get() orelse Colors.foreground;
        var bg = term.colors.background.get() orelse Colors.background;
        // DECSCNM reverses defaults, not explicitly selected ANSI/RGB colors.
        if (term.modes.get(.reverse_colors)) std.mem.swap(ghosttyvt.color.RGB, &fg, &bg);
        return .{ .fg = fg, .bg = bg, .palette = &term.colors.palette.current };
    }
};

fn cellColors(cell: ghosttyvt.Cell, style: ghosttyvt.Style, theme: Theme) CellColors {
    var colors: CellColors = .{
        .fg = rgbPixel(style.fg(.{ .default = theme.fg, .palette = theme.palette, .bold = .bright })),
        // bg() also handles blank cells that store their background inline.
        .bg = rgbPixel(style.bg(&cell, theme.palette) orelse theme.bg),
    };
    if (style.flags.inverse) std.mem.swap(u32, &colors.fg, &colors.bg);
    if (style.flags.faint) colors.fg = blendPixel(colors.bg, colors.fg, 128);
    return colors;
}

/// Whether a cell has the default style and no background of its own.
fn plain(cell: ghosttyvt.Cell) bool {
    return !cell.hasStyling() and switch (cell.content_tag) {
        .codepoint, .codepoint_grapheme => true,
        .bg_color_palette, .bg_color_rgb => false,
    };
}

/// Composite premultiplied BGRA over an XRGB pixel.
fn blendPremultiplied(bg: u32, bgra: *const [4]u8) u32 {
    const inverse_alpha: u32 = 255 - bgra[3];
    const red: u32 = @min(255, bgra[2] + (((bg >> 16) & 0xFF) * inverse_alpha + 127) / 255);
    const green: u32 = @min(255, bgra[1] + (((bg >> 8) & 0xFF) * inverse_alpha + 127) / 255);
    const blue: u32 = @min(255, bgra[0] + ((bg & 0xFF) * inverse_alpha + 127) / 255);
    return (red << 16) | (green << 8) | blue;
}

test "blendPremultiplied composites color glyph pixels" {
    try std.testing.expectEqual(@as(u32, 0x123456), blendPremultiplied(0x123456, &.{ 0, 0, 0, 0 }));
    try std.testing.expectEqual(@as(u32, 0xFF8000), blendPremultiplied(0x123456, &.{ 0, 0x80, 0xFF, 255 }));
    try std.testing.expectEqual(@as(u32, 0x807F7F), blendPremultiplied(0x00FFFF, &.{ 0, 0, 0x80, 128 }));
}

/// Draw a cell's grapheme cluster within rect, clipping overhang to its cells.
fn drawCell(self: *Self, font: *Font, pin: ghosttyvt.Pin, cell: *const ghosttyvt.Cell, style: FontStyle, rect: Rect, color: u32) !void {
    const codepoint = cell.codepoint();
    if (codepoint == 0) return;
    const extra: []const u21 = if (cell.hasGrapheme()) pin.grapheme(cell) orelse &.{} else &.{};
    const cells = cell.gridWidth();
    if (extra.len == 0) {
        if (codepoint != ' ') self.shadow.drawGlyph(font, try font.glyph(glyphKey(codepoint, style, cells)), rect, 0, 0, color);
        return;
    }
    for (try font.shape(codepoint, extra, style, cells)) |placed| {
        self.shadow.drawGlyph(font, try font.glyph(placed.key), rect, placed.x, placed.y, color);
    }
}

/// The cursor's row within the viewport, or null when scrolled out of view.
fn cursorRow(screen: *ghosttyvt.Screen) ?u16 {
    if (screen.viewportIsBottom()) return screen.cursor.y;
    const point = screen.pages.pointFromPin(.viewport, screen.cursor.page_pin.*) orelse return null;
    const y = point.coord().y;
    return if (y < screen.pages.rows) @intCast(y) else null;
}

/// Redraw damaged viewport rows, without presenting. Returns false when
/// the back buffer already matches the terminal and no page flip is needed.
/// Each cell's grapheme cluster is shaped and drawn within its cells; text
/// does not shape across cells, so there are no programming ligatures.
/// Cursor blinking is not implemented.
pub fn drawTerminal(self: *Self, font: *Font, term: *ghosttyvt.Terminal) !bool {
    if (self.flip_pending) return error.PageFlipPending;
    const screen = term.screens.active;
    const theme: Theme = .of(term);
    const default_bg = rgbPixel(theme.bg);
    const key: RenderKey = .{
        .screen = @intFromPtr(screen),
        .cols = screen.pages.cols,
        .width = self.mode.hdisplay,
        .height = self.mode.vdisplay,
        .font = font,
        .cell_width = font.cell_width,
        .cell_height = font.cell_height,
        .ascender = font.ascender,
        .fg = rgbPixel(theme.fg),
        .bg = default_bg,
    };
    const cursor_row = cursorRow(screen);
    const cursor: CursorState = .{
        .x = screen.cursor.x,
        .y = cursor_row orelse 0,
        .visible = term.modes.get(.cursor_visible) and cursor_row != null,
        .style = @intCast(@intFromEnum(screen.cursor.cursor_style)),
        .color = term.colors.cursor.get(),
    };
    if (self.damage.rows.items.len != screen.pages.rows) {
        try self.damage.rows.resize(self.allocator, screen.pages.rows);
        @memset(self.damage.rows.items, .{});
        self.damage.invalidate();
    }
    if (self.damage.key == null or !std.meta.eql(self.damage.key.?, key) or
        !std.meta.eql(term.flags.dirty, @as(@TypeOf(term.flags.dirty), .{})) or
        !std.meta.eql(screen.dirty, @as(@TypeOf(screen.dirty), .{}))) self.damage.invalidate();
    if (self.damage.cursor == null or !std.meta.eql(self.damage.cursor.?, cursor)) {
        if (self.damage.cursor) |old| {
            if (old.visible) self.damage.mark(old.y);
        }
        if (cursor.visible) self.damage.mark(cursor.y);
    }

    // Source damage is consumed as soon as it is recorded in self.damage,
    // which keeps it until the shadow and both framebuffers are updated. Pins
    // and serials detect rows moved/recycled by scrolling, including viewport
    // scrolling, without dereferencing any saved page pointer.
    term.flags.dirty = .{};
    screen.dirty = .{};
    var scan = screen.pages.rowIterator(.right_down, .{ .viewport = .{} }, null);
    var row_index: usize = 0;
    var page_node: usize = 0;
    var page_dirty = false;
    while (scan.next()) |pin| : (row_index += 1) {
        if (row_index >= self.damage.rows.items.len) break;
        const row = &self.damage.rows.items[row_index];
        const node = @intFromPtr(pin.node);
        // A page's flag covers all its rows, so clear it once per page.
        if (node != page_node) {
            page_node = node;
            page_dirty = pin.node.page().dirty;
            pin.node.page().dirty = false;
        }
        const source = pin.rowAndCell().row;
        if (row.node != node or row.serial != pin.node.serial or row.page_y != pin.y or
            page_dirty or source.dirty) self.damage.mark(row_index);
        source.dirty = false;
        row.node = node;
        row.serial = pin.node.serial;
        row.page_y = pin.y;
    }

    // Repaint rows an image covered last frame or covers now whenever any
    // placement appeared, moved, changed pixels, or disappeared.
    std.mem.swap(std.ArrayList(Images.Visible), &self.images, &self.previous_images);
    Images.collect(self.allocator, &self.images, term, font.cell_width, font.cell_height) catch |err| {
        self.damage.invalidate();
        return err;
    };
    if (!Images.sameGeometry(self.previous_images.items, self.images.items)) {
        for (self.previous_images.items) |image| self.markImageRows(image.geometry, font.cell_height);
        for (self.images.items) |image| self.markImageRows(image.geometry, font.cell_height);
    }
    const canvas = self.shadow;
    const grid_width: u32 = @intCast(@min(@as(u64, screen.pages.cols) * font.cell_width, canvas.width));

    if (self.damage.clear) canvas.clear(default_bg);
    var rows = screen.pages.rowIterator(.right_down, .{ .viewport = .{} }, null);
    var y: u32 = 0;
    row_index = 0;
    var redraw_cursor = false;
    while (rows.next()) |pin| : ({
        y += font.cell_height;
        row_index += 1;
    }) {
        if (y >= canvas.height or row_index >= self.damage.rows.items.len) break;
        if (!self.damage.rows.items[row_index].stale) continue;
        if (cursor.visible and row_index == cursor.y) redraw_cursor = true;
        if (!self.damage.clear) canvas.fillRect(default_bg, .{ .x = 0, .y = y, .width = canvas.width, .height = font.cell_height });
        const strip: Rect = .{ .x = 0, .y = y, .width = grid_width, .height = font.cell_height };
        self.drawImages(.below_background, strip);
        const cells = pin.cells(.all);
        // Paint backgrounds first so the trailing spacer never erases a wide glyph.
        for (cells, 0..) |*cell, column| {
            const x = @as(u64, column) * font.cell_width;
            if (x >= canvas.width) break;
            if (plain(cell.*)) continue;
            const colors = cellColors(cell.*, pin.style(cell), theme);
            if (colors.bg != default_bg)
                canvas.fillRect(colors.bg, .{ .x = @intCast(x), .y = y, .width = font.cell_width, .height = font.cell_height });
        }
        self.drawImages(.below_text, strip);
        for (cells, 0..) |*cell, column| {
            const x = @as(u64, column) * font.cell_width;
            if (x >= canvas.width) break;
            if (cell.wide == .spacer_head or cell.wide == .spacer_tail) continue;
            const style = pin.style(cell);
            const glyphless = cell.codepoint() == 0 or (cell.codepoint() == ' ' and !cell.hasGrapheme());
            const undecorated = style.flags.underline == .none and !style.flags.strikethrough and !style.flags.overline;
            if (style.flags.invisible or (glyphless and undecorated)) continue;
            const colors = cellColors(cell.*, style, theme);
            const rect: Rect = .{
                .x = @intCast(x),
                .y = y,
                .width = font.cell_width *| @as(u32, cell.gridWidth()),
                .height = font.cell_height,
            };
            try self.drawCell(font, pin, cell, FontStyle.fromCell(style), rect, colors.fg);
            const underline_color = if (style.underlineColor(theme.palette)) |rgb| rgbPixel(rgb) else colors.fg;
            canvas.drawDecorations(font, style, rect, colors.fg, underline_color);
        }
        self.drawImages(.above_text, strip);
    }

    if (redraw_cursor) try self.drawCursor(font, term, cursor.y);

    // Keep accumulated damage intact if any drawing operation failed.
    for (self.damage.rows.items) |*row| row.stale = false;
    self.damage.clear = false;
    self.damage.key = key;
    self.damage.cursor = cursor;
    return self.copyDamage(font.cell_height);
}

/// Copy the shadow's rows that the back buffer lacks. Returns false when
/// it was already current.
fn copyDamage(self: *Self, cell_height: u32) bool {
    const index = self.render_index;
    const target: [*]u32 = @ptrCast(@alignCast(self.framebuffers[index].map));
    const source = self.shadow.pixels;
    const full = self.damage.full[index];
    if (full) @memcpy(target[0..source.len], source);
    var changed = full;
    for (self.damage.rows.items, 0..) |*row, row_index| {
        if (!row.pending[index]) continue;
        row.pending[index] = false;
        changed = true;
        if (full) continue;
        const top = @min(row_index * cell_height, self.shadow.height);
        const bottom = @min(top + cell_height, self.shadow.height);
        const pixels = source[top * self.shadow.stride .. bottom * self.shadow.stride];
        @memcpy(target[top * self.shadow.stride ..][0..pixels.len], pixels);
    }
    self.damage.full[index] = false;
    return changed;
}

fn markImageRows(self: *Self, geometry: Images.Geometry, cell_height: u32) void {
    if (cell_height == 0) return;
    const first = @max(0, @divFloor(geometry.y, cell_height));
    const end = @divFloor(geometry.y + geometry.height + cell_height - 1, cell_height);
    var row = first;
    while (row < end and row < self.damage.rows.items.len) : (row += 1) self.damage.mark(@intCast(row));
}

fn drawImages(self: *Self, layer: Images.Layer, clip: Rect) void {
    for (self.images.items) |image| {
        if (Images.layer(image.geometry.z) == layer) self.shadow.drawImage(image, clip);
    }
}

fn drawCursor(self: *Self, font: *Font, term: *ghosttyvt.Terminal, row: u16) !void {
    const screen = term.screens.active;
    if (!term.modes.get(.cursor_visible)) return;
    var cursor_pin = screen.pages.pin(.{ .viewport = .{ .x = screen.cursor.x, .y = row } }) orelse return;
    var cell = cursor_pin.rowAndCell().cell;
    // A cursor on the trailing half of a wide glyph covers the whole glyph.
    if (cell.wide == .spacer_tail and cursor_pin.x > 0) {
        cursor_pin.x -= 1;
        cell = cursor_pin.rowAndCell().cell;
    }
    const x = @as(u64, cursor_pin.x) * font.cell_width;
    const cursor_y = @as(u64, row) * font.cell_height;
    if (x >= self.mode.hdisplay or cursor_y >= self.mode.vdisplay) return;
    const style = cursor_pin.style(cell);
    const colors = cellColors(cell.*, style, .of(term));
    const cursor_color = if (term.colors.cursor.get()) |rgb| rgbPixel(rgb) else colors.fg;
    const rect: Rect = .{
        .x = @intCast(x),
        .y = @intCast(cursor_y),
        .width = font.cell_width *| @as(u32, cell.gridWidth()),
        .height = font.cell_height,
    };
    const canvas = self.shadow;
    switch (screen.cursor.cursor_style) {
        .block => {
            canvas.fillRect(cursor_color, rect);
            if (!style.flags.invisible) {
                try self.drawCell(font, cursor_pin, cell, FontStyle.fromCell(style), rect, colors.bg);
                canvas.drawDecorations(font, style, rect, colors.bg, colors.bg);
            }
        },
        .bar => canvas.fillRect(cursor_color, .{ .x = rect.x, .y = rect.y, .width = @min(2, rect.width), .height = rect.height }),
        .underline => canvas.fillRect(cursor_color, .{ .x = rect.x, .y = rect.y + rect.height - @min(2, rect.height), .width = rect.width, .height = @min(2, rect.height) }),
        .block_hollow => {
            canvas.fillRect(cursor_color, .{ .x = rect.x, .y = rect.y, .width = rect.width, .height = 1 });
            canvas.fillRect(cursor_color, .{ .x = rect.x, .y = rect.y + rect.height - 1, .width = rect.width, .height = 1 });
            canvas.fillRect(cursor_color, .{ .x = rect.x, .y = rect.y, .width = 1, .height = rect.height });
            canvas.fillRect(cursor_color, .{ .x = rect.x + rect.width - 1, .y = rect.y, .width = 1, .height = rect.height });
        },
    }
}

/// Queue a flip without waiting; the event loop must poll fd and call handleEvents.
pub fn present(self: *Self) !void {
    if (self.flip_pending) return error.PageFlipPending;
    const framebuffer = self.framebuffers[self.render_index];

    if (self.display_index == null) {
        if (libdrm.drmModeSetCrtc(
            self.fd,
            self.device.crtc_id,
            framebuffer.id,
            0,
            0,
            &self.device.connector_id,
            1,
            &self.mode,
        ) != 0) {
            return error.FailedToSetCrtc;
        }
        self.is_modeset = true;
        self.completeFlip();
    } else {
        if (libdrm.drmModePageFlip(
            self.fd,
            self.device.crtc_id,
            framebuffer.id,
            libdrm.DRM_MODE_PAGE_FLIP_EVENT,
            self,
        ) != 0) {
            return error.FailedToQueuePageFlip;
        }
        // Neither buffer is writable until the old front buffer is released.
        self.flip_pending = true;
    }
}

fn completeFlip(self: *Self) void {
    self.display_index = self.render_index;
    self.render_index = (self.render_index + 1) % self.framebuffers.len;
    self.flip_pending = false;
}

/// Call only after poll reports the DRM fd readable, so drmHandleEvent cannot
/// block the PTY/input loop waiting for vblank.
pub fn handleEvents(self: *Self) !void {
    var event_context = std.mem.zeroes(libdrm.drmEventContext);
    event_context.version = libdrm.DRM_EVENT_CONTEXT_VERSION;
    event_context.page_flip_handler = &page_flip_handler;
    const result = libdrm.drmHandleEvent(self.fd, &event_context);
    if (result != 0 and std.posix.errno(result) != .INTR) return error.FailedToHandleDrmEvent;
}

/// Give the display to another session: finish any flip. The seat provider
/// revokes DRM master, and the CRTC is left for the next master to program.
pub fn deactivate(self: *Self) void {
    if (self.flip_pending) self.finishPendingFlip();
    self.active = false;
}

/// Resume once the seat provider has restored DRM master. The next present
/// modesets and the next draw copies the whole frame, since another master
/// owned the CRTC.
pub fn activate(self: *Self) !void {
    if (libdrm.drmIsMaster(self.fd) != 1) return error.DrmMasterUnavailable;
    self.active = true;
    self.display_index = null;
    self.damage.full = .{ true, true };
}

pub fn frameIntervalNs(self: *const Self) u64 {
    var refresh: u64 = self.mode.vrefresh;
    if (refresh == 0) refresh = 60;
    return @max(1, std.time.ns_per_s / refresh);
}

fn page_flip_handler(
    fd: c_int,
    frame: c_uint,
    sec: c_uint,
    usec: c_uint,
    user_data: ?*anyopaque,
) callconv(.c) void {
    _ = fd;
    _ = frame;
    _ = sec;
    _ = usec;
    const self: *Self = @ptrCast(@alignCast(user_data orelse return));
    self.completeFlip();
}

/// Free the state used to draw frames, which owns no DRM objects.
fn deinitDrawing(self: *Self) void {
    self.allocator.free(self.shadow.pixels);
    self.damage.deinit(self.allocator);
    self.images.deinit(self.allocator);
    self.previous_images.deinit(self.allocator);
}

pub fn deinit(self: *Self) void {
    self.deinitDrawing();
    // Normal shell exit already drains flips. Signals and error exits may not.
    if (self.flip_pending) self.finishPendingFlip();
    // While switched away, the display belongs to the active VT.
    if (self.is_modeset and self.active) self.restoreCrtc();
    if (self.saved_crtc) |saved_crtc| libdrm.drmModeFreeCrtc(saved_crtc);

    for (self.framebuffers) |framebuffer| destroyFramebuffer(self.fd, framebuffer);
    self.device.deinit();
}

fn finishPendingFlip(self: *Self) void {
    var fds = [_]std.posix.pollfd{.{ .fd = self.fd, .events = std.posix.POLL.IN, .revents = 0 }};
    const ready = std.posix.poll(&fds, 1000) catch |err| {
        std.log.warn("Cannot wait for final DRM flip: {s}", .{@errorName(err)});
        return;
    };
    if (ready == 0 or fds[0].revents & std.posix.POLL.IN == 0) {
        std.log.warn("Final DRM flip did not complete before display restoration", .{});
        return;
    }
    self.handleEvents() catch |err| std.log.warn("Cannot complete final DRM flip: {s}", .{@errorName(err)});
}

fn restoreCrtc(self: *Self) void {
    const saved_crtc = self.saved_crtc orelse return;
    for (0..2) |_| {
        const result = libdrm.drmModeSetCrtc(
            self.fd,
            saved_crtc.*.crtc_id,
            saved_crtc.*.buffer_id,
            saved_crtc.*.x,
            saved_crtc.*.y,
            if (saved_crtc.*.mode_valid != 0) &self.device.connector_id else null,
            if (saved_crtc.*.mode_valid != 0) 1 else 0,
            if (saved_crtc.*.mode_valid != 0) &saved_crtc.*.mode else null,
        );
        const err = std.posix.errno(result);
        if (err == .SUCCESS) return;
        if (err == .INTR) continue;
        if (err == .BUSY and self.flip_pending) {
            self.finishPendingFlip();
            continue;
        }
        std.log.warn("Failed to restore CRTC {d}: {s}", .{ saved_crtc.*.crtc_id, @tagName(err) });
        return;
    }
    std.log.warn("Could not restore CRTC {d} after retrying", .{saved_crtc.*.crtc_id});
}

/// Free with deinitDrawing.
fn testRenderer(pixels: []u32, width: u16, height: u16, stride: usize) !Self {
    const framebuffer = Framebuffer{ .id = 0, .handle = 0, .map = pixels.ptr, .size = pixels.len * @sizeOf(u32), .stride = stride };
    var mode = std.mem.zeroes(libdrm.drmModeModeInfo);
    mode.hdisplay = width;
    mode.vdisplay = height;
    return .{
        .allocator = std.testing.allocator,
        .fd = -1,
        .device = undefined,
        .mode = mode,
        .framebuffers = .{ framebuffer, framebuffer },
        .shadow = .{
            .pixels = try std.testing.allocator.alloc(u32, stride * height),
            .width = width,
            .height = height,
            .stride = stride,
        },
        .saved_crtc = null,
    };
}

test "bundled font faces load and cache each style independently" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.InvalidPixelSize, Font.init(allocator, .{ .pixel_size = 0 }));
    var font = try Font.init(allocator, .{ .pixel_size = 24 });
    defer font.deinit();
    try std.testing.expect(font.cell_width > 0 and font.cell_height > 0);
    try std.testing.expect(font.underline_position < font.cell_height);
    try std.testing.expect(font.underline_thickness > 0);
    // The strikethrough crosses lowercase letters: below the cap height and
    // above the baseline.
    try std.testing.expect(font.strikethrough_position > @as(u32, @intCast(font.ascender)) / 3);
    try std.testing.expect(font.strikethrough_position + font.strikethrough_thickness <= @as(u32, @intCast(font.ascender)));
    const styles = [_]FontStyle{ .regular, .bold, .italic, .bold_italic };
    for (styles) |style| {
        const flags = font.faces[@intFromEnum(style)].*.style_flags;
        try std.testing.expectEqual(style == .bold or style == .bold_italic, flags & freetype.FT_STYLE_FLAG_BOLD != 0);
        try std.testing.expectEqual(style == .italic or style == .bold_italic, flags & freetype.FT_STYLE_FLAG_ITALIC != 0);
        const glyph = try font.glyph(glyphKey('A', style, 1));
        try std.testing.expect(glyph.pixels.len > 0 and !glyph.color);
    }
    try std.testing.expectEqual(@as(u32, 4), font.glyphs.count());
    for (styles, 0..) |style, i| {
        const glyph = try font.glyph(glyphKey('A', style, 1));
        try std.testing.expect(glyph == try font.glyph(glyphKey('A', style, 1)));
        for (styles[i + 1 ..]) |other| {
            const other_glyph = try font.glyph(glyphKey('A', other, 1));
            try std.testing.expect(!std.mem.eql(u8, glyph.pixels, other_glyph.pixels));
        }
    }
    try std.testing.expectEqual(@as(u32, 4), font.glyphs.count());
}

test "external font directory and family name load all four faces" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const files = .{
        .{ "Custom-Regular.ttf", @embedFile("fonts/JetBrainsMono-Regular.ttf") },
        .{ "Custom-Bold.ttf", @embedFile("fonts/JetBrainsMono-Bold.ttf") },
        .{ "Custom-Italic.ttf", @embedFile("fonts/JetBrainsMono-Italic.ttf") },
        .{ "Custom-BoldItalic.ttf", @embedFile("fonts/JetBrainsMono-BoldItalic.ttf") },
    };
    inline for (files) |file| {
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = file[0], .data = file[1] });
    }
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(std.testing.io, &path_buffer);
    var font = try Font.init(allocator, .{ .directory = path_buffer[0..path_len], .name = "Custom" });
    defer font.deinit();
    for ([_]FontStyle{ .regular, .bold, .italic, .bold_italic }) |style| {
        _ = try font.glyph(glyphKey('A', style, 1));
    }
    // A missing style is a startup error, rather than silently using regular.
    try tmp.dir.deleteFile(std.testing.io, "Custom-BoldItalic.ttf");
    const previous_log_level = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = previous_log_level;
    try std.testing.expectError(error.FailedToLoadTypeface, Font.init(allocator, .{ .directory = path_buffer[0..path_len], .name = "Custom" }));
}

test "glyph masks own their pixels and normalize padded and negative pitch" {
    var source = [_]u8{ 10, 20, 99, 30, 40, 99 };
    var bitmap = std.mem.zeroes(freetype.FT_Bitmap);
    bitmap.width = 2;
    bitmap.rows = 2;
    bitmap.pitch = 3;
    bitmap.pixel_mode = freetype.FT_PIXEL_MODE_GRAY;
    bitmap.buffer = &source;
    const glyph = try Glyph.copy(std.testing.allocator, bitmap, -1, 2);
    defer std.testing.allocator.free(glyph.pixels);
    try std.testing.expectEqualSlices(u8, &.{ 10, 20, 30, 40 }, glyph.pixels);
    source[0] = 50;
    try std.testing.expectEqual(@as(u8, 10), glyph.pixels[0]);
    try std.testing.expectEqual(@as(i32, -1), glyph.left);
    try std.testing.expectEqual(@as(i32, 2), glyph.top);

    bitmap.buffer = source[3..].ptr;
    bitmap.pitch = -3;
    const reversed = try Glyph.copy(std.testing.allocator, bitmap, 0, 0);
    defer std.testing.allocator.free(reversed.pixels);
    try std.testing.expectEqualSlices(u8, &.{ 30, 40, 50, 20 }, reversed.pixels);
}

test "glyph masks unpack monochrome pixels across byte boundaries" {
    var source = [_]u8{ 0b10100001, 0b10000000 };
    var bitmap = std.mem.zeroes(freetype.FT_Bitmap);
    bitmap.width = 9;
    bitmap.rows = 1;
    bitmap.pitch = 2;
    bitmap.pixel_mode = freetype.FT_PIXEL_MODE_MONO;
    bitmap.buffer = &source;
    const glyph = try Glyph.copy(std.testing.allocator, bitmap, 0, 0);
    defer std.testing.allocator.free(glyph.pixels);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 255, 0, 0, 0, 0, 255, 255 }, glyph.pixels);
    bitmap.pixel_mode = freetype.FT_PIXEL_MODE_LCD;
    try std.testing.expectError(error.UnsupportedGlyphPixelMode, Glyph.copy(std.testing.allocator, bitmap, 0, 0));
}

test "color glyphs copy BGRA rows and resample by area" {
    // Two padded BGRA rows: opaque red and transparent, then two opaque blues.
    var source = [_]u8{ 0, 0, 255, 255, 0, 0, 0, 0, 99, 255, 0, 0, 255, 255, 0, 0, 255, 99 };
    var bitmap = std.mem.zeroes(freetype.FT_Bitmap);
    bitmap.width = 2;
    bitmap.rows = 2;
    bitmap.pitch = 9;
    bitmap.pixel_mode = freetype.FT_PIXEL_MODE_BGRA;
    bitmap.buffer = &source;
    const glyph = try Glyph.copy(std.testing.allocator, bitmap, 0, 0);
    defer std.testing.allocator.free(glyph.pixels);
    try std.testing.expect(glyph.color);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 255, 255, 0, 0, 0, 0, 255, 0, 0, 255, 255, 0, 0, 255 }, glyph.pixels);
    const averaged = try glyph.resample(std.testing.allocator, 1, 1);
    defer std.testing.allocator.free(averaged.pixels);
    try std.testing.expectEqualSlices(u8, &.{ 128, 0, 64, 191 }, averaged.pixels);
    const enlarged = try glyph.resample(std.testing.allocator, 4, 4);
    defer std.testing.allocator.free(enlarged.pixels);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 255, 255 }, enlarged.pixels[4..8]);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, enlarged.pixels[60..64]);
}

test "canvas fills clip rectangles and respect padded stride" {
    var pixels: [12]u32 = @splat(99);
    const canvas: Canvas = .{ .pixels = &pixels, .width = 3, .height = 3, .stride = 4 };
    canvas.clear(0x123456);
    try std.testing.expectEqualSlices(u32, &@as([12]u32, @splat(0x123456)), &pixels);
    canvas.fillRect(7, .{ .x = 1, .y = 1, .width = 20, .height = 20 });
    try std.testing.expectEqualSlices(u32, &.{ 0x123456, 0x123456, 0x123456, 0x123456, 0x123456, 7, 7, 0x123456, 0x123456, 7, 7, 0x123456 }, &pixels);
    canvas.fillRect(8, .{ .x = 10, .y = 10, .width = 2, .height = 2 });
    try std.testing.expectEqual(@as(u32, 7), pixels[10]);
}

test "glyphs clip to their rect and the canvas on every side" {
    var pixels: [20]u32 = @splat(0);
    const canvas: Canvas = .{ .pixels = &pixels, .width = 4, .height = 4, .stride = 5 };
    var font = testFont();
    var coverage: [9]u8 = @splat(255);
    const glyph: Glyph = .{ .pixels = &coverage, .width = 3, .rows = 3, .left = -1, .top = 1 };
    // Overhangs the rect's top-left corner, so only its bottom-right 2x2 lands.
    canvas.drawGlyph(&font, &glyph, .{ .x = 0, .y = 0, .width = 4, .height = 4 }, 0, 0, 7);
    try std.testing.expectEqualSlices(u32, &.{ 7, 7, 0, 0, 0, 7, 7, 0, 0, 0 }, pixels[0..10]);
    // Past the canvas's bottom-right corner, and entirely outside it.
    @memset(&pixels, 0);
    canvas.drawGlyph(&font, &glyph, .{ .x = 3, .y = 3, .width = 4, .height = 4 }, 1, 1, 7);
    try std.testing.expectEqual(@as(u32, 7), pixels[3 * 5 + 3]);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u32, &pixels, &.{7}));
    @memset(&pixels, 0);
    canvas.drawGlyph(&font, &glyph, .{ .x = 3, .y = 3, .width = 4, .height = 4 }, 5, 5, 7);
    canvas.drawGlyph(&font, &glyph, .{ .x = 0, .y = 0, .width = 4, .height = 4 }, -5, -5, 7);
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u32, &pixels, &.{7}));
}

test "cached glyphs render with backgrounds, reverse colors and transparent pixels" {
    const allocator = std.testing.allocator;
    var font = Font{
        .allocator = allocator,
        // Cache hits must not access the FreeType faces or their mutable slots.
        .library = null,
        .cell_width = 2,
        .cell_height = 1,
        .ascender = 0,
    };
    defer font.glyphs.deinit(allocator);
    const alpha = try allocator.dupe(u8, &.{ 255, 0 });
    defer allocator.free(alpha);
    try font.glyphs.put(allocator, glyphKey('A', .regular, 1), .{ .pixels = alpha, .width = 2, .rows = 1, .left = 0, .top = 0 });
    const first = try font.glyph(glyphKey('A', .regular, 1));
    try std.testing.expect(first == try font.glyph(glyphKey('A', .regular, 1)));

    var term = try ghosttyvt.Terminal.init(std.testing.io, allocator, .{ .cols = 3, .rows = 1 });
    defer term.deinit(allocator);
    try Colors.configure(&term, allocator, Colors.background);
    var stream = ghosttyvt.TerminalStream.init(.{ .allocator = allocator, .handler = .init(&term) });
    defer stream.deinit();
    stream.nextSlice("\x1b[?25lA\x1b[41m \x1b[0m");
    var pixels: [8]u32 = @splat(99);
    var renderer = try testRenderer(&pixels, 6, 1, 8);
    defer renderer.deinitDrawing();
    _ = try renderer.drawTerminal(&font, &term);
    const red = rgbPixel(term.colors.palette.current[1]);
    const fg = rgbPixel(Colors.foreground);
    const bg = rgbPixel(Colors.background);
    try std.testing.expectEqualSlices(u32, &.{ fg, bg, red, red, bg, bg, bg, bg }, &pixels);

    stream.nextSlice("\x1b[?5h");
    _ = try renderer.drawTerminal(&font, &term);
    try std.testing.expectEqualSlices(u32, &.{ bg, fg, red, red, fg, fg, fg, fg }, &pixels);
}

test "SGR font styles and block cursor use the matching cached face" {
    const allocator = std.testing.allocator;
    var font = testFont();
    font.cell_width = 4;
    font.cell_height = 4;
    font.underline_position = 3;
    defer font.deinit();
    for ([_]FontStyle{ .regular, .bold, .italic, .bold_italic }, 0..) |style, i| {
        const alpha = try allocator.alloc(u8, 4);
        @memset(alpha, 0);
        alpha[i] = 255;
        try font.glyphs.put(allocator, glyphKey('A', style, 1), .{ .pixels = alpha, .width = 4, .rows = 1, .left = 0, .top = 0 });
    }
    var term = try ghosttyvt.Terminal.init(std.testing.io, allocator, .{ .cols = 5, .rows = 1 });
    defer term.deinit(allocator);
    try Colors.configure(&term, allocator, Colors.background);
    var stream = ghosttyvt.TerminalStream.init(.{ .allocator = allocator, .handler = .init(&term) });
    defer stream.deinit();
    stream.nextSlice("\x1b[?25lA\x1b[1mA\x1b[22;3mA\x1b[1;4mA\x1b[0mA");
    var pixels: [80]u32 = @splat(99);
    var renderer = try testRenderer(&pixels, 20, 4, 20);
    defer renderer.deinitDrawing();
    _ = try renderer.drawTerminal(&font, &term);
    const fg = rgbPixel(Colors.foreground);
    const bg = rgbPixel(Colors.background);
    var expected: [20]u32 = @splat(bg);
    for ([_]usize{ 0, 5, 10, 15, 16 }) |x| expected[x] = fg;
    try std.testing.expectEqualSlices(u32, &expected, pixels[0..20]);
    try std.testing.expectEqualSlices(u32, &@as([4]u32, @splat(fg)), pixels[72..76]);
    stream.nextSlice("\x1b[1;4H\x1b[?25h");
    _ = try renderer.drawTerminal(&font, &term);
    // The block cursor inverts both the bold-italic glyph and its underline.
    try std.testing.expectEqualSlices(u32, &.{ fg, fg, fg, bg }, pixels[12..16]);
    try std.testing.expectEqualSlices(u32, &@as([4]u32, @splat(bg)), pixels[72..76]);
}

test "underline patterns stay within the cell and preserve canvas padding" {
    var font = testFont();
    font.cell_width = 24;
    font.cell_height = 6;
    font.underline_position = 4;
    var pixels: [26 * 6]u32 = @splat(99);
    const canvas: Canvas = .{ .pixels = &pixels, .width = 24, .height = 6, .stride = 26 };
    const cases = .{
        .{ ghosttyvt.Style{ .flags = .{ .underline = .single } }, 24 },
        .{ ghosttyvt.Style{ .flags = .{ .underline = .double } }, 48 },
        .{ ghosttyvt.Style{ .flags = .{ .underline = .dotted } }, 12 },
        .{ ghosttyvt.Style{ .flags = .{ .underline = .dashed } }, 16 },
        .{ ghosttyvt.Style{ .flags = .{ .underline = .curly } }, 24 },
    };
    inline for (cases) |case| {
        @memset(&pixels, 99);
        canvas.drawUnderline(&font, case[0], .{ .x = 0, .y = 0, .width = 24, .height = 6 }, 7);
        var painted: usize = 0;
        for (0..6) |y| {
            for (0..24) |x| {
                if (pixels[y * 26 + x] == 7) {
                    painted += 1;
                    try std.testing.expect(y >= 2 and y <= 4);
                }
            }
            try std.testing.expectEqual(@as(u32, 99), pixels[y * 26 + 24]);
            try std.testing.expectEqual(@as(u32, 99), pixels[y * 26 + 25]);
        }
        try std.testing.expectEqual(@as(usize, case[1]), painted);
    }
    // A clipped, one-pixel-high cell must still get a visible underline.
    font.underline_thickness = 3;
    @memset(&pixels, 99);
    canvas.drawUnderline(&font, .{ .flags = .{ .underline = .single } }, .{ .x = 23, .y = 5, .width = 4, .height = 1 }, 7);
    try std.testing.expectEqual(@as(u32, 7), pixels[5 * 26 + 23]);
    try std.testing.expectEqual(@as(u32, 99), pixels[5 * 26 + 24]);
}

test "underlines cover spaces and wide cells with colors, resets and invisibility" {
    const allocator = std.testing.allocator;
    var font = testFont();
    font.cell_width = 2;
    font.cell_height = 4;
    font.underline_position = 2;
    defer font.deinit();
    const alpha = try allocator.dupe(u8, &.{ 255, 255, 255, 255 });
    try font.glyphs.put(allocator, glyphKey('界', .regular, 2), .{ .pixels = alpha, .width = 4, .rows = 1, .left = 0, .top = 0 });
    var term = try ghosttyvt.Terminal.init(std.testing.io, allocator, .{ .cols = 7, .rows = 1 });
    defer term.deinit(allocator);
    try Colors.configure(&term, allocator, Colors.background);
    var stream = ghosttyvt.TerminalStream.init(.{ .allocator = allocator, .handler = .init(&term) });
    defer stream.deinit();
    stream.nextSlice("\x1b[?25l\x1b[4m \x1b[58;2;18;52;86m \x1b[24m \x1b[4;8m \x1b[28;59m界\x1b[24m ");
    var pixels: [56]u32 = @splat(99);
    var renderer = try testRenderer(&pixels, 14, 4, 14);
    defer renderer.deinitDrawing();
    _ = try renderer.drawTerminal(&font, &term);
    const fg = rgbPixel(Colors.foreground);
    const bg = rgbPixel(Colors.background);
    try std.testing.expectEqualSlices(u32, &.{ fg, fg, 0x123456, 0x123456, bg, bg, bg, bg, fg, fg, fg, fg, bg, bg }, pixels[28..42]);
    try std.testing.expectEqualSlices(u32, &@as([14]u32, @splat(bg)), pixels[42..56]);
    // SGR 58 indexed colors follow palette changes, independent of glyph color.
    stream.nextSlice("\x1b[1;2H\x1b[4;58;5;1m \x1b]4;1;#abcdef\x07");
    _ = try renderer.drawTerminal(&font, &term);
    try std.testing.expectEqual(@as(u32, 0xabcdef), pixels[30]);
}

test "strikethrough and overline cover spaces in the text color" {
    const allocator = std.testing.allocator;
    var font = testFont();
    font.cell_width = 2;
    font.cell_height = 4;
    font.underline_position = 3;
    font.strikethrough_position = 2;
    defer font.deinit();
    var term = try ghosttyvt.Terminal.init(std.testing.io, allocator, .{ .cols = 3, .rows = 1 });
    defer term.deinit(allocator);
    try Colors.configure(&term, allocator, Colors.background);
    var stream = ghosttyvt.TerminalStream.init(.{ .allocator = allocator, .handler = .init(&term) });
    defer stream.deinit();
    stream.nextSlice("\x1b[?25l\x1b[9;31m \x1b[29;53m \x1b[55;4;58;2;18;52;86m ");
    var pixels: [24]u32 = @splat(99);
    var renderer = try testRenderer(&pixels, 6, 4, 6);
    defer renderer.deinitDrawing();
    _ = try renderer.drawTerminal(&font, &term);
    const red = rgbPixel(Colors.palette[1]);
    const bg = rgbPixel(Colors.background);
    try std.testing.expectEqualSlices(u32, &.{ bg, bg, red, red, bg, bg }, pixels[0..6]);
    try std.testing.expectEqualSlices(u32, &@as([6]u32, @splat(bg)), pixels[6..12]);
    try std.testing.expectEqualSlices(u32, &.{ red, red, bg, bg, bg, bg }, pixels[12..18]);
    try std.testing.expectEqualSlices(u32, &.{ bg, bg, bg, bg, 0x123456, 0x123456 }, pixels[18..24]);
}

test "grapheme clusters choose faces by presentation and compose combining marks" {
    const allocator = std.testing.allocator;
    var font = try Font.init(allocator, .{ .pixel_size = 16 });
    defer font.deinit();
    const regular: u3 = @intFromEnum(FontStyle.regular);
    try std.testing.expectEqual(@as(u3, @intFromEnum(FontStyle.bold)), font.faceFor('A', &.{}, .bold, 1));
    try std.testing.expectEqual(emoji_face, font.faceFor(0x1F600, &.{}, .bold, 2));
    // Both faces cover these: narrow cells and VS15 mean text, wide cells and VS16 mean emoji.
    try std.testing.expectEqual(regular, font.faceFor(0x26A0, &.{}, .regular, 1));
    try std.testing.expectEqual(emoji_face, font.faceFor(0x26A0, &.{0xFE0F}, .regular, 2));
    try std.testing.expectEqual(emoji_face, font.faceFor(0x26A1, &.{}, .regular, 2));
    try std.testing.expectEqual(regular, font.faceFor(0x26A1, &.{0xFE0E}, .regular, 2));
    try std.testing.expectEqual(regular, font.faceFor('#', &.{}, .regular, 1));
    try std.testing.expectEqual(emoji_face, font.faceFor('#', &.{0x20E3}, .regular, 1));

    const text = font.faces[regular];
    const composed = try font.shape('e', &.{0x0301}, .regular, 1);
    try std.testing.expectEqual(@as(usize, 1), composed.len);
    try std.testing.expectEqual(indexKey(regular, freetype.FT_Get_Char_Index(text, 0xE9), 1), composed[0].key);
    try std.testing.expect(composed.ptr == (try font.shape('e', &.{0x0301}, .regular, 1)).ptr);
    // Without a precomposed form, the mark is a second glyph over the base.
    const stacked = try font.shape('q', &.{0x0301}, .regular, 1);
    try std.testing.expectEqual(@as(usize, 2), stacked.len);
    try std.testing.expectEqual(indexKey(regular, freetype.FT_Get_Char_Index(text, 0x0301), 1), stacked[1].key);
    // Zero-advance marks draw back from the pen, so their ink lands in the cell.
    const mark = try font.glyph(stacked[1].key);
    const ink_center = stacked[1].x + mark.left + @as(i32, @intCast(mark.width / 2));
    try std.testing.expect(ink_center >= 0 and ink_center < font.cell_width);
    try std.testing.expect(font.ascender - mark.top + stacked[1].y < @divFloor(font.ascender, 2));
    // A mark the face lacks is dropped instead of boxing over the base.
    const missing = try font.shape('a', &.{0x0331}, .regular, 1);
    try std.testing.expectEqual(@as(usize, 1), missing.len);
    try std.testing.expectEqual(indexKey(regular, freetype.FT_Get_Char_Index(text, 'a'), 1), missing[0].key);
}

test "emoji sequences render as one color glyph within their cells" {
    const allocator = std.testing.allocator;
    var font = try Font.init(allocator, .{ .pixel_size = 16 });
    defer font.deinit();
    const cols = 14;
    var term = try ghosttyvt.Terminal.init(std.testing.io, allocator, .{
        .cols = cols,
        .rows = 1,
        .default_modes = .{ .grapheme_cluster = true },
    });
    defer term.deinit(allocator);
    try Colors.configure(&term, allocator, Colors.background);
    var stream = ghosttyvt.TerminalStream.init(.{ .allocator = allocator, .handler = .init(&term) });
    defer stream.deinit();
    // A skin tone, a ZWJ family, a flag, a keycap, a VS16 heart, and a plain emoji.
    stream.nextSlice("\x1b[?25l\u{1F44D}\u{1F3FD}\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{1F1FA}\u{1F1F8}1\u{FE0F}\u{20E3}\u{2764}\u{FE0F}\u{1F600}");

    const pin = term.screens.active.pages.pin(.{ .active = .{ .x = 0, .y = 0 } }).?;
    var count: usize = 0;
    for (pin.cells(.all), 0..) |*cell, column| {
        if (cell.codepoint() == 0 or cell.wide == .spacer_tail) continue;
        const cells = cell.gridWidth();
        const key = if (pin.grapheme(cell)) |extra| key: {
            const placed = try font.shape(cell.codepoint(), extra, .regular, cells);
            try std.testing.expectEqual(@as(usize, 1), placed.len);
            break :key placed[0].key;
        } else glyphKey(cell.codepoint(), .regular, cells);
        if (count == 1) {
            // The family has its own glyph, rather than the man that starts it.
            const man = freetype.FT_Get_Char_Index(font.faces[emoji_face], 0x1F468);
            try std.testing.expect(key != indexKey(emoji_face, man, cells));
        }
        const glyph = try font.glyph(key);
        try std.testing.expect(glyph.color);
        try std.testing.expect(glyph.width > 0 and glyph.left >= 0 and glyph.left + @as(i64, @intCast(glyph.width)) <= font.cell_width * cells);
        const top = font.ascender - glyph.top;
        try std.testing.expect(top >= 0 and top + @as(i64, @intCast(glyph.rows)) <= font.cell_height);
        try std.testing.expect(column + cells <= cols);
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 6), count);

    const width = cols * font.cell_width;
    const pixels = try allocator.alloc(u32, width * font.cell_height);
    defer allocator.free(pixels);
    var renderer = try testRenderer(pixels, @intCast(width), @intCast(font.cell_height), width);
    defer renderer.deinitDrawing();
    _ = try renderer.drawTerminal(&font, &term);
    var colored: usize = 0;
    for (pixels) |pixel| {
        if ((pixel >> 16) & 0xFF != pixel & 0xFF) colored += 1;
    }
    try std.testing.expect(colored > pixels.len / 8);
}

test "box drawing fills whole cells so lines join across rows and columns" {
    const allocator = std.testing.allocator;
    var font = testFont();
    font.cell_width = 5;
    font.cell_height = 7;
    font.ascender = 5;
    defer font.deinit();
    var term = try ghosttyvt.Terminal.init(std.testing.io, allocator, .{ .cols = 3, .rows = 3 });
    defer term.deinit(allocator);
    try Colors.configure(&term, allocator, Colors.background);
    var stream = ghosttyvt.TerminalStream.init(.{ .allocator = allocator, .handler = .init(&term) });
    defer stream.deinit();
    stream.nextSlice("\x1b[?25l┌─┐\r\n│ │\r\n└─┘");
    var pixels: [15 * 21]u32 = @splat(0);
    var renderer = try testRenderer(&pixels, 15, 21, 15);
    defer renderer.deinitDrawing();
    _ = try renderer.drawTerminal(&font, &term);
    const fg = rgbPixel(Colors.foreground);
    // Each cell's light lines sit on row 3 and column 2 of the cell.
    for (2..13) |x| {
        try std.testing.expectEqual(fg, pixels[3 * 15 + x]);
        try std.testing.expectEqual(fg, pixels[17 * 15 + x]);
    }
    for (3..18) |y| {
        try std.testing.expectEqual(fg, pixels[y * 15 + 2]);
        try std.testing.expectEqual(fg, pixels[y * 15 + 12]);
    }
    try std.testing.expectEqual(rgbPixel(Colors.background), pixels[2 * 15 + 2]);
    try std.testing.expectEqual(rgbPixel(Colors.background), pixels[10 * 15 + 7]);
}

test "box drawing ignores the font's glyphs and spans the font's cell" {
    var font = try Font.init(std.testing.allocator, .{ .pixel_size = 16 });
    defer font.deinit();
    const glyph = try font.glyph(glyphKey(0x2502, .bold, 1));
    try std.testing.expectEqual(@as(usize, font.cell_width), glyph.width);
    try std.testing.expectEqual(@as(usize, font.cell_height), glyph.rows);
    try std.testing.expectEqual(font.ascender, glyph.top);
    const column = (font.cell_width - font.underline_thickness) / 2;
    for (0..glyph.rows) |row| try std.testing.expectEqual(@as(u8, 255), glyph.pixels[row * glyph.width + column]);
}

test "powerline separators ignore the font's glyphs and fill the font's cell" {
    var font = try Font.init(std.testing.allocator, .{ .pixel_size = 16 });
    defer font.deinit();
    for ([_]u21{ 0xE0B0, 0xE0B4 }) |codepoint| {
        const glyph = try font.glyph(glyphKey(codepoint, .regular, 1));
        try std.testing.expectEqual(@as(usize, font.cell_width), glyph.width);
        try std.testing.expectEqual(@as(usize, font.cell_height), glyph.rows);
        try std.testing.expectEqual(font.ascender, glyph.top);
        for (1..glyph.rows - 1) |row| try std.testing.expectEqual(@as(u8, 255), glyph.pixels[row * glyph.width]);
    }
}

test "full blocks ignore the font's glyphs and cover the whole cell" {
    var font = try Font.init(std.testing.allocator, .{ .pixel_size = 16 });
    defer font.deinit();
    const glyph = try font.glyph(glyphKey(0x2588, .regular, 1));
    try std.testing.expectEqual(@as(usize, font.cell_width), glyph.width);
    try std.testing.expectEqual(@as(usize, font.cell_height), glyph.rows);
    try std.testing.expectEqual(font.ascender, glyph.top);
    try std.testing.expect(std.mem.allEqual(u8, glyph.pixels, 255));
}

fn testFont() Font {
    return .{
        .allocator = std.testing.allocator,
        .library = null,
        .cell_width = 1,
        .cell_height = 1,
        .ascender = 0,
    };
}

test "dirty rows leave clean pixels untouched and accumulate across both buffers" {
    const allocator = std.testing.allocator;
    var font = testFont();
    var term = try ghosttyvt.Terminal.init(std.testing.io, allocator, .{ .cols = 3, .rows = 3 });
    defer term.deinit(allocator);
    try Colors.configure(&term, allocator, Colors.background);
    var stream = ghosttyvt.TerminalStream.init(.{ .allocator = allocator, .handler = .init(&term) });
    defer stream.deinit();
    stream.nextSlice("\x1b[?25l");
    var pixels: [2][24]u32 = @splat(@splat(99));
    var renderer = try testRenderer(&pixels[0], 4, 4, 6);
    renderer.framebuffers[1].map = &pixels[1];
    defer renderer.deinitDrawing();
    // Initialize both back buffers, just as successive page flips would.
    try std.testing.expect(try renderer.drawTerminal(&font, &term));
    renderer.completeFlip();
    try std.testing.expect(try renderer.drawTerminal(&font, &term));
    renderer.completeFlip();
    try std.testing.expect(!try renderer.drawTerminal(&font, &term));

    // A clean row must not be touched, not even by a full-screen clear.
    pixels[0][12] = 0xDEADBEEF;
    stream.nextSlice("\x1b[1;1H\x1b[41m \x1b[0m");
    try std.testing.expect(try renderer.drawTerminal(&font, &term));
    try std.testing.expectEqual(@as(u32, 0xDEADBEEF), pixels[0][12]);
    try std.testing.expectEqual(@as(u32, 0xCD0000), pixels[0][0]);
    try std.testing.expect(renderer.damage.rows.items[0].pending[1]);
    try std.testing.expect(!renderer.damage.rows.items[1].pending[1]);
    pixels[0][12] = 0;
    renderer.completeFlip();

    // The other buffer needs the previous row AND a newly dirtied row.
    stream.nextSlice("\x1b[3;1H\x1b[44m \x1b[0m");
    try std.testing.expect(try renderer.drawTerminal(&font, &term));
    try std.testing.expectEqual(@as(u32, 0xCD0000), pixels[1][0]);
    try std.testing.expectEqual(@as(u32, 0x0000EE), pixels[1][12]);
    renderer.completeFlip();
    stream.nextSlice("\x1b[2;1H\x1b[42m \x1b[0m");
    try std.testing.expect(try renderer.drawTerminal(&font, &term));
    try std.testing.expectEqual(@as(u32, 0xCD0000), pixels[0][0]);
    try std.testing.expectEqual(@as(u32, 0x00CD00), pixels[0][6]);
    try std.testing.expectEqual(@as(u32, 0x0000EE), pixels[0][12]);
    renderer.completeFlip();
    try std.testing.expect(try renderer.drawTerminal(&font, &term));
    try std.testing.expectEqualSlices(u32, &pixels[0], &pixels[1]);
    renderer.completeFlip();
    // Nonvisual output must not submit another page flip once both match.
    stream.nextSlice("\x1b]2;new title\x07");
    try std.testing.expect(!try renderer.drawTerminal(&font, &term));
}

test "incremental frames match full redraws through cursor, color, screen and scroll changes" {
    const allocator = std.testing.allocator;
    var font = testFont();
    var term = try ghosttyvt.Terminal.init(std.testing.io, allocator, .{ .cols = 3, .rows = 3 });
    defer term.deinit(allocator);
    try Colors.configure(&term, allocator, Colors.background);
    var stream = ghosttyvt.TerminalStream.init(.{ .allocator = allocator, .handler = .init(&term) });
    defer stream.deinit();
    var pixels: [2][24]u32 = @splat(@splat(99));
    var expected: [24]u32 = @splat(99);
    var renderer = try testRenderer(&pixels[0], 4, 4, 6);
    renderer.framebuffers[1].map = &pixels[1];
    defer renderer.deinitDrawing();
    var reference = try testRenderer(&expected, 4, 4, 6);
    defer reference.deinitDrawing();
    const updates = [_][]const u8{
        "\x1b[?25l",
        "\x1b[41m \x1b[0m",
        "\x1b[1;2H\x1b[4m \x1b[24m",
        "\x1b[1;2H\x1b[4:2m \x1b[24m",
        "\x1b[1;2H\x1b[4:3m \x1b[24m",
        "\x1b[1;2H\x1b[4:4m \x1b[24m",
        "\x1b[1;2H\x1b[4:5m \x1b[24m",
        "\x1b[1;2H ",
        "\x1b[3;1H\x1b[44m \x1b[0m",
        "\x1b[2;1H\x1b[42m \x1b[0m",
        "\x1b[?25h\x1b[1;1H",
        "\x1b[3;2H",
        "\x1b[5 q",
        "\x1b]12;#123456\x07",
        "\x1b[3 q",
        "\x1b[?25l",
        "\x1b[1;1H\x1b[2K",
        "\x1b]4;4;#abcdef\x07",
        "\x1b]11;#010203\x07",
        "\x1b]10;#654321\x07",
        "\x1b[?5h",
        "\x1b[?1049h\x1b[45m \x1b[0m",
        "\x1b[?1049l",
        "\x1b[3;1H\r\n",
        "\x1b[1;3r\x1b[1;1H\x1b[L",
        "\x1b[M",
        "\x1b[2J",
        "\x1bc",
    };
    for (updates) |update| {
        stream.nextSlice(update);
        const changed = try renderer.drawTerminal(&font, &term);
        reference.damage.invalidate();
        _ = try reference.drawTerminal(&font, &term);
        try std.testing.expectEqualSlices(u32, &expected, &pixels[renderer.render_index]);
        if (changed) renderer.completeFlip();
    }
    // Font/grid changes also repaint margins and clear now-uncovered pixels.
    font.cell_height = 2;
    _ = try renderer.drawTerminal(&font, &term);
    reference.damage.invalidate();
    _ = try reference.drawTerminal(&font, &term);
    try std.testing.expectEqualSlices(u32, &expected, &pixels[renderer.render_index]);
}

test "scrolled viewports render history and hide an off-screen cursor" {
    const allocator = std.testing.allocator;
    var font = testFont();
    var term = try ghosttyvt.Terminal.init(std.testing.io, allocator, .{ .cols = 3, .rows = 3, .max_scrollback_bytes = null });
    defer term.deinit(allocator);
    try Colors.configure(&term, allocator, Colors.background);
    var stream = ghosttyvt.TerminalStream.init(.{ .allocator = allocator, .handler = .init(&term) });
    defer stream.deinit();
    var pixels: [2][9]u32 = @splat(@splat(99));
    var expected: [9]u32 = @splat(99);
    var renderer = try testRenderer(&pixels[0], 3, 3, 3);
    renderer.framebuffers[1].map = &pixels[1];
    defer renderer.deinitDrawing();
    var reference = try testRenderer(&expected, 3, 3, 3);
    defer reference.deinitDrawing();

    const Step = union(enum) { output: []const u8, scroll: ghosttyvt.Terminal.ScrollViewport };
    const steps = [_]Step{
        // Five rows with distinct backgrounds; the first two move into history.
        .{ .output = "\x1b[41m \x1b[0m\r\n\x1b[42m \x1b[0m\r\n\x1b[43m \x1b[0m\r\n\x1b[44m \x1b[0m\r\n\x1b[45m \x1b[0m" },
        .{ .scroll = .{ .delta = -1 } },
        .{ .scroll = .top },
        // Output while scrolled back leaves the visible history in place.
        .{ .output = "\r\n\x1b[46m \x1b[0m" },
        .{ .scroll = .{ .delta = 1 } },
        .{ .scroll = .bottom },
    };
    for (steps) |step| {
        switch (step) {
            .output => |bytes| stream.nextSlice(bytes),
            .scroll => |scroll| term.scrollViewport(scroll),
        }
        const changed = try renderer.drawTerminal(&font, &term);
        reference.damage.invalidate();
        _ = try reference.drawTerminal(&font, &term);
        try std.testing.expectEqualSlices(u32, &expected, &pixels[renderer.render_index]);
        if (changed) renderer.completeFlip();
    }
    const screen = term.screens.active;
    try std.testing.expectEqual(@as(?u16, 2), cursorRow(screen));

    term.scrollViewport(.top);
    try std.testing.expectEqual(@as(?u16, null), cursorRow(screen));
    try std.testing.expect(try renderer.drawTerminal(&font, &term));
    const frame = pixels[renderer.render_index];
    try std.testing.expectEqualSlices(u32, &.{ 0xCD0000, 0x00CD00, 0xCDCD00 }, &.{ frame[0], frame[3], frame[6] });
    renderer.completeFlip();

    // Scrolling up one row pushes the cursor's bottom row out of view.
    term.scrollViewport(.bottom);
    term.scrollViewport(.{ .delta = -1 });
    try std.testing.expectEqual(@as(?u16, null), cursorRow(screen));
    term.scrollViewport(.{ .delta = 1 });
    try std.testing.expectEqual(@as(?u16, 2), cursorRow(screen));
}

test "kitty images draw in z layers and incremental frames match full redraws" {
    const allocator = std.testing.allocator;
    var font = testFont();
    var term = try ghosttyvt.Terminal.init(std.testing.io, allocator, .{ .cols = 4, .rows = 3 });
    defer term.deinit(allocator);
    try Colors.configure(&term, allocator, Colors.background);
    term.width_px = 4;
    term.height_px = 3;
    var stream = ghosttyvt.TerminalStream.init(.{ .allocator = allocator, .handler = .init(&term) });
    defer stream.deinit();
    var pixels: [2][12]u32 = @splat(@splat(99));
    var expected: [12]u32 = @splat(99);
    var renderer = try testRenderer(&pixels[0], 4, 3, 4);
    renderer.framebuffers[1].map = &pixels[1];
    defer renderer.deinitDrawing();
    var reference = try testRenderer(&expected, 4, 3, 4);
    defer reference.deinitDrawing();

    // A 2x2 RGB image, one pixel per cell: red, green / blue, white.
    const rgb = [_]u8{ 255, 0, 0, 0, 255, 0, 0, 0, 255, 255, 255, 255 };
    var base64: [16]u8 = undefined;
    var transmit_buffer: [64]u8 = undefined;
    // C=1 keeps the cursor still, so placing on the last row does not scroll.
    const transmit = try std.fmt.bufPrint(&transmit_buffer, "\x1b_Ga=T,f=24,s=2,v=2,i=1,p=1,C=1,q=2;{s}\x1b\\", .{std.base64.standard.Encoder.encode(&base64, &rgb)});

    const red = 0xFF0000;
    const default_bg = rgbPixel(Colors.background);
    const Check = struct { index: usize, value: u32 };
    const Step = struct { update: []const u8, checks: []const Check = &.{} };
    const steps = [_]Step{
        .{ .update = "\x1b[?25l" },
        .{ .update = transmit, .checks = &.{ .{ .index = 0, .value = red }, .{ .index = 5, .value = 0xFFFFFF } } },
        // z = 0 draws over text and its background.
        .{ .update = "\x1b[1;1H\x1b[44m \x1b[0m", .checks = &.{.{ .index = 0, .value = red }} },
        // Negative z draws over cell backgrounds but under text.
        .{
            .update = "\x1b[1;4H\x1b_Ga=p,i=1,p=2,z=-1,c=1,r=1,C=1,q=2\x1b\\\x1b[42m \x1b[0m",
            .checks = &.{.{ .index = 3, .value = red }},
        },
        // Below INT32_MIN/2, only default-background cells show the image.
        .{
            .update = "\x1b[3;3H\x1b_Ga=p,i=1,p=3,z=-2147483648,c=1,r=1,C=1,q=2\x1b\\" ++
                "\x1b[3;4H\x1b_Ga=p,i=1,p=4,z=-2147483648,c=1,r=1,C=1,q=2\x1b\\\x1b[42m \x1b[0m",
            .checks = &.{ .{ .index = 10, .value = red }, .{ .index = 11, .value = 0x00CD00 } },
        },
        .{ .update = "\x1b_Ga=d,d=i,i=1,p=1,q=2\x1b\\", .checks = &.{.{ .index = 5, .value = default_bg }} },
        // Placements scroll with the text they were placed on.
        .{ .update = "\x1b[3;1H\r\n", .checks = &.{.{ .index = 6, .value = red }} },
        .{ .update = "\x1bc" },
    };
    for (steps) |step| {
        stream.nextSlice(step.update);
        const changed = try renderer.drawTerminal(&font, &term);
        reference.damage.invalidate();
        _ = try reference.drawTerminal(&font, &term);
        try std.testing.expectEqualSlices(u32, &expected, &pixels[renderer.render_index]);
        for (step.checks) |check| try std.testing.expectEqual(check.value, expected[check.index]);
        if (changed) renderer.completeFlip();
    }
    try std.testing.expectEqual(@as(usize, 0), renderer.images.items.len);
}

test "pending flips retain source damage and wide cursor moves erase the old row" {
    const allocator = std.testing.allocator;
    var font = testFont();
    defer font.glyphs.deinit(allocator);
    const alpha = try allocator.dupe(u8, &.{ 255, 128 });
    defer allocator.free(alpha);
    try font.glyphs.put(allocator, glyphKey('界', .regular, 2), .{ .pixels = alpha, .width = 2, .rows = 1, .left = 0, .top = 0 });
    var term = try ghosttyvt.Terminal.init(std.testing.io, allocator, .{ .cols = 3, .rows = 3 });
    defer term.deinit(allocator);
    try Colors.configure(&term, allocator, Colors.background);
    var stream = ghosttyvt.TerminalStream.init(.{ .allocator = allocator, .handler = .init(&term) });
    defer stream.deinit();
    var pixels: [2][9]u32 = @splat(@splat(99));
    var renderer = try testRenderer(&pixels[0], 3, 3, 3);
    renderer.framebuffers[1].map = &pixels[1];
    defer renderer.deinitDrawing();
    stream.nextSlice("\x1b[?25l界\x1b[1;2H\x1b[?25h");
    _ = try renderer.drawTerminal(&font, &term);
    renderer.flip_pending = true;
    stream.nextSlice("\x1b[3;1H\x1b[44m \x1b[0m");
    try std.testing.expectError(error.PageFlipPending, renderer.drawTerminal(&font, &term));
    renderer.completeFlip();
    _ = try renderer.drawTerminal(&font, &term);
    renderer.completeFlip();
    _ = try renderer.drawTerminal(&font, &term);
    const fg = rgbPixel(Colors.foreground);
    const bg = rgbPixel(Colors.background);
    try std.testing.expectEqualSlices(u32, &.{ fg, blendPixel(bg, fg, 128), bg }, pixels[0][0..3]);
    try std.testing.expectEqualSlices(u32, &pixels[0], &pixels[1]);
    // Repainting an unchanged cursor would blend its glyph a second time.
    try std.testing.expect(!try renderer.drawTerminal(&font, &term));
    try std.testing.expectEqualSlices(u32, &pixels[0], &pixels[1]);
}

test "failed row drawing retains damage until a successful retry" {
    const allocator = std.testing.allocator;
    var font = testFont();
    defer font.glyphs.deinit(allocator);
    var term = try ghosttyvt.Terminal.init(std.testing.io, allocator, .{ .cols = 3, .rows = 3 });
    defer term.deinit(allocator);
    try Colors.configure(&term, allocator, Colors.background);
    var stream = ghosttyvt.TerminalStream.init(.{ .allocator = allocator, .handler = .init(&term) });
    defer stream.deinit();
    var pixels: [2][9]u32 = @splat(@splat(99));
    var renderer = try testRenderer(&pixels[0], 3, 3, 3);
    renderer.framebuffers[1].map = &pixels[1];
    defer renderer.deinitDrawing();
    stream.nextSlice("\x1b[?25l");
    _ = try renderer.drawTerminal(&font, &term);
    renderer.completeFlip();
    _ = try renderer.drawTerminal(&font, &term);
    renderer.completeFlip();
    stream.nextSlice("\x1b[2;1HA");
    pixels[0][3] = 0xDEADBEEF;
    // An uncached glyph on this synthetic font has no FreeType face to load.
    try std.testing.expectError(error.GlyphLoadFailed, renderer.drawTerminal(&font, &term));
    // The terminal's flag is consumed, but the renderer keeps the damage.
    const pin = term.screens.active.pages.pin(.{ .active = .{ .x = 0, .y = 1 } }).?;
    try std.testing.expect(!pin.rowAndCell().row.dirty);
    try std.testing.expect(renderer.damage.rows.items[1].stale);
    try std.testing.expect(renderer.damage.rows.items[1].pending[0]);
    try std.testing.expect(renderer.damage.rows.items[1].pending[1]);
    // A failed frame never reaches the back buffer.
    try std.testing.expectEqual(@as(u32, 0xDEADBEEF), pixels[0][3]);
    const alpha = try allocator.dupe(u8, &.{255});
    defer allocator.free(alpha);
    try font.glyphs.put(allocator, glyphKey('A', .regular, 1), .{ .pixels = alpha, .width = 1, .rows = 1, .left = 0, .top = 0 });
    try std.testing.expect(try renderer.drawTerminal(&font, &term));
    try std.testing.expect(!renderer.damage.rows.items[1].stale);
    try std.testing.expectEqual(rgbPixel(Colors.foreground), pixels[0][3]);
    renderer.completeFlip();
    _ = try renderer.drawTerminal(&font, &term);
    try std.testing.expectEqualSlices(u32, &pixels[0], &pixels[1]);
}

test "SGR colors preserve indexed and RGB values and apply intensity and inverse" {
    const allocator = std.testing.allocator;
    var term = try ghosttyvt.Terminal.init(std.testing.io, allocator, .{ .cols = 16, .rows = 1 });
    defer term.deinit(allocator);
    try Colors.configure(&term, allocator, Colors.background);
    var stream = ghosttyvt.TerminalStream.init(.{ .allocator = allocator, .handler = .init(&term) });
    defer stream.deinit();
    stream.nextSlice("\x1b[31mA\x1b[1mB\x1b[22;91mC\x1b[0;38;5;196mD" ++
        "\x1b[38;2;18;52;86;48;2;101;67;33mE\x1b[7mF\x1b[0;2;31mG\x1b[0;44m H");
    const fg = rgbPixel(Colors.foreground);
    const bg = rgbPixel(Colors.background);
    const expected = [_]CellColors{
        .{ .fg = 0xCD0000, .bg = bg },
        .{ .fg = 0xFF0000, .bg = bg },
        .{ .fg = 0xFF0000, .bg = bg },
        .{ .fg = 0xFF0000, .bg = bg },
        .{ .fg = 0x123456, .bg = 0x654321 },
        .{ .fg = 0x654321, .bg = 0x123456 },
        .{ .fg = blendPixel(bg, 0xCD0000, 128), .bg = bg },
        .{ .fg = fg, .bg = 0x0000EE },
        .{ .fg = fg, .bg = 0x0000EE },
    };
    for (expected, 0..) |colors, x| {
        const pin = term.screens.active.pages.pin(.{ .active = .{ .x = @intCast(x), .y = 0 } }).?;
        const cell = pin.rowAndCell().cell;
        try std.testing.expectEqual(colors, cellColors(cell.*, pin.style(cell), .of(&term)));
    }
    // Reverse-video must not swap explicit foreground/background pairs.
    stream.nextSlice("\x1b[?5h");
    for ([_]u16{ 4, 5 }) |x| {
        const pin = term.screens.active.pages.pin(.{ .active = .{ .x = x, .y = 0 } }).?;
        const cell = pin.rowAndCell().cell;
        try std.testing.expectEqual(expected[x], cellColors(cell.*, pin.style(cell), .of(&term)));
    }
    const pin = term.screens.active.pages.pin(.{ .active = .{ .x = 0, .y = 0 } }).?;
    const cell = pin.rowAndCell().cell;
    try std.testing.expectEqual(CellColors{ .fg = 0xCD0000, .bg = fg }, cellColors(cell.*, pin.style(cell), .of(&term)));
    // Cached cells must continue to follow application palette updates.
    stream.nextSlice("\x1b]4;1;#123456\x07");
    try std.testing.expectEqual(CellColors{ .fg = 0x123456, .bg = fg }, cellColors(cell.*, pin.style(cell), .of(&term)));
}

test "page flip completion releases the old buffer and pending flips prevent drawing" {
    var pixels = [_]u32{0};
    var renderer = try testRenderer(&pixels, 1, 1, 1);
    defer renderer.deinitDrawing();
    renderer.display_index = 0;
    renderer.render_index = 1;
    renderer.flip_pending = true;
    try std.testing.expectError(error.PageFlipPending, renderer.present());
    // The pending guard must run before touching font or terminal state.
    var font: Font = undefined;
    var term: ghosttyvt.Terminal = undefined;
    try std.testing.expectError(error.PageFlipPending, renderer.drawTerminal(&font, &term));
    try std.testing.expectEqual(@as(usize, 1), renderer.render_index);
    page_flip_handler(-1, 0, 0, 0, &renderer);
    try std.testing.expect(!renderer.flip_pending);
    try std.testing.expectEqual(@as(?usize, 1), renderer.display_index);
    try std.testing.expectEqual(@as(usize, 0), renderer.render_index);
    try std.testing.expectEqual(@as(u64, std.time.ns_per_s / 60), renderer.frameIntervalNs());
    renderer.mode.vrefresh = 144;
    try std.testing.expectEqual(@as(u64, std.time.ns_per_s / 144), renderer.frameIntervalNs());
}

fn createFramebuffer(fd: c_int, mode: libdrm.drmModeModeInfo) !Framebuffer {
    var create_request = std.mem.zeroes(libdrm.drm_mode_create_dumb);
    create_request.width = mode.hdisplay;
    create_request.height = mode.vdisplay;
    create_request.bpp = 32;
    if (libdrm.drmIoctl(fd, libdrm.DRM_IOCTL_MODE_CREATE_DUMB, &create_request) < 0) {
        return error.FailedToCreateDumbBuffer;
    }
    errdefer destroyDumbBuffer(fd, create_request.handle);

    var framebuffer_id: u32 = 0;
    var handles = [_]u32{ create_request.handle, 0, 0, 0 };
    var pitches = [_]u32{ create_request.pitch, 0, 0, 0 };
    var offsets = [_]u32{ 0, 0, 0, 0 };
    if (libdrm.drmModeAddFB2(
        fd,
        mode.hdisplay,
        mode.vdisplay,
        libdrm.DRM_FORMAT_XRGB8888,
        &handles,
        &pitches,
        &offsets,
        &framebuffer_id,
        0,
    ) != 0) {
        return error.FailedToAddFB;
    }
    errdefer _ = libdrm.drmModeRmFB(fd, framebuffer_id);

    var map_request = std.mem.zeroes(libdrm.drm_mode_map_dumb);
    map_request.handle = create_request.handle;
    if (libdrm.drmIoctl(fd, libdrm.DRM_IOCTL_MODE_MAP_DUMB, &map_request) < 0) {
        return error.FailedToMapDumbBuffer;
    }

    const offset = @as(libdrm.off_t, @intCast(map_request.offset));
    const map = linux.mmap(
        null,
        create_request.size,
        linux.PROT{ .READ = true, .WRITE = true },
        .{ .TYPE = linux.MAP_TYPE.SHARED },
        fd,
        offset,
    );
    if (linux.errno(map) != .SUCCESS) return error.MmapFailed;
    const mapped_memory: *anyopaque = @ptrFromInt(map);
    errdefer _ = linux.munmap(@ptrCast(mapped_memory), @intCast(create_request.size));

    return .{
        .id = framebuffer_id,
        .handle = create_request.handle,
        .map = mapped_memory,
        .size = @intCast(create_request.size),
        .stride = create_request.pitch / @sizeOf(u32),
    };
}

fn destroyFramebuffer(fd: c_int, framebuffer: Framebuffer) void {
    _ = linux.munmap(@ptrCast(framebuffer.map), framebuffer.size);
    _ = libdrm.drmModeRmFB(fd, framebuffer.id);
    destroyDumbBuffer(fd, framebuffer.handle);
}

fn destroyDumbBuffer(fd: c_int, handle: u32) void {
    var destroy_request = std.mem.zeroes(libdrm.drm_mode_destroy_dumb);
    destroy_request.handle = handle;
    _ = libdrm.drmIoctl(fd, libdrm.DRM_IOCTL_MODE_DESTROY_DUMB, &destroy_request);
}
