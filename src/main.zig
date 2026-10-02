const std = @import("std");

const ghostty_vt = @import("ghostty-vt");
const c = @import("c_graphics");

pub fn main(init: std.process.Init) !void {
    const fd = c.open("/dev/dri/card1", c.O_RDWR | c.O_CLOEXEC);

    if (fd < 0) return error.FailedToOpenDevice;
    defer _ = c.close(fd);

    const res = c.drmModeGetResources(fd) orelse return error.FailedToGetResources;
    defer c.drmModeFreeResources(res);

    var conn: *c.drmModeConnector = undefined;
    var mode: c.drmModeModeInfo = undefined;
    var found_connector = false;

    for (0..@intCast(res.*.count_connectors)) |i| {
        conn = c.drmModeGetConnector(fd, res.*.connectors[i]) orelse continue;
        if (conn.*.connection == c.DRM_MODE_CONNECTED and conn.*.count_modes > 0) {
            mode = conn.*.modes.*;
            found_connector = true;
            break;
        }
        c.drmModeFreeConnector(conn);
    }
    if (!found_connector) return error.NoConnectedDisplay;
    defer c.drmModeFreeConnector(conn);

    const enc = c.drmModeGetEncoder(fd, conn.*.encoder_id) orelse return error.NoEncoder;
    defer c.drmModeFreeEncoder(enc);

    var creq = std.mem.zeroes(c.drm_mode_create_dumb);
    creq.width = mode.hdisplay;
    creq.height = mode.vdisplay;
    creq.bpp = 32;

    if (c.drmIoctl(fd, c.DRM_IOCTL_MODE_CREATE_DUMB, &creq) < 0) {
        return error.FailedToCreateDumbBuffer;
    }

    var fb_id: u32 = 0;

    var handle = [_]u32 {creq.handle, 0, 0, 0};
    var pitches = [_]u32 {creq.pitch, 0, 0, 0};
    var offsets = [_]u32 {0, 0, 0, 0};

    if (c.drmModeAddFB2(
        fd,
        mode.hdisplay,
        mode.vdisplay,
        c.DRM_FORMAT_XRGB8888,
        &handle,
        &pitches,
        &offsets,
        &fb_id,
        0,
    ) != 0) {
        return error.FailedToAddFB;
    }

    var mreq = std.mem.zeroes(c.drm_mode_map_dumb);
    mreq.handle = creq.handle;
    if (c.drmIoctl(fd, c.DRM_IOCTL_MODE_MAP_DUMB, &mreq) < 0) return error.FailedToMapDumbBuffer;

    const offset = @as(c.off_t, @intCast(mreq.offset));
    const map = c.mmap(null, creq.size, c.PROT_READ | c.PROT_WRITE, c.MAP_SHARED, fd, offset);
    if (map == c.MAP_FAILED) return error.MmapFailed;

    const pixels = @as([*]u32, @ptrCast(@alignCast(map)));
    const num_pixels = creq.size / 4;
    for (0..num_pixels) |i| {
        pixels[i] = 0x000000FF;
    }

    const saved_crtc = c.drmModeGetCrtc(fd, enc.*.crtc_id);

    if (c.drmModeSetCrtc(fd, enc.*.crtc_id, fb_id, 0, 0, &conn.*.connector_id, 1, &mode) != 0) {
        return error.FailedToSetCrtc;
    }

    std.debug.print("Rendering to screen for 5 seconds...\n", .{});
    try init.io.sleep(std.Io.Duration.fromSeconds(5), .real);

    if (saved_crtc != null) {
        _ = c.drmModeSetCrtc(
            fd,
            saved_crtc.*.crtc_id,
            saved_crtc.*.buffer_id,
            saved_crtc.*.x,
            saved_crtc.*.y,
            &conn.*.connector_id,
            1,
            &saved_crtc.*.mode,
        );
        c.drmModeFreeCrtc(saved_crtc);
    }
}
