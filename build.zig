const std = @import("std");

pub fn build(b: *std.Build) !void {
	const target = b.standardTargetOptions(.{});
	const optimize = b.standardOptimizeOption(.{});

	const lib = b.addStaticLibrary(.{
		.name = "zqlite",
		.root_source_file = .{ .path = "zqlite.zig" },
		.target = target,
		.optimize = optimize,
	});
	lib.install();

	const lib_test = b.addTest(.{
		.root_source_file = .{ .path = "zqlite.zig" },
		.target = target,
		.optimize = optimize,
	});
	lib_test.linkSystemLibrary("c");
	addLibs(lib_test);

	const run_test = b.addRunArtifact(lib_test);
	run_test.has_side_effects = true;

	const test_step = b.step("test", "Run unit tests");
	test_step.dependOn(&run_test.step);
}

fn addLibs(step: *std.Build.CompileStep) void {
	step.addCSourceFile("lib/sqlite3/sqlite3.h", &[_][]const u8{});
	step.addCSourceFile("lib/sqlite3/sqlite3.c", &[_][]const u8{});
	step.addIncludePath("lib/sqlite3");
}
