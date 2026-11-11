//! Settings read from configuration files using Ghostty's syntax and rules.
//! Keys are the field names below with underscores written as dashes, e.g.
//! `font-size = 18`. An empty value (`font-size =`) restores the default.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ghosttyvt = @import("ghostty-vt");

const Config = @This();
const log = std.log.scoped(.config);

// Null uses bundled JetBrains Mono. External families must provide
// <font_name>-{Regular,Bold,Italic,BoldItalic}.ttf in this directory.
// Relative paths are resolved against the file that sets them, and `~/`
// against the home directory.
font_directory: ?[]const u8 = null,
font_name: []const u8 = "JetBrainsMono",
font_size: u8 = 16,
// Mode 2027 keeps each grapheme cluster (emoji ZWJ sequences, flags, skin
// tones, combining marks) in one cell. Programs can still toggle it.
grapheme_clustering: bool = true,
// Default background, also filling the display margins. Accepts the same
// forms as Ghostty: #RGB, #RRGGBB, RRGGBB or an X11 color name.
// Programs can override it with OSC 11 and restore it with OSC 111.
background: ghosttyvt.color.RGB = .{ .r = 0x0A, .g = 0x0E, .b = 0x14 },

// History lines kept above the screen, viewed with Shift+PageUp; 0 disables.
scrollback_lines: usize = 10_000,
// Bytes of decoded kitty graphics images kept before evicting old ones; 0
// disables the kitty graphics protocol.
image_storage_limit: usize = 320 * 1000 * 1000,
// Held keys repeat after the delay at the rate in keys per second; 0 disables.
repeat_delay_ms: u32 = 600,
repeat_rate: u32 = 25,

/// Loads `config` and then `config.apparition` from
/// `$XDG_CONFIG_HOME/apparition`, or `$HOME/.config/apparition` when
/// XDG_CONFIG_HOME is unset, followed by any files named with `config-file`.
/// Problems in the files are logged and skipped. Strings are allocated in
/// `arena`, which must outlive the returned config.
pub fn load(arena: Allocator, io: std.Io, environ: *const std.process.Environ.Map) Allocator.Error!Config {
    var loader: Loader = .{ .arena = arena, .io = io, .environ = environ };
    try loader.loadDefaultFiles();
    try loader.loadIncludes();
    return loader.config;
}

const whitespace = " \t";

const Loader = struct {
    config: Config = .{},
    arena: Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    // Absolute files named by `config-file`, loaded after the default files.
    includes: std.ArrayList(Include) = .empty,
    // Directory of the file being parsed, for resolving relative paths.
    base: []const u8 = "/",

    const Include = struct { path: []const u8, optional: bool };

    const Outcome = enum { loaded, not_found, failed };

    fn loadDefaultFiles(self: *Loader) Allocator.Error!void {
        const dir = try self.configDir() orelse {
            log.warn("cannot determine the home directory, not loading configuration files", .{});
            return;
        };
        const legacy = try std.fs.path.join(self.arena, &.{ dir, "config" });
        const preferred = try std.fs.path.join(self.arena, &.{ dir, "config.apparition" });
        const legacy_outcome = try self.loadOptionalFile(legacy);
        const preferred_outcome = try self.loadOptionalFile(preferred);
        if (legacy_outcome != .not_found and preferred_outcome != .not_found) {
            log.warn("both config files `{s}` and `{s}` exist.", .{ legacy, preferred });
            log.warn("loading them both in that order", .{});
        }
    }

    fn loadOptionalFile(self: *Loader, path: []const u8) Allocator.Error!Outcome {
        self.loadFile(path) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.FileNotFound => return .not_found,
            error.NotAFile => log.warn("config-file {s}: not reading because it is not a file", .{path}),
            else => {
                log.warn("error reading optional config file, not loading err={s} path={s}", .{ @errorName(err), path });
                return .failed;
            },
        };
        return .loaded;
    }

    /// Loads every `config-file`, including ones added by these files.
    fn loadIncludes(self: *Loader) Allocator.Error!void {
        var loaded: std.StringHashMapUnmanaged(void) = .empty;
        var i: usize = 0;
        while (i < self.includes.items.len) : (i += 1) {
            const include = self.includes.items[i];
            if (try loaded.fetchPut(self.arena, include.path, {}) != null) {
                log.warn("config-file {s}: cycle detected", .{include.path});
                continue;
            }
            self.loadFile(include.path) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.FileNotFound => if (!include.optional) {
                    log.warn("error opening config-file {s}: {s}", .{ include.path, @errorName(err) });
                },
                error.NotAFile => log.warn("config-file {s}: not reading because it is not a file", .{include.path}),
                else => log.warn("error opening config-file {s}: {s}", .{ include.path, @errorName(err) }),
            };
        }
    }

    fn loadFile(self: *Loader, path: []const u8) !void {
        const file = try std.Io.Dir.openFileAbsolute(self.io, path, .{});
        defer file.close(self.io);
        if ((try file.stat(self.io)).kind != .file) return error.NotAFile;
        log.info("reading configuration file path={s}", .{path});
        var buffer: [4096]u8 = undefined;
        var reader = file.reader(self.io, &buffer);
        const source = reader.interface.allocRemaining(self.arena, .unlimited) catch |err| switch (err) {
            error.ReadFailed => return reader.err.?,
            else => |e| return e,
        };
        try self.parse(path, source);
    }

    /// Applies one file's `key = value` lines; `path` must be absolute.
    fn parse(self: *Loader, path: []const u8, source: []const u8) Allocator.Error!void {
        self.base = std.fs.path.dirname(path) orelse "/";
        const bom = "\xEF\xBB\xBF";
        var lines = std.mem.splitScalar(u8, if (std.mem.startsWith(u8, source, bom)) source[bom.len..] else source, '\n');
        var number: usize = 0;
        while (lines.next()) |raw| {
            number += 1;
            const line = std.mem.trim(u8, raw, whitespace ++ "\r");
            if (line.len == 0 or line[0] == '#') continue;
            var key = line;
            var value: ?[]const u8 = null;
            if (std.mem.indexOfScalar(u8, line, '=')) |idx| {
                key = std.mem.trim(u8, line[0..idx], whitespace);
                var v = std.mem.trim(u8, line[idx + 1 ..], whitespace);
                if (v.len >= 2 and v[0] == '"' and v[v.len - 1] == '"') v = v[1 .. v.len - 1];
                value = v;
            }
            self.set(key, value) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidField => log.warn("{s}:{d}:{s}: unknown field", .{ path, number, key }),
                error.ValueRequired => log.warn("{s}:{d}:{s}: value required", .{ path, number, key }),
                error.InvalidValue => log.warn("{s}:{d}:{s}: invalid value \"{s}\"", .{ path, number, key, value.? }),
            };
        }
    }

    const SetError = Allocator.Error || error{ InvalidField, ValueRequired, InvalidValue };

    /// A null value means the key had no `=`, which only booleans accept.
    fn set(self: *Loader, key: []const u8, value: ?[]const u8) SetError!void {
        if (std.mem.eql(u8, key, "config-file")) {
            var path = value orelse return error.ValueRequired;
            if (path.len == 0) {
                self.includes.clearRetainingCapacity();
                return;
            }
            const optional = path[0] == '?';
            if (optional) path = path[1..];
            if (path.len >= 2 and path[0] == '"' and path[path.len - 1] == '"') path = path[1 .. path.len - 1];
            if (path.len == 0) return;
            try self.includes.append(self.arena, .{ .path = try self.resolvePath(path), .optional = optional });
            return;
        }
        inline for (@typeInfo(Config).@"struct".field_names) |name| {
            if (std.mem.eql(u8, key, comptime kebab(name))) {
                if (value != null and value.?.len == 0) {
                    @field(self.config, name) = @field(Config{}, name);
                } else if (comptime std.mem.eql(u8, name, "font_directory")) {
                    self.config.font_directory = try self.resolvePath(value orelse return error.ValueRequired);
                } else {
                    @field(self.config, name) = try parseValue(@FieldType(Config, name), self.arena, value);
                }
                return;
            }
        }
        return error.InvalidField;
    }

    fn resolvePath(self: *Loader, path: []const u8) SetError![]const u8 {
        if (std.fs.path.isAbsolute(path)) return try self.arena.dupe(u8, path);
        if (std.mem.startsWith(u8, path, "~/")) {
            const home_dir = home(self.environ) orelse {
                log.warn("error expanding home directory for path {s}", .{path});
                return error.InvalidValue;
            };
            return try std.mem.concat(self.arena, u8, &.{ home_dir, path[1..] });
        }
        return try std.fs.path.resolveAlloc(self.arena, &.{ self.base, path });
    }

    /// The directory holding the default files, or null without a home.
    fn configDir(self: *const Loader) Allocator.Error!?[]const u8 {
        // Relative XDG paths are invalid and ignored, per the XDG spec.
        if (self.environ.get("XDG_CONFIG_HOME")) |xdg| if (std.fs.path.isAbsolute(xdg)) {
            return try std.fs.path.join(self.arena, &.{ xdg, "apparition" });
        };
        const home_dir = home(self.environ) orelse return null;
        return try std.fs.path.join(self.arena, &.{ home_dir, ".config", "apparition" });
    }
};

fn home(environ: *const std.process.Environ.Map) ?[]const u8 {
    if (environ.get("HOME")) |dir| if (std.fs.path.isAbsolute(dir)) return dir;
    const entry = std.c.getpwuid(std.c.getuid()) orelse return null;
    const dir = std.mem.span(entry.dir orelse return null);
    return if (std.fs.path.isAbsolute(dir)) dir else null;
}

fn kebab(comptime name: []const u8) []const u8 {
    comptime {
        var result: [name.len]u8 = name[0..name.len].*;
        std.mem.replaceScalar(u8, &result, '_', '-');
        const final = result;
        return &final;
    }
}

fn parseValue(comptime T: type, arena: Allocator, value: ?[]const u8) !T {
    if (T == bool) return parseBool(value orelse "t");
    const v = value orelse return error.ValueRequired;
    return switch (T) {
        []const u8 => try arena.dupe(u8, v),
        ghosttyvt.color.RGB => ghosttyvt.color.RGB.parse(v) catch error.InvalidValue,
        else => switch (@typeInfo(T)) {
            .int => std.fmt.parseInt(T, v, 0) catch error.InvalidValue,
            else => @compileError("unsupported config field type " ++ @typeName(T)),
        },
    };
}

fn parseBool(v: []const u8) !bool {
    inline for (.{ "1", "t", "T", "true" }) |s| if (std.mem.eql(u8, v, s)) return true;
    inline for (.{ "0", "f", "F", "false" }) |s| if (std.mem.eql(u8, v, s)) return false;
    return error.InvalidValue;
}

test "parses Ghostty-style lines" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    try environ.put("HOME", "/home/user");
    var loader: Loader = .{ .arena = arena.allocator(), .io = std.testing.io, .environ = &environ };
    try loader.parse("/etc/apparition/config",
        \\# comment
        \\  font-size=20
        \\font-name = "Iosevka Term"
        \\grapheme-clustering = false
        \\background = #123
        \\scrollback-lines = 0x10
        \\repeat-rate = 40
        \\repeat-rate =
        \\font-directory = fonts
        \\font_size = 99
        \\image-storage-limit = lots
        \\font-name
        \\config-file = ?extra
        \\config-file = ~/more
        \\
    );
    const config = loader.config;
    try std.testing.expectEqual(@as(u8, 20), config.font_size);
    try std.testing.expectEqualStrings("Iosevka Term", config.font_name);
    try std.testing.expect(!config.grapheme_clustering);
    try std.testing.expectEqual(ghosttyvt.color.RGB{ .r = 0x11, .g = 0x22, .b = 0x33 }, config.background);
    try std.testing.expectEqual(@as(usize, 16), config.scrollback_lines);
    try std.testing.expectEqual((Config{}).repeat_rate, config.repeat_rate);
    try std.testing.expectEqualStrings("/etc/apparition/fonts", config.font_directory.?);
    try std.testing.expectEqual((Config{}).image_storage_limit, config.image_storage_limit);
    try std.testing.expectEqual(@as(usize, 2), loader.includes.items.len);
    try std.testing.expectEqualStrings("/etc/apparition/extra", loader.includes.items[0].path);
    try std.testing.expect(loader.includes.items[0].optional);
    try std.testing.expectEqualStrings("/home/user/more", loader.includes.items[1].path);
    try std.testing.expect(!loader.includes.items[1].optional);
}

test "bare boolean keys enable and empty config-file clears includes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    var loader: Loader = .{ .arena = arena.allocator(), .io = std.testing.io, .environ = &environ };
    try loader.parse("/c", "\xEF\xBB\xBFgrapheme-clustering = false\r\ngrapheme-clustering\r\nconfig-file = /a\r\nconfig-file =\r\n");
    try std.testing.expect(loader.config.grapheme_clustering);
    try std.testing.expectEqual(@as(usize, 0), loader.includes.items.len);
}

test "config directory prefers absolute XDG_CONFIG_HOME over HOME" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    try environ.put("HOME", "/home/user");
    var loader: Loader = .{ .arena = arena.allocator(), .io = std.testing.io, .environ = &environ };
    try std.testing.expectEqualStrings("/home/user/.config/apparition", (try loader.configDir()).?);
    try environ.put("XDG_CONFIG_HOME", "");
    try std.testing.expectEqualStrings("/home/user/.config/apparition", (try loader.configDir()).?);
    try environ.put("XDG_CONFIG_HOME", "relative");
    try std.testing.expectEqualStrings("/home/user/.config/apparition", (try loader.configDir()).?);
    try environ.put("XDG_CONFIG_HOME", "/xdg");
    try std.testing.expectEqualStrings("/xdg/apparition", (try loader.configDir()).?);
}

test "loads default files then includes, skipping cycles" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.createDirPath(io, "apparition");
    try tmp.dir.writeFile(io, .{ .sub_path = "apparition/config", .data = "font-size = 10\nrepeat-rate = 5\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "apparition/config.apparition", .data = "font-size = 12\nconfig-file = inc\nconfig-file = ?missing\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "apparition/inc", .data = "repeat-rate = 7\nconfig-file = inc\n" });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    try environ.put("XDG_CONFIG_HOME", try tmp.dir.realPathFileAlloc(io, ".", arena.allocator()));
    const config = try load(arena.allocator(), io, &environ);
    try std.testing.expectEqual(@as(u8, 12), config.font_size);
    try std.testing.expectEqual(@as(u32, 7), config.repeat_rate);
}
