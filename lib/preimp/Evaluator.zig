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

pub fn evalExprs(self: *Evaluator, exprs: []const preimp.Value, origin: ?*u.ArrayList(preimp.Value)) error{OutOfMemory}!preimp.Value {
    const env_start = self.env.items.len;
    defer self.env.shrinkRetainingCapacity(env_start);
    var value = preimp.Value.fromInner(.nil);
    for (exprs) |expr| {
        value = try self.evalExpr(expr, origin);
    }
    return value;
}

pub fn evalExpr(self: *Evaluator, expr: preimp.Value, origin: ?*u.ArrayList(preimp.Value)) error{OutOfMemory}!preimp.Value {
    var value = try self.evalExprInner(expr, origin);
    if (origin != null)
        value.meta = try preimp.KeyVal.put(
            self.allocator,
            value.meta,
            preimp.Value.fromInner(.{ .string = "origin" }),
            preimp.Value.fromInner(.{ .vec = try self.allocator.dupe(preimp.Value, origin.?.items) }),
        );
    return value;
}

pub fn evalExprInner(self: *Evaluator, expr: preimp.Value, origin: ?*u.ArrayList(preimp.Value)) error{OutOfMemory}!preimp.Value {
    switch (expr.inner) {
        .nil,
        .@"true",
        .@"false",
        .string,
        .number,
        .builtin,
        .fun,
        => return expr,
        .symbol => |symbol| {
            // builtin functions
            // TODO builtins should probably be default environment, not keywords
            inline for (@typeInfo(preimp.Builtin).Enum.fields) |field|
                if (u.deepEqual(symbol, field.name))
                    return preimp.Value.fromInner(.{ .builtin = @intToEnum(preimp.Builtin, field.value) });

            // regular symbols
            var i = self.env.items.len;
            while (i > 0) : (i -= 1) {
                const binding = self.env.items[i - 1];
                if (u.deepEqual(symbol, binding.name))
                    return binding.value;
            }

            // undefined symbol
            return preimp.Value.format(self.allocator,
                \\ #"error" #"undefined" ?
            , .{symbol});
        },
        .list => |list| {
            if (list.len == 0)
                return preimp.Value.format(self.allocator,
                    \\ #"error" #"empty list" nil
                , .{});

            // special forms
            const head_expr = list[0];
            if (head_expr.inner == .symbol) {
                if (u.deepEqual(head_expr.inner.symbol, "def")) {
                    // (def symbol expr)
                    if (list.len != 3)
                        return preimp.Value.format(self.allocator,
                            \\ #"error" #"malformed def" ?
                        , .{expr});
                    const name_expr = list[1];
                    if (name_expr.inner != .symbol)
                        return preimp.Value.format(self.allocator,
                            \\ #"error" #"malformed def" ?
                        , .{expr});
                    const name = name_expr.inner.symbol;
                    if (origin != null)
                        try origin.?.append(name_expr);
                    const value = try self.evalExpr(list[2], origin);
                    if (origin != null) {
                        _ = origin.?.pop();
                    }
                    try self.env.append(.{ .name = name, .value = value });
                    return preimp.Value.fromInner(.{ .nil = {} });
                }
                if (u.deepEqual(head_expr.inner.symbol, "fn")) {
                    // (fn [symbol*] expr*)
                    if (list.len < 2)
                        return preimp.Value.format(self.allocator,
                            \\ #"error" #"malformed fn" ?
                        , .{expr});
                    const args_expr = list[1];
                    if (args_expr.inner != .vec)
                        return preimp.Value.format(self.allocator,
                            \\ #"error" #"malformed fn" ?
                        , .{expr});
                    var args = u.ArrayList([]const u8).init(self.allocator);
                    for (args_expr.inner.vec) |arg_expr| {
                        if (arg_expr.inner != .symbol)
                            return preimp.Value.format(self.allocator,
                                \\ #"error" #"malformed fn arg" ?
                            , .{arg_expr});
                        try args.append(arg_expr.inner.symbol);
                    }
                    // TODO only close over referred bindings
                    const env = try self.allocator.dupe(preimp.Binding, self.env.items);
                    const body = list[2..];
                    return preimp.Value.fromInner(.{ .fun = .{ .env = env, .args = args.toOwnedSlice(), .body = body } });
                }
                if (u.deepEqual(head_expr.inner.symbol, "if")) {
                    // (if expr expr expr)
                    if (list.len != 4)
                        return preimp.Value.format(self.allocator,
                            \\ #"error" #"malformed if" ?
                        , .{expr});
                    const cond = try self.evalExpr(list[1], null);
                    return switch (cond.inner) {
                        .@"true" => self.evalExpr(list[2], null),
                        .@"false" => self.evalExpr(list[3], null),
                        else => preimp.Value.format(self.allocator,
                            \\ #"error" #"non-bool in if" ?
                        , .{cond}),
                    };
                }
            }

            // regular forms
            const head = try self.evalExpr(list[0], null);
            var tail = try u.ArrayList(preimp.Value).initCapacity(self.allocator, list.len - 1);
            for (list[1..]) |tail_expr|
                try tail.append(try self.evalExpr(tail_expr, null));
            for (tail.items) |tail_value|
                if (tail_value.inner.isError())
                    return tail_value;
            switch (head.inner) {
                .builtin => |builtin| {
                    switch (builtin) {
                        .@"+" => {
                            if (tail.items.len != 2)
                                return preimp.Value.format(self.allocator,
                                    \\ #"error" #"wrong number of args" {"expected" ? "found" ?}
                                , .{ 2, tail.items.len });
                            const arg0 = tail.items[0];
                            const arg1 = tail.items[1];

                            if (arg0.inner != .number)
                                return preimp.Value.format(self.allocator,
                                    \\ #"error" #"non-number passed to +" ?
                                , .{arg0});
                            if (arg1.inner != .number)
                                return preimp.Value.format(self.allocator,
                                    \\ #"error" #"non-number passed to +" ?
                                , .{arg1});

                            return preimp.Value.fromInner(.{ .number = arg0.inner.number + arg1.inner.number });
                        },
                        .@"-" => {
                            if (tail.items.len != 2)
                                return preimp.Value.format(self.allocator,
                                    \\ #"error" #"wrong number of args" {"expected" ? "found" ?}
                                , .{ 2, tail.items.len });
                            const arg0 = tail.items[0];
                            const arg1 = tail.items[1];

                            if (arg0.inner != .number)
                                return preimp.Value.format(self.allocator,
                                    \\ #"error" #"non-number passed to -" ?
                                , .{arg0});
                            if (arg1.inner != .number)
                                return preimp.Value.format(self.allocator,
                                    \\ #"error" #"non-number passed to -" ?
                                , .{arg1});

                            return preimp.Value.fromInner(.{ .number = arg0.inner.number - arg1.inner.number });
                        },
                        .@"*" => {
                            if (tail.items.len != 2)
                                return preimp.Value.format(self.allocator,
                                    \\ #"error" #"wrong number of args" {"expected" ? "found" ?}
                                , .{ 2, tail.items.len });
                            const arg0 = tail.items[0];
                            const arg1 = tail.items[1];

                            if (arg0.inner != .number)
                                return preimp.Value.format(self.allocator,
                                    \\ #"error" #"non-number passed to *" ?
                                , .{arg0});
                            if (arg1.inner != .number)
                                return preimp.Value.format(self.allocator,
                                    \\ #"error" #"non-number passed to *" ?
                                , .{arg1});

                            return preimp.Value.fromInner(.{ .number = arg0.inner.number * arg1.inner.number });
                        },
                        .@"/" => {
                            if (tail.items.len != 2)
                                return preimp.Value.format(self.allocator,
                                    \\ #"error" #"wrong number of args" {"expected" ? "found" ?}
                                , .{ 2, tail.items.len });
                            const arg0 = tail.items[0];
                            const arg1 = tail.items[1];

                            if (arg0.inner != .number)
                                return preimp.Value.format(self.allocator,
                                    \\ #"error" #"non-number passed to /" ?
                                , .{arg0});
                            if (arg1.inner != .number)
                                return preimp.Value.format(self.allocator,
                                    \\ #"error" #"non-number passed to /" ?
                                , .{arg1});

                            if (arg1.inner.number == 0)
                                return preimp.Value.format(self.allocator,
                                    \\ #"error" #"division by 0" nil
                                , .{});

                            return preimp.Value.fromInner(.{ .number = arg0.inner.number / arg1.inner.number });
                        },
                        .@"=" => {
                            if (tail.items.len != 2)
                                return preimp.Value.format(self.allocator,
                                    \\ #"error" #"wrong number of args" {"expected" ? "found" ?}
                                , .{ 2, tail.items.len });

                            return if (u.deepEqual(tail.items[0], tail.items[1]))
                                preimp.Value.fromInner(.{ .@"true" = {} })
                            else
                                preimp.Value.fromInner(.{ .@"false" = {} });
                        },
                        .get => {
                            if (tail.items.len != 2)
                                return preimp.Value.format(self.allocator,
                                    \\ #"error" #"wrong number of args" {"expected" ? "found" ?}
                                , .{ 2, tail.items.len });

                            const map = tail.items[0];
                            const key = tail.items[1];

                            switch (map.inner) {
                                .map => |key_vals| {
                                    return preimp.KeyVal.get(key_vals, key) orelse
                                        preimp.Value.format(self.allocator,
                                        \\ #"error" #"not found" ?
                                    , .{key});
                                },
                                .vec => |elems| {
                                    if (key.inner == .number) {
                                        const number = key.inner.number;
                                        if (number >= 0 and number == @trunc(number)) {
                                            const int = @floatToInt(usize, number);
                                            if (int < elems.len) {
                                                return elems[int];
                                            }
                                        }
                                    }

                                    return preimp.Value.format(self.allocator,
                                        \\ #"error" #"not found" ?
                                    , .{key});
                                },
                                else => {
                                    return preimp.Value.format(self.allocator,
                                        \\ #"error" #"cannot get in this" ?
                                    , .{map});
                                },
                            }
                        },
                        .put => {
                            if (tail.items.len != 3)
                                return preimp.Value.format(self.allocator,
                                    \\ #"error" #"wrong number of args" {"expected" ? "found" ?}
                                , .{ 3, tail.items.len });

                            const map = tail.items[0];
                            const key = tail.items[1];
                            const val = tail.items[2];

                            switch (map.inner) {
                                .map => |key_vals| {
                                    return preimp.Value.fromInner(.{ .map = try preimp.KeyVal.put(self.allocator, key_vals, key, val) });
                                },
                                .vec => |elems| {
                                    if (key.inner != .number)
                                        return preimp.Value.format(self.allocator,
                                            \\ #"error" #"cannot put this key in a vec" ?
                                        , .{key});

                                    const number = key.inner.number;
                                    if (number < 0 or number != @trunc(number))
                                        return preimp.Value.format(self.allocator,
                                            \\ #"error" #"cannot put this key in a vec" ?
                                        , .{key});

                                    const int = @floatToInt(usize, number);
                                    if (int < elems.len) {
                                        var new_elems = try self.allocator.dupe(preimp.Value, elems);
                                        elems[int] = val;
                                        return preimp.Value.fromInner(.{ .vec = new_elems });
                                    } else if (int == elems.len) {
                                        var new_elems = try u.ArrayList(preimp.Value).initCapacity(self.allocator, elems.len + 1);
                                        try new_elems.appendSlice(elems);
                                        try new_elems.append(val);
                                        return preimp.Value.fromInner(.{ .vec = new_elems.toOwnedSlice() });
                                    } else {
                                        return preimp.Value.format(self.allocator,
                                            \\ #"error" #"key is past end of vec" ?
                                        , .{key});
                                    }
                                },
                                else => {
                                    return preimp.Value.format(self.allocator,
                                        \\ #"error" #"cannot put in this" ?
                                    , .{map});
                                },
                            }
                        },
                        .@"get-meta" => {
                            if (tail.items.len != 1)
                                return preimp.Value.format(self.allocator,
                                    \\ #"error" #"wrong number of args" {"expected" ? "found" ?}
                                , .{ 1, tail.items.len });

                            return preimp.Value.fromInner(.{ .map = tail.items[0].meta });
                        },
                        .@"put-meta" => {
                            if (tail.items.len != 2)
                                return preimp.Value.format(self.allocator,
                                    \\ #"error" #"wrong number of args" {"expected" ? "found" ?}
                                , .{ 2, tail.items.len });

                            const value = tail.items[0];
                            const meta = tail.items[1];

                            if (meta.inner != .map)
                                return preimp.Value.format(self.allocator,
                                    \\ #"error" #"non-map passed to put-meta" ?
                                , .{meta});

                            return preimp.Value{ .inner = value.inner, .meta = meta.inner.map };
                        },
                        .count => {
                            if (tail.items.len != 1)
                                return preimp.Value.format(self.allocator,
                                    \\ #"error" #"wrong number of args" {"expected" ? "found" ?}
                                , .{ 1, tail.items.len });

                            const value = tail.items[0];
                            switch (value.inner) {
                                .map => |key_vals| return preimp.Value.fromInner(.{ .number = @intToFloat(f64, key_vals.len) }),
                                .vec => |elems| return preimp.Value.fromInner(.{ .number = @intToFloat(f64, elems.len) }),
                                else => return preimp.Value.format(self.allocator,
                                    \\ #"error" #"cannot count" ?
                                , .{value}),
                            }
                        },
                    }
                },
                .fun => |fun| {
                    // apply
                    const fn_env_start = self.env.items.len;
                    defer self.env.shrinkRetainingCapacity(fn_env_start);
                    try self.env.appendSlice(fun.env);
                    if (fun.args.len != tail.items.len)
                        return preimp.Value.format(self.allocator,
                            \\ #"error" #"wrong number of args" {"expected" ? "found" ?}
                        , .{ fun.args.len, tail.items.len });
                    for (fun.args) |arg, i|
                        try self.env.append(.{ .name = arg, .value = tail.items[i] });
                    return self.evalExprs(fun.body, origin);
                },
                else => {
                    return preimp.Value.format(self.allocator,
                        \\ #"error" #"can't call" ?
                    , .{head});
                },
            }
        },
        .vec => |vec| {
            var body = try u.ArrayList(preimp.Value).initCapacity(self.allocator, vec.len);
            for (vec) |body_expr, i| {
                if (origin != null)
                    try origin.?.append(preimp.Value.fromInner(.{ .number = @intToFloat(f64, i) }));
                try body.append(try self.evalExpr(body_expr, origin));
                if (origin != null) {
                    _ = origin.?.pop();
                }
            }
            return preimp.Value.fromInner(.{ .vec = body.toOwnedSlice() });
        },
        .map => |map| {
            var body = try u.ArrayList(preimp.KeyVal).initCapacity(self.allocator, @divTrunc(map.len, 2));
            for (map) |key_val| {
                const key = try self.evalExpr(key_val.key, null);
                if (origin != null)
                    try origin.?.append(key);
                const val = try self.evalExpr(key_val.val, origin);
                if (origin != null) {
                    _ = origin.?.pop();
                }
                try body.append(.{ .key = key, .val = val });
            }
            u.deepSort(body.items);
            // TODO check no duplicate values
            return preimp.Value.fromInner(.{ .map = body.toOwnedSlice() });
        },
        .tagged => |tagged| {
            const key = try self.evalExpr(tagged.key.*, null);
            if (origin != null)
                try origin.?.append(preimp.Value.fromInner(.{ .string = "val" }));
            const val = try self.evalExpr(tagged.val.*, origin);
            if (origin != null) {
                _ = origin.?.pop();
            }
            return preimp.Value.fromInner(.{ .tagged = .{
                .key = try u.box(self.allocator, key),
                .val = try u.box(self.allocator, val),
            } });
        },
    }
}

fn testEval(source: [:0]const u8, expected: []const u8) !void {
    var arena = u.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try preimp.Parser.init(arena.allocator(), source);
    const exprs = try parser.parseExprs(.eof);
    var evaluator = Evaluator.init(arena.allocator(), parser.values.items);
    var origin = u.ArrayList(preimp.Value).init(arena.allocator());
    const value = try evaluator.evalExprs(exprs, &origin);
    var found = u.ArrayList(u8).init(arena.allocator());
    try preimp.Value.dumpInto(found.writer(), 0, value);
    try std.testing.expectEqualStrings(expected, found.items);
}
