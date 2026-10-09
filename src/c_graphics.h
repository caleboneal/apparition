#pragma once
#define EGL_NO_X11
#define MESA_EGL_NO_X11_HEADERS

#include <fcntl.h>
#include <unistd.h>
#include <xf86drm.h>
#include <xf86drmMode.h>
#include <drm_fourcc.h>
#include <sys/mman.h>

static void apparition_page_flip_handler(
    int fd,
    unsigned int frame,
    unsigned int sec,
    unsigned int usec,
    void *user_data
) {
    (void)fd;
    (void)frame;
    (void)sec;
    (void)usec;
    (void)user_data;
}

static inline int apparition_wait_for_page_flip(int fd) {
    drmEventContext event_context = {0};
    event_context.version = DRM_EVENT_CONTEXT_VERSION;
    event_context.page_flip_handler = apparition_page_flip_handler;
    return drmHandleEvent(fd, &event_context);
}

#include <ft2build.h>
#include <freetype/freetype.h>
