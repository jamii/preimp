const std = @import("std");
const preimp = @import("../lib/preimp.zig");
const u = preimp.util;

var gpa = std.heap.GeneralPurposeAllocator(.{
    .safety = true,
    .never_unmap = true,
}){
    .backing_allocator = std.heap.page_allocator,
};
pub const allocator = gpa.allocator();

extern fn jsLog(string_ptr: usize, string_len: usize) noreturn;
extern fn jsPanic(string_ptr: usize, string_len: usize) noreturn;

const EvalState = struct {
    source: ?[:0]const u8,
    result: []const u8,
};
var eval_state = EvalState{
    .source = null,
    .result = "",
};
export fn evalSourceAlloc(len: usize) usize {
    checkIfPanicked();
    if (eval_state.source) |source| allocator.free(source);
    eval_state.source = allocator.allocSentinel(u8, len, 0) catch unreachable;
    return @ptrToInt(eval_state.source.?.ptr);
}
export fn evalResultPtr() usize {
    checkIfPanicked();
    return @ptrToInt(eval_state.result.ptr);
}
export fn evalResultLen() usize {
    checkIfPanicked();
    return eval_state.result.len;
}
fn evalInner() !void {
    var arena = u.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var parser = try preimp.Parser.init(arena.allocator(), eval_state.source.?);
    const exprs = try parser.parseExprs(null, .eof);
    var evaluator = preimp.Evaluator.init(arena.allocator());
    var origin = u.ArrayList(preimp.Value).init(arena.allocator());
    const value = try evaluator.evalExprs(exprs, &origin);

    var eval_result = u.ArrayList(u8).init(allocator);
    try preimp.Value.dumpInto(eval_result.writer(), 0, value);
    allocator.free(eval_state.result);
    eval_state.result = eval_result.toOwnedSlice();
}
export fn eval() void {
    checkIfPanicked();
    evalInner() catch unreachable;
}

var panicked = false;
pub fn checkIfPanicked() void {
    if (panicked)
        @panic("Already panicked");
}
pub fn panic(message: []const u8, stack_trace: ?*std.builtin.StackTrace) noreturn {
    panicked = true;
    var full_message = std.ArrayList(u8).init(allocator);
    // don't need to free full_message because we won't accept any more function calls
    std.fmt.format(full_message.writer(), "{s}\n\nTrace:\n{s}", .{ message, stack_trace }) catch
        std.mem.copy(u8, full_message.items[full_message.items.len - 3 .. full_message.items.len], "OOM");
    jsPanic(@ptrToInt(full_message.items.ptr), full_message.items.len);
}

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
