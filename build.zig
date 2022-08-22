const std = @import("std");
const imgui = @import("deps/zig-imgui/zig-imgui/imgui_build.zig");

pub fn build(b: *std.build.Builder) !void {
    const mode = b.standardReleaseOptions();
    var target = b.standardTargetOptions(.{});

    const test_end_to_end = addBin(b, mode, target, "test_end_to_end", "Run an end-to-end test file", "./test/end_to_end.zig");
    const default_args = [1][]const u8{"./test/end_to_end.test"};
    test_end_to_end.run.addArgs(b.args orelse &default_args);

    const test_unit_bin = b.addTestExe("test_unit", "lib/preimp.zig");
    commonSetup(test_unit_bin, mode, target);
    const test_unit_run = test_unit_bin.run();
    const test_unit_step = b.step("test_unit", "Run unit tests");
    test_unit_step.dependOn(&test_unit_run.step);

    const test_step = b.step("test", "Run all tests");
    //// Make sure that run.zig builds
    //test_step.dependOn(&run.bin.step);
    test_step.dependOn(test_end_to_end.step);
    test_step.dependOn(test_unit_step);

    const wasm = b.addSharedLibrary("preimp", "./wasm/wasm.zig", .unversioned);
    wasm.setBuildMode(mode);
    wasm.setTarget(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });
    wasm.setMainPkgPath("./");
    wasm.install();

    const wasm_step = b.step("wasm", "Build wasm (zig-out/lib/preimp.wasm)");
    wasm_step.dependOn(&wasm.step);

    const native = addBin(b, mode, target, "run_native", "Run the native gui", "./native/native.zig");
    imgui.link(native.bin);
    linkGlfw(native.bin, target);
    linkGlad(native.bin, target);
    native.bin.install();
}

fn addBin(
    b: *std.build.Builder,
    mode: std.builtin.Mode,
    target: std.zig.CrossTarget,
    name: []const u8,
    description: []const u8,
    exe_path: []const u8,
) struct {
    bin: *std.build.LibExeObjStep,
    run: *std.build.RunStep,
    step: *std.build.Step,
} {
    const bin = b.addExecutable(name, exe_path);
    commonSetup(bin, mode, target);
    const run = bin.run();
    const step = b.step(name, description);
    step.dependOn(&run.step);
    return .{ .bin = bin, .run = run, .step = step };
}

fn commonSetup(
    bin: *std.build.LibExeObjStep,
    mode: std.builtin.Mode,
    target: std.zig.CrossTarget,
) void {
    // stage2 doesn't like zig-imgui
    bin.use_stage1 = true;
    bin.setMainPkgPath("./");
    addDeps(bin);
    bin.setBuildMode(mode);
    bin.setTarget(target);
}

fn getRelativePath() []const u8 {
    comptime var src: std.builtin.SourceLocation = @src();
    return std.fs.path.dirname(src.file).? ++ std.fs.path.sep_str;
}

pub fn addDeps(
    bin: *std.build.LibExeObjStep,
) void {
    bin.linkLibC();
    //bin.addIncludeDir(getRelativePath() ++ "deps/sqlite-amalgamation-3370000/");
    //bin.addCSourceFile(getRelativePath() ++ "deps/sqlite-amalgamation-3370000/sqlite3.c", &[_][]const u8{"-std=c99"});
}

fn linkGlad(exe: *std.build.LibExeObjStep, target: std.zig.CrossTarget) void {
    _ = target;
    exe.addIncludeDir("native/imgui_impl/");
    exe.addCSourceFile("native/imgui_impl/glad.c", &[_][]const u8{"-std=c99"});
    //exe.linkSystemLibrary("opengl");
}

fn linkGlfw(exe: *std.build.LibExeObjStep, target: std.zig.CrossTarget) void {
    if (target.isWindows()) {
        exe.addObjectFile(if (target.getAbi() == .msvc) "native/imgui_impl/glfw3.lib" else "native/imgui_impl/libglfw3.a");
        exe.linkSystemLibrary("gdi32");
        exe.linkSystemLibrary("shell32");
    } else {
        exe.linkSystemLibrary("glfw");
    }
}
