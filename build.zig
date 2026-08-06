const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const default_sqlite3_build = [_][]const u8{"-std=c99"};
    const sqlite3_build = b.option([]const []const u8, "sqlite3", "options to use when compiling sqlite3") orelse &default_sqlite3_build;
    const use_llvm = b.option(bool, "use-llvm", "Use Zig's llvm code backend");
    const system_sqlite3 = b.option(bool, "system_sqlite3", "link the system SQLite instead of compiling the bundled amalgamation") orelse false;

    const lib_path = b.path("lib");

    const translate_c = b.addTranslateC(.{
        .root_source_file = if (system_sqlite3)
            b.addWriteFiles().add("zqlite_sqlite3.h", "#include <sqlite3.h>\n")
        else
            b.path("lib/sqlite3.h"),
        .target = target,
        .optimize = optimize,
    });
    if (system_sqlite3) {
        translate_c.linkSystemLibrary("sqlite3", .{});
    }

    const mod_zqlite = b.addModule("zqlite", .{
        .root_source_file = b.path("src/zqlite.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = if (system_sqlite3) true else null,
        .imports = &.{
            .{
                .name = "c",
                .module = translate_c.createModule(),
            }
        },
    });

    if (system_sqlite3) {
        mod_zqlite.linkSystemLibrary("sqlite3", .{});
    } else {
        const mod_sqlite = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,

        });
        mod_sqlite.addIncludePath(lib_path);
        mod_sqlite.addCSourceFile(.{
            .file = b.path("lib/sqlite3.c"),
            .flags = sqlite3_build,
        });

        const lib_sqlite = b.addLibrary(.{
            .linkage = .static,
            .name = "sqlite",
            .root_module = mod_sqlite,
            .use_llvm = use_llvm,
        });
        lib_sqlite.installHeadersDirectory(lib_path, "", .{});

        mod_zqlite.linkLibrary(lib_sqlite);
    }

    const tests = b.addTest(.{
        .root_module = mod_zqlite,
        .test_runner = .{ .path = b.path("test_runner.zig"), .mode = .simple },
        .use_llvm = use_llvm,
    });

    const run_test = b.addRunArtifact(tests);
    run_test.has_side_effects = true;

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_test.step);
}
