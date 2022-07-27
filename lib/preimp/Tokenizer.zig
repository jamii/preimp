const std = @import("std");
const preimp = @import("../preimp.zig");
const u = preimp.util;

const Tokenizer = @This();
source: [:0]const u8,
pos: usize,

pub const Token = enum {
    symbol,
    string,
    number,
    open_list,
    close_list,
    open_vec,
    close_vec,
    open_map,
    close_map,
    comment,
    whitespace,
    eof,
    err,
};

const State = enum {
    start,
    symbol,
    string,
    string_escape,
    string_end,
    number,
    comment,
    whitespace,
    minus,
    err,
};

pub fn init(source: [:0]const u8) Tokenizer {
    return .{
        .source = source,
        .pos = 0,
    };
}

pub fn next(self: *Tokenizer) Token {
    var state = State.start;
    while (true) {
        const char = self.source[self.pos];
        self.pos += 1;
        switch (state) {
            .start => switch (char) {
                0 => {
                    self.pos -= 1;
                    return .eof;
                },
                '(' => return .open_list,
                ')' => return .close_list,
                '[' => return .open_vec,
                ']' => return .close_vec,
                '{' => return .open_map,
                '}' => return .close_map,
                '"' => state = .string,
                ';' => state = .comment,
                'a'...'z', 'A'...'Z', '&', '*', '+', '!', '_', '?', '<', '>', '=' => state = .symbol,
                '0'...'9' => state = .number,
                '-' => state = .minus,
                ' ', '\r', '\t', '\n' => state = .whitespace,
                else => state = .err,
            },
            .string => switch (char) {
                0, '\n' => {
                    self.pos -= 1;
                    return .err;
                },
                '\\' => state = .string_escape,
                '"' => state = .string_end,
                else => {},
            },
            .string_escape => switch (char) {
                0, '\n' => {
                    self.pos -= 1;
                    return .err;
                },
                else => state = .string,
            },
            .string_end => switch (char) {
                0, ' ', '\r', '\t', '\n', ')', ']', '}' => {
                    self.pos -= 1;
                    return .string;
                },
                else => {
                    self.pos -= 1;
                    state = .err;
                },
            },
            .comment => switch (char) {
                0, '\r', '\n' => {
                    self.pos -= 1;
                    return .comment;
                },
                else => {},
            },
            .whitespace => switch (char) {
                ' ', '\r', '\t', '\n' => {},
                else => {
                    self.pos -= 1;
                    return .whitespace;
                },
            },
            .number => switch (char) {
                '0'...'9', '.' => {},
                0, ' ', '\r', '\t', '\n', ')', ']', '}' => {
                    self.pos -= 1;
                    return .number;
                },
                else => {
                    self.pos -= 1;
                    state = .err;
                },
            },
            .symbol => switch (char) {
                'a'...'z', 'A'...'Z', '0'...'9', '&', '*', '+', '!', '_', '?', '<', '>', '=', '-' => {},
                0, ' ', '\r', '\t', '\n', ')', ']', '}' => {
                    self.pos -= 1;
                    return .symbol;
                },
                else => {
                    self.pos -= 1;
                    state = .err;
                },
            },
            .minus => switch (char) {
                '0'...'9' => state = .number,
                else => {
                    self.pos -= 1;
                    state = .symbol;
                },
            },
            .err => switch (char) {
                0, ' ', '\r', '\t', '\n', ')', ']', '}', '(', '[', '{' => {
                    self.pos -= 1;
                    return .err;
                },
                else => {},
            },
        }
    }
}

fn testTokenize(source: [:0]const u8, expected_tokens: []const Token) !void {
    var tokenizer = Tokenizer.init(source);
    for (expected_tokens) |expected_token| {
        const token = tokenizer.next();
        try std.testing.expectEqual(expected_token, token);
    }
    const last_token = tokenizer.next();
    try std.testing.expectEqual(Token.eof, last_token);
    try std.testing.expectEqual(source.len, tokenizer.pos);
}

test "basic" {
    try testTokenize("()", &.{ .open_list, .close_list });
    try testTokenize("[]", &.{ .open_vec, .close_vec });
    try testTokenize("{}", &.{ .open_map, .close_map });
    try testTokenize("; foo ()", &.{.comment});
    try testTokenize(
        \\; foo
        \\foo
    , &.{ .comment, .whitespace, .symbol });
}

test "strings" {
    try testTokenize(
        \\"foo" "bar"
    , &.{ .string, .whitespace, .string });
    try testTokenize(
        \\"foo"]"bar"
    , &.{ .string, .close_vec, .string });
    try testTokenize(
        \\"foo""bar"
    , &.{.err});
    try testTokenize(
        \\"foo\"" bar
    , &.{ .string, .whitespace, .symbol });
    try testTokenize(
        \\"foo\""bar
    , &.{.err});
    try testTokenize(
        \\"\n\r\\"
    , &.{.string});
    try testTokenize(
        \\"foo
        \\bar"
    , &.{ .err, .whitespace, .err });

    // these should fail validation later
    try testTokenize(
        \\"\z"
    , &.{.string});
}

test "symbols" {
    try testTokenize("a", &.{.symbol});
    try testTokenize("-><-", &.{.symbol});
    try testTokenize("???", &.{.symbol});
    try testTokenize("-a1", &.{.symbol});

    try testTokenize("foo.bar/quux", &.{.err});
    try testTokenize("java$has$dollars", &.{.err});
    try testTokenize("a##", &.{.err});
}

test "numbers" {
    try testTokenize("1", &.{.number});
    try testTokenize("3.14", &.{.number});
    try testTokenize("-0.32", &.{.number});
    try testTokenize("1-", &.{.err});

    // these should fail validation later
    try testTokenize("0.", &.{.number});
    try testTokenize("0.0.0", &.{.number});

    try testTokenize("-1a", &.{.err});
    try testTokenize("32N", &.{.err});
    try testTokenize("1/2", &.{.err});
    try testTokenize("-1/2", &.{.err});
}

test "boundaries" {
    try testTokenize("(def a [1])", &.{ .open_list, .symbol, .whitespace, .symbol, .whitespace, .open_vec, .number, .close_vec, .close_list });
    try testTokenize("(def a[1])", &.{ .open_list, .symbol, .whitespace, .err, .open_vec, .number, .close_vec, .close_list });
    try testTokenize(
        \\[#-?"foo"]
    , &.{ .open_vec, .err, .close_vec });

    try testTokenize(
        \\[""]
    , &.{ .open_vec, .string, .close_vec });
    try testTokenize(
        \\[""[]]
    , &.{ .open_vec, .err, .open_vec, .close_vec, .close_vec });
}

test "real code" {
    try testTokenize("(- 1)", &.{ .open_list, .symbol, .whitespace, .number, .close_list });

    try testTokenize(
        \\(.startsWith(:uri request) "/out")
    , &.{ .open_list, .err, .open_list, .err, .whitespace, .symbol, .close_list, .whitespace, .string, .close_list });

    try testTokenize("#/ {}", &.{ .err, .whitespace, .open_map, .close_map });
}
