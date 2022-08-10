const std = @import("std");
const preimp = @import("../preimp.zig");
const u = preimp.util;

const Parser = @This();
allocator: u.Allocator,
source: [:0]const u8,
token_ix: TokenIx,
tokens: [:.eof]const preimp.Tokenizer.Token,
token_locs: []const [2]usize,

pub const TokenIx = usize;

pub fn init(allocator: u.Allocator, source: [:0]const u8) !Parser {
    var tokens = u.ArrayList(preimp.Tokenizer.Token).init(allocator);
    var token_locs = u.ArrayList([2]usize).init(allocator);
    var tokenizer = preimp.Tokenizer.init(source);
    while (true) {
        const start = tokenizer.pos;
        const token = tokenizer.next();
        const end = tokenizer.pos;
        try tokens.append(token);
        try token_locs.append(.{ start, end });
        if (token == .eof) break;
    }
    const tokens_slice = tokens.toOwnedSlice();
    return Parser{
        .allocator = allocator,
        .source = source,
        .token_ix = 0,
        .tokens = tokens_slice[0 .. tokens_slice.len - 1 :.eof],
        .token_locs = token_locs.toOwnedSlice(),
    };
}

fn pushValue(self: *Parser, values: *u.ArrayList(preimp.Value), value_inner: preimp.ValueInner, start: TokenIx) !void {
    const meta = try self.allocator.dupe(preimp.KeyVal, &[2]preimp.KeyVal{
        .{
            .key = preimp.Value.fromInner(.{ .string = "start token ix" }),
            .val = preimp.Value.fromInner(.{ .number = @intToFloat(f64, start) }),
        },
        .{
            .key = preimp.Value.fromInner(.{ .string = "end token ix" }),
            .val = preimp.Value.fromInner(.{ .number = @intToFloat(f64, self.token_ix) }),
        },
    });
    try values.append(.{ .inner = value_inner, .meta = meta });
}

pub fn parseExprs(self: *Parser, max_exprs_o: ?usize, closing_token: preimp.Tokenizer.Token) error{OutOfMemory}![]preimp.Value {
    var values = u.ArrayList(preimp.Value).init(self.allocator);
    while (true) {
        if (max_exprs_o) |max_exprs|
            if (values.items.len >= max_exprs)
                break;
        const start = self.token_ix;
        const token = self.tokens[start];
        self.token_ix += 1;
        switch (token) {
            .symbol => {
                const token_loc = self.token_locs[start];
                const bytes = self.source[token_loc[0]..token_loc[1]];
                const expr =
                    if (u.deepEqual(bytes, "nil"))
                    preimp.ValueInner{ .nil = {} }
                else if (u.deepEqual(bytes, "true"))
                    preimp.ValueInner{ .@"true" = {} }
                else if (u.deepEqual(bytes, "false"))
                    preimp.ValueInner{ .@"false" = {} }
                else
                    preimp.ValueInner{ .symbol = bytes };
                try self.pushValue(&values, expr, start);
            },
            .string => {
                const token_loc = self.token_locs[start];
                // TODO handle escapes
                const bytes = self.source[token_loc[0]..token_loc[1]];
                const expr = if (std.zig.string_literal.parseAlloc(self.allocator, bytes)) |string|
                    preimp.ValueInner{ .string = string }
                else |_|
                    try preimp.ValueInner.format(self.allocator,
                        \\ #"error" #"invalid string" nil
                    , .{});
                try self.pushValue(&values, expr, start);
            },
            .number => {
                const token_loc = self.token_locs[start];
                const bytes = self.source[token_loc[0]..token_loc[1]];
                const expr = if (std.fmt.parseFloat(f64, bytes)) |number|
                    preimp.ValueInner{ .number = number }
                else |_|
                    try preimp.ValueInner.format(self.allocator,
                        \\ #"error" #"invalid number" nil
                    , .{});
                try self.pushValue(&values, expr, start);
            },
            .open_list => {
                const list_values = try self.parseExprs(null, .close_list);
                try self.pushValue(&values, .{ .list = list_values }, start);
            },
            .open_vec => {
                const vec_values = try self.parseExprs(null, .close_vec);
                try self.pushValue(&values, .{ .vec = vec_values }, start);
            },
            .open_map => {
                const map_exprs = try self.parseExprs(null, .close_map);
                if (map_exprs.len % 2 == 1) {
                    try self.pushValue(
                        &values,
                        try preimp.ValueInner.format(self.allocator,
                            \\ #"error" #"map with odd elems" nil
                        , .{}),
                        start,
                    );
                } else {
                    var map_values = try u.ArrayList(preimp.KeyVal).initCapacity(self.allocator, @divTrunc(map_exprs.len, 2));
                    var i: usize = 0;
                    while (i < map_exprs.len) : (i += 2) {
                        const key = map_exprs[i];
                        const val = map_exprs[i + 1];
                        try map_values.append(.{ .key = key, .val = val });
                    }
                    u.deepSort(map_values.items);
                    // TODO check no duplicate values
                    try self.pushValue(&values, .{ .map = map_values.toOwnedSlice() }, start);
                }
            },
            .start_tag => {
                const tag_values = try self.parseExprs(2, .eof);
                const expr = if (tag_values.len != 2)
                    try preimp.ValueInner.format(self.allocator,
                        \\ #"error" #"tag ended early" nil
                    , .{})
                else
                    preimp.ValueInner{ .tagged = .{
                        .key = try u.box(self.allocator, tag_values[0]),
                        .val = try u.box(self.allocator, tag_values[1]),
                    } };
                try self.pushValue(&values, expr, start);
            },
            .close_list, .close_vec, .close_map, .eof => {
                if (token != closing_token) {
                    // pretend we saw closing_token before token
                    const expr =
                        try preimp.ValueInner.format(self.allocator,
                        \\ #"error" #"unexpected token" {"expected" ? "found" ?}
                    , .{ closing_token, token });
                    try self.pushValue(&values, expr, start);
                }
                if (token != closing_token or token == .eof)
                    self.token_ix -= 1;
                break;
            },
            .err => {
                try self.pushValue(
                    &values,
                    try preimp.ValueInner.format(self.allocator,
                        \\ #"error" #"tokenizer error" nil
                    , .{}),
                    start,
                );
            },
            .comment, .whitespace => continue,
        }
    }
    return values.toOwnedSlice();
}
