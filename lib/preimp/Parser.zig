const std = @import("std");
const preimp = @import("../preimp.zig");
const u = preimp.util;

const Parser = @This();
allocator: u.Allocator,
source: [:0]const u8,
token_ix: TokenIx,
tokens: [:.eof]const preimp.Tokenizer.Token,
token_locs: []const [2]usize,
exprs: u.ArrayList(Expr),
expr_locs: u.ArrayList([2]TokenIx),

pub const TokenIx = usize;
pub const ExprIx = usize;

pub const Expr = union(enum) {
    symbol: []const u8,
    string: []const u8,
    number: f64,
    list: []const ExprIx,
    vec: []const ExprIx,
    map: []const ExprIx,
    err: Error,
};

pub const Error = union(enum) {
    unexpected: struct {
        expected: preimp.Tokenizer.Token,
        found: preimp.Tokenizer.Token,
    },
    invalid_number,
    invalid_string,
    map_with_odd_elems,
    tokenizer_error,
};

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
        .exprs = u.ArrayList(Expr).init(allocator),
        .expr_locs = u.ArrayList([2]TokenIx).init(allocator),
    };
}

fn takeToken(self: *Parser) preimp.Tokenizer.Token {
    const token = self.tokens[self.token_ix];
    self.token_ix += 1;
    return token;
}

fn pushExpr(self: *Parser, expr_ixes: *u.ArrayList(ExprIx), expr: Expr, start: TokenIx) !void {
    const expr_ix = self.exprs.items.len;
    try self.exprs.append(expr);
    try self.expr_locs.append(.{ start, self.token_ix });
    try expr_ixes.append(expr_ix);
}

pub fn parseExprs(self: *Parser, closing_token: preimp.Tokenizer.Token) error{OutOfMemory}![]const ExprIx {
    var expr_ixes = u.ArrayList(ExprIx).init(self.allocator);
    while (true) {
        const start = self.token_ix;
        const token = self.takeToken();
        switch (token) {
            .symbol => {
                const token_loc = self.token_locs[start];
                const bytes = self.source[token_loc[0]..token_loc[1]];
                try self.pushExpr(&expr_ixes, .{ .symbol = bytes }, start);
            },
            .string => {
                const token_loc = self.token_locs[start];
                // TODO handle escapes
                const bytes = self.source[token_loc[0]..token_loc[1]];
                const expr = if (std.zig.string_literal.parseAlloc(self.allocator, bytes)) |string|
                    Expr{ .string = string }
                else |_|
                    Expr{ .err = .invalid_string };
                try self.pushExpr(&expr_ixes, expr, start);
            },
            .number => {
                const token_loc = self.token_locs[start];
                const bytes = self.source[token_loc[0]..token_loc[1]];
                const expr = if (std.fmt.parseFloat(f64, bytes)) |number|
                    Expr{ .number = number }
                else |_|
                    Expr{ .err = .invalid_number };
                try self.pushExpr(&expr_ixes, expr, start);
            },
            .open_list => {
                const list_expr_ixes = try self.parseExprs(.close_list);
                try self.pushExpr(&expr_ixes, .{ .list = list_expr_ixes }, start);
            },
            .open_vec => {
                const vec_expr_ixes = try self.parseExprs(.close_vec);
                try self.pushExpr(&expr_ixes, .{ .vec = vec_expr_ixes }, start);
            },
            .open_map => {
                const map_expr_ixes = try self.parseExprs(.close_map);
                const expr = if (map_expr_ixes.len % 2 == 0)
                    Expr{ .map = map_expr_ixes }
                else
                    Expr{ .err = .map_with_odd_elems };
                try self.pushExpr(&expr_ixes, expr, start);
            },
            .close_list, .close_vec, .close_map, .eof => {
                if (token != closing_token) {
                    // pretend we saw closing_token before token
                    const expr = Expr{ .err = .{ .unexpected = .{ .expected = closing_token, .found = token } } };
                    try self.pushExpr(&expr_ixes, expr, start);
                    self.token_ix -= 1;
                }
                break;
            },
            .err => {
                try self.pushExpr(&expr_ixes, .{ .err = .tokenizer_error }, start);
            },
            .comment, .whitespace => continue,
        }
    }
    return expr_ixes.toOwnedSlice();
}

pub fn dumpInto(self: Parser, writer: anytype, indent: u32, expr_ixes: []const ExprIx) anyerror!void {
    for (expr_ixes) |expr_ix| {
        const expr = self.exprs.items[expr_ix];
        switch (expr) {
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
                try self.dumpInto(writer, indent + 4, list);
                try writer.writeByteNTimes(' ', indent);
                try writer.writeAll(")\n");
            },
            .vec => |vec| {
                try writer.writeByteNTimes(' ', indent);
                try writer.writeAll("[\n");
                try self.dumpInto(writer, indent + 4, vec);
                try writer.writeByteNTimes(' ', indent);
                try writer.writeAll("]\n");
            },
            .map => |map| {
                try writer.writeByteNTimes(' ', indent);
                try writer.writeAll("{\n");
                try self.dumpInto(writer, indent + 4, map);
                try writer.writeByteNTimes(' ', indent);
                try writer.writeAll("}\n");
            },
            .err => |_| {
                try writer.writeByteNTimes(' ', indent);
                try std.fmt.format(writer, "err\n", .{});
            },
        }
    }
}

fn testParse(source: [:0]const u8, expected: []const u8) !void {
    var arena = u.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try Parser.init(arena.allocator(), source);
    const expr_ixes = try parser.parseExprs(.eof);
    var found = u.ArrayList(u8).init(arena.allocator());
    try parser.dumpInto(found.writer(), 0, expr_ixes);
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
        \\        err
        \\    )
        \\]
        \\
    );
    try testParse(
        \\["foo""bar"]
    ,
        \\[
        \\    err
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
        \\    err
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
}
