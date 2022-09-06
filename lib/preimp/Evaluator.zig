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

pub fn evalExprsKeepEnv(self: *Evaluator, exprs: []const preimp.Value) error{OutOfMemory}!preimp.Value {
    var value = preimp.Value.fromInner(.nil);
    for (exprs) |expr|
        value = try self.evalExpr(expr);
    return value;
}

pub fn evalExprs(self: *Evaluator, exprs: []const preimp.Value) error{OutOfMemory}!preimp.Value {
    const env_start = self.env.items.len;
    defer self.env.shrinkRetainingCapacity(env_start);
    return self.evalExprsKeepEnv(exprs);
}

pub fn evalExpr(self: *Evaluator, expr: preimp.Value) error{OutOfMemory}!preimp.Value {
    var value = try self.evalExprWithoutOrigin(expr);
    switch (expr.inner) {
        .list, .vec, .map, .tagged => {
            if (expr.getOrigin()) |origin|
                value = try value.putOrigin(self.allocator, origin.inner.vec);
        },
        else => {},
    }
    return value;
}

pub fn evalExprWithoutOrigin(self: *Evaluator, expr: preimp.Value) error{OutOfMemory}!preimp.Value {
    switch (expr.inner) {
        .nil,
        .@"true",
        .@"false",
        .string,
        .number,
        .builtin,
        .fun,
        .actions,
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
            if (head_expr.toKeyword()) |keyword| {
                switch (keyword) {
                    .def => {
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
                        const value = try self.evalExpr(list[2]);
                        try self.env.append(.{ .name = name, .value = value });
                        return value;
                    },
                    .@"fn" => {
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
                    },
                    .@"if" => {
                        // (if expr expr expr)
                        if (list.len != 4)
                            return preimp.Value.format(self.allocator,
                                \\ #"error" #"malformed if" ?
                            , .{expr});
                        const cond = try self.evalExpr(list[1]);
                        return switch (cond.inner) {
                            .@"true" => self.evalExpr(list[2]),
                            .@"false" => self.evalExpr(list[3]),
                            else => preimp.Value.format(self.allocator,
                                \\ #"error" #"non-bool in if" ?
                            , .{cond}),
                        };
                    },
                }
            } else {

                // regular forms
                const head = try self.evalExpr(list[0]);
                var tail = try u.ArrayList(preimp.Value).initCapacity(self.allocator, list.len - 1);
                for (list[1..]) |tail_expr|
                    try tail.append(try self.evalExpr(tail_expr));
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
                            .@"put!" => {
                                if (tail.items.len != 2)
                                    return preimp.Value.format(self.allocator,
                                        \\ #"error" #"wrong number of args" {"expected" ? "found" ?}
                                    , .{ 2, tail.items.len });

                                const old = tail.items[0];
                                const new = tail.items[1];

                                if (preimp.KeyVal.get(old.meta, preimp.Value.fromInner(.{ .string = "origin" }))) |old_origin| {
                                    if (old_origin.inner != .vec)
                                        return preimp.Value.format(self.allocator,
                                            \\ #"error" #"origin should be a vec" ?
                                        , .{old_origin});

                                    return preimp.Value.fromInner(.{ .actions = try self.allocator.dupe(
                                        preimp.Action,
                                        &[1]preimp.Action{
                                            .{
                                                .origin = (try old_origin.toPath(self.allocator)).?,
                                                .new = new,
                                            },
                                        },
                                    ) });
                                } else {
                                    return preimp.Value.format(self.allocator,
                                        \\ #"error" #"cannot put! a value with no origin" ?
                                    , .{old});
                                }
                            },
                            .do => {
                                var actions = u.ArrayList(preimp.Action).init(self.allocator);
                                for (tail.items) |value| {
                                    if (value.inner != .actions)
                                        return preimp.Value.format(self.allocator,
                                            \\ #"error" #"everything inside do must be an action" ?
                                        , .{value});

                                    try actions.appendSlice(value.inner.actions);
                                }
                                return preimp.Value.fromInner(.{ .actions = actions.toOwnedSlice() });
                            },
                            .map => {
                                if (tail.items.len != 2)
                                    return preimp.Value.format(self.allocator,
                                        \\ #"error" #"wrong number of args" {"expected" ? "found" ?}
                                    , .{ 2, tail.items.len });

                                const vec = tail.items[0];
                                if (vec.inner != .vec)
                                    return preimp.Value.format(self.allocator,
                                        \\ #"error" #"expected vec in map, got:" ?
                                    , .{vec});

                                const fun = tail.items[1];
                                if (fun.inner != .fun)
                                    return preimp.Value.format(self.allocator,
                                        \\ #"error" #"expected fun in map, got:" ?
                                    , .{fun});

                                const new_vec = try self.allocator.alloc(preimp.Value, vec.inner.vec.len);
                                for (new_vec) |*new_elem, i|
                                    new_elem.* = try self.apply(fun.inner.fun, vec.inner.vec[i .. i + 1]);
                                return preimp.Value.fromInner(.{ .vec = new_vec });
                            },
                            .filter => {
                                if (tail.items.len != 2)
                                    return preimp.Value.format(self.allocator,
                                        \\ #"error" #"wrong number of args" {"expected" ? "found" ?}
                                    , .{ 2, tail.items.len });

                                const vec = tail.items[0];
                                if (vec.inner != .vec)
                                    return preimp.Value.format(self.allocator,
                                        \\ #"error" #"expected vec in filter, got:" ?
                                    , .{vec});

                                const fun = tail.items[1];
                                if (fun.inner != .fun)
                                    return preimp.Value.format(self.allocator,
                                        \\ #"error" #"expected fun in filter, got:" ?
                                    , .{fun});

                                var new_vec = u.ArrayList(preimp.Value).init(self.allocator);
                                for (vec.inner.vec) |old_elem| {
                                    const keep = try self.apply(fun.inner.fun, &.{old_elem});
                                    switch (keep.inner) {
                                        .@"false" => {},
                                        .@"true" => try new_vec.append(old_elem),
                                        else => return preimp.Value.format(self.allocator,
                                            \\ #"error" #"expected filter fun to return bool, got:" ?
                                        , .{keep}),
                                    }
                                }
                                return preimp.Value.fromInner(.{ .vec = new_vec.toOwnedSlice() });
                            },
                            .@"map->vec" => {
                                if (tail.items.len != 1)
                                    return preimp.Value.format(self.allocator,
                                        \\ #"error" #"wrong number of args" {"expected" ? "found" ?}
                                    , .{ 1, tail.items.len });

                                const map = tail.items[0];
                                if (map.inner != .map)
                                    return preimp.Value.format(self.allocator,
                                        \\ #"error" #"expected map in map->vec, got:" ?
                                    , .{map});

                                var vec = try self.allocator.alloc(preimp.Value, map.inner.map.len);
                                for (vec) |*elem, i| {
                                    const key_val = map.inner.map[i];
                                    elem.* = preimp.Value.fromInner(.{
                                        .vec = try self.allocator.dupe(preimp.Value, &.{
                                            key_val.key,
                                            key_val.val,
                                        }),
                                    });
                                }
                                return preimp.Value.fromInner(.{ .vec = vec });
                            },
                            .@"vec->map" => {
                                if (tail.items.len != 1)
                                    return preimp.Value.format(self.allocator,
                                        \\ #"error" #"wrong number of args" {"expected" ? "found" ?}
                                    , .{ 1, tail.items.len });

                                const vec = tail.items[0];
                                if (vec.inner != .vec)
                                    return preimp.Value.format(self.allocator,
                                        \\ #"error" #"expected vec in vec->map, got:" ?
                                    , .{vec});

                                var map = try self.allocator.alloc(preimp.KeyVal, vec.inner.vec.len);
                                for (map) |*key_val, i| {
                                    const elem = vec.inner.vec[i];
                                    if (elem.inner != .vec or elem.inner.vec.len != 2)
                                        return preimp.Value.format(self.allocator,
                                            \\ #"error" #"expected [key val] in vec->map, got:" ?
                                        , .{elem});
                                    key_val.* = .{
                                        .key = elem.inner.vec[0],
                                        .val = elem.inner.vec[1],
                                    };
                                }
                                return preimp.KeyVal.toMap(self.allocator, map, .{});
                            },
                        }
                    },
                    .fun => |fun| {
                        return self.apply(fun, tail.items);
                    },
                    else => {
                        return preimp.Value.format(self.allocator,
                            \\ #"error" #"can't call" ?
                        , .{head});
                    },
                }
            }
        },
        .vec => |vec| {
            var body = try u.ArrayList(preimp.Value).initCapacity(self.allocator, vec.len);
            for (vec) |elem|
                try body.append(try self.evalExpr(elem));
            return preimp.Value.fromInner(.{ .vec = body.toOwnedSlice() });
        },
        .map => |map| {
            var body = try u.ArrayList(preimp.KeyVal).initCapacity(self.allocator, @divTrunc(map.len, 2));
            for (map) |key_val| {
                const key = try self.evalExpr(key_val.key);
                const val = try self.evalExpr(key_val.val);
                try body.append(.{ .key = key, .val = val });
            }
            return preimp.KeyVal.toMap(self.allocator, body.toOwnedSlice(), .{});
        },
        .tagged => |tagged| {
            const key = try self.evalExpr(tagged.key.*);
            const val = try self.evalExpr(tagged.val.*);
            return preimp.Value.fromInner(.{ .tagged = .{
                .key = try u.box(self.allocator, key),
                .val = try u.box(self.allocator, val),
            } });
        },
    }
}

fn apply(self: *Evaluator, fun: preimp.Fun, tail: []const preimp.Value) !preimp.Value {
    const fn_env_start = self.env.items.len;
    defer self.env.shrinkRetainingCapacity(fn_env_start);
    try self.env.appendSlice(fun.env);
    if (fun.args.len != tail.len)
        return preimp.Value.format(self.allocator,
            \\ #"error" #"wrong number of args" {"expected" ? "found" ?}
        , .{ fun.args.len, tail.len });
    for (fun.args) |arg, i|
        try self.env.append(.{ .name = arg, .value = tail[i] });
    return self.evalExprs(fun.body);
}
