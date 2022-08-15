const std = @import("std");
const preimp = @import("../lib/preimp.zig");
const u = preimp.util;

export fn hello(i: u32) u32 {
    return i + 1;
}
