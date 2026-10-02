#pragma once
#define EGL_NO_X11
#define MESA_EGL_NO_X11_HEADERS

#include <fcntl.h>
#include <unistd.h>
#include <xf86drm.h>
#include <xf86drmMode.h>
#include <drm_fourcc.h>
#include <sys/mman.h>
