const builtin = @import("builtin");
const std = @import("std");
const preimp = @import("../lib/preimp.zig");
const u = preimp.util;
const ig = @import("imgui");
const impl_glfw = @import("./imgui_impl/imgui_impl_glfw.zig");
const impl_gl3 = @import("./imgui_impl/imgui_impl_opengl3.zig");
const glfw = @import("./imgui_impl/glfw.zig");
const gl = @import("./imgui_impl/gl.zig");

const is_darwin = builtin.os.tag.isDarwin();

fn glfw_error_callback(err: c_int, description: ?[*:0]const u8) callconv(.C) void {
    std.debug.print("Glfw Error {}: {any}\n", .{ err, description });
}

const allocator = std.heap.c_allocator;

pub fn main() !void {
    // Setup window
    _ = glfw.glfwSetErrorCallback(glfw_error_callback);
    if (glfw.glfwInit() == 0)
        return error.GlfwInitFailed;

    // Decide GL+GLSL versions
    const glsl_version = if (is_darwin) "#version 150" else "#version 130";
    if (is_darwin) {
        // GL 3.2 + GLSL 150
        glfw.glfwWindowHint(glfw.GLFW_CONTEXT_VERSION_MAJOR, 3);
        glfw.glfwWindowHint(glfw.GLFW_CONTEXT_VERSION_MINOR, 2);
        glfw.glfwWindowHint(glfw.GLFW_OPENGL_PROFILE, glfw.GLFW_OPENGL_CORE_PROFILE); // 3.2+ only
        glfw.glfwWindowHint(glfw.GLFW_OPENGL_FORWARD_COMPAT, gl.GL_TRUE); // Required on Mac
    } else {
        // GL 3.0 + GLSL 130
        glfw.glfwWindowHint(glfw.GLFW_CONTEXT_VERSION_MAJOR, 3);
        glfw.glfwWindowHint(glfw.GLFW_CONTEXT_VERSION_MINOR, 0);
    }

    // Create window with graphics context
    const window = glfw.glfwCreateWindow(1280, 720, "Dear ImGui GLFW+OpenGL3 example", null, null) orelse return error.GlfwCreateWindowFailed;
    glfw.glfwMakeContextCurrent(window);
    glfw.glfwSwapInterval(1); // Enable vsync

    // Initialize OpenGL loader
    if (gl.gladLoadGL() == 0)
        return error.GladLoadGLFailed;

    // Setup Dear ImGui context
    ig.CHECKVERSION();
    _ = ig.CreateContext();
    const io = ig.GetIO();

    // Setup Dear ImGui style
    ig.StyleColorsDark();

    // Setup Platform/Renderer bindings
    _ = impl_glfw.InitForOpenGL(window, true);
    _ = impl_gl3.Init(glsl_version);

    // Load Fonts
    const fira_code_ttf = try allocator.dupe(u8, @embedFile("./Fira_Code_v5.2/ttf/FiraCode-Regular.ttf"));
    defer allocator.free(fira_code_ttf);
    const fira_code = io.Fonts.?.AddFontFromMemoryTTF(fira_code_ttf.ptr, @intCast(c_int, fira_code_ttf.len), 16.0);
    std.debug.assert(fira_code != null);

    // Main loop
    var show_window = true;
    while (glfw.glfwWindowShouldClose(window) == 0) {
        glfw.glfwPollEvents();

        // Start the Dear ImGui frame
        impl_gl3.NewFrame();
        impl_glfw.NewFrame();
        ig.NewFrame();

        // Size main window
        const viewport = ig.GetMainViewport().?;
        ig.SetNextWindowPos(viewport.Pos);
        ig.SetNextWindowSize(viewport.Size);

        // Main loop
        if (show_window) {
            _ = ig.BeginExt(
                "The window",
                &show_window,
                (ig.WindowFlags{
                    .NoBackground = true,
                    .AlwaysAutoResize = true,
                    .NoSavedSettings = true,
                    .NoFocusOnAppearing = true,
                }).with(ig.WindowFlags.NoDecoration).with(ig.WindowFlags.NoNav),
            );

            ig.Text("Application average %.3f ms/frame (%.1f FPS)", 1000.0 / ig.GetIO().Framerate, ig.GetIO().Framerate);

            ig.End();
        }

        // Rendering
        ig.Render();
        var display_w: c_int = 0;
        var display_h: c_int = 0;
        glfw.glfwGetFramebufferSize(window, &display_w, &display_h);
        gl.glViewport(0, 0, display_w, display_h);
        const clear_color = ig.Vec4{ .x = 0.45, .y = 0.55, .z = 0.60, .w = 1.00 };
        gl.glClearColor(
            clear_color.x * clear_color.w,
            clear_color.y * clear_color.w,
            clear_color.z * clear_color.w,
            clear_color.w,
        );
        gl.glClear(gl.GL_COLOR_BUFFER_BIT);
        impl_gl3.RenderDrawData(ig.GetDrawData());

        glfw.glfwSwapBuffers(window);
    }

    // Cleanup
    impl_gl3.Shutdown();
    impl_glfw.Shutdown();
    ig.DestroyContext();

    glfw.glfwDestroyWindow(window);
    glfw.glfwTerminate();
}
