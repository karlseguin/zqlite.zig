const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const default_sqlite3_build = [_][]const u8{"-std=c99"};
    const sqlite3_build = b.option([]const []const u8, "sqlite3", "options to use when compiling sqlite3") orelse &default_sqlite3_build;

    const lib_path = b.path("lib");

    const module = b.addModule("zqlite", .{
        .root_source_file = b.path("src/zqlite.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "sqlite",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    lib.addIncludePath(lib_path);
    lib.installHeadersDirectory(lib_path, "", .{});
    lib.addCSourceFile(.{
        .file = b.path("lib/sqlite3.c"),
        .flags = sqlite3_build,
    });

    module.linkLibrary(lib);

    const tests = b.addTest(.{
        .root_module = module,
        .test_runner = .{ .path = b.path("test_runner.zig"), .mode = .simple },
    });
    tests.linkLibrary(lib);

    const run_test = b.addRunArtifact(tests);
    run_test.has_side_effects = true;

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_test.step);
}
