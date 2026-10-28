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
card, connector, and CRTC. JetBrains Mono is bundled, so no system font
installation is needed. See [Fonts](#fonts) for configuration. Running via
`sudo` also runs the shell as root, so prefer appropriate device permissions
when possible.

Keyboards are discovered through libinput/udev. Input supports UTF-8, Shift,
Ctrl combinations such as Ctrl-C/Ctrl-D, Alt, Enter, Backspace, Tab, Escape,
and navigation keys, including application-cursor mode. XKB uses the default
layout, configurable through `XKB_DEFAULT_*` environment variables.

Use `exit` or Ctrl-D at an empty shell prompt to close the terminal. Normal
shutdown restores the previous display and console keyboard modes and reaps
the shell. The event loop polls PTY, input, and pending DRM page-flip events
instead of busy-spinning or blocking on vblank. Output updates are coalesced
at the display refresh rate (60 Hz if the mode does not report one).

Rendering caches glyph masks by codepoint and font style at the configured
font size and repaints only damaged rows. Damage accumulates independently for
both framebuffers, including
the old and new cursor rows. Screen, palette, default-color, and grid changes
trigger full redraws (including display margins). Once the back buffer is
current, nonvisual output does not cause another page flip.

This is still rudimentary: no key autorepeat, scrollback UI, mouse input,
clipboard, IME/compose, font fallback, grapheme shaping, or display hotplug/
resize handling. Rendering uses the first codepoint of each grapheme. Bold,
italic, and bold-italic text use separate font faces. Underlines support single,
double, curly, dotted, and dashed styles, including spaces, wide cells, and
SGR 58/59 underline colors. Colors use the xterm ANSI palette and standard
256-color cube/grayscale ramp, with bold-as-bright ANSI foregrounds, faint
text, inverse video, and truecolor support. Application OSC
color changes and resets are honored.

## Fonts

The default font is embedded JetBrains Mono 2.304, including Regular, Bold,
Italic, and BoldItalic. The executable does not need to find these files at
runtime. All styles use the regular face's cell dimensions and baseline;
glyph overhang is clipped to the cell grid.

To use another monospace family, edit `src/config.zig` and rebuild:

```zig
font_directory: ?[]const u8 = "/path/to/fonts",
font_name: []const u8 = "MyMono",
font_size: u8 = 16,
```

The directory must contain `MyMono-Regular.ttf`, `MyMono-Bold.ttf`,
`MyMono-Italic.ttf`, and `MyMono-BoldItalic.ttf`. All four faces are required;
startup reports the path if one cannot be loaded. Set `font_directory` to
`null` to use bundled JetBrains Mono (`font_name` is ignored in that case).
Underline position and thickness come from the regular font's metrics.

Try the styles in the terminal with:

```sh
printf '\033[1mBold\033[0m  \033[3mItalic\033[0m  \033[1;3mBold italic\033[0m  \033[4mUnderline\033[0m\n'
```

JetBrains Mono is distributed under the SIL Open Font License 1.1; see
`src/fonts/OFL.txt`. The build installs a copy of the license to
`zig-out/share/licenses/apparition/JetBrainsMono-OFL.txt`; include it when
redistributing the executable. The font files are from the official
[JetBrains Mono v2.304 release](https://github.com/JetBrains/JetBrainsMono/tree/v2.304).

## Tests

```sh
zig build test
```

Tests cover PTY shell startup and sizing, exec failure, queued input,
terminal parsing/replies, keyboard translation, DRM routing helpers, and
incremental rendering without requiring DRM or input hardware. Renderer tests
compare dirty-row frames against full redraws through buffer flips, cursor
changes, scrolling, screen switches, color changes, and drawing-error retries.
Font tests load bundled and external families, verify independent style caches,
and cover styled block cursors and underlines on spaces and wide cells.
