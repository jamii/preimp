const std = @import("std");
const preimp = @import("../preimp.zig");
const u = preimp.util;

const Evaluator = @This();
allocator: u.Allocator,
exprs: []const preimp.Parser.Expr,
env: u.ArrayList(Binding),

pub const ExprIx = usize;

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
            .err => |_| {
                try writer.writeByteNTimes(' ', indent);
                try std.fmt.format(writer, "err\n", .{});
            },
        }
    }
};

pub const KeyVal = struct {
    key: Value,
    val: Value,
};

pub const Builtin = enum {
    get,
};

pub const Fun = struct {
    env: []const Binding,
    args: []const []const u8,
    body: []const ExprIx,
};

pub const Binding = struct {
    name: []const u8,
    value: Value,
};

pub const Error = union(enum) {
    undef: []const u8,
    empty_list,
    parse_error: preimp.Parser.Error,
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
    wrong_type: struct {
        expected: ValueTag,
        found: ValueTag,
    },
    not_found,
};

pub fn init(allocator: u.Allocator, exprs: []const preimp.Parser.Expr) Evaluator {
    return Evaluator{
        .allocator = allocator,
        .exprs = exprs,
        .env = u.ArrayList(Binding).init(allocator),
    };
}

pub fn evalExprs(self: *Evaluator, expr_ixes: []const ExprIx) error{OutOfMemory}!Value {
    const env_start = self.env.items.len;
    defer self.env.shrinkRetainingCapacity(env_start);
    var value: Value = .nil;
    for (expr_ixes) |expr_ix| {
        value = try self.evalExpr(expr_ix);
    }
    return value;
}

pub fn evalExpr(self: *Evaluator, expr_ix: ExprIx) error{OutOfMemory}!Value {
    const expr = self.exprs[expr_ix];
    switch (expr) {
        .symbol => |symbol| {
            // builtin values
            if (u.deepEqual(symbol, "nil")) return Value{ .nil = {} };
            if (u.deepEqual(symbol, "true")) return Value{ .@"true" = {} };
            if (u.deepEqual(symbol, "false")) return Value{ .@"false" = {} };

            // builtin functions
            inline for (@typeInfo(Builtin).Enum.fields) |field|
                if (u.deepEqual(symbol, field.name))
                    return Value{ .builtin = @intToEnum(Builtin, field.value) };

            // regular symbols
            var i = self.env.items.len;
            while (i > 0) : (i -= 1) {
                const binding = self.env.items[i - 1];
                if (u.deepEqual(symbol, binding.name))
                    return binding.value;
            }

            // undefined symbol
            return Value{ .err = .{ .undef = symbol } };
        },
        .string => |string| {
            return Value{ .string = string };
        },
        .number => |number| {
            return Value{ .number = number };
        },
        .list => |list| {
            if (list.len == 0)
                return Value{ .err = .empty_list };

            // special forms
            const head_expr = self.exprs[list[0]];
            if (head_expr == .symbol) {
                if (u.deepEqual(head_expr.symbol, "def")) {
                    // (def symbol expr)
                    if (list.len != 3)
                        return Value{ .err = .bad_def };
                    const name_expr = self.exprs[list[1]];
                    if (name_expr != .symbol)
                        return Value{ .err = .bad_def };
                    const name = name_expr.symbol;
                    const value = try self.evalExpr(list[2]);
                    try self.env.append(.{ .name = name, .value = value });
                    return Value{ .nil = {} };
                }
                if (u.deepEqual(head_expr.symbol, "fn")) {
                    // (fn [symbol*] expr*)
                    if (list.len < 2)
                        return Value{ .err = .bad_fn };
                    const args_expr = self.exprs[list[1]];
                    if (args_expr != .vec)
                        return Value{ .err = .bad_fn };
                    var args = u.ArrayList([]const u8).init(self.allocator);
                    for (args_expr.vec) |arg_expr_ix| {
                        const arg_expr = self.exprs[arg_expr_ix];
                        if (arg_expr != .symbol)
                            return Value{ .err = .bad_fn_arg };
                        try args.append(arg_expr.symbol);
                    }
                    // TODO only close over referred bindings
                    const env = try self.allocator.dupe(Binding, self.env.items);
                    const body = list[2..];
                    return Value{ .fun = .{ .env = env, .args = args.toOwnedSlice(), .body = body } };
                }
                if (u.deepEqual(head_expr.symbol, "if")) {
                    // (if expr expr expr)
                    if (list.len != 4)
                        return Value{ .err = .bad_if };
                    const cond = try self.evalExpr(list[1]);
                    return switch (cond) {
                        .@"true" => self.evalExpr(list[2]),
                        .@"false" => self.evalExpr(list[3]),
                        else => Value{ .err = .{ .bad_if_cond = try u.box(self.allocator, cond) } },
                    };
                }
            }

            // regular forms
            const head = try self.evalExpr(list[0]);
            var tail = try u.ArrayList(Value).initCapacity(self.allocator, list.len - 1);
            for (list[1..]) |tail_expr_ix|
                try tail.append(try self.evalExpr(tail_expr_ix));
            switch (head) {
                .builtin => |builtin| {
                    switch (builtin) {
                        .get => {
                            if (tail.items.len != 2)
                                return Value{ .err = .{ .wrong_number_of_args = .{ .expected = 2, .found = tail.items.len } } };

                            const map = tail.items[0];
                            const key = tail.items[1];

                            if (map != .map)
                                return Value{ .err = .{ .wrong_type = .{ .expected = .map, .found = map } } };

                            return switch (u.binarySearch(KeyVal, key, map.map, {}, (struct {
                                fn compare(_: void, key_: Value, entry: KeyVal) std.math.Order {
                                    return u.deepCompare(key_, entry.key);
                                }
                            }).compare)) {
                                .Found => |pos| map.map[pos].val,
                                .NotFound => Value{ .err = .not_found },
                            };
                        },
                    }
                },
                .fun => |fun| {
                    // apply
                    const fn_env_start = self.env.items.len;
                    defer self.env.shrinkRetainingCapacity(fn_env_start);
                    try self.env.appendSlice(fun.env);
                    if (fun.args.len != tail.items.len)
                        return Value{ .err = .{
                            .wrong_number_of_args = .{ .expected = fun.args.len, .found = tail.items.len },
                        } };
                    for (fun.args) |arg, i|
                        try self.env.append(.{ .name = arg, .value = tail.items[i] });
                    return self.evalExprs(fun.body);
                },
                else => {
                    return Value{ .err = .{ .bad_apply_head = try u.box(self.allocator, head) } };
                },
            }
        },
        .vec => |vec| {
            var body = try u.ArrayList(Value).initCapacity(self.allocator, vec.len);
            for (vec) |body_expr_ix|
                try body.append(try self.evalExpr(body_expr_ix));
            return Value{ .vec = body.toOwnedSlice() };
        },
        .map => |map| {
            var body = try u.ArrayList(KeyVal).initCapacity(self.allocator, @divTrunc(map.len, 2));
            var i: usize = 0;
            while (i < map.len) : (i += 2) {
                const key = try self.evalExpr(map[i]);
                const val = try self.evalExpr(map[i + 1]);
                try body.append(.{ .key = key, .val = val });
            }
            u.deepSort(body.items);
            // TODO check no duplicate values
            return Value{ .map = body.toOwnedSlice() };
        },
        .err => |err| {
            return Value{ .err = .{ .parse_error = err } };
        },
    }
}

fn testEval(source: [:0]const u8, expected: []const u8) !void {
    var arena = u.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try preimp.Parser.init(arena.allocator(), source);
    const expr_ixes = try parser.parseExprs(.eof);
    var evaluator = Evaluator.init(arena.allocator(), parser.exprs.items);
    const value = try evaluator.evalExprs(expr_ixes);
    var found = u.ArrayList(u8).init(arena.allocator());
    try Value.dumpInto(found.writer(), 0, value);
    try std.testing.expectEqualStrings(expected, found.items);
}
