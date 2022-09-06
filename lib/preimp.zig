const std = @import("std");

pub const util = @import("preimp/util.zig");
pub const Tokenizer = @import("preimp/Tokenizer.zig");
pub const Parser = @import("preimp/Parser.zig");
pub const Evaluator = @import("preimp/Evaluator.zig");
pub usingnamespace @import("preimp/value.zig");
pub const stdlib = @embedFile("preimp/stdlib.preimp");

test {
    @import("std").testing.refAllDecls(@This());
}
