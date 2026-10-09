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

#include <libinput.h>
#include <libudev.h>
#include <xkbcommon/xkbcommon.h>
#include <xkbcommon/xkbcommon-keysyms.h>

#include <ft2build.h>
#include <freetype/freetype.h>

enum {
    APPARITION_INPUT_BACKSPACE = -2,
    APPARITION_INPUT_QUIT = -3,
};

typedef struct {
    struct udev *udev;
    struct libinput *libinput;
    struct xkb_context *xkb_context;
    struct xkb_keymap *keymap;
    struct xkb_state *state;
} apparition_input;

static int apparition_open_restricted(const char *path, int flags, void *user_data) {
    (void)user_data;
    return open(path, flags | O_CLOEXEC);
}

static void apparition_close_restricted(int fd, void *user_data) {
    (void)user_data;
    close(fd);
}

static const struct libinput_interface apparition_libinput_interface = {
    .open_restricted = apparition_open_restricted,
    .close_restricted = apparition_close_restricted,
};

static inline void apparition_input_destroy(apparition_input *input) {
    if (!input) return;
    if (input->state) xkb_state_unref(input->state);
    if (input->keymap) xkb_keymap_unref(input->keymap);
    if (input->xkb_context) xkb_context_unref(input->xkb_context);
    if (input->libinput) libinput_unref(input->libinput);
    if (input->udev) udev_unref(input->udev);
    free(input);
}

static inline apparition_input *apparition_input_create(void) {
    apparition_input *input = calloc(1, sizeof(*input));
    if (!input) return NULL;

    input->udev = udev_new();
    if (!input->udev) goto failure;
    input->libinput = libinput_udev_create_context(
        &apparition_libinput_interface,
        input,
        input->udev
    );
    if (!input->libinput) goto failure;
    if (libinput_udev_assign_seat(input->libinput, "seat0") != 0) goto failure;

    input->xkb_context = xkb_context_new(XKB_CONTEXT_NO_FLAGS);
    if (!input->xkb_context) goto failure;
    input->keymap = xkb_keymap_new_from_names(input->xkb_context, NULL, XKB_KEYMAP_COMPILE_NO_FLAGS);
    if (!input->keymap) goto failure;
    input->state = xkb_state_new(input->keymap);
    if (!input->state) goto failure;
    return input;

failure:
    apparition_input_destroy(input);
    return NULL;
}

static inline int apparition_input_wait(apparition_input *input) {
    struct pollfd poll_fd = {
        .fd = libinput_get_fd(input->libinput),
        .events = POLLIN,
    };
    if (poll(&poll_fd, 1, -1) <= 0) return -1;
    return libinput_dispatch(input->libinput);
}

static inline int apparition_input_next_text(apparition_input *input, char *text, size_t text_size) {
    struct libinput_event *event = libinput_get_event(input->libinput);
    if (!event) return 0;

    int result = 0;
    if (libinput_event_get_type(event) == LIBINPUT_EVENT_KEYBOARD_KEY) {
        struct libinput_event_keyboard *keyboard_event = libinput_event_get_keyboard_event(event);
        const uint32_t key = libinput_event_keyboard_get_key(keyboard_event) + 8;
        const enum libinput_key_state key_state = libinput_event_keyboard_get_key_state(keyboard_event);
        xkb_state_update_key(
            input->state,
            key,
            key_state == LIBINPUT_KEY_STATE_PRESSED ? XKB_KEY_DOWN : XKB_KEY_UP
        );

        if (key_state == LIBINPUT_KEY_STATE_PRESSED) {
            const xkb_keysym_t symbol = xkb_state_key_get_one_sym(input->state, key);
            if (symbol == XKB_KEY_Escape) {
                result = APPARITION_INPUT_QUIT;
            } else if (symbol == XKB_KEY_BackSpace) {
                result = APPARITION_INPUT_BACKSPACE;
            } else {
                result = xkb_state_key_get_utf8(input->state, key, text, text_size);
            }
        }
    }

    libinput_event_destroy(event);
    return result;
}

apparition_input *apparition_input_create_export(void);
void apparition_input_destroy_export(apparition_input *input);
int apparition_input_wait_export(apparition_input *input);
int apparition_input_next_text_export(apparition_input *input, char *text, size_t text_size);

static inline uint32_t apparition_blend_pixel(uint32_t dst, uint32_t src, uint8_t alpha) {
    const uint32_t inverse_alpha = 255 - alpha;
    const uint32_t red = (((src >> 16) & 0xff) * alpha + ((dst >> 16) & 0xff) * inverse_alpha) / 255;
    const uint32_t green = (((src >> 8) & 0xff) * alpha + ((dst >> 8) & 0xff) * inverse_alpha) / 255;
    const uint32_t blue = ((src & 0xff) * alpha + (dst & 0xff) * inverse_alpha) / 255;
    return (red << 16) | (green << 8) | blue;
}

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
    for (const unsigned char *character = (const unsigned char *)text; *character;) {
        const uint32_t codepoint = apparition_next_utf8(&character);
        if (codepoint == '\n') {
            pen_x = x;
            pen_y += face->size->metrics.height >> 6;
            continue;
        }
        if (FT_Load_Char(face, codepoint, FT_LOAD_RENDER) != 0) {
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
