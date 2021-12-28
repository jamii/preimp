const builtin = @import("builtin");
const std = @import("std");

pub fn build(b: *std.build.Builder) !void {
    const mode = b.standardReleaseOptions();
    var target = b.standardTargetOptions(.{});
    target.setGnuLibCVersion(2, 28, 0);

    const bin = b.addExecutable("preimp", "./preimp.zig");
    bin.setMainPkgPath("./");
    bin.linkLibC();
    bin.addIncludeDir("deps/sqlite-amalgamation-3370000/");
    bin.addCSourceFile("deps/sqlite-amalgamation-3370000/sqlite3.c", &[_][]const u8{"-std=c99"});
    bin.setBuildMode(mode);
    bin.setTarget(target);
    bin.install();

    const bin_step = b.step("build", "Build");
    bin_step.dependOn(&bin.step);

    const run = bin.run();
    const run_step = b.step("run", "Run");
    run_step.dependOn(&run.step);
}
