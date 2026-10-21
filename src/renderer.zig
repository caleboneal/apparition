const std = @import("std");
const linux = std.os.linux;

const libdrm = @import("libdrm");
const freetype = @import("freetype");
const ghosttyvt = @import("ghostty-vt");

const Self = @This();

/// Owns a reusable FreeType face. Cell dimensions are in pixels (u32).
/// Not thread-safe: loading a glyph mutates the face's glyph slot.
pub const Font = struct {
    library: freetype.FT_Library,
    face: freetype.FT_Face,
    cell_width: u32,
    cell_height: u32,
    ascender: i32,

    pub fn init(font_path: [*:0]const u8, pixel_size: u32) !Font {
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
            .library = library,
            .face = face,
            .cell_width = @intCast(width),
            .cell_height = @intCast(height),
            .ascender = @intCast(ascender),
        };
    }

    pub fn deinit(self: *Font) void {
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

fd: c_int,
resources: *libdrm.drmModeRes,
connector: *libdrm.drmModeConnector,
encoder: *libdrm.drmModeEncoder,
mode: libdrm.drmModeModeInfo,
framebuffers: [2]Framebuffer,
display_index: ?usize = null,
render_index: usize = 0,
saved_crtc: ?*libdrm.drmModeCrtc,
is_modeset: bool = false,

pub fn init() !Self {
    const fd: c_int = @intCast(linux.open(
        "/dev/dri/card0",
        .{ .ACCMODE = .RDWR, .CLOEXEC = true },
        0,
    ));
    if (fd < 0) return error.FailedToOpenDevice;
    errdefer _ = linux.close(fd);

    const resources = libdrm.drmModeGetResources(fd) orelse return error.FailedToGetResources;
    errdefer libdrm.drmModeFreeResources(resources);

    var connector: ?*libdrm.drmModeConnector = null;
    for (0..@intCast(resources.*.count_connectors)) |i| {
        const candidate = libdrm.drmModeGetConnector(fd, resources.*.connectors[i]) orelse continue;
        if (candidate.*.connection == libdrm.DRM_MODE_CONNECTED and candidate.*.count_modes > 0) {
            connector = candidate;
            break;
        }
        libdrm.drmModeFreeConnector(candidate);
    }
    const selected_connector = connector orelse return error.NoConnectedDisplay;
    errdefer libdrm.drmModeFreeConnector(selected_connector);

    const encoder = libdrm.drmModeGetEncoder(
        fd,
        selected_connector.*.encoder_id,
    ) orelse return error.NoEncoder;
    errdefer libdrm.drmModeFreeEncoder(encoder);

    const mode = selected_connector.*.modes.*;
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
        .fd = fd,
        .resources = resources,
        .connector = selected_connector,
        .encoder = encoder,
        .mode = mode,
        .framebuffers = framebuffers,
        .saved_crtc = libdrm.drmModeGetCrtc(fd, encoder.*.crtc_id),
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

    for (clipped_rect.y..(clipped_rect.y + clipped_rect.height)) |h| {
        for (clipped_rect.x..(clipped_rect.x + clipped_rect.width)) |w| {
            pixels[framebuffer.stride * h + w] = color;
        }
    }
}

pub fn clear(self: *Self, color: u32) void {
    const framebuffer = self.framebuffers[self.render_index];
    const pixels: [*]u32 = @ptrCast(@alignCast(framebuffer.map));
    const pixel_count = framebuffer.size / @sizeOf(u32);
    for (0..pixel_count) |i| pixels[i] = color;
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

fn resolveColor(color: ghosttyvt.Style.Color, fallback: u32, term: *const ghosttyvt.Terminal) u32 {
    return switch (color) {
        .none => fallback,
        .palette => |index| rgbPixel(term.colors.palette.current[index]),
        .rgb => |rgb| rgbPixel(rgb),
    };
}

const CellColors = struct { fg: u32, bg: u32 };

fn cellColors(cell: ghosttyvt.Cell, style: ghosttyvt.Style, term: *const ghosttyvt.Terminal) CellColors {
    var colors: CellColors = .{
        .fg = resolveColor(style.fg_color, if (term.colors.foreground.get()) |rgb| rgbPixel(rgb) else 0xFFFFFF, term),
        .bg = resolveColor(style.bg_color, if (term.colors.background.get()) |rgb| rgbPixel(rgb) else 0x000000, term),
    };
    // Blank backgrounds may be stored directly in the cell, without a style.
    switch (cell.content_tag) {
        .bg_color_palette => colors.bg = rgbPixel(term.colors.palette.current[cell.content.color_palette.data]),
        .bg_color_rgb => {
            const rgb = cell.content.color_rgb;
            colors.bg = (@as(u32, rgb.r) << 16) | (@as(u32, rgb.g) << 8) | rgb.b;
        },
        else => {},
    }
    if (style.flags.inverse != term.modes.get(.reverse_colors)) std.mem.swap(u32, &colors.fg, &colors.bg);
    return colors;
}

/// Render one codepoint at a fixed grid origin, clipping overhang to its cells.
fn drawGlyph(self: *Self, font: *Font, codepoint: u21, rect: Rect, color: u32) !void {
    if (codepoint == 0 or codepoint == ' ') return;
    if (freetype.FT_Load_Char(font.face, codepoint, freetype.FT_LOAD_RENDER | freetype.FT_LOAD_TARGET_NORMAL) != 0) {
        return error.GlyphLoadFailed;
    }
    const glyph = font.face.*.glyph;
    const bitmap = &glyph.*.bitmap;
    const clipped = rect.clip(.{ .x = 0, .y = 0, .width = self.mode.hdisplay, .height = self.mode.vdisplay });
    const framebuffer = self.framebuffers[self.render_index];
    const pixels: [*]u32 = @ptrCast(@alignCast(framebuffer.map));

    for (0..bitmap.*.rows) |row| {
        const y = @as(i64, rect.y) + font.ascender - glyph.*.bitmap_top + @as(i64, @intCast(row));
        if (y < clipped.y or y >= @as(i64, clipped.y) + clipped.height) continue;
        // Pitch is the signed offset to the next logical row.
        const row_address = @as(i128, @intCast(@intFromPtr(bitmap.*.buffer))) + @as(i128, @intCast(row)) * bitmap.*.pitch;
        const source: [*]const u8 = @ptrFromInt(@as(usize, @intCast(row_address)));
        for (0..bitmap.*.width) |column| {
            const x = @as(i64, rect.x) + glyph.*.bitmap_left + @as(i64, @intCast(column));
            if (x < clipped.x or x >= @as(i64, clipped.x) + clipped.width) continue;
            const alpha: u8 = switch (bitmap.*.pixel_mode) {
                freetype.FT_PIXEL_MODE_GRAY => source[column],
                freetype.FT_PIXEL_MODE_MONO => if (source[column / 8] & (@as(u8, 0x80) >> @as(u3, @intCast(column % 8))) != 0) 255 else 0,
                else => return error.UnsupportedGlyphPixelMode,
            };
            const index = @as(usize, @intCast(y)) * framebuffer.stride + @as(usize, @intCast(x));
            pixels[index] = blendPixel(pixels[index], color, alpha);
        }
    }
}

/// Full redraw of the active screen (not scrollback), without presenting it.
/// The terminal already decoded UTF-8; only the first codepoint of each
/// grapheme is rendered. Shaping, fallback fonts, and cursor blinking are not implemented.
pub fn drawTerminal(self: *Self, font: *Font, term: *ghosttyvt.Terminal) !void {
    const screen = term.screens.active;
    const default_bg = if (term.modes.get(.reverse_colors))
        (if (term.colors.foreground.get()) |rgb| rgbPixel(rgb) else 0xFFFFFF)
    else
        (if (term.colors.background.get()) |rgb| rgbPixel(rgb) else 0x000000);
    self.clear(default_bg);

    var rows = screen.pages.rowIterator(.right_down, .{ .active = .{} }, null);
    var y: u32 = 0;
    while (rows.next()) |pin| : (y += font.cell_height) {
        if (y >= self.mode.vdisplay) break;
        const cells = pin.cells(.all);
        // Paint backgrounds first so the trailing spacer never erases a wide glyph.
        for (cells, 0..) |*cell, column| {
            const x = @as(u64, column) * font.cell_width;
            if (x >= self.mode.hdisplay) break;
            const colors = cellColors(cell.*, pin.style(cell), term);
            self.fill_rect(colors.bg, .{ .x = @intCast(x), .y = y, .width = font.cell_width, .height = font.cell_height });
        }
        for (cells, 0..) |*cell, column| {
            const x = @as(u64, column) * font.cell_width;
            if (x >= self.mode.hdisplay) break;
            if (cell.wide == .spacer_head or cell.wide == .spacer_tail) continue;
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

pub fn present(self: *Self) !void {
    const framebuffer = self.framebuffers[self.render_index];

    if (self.display_index == null) {
        if (libdrm.drmModeSetCrtc(
            self.fd,
            self.encoder.*.crtc_id,
            framebuffer.id,
            0,
            0,
            &self.connector.*.connector_id,
            1,
            &self.mode,
        ) != 0) {
            return error.FailedToSetCrtc;
        }
        self.is_modeset = true;
    } else {
        if (libdrm.drmModePageFlip(
            self.fd,
            self.encoder.*.crtc_id,
            framebuffer.id,
            libdrm.DRM_MODE_PAGE_FLIP_EVENT,
            null,
        ) != 0) {
            return error.FailedToQueuePageFlip;
        }
        if (wait_for_page_flip(self.fd) != 0) {
            return error.FailedToWaitForPageFlip;
        }
    }

    self.display_index = self.render_index;
    self.render_index = (self.render_index + 1) % self.framebuffers.len;
}

fn wait_for_page_flip(fd: c_int) i32 {
    var event_context = std.mem.zeroes(libdrm.drmEventContext);
    event_context.version = libdrm.DRM_EVENT_CONTEXT_VERSION;
    event_context.page_flip_handler = &page_flip_handler;
    return @intCast(libdrm.drmHandleEvent(fd, &event_context));
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
    _ = user_data;
}

pub fn deinit(self: *Self) void {
    if (self.is_modeset) self.restoreCrtc();
    if (self.saved_crtc) |saved_crtc| libdrm.drmModeFreeCrtc(saved_crtc);

    for (self.framebuffers) |framebuffer| destroyFramebuffer(self.fd, framebuffer);
    libdrm.drmModeFreeEncoder(self.encoder);
    libdrm.drmModeFreeConnector(self.connector);
    libdrm.drmModeFreeResources(self.resources);
    _ = linux.close(self.fd);
}

fn restoreCrtc(self: *Self) void {
    const saved_crtc = self.saved_crtc orelse return;
    _ = libdrm.drmModeSetCrtc(
        self.fd,
        saved_crtc.*.crtc_id,
        saved_crtc.*.buffer_id,
        saved_crtc.*.x,
        saved_crtc.*.y,
        &self.connector.*.connector_id,
        1,
        &saved_crtc.*.mode,
    );
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
    if (map == std.math.maxInt(usize)) return error.MmapFailed;
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
