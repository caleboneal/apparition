const std = @import("std");
const linux = std.os.linux;

const libdrm = @import("libdrm");
const freetype = @import("freetype");
const ghosttyvt = @import("ghostty-vt");
const Drm = @import("drm.zig");
const Colors = @import("colors.zig");

const Self = @This();

const Glyph = struct {
    alpha: []u8,
    width: usize,
    rows: usize,
    left: i32,
    top: i32,

    fn copy(allocator: std.mem.Allocator, bitmap: freetype.FT_Bitmap, left: i32, top: i32) !Glyph {
        if (bitmap.pixel_mode != freetype.FT_PIXEL_MODE_GRAY and bitmap.pixel_mode != freetype.FT_PIXEL_MODE_MONO)
            return error.UnsupportedGlyphPixelMode;
        const alpha = try allocator.alloc(u8, @as(usize, bitmap.width) * bitmap.rows);
        for (0..bitmap.rows) |row| {
            // FreeType pitch is signed and may include padding between rows.
            const address = @as(i128, @intCast(@intFromPtr(bitmap.buffer))) + @as(i128, @intCast(row)) * bitmap.pitch;
            const source: [*]const u8 = @ptrFromInt(@as(usize, @intCast(address)));
            const dest = alpha[row * bitmap.width ..][0..bitmap.width];
            if (bitmap.pixel_mode == freetype.FT_PIXEL_MODE_GRAY) {
                @memcpy(dest, source[0..bitmap.width]);
            } else {
                for (dest, 0..) |*value, column| {
                    value.* = if (source[column / 8] & (@as(u8, 0x80) >> @as(u3, @intCast(column % 8))) != 0) 255 else 0;
                }
            }
        }
        return .{ .alpha = alpha, .width = bitmap.width, .rows = bitmap.rows, .left = left, .top = top };
    }
};

/// Owns a reusable FreeType face and cached glyph masks at one fixed size.
/// Not thread-safe: loading a glyph mutates the face's glyph slot.
pub const Font = struct {
    allocator: std.mem.Allocator,
    glyphs: std.AutoHashMapUnmanaged(u21, Glyph) = .empty,
    library: freetype.FT_Library,
    face: freetype.FT_Face,
    cell_width: u32,
    cell_height: u32,
    ascender: i32,

    pub fn init(allocator: std.mem.Allocator, font_path: [*:0]const u8, pixel_size: u32) !Font {
        if (pixel_size == 0) return error.InvalidPixelSize;
        var library: freetype.FT_Library = undefined;
        if (freetype.FT_Init_FreeType(&library) != 0) return error.FailedToInitializeFreeType;
        errdefer _ = freetype.FT_Done_FreeType(library);

        var face: freetype.FT_Face = undefined;
        if (freetype.FT_New_Face(library, font_path, 0, &face) != 0) return error.FailedToLoadTypeface;
        errdefer _ = freetype.FT_Done_Face(face);
        if (freetype.FT_Set_Pixel_Sizes(face, 0, pixel_size) != 0) return error.FailedToSetPixelSizes;

        const metrics = face.*.size.*.metrics;
        const width = @max(1, @divFloor(metrics.max_advance + 63, 64));
        const ascender = @max(0, @divFloor(metrics.ascender + 63, 64));
        const height = @max(1, @max(@divFloor(metrics.height + 63, 64), ascender - @divFloor(metrics.descender, 64)));
        // Coordinates below use signed pixel offsets, including glyph bearings.
        if (width > std.math.maxInt(i32) or height > std.math.maxInt(i32)) return error.InvalidFontMetrics;
        return .{
            .allocator = allocator,
            .library = library,
            .face = face,
            .cell_width = @intCast(width),
            .cell_height = @intCast(height),
            .ascender = @intCast(ascender),
        };
    }

    fn glyph(self: *Font, codepoint: u21) !*const Glyph {
        if (self.glyphs.getPtr(codepoint)) |cached| return cached;
        if (freetype.FT_Load_Char(self.face, codepoint, freetype.FT_LOAD_RENDER | freetype.FT_LOAD_TARGET_NORMAL) != 0)
            return error.GlyphLoadFailed;
        const slot = self.face.*.glyph.*;
        const cached = try Glyph.copy(self.allocator, slot.bitmap, slot.bitmap_left, slot.bitmap_top);
        errdefer self.allocator.free(cached.alpha);
        try self.glyphs.put(self.allocator, codepoint, cached);
        return self.glyphs.getPtr(codepoint).?;
    }

    pub fn deinit(self: *Font) void {
        var values = self.glyphs.valueIterator();
        while (values.next()) |cached| self.allocator.free(cached.alpha);
        self.glyphs.deinit(self.allocator);
        _ = freetype.FT_Done_Face(self.face);
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
    full: [2]bool = .{ true, true },
    key: ?RenderKey = null,
    cursor: ?CursorState = null,

    fn deinit(self: *Damage, allocator: std.mem.Allocator) void {
        self.rows.deinit(allocator);
    }

    fn invalidate(self: *Damage) void {
        self.full = .{ true, true };
        for (self.rows.items) |*row| row.pending = .{ true, true };
    }

    fn mark(self: *Damage, y: usize) void {
        if (y < self.rows.items.len) self.rows.items[y].pending = .{ true, true };
    }
};

allocator: std.mem.Allocator,
damage: Damage = .{},
device: Drm.Device,
fd: c_int,
mode: libdrm.drmModeModeInfo,
framebuffers: [2]Framebuffer,
display_index: ?usize = null,
render_index: usize = 0,
flip_pending: bool = false,
saved_crtc: ?*libdrm.drmModeCrtc,
is_modeset: bool = false,

pub fn init(allocator: std.mem.Allocator) !Self {
    var device = try Drm.Device.init();
    errdefer device.deinit();
    const fd = device.fd;
    const mode = device.mode;
    const saved_crtc = libdrm.drmModeGetCrtc(fd, device.crtc_id) orelse return error.FailedToSaveCrtc;
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

    return .{
        .allocator = allocator,
        .device = device,
        .fd = fd,
        .mode = mode,
        .framebuffers = framebuffers,
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
    try std.testing.expectEqual(Rect{ .x = 90, .y = 50, .width = 10, .height = 10 }, (Rect{ .x = 90, .y = 50, .width = 30, .height = 20 }).clip(bounds));
    const disjoint = (Rect{ .x = 101, .y = 61, .width = 10, .height = 10 }).clip(bounds);
    try std.testing.expectEqual(@as(u32, 0), disjoint.width);
    try std.testing.expectEqual(@as(u32, 0), disjoint.height);
    const overflowing = (Rect{ .x = 90, .y = 50, .width = std.math.maxInt(u32), .height = std.math.maxInt(u32) }).clip(bounds);
    try std.testing.expectEqual(@as(u32, 10), overflowing.width);
    try std.testing.expectEqual(@as(u32, 10), overflowing.height);
}

pub fn fill_rect(self: *Self, color: u32, rect: Rect) void {
    const framebuffer = self.framebuffers[self.render_index];
    const pixels: [*]u32 = @ptrCast(@alignCast(framebuffer.map));
    const clipped_rect = rect.clip(Rect{
        .x = 0,
        .y = 0,
        .width = self.mode.hdisplay,
        .height = self.mode.vdisplay,
    });

    if (clipped_rect.width == 0 or clipped_rect.height == 0) return;
    for (clipped_rect.y..(clipped_rect.y + clipped_rect.height)) |h| {
        @memset(pixels[framebuffer.stride * h + clipped_rect.x ..][0..clipped_rect.width], color);
    }
}

pub fn clear(self: *Self, color: u32) void {
    const framebuffer = self.framebuffers[self.render_index];
    const pixels: [*]u32 = @ptrCast(@alignCast(framebuffer.map));
    const pixel_count = framebuffer.size / @sizeOf(u32);
    @memset(pixels[0..pixel_count], color);
}

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

fn defaultColors(term: *const ghosttyvt.Terminal) struct { fg: ghosttyvt.color.RGB, bg: ghosttyvt.color.RGB } {
    var fg = term.colors.foreground.get() orelse Colors.foreground;
    var bg = term.colors.background.get() orelse Colors.background;
    // DECSCNM reverses defaults, not explicitly selected ANSI/RGB colors.
    if (term.modes.get(.reverse_colors)) std.mem.swap(ghosttyvt.color.RGB, &fg, &bg);
    return .{ .fg = fg, .bg = bg };
}

fn cellColors(cell: ghosttyvt.Cell, style: ghosttyvt.Style, term: *const ghosttyvt.Terminal) CellColors {
    const defaults = defaultColors(term);
    const palette = &term.colors.palette.current;
    var colors: CellColors = .{
        .fg = rgbPixel(style.fg(.{ .default = defaults.fg, .palette = palette, .bold = .bright })),
        // bg() also handles blank cells that store their background inline.
        .bg = rgbPixel(style.bg(&cell, palette) orelse defaults.bg),
    };
    if (style.flags.inverse) std.mem.swap(u32, &colors.fg, &colors.bg);
    if (style.flags.faint) colors.fg = blendPixel(colors.bg, colors.fg, 128);
    return colors;
}

/// Render one codepoint at a fixed grid origin, clipping overhang to its cells.
fn drawGlyph(self: *Self, font: *Font, codepoint: u21, rect: Rect, color: u32) !void {
    if (codepoint == 0 or codepoint == ' ') return;
    const glyph = try font.glyph(codepoint);
    const clipped = rect.clip(.{ .x = 0, .y = 0, .width = self.mode.hdisplay, .height = self.mode.vdisplay });
    const framebuffer = self.framebuffers[self.render_index];
    const pixels: [*]u32 = @ptrCast(@alignCast(framebuffer.map));

    for (0..glyph.rows) |row| {
        const y = @as(i64, rect.y) + font.ascender - glyph.top + @as(i64, @intCast(row));
        if (y < clipped.y or y >= @as(i64, clipped.y) + clipped.height) continue;
        for (0..glyph.width) |column| {
            const x = @as(i64, rect.x) + glyph.left + @as(i64, @intCast(column));
            if (x < clipped.x or x >= @as(i64, clipped.x) + clipped.width) continue;
            const alpha = glyph.alpha[row * glyph.width + column];
            if (alpha == 0) continue;
            const index = @as(usize, @intCast(y)) * framebuffer.stride + @as(usize, @intCast(x));
            pixels[index] = if (alpha == 255) color else blendPixel(pixels[index], color, alpha);
        }
    }
}

/// Redraw damaged active-screen rows, without presenting. Returns false when
/// the back buffer already matches the terminal and no page flip is needed.
/// The terminal already decoded UTF-8; only the first codepoint of each
/// grapheme is rendered. Shaping, fallback fonts, and cursor blinking are not implemented.
pub fn drawTerminal(self: *Self, font: *Font, term: *ghosttyvt.Terminal) !bool {
    if (self.flip_pending) return error.PageFlipPending;
    const screen = term.screens.active;
    const defaults = defaultColors(term);
    const default_bg = rgbPixel(defaults.bg);
    const key: RenderKey = .{
        .screen = @intFromPtr(screen),
        .cols = screen.pages.cols,
        .width = self.mode.hdisplay,
        .height = self.mode.vdisplay,
        .font = font,
        .cell_width = font.cell_width,
        .cell_height = font.cell_height,
        .ascender = font.ascender,
        .fg = rgbPixel(defaults.fg),
        .bg = default_bg,
    };
    const cursor: CursorState = .{
        .x = screen.cursor.x,
        .y = screen.cursor.y,
        .visible = term.modes.get(.cursor_visible),
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

    // Consume source damage only after recording it for BOTH buffers. Pins
    // and serials detect rows moved/recycled by scrolling without dereferencing
    // any saved page pointer.
    var scan = screen.pages.rowIterator(.right_down, .{ .active = .{} }, null);
    var row_index: usize = 0;
    while (scan.next()) |pin| : (row_index += 1) {
        if (row_index >= self.damage.rows.items.len) break;
        const row = &self.damage.rows.items[row_index];
        const node = @intFromPtr(pin.node);
        if (row.node != node or row.serial != pin.node.serial or row.page_y != pin.y or
            pin.node.page().dirty or pin.rowAndCell().row.dirty) self.damage.mark(row_index);
        row.node = node;
        row.serial = pin.node.serial;
        row.page_y = pin.y;
    }

    const full = self.damage.full[self.render_index];
    var changed = full;
    if (full) self.clear(default_bg);
    var rows = screen.pages.rowIterator(.right_down, .{ .active = .{} }, null);
    var y: u32 = 0;
    row_index = 0;
    var redraw_cursor = false;
    while (rows.next()) |pin| : ({
        y += font.cell_height;
        row_index += 1;
    }) {
        if (y >= self.mode.vdisplay or row_index >= self.damage.rows.items.len) break;
        if (!self.damage.rows.items[row_index].pending[self.render_index]) continue;
        changed = true;
        if (row_index == cursor.y) redraw_cursor = true;
        if (!full) self.fill_rect(default_bg, .{ .x = 0, .y = y, .width = self.mode.hdisplay, .height = font.cell_height });
        const cells = pin.cells(.all);
        // Paint backgrounds first so the trailing spacer never erases a wide glyph.
        for (cells, 0..) |*cell, column| {
            const x = @as(u64, column) * font.cell_width;
            if (x >= self.mode.hdisplay) break;
            const colors = cellColors(cell.*, pin.style(cell), term);
            if (colors.bg != default_bg)
                self.fill_rect(colors.bg, .{ .x = @intCast(x), .y = y, .width = font.cell_width, .height = font.cell_height });
        }
        for (cells, 0..) |*cell, column| {
            const x = @as(u64, column) * font.cell_width;
            if (x >= self.mode.hdisplay) break;
            if (cell.wide == .spacer_head or cell.wide == .spacer_tail) continue;
            if (cell.codepoint() == 0 or cell.codepoint() == ' ') continue;
            const style = pin.style(cell);
            if (style.flags.invisible) continue;
            const colors = cellColors(cell.*, style, term);
            try self.drawGlyph(font, cell.codepoint(), .{
                .x = @intCast(x),
                .y = y,
                .width = font.cell_width *| @as(u32, cell.gridWidth()),
                .height = font.cell_height,
            }, colors.fg);
        }
    }

    if (redraw_cursor) try self.drawCursor(font, term);

    // Keep accumulated damage intact if any drawing operation failed.
    for (self.damage.rows.items) |*row| row.pending[self.render_index] = false;
    self.damage.full[self.render_index] = false;
    self.damage.key = key;
    self.damage.cursor = cursor;
    term.flags.dirty = .{};
    screen.dirty = .{};
    var clean = screen.pages.rowIterator(.right_down, .{ .active = .{} }, null);
    row_index = 0;
    while (clean.next()) |pin| : (row_index += 1) {
        if (row_index >= self.damage.rows.items.len) break;
        pin.rowAndCell().row.dirty = false;
        pin.node.page().dirty = false;
    }
    return changed;
}

fn drawCursor(self: *Self, font: *Font, term: *ghosttyvt.Terminal) !void {
    const screen = term.screens.active;
    if (!term.modes.get(.cursor_visible)) return;
    var cursor_pin = screen.pages.pin(.{ .active = .{ .x = screen.cursor.x, .y = screen.cursor.y } }) orelse return;
    var cell = cursor_pin.rowAndCell().cell;
    // A cursor on the trailing half of a wide glyph covers the whole glyph.
    if (cell.wide == .spacer_tail and cursor_pin.x > 0) {
        cursor_pin.x -= 1;
        cell = cursor_pin.rowAndCell().cell;
    }
    const x = @as(u64, cursor_pin.x) * font.cell_width;
    const cursor_y = @as(u64, screen.cursor.y) * font.cell_height;
    if (x >= self.mode.hdisplay or cursor_y >= self.mode.vdisplay) return;
    const style = cursor_pin.style(cell);
    const colors = cellColors(cell.*, style, term);
    const cursor_color = if (term.colors.cursor.get()) |rgb| rgbPixel(rgb) else colors.fg;
    const rect: Rect = .{
        .x = @intCast(x),
        .y = @intCast(cursor_y),
        .width = font.cell_width *| @as(u32, cell.gridWidth()),
        .height = font.cell_height,
    };
    switch (screen.cursor.cursor_style) {
        .block => {
            self.fill_rect(cursor_color, rect);
            if (!style.flags.invisible) try self.drawGlyph(font, cell.codepoint(), rect, colors.bg);
        },
        .bar => self.fill_rect(cursor_color, .{ .x = rect.x, .y = rect.y, .width = @min(2, rect.width), .height = rect.height }),
        .underline => self.fill_rect(cursor_color, .{ .x = rect.x, .y = rect.y + rect.height - @min(2, rect.height), .width = rect.width, .height = @min(2, rect.height) }),
        .block_hollow => {
            self.fill_rect(cursor_color, .{ .x = rect.x, .y = rect.y, .width = rect.width, .height = 1 });
            self.fill_rect(cursor_color, .{ .x = rect.x, .y = rect.y + rect.height - 1, .width = rect.width, .height = 1 });
            self.fill_rect(cursor_color, .{ .x = rect.x, .y = rect.y, .width = 1, .height = rect.height });
            self.fill_rect(cursor_color, .{ .x = rect.x + rect.width - 1, .y = rect.y, .width = 1, .height = rect.height });
        },
    }
}

/// Rasterize UTF-8 text with FreeType into the current back buffer.
/// `baseline_y` specifies the baseline of the first line in screen pixels.
pub fn drawText(
    self: *Self,
    font_path: [*:0]const u8,
    text: [*:0]const u8,
    pixel_size: u32,
    x: i32,
    baseline_y: i32,
    color: u32,
) !void {
    const framebuffer = self.framebuffers[self.render_index];
    const pixels: [*]u32 = @ptrCast(@alignCast(framebuffer.map));
    const height = self.mode.vdisplay;
    const width = self.mode.hdisplay;
    const stride: u32 = @intCast(framebuffer.stride);

    var library: freetype.FT_Library = undefined;
    var face: freetype.FT_Face = undefined;
    if (freetype.FT_Init_FreeType(&library) != 0) return error.FailedToInitializeFreeType;
    defer _ = freetype.FT_Done_FreeType(library);

    if (freetype.FT_New_Face(library, font_path, 0, &face) != 0) return error.FailedToLoadTypeface;
    defer _ = freetype.FT_Done_Face(face);

    if (freetype.FT_Set_Pixel_Sizes(face, 0, pixel_size) != 0) return error.FailedToSetPixelSizes;

    var pen_x = x;
    var pen_y = baseline_y;

    var utf8_view = std.unicode.Utf8View.init(std.mem.span(text)) catch return error.InvalidUtf8;
    var iter = utf8_view.iterator();

    while (iter.nextCodepoint()) |codepoint| {
        if (codepoint == '\n') {
            pen_x = x;

            pen_y += @as(i32, @intCast(face.*.size.*.metrics.height >> 6));
            continue;
        }

        if (freetype.FT_Load_Char(face, codepoint, freetype.FT_LOAD_RENDER) != 0) {
            return error.GlyphLoadFailed;
        }

        const glyph = face.*.glyph;
        const bitmap = &glyph.*.bitmap;

        var row: u32 = 0;
        while (row < bitmap.*.rows) : (row += 1) {
            const destination_y = pen_y - glyph.*.bitmap_top + @as(i32, @intCast(row));

            if (destination_y < 0 or destination_y >= height) continue;

            var column: u32 = 0;
            while (column < bitmap.*.width) : (column += 1) {
                const destination_x = pen_x + glyph.*.bitmap_left + @as(i32, @intCast(column));

                if (destination_x < 0 or destination_x >= width) continue;

                const buffer_idx = row * @as(u32, @intCast(bitmap.*.pitch)) + column;
                const alpha = bitmap.*.buffer[buffer_idx];

                const dest_idx = @as(u32, @intCast(destination_y)) * stride + @as(u32, @intCast(destination_x));

                pixels[dest_idx] = blendPixel(pixels[dest_idx], color, alpha);
            }
        }

        pen_x += @as(i32, @intCast(glyph.*.advance.x >> 6));
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
            &self.device.connector.connector_id,
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

pub fn deinit(self: *Self) void {
    self.damage.deinit(self.allocator);
    // Normal shell exit already drains flips. Signals and error exits may not.
    if (self.flip_pending) self.finishPendingFlip();
    if (self.is_modeset) self.restoreCrtc();
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
            if (saved_crtc.*.mode_valid != 0) &self.device.connector.connector_id else null,
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

fn testRenderer(pixels: []u32, width: u16, height: u16, stride: usize) Self {
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
        .saved_crtc = null,
    };
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
    defer std.testing.allocator.free(glyph.alpha);
    try std.testing.expectEqualSlices(u8, &.{ 10, 20, 30, 40 }, glyph.alpha);
    source[0] = 50;
    try std.testing.expectEqual(@as(u8, 10), glyph.alpha[0]);
    try std.testing.expectEqual(@as(i32, -1), glyph.left);
    try std.testing.expectEqual(@as(i32, 2), glyph.top);

    bitmap.buffer = source[3..].ptr;
    bitmap.pitch = -3;
    const reversed = try Glyph.copy(std.testing.allocator, bitmap, 0, 0);
    defer std.testing.allocator.free(reversed.alpha);
    try std.testing.expectEqualSlices(u8, &.{ 30, 40, 50, 20 }, reversed.alpha);
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
    defer std.testing.allocator.free(glyph.alpha);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 255, 0, 0, 0, 0, 255, 255 }, glyph.alpha);
    bitmap.pixel_mode = freetype.FT_PIXEL_MODE_BGRA;
    try std.testing.expectError(error.UnsupportedGlyphPixelMode, Glyph.copy(std.testing.allocator, bitmap, 0, 0));
}

test "framebuffer fills clip rectangles and respect padded stride" {
    var pixels = [_]u32{99} ** 12;
    var renderer = testRenderer(&pixels, 3, 3, 4);
    renderer.clear(0x123456);
    try std.testing.expectEqualSlices(u32, &([_]u32{0x123456} ** 12), &pixels);
    renderer.fill_rect(7, .{ .x = 1, .y = 1, .width = 20, .height = 20 });
    try std.testing.expectEqualSlices(u32, &.{ 0x123456, 0x123456, 0x123456, 0x123456, 0x123456, 7, 7, 0x123456, 0x123456, 7, 7, 0x123456 }, &pixels);
    renderer.fill_rect(8, .{ .x = 10, .y = 10, .width = 2, .height = 2 });
    try std.testing.expectEqual(@as(u32, 7), pixels[10]);
}

test "cached glyphs render with backgrounds, reverse colors and transparent pixels" {
    const allocator = std.testing.allocator;
    var font = Font{
        .allocator = allocator,
        // Cache hits must not access the FreeType face or its mutable slot.
        .library = null,
        .face = null,
        .cell_width = 2,
        .cell_height = 1,
        .ascender = 0,
    };
    defer font.glyphs.deinit(allocator);
    const alpha = try allocator.dupe(u8, &.{ 255, 0 });
    defer allocator.free(alpha);
    try font.glyphs.put(allocator, 'A', .{ .alpha = alpha, .width = 2, .rows = 1, .left = 0, .top = 0 });
    const first = try font.glyph('A');
    try std.testing.expect(first == try font.glyph('A'));

    var term = try ghosttyvt.Terminal.init(std.testing.io, allocator, .{ .cols = 3, .rows = 1 });
    defer term.deinit(allocator);
    try Colors.configure(&term, allocator);
    var stream = ghosttyvt.TerminalStream.init(.{ .allocator = allocator, .handler = .init(&term) });
    defer stream.deinit();
    stream.nextSlice("\x1b[?25lA\x1b[41m \x1b[0m");
    var pixels = [_]u32{99} ** 8;
    var renderer = testRenderer(&pixels, 6, 1, 8);
    defer renderer.damage.deinit(renderer.allocator);
    _ = try renderer.drawTerminal(&font, &term);
    const red = rgbPixel(term.colors.palette.current[1]);
    const fg = rgbPixel(Colors.foreground);
    try std.testing.expectEqualSlices(u32, &.{ fg, 0, red, red, 0, 0, 0, 0 }, &pixels);

    stream.nextSlice("\x1b[?5h");
    _ = try renderer.drawTerminal(&font, &term);
    try std.testing.expectEqualSlices(u32, &.{ 0, fg, red, red, fg, fg, fg, fg }, &pixels);
}

fn testFont() Font {
    return .{
        .allocator = std.testing.allocator,
        .library = null,
        .face = null,
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
    try Colors.configure(&term, allocator);
    var stream = ghosttyvt.TerminalStream.init(.{ .allocator = allocator, .handler = .init(&term) });
    defer stream.deinit();
    stream.nextSlice("\x1b[?25l");
    var pixels = [_][24]u32{[_]u32{99} ** 24} ** 2;
    var renderer = testRenderer(&pixels[0], 4, 4, 6);
    renderer.framebuffers[1].map = &pixels[1];
    defer renderer.damage.deinit(allocator);
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
    try Colors.configure(&term, allocator);
    var stream = ghosttyvt.TerminalStream.init(.{ .allocator = allocator, .handler = .init(&term) });
    defer stream.deinit();
    var pixels = [_][24]u32{[_]u32{99} ** 24} ** 2;
    var expected = [_]u32{99} ** 24;
    var renderer = testRenderer(&pixels[0], 4, 4, 6);
    renderer.framebuffers[1].map = &pixels[1];
    defer renderer.damage.deinit(allocator);
    var reference = testRenderer(&expected, 4, 4, 6);
    defer reference.damage.deinit(allocator);
    const updates = [_][]const u8{
        "\x1b[?25l",
        "\x1b[41m \x1b[0m",
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

test "pending flips retain source damage and wide cursor moves erase the old row" {
    const allocator = std.testing.allocator;
    var font = testFont();
    defer font.glyphs.deinit(allocator);
    const alpha = try allocator.dupe(u8, &.{ 255, 128 });
    defer allocator.free(alpha);
    try font.glyphs.put(allocator, '界', .{ .alpha = alpha, .width = 2, .rows = 1, .left = 0, .top = 0 });
    var term = try ghosttyvt.Terminal.init(std.testing.io, allocator, .{ .cols = 3, .rows = 3 });
    defer term.deinit(allocator);
    try Colors.configure(&term, allocator);
    var stream = ghosttyvt.TerminalStream.init(.{ .allocator = allocator, .handler = .init(&term) });
    defer stream.deinit();
    var pixels = [_][9]u32{[_]u32{99} ** 9} ** 2;
    var renderer = testRenderer(&pixels[0], 3, 3, 3);
    renderer.framebuffers[1].map = &pixels[1];
    defer renderer.damage.deinit(allocator);
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
    try std.testing.expectEqualSlices(u32, &.{ fg, blendPixel(0, fg, 128), 0 }, pixels[0][0..3]);
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
    try Colors.configure(&term, allocator);
    var stream = ghosttyvt.TerminalStream.init(.{ .allocator = allocator, .handler = .init(&term) });
    defer stream.deinit();
    var pixels = [_][9]u32{[_]u32{99} ** 9} ** 2;
    var renderer = testRenderer(&pixels[0], 3, 3, 3);
    renderer.framebuffers[1].map = &pixels[1];
    defer renderer.damage.deinit(allocator);
    stream.nextSlice("\x1b[?25l");
    _ = try renderer.drawTerminal(&font, &term);
    renderer.completeFlip();
    _ = try renderer.drawTerminal(&font, &term);
    renderer.completeFlip();
    stream.nextSlice("\x1b[2;1HA");
    // An uncached glyph on this synthetic font has no FreeType face to load.
    try std.testing.expectError(error.GlyphLoadFailed, renderer.drawTerminal(&font, &term));
    try std.testing.expect(renderer.damage.rows.items[1].pending[0]);
    try std.testing.expect(renderer.damage.rows.items[1].pending[1]);
    const pin = term.screens.active.pages.pin(.{ .active = .{ .x = 0, .y = 1 } }).?;
    try std.testing.expect(pin.rowAndCell().row.dirty);
    const alpha = try allocator.dupe(u8, &.{255});
    defer allocator.free(alpha);
    try font.glyphs.put(allocator, 'A', .{ .alpha = alpha, .width = 1, .rows = 1, .left = 0, .top = 0 });
    try std.testing.expect(try renderer.drawTerminal(&font, &term));
    try std.testing.expect(!pin.rowAndCell().row.dirty);
    try std.testing.expectEqual(rgbPixel(Colors.foreground), pixels[0][3]);
    renderer.completeFlip();
    _ = try renderer.drawTerminal(&font, &term);
    try std.testing.expectEqualSlices(u32, &pixels[0], &pixels[1]);
}

test "SGR colors preserve indexed and RGB values and apply intensity and inverse" {
    const allocator = std.testing.allocator;
    var term = try ghosttyvt.Terminal.init(std.testing.io, allocator, .{ .cols = 16, .rows = 1 });
    defer term.deinit(allocator);
    try Colors.configure(&term, allocator);
    var stream = ghosttyvt.TerminalStream.init(.{ .allocator = allocator, .handler = .init(&term) });
    defer stream.deinit();
    stream.nextSlice("\x1b[31mA\x1b[1mB\x1b[22;91mC\x1b[0;38;5;196mD" ++
        "\x1b[38;2;18;52;86;48;2;101;67;33mE\x1b[7mF\x1b[0;2;31mG\x1b[0;44m H");
    const fg = rgbPixel(Colors.foreground);
    const expected = [_]CellColors{
        .{ .fg = 0xCD0000, .bg = 0 },
        .{ .fg = 0xFF0000, .bg = 0 },
        .{ .fg = 0xFF0000, .bg = 0 },
        .{ .fg = 0xFF0000, .bg = 0 },
        .{ .fg = 0x123456, .bg = 0x654321 },
        .{ .fg = 0x654321, .bg = 0x123456 },
        .{ .fg = 0x660000, .bg = 0 },
        .{ .fg = fg, .bg = 0x0000EE },
        .{ .fg = fg, .bg = 0x0000EE },
    };
    for (expected, 0..) |colors, x| {
        const pin = term.screens.active.pages.pin(.{ .active = .{ .x = @intCast(x), .y = 0 } }).?;
        const cell = pin.rowAndCell().cell;
        try std.testing.expectEqual(colors, cellColors(cell.*, pin.style(cell), &term));
    }
    // Reverse-video must not swap explicit foreground/background pairs.
    stream.nextSlice("\x1b[?5h");
    for ([_]u16{ 4, 5 }) |x| {
        const pin = term.screens.active.pages.pin(.{ .active = .{ .x = x, .y = 0 } }).?;
        const cell = pin.rowAndCell().cell;
        try std.testing.expectEqual(expected[x], cellColors(cell.*, pin.style(cell), &term));
    }
    const pin = term.screens.active.pages.pin(.{ .active = .{ .x = 0, .y = 0 } }).?;
    const cell = pin.rowAndCell().cell;
    try std.testing.expectEqual(CellColors{ .fg = 0xCD0000, .bg = fg }, cellColors(cell.*, pin.style(cell), &term));
    // Cached cells must continue to follow application palette updates.
    stream.nextSlice("\x1b]4;1;#123456\x07");
    try std.testing.expectEqual(CellColors{ .fg = 0x123456, .bg = fg }, cellColors(cell.*, pin.style(cell), &term));
}

test "page flip completion releases the old buffer and pending flips prevent drawing" {
    var pixels = [_]u32{0};
    var renderer = testRenderer(&pixels, 1, 1, 1);
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
