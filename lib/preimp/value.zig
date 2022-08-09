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
    err,
};

pub const Value = union(ValueTag) {
    nil,
    @"true",
    @"false",
    symbol: []const u8,
    string: []const u8,
    number: f64,
    list: []const Value,
    vec: []const Value,
    // sorted by key
    map: []const KeyVal,
    tagged: Tagged,
    builtin: Builtin,
    fun: Fun,
    err: Error,

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
            .err => |err| {
                try writer.writeByteNTimes(' ', indent);
                try writer.writeAll("#\n");
                try writer.writeByteNTimes(' ', indent + 4);
                try writer.writeAll("\"error\"\n");
                try writer.writeByteNTimes(' ', indent + 4);
                try std.fmt.format(writer, "{}\n", .{err});
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

pub const Error = union(enum) {
    // parse errors
    unexpected: struct {
        expected: preimp.Tokenizer.Token,
        found: preimp.Tokenizer.Token,
    },
    invalid_number,
    invalid_string,
    map_with_odd_elems,
    tokenizer_error,
    tag_ended_early,

    // eval errors
    undef: []const u8,
    empty_list,
    bad_def,
    bad_fn,
    bad_if,
    bad_for,
    bad_apply_head: *Value,
    bad_if_cond: *Value,
    bad_fn_arg,
    wrong_number_of_args: struct {
        expected: usize,
        found: usize,
    },
    not_a_map: *Value,
    not_found,
};
