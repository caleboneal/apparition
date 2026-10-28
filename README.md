# Apparition

Apparition is a KMS / DRM terminal emulator built on `libghostty-vt`.

It starts an interactive `$SHELL` (falling back to `/bin/sh`) on a PTY with
`TERM=xterm-256color`. Shell output is parsed by `libghostty-vt` and rendered
as a fixed-cell grid with colors and a cursor. The terminal's rows and columns
are derived from the display resolution and font metrics and passed to the PTY.

## Running

```sh
zig build
zig build run
```

Run on Linux with access to a primary DRM node in `/dev/dri` and the input
devices on `seat0`, with DRM master available (normally from an active virtual
console without another display server owning the device). Apparition discovers
DRM cards and selects one with dumb-buffer support and a connected, routable
output, skipping inaccessible or unsuitable cards. It prefers an existing
compatible display route and the output's preferred mode, and logs the selected
card, connector, and CRTC. The configured font must exist;
see `src/config.zig` for the font path and size. Running via `sudo` also runs
the shell as root, so prefer appropriate device permissions when possible.

Keyboards are discovered through libinput/udev. Input supports UTF-8, Shift,
Ctrl combinations such as Ctrl-C/Ctrl-D, Alt, Enter, Backspace, Tab, Escape,
and navigation keys, including application-cursor mode. XKB uses the default
layout, configurable through `XKB_DEFAULT_*` environment variables.

Use `exit` or Ctrl-D at an empty shell prompt to close the terminal. Normal
shutdown restores the previous display and console keyboard modes and reaps
the shell. The event loop polls PTY, input, and pending DRM page-flip events
instead of busy-spinning or blocking on vblank. Output updates are coalesced
at the display refresh rate (60 Hz if the mode does not report one).

Rendering caches glyph masks for the configured font size, uses bulk pixel
fills, and skips redundant default-background fills. Frames still redraw the
whole visible grid; dirty-row rendering is not yet implemented.

This is still rudimentary: no key autorepeat, scrollback UI, mouse input,
clipboard, IME/compose, font fallback, grapheme shaping, or display hotplug/
resize handling. Rendering uses the first codepoint of each grapheme, and
bold/italic/underline font styling is not yet drawn. Colors use the xterm ANSI
palette and standard 256-color cube/grayscale ramp, with bold-as-bright ANSI
foregrounds, faint text, inverse video, and truecolor support. Application OSC
color changes and resets are honored.

## Tests

```sh
zig build test
```

Tests cover PTY shell startup and sizing, exec failure, queued input,
terminal parsing/replies, keyboard translation, and renderer helpers without
requiring DRM or input hardware.
