#pragma once
#define EGL_NO_X11
#define MESA_EGL_NO_X11_HEADERS

#include <fcntl.h>
#include <unistd.h>
#include <xf86drm.h>
#include <xf86drmMode.h>
#include <drm_fourcc.h>
#include <sys/mman.h>
#include <stdint.h>
#include <stdlib.h>
#include <poll.h>

#include <ft2build.h>
#include <freetype/freetype.h>

static inline uint32_t apparition_next_utf8(const unsigned char **text) {
    const unsigned char *character = *text;
    const unsigned char first = *character++;
    if (first < 0x80) {
        *text = character;
        return first;
    }

    unsigned int continuation_bytes;
    uint32_t codepoint;
    if ((first & 0xe0) == 0xc0) {
        continuation_bytes = 1;
        codepoint = first & 0x1f;
    } else if ((first & 0xf0) == 0xe0) {
        continuation_bytes = 2;
        codepoint = first & 0x0f;
    } else if ((first & 0xf8) == 0xf0) {
        continuation_bytes = 3;
        codepoint = first & 0x07;
    } else {
        *text = character;
        return 0xfffd;
    }

    for (unsigned int i = 0; i < continuation_bytes; ++i) {
        const unsigned char next = *character;
        if ((next & 0xc0) != 0x80) {
            *text = character;
            return 0xfffd;
        }
        codepoint = (codepoint << 6) | (next & 0x3f);
        ++character;
    }
    *text = character;
    return codepoint;
}
