const std = @import("std");
const preimp = @import("../lib/preimp.zig");
const u = preimp.util;

pub fn main() anyerror!void {
    var allocator = std.heap.c_allocator;

    var num_tests: usize = 0;
    var num_failed: usize = 0;

    var rewrite_tests = false;

    var args = std.process.args();
    // arg 0 is executable
    _ = try args.next(allocator).?;
    while (args.next(allocator)) |arg| {
        var rewritten_tests = u.ArrayList(u8).init(allocator);
        const filename = try arg;

        if (std.mem.eql(u8, filename, "--rewrite-tests")) {
            rewrite_tests = true;
            continue;
        }

        // TODO When using `--test-cmd` to run with rr, `zig run` also passes the location of the zig binary as an extra argument. I don't know how to turn this off.
        if (std.mem.endsWith(u8, filename, "zig")) continue;

        var file = if (std.mem.eql(u8, filename, "-"))
            std.io.getStdIn()
        else
            try std.fs.cwd().openFile(filename, .{ .read = true, .write = true });

        // TODO can't use readFileAlloc on stdin
        var cases = u.ArrayList(u8).init(allocator);
        defer cases.deinit();
        {
            const chunk_size = 1024;
            var buf = try allocator.alloc(u8, chunk_size);
            defer allocator.free(buf);
            while (true) {
                const len = try file.readAll(buf);
                try cases.appendSlice(buf[0..len]);
                if (len < chunk_size) break;
            }
        }

        var cases_iter = std.mem.split(u8, cases.items, "\n\n");
        while (cases_iter.next()) |case| {
            var case_iter = std.mem.split(u8, case, "---");
            const source = std.mem.trim(u8, case_iter.next().?, "\n ");
            const expected = std.mem.trim(u8, case_iter.next().?, "\n ");
            try std.testing.expectEqual(case_iter.next(), null);

            var arena = u.ArenaAllocator.init(allocator);
            defer arena.deinit();

            var parser = try preimp.Parser.init(arena.allocator(), try arena.allocator().dupeZ(u8, source));
            const expr_ixes = try parser.parseExprs(.eof);
            var evaluator = preimp.Evaluator.init(arena.allocator(), parser.exprs.items);
            const value = try evaluator.evalExprs(expr_ixes);

            var bytes = u.ArrayList(u8).init(allocator);
            defer bytes.deinit();
            const writer = bytes.writer();
            try preimp.Evaluator.Value.dumpInto(writer, 0, value);
            const found = std.mem.trim(u8, bytes.items, "\n ");

            num_tests += 1;
            if (std.meta.isError(std.testing.expectEqualStrings(expected, found)))
                num_failed += 1;

            if (rewrite_tests) {
                if (rewritten_tests.items.len > 0)
                    try rewritten_tests.appendSlice("\n\n");
                try std.fmt.format(rewritten_tests.writer(), "{s}\n---\n{s}", .{ source, found });
            }
        }

        if (rewrite_tests) {
            try file.seekTo(0);
            try file.setEndPos(0);
            try file.writeAll(rewritten_tests.items);
        }

        if (num_failed > 0) {
            std.debug.print("{}/{} tests failed!\n", .{ num_failed, num_tests });
            std.os.exit(1);
        } else {
            std.debug.print("All {} tests passed\n", .{num_tests});
            std.os.exit(0);
        }
    }
}
