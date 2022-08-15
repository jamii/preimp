const std = @import("std");

pub const Allocator = std.mem.Allocator;
pub const ArenaAllocator = std.heap.ArenaAllocator;
pub const ArrayList = std.ArrayList;
pub const HashMap = std.HashMap;

// TODO should probably preallocate memory for panic message
pub fn panic(comptime fmt: []const u8, args: anytype) noreturn {
    var buf = ArrayList(u8).init(std.heap.page_allocator);
    var writer = buf.writer();
    const message: []const u8 = message: {
        std.fmt.format(writer, fmt, args) catch |err| {
            switch (err) {
                error.OutOfMemory => break :message "OOM inside panic",
            }
        };
        break :message buf.toOwnedSlice();
    };
    @panic(message);
}

pub fn assert(b: bool) void {
    if (!b)
        panic("Assert failed", .{});
}

pub fn oom() noreturn {
    @panic("Out of memory");
}

pub fn dump(thing: anytype) void {
    std.debug.getStderrMutex().lock();
    defer std.debug.getStderrMutex().unlock();
    const my_stderr = std.io.getStdErr();
    const writer = my_stderr.writer();
    dumpInto(writer, 0, thing) catch return;
    writer.writeAll("\n") catch return;
}

pub fn dumpInto(writer: anytype, indent: u32, thing: anytype) anyerror!void {
    switch (@typeInfo(@TypeOf(thing))) {
        .Pointer => |pti| {
            switch (pti.size) {
                .One => {
                    try writer.writeAll("&");
                    try dumpInto(writer, indent, thing.*);
                },
                .Many => {
                    // bail
                    try std.fmt.format(writer, "{}", .{thing});
                },
                .Slice => {
                    if (pti.child == u8) {
                        try std.fmt.format(writer, "\"{s}\"", .{thing});
                    } else {
                        try std.fmt.format(writer, "[]{s}[\n", .{pti.child});
                        for (thing) |elem| {
                            try writer.writeByteNTimes(' ', indent + 4);
                            try dumpInto(writer, indent + 4, elem);
                            try writer.writeAll(",\n");
                        }
                        try writer.writeByteNTimes(' ', indent);
                        try writer.writeAll("]");
                    }
                },
                .C => {
                    // bail
                    try std.fmt.format(writer, "{}", .{thing});
                },
            }
        },
        .Array => |ati| {
            if (ati.child == u8) {
                try std.fmt.format(writer, "\"{s}\"", .{thing});
            } else {
                try std.fmt.format(writer, "[{}]{s}[\n", .{ ati.len, ati.child });
                for (thing) |elem| {
                    try writer.writeByteNTimes(' ', indent + 4);
                    try dumpInto(writer, indent + 4, elem);
                    try writer.writeAll(",\n");
                }
                try writer.writeByteNTimes(' ', indent);
                try writer.writeAll("]");
            }
        },
        .Struct => |sti| {
            try writer.writeAll(@typeName(@TypeOf(thing)));
            try writer.writeAll("{\n");
            inline for (sti.fields) |field| {
                try writer.writeByteNTimes(' ', indent + 4);
                try std.fmt.format(writer, ".{s} = ", .{field.name});
                try dumpInto(writer, indent + 4, @field(thing, field.name));
                try writer.writeAll(",\n");
            }
            try writer.writeByteNTimes(' ', indent);
            try writer.writeAll("}");
        },
        .Union => |uti| {
            if (uti.tag_type) |tag_type| {
                try writer.writeAll(@typeName(@TypeOf(thing)));
                try writer.writeAll("{\n");
                inline for (@typeInfo(tag_type).Enum.fields) |fti| {
                    if (@enumToInt(std.meta.activeTag(thing)) == fti.value) {
                        try writer.writeByteNTimes(' ', indent + 4);
                        try std.fmt.format(writer, ".{s} = ", .{fti.name});
                        try dumpInto(writer, indent + 4, @field(thing, fti.name));
                        try writer.writeAll("\n");
                        try writer.writeByteNTimes(' ', indent);
                        try writer.writeAll("}");
                    }
                }
            } else {
                // bail
                try std.fmt.format(writer, "{}", .{thing});
            }
        },
        .Optional => {
            if (thing == null) {
                try writer.writeAll("null");
            } else {
                try dumpInto(writer, indent, thing.?);
            }
        },
        .Opaque => {
            try writer.writeAll("opaque");
        },
        else => {
            // bail
            try std.fmt.format(writer, "{any}", .{thing});
        },
    }
}

pub fn format(allocator: Allocator, comptime fmt: []const u8, args: anytype) []const u8 {
    var buf = ArrayList(u8).init(allocator);
    var writer = buf.writer();
    std.fmt.format(writer, fmt, args) catch oom();
    return buf.items;
}

pub fn deepEqual(a: anytype, b: @TypeOf(a)) bool {
    return deepCompare(a, b) == .eq;
}

pub fn deepCompare(a: anytype, b: @TypeOf(a)) std.math.Order {
    const T = @TypeOf(a);
    const ti = @typeInfo(T);
    switch (ti) {
        .Struct, .Enum, .Union => {
            if (@hasDecl(T, "deepCompare")) {
                return T.deepCompare(a, b);
            }
        },
        else => {},
    }
    switch (ti) {
        .Bool => {
            if (a == b) return .eq;
            if (a) return .gt;
            return .lt;
        },
        .Int, .Float => {
            if (a < b) {
                return .lt;
            }
            if (a > b) {
                return .gt;
            }
            return .eq;
        },
        .Enum => {
            return deepCompare(@enumToInt(a), @enumToInt(b));
        },
        .Pointer => |pti| {
            switch (pti.size) {
                .One => {
                    return deepCompare(a.*, b.*);
                },
                .Slice => {
                    if (a.len < b.len) {
                        return .lt;
                    }
                    if (a.len > b.len) {
                        return .gt;
                    }
                    for (a) |a_elem, a_ix| {
                        const ordering = deepCompare(a_elem, b[a_ix]);
                        if (ordering != .eq) {
                            return ordering;
                        }
                    }
                    return .eq;
                },
                .Many, .C => @compileError("cannot deepCompare " ++ @typeName(T)),
            }
        },
        .Optional => {
            if (a) |a_val| {
                if (b) |b_val| {
                    return deepCompare(a_val, b_val);
                } else {
                    return .gt;
                }
            } else {
                if (b) |_| {
                    return .lt;
                } else {
                    return .eq;
                }
            }
        },
        .Array => {
            for (a) |a_elem, a_ix| {
                const ordering = deepCompare(a_elem, b[a_ix]);
                if (ordering != .eq) {
                    return ordering;
                }
            }
            return .eq;
        },
        .Struct => |sti| {
            inline for (sti.fields) |fti| {
                const ordering = deepCompare(@field(a, fti.name), @field(b, fti.name));
                if (ordering != .eq) {
                    return ordering;
                }
            }
            return .eq;
        },
        .Union => |uti| {
            if (uti.tag_type) |tag_type| {
                const enum_info = @typeInfo(tag_type).Enum;
                const a_tag = @enumToInt(@as(tag_type, a));
                const b_tag = @enumToInt(@as(tag_type, b));
                if (a_tag < b_tag) {
                    return .lt;
                }
                if (a_tag > b_tag) {
                    return .gt;
                }
                inline for (enum_info.fields) |fti| {
                    if (a_tag == fti.value) {
                        return deepCompare(
                            @field(a, fti.name),
                            @field(b, fti.name),
                        );
                    }
                }
                unreachable;
            } else {
                @compileError("cannot deepCompare " ++ @typeName(T));
            }
        },
        .Void => return .eq,
        .ErrorUnion => {
            if (a) |a_ok| {
                if (b) |b_ok| {
                    return deepCompare(a_ok, b_ok);
                } else |_| {
                    return .lt;
                }
            } else |a_err| {
                if (b) |_| {
                    return .gt;
                } else |b_err| {
                    return deepCompare(a_err, b_err);
                }
            }
        },
        .ErrorSet => return deepCompare(@errorToInt(a), @errorToInt(b)),
        else => @compileError("cannot deepCompare " ++ @typeName(T)),
    }
}

pub fn deepHash(key: anytype) u64 {
    var hasher = std.hash.Wyhash.init(0);
    deepHashInto(&hasher, key);
    return hasher.final();
}

pub fn deepHashInto(hasher: anytype, key: anytype) void {
    const T = @TypeOf(key);
    const ti = @typeInfo(T);
    switch (ti) {
        .Struct, .Enum, .Union => {
            if (@hasDecl(T, "deepHashInto")) {
                return T.deepHashInto(hasher, key);
            }
        },
        else => {},
    }
    switch (ti) {
        .Int => @call(.{ .modifier = .always_inline }, hasher.update, .{std.mem.asBytes(&key)}),
        .Float => |info| deepHashInto(hasher, @bitCast(std.meta.Int(.unsigned, info.bits), key)),
        .Bool => deepHashInto(hasher, @boolToInt(key)),
        .Enum => deepHashInto(hasher, @enumToInt(key)),
        .Pointer => |pti| {
            switch (pti.size) {
                .One => deepHashInto(hasher, key.*),
                .Slice => {
                    for (key) |element| {
                        deepHashInto(hasher, element);
                    }
                },
                .Many, .C => @compileError("cannot deepHash " ++ @typeName(T)),
            }
        },
        .Optional => if (key) |k| deepHashInto(hasher, k),
        .Array => {
            for (key) |element| {
                deepHashInto(hasher, element);
            }
        },
        .Struct => |info| {
            inline for (info.fields) |field| {
                deepHashInto(hasher, @field(key, field.name));
            }
        },
        .Union => |info| {
            if (info.tag_type) |tag_type| {
                const enum_info = @typeInfo(tag_type).Enum;
                const tag = std.meta.activeTag(key);
                deepHashInto(hasher, tag);
                inline for (enum_info.fields) |enum_field| {
                    if (enum_field.value == @enumToInt(tag)) {
                        deepHashInto(hasher, @field(key, enum_field.name));
                        return;
                    }
                }
                unreachable;
            } else @compileError("cannot deepHash " ++ @typeName(T));
        },
        .Void => {},
        else => @compileError("cannot deepHash " ++ @typeName(T)),
    }
}

pub fn DeepHashContext(comptime K: type) type {
    return struct {
        const Self = @This();
        pub fn hash(_: Self, pseudo_key: K) u64 {
            return deepHash(pseudo_key);
        }
        pub fn eql(_: Self, pseudo_key: K, key: K) bool {
            return deepEqual(pseudo_key, key);
        }
    };
}

pub fn DeepHashMap(comptime K: type, comptime V: type) type {
    return std.HashMap(K, V, DeepHashContext(K), std.hash_map.default_max_load_percentage);
}

pub fn DeepHashSet(comptime K: type) type {
    return DeepHashMap(K, void);
}

pub fn deepSort(slice: anytype) void {
    const T = @typeInfo(@TypeOf(slice)).Pointer.child;
    std.sort.sort(T, slice, {}, struct {
        fn lessThan(_: void, a: T, b: T) bool {
            return deepCompare(a, b) == .lt;
        }
    }.lessThan);
}

pub fn box(allocator: Allocator, value: anytype) error{OutOfMemory}!*@TypeOf(value) {
    var boxed = try allocator.create(@TypeOf(value));
    boxed.* = value;
    return boxed;
}

pub const BinarySearchResult = union(enum) {
    Found: usize,
    NotFound: usize,

    pub fn position(self: BinarySearchResult) usize {
        return switch (self) {
            .Found => |found| found,
            .NotFound => |not_found| not_found,
        };
    }
};

pub fn binarySearch(
    comptime T: type,
    key: anytype,
    items: []const T,
    context: anytype,
    comptime compareFn: fn (context: @TypeOf(context), lhs: @TypeOf(key), rhs: T) std.math.Order,
) BinarySearchResult {
    var left: usize = 0;
    var right: usize = items.len;

    while (left < right) {
        // Avoid overflowing in the midpoint calculation
        const mid = left + (right - left) / 2;
        // Compare the key with the midpoint element
        switch (compareFn(context, key, items[mid])) {
            .eq => return .{ .Found = mid },
            .gt => left = mid + 1,
            .lt => right = mid,
        }
    }

    return .{ .NotFound = left };
}

// slightly modified from std.json.stringify
pub fn stringify(
    value: anytype,
    options: std.json.StringifyOptions,
    out_stream: anytype,
) @TypeOf(out_stream).Error!void {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .Float, .ComptimeFloat => {
            return std.fmt.formatFloatScientific(value, std.fmt.FormatOptions{}, out_stream);
        },
        .Int, .ComptimeInt => {
            return std.fmt.formatIntValue(value, "", std.fmt.FormatOptions{}, out_stream);
        },
        .Bool => {
            return out_stream.writeAll(if (value) "true" else "false");
        },
        .Null => {
            return out_stream.writeAll("null");
        },
        .Optional => {
            if (value) |payload| {
                return try stringify(payload, options, out_stream);
            } else {
                return try stringify(null, options, out_stream);
            }
        },
        .Enum => {
            if (comptime std.meta.trait.hasFn("jsonStringify")(T)) {
                return value.jsonStringify(options, out_stream);
            }

            const info = @typeInfo(T).Enum;
            inline for (info.fields) |e_field| {
                if (value == @field(T, e_field.name)) {
                    return try stringify(e_field.name, options, out_stream);
                }
            }
        },
        .Union => {
            if (comptime std.meta.trait.hasFn("jsonStringify")(T)) {
                return value.jsonStringify(options, out_stream);
            }

            const info = @typeInfo(T).Union;
            if (info.tag_type) |UnionTagType| {
                inline for (info.fields) |u_field| {
                    if (value == @field(UnionTagType, u_field.name)) {
                        return try stringify(@field(value, u_field.name), options, out_stream);
                    }
                }
            } else {
                @compileError("Unable to stringify untagged union '" ++ @typeName(T) ++ "'");
            }
        },
        .Struct => |S| {
            if (comptime std.meta.trait.hasFn("jsonStringify")(T)) {
                return value.jsonStringify(options, out_stream);
            }

            try out_stream.writeByte('{');
            var field_output = false;
            var child_options = options;
            if (child_options.whitespace) |*child_whitespace| {
                child_whitespace.indent_level += 1;
            }
            inline for (S.fields) |Field| {
                // don't include void fields
                if (Field.field_type == void) continue;

                var emit_field = true;

                // don't include optional fields that are null when emit_null_optional_fields is set to false
                if (@typeInfo(Field.field_type) == .Optional) {
                    if (options.emit_null_optional_fields == false) {
                        if (@field(value, Field.name) == null) {
                            emit_field = false;
                        }
                    }
                }

                if (emit_field) {
                    if (!field_output) {
                        field_output = true;
                    } else {
                        try out_stream.writeByte(',');
                    }
                    if (child_options.whitespace) |child_whitespace| {
                        try child_whitespace.outputIndent(out_stream);
                    }
                    try std.json.encodeJsonString(Field.name, options, out_stream);
                    try out_stream.writeByte(':');
                    if (child_options.whitespace) |child_whitespace| {
                        if (child_whitespace.separator) {
                            try out_stream.writeByte(' ');
                        }
                    }
                    try stringify(@field(value, Field.name), child_options, out_stream);
                }
            }
            if (field_output) {
                if (options.whitespace) |whitespace| {
                    try whitespace.outputIndent(out_stream);
                }
            }
            try out_stream.writeByte('}');
            return;
        },
        .ErrorSet => return stringify(@as([]const u8, @errorName(value)), options, out_stream),
        .Pointer => |ptr_info| switch (ptr_info.size) {
            .One => switch (@typeInfo(ptr_info.child)) {
                .Array => {
                    const Slice = []const std.meta.Elem(ptr_info.child);
                    return stringify(@as(Slice, value), options, out_stream);
                },
                else => {
                    // TODO: avoid loops?
                    return stringify(value.*, options, out_stream);
                },
            },
            // TODO: .Many when there is a sentinel (waiting for https://github.com/ziglang/zig/pull/3972)
            .Slice => {
                if (ptr_info.child == u8 and options.string == .String and std.unicode.utf8ValidateSlice(value)) {
                    try std.json.encodeJsonString(value, options, out_stream);
                    return;
                }

                try out_stream.writeByte('[');
                var child_options = options;
                if (child_options.whitespace) |*whitespace| {
                    whitespace.indent_level += 1;
                }
                for (value) |x, i| {
                    if (i != 0) {
                        try out_stream.writeByte(',');
                    }
                    if (child_options.whitespace) |child_whitespace| {
                        try child_whitespace.outputIndent(out_stream);
                    }
                    try stringify(x, child_options, out_stream);
                }
                if (value.len != 0) {
                    if (options.whitespace) |whitespace| {
                        try whitespace.outputIndent(out_stream);
                    }
                }
                try out_stream.writeByte(']');
                return;
            },
            else => @compileError("Unable to stringify type '" ++ @typeName(T) ++ "'"),
        },
        .Array => return stringify(&value, options, out_stream),
        .Vector => |info| {
            const array: [info.len]info.child = value;
            return stringify(&array, options, out_stream);
        },
        .Void => try out_stream.writeAll("null"),
        else => @compileError("Unable to stringify type '" ++ @typeName(T) ++ "'"),
    }
    unreachable;
}
