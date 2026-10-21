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

Run on Linux with access to `/dev/dri/card0` and the input devices on `seat0`,
and with DRM master available (normally from an active virtual console without
another display server owning the device). The configured font must exist;
see `src/config.zig` for the font path and size. Running via `sudo` also runs
the shell as root, so prefer appropriate device permissions when possible.

Keyboards are discovered through libinput/udev. Input supports UTF-8, Shift,
Ctrl combinations such as Ctrl-C/Ctrl-D, Alt, Enter, Backspace, Tab, Escape,
and navigation keys, including application-cursor mode. XKB uses the default
layout, configurable through `XKB_DEFAULT_*` environment variables.

Use `exit` or Ctrl-D at an empty shell prompt to close the terminal. Normal
shutdown restores the previous display and console keyboard modes and reaps
the shell. The event loop polls for activity instead of busy-spinning.

This is still rudimentary: no key autorepeat, scrollback UI, mouse input,
clipboard, IME/compose, font fallback, grapheme shaping, or display hotplug/
resize handling. Rendering uses the first codepoint of each grapheme, and
bold/italic/underline styling is not yet drawn.

## Tests

```sh
zig build test
```

Tests cover PTY shell startup and sizing, exec failure, queued input,
terminal parsing/replies, keyboard translation, and renderer helpers without
requiring DRM or input hardware.
