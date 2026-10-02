const c = @import("c_graphics");

const std = @import("std");

pub const GraphicsContext = struct {
    drm_fd: c_int,
    crtc_id: u32,
    connector_id: u32,
    mode: c.drmModeModeInfo,
    gbm_device: *c.struct_gbm_device,
    gbm_surface: *c.struct_gbm_surface,
    egl_display: c.EGLDisplay,
    egl_config: c.EGLConfig,
    egl_context: c.EGLContext,
    egl_surface: c.EGLSurface,

    pub fn init() !GraphicsContext {
        // 1. Open the primary GPU device node
        // On the CM5 / Raspberry Pi, this is typically /dev/dri/card0 or card1
        const drm_fd = c.open("/dev/dri/card0", c.O_RDWR | c.O_CLOEXEC);
        if (drm_fd < 0) return error.DrmOpenFailed;
        errdefer _ = c.close(drm_fd);

        // 2. Query DRM Resources to find an active screen connector
        const res = c.drmModeGetResources(drm_fd) orelse return error.DrmResourcesNotFound;
        defer c.drmModeFreeResources(res);

        var connector: ?*c.drmModeConnector = null;
        var i: usize = 0;
        while (i < res.*.count_connectors) : (i += 1) {
            if (c.drmModeGetConnector(drm_fd, res.*.connectors[i])) |conn| {
                if (conn.*.connection == c.DRM_MODE_CONNECTED and conn.*.count_modes > 0) {
                    connector = conn;
                    break;
                } else {
                    if (conn != null) c.drmModeFreeConnector(conn);
                }
            }
        }

        const conn = connector orelse return error.NoConnectedDisplay;
        defer c.drmModeFreeConnector(conn);

        // Take the primary/preferred display resolution mode
        const mode = conn.*.modes[0];
        const connector_id = conn.*.connector_id;

        // Find a valid encoder -> CRTC pipeline to drive the display
        const encoder = c.drmModeGetEncoder(drm_fd, conn.*.encoder_id) orelse return error.DrmEncoderNotFound;
        defer c.drmModeFreeEncoder(encoder);
        const crtc_id = encoder.*.crtc_id;

        // 3. Initialize GBM (Generic Buffer Management) to allocate raw GPU memory surfaces
        const gbm_device = c.gbm_create_device(drm_fd) orelse return error.GbmDeviceCreationFailed;
        errdefer c.gbm_device_destroy(gbm_device);

        const gbm_surface = c.gbm_surface_create(
            gbm_device,
            mode.hdisplay,
            mode.vdisplay,
            c.GBM_FORMAT_XRGB8888,
            c.GBM_BO_USE_SCANOUT | c.GBM_BO_USE_RENDERING,
        ) orelse return error.GbmSurfaceCreationFailed;
        errdefer c.gbm_surface_destroy(gbm_surface);

        // 4. Initialize EGL to wire OpenGL ES directly to our GBM surfaces
        const egl_display = c.eglGetDisplay(@ptrCast(gbm_device));
        if (egl_display == c.EGL_NO_DISPLAY) return error.EglDisplayFailed;

        if (c.eglInitialize(egl_display, null, null) == c.EGL_FALSE) return error.EglInitFailed;
        errdefer _ = c.eglTerminate(egl_display);

        // Enforce an OpenGL ES 3.0 API binding
        if (c.eglBindAPI(c.EGL_OPENGL_ES_API) == c.EGL_FALSE) return error.EglBindApiFailed;

        const config_attribs = [_]c.EGLint{
            c.EGL_SURFACE_TYPE,    c.EGL_WINDOW_BIT,
            c.EGL_RED_SIZE,        8,
            c.EGL_GREEN_SIZE,      8,
            c.EGL_BLUE_SIZE,       8,
            c.EGL_ALPHA_SIZE,      0,
            c.EGL_RENDERABLE_TYPE, c.EGL_OPENGL_ES3_BIT,
            c.EGL_NONE,
        };

        var egl_config: c.EGLConfig = undefined;
        var num_configs: c.EGLint = undefined;
        if (c.eglChooseConfig(egl_display, &config_attribs, &egl_config, 1, &num_configs) == c.EGL_FALSE or num_configs == 0) {
            return error.EglConfigFailed;
        }

        const context_attribs = [_]c.EGLint{
            c.EGL_CONTEXT_CLIENT_VERSION, 3, // Request OpenGL ES 3.0 context
            c.EGL_NONE,
        };

        const egl_context = c.eglCreateContext(egl_display, egl_config, c.EGL_NO_CONTEXT, &context_attribs) orelse return error.EglContextCreationFailed;
        errdefer _ = c.eglDestroyContext(egl_display, egl_context);

        const egl_surface = c.eglCreateWindowSurface(egl_display, egl_config, @ptrCast(gbm_surface), null) orelse return error.EglSurfaceCreationFailed;
        errdefer _ = c.eglDestroySurface(egl_display, egl_surface);

        // 5. Activate the rendering context for this thread
        if (c.eglMakeCurrent(egl_display, egl_surface, egl_surface, egl_context) == c.EGL_FALSE) {
            return error.EglMakeCurrentFailed;
        }

        std.log.info("Direct DRM/GLES Context Initialized successfully! Resolution: {}x{}", .{ mode.hdisplay, mode.vdisplay });

        return GraphicsContext{
            .drm_fd = drm_fd,
            .crtc_id = crtc_id,
            .connector_id = connector_id,
            .mode = mode,
            .gbm_device = gbm_device,
            .gbm_surface = gbm_surface,
            .egl_display = egl_display,
            .egl_config = egl_config,
            .egl_context = egl_context,
            .egl_surface = egl_surface,
        };
    }

    pub fn swapBuffers(self: *GraphicsContext) void {
        // Swap OpenGL ES render targets
        _ = c.eglSwapBuffers(self.egl_display, self.egl_surface);

        // Fetch back-buffer from GBM surface to display via DRM
        const bo = c.gbm_surface_lock_front_buffer(self.gbm_surface);
        defer c.gbm_surface_release_buffer(self.gbm_surface, bo);

        const fb_id = self.getFbIdForBo(bo);

        // Issue a hardware page-flip to display the frame instantly at VBLANK
        _ = c.drmModePageFlip(self.drm_fd, self.crtc_id, fb_id, c.DRM_MODE_PAGE_FLIP_EVENT, self);
    }

    // Helper function to turn a GBM buffer object into a DRM Framebuffer ID
    fn getFbIdForBo(self: *GraphicsContext, bo: *c.struct_gbm_bo) u32 {
        const width = c.gbm_bo_get_width(bo);
        const height = c.gbm_bo_get_height(bo);
        const stride = c.gbm_bo_get_stride(bo);
        const handle = c.gbm_bo_get_handle(bo).u32;

        var fb_id: u32 = 0;
        _ = c.drmModeAddFB(self.drm_fd, width, height, 24, 32, stride, handle, &fb_id);
        return fb_id;
    }

    pub fn deinit(self: *GraphicsContext) void {
        _ = c.eglMakeCurrent(self.egl_display, c.EGL_NO_SURFACE, c.EGL_NO_SURFACE, c.EGL_NO_CONTEXT);
        _ = c.eglDestroySurface(self.egl_display, self.egl_surface);
        _ = c.eglDestroyContext(self.egl_display, self.egl_context);
        _ = c.eglTerminate(self.egl_display);
        _ = c.gbm_surface_destroy(self.gbm_surface);
        _ = c.gbm_device_destroy(self.gbm_device);
        _ = c.close(self.drm_fd);
    }
};
