const std = @import("std");
const preimp = @import("../preimp.zig");
const u = preimp.util;

pub const ValueTag = enum {
    nil,
    @"true",
    @"false",
    symbol,
    string,
    number,
    list,
    vec,
    map,
    tagged,
    builtin,
    fun,
};

pub const Value = union(ValueTag) {
    nil,
    @"true",
    @"false",
    symbol: []const u8,
    string: []const u8,
    number: f64,
    list: []Value,
    vec: []Value,
    // sorted by key
    map: []KeyVal,
    tagged: Tagged,
    builtin: Builtin,
    fun: Fun,

    pub fn fromZig(allocator: u.Allocator, zig_value: anytype) !Value {
        const T = @TypeOf(zig_value);
        switch (T) {
            Value => return zig_value,
            []const u8 => return Value{ .string = zig_value },
            else => {},
        }
        switch (@typeInfo(T)) {
            .Int, .ComptimeInt => return Value{ .number = @intToFloat(f64, zig_value) },
            .Float, .ComptimeFloat => return Value{ .number = @floatCast(f64, zig_value) },
            .Struct => |info| {
                var map_values = u.ArrayList(KeyVal).init(allocator);
                inline for (info.fields) |field| {
                    try map_values.push(.{
                        .key = try Value.fromZig(allocator, field.name),
                        .val = try Value.fromZig(allocator, @field(zig_value, field.name)),
                    });
                }
                return Value{ .map = map_values.toOwnedSlice() };
            },
            .Enum => |info| {
                inline for (info.fields) |field| {
                    if (@enumToInt(zig_value) == field.value) {
                        return Value{ .string = field.name };
                    }
                }
                unreachable;
            },
            else => @compileError("Don't know how to turn value of type " ++ @typeName(T) ++ " into preimp.Value"),
        }
    }

    pub fn errorFromZig(allocator: u.Allocator, zig_value: anytype) !Value {
        return Value{ .tagged = .{
            .key = try u.box(allocator, try Value.fromZig(allocator, "error")),
            .val = try u.box(allocator, try Value.fromZig(allocator, zig_value)),
        } };
    }

    pub fn format(allocator: u.Allocator, source: [:0]const u8, args: anytype) !Value {
        var arg_values: [args.len]Value = undefined;
        comptime var i: usize = 0;
        inline while (i < args.len) : (i += 1)
            arg_values[i] = try Value.fromZig(allocator, args[i]);
        return Value.formatValues(allocator, source, &arg_values);
    }

    pub fn formatValues(allocator: u.Allocator, source: [:0]const u8, args: []const Value) !Value {
        // TODO be careful about leaking tokens etc
        var parser = try preimp.Parser.init(allocator, source);
        const exprs = try parser.parseExprs(null, .eof);
        u.assert(exprs.len == 1);
        var value = exprs[0];
        var arg_ix: usize = 0;
        value.replace(&arg_ix, args);
        u.assert(arg_ix == args.len);
        return value;
    }

    pub fn replace(self: *Value, arg_ix: *usize, args: []const Value) void {
        switch (self.*) {
            .nil, .@"true", .@"false", .string, .number, .builtin, .fun => {},
            .symbol => |symbol| {
                if (u.deepEqual(symbol, "?")) {
                    self.* = args[arg_ix.*];
                    arg_ix.* += 1;
                }
            },
            .list => |list| {
                for (list) |*elem|
                    elem.replace(arg_ix, args);
            },
            .vec => |vec| {
                for (vec) |*elem|
                    elem.replace(arg_ix, args);
            },
            .map => |map| {
                for (map) |*elem| {
                    elem.key.replace(arg_ix, args);
                    elem.val.replace(arg_ix, args);
                }
            },
            .tagged => |*tagged| {
                tagged.key.replace(arg_ix, args);
                tagged.val.replace(arg_ix, args);
            },
        }
    }

    pub fn isError(self: Value) bool {
        return self == .tagged and
            self.tagged.key.* == .string and
            u.deepEqual(self.tagged.key.string, "error");
    }

    pub fn dumpInto(writer: anytype, indent: u32, self: Value) anyerror!void {
        switch (self) {
            .nil => {
                try writer.writeByteNTimes(' ', indent);
                try writer.writeAll("nil");
                try writer.writeAll("\n");
            },
            .@"true" => {
                try writer.writeByteNTimes(' ', indent);
                try writer.writeAll("true");
                try writer.writeAll("\n");
            },
            .@"false" => {
                try writer.writeByteNTimes(' ', indent);
                try writer.writeAll("false");
                try writer.writeAll("\n");
            },
            .symbol => |symbol| {
                try writer.writeByteNTimes(' ', indent);
                try writer.writeAll(symbol);
                try writer.writeAll("\n");
            },
            .string => |string| {
                try writer.writeByteNTimes(' ', indent);
                try std.fmt.format(writer, "\"{}\"", .{std.zig.fmtEscapes(string)});
                try writer.writeAll("\n");
            },
            .number => |number| {
                try writer.writeByteNTimes(' ', indent);
                try std.fmt.format(writer, "{}", .{number});
                try writer.writeAll("\n");
            },
            .list => |list| {
                try writer.writeByteNTimes(' ', indent);
                try writer.writeAll("(\n");
                for (list) |value|
                    try Value.dumpInto(writer, indent + 4, value);
                try writer.writeByteNTimes(' ', indent);
                try writer.writeAll(")\n");
            },
            .vec => |vec| {
                try writer.writeByteNTimes(' ', indent);
                try writer.writeAll("[\n");
                for (vec) |value|
                    try Value.dumpInto(writer, indent + 4, value);
                try writer.writeByteNTimes(' ', indent);
                try writer.writeAll("]\n");
            },
            .map => |map| {
                try writer.writeByteNTimes(' ', indent);
                try writer.writeAll("{\n");
                for (map) |key_val| {
                    try Value.dumpInto(writer, indent + 4, key_val.key);
                    try Value.dumpInto(writer, indent + 4, key_val.val);
                }
                try writer.writeByteNTimes(' ', indent);
                try writer.writeAll("}\n");
            },
            .tagged => |tagged| {
                try writer.writeByteNTimes(' ', indent);
                try writer.writeAll("#\n");
                try Value.dumpInto(writer, indent + 4, tagged.key.*);
                try Value.dumpInto(writer, indent + 4, tagged.val.*);
            },
            .builtin => |builtin| {
                try writer.writeByteNTimes(' ', indent);
                try writer.writeAll(std.meta.tagName(builtin));
                try writer.writeAll("\n");
            },
            .fun => |_| {
                try writer.writeByteNTimes(' ', indent);
                try writer.writeAll("<fn>");
                try writer.writeAll("\n");
            },
        }
    }
};

pub const KeyVal = struct {
    key: Value,
    val: Value,
};

pub const Tagged = struct {
    key: *Value,
    val: *Value,
};

pub const Builtin = enum {
    get,
    put,
};

pub const Fun = struct {
    env: []const Binding,
    args: []const []const u8,
    body: []const Value,
};

pub const Binding = struct {
    name: []const u8,
    value: Value,
};
