const builtin = @import("builtin");
const std = @import("std");
const preimp = @import("../lib/preimp.zig");
const u = preimp.util;
const imgui = @import("imgui");
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
        //glfw.glfwWindowHint(glfw.GLFW_OPENGL_PROFILE, glfw.GLFW_OPENGL_CORE_PROFILE);  // 3.2+ only
        //glfw.glfwWindowHint(glfw.GLFW_OPENGL_FORWARD_COMPAT, gl.GL_TRUE);            // 3.0+ only
    }

    // Create window with graphics context
    const window = glfw.glfwCreateWindow(1280, 720, "Dear ImGui GLFW+OpenGL3 example", null, null) orelse return error.GlfwCreateWindowFailed;
    glfw.glfwMakeContextCurrent(window);
    glfw.glfwSwapInterval(1); // Enable vsync

    // Initialize OpenGL loader
    if (gl.gladLoadGL() == 0)
        return error.GladLoadGLFailed;

    // Setup Dear ImGui context
    imgui.CHECKVERSION();
    _ = imgui.CreateContext();
    const io = imgui.GetIO();
    //io.ConfigFlags |= imgui.ConfigFlags.NavEnableKeyboard;     // Enable Keyboard Controls
    //io.ConfigFlags |= imgui.ConfigFlags.NavEnableGamepad;      // Enable Gamepad Controls

    // Setup Dear ImGui style
    imgui.StyleColorsDark();
    //imgui.StyleColorsClassic();

    // Setup Platform/Renderer bindings
    _ = impl_glfw.InitForOpenGL(window, true);
    _ = impl_gl3.Init(glsl_version);

    // Load Fonts
    const fira_code_ttf = try allocator.dupe(u8, @embedFile("./Fira_Code_v5.2/ttf/FiraCode-Regular.ttf"));
    defer allocator.free(fira_code_ttf);
    const fira_code = io.Fonts.?.AddFontFromMemoryTTF(fira_code_ttf.ptr, @intCast(c_int, fira_code_ttf.len), 16.0);
    std.debug.assert(fira_code != null);

    // Our state
    var show_demo_window = true;
    var show_another_window = false;
    var clear_color = imgui.Vec4{ .x = 0.45, .y = 0.55, .z = 0.60, .w = 1.00 };
    var slider_value: f32 = 0;
    var counter: i32 = 0;

    // Main loop
    while (glfw.glfwWindowShouldClose(window) == 0) {
        glfw.glfwPollEvents();

        // Start the Dear ImGui frame
        impl_gl3.NewFrame();
        impl_glfw.NewFrame();
        imgui.NewFrame();

        // 1. Show the big demo window (Most of the sample code is in imgui.ShowDemoWindow()! You can browse its code to learn more about Dear ImGui!).
        if (show_demo_window)
            imgui.ShowDemoWindowExt(&show_demo_window);

        // 2. Show a simple window that we create ourselves. We use a Begin/End pair to created a named window.
        {
            _ = imgui.Begin("Hello, world!"); // Create a window called "Hello, world!" and append into it.

            imgui.Text("This is some useful text."); // Display some text (you can use a format strings too)
            _ = imgui.Checkbox("Demo Window", &show_demo_window); // Edit bools storing our window open/close state
            _ = imgui.Checkbox("Another Window", &show_another_window);

            _ = imgui.SliderFloat("float", &slider_value, 0.0, 1.0); // Edit 1 float using a slider from 0.0 to 1.0
            _ = imgui.ColorEdit3("clear color", @ptrCast(*[3]f32, &clear_color)); // Edit 3 floats representing a color

            if (imgui.Button("Button")) // Buttons return true when clicked (most widgets return true when edited/activated)
                counter += 1;
            imgui.SameLine();
            imgui.Text("counter = %d", counter);

            imgui.Text("Application average %.3f ms/frame (%.1f FPS)", 1000.0 / imgui.GetIO().Framerate, imgui.GetIO().Framerate);
            imgui.End();
        }

        // 3. Show another simple window.
        if (show_another_window) {
            _ = imgui.BeginExt("Another Window", &show_another_window, .{});
            imgui.Text("Hello from another window!");
            if (imgui.Button("Close Me"))
                show_another_window = false;
            imgui.End();
        }

        // Rendering
        imgui.Render();
        var display_w: c_int = 0;
        var display_h: c_int = 0;
        glfw.glfwGetFramebufferSize(window, &display_w, &display_h);
        gl.glViewport(0, 0, display_w, display_h);
        gl.glClearColor(
            clear_color.x * clear_color.w,
            clear_color.y * clear_color.w,
            clear_color.z * clear_color.w,
            clear_color.w,
        );
        gl.glClear(gl.GL_COLOR_BUFFER_BIT);
        impl_gl3.RenderDrawData(imgui.GetDrawData());

        glfw.glfwSwapBuffers(window);
    }

    // Cleanup
    impl_gl3.Shutdown();
    impl_glfw.Shutdown();
    imgui.DestroyContext();

    glfw.glfwDestroyWindow(window);
    glfw.glfwTerminate();
}
