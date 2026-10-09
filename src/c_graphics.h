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

#include <ft2build.h>
#include <freetype/freetype.h>

static inline uint32_t apparition_blend_pixel(uint32_t dst, uint32_t src, uint8_t alpha) {
    const uint32_t inverse_alpha = 255 - alpha;
    const uint32_t red = (((src >> 16) & 0xff) * alpha + ((dst >> 16) & 0xff) * inverse_alpha) / 255;
    const uint32_t green = (((src >> 8) & 0xff) * alpha + ((dst >> 8) & 0xff) * inverse_alpha) / 255;
    const uint32_t blue = ((src & 0xff) * alpha + (dst & 0xff) * inverse_alpha) / 255;
    return (red << 16) | (green << 8) | blue;
}

static inline int apparition_draw_text(
    uint32_t *pixels,
    uint32_t stride,
    uint32_t width,
    uint32_t height,
    const char *font_path,
    const char *text,
    uint32_t pixel_size,
    int x,
    int baseline_y,
    uint32_t color
) {
    FT_Library library;
    FT_Face face;
    if (FT_Init_FreeType(&library) != 0) return -1;
    if (FT_New_Face(library, font_path, 0, &face) != 0) {
        FT_Done_FreeType(library);
        return -2;
    }
    if (FT_Set_Pixel_Sizes(face, 0, pixel_size) != 0) {
        FT_Done_Face(face);
        FT_Done_FreeType(library);
        return -3;
    }

    int pen_x = x;
    int pen_y = baseline_y;
    for (const unsigned char *character = (const unsigned char *)text; *character; ++character) {
        if (*character == '\n') {
            pen_x = x;
            pen_y += face->size->metrics.height >> 6;
            continue;
        }
        if (FT_Load_Char(face, *character, FT_LOAD_RENDER) != 0) {
            FT_Done_Face(face);
            FT_Done_FreeType(library);
            return -4;
        }

        FT_GlyphSlot glyph = face->glyph;
        for (unsigned int row = 0; row < glyph->bitmap.rows; ++row) {
            const int destination_y = pen_y - glyph->bitmap_top + (int)row;
            if (destination_y < 0 || destination_y >= (int)height) continue;

            for (unsigned int column = 0; column < glyph->bitmap.width; ++column) {
                const int destination_x = pen_x + glyph->bitmap_left + (int)column;
                if (destination_x < 0 || destination_x >= (int)width) continue;

                const uint8_t alpha = glyph->bitmap.buffer[row * glyph->bitmap.pitch + column];
                uint32_t *pixel = &pixels[(uint32_t)destination_y * stride + (uint32_t)destination_x];
                *pixel = apparition_blend_pixel(*pixel, color, alpha);
            }
        }
        pen_x += glyph->advance.x >> 6;
    }

    FT_Done_Face(face);
    FT_Done_FreeType(library);
    return 0;
}

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
