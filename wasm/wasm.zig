const std = @import("std");
const preimp = @import("../lib/preimp.zig");
const u = preimp.util;
const json = @import("./json.zig");

var gpa = std.heap.GeneralPurposeAllocator(.{
    .safety = true,
    .never_unmap = true,
}){
    .backing_allocator = std.heap.page_allocator,
};
pub const allocator = gpa.allocator();

const JsArgs = struct {
    input: []const u8,
    output: []const u8,
};
var js_args = JsArgs{
    .input = "",
    .output = "",
};

export fn inputAlloc(len: usize) usize {
    checkIfPanicked();
    allocator.free(js_args.input);
    js_args.input = allocator.allocSentinel(u8, len, 0) catch
        u.panic("OOM", .{});
    return @ptrToInt(js_args.input.ptr);
}

export fn outputPtr() usize {
    checkIfPanicked();
    return @ptrToInt(js_args.output.ptr);
}

export fn outputLen() usize {
    checkIfPanicked();
    return js_args.output.len;
}

fn parseInner() !void {
    var arena = u.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var parser = try preimp.Parser.init(arena.allocator(), try arena.allocator().dupeZ(u8, js_args.input));
    const exprs = try parser.parseExprs(null, .eof);

    var output = u.ArrayList(u8).init(allocator);
    try json.stringify(exprs, .{}, output.writer());
    allocator.free(js_args.output);
    js_args.output = output.toOwnedSlice();
}
export fn parse() void {
    checkIfPanicked();
    parseInner() catch |err|
        u.panic("{}", .{err});
}

fn evalInner() !void {
    var arena = u.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var token_stream = json.TokenStream.init(js_args.input);
    @setEvalBranchQuota(10000);
    const exprs = try json.parse([]preimp.Value, &token_stream, .{ .allocator = arena.allocator() });
    var evaluator = preimp.Evaluator.init(arena.allocator());
    var origin = u.ArrayList(preimp.Value).init(arena.allocator());
    const value = try evaluator.evalExprs(exprs, &origin);

    var output = u.ArrayList(u8).init(allocator);
    try json.stringify(value, .{}, output.writer());
    allocator.free(js_args.output);
    js_args.output = output.toOwnedSlice();
}
export fn eval() void {
    checkIfPanicked();
    evalInner() catch |err|
        u.panic("{}", .{err});
}

extern fn jsPanic(string_ptr: usize, string_len: usize) noreturn;

var panicked = false;

pub fn checkIfPanicked() void {
    if (panicked)
        u.panic("Already panicked", .{});
}

pub fn panic(message: []const u8, stack_trace: ?*std.builtin.StackTrace) noreturn {
    panicked = true;
    var full_message = std.ArrayList(u8).init(allocator);
    defer allocator.free(full_message);
    std.fmt.format(full_message.writer(), "{s}\n\nTrace:\n{any}", .{ message, stack_trace }) catch
        std.mem.copy(u8, full_message.items[full_message.items.len - 3 .. full_message.items.len], "OOM");
    jsPanic(@ptrToInt(full_message.items.ptr), full_message.items.len);
}

extern fn jsLog(string_ptr: usize, string_len: usize) noreturn;

pub fn log(
    comptime message_level: std.log.Level,
    comptime scope: @Type(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    var full_message = std.ArrayList(u8).init(allocator);
    defer allocator.free(full_message);
    std.fmt.format(full_message.writer(), "{} {}:", .{ message_level, scope }) catch
        std.mem.copy(u8, full_message.items[full_message.items.len - 3 .. full_message.items.len], "OOM");
    std.fmt.format(full_message.writer(), format, args) catch
        std.mem.copy(u8, full_message.items[full_message.items.len - 3 .. full_message.items.len], "OOM");
    jsLog(@ptrToInt(full_message.items.ptr), full_message.items.len);
}
