const std = @import("std");
const linux = std.os.linux;
const libdrm = @import("libdrm");
const log = std.log.scoped(.drm);

/// Owns the primary-node fd, DRM master, and the three libdrm allocations.
/// Discovery does not modeset. The caller must use crtc_id (not encoder.crtc_id),
/// and restore any modeset / release framebuffers before calling deinit.
/// Treat this as move-only; deinit must be called exactly once after success.
pub const Device = struct {
    fd: c_int,
    resources: *libdrm.drmModeRes,
    connector: *libdrm.drmModeConnector,
    encoder: *libdrm.drmModeEncoder,
    mode: libdrm.drmModeModeInfo,
    crtc_id: u32,

    pub fn init() !Device {
        const capacity = libdrm.drmGetDevices2(0, null, 0);
        if (capacity < 0) {
            log.err("DRM enumeration failed: libdrm returned {d}", .{capacity});
            return error.DrmEnumerationFailed;
        }
        if (capacity == 0) return error.NoDrmDevices;

        const devices = try std.heap.page_allocator.alloc(libdrm.drmDevicePtr, @intCast(capacity));
        defer std.heap.page_allocator.free(devices);
        @memset(devices, null);
        // libdrm 2.4.134 publishes output entries only on success; failures
        // leave ownership inside libdrm. Free exactly the successful count.
        const count = libdrm.drmGetDevices2(0, devices.ptr, capacity);
        if (count < 0) {
            log.err("DRM enumeration failed: libdrm returned {d}", .{count});
            return error.DrmEnumerationFailed;
        }

        defer libdrm.drmFreeDevices(devices.ptr, count);

        for (devices[0..@intCast(count)]) |device| {
            if (device == null) continue;
            if (device.*.available_nodes & (@as(c_int, 1) << libdrm.DRM_NODE_PRIMARY) == 0) {
                log.debug("Skipping DRM device without a primary node", .{});
                continue;
            }
            if (device.*.nodes == null or device.*.nodes[libdrm.DRM_NODE_PRIMARY] == null) continue;
            const path: [*:0]const u8 = @ptrCast(device.*.nodes[libdrm.DRM_NODE_PRIMARY]);
            return openCandidate(path) catch |err| {
                log.warn("Skipping {s}: {s}", .{ path, @errorName(err) });
                continue;
            };
        }
        log.err("No primary DRM node has master access, dumb buffers, and a usable connected output", .{});
        return error.NoUsableDrmDevice;
    }

    pub fn deinit(self: *Device) void {
        libdrm.drmModeFreeEncoder(self.encoder);
        libdrm.drmModeFreeConnector(self.connector);
        libdrm.drmModeFreeResources(self.resources);
        if (libdrm.drmDropMaster(self.fd) != 0)
            log.warn("Failed to drop DRM master on fd {d}: errno {d}", .{ self.fd, std.c._errno().* });
        _ = linux.close(self.fd);
        self.* = undefined;
    }
};

fn openCandidate(path: [*:0]const u8) !Device {
    const result = linux.open(path, .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0);
    const err = linux.errno(result);
    if (err != .SUCCESS) {
        log.warn("Cannot open {s}: {s} ({d})", .{ path, @tagName(err), @intFromEnum(err) });
        return error.DrmOpenFailed;
    }
    // Raw Linux syscall errors are unsigned -errno, so check before narrowing.
    const fd: c_int = @intCast(result);
    errdefer _ = linux.close(fd);

    if (libdrm.drmIsMaster(fd) != 1) {
        if (libdrm.drmSetMaster(fd) != 0) {
            log.warn("Cannot acquire DRM master on {s}: errno {d} (is another compositor running?)", .{ path, std.c._errno().* });
            return error.DrmMasterUnavailable;
        }
    }
    if (libdrm.drmIsMaster(fd) != 1) return error.DrmMasterUnavailable;
    errdefer _ = libdrm.drmDropMaster(fd);

    const resources: *libdrm.drmModeRes = libdrm.drmModeGetResources(fd) orelse {
        log.warn("Cannot get KMS resources on {s}: errno {d}", .{ path, std.c._errno().* });
        return error.NoKmsResources;
    };
    errdefer libdrm.drmModeFreeResources(resources);
    if (drmSlice(u32, resources.crtcs, resources.count_crtcs).len == 0 or
        drmSlice(u32, resources.connectors, resources.count_connectors).len == 0 or
        drmSlice(u32, resources.encoders, resources.count_encoders).len == 0)
        return error.NoKmsResources;

    var dumb: u64 = 0;
    const cap_result = libdrm.drmGetCap(fd, libdrm.DRM_CAP_DUMB_BUFFER, &dumb);
    if (cap_result != 0) {
        log.warn("Cannot query dumb-buffer support on {s}: errno {d}", .{ path, std.c._errno().* });
        return error.DumbBuffersUnavailable;
    }
    if (dumb == 0) return error.DumbBuffersUnavailable;

    const selection = try selectDisplay(fd, resources);
    log.info("Selected {s}: connector {d}, encoder {d}, CRTC {d}, {d}x{d}", .{
        path,              selection.connector.connector_id, selection.encoder.encoder_id,
        selection.crtc_id, selection.mode.hdisplay,          selection.mode.vdisplay,
    });
    return .{
        .fd = fd,
        .resources = resources,
        .connector = selection.connector,
        .encoder = selection.encoder,
        .mode = selection.mode,
        .crtc_id = selection.crtc_id,
    };
}

fn drmSlice(comptime T: type, pointer: [*c]T, count: c_int) []const T {
    if (count <= 0 or pointer == null) return &.{};
    return pointer[0..@intCast(count)];
}

const Route = struct {
    connector_id: u32 = 0,
    encoder_id: u32 = 0,
    crtc_id: u32 = 0,
    known: bool = true,
};

const Output = struct {
    connector: ?*libdrm.drmModeConnector = null,
    encoder: ?*libdrm.drmModeEncoder = null,
    mode: ?libdrm.drmModeModeInfo = null,
    route: Route = .{},

    fn deinit(self: *Output) void {
        if (self.encoder) |encoder| libdrm.drmModeFreeEncoder(encoder);
        if (self.connector) |connector| libdrm.drmModeFreeConnector(connector);
    }
};

const Selection = struct {
    connector: *libdrm.drmModeConnector,
    encoder: *libdrm.drmModeEncoder,
    mode: libdrm.drmModeModeInfo,
    crtc_id: u32,
};

fn selectDisplay(fd: c_int, resources: *const libdrm.drmModeRes) !Selection {
    const connector_ids = drmSlice(u32, resources.connectors, resources.count_connectors);
    const crtcs = drmSlice(u32, resources.crtcs, resources.count_crtcs);
    const outputs = try std.heap.page_allocator.alloc(Output, connector_ids.len);
    defer std.heap.page_allocator.free(outputs);
    @memset(outputs, .{});
    defer for (outputs) |*output| output.deinit();

    // Snapshot all connected routes, even outputs without modes, so selecting a
    // disabled output does not unknowingly steal another monitor's CRTC/encoder.
    for (connector_ids, outputs) |id, *output| {
        output.route.connector_id = id;
        const connector: *libdrm.drmModeConnector = libdrm.drmModeGetConnector(fd, id) orelse {
            log.warn("Cannot inspect connector {d}: errno {d}", .{ id, std.c._errno().* });
            output.route.known = false;
            continue;
        };
        if (connector.connection != libdrm.DRM_MODE_CONNECTED) {
            libdrm.drmModeFreeConnector(connector);
            continue;
        }
        output.connector = connector;
        output.mode = selectMode(drmSlice(libdrm.drmModeModeInfo, connector.modes, connector.count_modes));
        output.route.encoder_id = connector.encoder_id;
        if (connector.encoder_id != 0) {
            output.encoder = libdrm.drmModeGetEncoder(fd, connector.encoder_id);
            if (output.encoder) |encoder| {
                output.route.crtc_id = encoder.crtc_id;
            } else {
                log.warn("Cannot inspect current encoder {d}: errno {d}", .{ connector.encoder_id, std.c._errno().* });
                output.route.known = false;
            }
        }
    }

    // Prefer an existing exclusive route, then enable previously disabled
    // outputs. Never reroute an enabled connector: the renderer saves only
    // the selected CRTC, not the connector's original routing.
    for ([_]bool{ true, false }) |current_only| {
        for (outputs) |*output| {
            if (!outputEligible(output, current_only)) continue;
            const connector = output.connector.?;
            if (output.encoder) |encoder| {
                if (chooseOutputCrtc(output, encoder, crtcs, outputs, current_only)) |crtc_id|
                    return takeSelection(output, encoder, crtc_id);
            }
            if (current_only) continue;
            for (drmSlice(u32, connector.encoders, connector.count_encoders)) |encoder_id| {
                if (encoder_id == 0) continue;
                if (output.encoder != null and encoder_id == connector.encoder_id) continue;
                const encoder: *libdrm.drmModeEncoder = libdrm.drmModeGetEncoder(fd, encoder_id) orelse {
                    log.warn("Cannot inspect encoder {d} for connector {d}: errno {d}", .{ encoder_id, connector.connector_id, std.c._errno().* });
                    continue;
                };
                if (chooseOutputCrtc(output, encoder, crtcs, outputs, current_only)) |crtc_id|
                    return takeSelection(output, encoder, crtc_id);
                libdrm.drmModeFreeEncoder(encoder);
            }
        }
    }
    return error.NoUsableConnectedOutput;
}

fn outputEligible(output: *const Output, current_only: bool) bool {
    return output.connector != null and output.mode != null and output.route.known and
        (if (current_only) output.route.crtc_id != 0 else output.route.crtc_id == 0);
}

fn chooseOutputCrtc(output: *const Output, encoder: *const libdrm.drmModeEncoder, crtcs: []const u32, outputs: []const Output, current_only: bool) ?u32 {
    if (!outputEligible(output, current_only)) return null;
    if (current_only and (encoder.encoder_id != output.route.encoder_id or encoder.crtc_id != output.route.crtc_id)) return null;
    const crtc_id = chooseCrtc(crtcs, encoder.possible_crtcs, encoder.crtc_id, output.route.connector_id, encoder.encoder_id, outputs) orelse return null;
    if (current_only and crtc_id != output.route.crtc_id) return null;
    return crtc_id;
}

fn takeSelection(output: *Output, encoder: *libdrm.drmModeEncoder, crtc_id: u32) Selection {
    const selection: Selection = .{
        .connector = output.connector.?,
        .encoder = encoder,
        .mode = output.mode.?,
        .crtc_id = crtc_id,
    };

    output.connector = null;
    if (output.encoder == encoder) output.encoder = null;
    return selection;
}

fn crtcSupported(possible: u32, index: usize) bool {
    // possible_crtcs bits refer to resource-array indices, never object IDs.
    return index < @bitSizeOf(u32) and possible & (@as(u32, 1) << @as(u5, @intCast(index))) != 0;
}

fn routeConflicts(crtc_id: u32, encoder_id: u32, connector_id: u32, outputs: []const Output) bool {
    for (outputs) |output| {
        const route = output.route;
        if (route.connector_id == connector_id) continue;
        // Unknown routes are conservatively reserved; exclusivity is required.
        if (!route.known or route.crtc_id == crtc_id or (route.encoder_id != 0 and route.encoder_id == encoder_id)) return true;
    }
    return false;
}

fn chooseCrtc(crtcs: []const u32, possible: u32, current: u32, connector_id: u32, encoder_id: u32, outputs: []const Output) ?u32 {
    if (current != 0) {
        for (crtcs, 0..) |id, index| {
            if (id == current and crtcSupported(possible, index) and
                !routeConflicts(id, encoder_id, connector_id, outputs)) return id;
        }
    }
    for (crtcs, 0..) |id, index| {
        if (id != 0 and crtcSupported(possible, index) and
            !routeConflicts(id, encoder_id, connector_id, outputs)) return id;
    }
    return null;
}

fn validMode(mode: libdrm.drmModeModeInfo) bool {
    return mode.clock != 0 and mode.hdisplay != 0 and mode.vdisplay != 0 and
        mode.hdisplay <= mode.hsync_start and mode.hsync_start <= mode.hsync_end and mode.hsync_end <= mode.htotal and
        mode.vdisplay <= mode.vsync_start and mode.vsync_start <= mode.vsync_end and mode.vsync_end <= mode.vtotal;
}

fn selectMode(modes: []const libdrm.drmModeModeInfo) ?libdrm.drmModeModeInfo {
    var first: ?libdrm.drmModeModeInfo = null;
    for (modes) |mode| {
        if (!validMode(mode)) continue;
        if (first == null) first = mode;
        if (mode.type & libdrm.DRM_MODE_TYPE_PREFERRED != 0) return mode;
    }
    return first;
}

test "CRTC masks use indices and safely handle the 32-bit boundary" {
    try std.testing.expect(crtcSupported(1, 0));
    try std.testing.expect(!crtcSupported(1, 1));
    try std.testing.expect(crtcSupported(0x80000000, 31));
    try std.testing.expect(!crtcSupported(0xffffffff, 32));
    try std.testing.expect(!crtcSupported(0xffffffff, std.math.maxInt(usize)));
    try std.testing.expectEqual(@as(?u32, 91), chooseCrtc(&.{ 47, 91 }, 2, 0, 10, 20, &.{}));
    try std.testing.expectEqual(@as(?u32, null), chooseCrtc(&.{ 47, 91 }, 4, 0, 10, 20, &.{}));
}

test "CRTC selection preserves compatible current routes and enables disabled outputs" {
    const crtcs = [_]u32{ 47, 91 };
    try std.testing.expectEqual(@as(?u32, 91), chooseCrtc(&crtcs, 3, 91, 10, 20, &.{}));
    try std.testing.expectEqual(@as(?u32, 47), chooseCrtc(&crtcs, 1, 91, 10, 20, &.{}));
    try std.testing.expectEqual(@as(?u32, 47), chooseCrtc(&crtcs, 3, 0, 10, 20, &.{}));
    try std.testing.expectEqual(@as(?u32, 47), chooseCrtc(&crtcs, 3, 999, 10, 20, &.{}));
    try std.testing.expectEqual(@as(?u32, null), chooseCrtc(&crtcs, 0, 47, 10, 20, &.{}));
    try std.testing.expectEqual(@as(?u32, null), chooseCrtc(&.{}, 3, 47, 10, 20, &.{}));
    try std.testing.expectEqual(@as(?u32, null), chooseCrtc(&.{0}, 1, 0, 10, 20, &.{}));
}

test "selection never steals another connected output's CRTC or encoder" {
    const outputs = [_]Output{
        .{ .route = .{ .connector_id = 10, .encoder_id = 20, .crtc_id = 47 } },
        .{ .route = .{ .connector_id = 11, .encoder_id = 21, .crtc_id = 91 } },
    };
    try std.testing.expectEqual(@as(?u32, 47), chooseCrtc(&.{ 47, 91 }, 3, 91, 10, 20, &outputs));
    try std.testing.expectEqual(@as(?u32, null), chooseCrtc(&.{ 47, 91 }, 2, 0, 10, 20, &outputs));
    // All CRTCs are occupied by other connectors, including the current CRTC.
    try std.testing.expectEqual(@as(?u32, null), chooseCrtc(&.{ 47, 91 }, 3, 47, 12, 22, &outputs));
    try std.testing.expectEqual(@as(?u32, null), chooseCrtc(&.{ 47, 91 }, 3, 0, 12, 22, &outputs));
    // A free CRTC cannot safely be driven by another output's occupied encoder.
    try std.testing.expectEqual(@as(?u32, null), chooseCrtc(&.{ 47, 91, 99 }, 4, 0, 10, 21, &outputs));
    try std.testing.expectEqual(@as(?u32, 99), chooseCrtc(&.{ 47, 91, 99 }, 7, 91, 12, 22, &outputs));
    // Even the selected connector's current route is unsafe if it is cloned.
    const cloned = [_]Output{
        outputs[0],
        .{ .route = .{ .connector_id = 11, .encoder_id = 21, .crtc_id = 47 } },
    };
    try std.testing.expectEqual(@as(?u32, null), chooseCrtc(&.{47}, 1, 47, 10, 20, &cloned));
}

test "unknown routes prevent exclusive selection without logging errors" {
    const unknown = [_]Output{.{ .route = .{ .connector_id = 11, .known = false } }};
    try std.testing.expectEqual(@as(?u32, null), chooseCrtc(&.{47}, 1, 0, 10, 20, &unknown));
    try std.testing.expectEqual(@as(?u32, null), chooseCrtc(&.{47}, 1, 47, 10, 20, &unknown));
}

test "enabled connector selection permits only its compatible current encoder and CRTC" {
    var connector: libdrm.drmModeConnector = .{ .connector_id = 10, .connection = libdrm.DRM_MODE_CONNECTED };
    var encoder: libdrm.drmModeEncoder = .{ .encoder_id = 20, .crtc_id = 47, .possible_crtcs = 3 };
    const outputs = [_]Output{.{
        .connector = &connector,
        .encoder = &encoder,
        .mode = testMode(1024, false),
        .route = .{ .connector_id = 10, .encoder_id = 20, .crtc_id = 47 },
    }};
    const output = &outputs[0];
    try std.testing.expectEqual(@as(?u32, 47), chooseOutputCrtc(output, &encoder, &.{ 47, 91 }, &outputs, true));
    try std.testing.expect(!outputEligible(output, false));
    try std.testing.expectEqual(@as(?u32, null), chooseOutputCrtc(output, &encoder, &.{ 47, 91 }, &outputs, false));

    const alternate: libdrm.drmModeEncoder = .{ .encoder_id = 21, .crtc_id = 91, .possible_crtcs = 3 };
    try std.testing.expectEqual(@as(?u32, null), chooseOutputCrtc(output, &alternate, &.{ 47, 91 }, &outputs, true));
    try std.testing.expectEqual(@as(?u32, null), chooseOutputCrtc(output, &alternate, &.{ 47, 91 }, &outputs, false));
    // Even with the same CRTC, an alternate encoder must not be substituted.
    var same_crtc = alternate;
    same_crtc.crtc_id = 47;
    try std.testing.expectEqual(@as(?u32, null), chooseOutputCrtc(output, &same_crtc, &.{ 47, 91 }, &outputs, true));

    // The current encoder can drive a free CRTC, but moving it is not safe.
    encoder.possible_crtcs = 2;
    try std.testing.expectEqual(@as(?u32, null), chooseOutputCrtc(output, &encoder, &.{ 47, 91 }, &outputs, true));
    try std.testing.expectEqual(@as(?u32, null), chooseOutputCrtc(output, &encoder, &.{ 47, 91 }, &outputs, false));
}

test "cloned enabled connector is rejected rather than moved to a free CRTC" {
    var connector: libdrm.drmModeConnector = .{ .connector_id = 10, .connection = libdrm.DRM_MODE_CONNECTED };
    var encoder: libdrm.drmModeEncoder = .{ .encoder_id = 20, .crtc_id = 47, .possible_crtcs = 3 };
    const outputs = [_]Output{
        .{
            .connector = &connector,
            .encoder = &encoder,
            .mode = testMode(1024, false),
            .route = .{ .connector_id = 10, .encoder_id = 20, .crtc_id = 47 },
        },
        .{ .route = .{ .connector_id = 11, .encoder_id = 21, .crtc_id = 47 } },
    };
    // The low-level mask helper finds 91, but connector selection must reject it.
    try std.testing.expectEqual(@as(?u32, 91), chooseCrtc(&.{ 47, 91 }, 3, 47, 10, 20, &outputs));
    try std.testing.expectEqual(@as(?u32, null), chooseOutputCrtc(&outputs[0], &encoder, &.{ 47, 91 }, &outputs, true));
    try std.testing.expectEqual(@as(?u32, null), chooseOutputCrtc(&outputs[0], &encoder, &.{ 47, 91 }, &outputs, false));
}

test "known disabled connector can select a current or alternate encoder exclusively" {
    var connector: libdrm.drmModeConnector = .{ .connector_id = 10, .connection = libdrm.DRM_MODE_CONNECTED };
    var encoder: libdrm.drmModeEncoder = .{ .encoder_id = 20, .possible_crtcs = 3 };
    const outputs = [_]Output{
        .{
            .connector = &connector,
            .encoder = &encoder,
            .mode = testMode(1024, false),
            .route = .{ .connector_id = 10, .encoder_id = 20 },
        },
        .{ .route = .{ .connector_id = 11, .encoder_id = 21, .crtc_id = 47 } },
    };
    const output = &outputs[0];
    try std.testing.expectEqual(@as(?u32, null), chooseOutputCrtc(output, &encoder, &.{ 47, 91 }, &outputs, true));
    try std.testing.expect(outputEligible(output, false));
    try std.testing.expectEqual(@as(?u32, 91), chooseOutputCrtc(output, &encoder, &.{ 47, 91 }, &outputs, false));
    var alternate: libdrm.drmModeEncoder = .{ .encoder_id = 22, .possible_crtcs = 2 };
    try std.testing.expectEqual(@as(?u32, 91), chooseOutputCrtc(output, &alternate, &.{ 47, 91 }, &outputs, false));
    // Switching encoders still cannot steal another output's route.
    alternate.encoder_id = 21;
    try std.testing.expectEqual(@as(?u32, null), chooseOutputCrtc(output, &alternate, &.{ 47, 91 }, &outputs, false));
}

test "unknown connector candidates are skipped in both selection passes" {
    var connector: libdrm.drmModeConnector = .{ .connector_id = 10, .connection = libdrm.DRM_MODE_CONNECTED };
    var encoder: libdrm.drmModeEncoder = .{ .encoder_id = 20, .possible_crtcs = 3 };
    var output: Output = .{
        .connector = &connector,
        .encoder = &encoder,
        .mode = testMode(1024, false),
        .route = .{ .connector_id = 10, .encoder_id = 20, .known = false },
    };
    for ([_]u32{ 0, 47 }) |current| {
        output.route.crtc_id = current;
        encoder.crtc_id = current;
        for ([_]bool{ true, false }) |current_only| {
            try std.testing.expect(!outputEligible(&output, current_only));
            try std.testing.expectEqual(@as(?u32, null), chooseOutputCrtc(&output, &encoder, &.{ 47, 91 }, &.{output}, current_only));
        }
    }
}

fn testMode(width: u16, preferred: bool) libdrm.drmModeModeInfo {
    var mode = std.mem.zeroes(libdrm.drmModeModeInfo);
    mode.clock = 65000;
    mode.hdisplay = width;
    mode.hsync_start = width + 16;
    mode.hsync_end = width + 32;
    mode.htotal = width + 64;
    mode.vdisplay = 768;
    mode.vsync_start = 771;
    mode.vsync_end = 777;
    mode.vtotal = 800;
    mode.type = if (preferred) libdrm.DRM_MODE_TYPE_PREFERRED else 0;
    return mode;
}

test "mode selection prefers the first valid preferred mode then the first valid mode" {
    const first = testMode(1024, false);
    const preferred = testMode(1280, true);
    const later = testMode(1600, true);
    var invalid = preferred;
    invalid.clock = 0;
    try std.testing.expectEqual(@as(u16, 1280), selectMode(&.{ first, invalid, preferred, later }).?.hdisplay);
    try std.testing.expectEqual(@as(u16, 1024), selectMode(&.{ invalid, first, testMode(800, false) }).?.hdisplay);
    try std.testing.expect(selectMode(&.{invalid}) == null);
    try std.testing.expect(selectMode(&.{}) == null);
}

test "mode validation rejects missing dimensions and malformed timings" {
    var mode = testMode(1024, false);
    mode.hdisplay = 0;
    try std.testing.expect(!validMode(mode));
    mode = testMode(1024, false);
    mode.vdisplay = 0;
    try std.testing.expect(!validMode(mode));
    mode = testMode(1024, false);
    mode.hsync_start = mode.hdisplay - 1;
    try std.testing.expect(!validMode(mode));
    mode = testMode(1024, false);
    mode.vtotal = mode.vsync_end - 1;
    try std.testing.expect(!validMode(mode));
}

test "DRM arrays reject absent or nonpositive counts without dereferencing" {
    var values = [_]u32{ 47, 91 };
    try std.testing.expectEqual(@as(usize, 0), drmSlice(u32, null, 2).len);
    try std.testing.expectEqual(@as(usize, 0), drmSlice(u32, &values, -1).len);
    try std.testing.expectEqual(@as(usize, 0), drmSlice(u32, &values, 0).len);
    try std.testing.expectEqualSlices(u32, &values, drmSlice(u32, &values, 2));
}

test "public discovery entry points compile without performing DRM IO" {
    std.testing.refAllDecls(Device);
}
