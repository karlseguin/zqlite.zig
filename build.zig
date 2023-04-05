const std = @import("std");

pub fn build(b: *std.Build) !void {
	const target = b.standardTargetOptions(.{});
	const optimize = b.standardOptimizeOption(.{});

	const default_sqlite3_build = [_][]const u8{"-std=c99"};
	var sqlite3_build = b.option([]const []const u8, "sqlite3", "options to use when compiling sqlite3") orelse &default_sqlite3_build;

	_ = b.addModule("zqlite", .{
		.source_file = .{ .path = "zqlite.zig" },
	});

	const lib_test = b.addTest(.{
		.root_source_file = .{ .path = "zqlite.zig" },
		.target = target,
		.optimize = optimize,
	});
	lib_test.addCSourceFile("lib/sqlite3/sqlite3.c", sqlite3_build);
	lib_test.addIncludePath("lib/sqlite3/");
	lib_test.linkLibC();

	const run_test = b.addRunArtifact(lib_test);
	run_test.has_side_effects = true;

	const test_step = b.step("test", "Run unit tests");
	test_step.dependOn(&run_test.step);
}
