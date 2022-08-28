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

fn glfwErrorCallback(err: c_int, description: ?[*:0]const u8) callconv(.C) void {
    std.debug.print("Glfw Error {}: {any}\n", .{ err, description });
}

const allocator = std.heap.c_allocator;

pub fn main() !void {
    // Setup window
    _ = glfw.glfwSetErrorCallback(glfwErrorCallback);
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
    const window = glfw.glfwCreateWindow(1280, 720, "preimp", null, null) orelse
        return error.GlfwCreateWindowFailed;
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
    const style = ig.GetStyle().?;
    style.FrameBorderSize = 2;
    style.Colors[@enumToInt(ig.Col.Text)] = ig.Color.initHSVA(0, 0.0, 0.9, 1.0).Value;
    style.Colors[@enumToInt(ig.Col.Border)] = ig.Color.initHSVA(0, 0.0, 0.9, 1.0).Value;
    style.Colors[@enumToInt(ig.Col.TextDisabled)] = ig.Color.initHSVA(0, 0.0, 0.6, 1.0).Value;
    style.Colors[@enumToInt(ig.Col.WindowBg)] = ig.Color.initHSVA(0, 0, 0.2, 1.0).Value;
    style.Colors[@enumToInt(ig.Col.ChildBg)] = ig.Color.initHSVA(0, 0, 0.2, 1.0).Value;
    style.Colors[@enumToInt(ig.Col.FrameBg)] = ig.Color.initHSVA(0, 0, 0.2, 1.0).Value;

    // Setup Platform/Renderer bindings
    _ = impl_glfw.InitForOpenGL(window, true);
    _ = impl_gl3.Init(glsl_version);

    // Load Fonts
    const fira_code_ttf = try allocator.dupe(u8, @embedFile("./Fira_Code_v5.2/ttf/FiraCode-Regular.ttf"));
    defer allocator.free(fira_code_ttf);
    const fira_code = io.Fonts.?.AddFontFromMemoryTTF(fira_code_ttf.ptr, @intCast(c_int, fira_code_ttf.len), 16.0);
    std.debug.assert(fira_code != null);

    // Global state
    var show_window = true;
    var state = State{
        .selection = null,
        .input = try allocator.dupe(preimp.Value, &[1]preimp.Value{preimp.Value.fromInner(.nil)}),
        .output_arena = u.ArenaAllocator.init(allocator),
        .output = preimp.Value.fromInner(.nil),
        .hovered_path = null,
        .last_hovered_origin = null,
    };

    // Initial example
    state.selection = .{
        .path = try allocator.dupe(usize, &[1]usize{0}),
        .origin = try allocator.dupe(usize, &[1]usize{0}),
        .source = try allocator.dupeZ(u8, "{{[1 2] [3 4] [5 6] #foo (+ 7 8)} {\"a\" \"b\"}}"),
        .parsed = try allocator.dupe(preimp.Value, &[1]preimp.Value{preimp.Value.fromInner(.nil)}),
    };
    try parse(&state, &state.selection.?);
    try completeSelection(&state, &state.selection.?);
    try evaluate(&state);

    // Main loop
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

            try draw(&state);

            ig.End();
        }

        // Rendering
        ig.Render();
        var display_w: c_int = 0;
        var display_h: c_int = 0;
        glfw.glfwGetFramebufferSize(window, &display_w, &display_h);
        gl.glViewport(0, 0, display_w, display_h);
        const clear_color = style.Colors[@enumToInt(ig.Col.WindowBg)];
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

const State = struct {
    selection: ?Selection,
    input: []preimp.Value,
    output_arena: u.ArenaAllocator,
    output: preimp.Value,
    hovered_path: ?[]const usize,
    last_hovered_origin: ?[]const usize,

    fn deinit(self: *State) void {
        allocator.free(self.source);
        self.output_arena.deinit();
    }
};

const Selection = struct {
    path: []const usize,
    origin: []const usize,
    // actually null-terminated, but maybe not at this length
    source: []u8,
    parsed: []preimp.Value,
};

fn draw(state: *State) !void {
    state.last_hovered_origin = null;
    if (state.hovered_path) |hovered_path| {
        if (hovered_path[0] == 1) {
            const last_hovered_value = getValueAtPath(state.output, hovered_path[1..]);
            if (last_hovered_value.getOrigin()) |origin| {
                state.last_hovered_origin = (try origin.toPath(allocator)).?;
            }
        }
    }

    state.hovered_path = null;

    var path = u.ArrayList(usize).init(allocator);
    defer path.deinit();

    {
        ig.BeginGroup();
        defer ig.EndGroup();
        ig.Text("INPUT:");
        ig.NewLine();
        try pathPush(&path, 0);
        defer pathPop(&path);
        for (state.input) |expr, i| {
            try pathPush(&path, i);
            defer pathPop(&path);
            try drawValue(state, expr, &path, .edit_source);
        }
    }

    {
        ig.SameLine();
        ig.BeginGroup();
        ig.Text("OUTPUT:");
        ig.NewLine();
        defer ig.EndGroup();
        try pathPush(&path, 1);
        defer pathPop(&path);
        try drawValue(state, state.output, &path, .edit_origin);
    }

    if (state.hovered_path) |hovered_path| {
        ig.SameLine();
        ig.BeginGroup();
        defer ig.EndGroup();
        ig.Text("DEBUG:");
        ig.NewLine();
        try pathPush(&path, 2);
        defer pathPop(&path);
        const hovered_value = switch (hovered_path[0]) {
            0 => getValueAtPath(state.input[hovered_path[1]], hovered_path[2..]),
            1 => getValueAtPath(state.output, hovered_path[1..]),
            else => unreachable,
        };
        const meta = preimp.Value.fromInner(.{ .map = hovered_value.meta });
        try drawValue(state, meta, &path, .none);
    }
}

const Interaction = enum {
    edit_source,
    edit_origin,
    none,
};

fn drawValue(state: *State, value: preimp.Value, path: *u.ArrayList(usize), interaction: Interaction) error{OutOfMemory}!void {
    if (interaction != .none) {
        if (state.selection) |*selection| {
            if (u.deepEqual(selection.path, path.items)) {
                {
                    ig.PushID_Str("selection");
                    defer ig.PopID();
                    try drawSelection(state, selection);
                }
                ig.SameLine();
                {
                    ig.PushID_Str("parsed");
                    defer ig.PopID();
                    ig.BeginGroup();
                    for (selection.parsed) |parsed_value, i| {
                        try pathPush(path, i);
                        defer pathPop(path);
                        try drawValue(state, parsed_value, path, .none);
                    }
                    ig.EndGroup();
                }
                return;
            }
        }
    }
    ig.BeginGroup();
    switch (value.inner) {
        .nil => ig.Text("nil"),
        .@"true" => ig.Text("true"),
        .@"false" => ig.Text("false"),
        .symbol => |symbol| ig.Text(try allocator.dupeZ(u8, symbol)),
        .string => |string| {
            const text = u.formatZ(allocator, "\"{}\"", .{std.zig.fmtEscapes(string)});
            ig.Text(text);
        },
        .number => |number| {
            const text = u.formatZ(allocator, "{d}", .{number});
            ig.Text(text);
        },
        .list => |list| {
            OpenBrace("(");
            defer CloseBrace(")");
            for (list) |elem, i| {
                try pathPush(path, i);
                defer pathPop(path);
                try drawValue(state, elem, path, interaction);
            }
        },
        .vec => |vec| {
            OpenBrace("[");
            defer CloseBrace("]");
            for (vec) |elem, i| {
                try pathPush(path, i);
                defer pathPop(path);
                try drawValue(state, elem, path, interaction);
            }
        },
        .map => |map| {
            OpenBrace("{");
            defer CloseBrace("}");
            for (map) |key_val, i| {
                if (i != 0)
                    ig.NewLine();
                try pathPush(path, i);
                defer pathPop(path);
                {
                    try pathPush(path, 0);
                    defer pathPop(path);
                    try drawValue(state, key_val.key, path, interaction);
                }
                {
                    try pathPush(path, 1);
                    defer pathPop(path);
                    try drawValue(state, key_val.val, path, interaction);
                }
            }
        },
        .tagged => |tagged| {
            OpenBrace("#");
            defer CloseBrace("");
            {
                try pathPush(path, 0);
                defer pathPop(path);
                try drawValue(state, tagged.key.*, path, interaction);
            }
            {
                try pathPush(path, 1);
                defer pathPop(path);
                OpenBrace(" ");
                defer CloseBrace("");
                try drawValue(state, tagged.val.*, path, interaction);
            }
        },
        .builtin => |builtin_| ig.Text(try allocator.dupeZ(u8, std.meta.tagName(builtin_))),
        .fun => ig.Text("<fn>"),
        .actions => |actions| {
            OpenBrace("(");
            defer CloseBrace(")");
            ig.Text("do");
            for (actions) |action, action_ix| {
                try pathPush(path, action_ix);
                defer pathPop(path);
                ig.Text("put-at!");
                {
                    try pathPush(path, 0);
                    defer pathPop(path);
                    OpenBrace("[");
                    defer CloseBrace("]");
                    for (action.origin) |origin_elem, origin_elem_ix| {
                        try pathPush(path, origin_elem_ix);
                        defer pathPop(path);
                        try drawValue(state, origin_elem, path, interaction);
                    }
                }
                {
                    try pathPush(path, 1);
                    defer pathPop(path);
                    try drawValue(state, action.new, path, interaction);
                }
            }
        },
    }
    ig.EndGroup();

    if (ig.IsItemHovered() and state.hovered_path == null) {
        if (ig.IsMouseClicked(.Left) and
            (interaction == .edit_source or
            (interaction == .edit_origin and value.getOrigin() != null)))
        {
            if (state.selection) |*selection| {
                try completeSelection(state, selection);
            }
            var source = u.ArrayList(u8).init(allocator);
            defer source.deinit();
            preimp.Value.dumpInto(source.writer(), 0, value) catch |err|
                switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => unreachable,
            };
            try source.append(0);

            state.selection = .{
                .path = try allocator.dupe(usize, path.items),
                .origin = switch (interaction) {
                    .edit_source => try allocator.dupe(usize, path.items[1..]),
                    .edit_origin => (try value.getOrigin().?.toPath(allocator)).?,
                    .none => unreachable,
                },
                .source = source.toOwnedSlice(),
                .parsed = try allocator.dupe(preimp.Value, &[1]preimp.Value{value}),
            };
        }
        ig.GetBackgroundDrawList().?.AddRectFilled(
            ig.GetItemRectMin(),
            ig.GetItemRectMax(),
            ig.Color.initHSVA(0, 0.0, 0.9, 0.3).packABGR(),
        );
        state.hovered_path = try allocator.dupe(usize, path.items);
    }

    if (state.last_hovered_origin != null and path.items[0] == 0 and u.deepEqual(state.last_hovered_origin.?, path.items[1..])) {
        ig.GetBackgroundDrawList().?.AddRectFilled(
            ig.GetItemRectMin(),
            ig.GetItemRectMax(),
            ig.Color.initHSVA(0, 0.0, 0.9, 0.3).packABGR(),
        );
    }
}

fn pathPush(path: *u.ArrayList(usize), elem: usize) !void {
    _ = ig.PushID_Int(@intCast(c_int, elem));
    try path.append(elem);
}

fn pathPop(path: *u.ArrayList(usize)) void {
    _ = ig.PopID();
    _ = path.pop();
}

fn OpenBrace(label: [:0]const u8) void {
    ig.Text(label);
    ig.SameLine();
    ig.SetCursorPosX(ig.GetCursorPosX() - ig.GetStyle().?.ItemSpacing.x);
    ig.BeginGroup();
}

fn CloseBrace(label: [:0]const u8) void {
    ig.EndGroup();
    const closing_y = ig.GetCursorPosY() - ig.GetTextLineHeightWithSpacing();
    ig.SameLine();
    const closing_x = ig.GetCursorPosX() - ig.GetStyle().?.ItemSpacing.x;
    ig.SetCursorPosX(closing_x);
    ig.SetCursorPosY(closing_y);
    ig.Text(label);
}

fn drawSelection(state: *State, selection: *Selection) error{OutOfMemory}!void {
    ig.BeginGroup();

    var num_lines: usize = 1;
    {
        const source = std.mem.sliceTo(selection.source, 0);
        for (source) |char| {
            if (char == '\n') {
                num_lines += 1;
            }
        }
    }

    const UserData = struct {
        state: *State,
        selection: *Selection,
    };
    var user_data = UserData{
        .state = state,
        .selection = selection,
    };
    ig.SetKeyboardFocusHere();
    const source_changed = ig.InputTextMultilineExt(
        "##source",
        selection.source.ptr,
        selection.source.len,
        .{
            .x = 0,
            .y = @intToFloat(f32, num_lines) * ig.GetTextLineHeight() +
                2 * ig.GetStyle().?.FramePadding.y +
                2,
        },
        .{
            .CallbackResize = true,
        },
        struct {
            fn resize(data: [*c]ig.InputTextCallbackData) callconv(.C) c_int {
                const my_user_data = @ptrCast(*UserData, @alignCast(@alignOf(UserData), data.*.UserData));
                if (data.*.EventFlag.CallbackResize) {
                    my_user_data.selection.source = allocator.realloc(my_user_data.selection.source, @intCast(usize, data.*.BufSize)) catch unreachable;
                    data.*.Buf = my_user_data.selection.source.ptr;
                    return 0;
                }
                // We didn't ask for any other events
                unreachable;
            }
        }.resize,
        @ptrCast(*anyopaque, &user_data),
    );

    if (source_changed)
        try parse(state, selection);

    ig.EndGroup();
    if (ig.IsItemHovered() and state.hovered_path == null) {
        state.hovered_path = try allocator.dupe(usize, selection.path);
    }

    if (ig.IsKeyPressed(.Escape))
        try cancelSelection(state, selection);
    if (ig.IsKeyPressed(.Enter) and ig.IsKeyDown(.ModCtrl))
        try completeSelection(state, selection);
}

fn parse(state: *State, selection: *Selection) !void {
    _ = state;
    // TODO duped source is leaked
    var parser = try preimp.Parser.init(allocator, try allocator.dupeZ(u8, selection.source));
    // TODO old selection.parsed is leaked
    selection.parsed = try parser.parseExprs(null, .eof);
}

fn completeSelection(state: *State, selection: *Selection) !void {
    try replaceValues(&state.input, selection.origin, selection.parsed);
    try evaluate(state);
    try cancelSelection(state, selection);
}

fn cancelSelection(state: *State, selection: *Selection) !void {
    _ = selection;
    // TODO free selection - probably later in frame
    state.selection = null;
}

fn replaceValue(input: *preimp.Value, path: []const usize, values: []preimp.Value) error{OutOfMemory}!void {
    std.debug.assert(path.len > 0);
    switch (input.inner) {
        .nil, .@"true", .@"false", .symbol, .string, .number, .builtin, .fun => unreachable,
        .list => |*list| {
            try replaceValues(list, path, values);
        },
        .vec => |*vec| {
            try replaceValues(vec, path, values);
        },
        .map => |*map| {
            std.debug.assert(path.len > 1);
            if (path.len == 2) {
                var elems = u.ArrayList(preimp.Value).init(allocator);
                defer elems.deinit();
                for (map.*) |key_val| {
                    try elems.append(key_val.key);
                    try elems.append(key_val.val);
                }
                const ix = 2 * path[0] + path[1];
                _ = elems.orderedRemove(ix);
                try elems.insertSlice(ix, values);
                if (elems.items.len % 2 != 0) {
                    try elems.insert(
                        ix + values.len,
                        try preimp.Value.format(allocator,
                            \\ #"error" #"odd number of map elems inserted" nil
                        , .{}),
                    );
                }
                var key_vals = u.ArrayList(preimp.KeyVal).init(allocator);
                defer key_vals.deinit();
                var i: usize = 0;
                while (i < elems.items.len) : (i += 2) {
                    try key_vals.append(.{
                        .key = elems.items[i],
                        .val = elems.items[i + 1],
                    });
                }
                map.* = key_vals.toOwnedSlice();
            } else {
                const key_val = &map.*[path[0]];
                const elem = switch (path[1]) {
                    0 => &key_val.key,
                    1 => &key_val.val,
                    else => unreachable,
                };
                try replaceValue(elem, path[2..], values);
            }
        },
        .tagged => |tagged| {
            const elem = switch (path[0]) {
                0 => tagged.key,
                1 => tagged.val,
                else => unreachable,
            };
            if (path.len == 1) {
                // TODO handle this case properly
                if (values.len > 0)
                    elem.* = values[0];
            } else {
                try replaceValue(elem, path[1..], values);
            }
        },
        .actions => |actions| {
            // TODO handle replace properly later
            const action = &actions[path[0]];
            switch (path[1]) {
                0 => {
                    const elem = &action.origin[path[2]];
                    try replaceValue(elem, path[3..], values);
                },
                1 => {
                    try replaceValue(&action.new, path[2..], values);
                },
                else => unreachable,
            }
        },
    }
}

fn replaceValues(inputs: *[]preimp.Value, path: []const usize, values: []preimp.Value) !void {
    if (path.len == 0) {
        inputs.* = values;
    } else if (path.len == 1) {
        inputs.* = try std.mem.concat(allocator, preimp.Value, &.{
            inputs.*[0..path[0]],
            values,
            inputs.*[path[0] + 1 ..],
        });
    } else {
        try replaceValue(&inputs.*[path[0]], path[1..], values);
    }
}

fn evaluate(state: *State) !void {
    var origin = u.ArrayList(preimp.Value).init(allocator);
    defer origin.deinit();
    for (state.input) |*expr, i| {
        try origin.append(try preimp.Value.fromZig(allocator, i));
        defer _ = origin.pop();
        _ = try expr.setOriginRecursively(allocator, &origin);
    }
    state.output_arena.deinit();
    state.output_arena = u.ArenaAllocator.init(allocator);
    var evaluator = preimp.Evaluator.init(state.output_arena.allocator());
    state.output = try evaluator.evalExprs(state.input);
}

fn getValueAtPath(output: preimp.Value, path: []const usize) preimp.Value {
    if (path.len == 0) {
        return output;
    } else switch (output.inner) {
        .nil, .@"true", .@"false", .symbol, .string, .number, .builtin, .fun => unreachable,
        .list => |list| {
            return getValueAtPath(list[path[0]], path[1..]);
        },
        .vec => |vec| {
            return getValueAtPath(vec[path[0]], path[1..]);
        },
        .map => |map| {
            const key_val = map[path[0]];
            const elem = switch (path[1]) {
                0 => key_val.key,
                1 => key_val.val,
                else => unreachable,
            };
            return getValueAtPath(elem, path[2..]);
        },
        .tagged => |tagged| {
            const elem = switch (path[0]) {
                0 => tagged.key.*,
                1 => tagged.val.*,
                else => unreachable,
            };
            return getValueAtPath(elem, path[1..]);
        },
        .actions => |actions| {
            const action = actions[path[0]];
            switch (path[1]) {
                0 => {
                    const elem = action.origin[path[2]];
                    return getValueAtPath(elem, path[3..]);
                },
                1 => {
                    return getValueAtPath(action.new, path[2..]);
                },
                else => unreachable,
            }
        },
    }
}
