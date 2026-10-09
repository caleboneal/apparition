const std = @import("std");
const c = @import("c_graphics");

const Self = @This();

const Framebuffer = struct {
    id: u32,
    handle: u32,
    map: *anyopaque,
    size: usize,
    stride: usize,
};

fd: c_int,
resources: *c.drmModeRes,
connector: *c.drmModeConnector,
encoder: *c.drmModeEncoder,
mode: c.drmModeModeInfo,
framebuffers: [2]Framebuffer,
display_index: ?usize = null,
render_index: usize = 0,
saved_crtc: ?*c.drmModeCrtc,
is_modeset: bool = false,

pub fn init() !Self {
    const fd = c.open("/dev/dri/card1", c.O_RDWR | c.O_CLOEXEC);
    if (fd < 0) return error.FailedToOpenDevice;
    errdefer _ = c.close(fd);

    const resources = c.drmModeGetResources(fd) orelse return error.FailedToGetResources;
    errdefer c.drmModeFreeResources(resources);

    var connector: ?*c.drmModeConnector = null;
    for (0..@intCast(resources.*.count_connectors)) |i| {
        const candidate = c.drmModeGetConnector(fd, resources.*.connectors[i]) orelse continue;
        if (candidate.*.connection == c.DRM_MODE_CONNECTED and candidate.*.count_modes > 0) {
            connector = candidate;
            break;
        }
        c.drmModeFreeConnector(candidate);
    }
    const selected_connector = connector orelse return error.NoConnectedDisplay;
    errdefer c.drmModeFreeConnector(selected_connector);

    const encoder = c.drmModeGetEncoder(fd, selected_connector.*.encoder_id) orelse return error.NoEncoder;
    errdefer c.drmModeFreeEncoder(encoder);

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
        .saved_crtc = c.drmModeGetCrtc(fd, encoder.*.crtc_id),
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
        for (clipped_rect.x..(clipped_rect.x + clipped_rect.width)) |w| pixels[framebuffer.stride * h + w] = color;
    }
}

pub fn clear(self: *Self, color: u32) void {
    const framebuffer = self.framebuffers[self.render_index];
    const pixels: [*]u32 = @ptrCast(@alignCast(framebuffer.map));
    const pixel_count = framebuffer.size / @sizeOf(u32);
    for (0..pixel_count) |i| pixels[i] = color;
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
    if (c.apparition_draw_text(
        pixels,
        @intCast(framebuffer.stride),
        self.mode.hdisplay,
        self.mode.vdisplay,
        font_path,
        text,
        pixel_size,
        x,
        baseline_y,
        color,
    ) != 0) {
        return error.FailedToRenderText;
    }
}

pub fn present(self: *Self) !void {
    const framebuffer = self.framebuffers[self.render_index];

    if (self.display_index == null) {
        if (c.drmModeSetCrtc(
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
        if (c.drmModePageFlip(
            self.fd,
            self.encoder.*.crtc_id,
            framebuffer.id,
            c.DRM_MODE_PAGE_FLIP_EVENT,
            null,
        ) != 0) {
            return error.FailedToQueuePageFlip;
        }
        if (c.apparition_wait_for_page_flip(self.fd) != 0) {
            return error.FailedToWaitForPageFlip;
        }
    }

    self.display_index = self.render_index;
    self.render_index = (self.render_index + 1) % self.framebuffers.len;
}

pub fn deinit(self: *Self) void {
    if (self.is_modeset) self.restoreCrtc();
    if (self.saved_crtc) |saved_crtc| c.drmModeFreeCrtc(saved_crtc);

    for (self.framebuffers) |framebuffer| destroyFramebuffer(self.fd, framebuffer);
    c.drmModeFreeEncoder(self.encoder);
    c.drmModeFreeConnector(self.connector);
    c.drmModeFreeResources(self.resources);
    _ = c.close(self.fd);
}

fn restoreCrtc(self: *Self) void {
    const saved_crtc = self.saved_crtc orelse return;
    _ = c.drmModeSetCrtc(
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

fn createFramebuffer(fd: c_int, mode: c.drmModeModeInfo) !Framebuffer {
    var create_request = std.mem.zeroes(c.drm_mode_create_dumb);
    create_request.width = mode.hdisplay;
    create_request.height = mode.vdisplay;
    create_request.bpp = 32;
    if (c.drmIoctl(fd, c.DRM_IOCTL_MODE_CREATE_DUMB, &create_request) < 0) {
        return error.FailedToCreateDumbBuffer;
    }
    errdefer destroyDumbBuffer(fd, create_request.handle);

    var framebuffer_id: u32 = 0;
    var handles = [_]u32{ create_request.handle, 0, 0, 0 };
    var pitches = [_]u32{ create_request.pitch, 0, 0, 0 };
    var offsets = [_]u32{ 0, 0, 0, 0 };
    if (c.drmModeAddFB2(
        fd,
        mode.hdisplay,
        mode.vdisplay,
        c.DRM_FORMAT_XRGB8888,
        &handles,
        &pitches,
        &offsets,
        &framebuffer_id,
        0,
    ) != 0) {
        return error.FailedToAddFB;
    }
    errdefer _ = c.drmModeRmFB(fd, framebuffer_id);

    var map_request = std.mem.zeroes(c.drm_mode_map_dumb);
    map_request.handle = create_request.handle;
    if (c.drmIoctl(fd, c.DRM_IOCTL_MODE_MAP_DUMB, &map_request) < 0) {
        return error.FailedToMapDumbBuffer;
    }

    const offset = @as(c.off_t, @intCast(map_request.offset));
    const map = c.mmap(null, create_request.size, c.PROT_READ | c.PROT_WRITE, c.MAP_SHARED, fd, offset);
    if (map == c.MAP_FAILED) return error.MmapFailed;
    const mapped_memory: *anyopaque = @ptrCast(map);
    errdefer _ = c.munmap(mapped_memory, @intCast(create_request.size));

    return .{
        .id = framebuffer_id,
        .handle = create_request.handle,
        .map = mapped_memory,
        .size = @intCast(create_request.size),
        .stride = create_request.pitch / @sizeOf(u32),
    };
}

fn destroyFramebuffer(fd: c_int, framebuffer: Framebuffer) void {
    _ = c.munmap(framebuffer.map, framebuffer.size);
    _ = c.drmModeRmFB(fd, framebuffer.id);
    destroyDumbBuffer(fd, framebuffer.handle);
}

fn destroyDumbBuffer(fd: c_int, handle: u32) void {
    var destroy_request = std.mem.zeroes(c.drm_mode_destroy_dumb);
    destroy_request.handle = handle;
    _ = c.drmIoctl(fd, c.DRM_IOCTL_MODE_DESTROY_DUMB, &destroy_request);
}
