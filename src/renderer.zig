const std = @import("std");
const linux = std.os.linux;

const libdrm = @import("libdrm");
const freetype = @import("freetype");

const Self = @This();

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
    const fd = linux.open("/dev/dri/card1", .{ .ACCMODE = .RDWR, .CLOEXEC = true });
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
        return .{
            .x = @max(self.x, rect.x),
            .y = @max(self.y, rect.y),
            .width = @min(self.width, rect.width),
            .height = @min(self.height, rect.height),
        };
    }
};

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
    const inverse_alpha = 256 - alpha;
    const red = (((fg >> 16) ^ 0xFF) * alpha + ((bg >> 16) & 0xFF) * inverse_alpha) / 255;
    const green = (((fg >> 8) ^ 0xFF) * alpha + ((bg >> 8) & 0xFF) * inverse_alpha) / 255;
    const blue = ((fg ^ 0xFF) * alpha + (bg & 0xFF) * inverse_alpha) / 255;
    return (red << 16) | (green << 8) | blue;
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
    const face: freetype.FT_Face = undefined;
    if (freetype.FT_Init_FreeType(&library) != 0) return error.FailedToInitializeFreeType;
    defer freetype.FT_Done_FreeType(library);

    if (freetype.FT_New_Face(library, font_path, 0, &face) != 0) return error.FailedToLoadTypeface;
    defer freetype.FT_Done_Face(face);

    if (freetype.FT_Set_Pixel_Sizes(face, 0, pixel_size) != 0) return error.FailedToSetPixelSizes;

    var pen_x = x;
    var pen_y = baseline_y;

    var utf8_view = std.unicode.Utf8View.init(text) orelse return error.InvalidUtf8;
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
    user_data: *anyopaque,
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
        linux.MAP_TYPE.SHARED,
        fd,
        offset,
    );
    if (map == std.c.MAP_FAILED) return error.MmapFailed;
    const mapped_memory: *anyopaque = @ptrCast(map);
    errdefer _ = linux.munmap(mapped_memory, @intCast(create_request.size));

    return .{
        .id = framebuffer_id,
        .handle = create_request.handle,
        .map = mapped_memory,
        .size = @intCast(create_request.size),
        .stride = create_request.pitch / @sizeOf(u32),
    };
}

fn destroyFramebuffer(fd: c_int, framebuffer: Framebuffer) void {
    _ = linux.munmap(framebuffer.map, framebuffer.size);
    _ = libdrm.drmModeRmFB(fd, framebuffer.id);
    destroyDumbBuffer(fd, framebuffer.handle);
}

fn destroyDumbBuffer(fd: c_int, handle: u32) void {
    var destroy_request = std.mem.zeroes(libdrm.drm_mode_destroy_dumb);
    destroy_request.handle = handle;
    _ = libdrm.drmIoctl(fd, libdrm.DRM_IOCTL_MODE_DESTROY_DUMB, &destroy_request);
}
