// Null uses bundled JetBrains Mono. External families must provide
// <font_name>-{Regular,Bold,Italic,BoldItalic}.ttf in this directory.
font_directory: ?[]const u8 = null,
font_name: []const u8 = "JetBrainsMono",
font_size: u8 = 16,
// History lines kept above the screen, viewed with Shift+PageUp; 0 disables.
scrollback_lines: usize = 10_000,
// Bytes of decoded kitty graphics images kept before evicting old ones; 0
// disables the kitty graphics protocol.
image_storage_limit: usize = 320 * 1000 * 1000,
// Held keys repeat after the delay at the rate in keys per second; 0 disables.
repeat_delay_ms: u32 = 600,
repeat_rate: u32 = 25,
