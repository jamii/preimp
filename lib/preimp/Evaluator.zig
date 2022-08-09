const std = @import("std");
const preimp = @import("../preimp.zig");
const u = preimp.util;

const Evaluator = @This();
allocator: u.Allocator,
env: u.ArrayList(preimp.Binding),

pub fn init(allocator: u.Allocator) Evaluator {
    return Evaluator{
        .allocator = allocator,
        .env = u.ArrayList(preimp.Binding).init(allocator),
    };
}

pub fn evalExprs(self: *Evaluator, exprs: []const preimp.Value) error{OutOfMemory}!preimp.Value {
    const env_start = self.env.items.len;
    defer self.env.shrinkRetainingCapacity(env_start);
    var value: preimp.Value = .nil;
    for (exprs) |expr| {
        value = try self.evalExpr(expr);
    }
    return value;
}

pub fn evalExpr(self: *Evaluator, expr: preimp.Value) error{OutOfMemory}!preimp.Value {
    switch (expr) {
        .nil,
        .@"true",
        .@"false",
        .string,
        .number,
        .builtin,
        .fun,
        .err,
        => return expr,
        .symbol => |symbol| {
            // builtin functions
            inline for (@typeInfo(preimp.Builtin).Enum.fields) |field|
                if (u.deepEqual(symbol, field.name))
                    return preimp.Value{ .builtin = @intToEnum(preimp.Builtin, field.value) };

            // regular symbols
            var i = self.env.items.len;
            while (i > 0) : (i -= 1) {
                const binding = self.env.items[i - 1];
                if (u.deepEqual(symbol, binding.name))
                    return binding.value;
            }

            // undefined symbol
            return preimp.Value{ .err = .{ .undef = symbol } };
        },
        .list => |list| {
            if (list.len == 0)
                return preimp.Value{ .err = .empty_list };

            // special forms
            const head_expr = list[0];
            if (head_expr == .symbol) {
                if (u.deepEqual(head_expr.symbol, "def")) {
                    // (def symbol expr)
                    if (list.len != 3)
                        return preimp.Value{ .err = .bad_def };
                    const name_expr = list[1];
                    if (name_expr != .symbol)
                        return preimp.Value{ .err = .bad_def };
                    const name = name_expr.symbol;
                    const value = try self.evalExpr(list[2]);
                    try self.env.append(.{ .name = name, .value = value });
                    return preimp.Value{ .nil = {} };
                }
                if (u.deepEqual(head_expr.symbol, "fn")) {
                    // (fn [symbol*] expr*)
                    if (list.len < 2)
                        return preimp.Value{ .err = .bad_fn };
                    const args_expr = list[1];
                    if (args_expr != .vec)
                        return preimp.Value{ .err = .bad_fn };
                    var args = u.ArrayList([]const u8).init(self.allocator);
                    for (args_expr.vec) |arg_expr| {
                        if (arg_expr != .symbol)
                            return preimp.Value{ .err = .bad_fn_arg };
                        try args.append(arg_expr.symbol);
                    }
                    // TODO only close over referred bindings
                    const env = try self.allocator.dupe(preimp.Binding, self.env.items);
                    const body = list[2..];
                    return preimp.Value{ .fun = .{ .env = env, .args = args.toOwnedSlice(), .body = body } };
                }
                if (u.deepEqual(head_expr.symbol, "if")) {
                    // (if expr expr expr)
                    if (list.len != 4)
                        return preimp.Value{ .err = .bad_if };
                    const cond = try self.evalExpr(list[1]);
                    return switch (cond) {
                        .@"true" => self.evalExpr(list[2]),
                        .@"false" => self.evalExpr(list[3]),
                        else => preimp.Value{ .err = .{ .bad_if_cond = try u.box(self.allocator, cond) } },
                    };
                }
            }

            // regular forms
            const head = try self.evalExpr(list[0]);
            var tail = try u.ArrayList(preimp.Value).initCapacity(self.allocator, list.len - 1);
            for (list[1..]) |tail_expr_ix|
                try tail.append(try self.evalExpr(tail_expr_ix));
            switch (head) {
                .builtin => |builtin| {
                    switch (builtin) {
                        .get => {
                            if (tail.items.len != 2)
                                return preimp.Value{ .err = .{ .wrong_number_of_args = .{ .expected = 2, .found = tail.items.len } } };

                            const map = tail.items[0];
                            const key = tail.items[1];

                            if (map != .map)
                                return preimp.Value{ .err = .{ .not_a_map = try u.box(self.allocator, map) } };

                            return switch (u.binarySearch(preimp.KeyVal, key, map.map, {}, (struct {
                                fn compare(_: void, key_: preimp.Value, key_val: preimp.KeyVal) std.math.Order {
                                    return u.deepCompare(key_, key_val.key);
                                }
                            }).compare)) {
                                .Found => |pos| map.map[pos].val,
                                .NotFound => preimp.Value{ .err = .not_found },
                            };
                        },
                        .put => {
                            if (tail.items.len != 3)
                                return preimp.Value{ .err = .{ .wrong_number_of_args = .{ .expected = 3, .found = tail.items.len } } };

                            const map = tail.items[0];
                            const key = tail.items[1];
                            const val = tail.items[2];

                            if (map != .map)
                                return preimp.Value{ .err = .{ .not_a_map = try u.box(self.allocator, map) } };

                            var key_vals = try u.ArrayList(preimp.KeyVal).initCapacity(self.allocator, map.map.len);
                            try key_vals.appendSlice(map.map);

                            switch (u.binarySearch(preimp.KeyVal, key, key_vals.items, {}, (struct {
                                fn compare(_: void, key_: preimp.Value, key_val: preimp.KeyVal) std.math.Order {
                                    return u.deepCompare(key_, key_val.key);
                                }
                            }).compare)) {
                                .Found => |pos| key_vals.items[pos].val = val,
                                .NotFound => |pos| try key_vals.insert(pos, .{ .key = key, .val = val }),
                            }

                            return preimp.Value{ .map = key_vals.toOwnedSlice() };
                        },
                    }
                },
                .fun => |fun| {
                    // apply
                    const fn_env_start = self.env.items.len;
                    defer self.env.shrinkRetainingCapacity(fn_env_start);
                    try self.env.appendSlice(fun.env);
                    if (fun.args.len != tail.items.len)
                        return preimp.Value{ .err = .{
                            .wrong_number_of_args = .{ .expected = fun.args.len, .found = tail.items.len },
                        } };
                    for (fun.args) |arg, i|
                        try self.env.append(.{ .name = arg, .value = tail.items[i] });
                    return self.evalExprs(fun.body);
                },
                else => {
                    return preimp.Value{ .err = .{ .bad_apply_head = try u.box(self.allocator, head) } };
                },
            }
        },
        .vec => |vec| {
            var body = try u.ArrayList(preimp.Value).initCapacity(self.allocator, vec.len);
            for (vec) |body_expr_ix|
                try body.append(try self.evalExpr(body_expr_ix));
            return preimp.Value{ .vec = body.toOwnedSlice() };
        },
        .map => |map| {
            var body = try u.ArrayList(preimp.KeyVal).initCapacity(self.allocator, @divTrunc(map.len, 2));
            for (map) |key_val| {
                const key = try self.evalExpr(key_val.key);
                const val = try self.evalExpr(key_val.val);
                try body.append(.{ .key = key, .val = val });
            }
            u.deepSort(body.items);
            // TODO check no duplicate values
            return preimp.Value{ .map = body.toOwnedSlice() };
        },
        .tagged => |tagged| {
            const key = try self.evalExpr(tagged.key.*);
            const val = try self.evalExpr(tagged.val.*);
            return preimp.Value{ .tagged = .{
                .key = try u.box(self.allocator, key),
                .val = try u.box(self.allocator, val),
            } };
        },
    }
}

fn testEval(source: [:0]const u8, expected: []const u8) !void {
    var arena = u.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try preimp.Parser.init(arena.allocator(), source);
    const expr_ixes = try parser.parseExprs(.eof);
    var evaluator = Evaluator.init(arena.allocator(), parser.values.items);
    const value = try evaluator.evalExprs(expr_ixes);
    var found = u.ArrayList(u8).init(arena.allocator());
    try preimp.Value.dumpInto(found.writer(), 0, value);
    try std.testing.expectEqualStrings(expected, found.items);
}