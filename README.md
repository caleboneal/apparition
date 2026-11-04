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

Run on Linux from a local login on a virtual console. Apparition takes control
of the session's seat through libseat (`logind`, `seatd`, or as root its
builtin backend), which opens the DRM and input devices for it, so no `input`
group membership, device permissions, or `sudo` are needed. It waits up to ten
seconds for the session to be the active VT, and fails if another display
server already holds DRM master. Apparition discovers
DRM cards and selects one with dumb-buffer support and a connected, routable
output, skipping inaccessible or unsuitable cards. It prefers an existing
compatible display route and the output's preferred mode, and logs the selected
card, connector, and CRTC. JetBrains Mono and Noto Color Emoji are bundled, so
no system font installation is needed. See [Fonts](#fonts) for configuration.

Keyboards are discovered through libinput/udev. Input supports UTF-8, Shift,
Ctrl combinations such as Ctrl-C/Ctrl-D, Alt, Enter, Backspace, Tab, Escape,
and navigation keys, including application-cursor mode. XKB uses the default
layout, configurable through `XKB_DEFAULT_*` environment variables. Held keys
autorepeat after `repeat_delay_ms` (600 ms) at `repeat_rate` (25 per second),
both set in `src/config.zig`; a rate of 0 disables autorepeat. Modifiers do
not repeat, and repeats use the current modifiers.

Shift+PageUp and Shift+PageDown scroll through history a page at a time, and
Shift+Home and Shift+End jump to the oldest line or back to the live screen.
Any key that sends input also returns to the live screen; new output does not
move a scrolled-back view. History keeps `scrollback_lines` (10,000) lines, set
in `src/config.zig`; 0 disables it. The alternate screen used by full-screen
programs has no history, so these keys reach the program there.

The kitty graphics protocol is supported, so tools such as `kitten icat`,
`chafa`, `timg`, and image previews in `yazi` or `ranger` can show images.
PNG data is decoded with libpng; raw RGB and RGBA are accepted too. Images may
be sent inline or, from local programs, by file, temporary file, or shared
memory. Placements follow the protocol's z layers (over text, under text, or
under cell backgrounds), scale and crop as requested, scroll with the text, and
play animations. Decoded images share a `image_storage_limit` (320 MB) budget
in `src/config.zig`; 0 disables the protocol. The PTY and CSI 14/16 t replies
report the grid's pixel size so programs can size images to cells. Unicode
placeholder placements (`U=1`, used by tmux passthrough) are not drawn yet.

Ctrl+Alt+F1 through F12 switch virtual terminals (following the keymap's
`XF86Switch_VT_*` keysyms) through the seat provider, which also disables the
console keyboard and restores the VT if Apparition exits or crashes. Switching
away finishes any pending page flip and closes input devices before
acknowledging; the seat provider revokes DRM master and any input still open,
so other sessions' keys never reach this shell. Switching back reopens input
and does a full modeset and redraw. If the shell exits while another VT is
active, Apparition quits without touching the display.

Use `exit` or Ctrl-D at an empty shell prompt to close the terminal. Normal
shutdown restores the previous display and console keyboard modes and reaps
the shell. The event loop polls PTY, input, shell exit (through a pidfd, so
Linux 5.3 or later is required), and pending DRM page-flip events instead of
busy-spinning or blocking on vblank, and an idle terminal sleeps without a
timeout. Output updates are coalesced at the display refresh rate (60 Hz if
the mode does not report one).

Rendering caches glyphs by codepoint, font style, and cell width at the
configured font size and repaints only damaged rows, including the old and
new cursor rows. Rows are drawn into a buffer in system memory, since dumb
buffers are often slow to read back, and each framebuffer then receives a copy
of the rows that changed since it was last drawn. Screen, palette,
default-color, and grid changes trigger full redraws (including display
margins). Once the back buffer is current, nonvisual output does not cause
another page flip.

Grapheme clustering (mode 2027) is on by default, so emoji ZWJ sequences,
flags, skin tones, keycaps, and combining marks each occupy one cell (wide for
emoji). Set `grapheme_clustering` in `src/config.zig` to `false` for legacy
per-codepoint widths; programs can also toggle the mode. Cells holding more
than one codepoint are shaped once with HarfBuzz and cached, so combining
marks compose or stack on their base and emoji sequences become a single
glyph. Marks the font lacks are omitted, and an emoji sequence the emoji font
does not know shows its first emoji. Text is not shaped across cells, so there
are no programming ligatures.

A cell uses the emoji font when its codepoint requests emoji presentation:
with VS16, a ZWJ, a skin tone, a keycap, or a tag sequence; when the terminal
made it wide; or when the text font lacks it. VS15 asks for the text font.
Color emoji keep their colors (including under a block cursor) and are scaled
to fit their cells, centered.

Box drawing characters (U+2500 to U+257F) are drawn by Apparition rather than
taken from the font, so they fill each cell exactly and join across cells with
no gaps, whatever the font's metrics. Light lines use the font's underline
thickness; heavy lines are twice that, and double lines are spaced by it. This
covers light, heavy, and double lines with their mixed junctions, dashed
lines, rounded corners, and diagonals.

Powerline separators (U+E0B0 to U+E0BF) are drawn the same way, so prompts
such as starship's render with any font, without a Nerd Font, and their solid
shapes meet neighboring cell backgrounds without gaps. This covers the solid
and thin arrows, solid and outlined half circles, corner triangles, and slash
separators. Other Nerd Font icons still need a font that has them.

This is still rudimentary: no mouse input,
clipboard, IME/compose, fallback beyond the emoji font, or display hotplug/
resize handling. Bold,
italic, and bold-italic text use separate font faces. Underlines support single,
double, curly, dotted, and dashed styles, including spaces, wide cells, and
SGR 58/59 underline colors. Colors use the xterm ANSI palette and standard
256-color cube/grayscale ramp, with bold-as-bright ANSI foregrounds, faint
text, inverse video, and truecolor support. Application OSC
color changes and resets are honored. The default background, which also fills
the display margins, is `background` in `src/config.zig` as `0xRRGGBB`
(black by default); OSC 111 resets to it.

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

Noto Color Emoji 2.057 (Unicode 18) is embedded for emoji with any text
family. It is a color bitmap font with a single 109 ppem strike, so emoji are
downscaled to the cell grid with area averaging. Try it with:

```sh
printf '👍🏽 👨‍👩‍👧 🇺🇸 1️⃣ ❤️ ⚡ ⚡︎ e\u0301\n'
```

JetBrains Mono and Noto Color Emoji are distributed under the SIL Open Font
License 1.1; see `src/fonts/OFL.txt` and `src/fonts/NotoColorEmoji-OFL.txt`.
The build installs copies of both licenses to
`zig-out/share/licenses/apparition/`; include them when redistributing the
executable. The font files are from the official
[JetBrains Mono v2.304 release](https://github.com/JetBrains/JetBrainsMono/tree/v2.304)
and the
[Noto Emoji v2026-09-24-unicode18_0 release](https://github.com/googlefonts/noto-emoji/tree/v2026-09-24-unicode18_0/2D/fonts).

## Tests

```sh
zig build test
```

Tests cover PTY shell startup and sizing (including pixel size), exec
failure, queued input, libpng decoding and kitty PNG transmissions, kitty image
layering, scaling, and incremental redraws,
terminal parsing/replies, keyboard translation and autorepeat timing, VT
switch keys and seat enable/disable ordering, DRM routing helpers, and
incremental rendering without requiring DRM or input hardware. Renderer tests
compare dirty-row frames against full redraws through buffer flips, cursor
changes, scrolling, scrollback viewports, screen switches, color changes, and
drawing-error retries.
Font tests load bundled and external families, verify independent style caches,
and cover styled block cursors and underlines on spaces and wide cells. Emoji
and grapheme tests cover presentation selection, combining mark composition and
placement, color glyph copying, resampling, and blending, and render skin-tone,
ZWJ, flag, keycap, and VS16 sequences as single color glyphs within their
cells. Box drawing tests check exact pixels for lines, junctions, nested double
corners, dashes, and arcs, that every character reaches the cell edges its
lines point to, and that boxes join across neighboring cells. Powerline tests
check that left and right separators mirror each other, solid shapes cover
their flat edge, and separators bypass the font.
