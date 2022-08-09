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

fn boxValue(self: *Parser, value: preimp.Value) !*preimp.Value {
    // TODO add meta for source location
    const value_box = try self.allocator.create(preimp.Value);
    value_box.* = value;
    return value_box;
}

fn pushValue(self: *Parser, values: *u.ArrayList(preimp.Value), value: preimp.Value, start: TokenIx) !void {
    // TODO add meta for source location
    _ = self;
    _ = start;
    try values.append(value);
}

pub fn parseExprs(self: *Parser, max_exprs_o: ?usize, closing_token: preimp.Tokenizer.Token) error{OutOfMemory}![]const preimp.Value {
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
                    preimp.Value{ .nil = {} }
                else if (u.deepEqual(bytes, "true"))
                    preimp.Value{ .@"true" = {} }
                else if (u.deepEqual(bytes, "false"))
                    preimp.Value{ .@"false" = {} }
                else
                    preimp.Value{ .symbol = bytes };
                try self.pushValue(&values, expr, start);
            },
            .string => {
                const token_loc = self.token_locs[start];
                // TODO handle escapes
                const bytes = self.source[token_loc[0]..token_loc[1]];
                const expr = if (std.zig.string_literal.parseAlloc(self.allocator, bytes)) |string|
                    preimp.Value{ .string = string }
                else |_|
                    preimp.Value{ .err = .invalid_string };
                try self.pushValue(&values, expr, start);
            },
            .number => {
                const token_loc = self.token_locs[start];
                const bytes = self.source[token_loc[0]..token_loc[1]];
                const expr = if (std.fmt.parseFloat(f64, bytes)) |number|
                    preimp.Value{ .number = number }
                else |_|
                    preimp.Value{ .err = .invalid_number };
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
                    try self.pushValue(&values, .{ .err = .map_with_odd_elems }, start);
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
                    preimp.Value{ .err = .tag_ended_early }
                else
                    preimp.Value{ .tagged = .{
                        .key = try self.boxValue(tag_values[0]),
                        .val = try self.boxValue(tag_values[1]),
                    } };
                try self.pushValue(&values, expr, start);
            },
            .close_list, .close_vec, .close_map, .eof => {
                if (token != closing_token) {
                    // pretend we saw closing_token before token
                    const expr = preimp.Value{ .err = .{ .unexpected = .{ .expected = closing_token, .found = token } } };
                    try self.pushValue(&values, expr, start);
                }
                if (token != closing_token or token == .eof)
                    self.token_ix -= 1;
                break;
            },
            .err => {
                try self.pushValue(&values, .{ .err = .tokenizer_error }, start);
            },
            .comment, .whitespace => continue,
        }
    }
    return values.toOwnedSlice();
}

fn testParse(source: [:0]const u8, expected: []const u8) !void {
    var arena = u.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try Parser.init(arena.allocator(), source);
    const values = try parser.parseExprs(null, .eof);
    var found = u.ArrayList(u8).init(arena.allocator());
    for (values) |value|
        try preimp.Value.dumpInto(found.writer(), 0, value);
    try std.testing.expectEqualStrings(expected, found.items);
}

test {
    try testParse(
        \\(= [1 3.14 -0.4 -0.] {"foo" "ba\"r"})
    ,
        \\(
        \\    =
        \\    [
        \\        1.0e+00
        \\        3.14e+00
        \\        -4.0e-01
        \\        -0.0e+00
        \\    ]
        \\    {
        \\        "foo"
        \\        "ba\"r"
        \\    }
        \\)
        \\
    );
    try testParse(
        \\[1 (= 2]
    ,
        \\[
        \\    1.0e+00
        \\    (
        \\        =
        \\        2.0e+00
        \\        #
        \\            "error"
        \\            Error{ .unexpected = lib.preimp.value.struct:151:17{ .expected = Token.close_list, .found = Token.close_vec } }
        \\    )
        \\]
        \\
    );
    try testParse(
        \\["foo""bar"]
    ,
        \\[
        \\    #
        \\        "error"
        \\        Error{ .tokenizer_error = void }
        \\]
        \\
    );
    try testParse(
        \\(def a 1
    ,
        \\(
        \\    def
        \\    a
        \\    1.0e+00
        \\    #
        \\        "error"
        \\        Error{ .unexpected = lib.preimp.value.struct:151:17{ .expected = Token.close_list, .found = Token.eof } }
        \\)
        \\
    );
    try testParse(
        \\def a 1
    ,
        \\def
        \\a
        \\1.0e+00
        \\
    );

    try testParse(
        \\[#foo bar quux]
    ,
        \\[
        \\    #
        \\        foo
        \\        bar
        \\    quux
        \\]
        \\
    );
}
