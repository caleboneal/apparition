const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Deps
    const ghostty = b.dependency("ghostty", .{});
    const c_graphics = b.addTranslateC(.{
        .root_source_file = b.path("src/c_graphics.h"),
        .target = target,
        .optimize = optimize,
    });

    addPkgConfigIncludes(b, c_graphics, "libdrm");
    addPkgConfigIncludes(b, c_graphics, "gbm");
    addPkgConfigIncludes(b, c_graphics, "egl");
    addPkgConfigIncludes(b, c_graphics, "glesv2");
    addPkgConfigIncludes(b, c_graphics, "freetype2");
    addPkgConfigIncludes(b, c_graphics, "libinput");
    addPkgConfigIncludes(b, c_graphics, "libudev");
    addPkgConfigIncludes(b, c_graphics, "xkbcommon");

    const exe = b.addExecutable(.{
        .name = "apparition",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    exe.root_module.addImport("ghostty-vt", ghostty.module("ghostty-vt"));
    exe.root_module.addCSourceFile(.{ .file = b.path("src/c_graphics.c") });

    exe.root_module.linkSystemLibrary("gbm", .{});
    exe.root_module.linkSystemLibrary("glesv2", .{});
    exe.root_module.linkSystemLibrary("EGL", .{});
    exe.root_module.linkSystemLibrary("freetype2", .{});
    exe.root_module.linkSystemLibrary("input", .{});
    exe.root_module.linkSystemLibrary("libudev", .{ .use_pkg_config = .force });
    exe.root_module.linkSystemLibrary("xkbcommon", .{});
    exe.root_module.linkSystemLibrary("drm", .{});

    exe.root_module.addImport("c_graphics", c_graphics.createModule());

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the application");
    run_step.dependOn(&run_cmd.step);
}

/// Helper function to parse pkg-config include directories and register them
fn addPkgConfigIncludes(b: *std.Build, translate_c: *std.Build.Step.TranslateC, lib_name: []const u8) void {
    // Run pkg-config to extract compilation flags for the given package
    const flags_raw = b.run(&.{ "pkg-config", "--cflags-only-I", lib_name });
    const flags = std.mem.trim(u8, flags_raw, " \n\r\t");
    var iter = std.mem.splitSequence(u8, flags, " ");

    while (iter.next()) |flag| {
        // Strip out the leading "-I" to get the raw path string
        if (std.mem.startsWith(u8, flag, "-I")) {
            const include_path = flag[2..];
            translate_c.addIncludePath(.{ .cwd_relative = include_path });
        }
    }
}
