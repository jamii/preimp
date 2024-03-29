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
    _ = args.next().?;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--rewrite-tests")) {
            rewrite_tests = true;
            continue;
        }

        const filename = arg;

        // TODO When using `--test-cmd` to run with rr, `zig run` also passes the location of the zig binary as an extra argument. I don't know how to turn this off.
        if (std.mem.endsWith(u8, filename, "zig")) continue;

        var file = if (std.mem.eql(u8, filename, "-"))
            std.io.getStdIn()
        else
            try std.fs.cwd().openFile(filename, .{ .mode = .read_write });

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

        var rewritten_tests = u.ArrayList(u8).init(allocator);
        var cases_iter = std.mem.split(u8, cases.items, "\n\n");

        var stdlib_parser = try preimp.Parser.init(allocator, preimp.stdlib);
        const stdlib = try stdlib_parser.parseExprs(null, .eof);
        var stdlib_evaluator = preimp.Evaluator.init(allocator);
        _ = try stdlib_evaluator.evalExprsKeepEnv(stdlib);

        while (cases_iter.next()) |case| {
            var case_iter = std.mem.split(u8, case, "---");
            const source = std.mem.trim(u8, case_iter.next().?, "\n ");
            const expected = std.mem.trim(u8, case_iter.next().?, "\n ");
            std.debug.assert(case_iter.next() == null);

            var arena = u.ArenaAllocator.init(allocator);
            defer arena.deinit();
            var parser = try preimp.Parser.init(arena.allocator(), try arena.allocator().dupeZ(u8, source));
            const exprs = try parser.parseExprs(null, .eof);
            var origin = u.ArrayList(preimp.Value).init(arena.allocator());
            for (exprs) |*expr, i| {
                try origin.append(try preimp.Value.fromZig(arena.allocator(), i));
                defer _ = origin.pop();
                _ = try expr.setOriginRecursively(arena.allocator(), &origin);
            }
            var evaluator = preimp.Evaluator.init(arena.allocator());
            try evaluator.env.appendSlice(stdlib_evaluator.env.items);
            const value = try evaluator.evalExprs(exprs);

            var bytes = u.ArrayList(u8).init(allocator);
            defer bytes.deinit();
            try preimp.Value.dumpInto(bytes.writer(), 0, value);
            const found = std.mem.trim(u8, bytes.items, "\n ");

            num_tests += 1;
            if (std.meta.isError(std.testing.expectEqualStrings(expected, found))) {
                num_failed += 1;
                std.debug.print("In test:\n{s}\n\n", .{source});
            }

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
